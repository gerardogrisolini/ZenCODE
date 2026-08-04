//
//  TerminalChatEventQueue.swift
//  ZenCODE
//

import Foundation
import Synchronization

/// Thread-safe FIFO ingress for the terminal runtime loop.
///
/// `send(_:)` is synchronous so events produced by the single terminal input
/// task retain their physical order instead of being forwarded through
/// independently scheduled tasks. `AsyncStream.Continuation` is safe to yield
/// from concurrent producers and the runtime loop remains the sole consumer.
///
/// Lifecycle: the runtime loop calls ``finish()`` when it exits, which
/// terminates the stream and makes every later `send(_:)` a no-op. Producers
/// that outlive the loop for a moment (the Telegram forwarder, remote
/// transcription work that is being cancelled, the panel task during teardown)
/// can therefore keep calling `send(_:)` safely without their events
/// accumulating in a buffer nobody drains.
///
/// Buffering: events are unbounded so their physical order is never dropped.
final class TerminalChatEventQueue: Sendable {
    private struct State {
        var isFinished = false
    }

    let events: AsyncStream<TerminalChatRuntimeEvent>
    private let continuation: AsyncStream<TerminalChatRuntimeEvent>.Continuation
    private let state = Mutex(State())

    init() {
        let stream = AsyncStream<TerminalChatRuntimeEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream.stream
        self.continuation = stream.continuation
    }

    /// Enqueues an event unless the queue has been finished.
    /// Returns whether the event was accepted.
    @discardableResult
    func send(_ event: TerminalChatRuntimeEvent) -> Bool {
        let shouldSend = state.withLock { state -> Bool in
            guard !state.isFinished else {
                return false
            }
            return true
        }
        guard shouldSend else {
            return false
        }
        continuation.yield(event)
        return true
    }

    /// Terminates the stream. Idempotent, and safe to call while producers are
    /// still running: later `send(_:)` calls are dropped instead of trapping or
    /// buffering into a stream nobody consumes.
    func finish() {
        let shouldFinish = state.withLock { state -> Bool in
            guard !state.isFinished else {
                return false
            }
            state.isFinished = true
            return true
        }
        guard shouldFinish else {
            return
        }
        continuation.finish()
    }

    var isFinished: Bool {
        state.withLock { $0.isFinished }
    }

    deinit {
        continuation.finish()
    }
}
