//
//  TerminalChatEventQueue.swift
//  ZenCODE
//

import Foundation
import Synchronization

/// Thread-safe, bounded FIFO ingress for the terminal runtime loop.
///
/// `offer(_:)` never grows the buffer beyond ``capacity``. Shared-chat rendering
/// is recoverable and may be evicted oldest-first; an auto-trigger which cannot
/// fit is returned to its producer as ``OfferResult/rejectedFull`` so that
/// producer can decline it and the Core can requeue the batch. All other events
/// carry terminal work with no second copy and use ``sendWithBackpressure(_:)``:
/// their finite producer suspends until the single consumer makes room, instead
/// of silently dropping work or accumulating another unbounded side queue.
///
/// Lifecycle: the runtime loop calls ``finish()`` when it exits. Later offers
/// fail with ``OfferResult/finished`` and waiting producers wake on their next
/// cancellation/finish check, so teardown never retains events nobody drains.
final class TerminalChatEventQueue: Sendable {
    /// Default upper bound for unconsumed runtime events. It is comfortably
    /// above a healthy backlog but still makes a stalled TUI memory-bounded.
    static let defaultCapacity = 256

    /// Result of one non-blocking insertion attempt.
    enum OfferResult: Sendable, Equatable {
        /// The event was appended or handed to an already suspended reader.
        case accepted
        /// The hard capacity was occupied by non-evictable terminal work.
        /// Callers of critical ingress must retry with backpressure; shared-chat
        /// auto-trigger producers decline their trigger so Core can requeue it.
        case rejectedFull
        /// The runtime loop has exited and will not consume another event.
        case finished
    }

    private let storage: Storage
    let events: AsyncStream<TerminalChatRuntimeEvent>

    var capacity: Int { storage.capacity }

    init(capacity: Int = TerminalChatEventQueue.defaultCapacity) {
        let storage = Storage(capacity: max(1, capacity))
        self.storage = storage
        // Storage owns the buffer rather than AsyncStream so admission can apply
        // the explicit overflow policy before yielding an event.
        events = AsyncStream(
            unfolding: { await storage.next() },
            onCancel: { storage.finish() }
        )
    }

    /// Attempts a non-blocking insertion without exceeding ``capacity``.
    ///
    /// Use this for recoverable shared-chat events. Critical terminal ingress
    /// should use ``sendWithBackpressure(_:)`` instead, which preserves the
    /// event by waiting for space rather than observing `rejectedFull`.
    @discardableResult
    func offer(_ event: TerminalChatRuntimeEvent) -> OfferResult {
        storage.offer(event)
    }

    /// Compatibility shorthand for fire-and-forget, recoverable producers.
    /// Returns `false` both for a full queue and after teardown; callers that
    /// need to distinguish those states should use ``offer(_:)``.
    @discardableResult
    func send(_ event: TerminalChatRuntimeEvent) -> Bool {
        offer(event) == .accepted
    }

