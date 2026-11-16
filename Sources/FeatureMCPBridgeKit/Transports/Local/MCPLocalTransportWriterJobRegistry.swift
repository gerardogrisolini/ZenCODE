//
//  MCPLocalTransportWriterJobRegistry.swift
//  ZenCODE
//
//  Sole owner of the unresolved job continuations of the local MCP transport
//  writer, tracking each job through its queued and in-flight lifecycle.
//

import Synchronization

#if os(macOS)
import Darwin
import Dispatch
import Foundation

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
final class MCPLocalTransportWriterJobRegistry: Sendable {
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
#endif
