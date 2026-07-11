//
//  TerminalChatEventQueue.swift
//  ZenCODE
//

import Foundation

actor TerminalChatEventQueue {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<TerminalChatRuntimeEvent?, Never>
    }

    private var events: [TerminalChatRuntimeEvent] = []
    // Head index into `events` so dequeuing is amortized O(1) instead of the
    // O(n) shift performed by `Array.removeFirst()`. The backing storage is
    // compacted once the consumed prefix grows past a threshold.
    private var eventsHead = 0
    private var waiters: [Waiter] = []

    func send(_ event: TerminalChatRuntimeEvent) {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: event)
            return
        }
        events.append(event)
    }

    /// Returns the next event, or `nil` when the waiting task is cancelled.
    func next() async -> TerminalChatRuntimeEvent? {
        if let event = dequeueBufferedEvent() {
            return event
        }

        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: nil)
                    return
                }
                waiters.append(Waiter(id: waiterID, continuation: continuation))
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(id: waiterID)
            }
        }
    }

    private func dequeueBufferedEvent() -> TerminalChatRuntimeEvent? {
        guard eventsHead < events.count else {
            // Buffer fully drained: reset so it can be reused without growth.
            if !events.isEmpty {
                events.removeAll(keepingCapacity: true)
            }
            eventsHead = 0
            return nil
        }
        let event = events[eventsHead]
        eventsHead += 1
        // Compact the consumed prefix once it dominates the buffer to keep
        // memory bounded during long streaming bursts.
        if eventsHead > 256, eventsHead * 2 >= events.count {
            events.removeFirst(eventsHead)
            eventsHead = 0
        }
        return event
    }

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }
}