    /// Preserves critical terminal work using producer-side backpressure.
    ///
    /// This method intentionally parks no continuations in the queue: the
    /// bounded producers (panel reader, one Telegram forwarder, at most three
    /// voice tasks, and one generation lifecycle task) wait in their own task.
    /// Therefore a flood cannot turn the waiter list itself into another
    /// unbounded queue. Cancellation and teardown explicitly return `false`.
    @discardableResult
    func sendWithBackpressure(_ event: TerminalChatRuntimeEvent) async -> Bool {
        while !Task.isCancelled {
            switch offer(event) {
            case .accepted:
                return true
            case .finished:
                return false
            case .rejectedFull:
                // A short cooperative pause supplies backpressure without a
                // second heap queue of producer continuations. The only callers
                // are bounded ingress tasks documented above.
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        return false
    }

    /// Terminates the stream. Idempotent and safe while producers are stopping.
    func finish() {
        storage.finish()
    }

    var isFinished: Bool {
        storage.isFinished
    }

    /// Number of recoverable render events evicted to make room. Diagnostics and
    /// saturation tests only; no terminal input/lifecycle event contributes.
    var evictedEventCount: Int {
        storage.evictedEventCount
    }

    /// Number of non-blocking offers refused because the hard bound was full.
    var rejectedEventCount: Int {
        storage.rejectedEventCount
    }

    /// Unconsumed events currently buffered. Always `<= capacity`.
    var bufferedEventCount: Int {
        storage.bufferedEventCount
    }

    deinit {
        storage.finish()
    }
}

/// Bounded buffer plus at most one suspended reader.
///
/// Kept separate from ``TerminalChatEventQueue`` so the queue can hand the
/// buffer to its `AsyncStream` during initialization while retaining admission
/// control.
private final class Storage: Sendable {
    private enum ReadOutcome {
        case event(TerminalChatRuntimeEvent)
        case finished
        case wait
    }

    private enum OfferOutcome {
        case result(TerminalChatEventQueue.OfferResult)
        case handOff(CheckedContinuation<TerminalChatRuntimeEvent?, Never>)
    }

    private struct State {
        var isFinished = false
        var buffer: [TerminalChatRuntimeEvent] = []
        var waiter: CheckedContinuation<TerminalChatRuntimeEvent?, Never>?
        var evictedEventCount = 0
        var rejectedEventCount = 0
    }

    let capacity: Int
    private let state = Mutex(State())

    init(capacity: Int) {
        self.capacity = capacity
    }

    func offer(_ event: TerminalChatRuntimeEvent) -> TerminalChatEventQueue.OfferResult {
        let outcome = state.withLock { state -> OfferOutcome in
            guard !state.isFinished else {
                return .result(.finished)
            }
            // A waiting reader implies an empty buffer, so direct handoff keeps
            // FIFO order and does not consume bounded storage.
            if let waiter = state.waiter {
                state.waiter = nil
                return .handOff(waiter)
            }
            if state.buffer.count == capacity {
                guard let renderIndex = Self.oldestEvictableRenderIndex(in: state.buffer) else {
                    state.rejectedEventCount += 1
                    return .result(.rejectedFull)
                }
                state.buffer.remove(at: renderIndex)
                state.evictedEventCount += 1
            }
            state.buffer.append(event)
            return .result(.accepted)
        }
        switch outcome {
        case let .result(result):
            return result
        case let .handOff(continuation):
            // Resume outside the lock: the reader can continue immediately.
            continuation.resume(returning: event)
            return .accepted
        }
    }

    func next() async -> TerminalChatRuntimeEvent? {
        let immediate = state.withLock { state -> ReadOutcome in
            if !state.buffer.isEmpty {
                return .event(state.buffer.removeFirst())
            }
            return state.isFinished ? .finished : .wait
        }
        switch immediate {
        case let .event(event):
            return event
        case .finished:
            return nil
        case .wait:
            break
        }
        return await withCheckedContinuation { continuation in
            let outcome = state.withLock { state -> ReadOutcome in
                // Re-check under the lock: a producer could have run between the
                // initial empty observation and continuation registration.
                if !state.buffer.isEmpty {
                    return .event(state.buffer.removeFirst())
                }
                if state.isFinished {
                    return .finished
                }
                state.waiter = continuation
                return .wait
            }
            switch outcome {
            case let .event(event):
                continuation.resume(returning: event)
            case .finished:
                continuation.resume(returning: nil)
            case .wait:
                break
            }
        }
    }

    func finish() {
        let waiter = state.withLock { state -> CheckedContinuation<TerminalChatRuntimeEvent?, Never>? in
            guard !state.isFinished else {
                return nil
            }
            state.isFinished = true
            let waiter = state.waiter
            state.waiter = nil
            return waiter
        }
        // Existing buffered events remain readable before termination.
        waiter?.resume(returning: nil)
    }

    var isFinished: Bool {
        state.withLock { $0.isFinished }
    }

    var evictedEventCount: Int {
        state.withLock { $0.evictedEventCount }
    }

    var rejectedEventCount: Int {
        state.withLock { $0.rejectedEventCount }
    }

    var bufferedEventCount: Int {
        state.withLock { $0.buffer.count }
    }

    /// Only participant-roster changes may be removed under overflow.
    /// Shared-chat messages are never evicted: the blue box must reach every
    /// active observer within the transcript bound, so their producer applies
    /// backpressure (``TerminalChatEventQueue/sendWithBackpressure(_:)``)
    /// instead of relying on eviction. Auto-triggers are also never evicted.
    private static func oldestEvictableRenderIndex(
        in buffer: [TerminalChatRuntimeEvent]
    ) -> Int? {
        buffer.firstIndex { event in
            switch event {
            case .sharedChatParticipantsChanged:
                true
            case .input,
                 .generationCompleted,
                 .startNextQueuedPrompt,
                 .telegramMessage,
                 .telegramRouteInvalidated,
                 .voicePromptCompleted,
                 .sharedChatMessages,
                 .sharedChatObservationEnded,
                 .sharedChatReaderCollapsed,
                 .sharedChatAutoTrigger:
                false
            }
        }
    }
}
