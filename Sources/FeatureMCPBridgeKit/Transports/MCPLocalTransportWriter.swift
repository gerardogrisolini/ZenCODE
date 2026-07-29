import Synchronization
//
//  MCPLocalTransportWriter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if os(macOS)
import Darwin
import Dispatch
import Foundation

/// Serialized, non-blocking writer for a local MCP bridge's stdin.
///
/// All writes are funneled through a single detached consumer task that drains
/// an `AsyncStream`, so exactly one frame is ever in flight on the descriptor at
/// a time: concurrent producers cannot interleave bytes even though an
/// individual write suspends on back-pressure. Because the descriptor is
/// non-blocking, a full pipe yields async back-pressure (`Task.sleep` on
/// `EAGAIN`) instead of blocking a thread; `MCPClient` merely awaits the job's
/// continuation and stays free to run `disconnect()` or cancellation handlers.
struct MCPLocalTransportWriter: Sendable {
    /// Only the job identity travels through the stream. The continuation itself
    /// is owned by `registry`, never by the stream buffer — see the registry's
    /// documentation for why that distinction is what prevents the teardown leak.
    private struct Job: Sendable {
        let id: UInt64
        let payload: Data
    }

    /// Grace granted to a frame that was ALREADY partially written when teardown
    /// began. In normal operation a started frame is never truncated; during
    /// teardown the peer may be gone for good (a descendant can keep the read end
    /// open without ever draining it), so the wait must be finite.
    static let defaultTeardownFrameGraceNanoseconds: UInt64 = 500_000_000
    /// Back-pressure poll interval. Deliberately not a busy loop.
    private static let maxQueuedJobs = 128
    private static let backPressurePollNanoseconds: UInt64 = 1_000_000

    private let task: Task<Void, Never>
    private let sink: AsyncStream<Job>.Continuation
    /// The single owner of every unresolved job continuation. Boxed in a class
    /// because `Mutex` is non-copyable while this writer is a value type shared
    /// by copy between the actor and its detached consumer.
    private let registry = MCPLocalTransportWriterJobRegistry()
    /// Sole holder of the stdin descriptor. Every syscall goes through it, so
    /// detaching it is what makes closing the FD safe — independently of whether
    /// the consumer task has finished unwinding.
    private let gate: MCPLocalTransportWriterDescriptorGate

    init(
        fileDescriptor: Int32,
        teardownFrameGraceNanoseconds: UInt64 = MCPLocalTransportWriter
            .defaultTeardownFrameGraceNanoseconds
    ) {
        let (stream, continuation) = AsyncStream<Job>.makeStream(
            bufferingPolicy: .bufferingOldest(Self.maxQueuedJobs)
        )
        sink = continuation
        let registry = self.registry
        let gate = MCPLocalTransportWriterDescriptorGate(descriptor: fileDescriptor)
        self.gate = gate
        task = Task.detached(name: "MCP local transport writer") {
            var writeFailure: Error?
            for await job in stream {
                // Claim the job FOR WRITING. `nil` means it is no longer
                // writable: a cancelled request withdrew it while it was still
                // queued, a terminated yield reclaimed it, or the final drain
                // below already concluded it. In every case the payload must not
                // reach the wire and its continuation must not be resumed twice.
                guard let result = registry.claimForWrite(job.id) else {
                    continue
                }
                // From here the job is in flight: this loop owns `result` and no
                // cancellation may withdraw it any more, which is what keeps a
                // started frame from being truncated mid-write.
                defer { registry.completeInFlight(job.id) }
                // Once teardown has begun (or the writer task was cancelled),
                // stop writing but keep draining so buffered jobs fail fast
                // instead of riding on a descriptor that is about to close.
                if let writeFailure {
                    result.resume(throwing: writeFailure)
                    continue
                }
                if Task.isCancelled || registry.isTearingDown {
                    let error = CancellationError()
                    writeFailure = error
                    result.resume(throwing: error)
                    continue
                }
                do {
                    try await Self.writeAllNonBlocking(
                        MCPTransportCodec.frame(job.payload),
                        through: gate,
                        registry: registry,
                        teardownFrameGraceNanoseconds: teardownFrameGraceNanoseconds
                    )
                    result.resume()
                } catch {
                    // A failed descriptor stays failed: fail the remaining
                    // buffered jobs with the same error instead of retrying a
                    // write that cannot succeed.
                    writeFailure = error
                    result.resume(throwing: error)
                }
            }

            // A cancelled `for await` over an AsyncStream stops delivering
            // immediately and DROPS whatever is still buffered, so `finish()`
            // followed by `cancel()` (exactly what disconnect() does) can end the
            // loop with jobs still queued. Because the registry — not the stream
            // — owns those continuations, they are still reachable here and are
            // concluded before the task ends. This runs synchronously and without
            // an `await` on purpose: it must complete even though the task is
            // already cancelled, which is what makes `join()` a real guarantee
            // that no continuation stays suspended and the FD can be closed.
            let abandoned = registry.drainQueued()
            let terminalError = writeFailure ?? CancellationError()
            for result in abandoned {
                result.resume(throwing: terminalError)
            }
        }
    }

