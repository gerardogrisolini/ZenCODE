//
//  ChatGPTSubscriptionWebSocketPool.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation
import Synchronization

/// Keeps the ChatGPT Responses WebSocket associated with a session between
/// rounds and owns lifecycle tracking for session-scoped HTTP fallback streams.
/// All platforms use the same NIO adapter; no OS-specific socket path
/// participates in acquisition, reuse, heartbeats, fencing, or fallback I/O.
public final class ChatGPTSubscriptionWebSocketPool: Sendable {
    private struct Entry {
        let task: any ChatGPTSubscriptionWebSocketTask
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
        let task: any ChatGPTSubscriptionWebSocketTask
    }

    struct HTTPStreamLease {
        let token: UInt64
        let response: RemoteHTTPStreamingResponse
    }

    private struct ActiveHTTPStream {
        let scopeID: String
        let body: RemoteHTTPBody
    }

    private struct PendingHTTPStream {
        let scopeID: String
        let task: Task<RemoteHTTPStreamingResponse, Error>
    }

    private struct State {
        var entries: [String: Entry] = [:]
        /// A second acquire must not replace or close an active cached task.
        /// Its short-lived task is tracked here until its matching release.
        var transientEntries: [UInt64: TransientEntry] = [:]
        /// Once a logical agent session exhausts or is rejected by the
        /// WebSocket backend, keep all later transport IDs for that session on
        /// HTTP instead of probing the same failing route again.
        var httpFallbackScopeIDs: Set<String> = []
        /// A closed incarnation is fenced permanently; its generation-qualified
        /// scope ID is never reused by a later logical session incarnation.
        var closedHTTPFallbackScopeIDs: Set<String> = []
        var pendingHTTPStreams: [UInt64: PendingHTTPStream] = [:]
        var activeHTTPStreams: [UInt64: ActiveHTTPStream] = [:]
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

    enum ScopedWebSocketAcquireResult {
        case acquired(ChatGPTSubscriptionResponsesClient.WebSocketLease)
        case useHTTPFallback
        case closed
    }

    private enum AcquireDecision {
        case acquired(AcquireResult)
        case useHTTPFallback
        case closed
    }

    private struct ReleaseResult {
        var heartbeatToCancel: Task<Void, Never>?
        var entryToClose: Entry?
        var taskToClose: (any ChatGPTSubscriptionWebSocketTask)?
        var heartbeatIDToStart: UInt64?
    }

    static let defaultHeartbeatIntervalNanoseconds: UInt64 = 30 * 1_000_000_000

    /// A newly started WebSocket can report a transient connection failure if
    /// the first application frame races the HTTP upgrade. A control ping makes
    /// the readiness boundary explicit before a Responses payload is committed.
    static let defaultConnectionReadinessAttempts = 3
    static let defaultConnectionReadinessRetryDelayNanoseconds: UInt64 =
        100_000_000
    static let defaultConnectionReadinessPingTimeoutNanoseconds: UInt64 =
        10 * 1_000_000_000

    /// The server rejects a Responses WebSocket after 60 minutes of absolute
    /// connection lifetime.
    static let serverMaximumConnectionAge: Duration = .seconds(60 * 60)

    /// Retire an idle connection before the server's 60-minute limit so the
    /// next acquire builds a fresh upgrade request with current credentials.
    static let defaultMaximumConnectionAge: Duration = .seconds(55 * 60)

    private let heartbeatIntervalNanoseconds: UInt64
    private let maximumConnectionAge: Duration
    private let monotonicClock: @Sendable () -> ContinuousClock.Instant
    private let heartbeatSleep: @Sendable (UInt64) async throws -> Void
    private let webSocketTaskFactory: @Sendable (
        RemoteWebSocketRequest
    ) -> any ChatGPTSubscriptionWebSocketTask
    private let closeWebSocketTask: @Sendable (
        any ChatGPTSubscriptionWebSocketTask
    ) -> Void
    private let httpStreamOpener: @Sendable (
        RemoteHTTPStreamingRequest
    ) async throws -> RemoteHTTPStreamingResponse
    /// Non-nil only when this pool constructed the NIO transport itself. An
    /// injected transport remains owned by its embedding composition root.
    private let ownedTransport: RemoteTransportCore?
    private let state = Mutex(State())

