//
//  ChatGPTSubscriptionWebSocketPool+Heartbeat.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation
import Synchronization

extension ChatGPTSubscriptionWebSocketPool {
    func startHeartbeat(
        sessionID: String,
        webSocketTask: any ChatGPTSubscriptionWebSocketTask,
        heartbeatID: UInt64
    ) {
        let heartbeatTask = makeHeartbeatTask(
            sessionID: sessionID,
            webSocketTask: webSocketTask,
            heartbeatID: heartbeatID
        )
        let didInstall = state.withLock { state -> Bool in
            guard var entry = state.entries[sessionID],
                  entry.task === webSocketTask,
                  !entry.isBusy,
                  entry.heartbeatID == heartbeatID,
                  case nil = entry.heartbeatTask else {
                return false
            }
            entry.heartbeatTask = heartbeatTask
            state.entries[sessionID] = entry
            return true
        }
        if !didInstall {
            heartbeatTask.cancel()
        }
    }

    func makeHeartbeatTask(
        sessionID: String,
        webSocketTask: any ChatGPTSubscriptionWebSocketTask,
        heartbeatID: UInt64
    ) -> Task<Void, Never> {
        let interval = heartbeatIntervalNanoseconds
        let sleep = heartbeatSleep
        return Task(name: "ChatGPT WebSocket pool background task") { [weak self] in
            await Self.runHeartbeat(
                intervalNanoseconds: interval,
                sleep: sleep,
                shouldRetire: { [weak self] in
                    guard let self else {
                        return true
                    }
                    return self.shouldRetireIdleEntry(
                        sessionID: sessionID,
                        webSocketTask: webSocketTask,
                        heartbeatID: heartbeatID
                    )
                },
                ping: {
                    try await Self.sendHeartbeatPing(to: webSocketTask)
                },
                onExpiration: { [weak self] in
                    self?.discardIdleEntry(
                        sessionID: sessionID,
                        webSocketTask: webSocketTask,
                        heartbeatID: heartbeatID
                    )
                },
                onFailure: { [weak self] _ in
                    self?.discardIdleEntry(
                        sessionID: sessionID,
                        webSocketTask: webSocketTask,
                        heartbeatID: heartbeatID
                    )
                }
            )
        }
    }

    static func runHeartbeat(
        intervalNanoseconds: UInt64,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        shouldRetire: @escaping @Sendable () -> Bool = { false },
        ping: @escaping @Sendable () async throws -> Void,
        onExpiration: @escaping @Sendable () -> Void = {},
        onFailure: @escaping @Sendable (Error) -> Void
    ) async {
        while !Task.isCancelled {
            if shouldRetire() {
                onExpiration()
                return
            }

            do {
                try await sleep(max(intervalNanoseconds, 1))
                try Task.checkCancellation()
                if shouldRetire() {
                    onExpiration()
                    return
                }
                try await ping()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                onFailure(error)
                return
            }
        }
    }

    func shouldRetireIdleEntry(
        sessionID: String,
        webSocketTask: any ChatGPTSubscriptionWebSocketTask,
        heartbeatID: UInt64
    ) -> Bool {
        state.withLock { state in
            let now = monotonicClock()
            guard let entry = state.entries[sessionID],
                  entry.task === webSocketTask,
                  !entry.isBusy,
                  entry.heartbeatID == heartbeatID else {
                return true
            }
            return !Self.isReusable(entry.task)
                || Self.hasReachedMaximumConnectionAge(
                    openedAt: entry.openedAt,
                    now: now,
                    maximumConnectionAge: maximumConnectionAge
                )
        }
    }

    static func sendHeartbeatPing(to task: any ChatGPTSubscriptionWebSocketTask) async throws {
        try await task.sendHeartbeatPing()
    }

    /// Runs before every response payload, including a reused pooled socket.
    /// Retrying only retryable connection errors avoids hiding application-level
    /// upgrade or protocol failures.
    func waitUntilReady(_ task: any ChatGPTSubscriptionWebSocketTask) async throws {
        try await Self.waitUntilReady {
            try await Self.sendReadinessPing(to: task)
        }
    }

    static func waitUntilReady(
        maximumAttempts: Int = defaultConnectionReadinessAttempts,
        retryDelayNanoseconds: UInt64 =
            defaultConnectionReadinessRetryDelayNanoseconds,
        sleep: @escaping @Sendable (UInt64) async throws -> Void = { delay in
            try await Task.sleep(nanoseconds: delay)
        },
        ping: @escaping @Sendable () async throws -> Void
    ) async throws {
        let attemptLimit = max(maximumAttempts, 1)
        var attempt = 1

        while true {
            do {
                try await ping()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                guard attempt < attemptLimit,
                      ChatGPTSubscriptionResponsesClient
                          .isRetryableTransportError(error) else {
                    throw error
                }

                let multiplier = UInt64(1) << UInt64(min(attempt - 1, 3))
                try await sleep(retryDelayNanoseconds * multiplier)
                attempt += 1
            }
        }
    }

    static func sendReadinessPing(to task: any ChatGPTSubscriptionWebSocketTask) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask(name: "ChatGPT WebSocket readiness ping") {
                // Unlike an idle heartbeat, readiness owns the connection and
                // must let timeout cancellation force-close a stuck write.
                try await task.sendPing()
            }
            group.addTask(name: "ChatGPT WebSocket readiness timeout") {
                try await Task.sleep(nanoseconds: defaultConnectionReadinessPingTimeoutNanoseconds)
                throw RemoteTransportError.timeout
            }

            defer {
                group.cancelAll()
            }
            guard let _ = try await group.next() else {
                return
            }
        }
    }

    func discardIdleEntry(
        sessionID: String,
        webSocketTask: any ChatGPTSubscriptionWebSocketTask,
        heartbeatID: UInt64
    ) {
        let entry = state.withLock { state -> Entry? in
            guard let entry = state.entries[sessionID],
                  entry.task === webSocketTask,
                  !entry.isBusy,
                  entry.heartbeatID == heartbeatID else {
                return nil
            }
            state.entries.removeValue(forKey: sessionID)
            return entry
        }
        if let entry {
            dispose(entry)
        }
    }

    /// Returns true at the exact boundary so a connection is never reused at
    /// or beyond its configured absolute lifetime.
    static func hasReachedMaximumConnectionAge(
        openedAt: ContinuousClock.Instant,
        now: ContinuousClock.Instant,
        maximumConnectionAge: Duration
    ) -> Bool {
        openedAt.duration(to: now) >= maximumConnectionAge
    }

    static func isReusable(_ task: any ChatGPTSubscriptionWebSocketTask) -> Bool {
        guard task.closeCode == nil else {
            return false
        }
        // A peer reset can lack a close frame, so lifecycle state is as
        // important as the close code when deciding whether to hand it out.
        switch task.state {
        case .completed, .canceling:
            return false
        case .running, .suspended:
            return true
        }
    }

    func dispose(_ entry: Entry) {
        entry.heartbeatTask?.cancel()
        closeWebSocketTask(entry.task)
    }
}