    /// Enqueues `payload` for serialized writing and suspends until it has been
    /// fully written (or fails).
    ///
    /// Cancelling the caller WITHDRAWS the job as long as it is still queued, so
    /// a cancelled MCP request never reaches the bridge even when the writer is
    /// wedged on a full pipe and the job was already buffered by the stream.
    /// Once the consumer claimed the job for writing, withdrawal deliberately
    /// fails: the frame is completed instead of being truncated on the wire.
    func enqueue(_ payload: Data) async throws {
        try Task.checkCancellation()
        // The job id only exists inside the continuation body, so publish it on a
        // ticket that the cancellation handler can read (and that records a
        // cancellation arriving before registration).
        let ticket = MCPLocalTransportWriterJobTicket()
        let registry = self.registry
        let sink = self.sink
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Register first: from this point the registry is the single owner
                // of the continuation, so every exit path below (rejection,
                // withdrawal, dropped yield, consumer drain, teardown) resolves it
                // exactly once, and none of them can resolve it twice.
                guard let id = registry.register(continuation) else {
                    // Teardown already started; the job could never be drained.
                    continuation.resume(throwing: CancellationError())
                    return
                }

                // Cancellation that fired before the id was published must still
                // withdraw the job, otherwise it would ride to the bridge.
                guard ticket.adopt(id) else {
                    registry.withdrawIfQueued(id)?.resume(throwing: CancellationError())
                    return
                }

                switch sink.yield(Job(id: id, payload: payload)) {
                case .enqueued:
                    break
                case let .dropped(droppedJob):
                    registry.withdrawIfQueued(droppedJob.id)?.resume(
                        throwing: MCPLocalTransportWriterError.queueFull
                    )
                case .terminated:
                    registry.withdrawIfQueued(id)?.resume(throwing: CancellationError())
                @unknown default:
                    registry.withdrawIfQueued(id)?.resume(
                        throwing: MCPLocalTransportWriterError.queueFull
                    )
                }
            }
        } onCancel: {
            // Withdraw only while queued. `withdrawIfQueued` returns nil once the
            // consumer owns the job, so an already-started frame is never cut
            // short; the consumer resumes that caller when the frame completes.
            guard let id = ticket.cancel() else {
                return
            }
            registry.withdrawIfQueued(id)?.resume(throwing: CancellationError())
        }
    }

    /// Number of jobs the consumer currently owns for writing, i.e. frames that
    /// may already be partially on the wire and are therefore NOT withdrawable.
    /// Exposed so the cancellation invariants can be asserted directly.
    var inFlightJobCount: Int {
        registry.inFlightCount
    }

    /// Jobs registered but not yet claimed by the consumer: still withdrawable.
    var queuedJobCount: Int {
        registry.queuedCount
    }

    /// `true` once a frame is provably wedged: it has already put bytes on the
    /// wire AND has hit at least one `EAGAIN`. Tests await this instead of
    /// sleeping, which makes the "writer stuck on a full pipe" precondition a
    /// deterministic happens-before edge rather than a timing assumption.
    var didStallInFlightFrame: Bool {
        registry.didStallInFlightFrame
    }

    /// `true` while this writer may still issue a `write()` on its descriptor.
    /// Becomes `false` permanently once teardown detached it, which is the exact
    /// condition that makes closing/recycling the FD safe.
    var isDescriptorValid: Bool {
        gate.isValid
    }

    /// Stops accepting new jobs. Buffered jobs are still concluded by the
    /// consumer task (draining normally, or failing whatever remains in the
    /// registry when cancellation cut the drain short).
    ///
    /// This also arms the teardown deadline for a frame that is ALREADY on the
    /// wire: from here that frame gets a finite grace window instead of waiting
    /// for pipe capacity forever. Without it, a bridge that exited while a
    /// descendant still holds the read end open (and never drains it) would wedge
    /// the write on `EAGAIN` permanently and make `join()` non-terminating.
    func finish() {
        registry.beginTeardown()
        sink.finish()
    }

    func cancel() {
        // Cancelling the consumer IS a teardown signal: it must also arm the
        // deadline for a frame already on the wire. Otherwise `cancel()` without
        // `finish()` would leave a wedged frame waiting for pipe capacity that a
        // dead peer will never provide, and `join()` would never return.
        registry.beginTeardown()
        task.cancel()
    }

    func join() async {
        await task.value
    }

    /// Detaches the descriptor from the writer, permanently and idempotently.
    ///
    /// After this returns, no code path of this writer can ever issue another
    /// `write()` on that FD — including a consumer that is still unwinding. That
    /// is what makes closing (and letting the OS recycle) the descriptor safe
    /// WITHOUT first awaiting `join()`, which is exactly the dependency that
    /// could deadlock teardown.
    func invalidateDescriptor() {
        gate.invalidate()
    }

    /// Bounded teardown: stop accepting jobs, cancel the consumer, then wait for
    /// the consumer only up to `timeoutNanoseconds`.
    ///
    /// Returns `true` when the consumer finished on its own. On `false` the
    /// descriptor has still been detached and every registry-owned continuation
    /// has still been concluded, so the caller may close the FD immediately: the
    /// straggler can no longer touch it, it can only observe the closed gate and
    /// exit. Process teardown therefore always terminates.
    @discardableResult
    func shutdown(
        timeoutNanoseconds: UInt64 = MCPLocalTransportWriter.defaultTeardownFrameGraceNanoseconds * 2
    ) async -> Bool {
        finish()
        cancel()

        // Race "consumer finished" against a deadline. Both arms run on DETACHED
        // tasks so neither is shortened by a caller that is itself already
        // cancelled, and the outcome is published through a one-shot box so the
        // waiter is resumed exactly once and never waits for the loser.
        let outcome = MCPLocalTransportWriterDeadlineBox()
        let consumer = task
        Task.detached(name: "MCP local writer shutdown consumer") {
            await consumer.value
            outcome.resolve(completed: true)
        }
        Task.detached(name: "MCP local writer shutdown deadline") {
            await MCPLocalTransportWriter.sleepIgnoringCancellation(
                nanoseconds: timeoutNanoseconds
            )
            outcome.resolve(completed: false)
        }
        let completed = await outcome.value()

        // Whatever the outcome, the descriptor is now unreachable for this
        // writer and no continuation may stay suspended.
        gate.invalidate()
        let stragglers = registry.drainQueued()
        for straggler in stragglers {
            straggler.resume(throwing: CancellationError())
        }
        return completed
    }

    /// Suspends for `nanoseconds` WITHOUT observing cancellation.
    ///
    /// `Task.sleep` on an already-cancelled task returns immediately, which turns
    /// a "retry after a short pause" loop into a CPU spin. Teardown back-pressure
    /// and the teardown deadline both run on cancelled tasks by construction, so
    /// they must not be shortened by cancellation.
    static func sleepIgnoringCancellation(nanoseconds: UInt64) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let deadline = DispatchTime.now() + .nanoseconds(Int(clamping: nanoseconds))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: deadline) {
                continuation.resume()
            }
        }
    }

    /// Writes `payload` fully through `gate`, on a non-blocking descriptor. On
    /// `EAGAIN`/`EWOULDBLOCK` it suspends briefly (async back-pressure) instead of
    /// busy-spinning or blocking a thread. `errno` is captured inside the
    /// `withUnsafeBytes` body so it cannot be reset before it is inspected.
    ///
    /// Cancellation is honoured before the first byte of the frame reaches the
    /// pipe: aborting mid-frame would leave a truncated JSON-RPC message on the
    /// bridge's stdin and corrupt the wire format for every later message.
    ///
    /// A started frame is therefore never truncated in normal operation. It is
    /// only abandoned when BOTH conditions hold: teardown has begun and the pipe
    /// stayed full for the whole grace window — i.e. the peer is gone and the
    /// framing no longer has a consumer to corrupt. Safe process exit wins over
    /// wire purity at that point, and the abandonment is reported as an error so
    /// the caller's continuation is resolved rather than left suspended.
    private static func writeAllNonBlocking(
        _ payload: Data,
        through gate: MCPLocalTransportWriterDescriptorGate,
        registry: MCPLocalTransportWriterJobRegistry,
        teardownFrameGraceNanoseconds: UInt64
    ) async throws {
        var totalWritten = 0
        // Grace is measured from the moment teardown is first OBSERVED while this
        // frame is stalled, not from the start of the write, so a healthy slow
        // consumer is never cut off.
        var teardownStallDeadline: DispatchTime?
        while totalWritten < payload.count {
            if totalWritten == 0 {
                try Task.checkCancellation()
            }
            let outcome = try gate.withDescriptor { fileDescriptor in
                payload.withUnsafeBytes { rawBuffer -> (written: ssize_t, capturedErrno: Int32) in
                    guard let base = rawBuffer.baseAddress else {
                        return (written: 0, capturedErrno: 0)
                    }
                    let remaining = rawBuffer.count - totalWritten
                    let written = Darwin.write(
                        fileDescriptor,
                        base.advanced(by: totalWritten),
                        remaining
                    )
                    return (written: written, capturedErrno: written == -1 ? errno : 0)
                }
            }
            switch outcome.written {
            case 1...:
                totalWritten += Int(outcome.written)
                // Progress resets the stall budget: a draining peer is alive.
                teardownStallDeadline = nil
            case 0:
                throw POSIXError(.EIO)
            case -1:
                switch outcome.capturedErrno {
                case EINTR:
                    continue
                case EAGAIN, EWOULDBLOCK:
                    // A cancelled writer must still be able to leave before the
                    // first byte: nothing is on the wire yet.
                    if totalWritten == 0, Task.isCancelled || registry.isTearingDown {
                        throw CancellationError()
                    }
                    // Publish the wedged state: frame started AND pipe full.
                    registry.noteInFlightStall()
                    if registry.isTearingDown {
                        let now = DispatchTime.now()
                        let deadline = teardownStallDeadline ?? now + .nanoseconds(
                            Int(clamping: teardownFrameGraceNanoseconds)
                        )
                        teardownStallDeadline = deadline
                        if now >= deadline {
                            // The peer never drained within the grace window;
                            // abandoning the frame is what keeps teardown bounded.
                            throw MCPLocalTransportWriterError.teardownAbandonedFrame
                        }
                    }
                    // Uninterruptible on purpose: `try? await Task.sleep` on an
                    // already-cancelled task returns instantly and turns this
                    // retry loop into a CPU spin.
                    await sleepIgnoringCancellation(
                        nanoseconds: backPressurePollNanoseconds
                    )
                    continue
                default:
                    throw POSIXError(POSIXErrorCode(rawValue: outcome.capturedErrno) ?? .EIO)
                }
            default:
                throw POSIXError(.EIO)
            }
        }
    }
}

