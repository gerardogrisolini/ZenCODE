//
//  ChatGPTSubscriptionWebSocketPool.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 15/06/26.
//
#if os(macOS)
import Foundation
#if canImport(os)
import os
#endif

public final class ChatGPTSubscriptionWebSocketPool: Sendable {
    private struct Entry {
        let task: URLSessionWebSocketTask
        var lastUsedAt: Date
        var isBusy: Bool
    }

    private struct State {
        var entries: [String: Entry] = [:]
        var sseFallbackSessionIDs: Set<String> = []
    }

    private let idleTTL: TimeInterval = 5 * 60
    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    public func isFallbackToSSEActive(sessionID: String) -> Bool {
        state.withLock { state in
            state.sseFallbackSessionIDs.contains(sessionID)
        }
    }

    public func activateSSEFallback(sessionID: String) {
        let entry = state.withLock { state in
            state.sseFallbackSessionIDs.insert(sessionID)
            return state.entries.removeValue(forKey: sessionID)
        }
        if let entry {
            Self.close(entry.task)
        }
    }

    func acquire(
        sessionID: String,
        request: URLRequest,
        urlSession: URLSession
    ) -> ChatGPTSubscriptionResponsesClient.WebSocketLease {
        let now = Date()
        let result = state.withLock { state -> (
            lease: ChatGPTSubscriptionResponsesClient.WebSocketLease,
            taskToClose: URLSessionWebSocketTask?
        ) in
            if let existing = state.entries[sessionID],
               !existing.isBusy,
               Self.isReusable(existing.task),
               now.timeIntervalSince(existing.lastUsedAt) < idleTTL {
                var updated = existing
                updated.lastUsedAt = now
                updated.isBusy = true
                state.entries[sessionID] = updated
                return (
                    ChatGPTSubscriptionResponsesClient.WebSocketLease(
                        sessionID: sessionID,
                        task: existing.task,
                        isCached: true,
                        isReused: true
                    ),
                    nil
                )
            }

            let existing = state.entries.removeValue(forKey: sessionID)
            let task = urlSession.webSocketTask(with: request)
            task.resume()
            state.entries[sessionID] = Entry(
                task: task,
                lastUsedAt: now,
                isBusy: true
            )
            return (
                ChatGPTSubscriptionResponsesClient.WebSocketLease(
                    sessionID: sessionID,
                    task: task,
                    isCached: true,
                    isReused: false
                ),
                existing?.task
            )
        }
        if let task = result.taskToClose {
            DispatchQueue.global().async {
                Self.close(task)
            }
        }
        return result.lease
    }

    func release(
        _ lease: ChatGPTSubscriptionResponsesClient.WebSocketLease,
        keepAlive: Bool
    ) {
        let shouldClose = state.withLock { state in
            if keepAlive,
               lease.isCached,
               var entry = state.entries[lease.sessionID],
               entry.task === lease.task,
               Self.isReusable(entry.task) {
                entry.lastUsedAt = Date()
                entry.isBusy = false
                state.entries[lease.sessionID] = entry
                return false
            }

            if lease.isCached,
               let entry = state.entries[lease.sessionID],
               entry.task === lease.task {
                state.entries.removeValue(forKey: lease.sessionID)
            }
            return true
        }
        if shouldClose {
            Self.close(lease.task)
        }
    }

    public func closeSession(sessionID: String) {
        let entry = state.withLock { state in
            state.sseFallbackSessionIDs.remove(sessionID)
            return state.entries.removeValue(forKey: sessionID)
        }
        if let entry {
            Self.close(entry.task)
        }
    }

    public func closeAll() {
        let openTasks = state.withLock { state in
            let openTasks = state.entries.values.map(\.task)
            state.entries.removeAll()
            state.sseFallbackSessionIDs.removeAll()
            return openTasks
        }

        for task in openTasks {
            Self.close(task)
        }
    }

    private static func isReusable(
        _ task: URLSessionWebSocketTask
    ) -> Bool {
        task.closeCode == .invalid
    }

    private static func close(
        _ task: URLSessionWebSocketTask
    ) {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

#endif
