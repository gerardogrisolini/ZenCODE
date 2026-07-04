//
//  ChatGPTSubscriptionWebSocketPool.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 15/06/26.
//

#if os(macOS)
import Foundation
import Synchronization

public final class ChatGPTSubscriptionWebSocketPool: Sendable {
    private struct Entry {
        let task: URLSessionWebSocketTask
        var lastUsedAt: Date
        var isBusy: Bool
    }

    private struct State {
        var entries: [String: Entry] = [:]
    }

    private let idleTTL: TimeInterval = 5 * 60
    private let state = Mutex(State())

    public init() {}

    /// Closes idle entries whose `idleTTL` has elapsed. Without this sweep,
    /// web sockets for short-lived sessions that are never re-acquired would
    /// stay open indefinitely, leaking `URLSessionWebSocketTask` instances.
    private func reapExpiredIdleEntries(now: Date = Date()) {
        let expiredTasks = state.withLock { state -> [URLSessionWebSocketTask] in
            var expired: [URLSessionWebSocketTask] = []
            for (sessionID, entry) in state.entries
            where !entry.isBusy
                && (now.timeIntervalSince(entry.lastUsedAt) >= idleTTL
                    || !Self.isReusable(entry.task)) {
                expired.append(entry.task)
                state.entries.removeValue(forKey: sessionID)
            }
            return expired
        }
        for task in expiredTasks {
            Self.close(task)
        }
    }

    func acquire(
        sessionID: String,
        request: URLRequest,
        urlSession: URLSession
    ) -> ChatGPTSubscriptionResponsesClient.WebSocketLease {
        let now = Date()
        reapExpiredIdleEntries(now: now)
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
        reapExpiredIdleEntries()
    }

    public func closeSession(sessionID: String) {
        let entry = state.withLock { state in
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