/// Failures specific to the local writer's bounded teardown.
enum MCPLocalTransportWriterError: Error, Equatable {
    /// A partially written frame was abandoned because teardown had begun and the
    /// peer did not drain the pipe within the grace window.
    case teardownAbandonedFrame
    /// The descriptor was detached (teardown completed) before this write.
    case descriptorClosed
    /// The bounded writer queue rejected a request before any bytes reached the wire.
    case queueFull
}

/// Resolves a bounded wait exactly once, whichever racer wins.
///
/// The waiter is resumed by the FIRST of "consumer finished" / "deadline
/// elapsed" and never observes the loser, so a wedged consumer cannot keep the
/// waiter suspended and the late racer cannot double-resume it.
private final class MCPLocalTransportWriterDeadlineBox: Sendable {
    private struct State {
        var completed: Bool?
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let state = Mutex(State())

    /// Publishes the outcome. Only the first call resumes the waiter.
    func resolve(completed: Bool) {
        let waiter = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            guard state.completed == nil else { return nil }
            state.completed = completed
            let pending = state.waiter
            state.waiter = nil
            return pending
        }
        waiter?.resume(returning: completed)
    }

    /// Suspends until the first racer resolves the box. Returns immediately when
    /// the outcome was already published (the resolve-before-await race).
    func value() async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let resolved = state.withLock { state -> Bool? in
                if let completed = state.completed {
                    return completed
                }
                state.waiter = continuation
                return nil
            }
            if let resolved {
                continuation.resume(returning: resolved)
            }
        }
    }
}