    public convenience init() {
        self.init(
            transport: nil,
            heartbeatIntervalNanoseconds: Self.defaultHeartbeatIntervalNanoseconds
        )
    }

    /// Internal injection points keep lifetime, fencing, and retry tests fully
    /// deterministic while production always constructs the NIO adapter.
    init(
        transport: RemoteTransportCore? = nil,
        heartbeatIntervalNanoseconds: UInt64,
        maximumConnectionAge: Duration =
            ChatGPTSubscriptionWebSocketPool.defaultMaximumConnectionAge,
        monotonicClock: @escaping @Sendable () -> ContinuousClock.Instant = {
            ContinuousClock.now
        },
        heartbeatSleep: @escaping @Sendable (UInt64) async throws -> Void = {
            try await Task.sleep(nanoseconds: $0)
        },
        webSocketTaskFactory: (@Sendable (
            RemoteWebSocketRequest
        ) -> any ChatGPTSubscriptionWebSocketTask)? = nil,
        closeWebSocketTask: @escaping @Sendable (
            any ChatGPTSubscriptionWebSocketTask
        ) -> Void = { task in
            task.cancel(
                with: ChatGPTSubscriptionWebSocketCloseCode.normalClosure,
                reason: nil
            )
        }
    ) {
        let resolvedTransport = transport ?? RemoteTransportCore()
        self.heartbeatIntervalNanoseconds = max(heartbeatIntervalNanoseconds, 1)
        self.maximumConnectionAge = max(maximumConnectionAge, .zero)
        self.monotonicClock = monotonicClock
        self.heartbeatSleep = heartbeatSleep
        ownedTransport = transport == nil ? resolvedTransport : nil
        self.webSocketTaskFactory = webSocketTaskFactory ?? { request in
            ChatGPTSubscriptionNIOWebSocketTask(
                transport: resolvedTransport,
                request: request
            )
        }
        self.closeWebSocketTask = closeWebSocketTask
        self.httpStreamOpener = { request in
            try await resolvedTransport.openHTTPStream(request)
        }
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
        request: RemoteWebSocketRequest
    ) -> ChatGPTSubscriptionResponsesClient.WebSocketLease {
        guard case let .acquired(lease) = acquire(
            sessionID: sessionID,
            request: request,
            fallbackScopeID: nil
        ) else {
            preconditionFailure("An unscoped WebSocket acquire cannot be rerouted")
        }
        return lease
    }

    func acquire(
        sessionID: String,
        request: RemoteWebSocketRequest,
        fallbackScopeID: String
    ) -> ScopedWebSocketAcquireResult {
        acquire(
            sessionID: sessionID,
            request: request,
            fallbackScopeID: Optional(fallbackScopeID)
        )
    }

    private func acquire(
        sessionID: String,
        request: RemoteWebSocketRequest,
        fallbackScopeID: String?
    ) -> ScopedWebSocketAcquireResult {
        reapInvalidOrExpiredIdleEntries()
        let decision = state.withLock { state -> AcquireDecision in
            if let fallbackScopeID {
                if state.closedHTTPFallbackScopeIDs.contains(fallbackScopeID) {
                    return .closed
                }
                if state.httpFallbackScopeIDs.contains(fallbackScopeID) {
                    return .useHTTPFallback
                }
            }

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
                    return .acquired(AcquireResult(
                        lease: ChatGPTSubscriptionResponsesClient.WebSocketLease(
                            sessionID: sessionID,
                            task: existing.task,
                            isCached: true,
                            isReused: true,
                            leaseID: leaseID
                        ),
                        heartbeatToCancel: heartbeatToCancel,
                        entryToClose: nil
                    ))
                }

                if !existing.isBusy {
                    let entryToClose = state.entries.removeValue(forKey: sessionID)
                    let leaseID = state.makeToken()
                    let entry = makeEntry(request: request, leaseID: leaseID)
                    state.entries[sessionID] = entry
                    return .acquired(AcquireResult(
                        lease: ChatGPTSubscriptionResponsesClient.WebSocketLease(
                            sessionID: sessionID,
                            task: entry.task,
                            isCached: true,
                            isReused: false,
                            leaseID: leaseID
                        ),
                        heartbeatToCancel: nil,
                        entryToClose: entryToClose
                    ))
                }

                // Do not evict an active response, even if its connection has
                // crossed the lifetime threshold. It retires on its own release.
                let leaseID = state.makeToken()
                let task = makeWebSocketTask(request: request)
                state.transientEntries[leaseID] = TransientEntry(
                    sessionID: sessionID,
                    task: task
                )
                return .acquired(AcquireResult(
                    lease: ChatGPTSubscriptionResponsesClient.WebSocketLease(
                        sessionID: sessionID,
                        task: task,
                        isCached: false,
                        isReused: false,
                        leaseID: leaseID
                    ),
                    heartbeatToCancel: nil,
                    entryToClose: nil
                ))
            }

