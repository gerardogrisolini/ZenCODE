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
        if !events.isEmpty {
            return events.removeFirst()
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

    private func cancelWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else {
            return
        }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }
}