/// Sole holder of the local bridge's stdin descriptor.
///
/// Every `write()` of the writer is issued inside `withDescriptor`, under a lock,
/// and only while the gate is still valid. `invalidate()` therefore establishes a
/// hard happens-before edge: once it returns, no write can be in progress and no
/// further write can ever start. That is what allows the owner to close the FD
/// without first joining the consumer task — the ordering constraint that made
/// teardown deadlock-prone when a wedged frame could not finish.
private final class MCPLocalTransportWriterDescriptorGate: Sendable {
    private struct State {
        var descriptor: Int32
        var isValid: Bool
    }

    private let state: Mutex<State>

    init(descriptor: Int32) {
        state = Mutex(State(descriptor: descriptor, isValid: true))
    }

    var isValid: Bool {
        state.withLock { $0.isValid }
    }

    /// Runs `body` with the descriptor while the gate is valid. Throws
    /// `descriptorClosed` once teardown detached it, so a straggling consumer
    /// fails fast instead of writing on a closed — or recycled — FD.
    func withDescriptor<T>(_ body: (Int32) -> T) throws -> T {
        try state.withLock { state -> T in
            guard state.isValid else {
                throw MCPLocalTransportWriterError.descriptorClosed
            }
            return body(state.descriptor)
        }
    }