            let leaseID = state.makeToken()
            let entry = makeEntry(request: request, leaseID: leaseID)
            state.entries[sessionID] = entry
            return .acquired(AcquireResult(
                lease: ChatGPTSubscriptionResponsesClient.WebSocketLease(
                    sessionID: sessionID,
                    task: entry.task,
                    isCached: true,
                    isReused: false,
                    leaseID: leaseID
                ),
                heartbeatToCancel: nil,
                entryToClose: nil
            ))
        }

        switch decision {
        case let .acquired(result):
            result.heartbeatToCancel?.cancel()
            if let entryToClose = result.entryToClose {
                dispose(entryToClose)
            }
            return .acquired(result.lease)
        case .useHTTPFallback:
            return .useHTTPFallback
        case .closed:
            return .closed
        }
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

            // Lease fencing prevents an old deferred release from changing a
            // later owner's state after the same cached task was reused.
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

    func openHTTPStream(
        _ request: RemoteHTTPStreamingRequest,
        scopeID: String
    ) async throws -> HTTPStreamLease {
        let opener = httpStreamOpener
        let openingTask = Task<RemoteHTTPStreamingResponse, Error> {
            try await opener(request)
        }
        let token = state.withLock { state -> UInt64? in
            guard !state.closedHTTPFallbackScopeIDs.contains(scopeID) else {
                return nil
            }
            let token = state.makeToken()
            state.pendingHTTPStreams[token] = PendingHTTPStream(
                scopeID: scopeID,
                task: openingTask
            )
            return token
        }
        guard let token else {
            openingTask.cancel()
            throw CancellationError()
        }

        let response: RemoteHTTPStreamingResponse
        do {
            response = try await withTaskCancellationHandler {
                try await openingTask.value
            } onCancel: {
                openingTask.cancel()
            }
        } catch {
            _ = state.withLock {
                $0.pendingHTTPStreams.removeValue(forKey: token)
            }
            throw error
        }

        let didRegister = state.withLock { state -> Bool in
            state.pendingHTTPStreams.removeValue(forKey: token)
            guard !state.closedHTTPFallbackScopeIDs.contains(scopeID) else {
                return false
            }
            state.activeHTTPStreams[token] = ActiveHTTPStream(
                scopeID: scopeID,
                body: response.body
            )
            return true
        }
        guard didRegister else {
            response.body.cancel()
            throw CancellationError()
        }
        return HTTPStreamLease(token: token, response: response)
    }

    func releaseHTTPStream(_ lease: HTTPStreamLease) {
        _ = state.withLock {
            $0.activeHTTPStreams.removeValue(forKey: lease.token)
        }
    }

    func hasActiveHTTPStream(scopeID: String) -> Bool {
        state.withLock {
            $0.activeHTTPStreams.values.contains { $0.scopeID == scopeID }
        }
    }

    func hasPendingHTTPStream(scopeID: String) -> Bool {
        state.withLock {
            $0.pendingHTTPStreams.values.contains { $0.scopeID == scopeID }
        }
    }

    func usesHTTPFallback(scopeID: String) -> Bool {
        state.withLock {
            !$0.closedHTTPFallbackScopeIDs.contains(scopeID)
                && $0.httpFallbackScopeIDs.contains(scopeID)
        }
    }

    func isHTTPFallbackScopeClosed(scopeID: String) -> Bool {
        state.withLock { $0.closedHTTPFallbackScopeIDs.contains(scopeID) }
    }

    @discardableResult
    func activateHTTPFallback(scopeID: String) -> Bool {
        state.withLock { state in
            guard !state.closedHTTPFallbackScopeIDs.contains(scopeID) else {
                return false
            }
            return state.httpFallbackScopeIDs.insert(scopeID).inserted
        }
    }

