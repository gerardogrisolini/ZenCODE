//
//  TerminalChatEventQueue.swift
//  ZenCODE
//

import Foundation

/// Thread-safe FIFO ingress for the terminal runtime loop.
///
/// `send(_:)` is synchronous so events produced by the single terminal input
/// task retain their physical order instead of being forwarded through
/// independently scheduled tasks. `AsyncStream.Continuation` is safe to yield
/// from concurrent producers and the runtime loop remains the sole consumer.
final class TerminalChatEventQueue: Sendable {
    let events: AsyncStream<TerminalChatRuntimeEvent>
    private let continuation: AsyncStream<TerminalChatRuntimeEvent>.Continuation

    init() {
        let stream = AsyncStream<TerminalChatRuntimeEvent>.makeStream(
            bufferingPolicy: .unbounded
        )
        self.events = stream.stream
        self.continuation = stream.continuation
    }

    func send(_ event: TerminalChatRuntimeEvent) {
        continuation.yield(event)
    }

    deinit {
        continuation.finish()
    }
}
