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
        var isBusy: Bool
        var heartbeatTask: Task<Void, Never>?
    }

    private struct State {
        var entries: [String: Entry] = [:]
    }

    static let defaultHeartbeatIntervalNanoseconds: UInt64 = 30 * 1_000_000_000

    private let heartbeatIntervalNanoseconds: UInt64
    private let state = Mutex(State())

    public convenience init() {
        self.init(heartbeatIntervalNanoseconds: Self.defaultHeartbeatIntervalNanoseconds)
    }

    init(heartbeatIntervalNanoseconds: UInt64) {
        self.heartbeatIntervalNanoseconds = max(heartbeatIntervalNanoseconds, 1)
    }

    /// Removes sockets that the transport has already closed. Valid idle
    /// sockets intentionally have no TTL: a parent session may wait on a
    /// long-running tool or sub-agent before sending its continuation.
    private func reapInvalidIdleEntries() {
        let staleEntries = state.withLock { state -> [Entry] in
            var staleEntries: [Entry] = []
            for (sessionID, entry) in state.entries
            where !entry.isBusy && !Self.isReusable(entry.task) {
                staleEntries.append(entry)
                state.entries.removeValue(forKey: sessionID)
            }
            return staleEntries
        }
        for entry in staleEntries {
            entry.heartbeatTask?.cancel()
            Self.close(entry.task)
        }
    }

    func acquire(
        sessionID: String,
        request: URLRequest,
        urlSession: URLSession
    ) -> ChatGPTSubscriptionResponsesClient.WebSocketLease {
        reapInvalidIdleEntries()
        let result = state.withLock { state -> (
            lease: ChatGPTSubscriptionResponsesClient.WebSocketLease,
            entryToClose: Entry?
        ) in
            if var existing = state.entries[sessionID],
               !existing.isBusy,
               Self.isReusable(existing.task) {
                existing.heartbeatTask?.cancel()
                existing.heartbeatTask = nil
                existing.isBusy = true
                state.entries[sessionID] = existing
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
                isBusy: true,
                heartbeatTask: nil
            )
            return (
                ChatGPTSubscriptionResponsesClient.WebSocketLease(
                    sessionID: sessionID,
                    task: task,
                    isCached: true,
                    isReused: false
                ),
                existing
            )
        }
        if let entry = result.entryToClose {
            entry.heartbeatTask?.cancel()
            DispatchQueue.global().async {
                Self.close(entry.task)
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
                entry.heartbeatTask?.cancel()
                entry.isBusy = false
                entry.heartbeatTask = makeHeartbeatTask(
                    sessionID: lease.sessionID,
                    webSocketTask: lease.task
                )
                state.entries[lease.sessionID] = entry
                return false
            }

            if lease.isCached,
               let entry = state.entries[lease.sessionID],
               entry.task === lease.task {
                entry.heartbeatTask?.cancel()
                state.entries.removeValue(forKey: lease.sessionID)
            }
            return true
        }
        if shouldClose {
            Self.close(lease.task)
        }
        reapInvalidIdleEntries()
    }

    public func closeSession(sessionID: String) {
        let entry = state.withLock { state in
            state.entries.removeValue(forKey: sessionID)
        }
        if let entry {
            entry.heartbeatTask?.cancel()
            Self.close(entry.task)
        }
    }

    public func closeAll() {
        let entries = state.withLock { state in
            let entries = Array(state.entries.values)
            state.entries.removeAll()
            return entries
        }

        for entry in entries {
            entry.heartbeatTask?.cancel()
            Self.close(entry.task)
        }
    }

    private func makeHeartbeatTask(
        sessionID: String,
        webSocketTask: URLSessionWebSocketTask
    ) -> Task<Void, Never> {
        let interval = heartbeatIntervalNanoseconds
        return Task { [weak self] in
            await Self.runHeartbeat(
                intervalNanoseconds: interval,
                ping: {
                    try await Self.sendPing(to: webSocketTask)
                },
                onFailure: { [weak self] _ in
                    self?.discardIdleEntry(
                        sessionID: sessionID,
                        webSocketTask: webSocketTask
                    )
                }
            )
        }
    }

    static func runHeartbeat(
        intervalNanoseconds: UInt64,
        ping: @escaping @Sendable () async throws -> Void,
        onFailure: @escaping @Sendable (Error) -> Void
    ) async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(
                    nanoseconds: max(intervalNanoseconds, 1)
                )
                try Task.checkCancellation()
                try await ping()
            } catch is CancellationError {
                return
            } catch {
                onFailure(error)
                return
            }
        }
    }

    private static func sendPing(
        to task: URLSessionWebSocketTask
    ) async throws {
        try await awaitPing { completion in
            task.sendPing(pongReceiveHandler: completion)
        }
    }

    static func awaitPing(
        _ send: (@escaping @Sendable (Error?) -> Void) -> Void
    ) async throws {
        let resumed = Atomic(false)

        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            send { error in
                guard resumed.compareExchange(
                    expected: false,
                    desired: true,
                    ordering: .relaxed
                ).exchanged else {
                    return
                }

                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func discardIdleEntry(
        sessionID: String,
        webSocketTask: URLSessionWebSocketTask
    ) {
        let entry = state.withLock { state -> Entry? in
            guard let entry = state.entries[sessionID],
                  entry.task === webSocketTask,
                  !entry.isBusy else {
                return nil
            }
            state.entries.removeValue(forKey: sessionID)
            return entry
        }
        if let entry {
            entry.heartbeatTask?.cancel()
            Self.close(entry.task)
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