    func clearHTTPFallback(scopeID: String) {
        _ = state.withLock {
            $0.httpFallbackScopeIDs.remove(scopeID)
        }
    }

    func closeHTTPFallbackScope(scopeID: String) {
        let retired = state.withLock { state -> (
            [Task<RemoteHTTPStreamingResponse, Error>],
            [RemoteHTTPBody]
        ) in
            state.closedHTTPFallbackScopeIDs.insert(scopeID)
            state.httpFallbackScopeIDs.remove(scopeID)
            let pendingTokens = state.pendingHTTPStreams.compactMap { token, stream in
                stream.scopeID == scopeID ? token : nil
            }
            let pendingTasks = pendingTokens.compactMap {
                state.pendingHTTPStreams.removeValue(forKey: $0)?.task
            }
            let activeTokens = state.activeHTTPStreams.compactMap { token, stream in
                stream.scopeID == scopeID ? token : nil
            }
            let bodies = activeTokens.compactMap {
                state.activeHTTPStreams.removeValue(forKey: $0)?.body
            }
            return (pendingTasks, bodies)
        }
        for task in retired.0 {
            task.cancel()
        }
        for body in retired.1 {
            body.cancel()
        }
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
        let retired = state.withLock {
            state -> (
                [Entry],
                [TransientEntry],
                [Task<RemoteHTTPStreamingResponse, Error>],
                [RemoteHTTPBody]
            ) in
            let entries = Array(state.entries.values)
            let transientEntries = Array(state.transientEntries.values)
            let pendingTasks = state.pendingHTTPStreams.values.map(\.task)
            let httpBodies = state.activeHTTPStreams.values.map(\.body)
            state.entries.removeAll()
            state.transientEntries.removeAll()
            state.pendingHTTPStreams.removeAll()
            state.activeHTTPStreams.removeAll()
            return (entries, transientEntries, pendingTasks, httpBodies)
        }

        for entry in retired.0 {
            dispose(entry)
        }
        for entry in retired.1 {
            close(entry.task)
        }
        for task in retired.2 {
            task.cancel()
        }
        for body in retired.3 {
            body.cancel()
        }
    }

    /// Terminal lifecycle operation for a pool that owns its default NIO
    /// transport. `closeAll()` remains reusable; after `shutdown()` the pool
    /// must not be used to acquire another connection.
    public func shutdown() async {
        closeAll()
        state.withLock {
            $0.httpFallbackScopeIDs.removeAll()
            $0.closedHTTPFallbackScopeIDs.removeAll()
        }
        if let ownedTransport {
            try? await ownedTransport.shutdown()
        }
    }

    private func makeEntry(
        request: RemoteWebSocketRequest,
        leaseID: UInt64
    ) -> Entry {
        let openedAt = monotonicClock()
        let task = makeWebSocketTask(request: request)
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
        request: RemoteWebSocketRequest
    ) -> any ChatGPTSubscriptionWebSocketTask {
        let task = webSocketTaskFactory(request)
        task.resume()
        return task
    }

    private func startHeartbeat(
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

    private func makeHeartbeatTask(
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

    private func shouldRetireIdleEntry(
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

    private static func sendHeartbeatPing(
        to task: any ChatGPTSubscriptionWebSocketTask
    ) async throws {
        try await task.sendHeartbeatPing()
    }

    /// Runs before every response payload, including a reused pooled socket.
    /// Retrying only retryable connection errors avoids hiding application-level
    /// upgrade or protocol failures.
    func waitUntilReady(
        _ task: any ChatGPTSubscriptionWebSocketTask
    ) async throws {
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

    private static func sendReadinessPing(
        to task: any ChatGPTSubscriptionWebSocketTask
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                // Unlike an idle heartbeat, readiness owns the connection and
                // must let timeout cancellation force-close a stuck write.
                try await task.sendPing()
            }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: defaultConnectionReadinessPingTimeoutNanoseconds
                )
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

    private func discardIdleEntry(
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

    private static func isReusable(
        _ task: any ChatGPTSubscriptionWebSocketTask
    ) -> Bool {
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

    private func dispose(_ entry: Entry) {
        entry.heartbeatTask?.cancel()
        close(entry.task)
    }

    private func close(_ task: any ChatGPTSubscriptionWebSocketTask) {
        closeWebSocketTask(task)
    }
}