    /// Permanently detaches the descriptor. Idempotent.
    func invalidate() {
        state.withLock { $0.isValid = false }
    }
}

/// Sole owner of the unresolved job continuations of `MCPLocalTransportWriter`.
///
/// Continuations are deliberately kept OUT of the `AsyncStream` buffer. A
/// cancelled `for await` drops buffered elements without delivering them, so a
/// continuation stored inside a `Job` would silently vanish during
/// `finish()` + `cancel()` and hang its caller forever. Holding them here keeps
/// them reachable no matter how the consumer loop ends.
///
/// The registry also tracks the job LIFECYCLE, which is what makes cancellation
/// safe on a byte stream:
/// - `queued`: registered, possibly buffered by the stream, no byte written.
///   Withdrawable, so a cancelled request never reaches the bridge.
/// - `inFlight`: claimed by the consumer, which may already have written part of
///   the frame. NOT withdrawable — truncating it would corrupt the wire format
///   for every later message.
///
/// Each transition is an exactly-once handoff: whoever receives the continuation
/// back owns resuming it, and every other site gets `nil`. A class box is
/// required because `Mutex` is non-copyable while the writer is a `Sendable`
/// value type copied between the actor and its detached consumer.
private final class MCPLocalTransportWriterJobRegistry: Sendable {
    private struct State {
        var nextID: UInt64 = 0
        /// Registered but not yet claimed by the consumer: withdrawable.
        var queued: [UInt64: CheckedContinuation<Void, Error>] = [:]
        /// Claimed by the consumer and possibly partially written: not
        /// withdrawable. Tracked so `drainQueued` can never double-resume a job
        /// the consumer still owns.
        var inFlight: Set<UInt64> = []
        /// Set once a frame that is already partially on the wire has observed at
        /// least one `EAGAIN`. Exposed so tests can synchronize on the REAL
        /// wedged state (frame started + pipe full) instead of a timing guess.
        var didStallInFlightFrame = false
        var isTearingDown = false
    }

