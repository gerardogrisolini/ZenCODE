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
        /// Recorded once when the task is created; reuse and heartbeats never
        /// extend a connection's absolute lifetime.
        let openedAt: ContinuousClock.Instant
        var isBusy: Bool
        var activeLeaseID: UInt64?
        var heartbeatID: UInt64?
        var heartbeatTask: Task<Void, Never>?
    }

    private struct TransientEntry {
        let sessionID: String
        let task: URLSessionWebSocketTask
    }

    private struct State {
        var entries: [String: Entry] = [:]
        /// A second acquire must not replace or close an active cached task.
        /// Its short-lived task is tracked here until its matching release.
        var transientEntries: [UInt64: TransientEntry] = [:]
        private var nextToken: UInt64 = 0

        mutating func makeToken() -> UInt64 {
            nextToken &+= 1
            return nextToken
        }
    }

    private struct AcquireResult {
        let lease: ChatGPTSubscriptionResponsesClient.WebSocketLease
        let heartbeatToCancel: Task<Void, Never>?
        let entryToClose: Entry?
    }

    private struct ReleaseResult {
        var heartbeatToCancel: Task<Void, Never>?
        var entryToClose: Entry?
        var taskToClose: URLSessionWebSocketTask?
        var heartbeatIDToStart: UInt64?
    }

    static let defaultHeartbeatIntervalNanoseconds: UInt64 = 30 * 1_000_000_000

    /// The server rejects a Responses WebSocket after 60 minutes of absolute
    /// connection lifetime.
    static let serverMaximumConnectionAge: Duration = .seconds(60 * 60)

    /// Retire an idle connection before the server's 60-minute limit so the
    /// next acquire builds a fresh request with current credentials.
    static let defaultMaximumConnectionAge: Duration = .seconds(55 * 60)

    private let heartbeatIntervalNanoseconds: UInt64
    private let maximumConnectionAge: Duration
    private let monotonicClock: @Sendable () -> ContinuousClock.Instant
    private let heartbeatSleep: @Sendable (UInt64) async throws -> Void
    private let webSocketTaskFactory: @Sendable (
        URLSession,
        URLRequest
    ) -> URLSessionWebSocketTask
    private let resumeWebSocketTask: @Sendable (URLSessionWebSocketTask) -> Void
    private let closeWebSocketTask: @Sendable (URLSessionWebSocketTask) -> Void
    private let state = Mutex(State())

    public convenience init() {
        self.init(heartbeatIntervalNanoseconds: Self.defaultHeartbeatIntervalNanoseconds)
    }

    /// Internal injection points keep lifetime tests deterministic while the
    /// public pool API remains configuration-free.
    init(
        heartbeatIntervalNanoseconds: UInt64,
        maximumConnectionAge: Duration =
            ChatGPTSubscriptionWebSocketPool.defaultMaximumConnectionAge,
        monotonicClock: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock.now
        },
        heartbeatSleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        webSocketTaskFactory: @escaping @Sendable (
            URLSession,
            URLRequest
        ) -> URLSessionWebSocketTask = { urlSession, request in
            urlSession.webSocketTask(with: request)
        },
        resumeWebSocketTask: @escaping @Sendable (
            URLSessionWebSocketTask
        ) -> Void = { task in
            task.resume()
        },
        closeWebSocketTask: @escaping @Sendable (
            URLSessionWebSocketTask
        ) -> Void = { task in
            task.cancel(with: .normalClosure, reason: nil)
        }
    ) {
        self.heartbeatIntervalNanoseconds = max(heartbeatIntervalNanoseconds, 1)
        self.maximumConnectionAge = max(maximumConnectionAge, .zero)
        self.monotonicClock = monotonicClock
        self.heartbeatSleep = heartbeatSleep
        self.webSocketTaskFactory = webSocketTaskFactory
        self.resumeWebSocketTask = resumeWebSocketTask
        self.closeWebSocketTask = closeWebSocketTask
    }

    /// Idle time has no independent TTL: a session may wait on a long-running
    /// tool or sub-agent. Every socket still has a bounded absolute monotonic
    /// lifetime and is never reused once it reaches that age.
    private func reapInvalidOrExpiredIdleEntries() {
        let staleEntries = state.withLock { state -> [Entry] in
            let now = monotonicClock()
            let staleSessionIDs: [String] = state.entries.compactMap {
                sessionID,
                entry in
                guard !entry.isBusy else {
                    return nil
                }
                return !Self.isReusable(entry.task)
                    || Self.hasReachedMaximumConnectionAge(
                        openedAt: entry.openedAt,
                        now: now,
                        maximumConnectionAge: maximumConnectionAge
                    ) ? sessionID : nil
            }
            return staleSessionIDs.compactMap {
                state.entries.removeValue(forKey: $0)
            }
        }

        for entry in staleEntries {
            dispose(entry)
        }
    }

    func acquire(
        sessionID: String,
        request: URLRequest,
        urlSession: URLSession
    ) -> ChatGPTSubscriptionResponsesClient.WebSocketLease {
        reapInvalidOrExpiredIdleEntries()
        let result = state.withLock { state -> AcquireResult in
            let now = monotonicClock()
            if var existing = state.entries[sessionID] {
                if !existing.isBusy,
                   Self.isReusable(existing.task),
                   !Self.hasReachedMaximumConnectionAge(
                       openedAt: existing.openedAt,
                       now: now,
                       maximumConnectionAge: maximumConnectionAge
                   ) {
                    let leaseID = state.makeToken()
                    let heartbeatToCancel = existing.heartbeatTask
                    existing.isBusy = true
                    existing.activeLeaseID = leaseID
                    existing.heartbeatID = nil
                    existing.heartbeatTask = nil
                    state.entries[sessionID] = existing
                    return AcquireResult(
                        lease: ChatGPTSubscriptionResponsesClient.WebSocketLease(
                            sessionID: sessionID,
                            task: existing.task,
                            isCached: true,
                            isReused: true,
                            leaseID: leaseID
                        ),
                        heartbeatToCancel: heartbeatToCancel,
                        entryToClose: nil
                    )
                }

                if !existing.isBusy {
                    let entryToClose = state.entries.removeValue(forKey: sessionID)
                    let leaseID = state.makeToken()
                    let entry = makeEntry(
                        request: request,
                        urlSession: urlSession,
                        leaseID: leaseID
                    )
                    state.entries[sessionID] = entry
                    return AcquireResult(
                        lease: ChatGPTSubscriptionResponsesClient.WebSocketLease(
                            sessionID: sessionID,
                            task: entry.task,
                            isCached: true,
                            isReused: false,
                            leaseID: leaseID
                        ),
                        heartbeatToCancel: nil,
                        entryToClose: entryToClose
                    )
                }

                // Do not evict an active response, even if its connection has
                // crossed the lifetime threshold. It will retire on release.
                let leaseID = state.makeToken()
                let task = makeWebSocketTask(request: request, urlSession: urlSession)
                state.transientEntries[leaseID] = TransientEntry(
                    sessionID: sessionID,
                    task: task
                )
                return AcquireResult(
                    lease: ChatGPTSubscriptionResponsesClient.WebSocketLease(
                        sessionID: sessionID,
                        task: task,
                        isCached: false,
                        isReused: false,
                        leaseID: leaseID
                    ),
                    heartbeatToCancel: nil,
                    entryToClose: nil
                )
            }

            let leaseID = state.makeToken()
            let entry = makeEntry(
                request: request,
                urlSession: urlSession,
                leaseID: leaseID
            )
            state.entries[sessionID] = entry
            return AcquireResult(
                lease: ChatGPTSubscriptionResponsesClient.WebSocketLease(
                    sessionID: sessionID,
                    task: entry.task,
                    isCached: true,
                    isReused: false,
                    leaseID: leaseID
                ),
                heartbeatToCancel: nil,
                entryToClose: nil
            )
        }

        result.heartbeatToCancel?.cancel()
        if let entryToClose = result.entryToClose {
            dispose(entryToClose)
        }
        return result.lease
    }

    func release(
        _ lease: ChatGPTSubscriptionResponsesClient.WebSocketLease,
        keepAlive: Bool
    ) {
        let result = state.withLock { state -> ReleaseResult in
            let now = monotonicClock()
            guard lease.isCached else {
                guard let transient = state.transientEntries[lease.leaseID],
                      transient.sessionID == lease.sessionID,
                      transient.task === lease.task else {
                    return ReleaseResult()
                }
                state.transientEntries.removeValue(forKey: lease.leaseID)
                return ReleaseResult(taskToClose: transient.task)
            }

            guard var entry = state.entries[lease.sessionID],
                  entry.task === lease.task,
                  entry.isBusy,
                  entry.activeLeaseID == lease.leaseID else {
                return ReleaseResult()
            }

            if keepAlive,
               Self.isReusable(entry.task),
               !Self.hasReachedMaximumConnectionAge(
                   openedAt: entry.openedAt,
                   now: now,
                   maximumConnectionAge: maximumConnectionAge
               ) {
                let heartbeatID = state.makeToken()
                let heartbeatToCancel = entry.heartbeatTask
                entry.isBusy = false
                entry.activeLeaseID = nil
                entry.heartbeatID = heartbeatID
                entry.heartbeatTask = nil
                state.entries[lease.sessionID] = entry
                return ReleaseResult(
                    heartbeatToCancel: heartbeatToCancel,
                    heartbeatIDToStart: heartbeatID
                )
            }

            state.entries.removeValue(forKey: lease.sessionID)
            return ReleaseResult(entryToClose: entry)
        }

        result.heartbeatToCancel?.cancel()
        if let entryToClose = result.entryToClose {
            dispose(entryToClose)
        }
        if let taskToClose = result.taskToClose {
            close(taskToClose)
        }
        if let heartbeatID = result.heartbeatIDToStart {
            startHeartbeat(
                sessionID: lease.sessionID,
                webSocketTask: lease.task,
                heartbeatID: heartbeatID
            )
        }
        reapInvalidOrExpiredIdleEntries()
    }

    public func closeSession(sessionID: String) {
        let retired = state.withLock { state -> (Entry?, [TransientEntry]) in
            let entry = state.entries.removeValue(forKey: sessionID)
            let transientIDs = state.transientEntries.compactMap { token, entry in
                entry.sessionID == sessionID ? token : nil
            }
            let transientEntries = transientIDs.compactMap {
                state.transientEntries.removeValue(forKey: $0)
            }
            return (entry, transientEntries)
        }

        if let entry = retired.0 {
            dispose(entry)
        }
        for entry in retired.1 {
            close(entry.task)
        }
    }

    public func closeAll() {
        let retired = state.withLock { state -> ([Entry], [TransientEntry]) in
            let entries = Array(state.entries.values)
            let transientEntries = Array(state.transientEntries.values)
            state.entries.removeAll()
            state.transientEntries.removeAll()
            return (entries, transientEntries)
        }

        for entry in retired.0 {
            dispose(entry)
        }
        for entry in retired.1 {
            close(entry.task)
        }
    }

    private func makeEntry(
        request: URLRequest,
        urlSession: URLSession,
        leaseID: UInt64
    ) -> Entry {
        let openedAt = monotonicClock()
        let task = makeWebSocketTask(request: request, urlSession: urlSession)
        return Entry(
            task: task,
            openedAt: openedAt,
            isBusy: true,
            activeLeaseID: leaseID,
            heartbeatID: nil,
            heartbeatTask: nil
        )
    }

    private func makeWebSocketTask(
        request: URLRequest,
        urlSession: URLSession
    ) -> URLSessionWebSocketTask {
        let task = webSocketTaskFactory(urlSession, request)
        resumeWebSocketTask(task)
        return task
    }

    private func startHeartbeat(
        sessionID: String,
        webSocketTask: URLSessionWebSocketTask,
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

    private func makeHeartbeatTask(
        sessionID: String,
        webSocketTask: URLSessionWebSocketTask,
        heartbeatID: UInt64
    ) -> Task<Void, Never> {
        let interval = heartbeatIntervalNanoseconds
        let sleep = heartbeatSleep
        return Task { [weak self] in
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
                    try await Self.sendPing(to: webSocketTask)
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
                onFailure(error)
                return
            }
        }
    }

    private func shouldRetireIdleEntry(
        sessionID: String,
        webSocketTask: URLSessionWebSocketTask,
        heartbeatID: UInt64
    ) -> Bool {
        return state.withLock { state in
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
        let state = PingContinuationState()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                state.set(continuation)
                if Task.isCancelled {
                    state.resume(throwing: CancellationError())
                    return
                }
                send { error in
                    if let error {
                        state.resume(throwing: error)
                    } else {
                        state.resume()
                    }
                }
            }
        } onCancel: {
            state.resume(throwing: CancellationError())
        }
    }

    private func discardIdleEntry(
        sessionID: String,
        webSocketTask: URLSessionWebSocketTask,
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

    private static func isReusable(
        _ task: URLSessionWebSocketTask
    ) -> Bool {
        task.closeCode == .invalid
    }

    private func dispose(_ entry: Entry) {
        entry.heartbeatTask?.cancel()
        close(entry.task)
    }

    private func close(
        _ task: URLSessionWebSocketTask
    ) {
        closeWebSocketTask(task)
    }
}

private final class PingContinuationState: @unchecked Sendable {
    private let resumed = Atomic(false)
    private let continuation = Mutex<CheckedContinuation<Void, Error>?>(nil)

    func set(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume() {
        resume(with: .success(()))
    }

    func resume(throwing error: Error) {
        resume(with: .failure(error))
    }

    private func resume(with result: Result<Void, Error>) {
        let continuation = continuation.withLock { $0 }
        guard let continuation,
              resumed.compareExchange(
                  expected: false,
                  desired: true,
                  ordering: .relaxed
              ).exchanged else {
            return
        }
        self.continuation.withLock { $0 = nil }
        switch result {
        case .success:
            continuation.resume()
        case let .failure(error):
            continuation.resume(throwing: error)
        }
    }
}
#endif
