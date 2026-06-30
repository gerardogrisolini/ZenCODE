//
//  TerminalChatEventQueue.swift
//  ZenCODE
//

import Foundation

actor TerminalChatEventQueue {
    private var events: [TerminalChatRuntimeEvent] = []
    private var waiters: [CheckedContinuation<TerminalChatRuntimeEvent, Never>] = []

    func send(_ event: TerminalChatRuntimeEvent) {
        if !waiters.isEmpty {
            let waiter = waiters.removeFirst()
            waiter.resume(returning: event)
            return
        }
        events.append(event)
    }

    func next() async -> TerminalChatRuntimeEvent {
        if !events.isEmpty {
            return events.removeFirst()
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