    private let state = Mutex(State())

    var isTearingDown: Bool {
        state.withLock { $0.isTearingDown }
    }

    /// `true` once a partially written frame had to wait for pipe capacity.
    var didStallInFlightFrame: Bool {
        state.withLock { $0.didStallInFlightFrame }
    }

    /// Records that an in-flight frame is waiting for pipe capacity.
    func noteInFlightStall() {
        state.withLock { $0.didStallInFlightFrame = true }
    }

    /// Jobs claimed by the consumer and possibly partially written.
    var inFlightCount: Int {
        state.withLock { $0.inFlight.count }
    }

    /// Registered but not yet claimed: still withdrawable.
    var queuedCount: Int {
        state.withLock { $0.queued.count }
    }

    /// Takes ownership of `continuation`, returning its job id, or `nil` when
    /// teardown already started and the job could never be drained.
    func register(_ continuation: CheckedContinuation<Void, Error>) -> UInt64? {
        state.withLock { state -> UInt64? in
            guard !state.isTearingDown else { return nil }
            state.nextID &+= 1
            let id = state.nextID
            state.queued[id] = continuation
            return id
        }
    }

    /// Moves a job from `queued` to `inFlight` and hands its continuation to the
    /// consumer, or returns `nil` when the job was already withdrawn (cancelled
    /// request, terminated yield) or swept by teardown. Exactly one caller can
    /// ever receive a given continuation: a job that is already in flight is
    /// never handed out a second time.
    func claimForWrite(_ id: UInt64) -> CheckedContinuation<Void, Error>? {
        state.withLock { state -> CheckedContinuation<Void, Error>? in
            guard !state.inFlight.contains(id),
                  let continuation = state.queued.removeValue(forKey: id) else {
                return nil
            }
            state.inFlight.insert(id)
            return continuation
        }
    }

    /// Releases the in-flight marker after the consumer resumed the job.
    func completeInFlight(_ id: UInt64) {
        _ = state.withLock { $0.inFlight.remove(id) }
    }

    /// Withdraws a job that has NOT started writing, returning its continuation
    /// so the canceller can fail it. Returns `nil` once the consumer claimed it
    /// for writing, which is what keeps a partially written frame intact.
    func withdrawIfQueued(_ id: UInt64) -> CheckedContinuation<Void, Error>? {
        state.withLock { $0.queued.removeValue(forKey: id) }
    }

    /// Marks teardown so no further job is accepted.
    func beginTeardown() {
        state.withLock { $0.isTearingDown = true }
    }

    /// Claims every job still queued, for the consumer's final sweep. In-flight
    /// jobs are intentionally excluded: the consumer loop already owns their
    /// continuations and resumes them itself.
    func drainQueued() -> [CheckedContinuation<Void, Error>] {
        state.withLock { state -> [CheckedContinuation<Void, Error>] in
            state.isTearingDown = true
            let queued = Array(state.queued.values)
            state.queued.removeAll()
            return queued
        }
    }
}

/// Publishes a writer job id to its own cancellation handler.
///
/// `enqueue` only learns the job id inside the continuation body, while the
/// `onCancel` handler runs outside it and may fire BEFORE registration. The
/// ticket closes that race: a cancellation that arrives first makes `adopt`
/// return `false`, so the registering side withdraws the job itself.
private final class MCPLocalTransportWriterJobTicket: Sendable {
    private struct State {
        var id: UInt64?
        var isCancelled = false
    }

    private let state = Mutex(State())

    /// Publishes `id`, or returns `false` when cancellation already fired and the
    /// caller must withdraw the job itself.
    func adopt(_ id: UInt64) -> Bool {
        state.withLock { state -> Bool in
            guard !state.isCancelled else { return false }
            state.id = id
            return true
        }
    }

    /// Returns the job id to withdraw, exactly once, or `nil` when no id was
    /// published yet (the registering side will observe the cancellation).
    func cancel() -> UInt64? {
        state.withLock { state -> UInt64? in
            state.isCancelled = true
            let id = state.id
            state.id = nil
            return id
        }
    }
}
#endif
