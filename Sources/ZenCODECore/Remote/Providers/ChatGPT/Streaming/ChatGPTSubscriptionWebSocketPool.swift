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
    struct Entry {
        let task: any ChatGPTSubscriptionWebSocketTask
        /// Recorded once when the task is created; reuse and heartbeats never
        /// extend a connection's absolute lifetime.
        let openedAt: ContinuousClock.Instant
        var isBusy: Bool
        var activeLeaseID: UInt64?
        var heartbeatID: UInt64?
        var heartbeatTask: Task<Void, Never>?
    }

    struct TransientEntry {
        let sessionID: String
        let task: any ChatGPTSubscriptionWebSocketTask
    }

    struct HTTPStreamLease {
        let token: UInt64
        let response: RemoteHTTPStreamingResponse
    }

    struct ActiveHTTPStream {
        let scopeID: String
        let body: RemoteHTTPBody
    }

    struct PendingHTTPStream {
        let scopeID: String
        let task: Task<RemoteHTTPStreamingResponse, Error>
    }

    struct State {
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
        /// `closeAll()` leaves the pool reusable. Its epoch fences an opener
        /// against a teardown that races its pending-owner creation.
        var httpStreamEpoch: UInt64 = 0
        /// Unlike `closeAll()`, shutdown is terminal: no opener may be
        /// constructed or promoted after this bit is set.
        var isTerminallyShutdown = false
        /// Every `closeAll()` contributes its cancelled openers to this chain.
        /// A later terminal shutdown awaits it before closing an owned transport.
        var httpStreamDrainTask: Task<Void, Never>?
        /// The single terminal operation shared by all concurrent callers.
        /// Its body captures the pool weakly, so storing it in `State` cannot
        /// form a permanent pool -> state -> task -> pool cycle.
        var shutdownTask: Task<Void, Never>?
        var pendingHTTPStreams: [UInt64: PendingHTTPStream] = [:]
        var activeHTTPStreams: [UInt64: ActiveHTTPStream] = [:]
        private var nextToken: UInt64 = 0

        mutating func makeToken() -> UInt64 {
            nextToken &+= 1
            return nextToken
        }
    }

    struct AcquireResult {
        let lease: ChatGPTSubscriptionResponsesClient.WebSocketLease
        let heartbeatToCancel: Task<Void, Never>?
        let entryToClose: Entry?
    }

    enum ScopedWebSocketAcquireResult {
        case acquired(ChatGPTSubscriptionResponsesClient.WebSocketLease)
        case useHTTPFallback
        case closed
    }

    enum AcquireDecision {
        case acquired(AcquireResult)
        case useHTTPFallback
        case closed
    }

    struct ReleaseResult {
        var heartbeatToCancel: Task<Void, Never>?
        var entryToClose: Entry?
        var taskToClose: (any ChatGPTSubscriptionWebSocketTask)?
        var heartbeatIDToStart: UInt64?
    }

    struct RetiredHTTPStreams {
        let pendingTasks: [Task<RemoteHTTPStreamingResponse, Error>]
        let bodies: [RemoteHTTPBody]
    }

    /// A single-use asynchronous latch. Terminal shutdown publishes its task
    /// while holding `state`, then opens this latch only after cancelling the
    /// HTTP owners it retired outside that mutex.
    actor OneShotGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !isOpen else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func open() {
            guard !isOpen else { return }
            isOpen = true
            let pendingWaiters = waiters
            waiters.removeAll()
            for waiter in pendingWaiters {
                waiter.resume()
            }
        }
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

    let heartbeatIntervalNanoseconds: UInt64
    let maximumConnectionAge: Duration
    let monotonicClock: @Sendable () -> ContinuousClock.Instant
    let heartbeatSleep: @Sendable (UInt64) async throws -> Void
    let webSocketTaskFactory: @Sendable (
        RemoteWebSocketRequest
    ) -> any ChatGPTSubscriptionWebSocketTask
    let closeWebSocketTask: @Sendable (
        any ChatGPTSubscriptionWebSocketTask
    ) -> Void
    let httpStreamOpener: @Sendable (
        RemoteHTTPStreamingRequest
    ) async throws -> RemoteHTTPStreamingResponse
    /// Test seam for forcing the narrow interval between an HTTP opener
    /// completing and ownership promotion into `activeHTTPStreams`.
    let beforeHTTPStreamRegistration: @Sendable () async -> Void
    /// Test seam for observing that all retired HTTP work has drained before
    /// this pool tears down the transport it owns.
    let beforeOwnedTransportShutdown: @Sendable () async -> Void
    /// Test seam that records each caller once it has entered shutdown's
    /// serialization point. It is synchronous specifically so it is safe to
    /// invoke under `state`'s mutex.
    let didEnterShutdown: @Sendable () -> Void
    /// Non-nil only when this pool constructed the NIO transport itself. An
    /// injected transport remains owned by its embedding composition root.
    let ownedTransport: RemoteTransportCore?
    let state = Mutex(State())

    public convenience init() {
        self.init(transport: nil, heartbeatIntervalNanoseconds: Self.defaultHeartbeatIntervalNanoseconds)
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
            task.cancel(with: ChatGPTSubscriptionWebSocketCloseCode.normalClosure, reason: nil)
        },
        httpStreamOpener: (@Sendable (
            RemoteHTTPStreamingRequest
        ) async throws -> RemoteHTTPStreamingResponse)? = nil,
        beforeHTTPStreamRegistration: @escaping @Sendable () async -> Void = {},
        beforeOwnedTransportShutdown: @escaping @Sendable () async -> Void = {},
        didEnterShutdown: @escaping @Sendable () -> Void = {}
    ) {
        let resolvedTransport = transport ?? RemoteTransportCore()
        self.heartbeatIntervalNanoseconds = max(heartbeatIntervalNanoseconds, 1)
        self.maximumConnectionAge = max(maximumConnectionAge, .zero)
        self.monotonicClock = monotonicClock
        self.heartbeatSleep = heartbeatSleep
        ownedTransport = transport == nil ? resolvedTransport : nil
        self.webSocketTaskFactory = webSocketTaskFactory ?? { request in
            ChatGPTSubscriptionNIOWebSocketTask(transport: resolvedTransport, request: request)
        }
        self.closeWebSocketTask = closeWebSocketTask
        self.httpStreamOpener = httpStreamOpener ?? { request in
            try await resolvedTransport.openHTTPStream(request)
        }
        self.beforeHTTPStreamRegistration = beforeHTTPStreamRegistration
        self.beforeOwnedTransportShutdown = beforeOwnedTransportShutdown
        self.didEnterShutdown = didEnterShutdown
    }

    /// Idle time has no independent TTL: a session may wait on a long-running
    /// tool or sub-agent. Every socket still has a bounded absolute monotonic
    /// lifetime and is never reused once it reaches that age.
    func reapInvalidOrExpiredIdleEntries() {
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
        acquire(sessionID: sessionID, request: request, fallbackScopeID: Optional(fallbackScopeID))
    }

    private static func acquired(
        _ sessionID: String,
        _ task: any ChatGPTSubscriptionWebSocketTask,
        isCached: Bool,
        isReused: Bool,
        leaseID: UInt64,
        heartbeatToCancel: Task<Void, Never>? = nil,
        entryToClose: Entry? = nil
    ) -> AcquireDecision {
        .acquired(AcquireResult(
            lease: ChatGPTSubscriptionResponsesClient.WebSocketLease(
                sessionID: sessionID,
                task: task,
                isCached: isCached,
                isReused: isReused,
                leaseID: leaseID
            ),
            heartbeatToCancel: heartbeatToCancel,
            entryToClose: entryToClose
        ))
    }

    func acquire(
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
                    return Self.acquired(
                        sessionID, existing.task, isCached: true, isReused: true, leaseID: leaseID,
                        heartbeatToCancel: heartbeatToCancel
                    )
                }

                if !existing.isBusy {
                    let entryToClose = state.entries.removeValue(forKey: sessionID)
                    let leaseID = state.makeToken()
                    let entry = makeEntry(request: request, leaseID: leaseID)
                    state.entries[sessionID] = entry
                    return Self.acquired(
                        sessionID, entry.task, isCached: true, isReused: false, leaseID: leaseID,
                        entryToClose: entryToClose
                    )
                }

                // Do not evict an active response, even if its connection has
                // crossed the lifetime threshold. It retires on its own release.
                let leaseID = state.makeToken()
                let task = makeWebSocketTask(request: request)
                state.transientEntries[leaseID] = TransientEntry(sessionID: sessionID, task: task)
                return Self.acquired(sessionID, task, isCached: false, isReused: false, leaseID: leaseID)
            }

            let leaseID = state.makeToken()
            let entry = makeEntry(request: request, leaseID: leaseID)
            state.entries[sessionID] = entry
            return Self.acquired(sessionID, entry.task, isCached: true, isReused: false, leaseID: leaseID)
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

    func release(_ lease: ChatGPTSubscriptionResponsesClient.WebSocketLease, keepAlive: Bool) {
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
                return ReleaseResult(heartbeatToCancel: heartbeatToCancel, heartbeatIDToStart: heartbeatID)
            }

            state.entries.removeValue(forKey: lease.sessionID)
            return ReleaseResult(entryToClose: entry)
        }

        result.heartbeatToCancel?.cancel()
        if let entryToClose = result.entryToClose {
            dispose(entryToClose)
        }
        if let taskToClose = result.taskToClose {
            closeWebSocketTask(taskToClose)
        }
        if let heartbeatID = result.heartbeatIDToStart {
            startHeartbeat(sessionID: lease.sessionID, webSocketTask: lease.task, heartbeatID: heartbeatID)
        }
        reapInvalidOrExpiredIdleEntries()
    }

    func openHTTPStream(
        _ request: RemoteHTTPStreamingRequest,
        scopeID: String
    ) async throws -> HTTPStreamLease {
        let opener = httpStreamOpener
        let pendingOwner = state.withLock {
            state -> (token: UInt64, task: Task<RemoteHTTPStreamingResponse, Error>)?
        in
            // Task construction and publication share the same critical
            // section as terminal shutdown. This prevents an unowned opener
            // from escaping after the terminal fence linearizes.
            guard !state.isTerminallyShutdown,
                  !state.closedHTTPFallbackScopeIDs.contains(scopeID) else {
                return nil
            }

            // Constructing and publishing the unstructured task is atomic
            // with respect to teardown. Its operation executes independently
            // after this short state mutation completes.
            let openingTask = Task<RemoteHTTPStreamingResponse, Error> {
                try await opener(request)
            }
            let token = state.makeToken()
            state.pendingHTTPStreams[token] = PendingHTTPStream(scopeID: scopeID, task: openingTask)
            return (token, openingTask)
        }
        guard let pendingOwner else {
            throw CancellationError()
        }
        let token = pendingOwner.token
        let openingTask = pendingOwner.task

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

        await beforeHTTPStreamRegistration()

        let didRegister = state.withLock { state -> Bool in
            // `closeAll()` and `closeHTTPFallbackScope` remove a pending token
            // before cancelling its opener. The opener may nevertheless win its
            // cancellation race and return a response. Only the still-pending
            // owner is allowed to promote that response to an active stream;
            // otherwise teardown would leak a body after it completed.
            guard state.pendingHTTPStreams.removeValue(forKey: token) != nil,
                  !state.isTerminallyShutdown,
                  !state.closedHTTPFallbackScopeIDs.contains(scopeID) else {
                return false
            }
            state.activeHTTPStreams[token] = ActiveHTTPStream(scopeID: scopeID, body: response.body)
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
            closeWebSocketTask(entry.task)
        }
    }

    public func closeAll() {
        let retired = state.withLock {
            state -> ([Entry], [TransientEntry], RetiredHTTPStreams) in
            let entries = Array(state.entries.values)
            let transientEntries = Array(state.transientEntries.values)
            let httpStreams = retireHTTPStreams(in: &state)
            let precedingDrain = state.httpStreamDrainTask
            state.httpStreamDrainTask = Task {
                if let precedingDrain {
                    await precedingDrain.value
                }
                await Self.drain(httpStreams)
            }
            state.entries.removeAll()
            state.transientEntries.removeAll()
            return (entries, transientEntries, httpStreams)
        }

        // Cancellation deliberately happens after relinquishing the mutex but
        // before returning. The chained task only drains; deferring cancellation
        // to it lets a closeAll caller race a terminal transport shutdown.
        Self.cancel(retired.2)
        for entry in retired.0 {
            dispose(entry)
        }
        for entry in retired.1 {
            closeWebSocketTask(entry.task)
        }
    }

    /// Terminal lifecycle operation for a pool that owns its default NIO
    /// transport. `closeAll()` remains reusable; after `shutdown()` the pool
    /// must not be used to acquire another connection.
    public func shutdown() async {
        let shutdown = state.withLock {
            state -> (Task<Void, Never>, RetiredHTTPStreams?, OneShotGate?) in
            didEnterShutdown()
            if let shutdownTask = state.shutdownTask {
                return (shutdownTask, nil, nil)
            }

            // The terminal bit, epoch increment, and retirement of every HTTP
            // owner are one linearization point. Do not await while this mutex
            // is held: cancellation/draining can re-enter transport code.
            state.isTerminallyShutdown = true
            let entries = Array(state.entries.values)
            let transientEntries = Array(state.transientEntries.values)
            let httpStreams = retireHTTPStreams(in: &state)
            let precedingDrain = state.httpStreamDrainTask
            state.entries.removeAll()
            state.transientEntries.removeAll()
            state.httpFallbackScopeIDs.removeAll()
            state.closedHTTPFallbackScopeIDs.removeAll()

            let currentDrain = Task {
                if let precedingDrain {
                    await precedingDrain.value
                }
                await Self.drain(httpStreams)
            }
            state.httpStreamDrainTask = currentDrain

            // Keep this task independent from the pool. In particular, the
            // task is retained by `State`, so capturing `self` here would keep
            // the pool alive throughout an indefinitely stalled HTTP drain.
            let terminalGate = OneShotGate()
            let closeWebSocketTask = self.closeWebSocketTask
            let ownedTransport = self.ownedTransport
            let beforeOwnedTransportShutdown = self.beforeOwnedTransportShutdown
            let task = Task {
                await terminalGate.wait()
                for entry in entries {
                    entry.heartbeatTask?.cancel()
                    closeWebSocketTask(entry.task)
                }
                for entry in transientEntries {
                    closeWebSocketTask(entry.task)
                }
                // The current drain includes every preceding closeAll drain,
                // so coalesced shutdown callers all observe the same boundary.
                await currentDrain.value
                if let ownedTransport {
                    await beforeOwnedTransportShutdown()
                    try? await ownedTransport.shutdown()
                }
            }
            state.shutdownTask = task
            return (task, httpStreams, terminalGate)
        }
        // As with closeAll, cancellation must not wait for the drain chain:
        // an earlier closeAll drain can be blocked by an opener that ignores
        // cancellation until its deterministic completion gate is released.
        if let retired = shutdown.1 {
            Self.cancel(retired)
            // `shutdownTask` is already visible to coalescing callers, but it
            // cannot observe/drain the retired owners before this cancellation
            // completes. This is the required cancellation -> drain edge.
            await shutdown.2?.open()
        }
        await shutdown.0.value
    }

    func retireHTTPStreams(in state: inout State) -> RetiredHTTPStreams {
        let retired = RetiredHTTPStreams(
            pendingTasks: state.pendingHTTPStreams.values.map(\.task),
            bodies: state.activeHTTPStreams.values.map(\.body)
        )
        state.httpStreamEpoch &+= 1
        state.pendingHTTPStreams.removeAll()
        state.activeHTTPStreams.removeAll()
        return retired
    }

    static func cancel(_ retired: RetiredHTTPStreams) {
        for task in retired.pendingTasks { task.cancel() }
        for body in retired.bodies { body.cancel() }
    }

    static func drain(_ retired: RetiredHTTPStreams) async {
        // An opener can win cancellation and produce a response; cancel that
        // not-yet-promoted body before its owned event-loop group is shut down.
        for task in retired.pendingTasks {
            if case let .success(response) = await task.result {
                response.body.cancel()
            }
        }
    }

    func makeEntry(request: RemoteWebSocketRequest, leaseID: UInt64) -> Entry {
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

    func makeWebSocketTask(request: RemoteWebSocketRequest) -> any ChatGPTSubscriptionWebSocketTask {
        let task = webSocketTaskFactory(request)
        task.resume()
        return task
    }
}
