import Foundation
import ToolCore

public typealias DirectSubAgentBackendFactory = @Sendable () -> any AgentRuntimeBackend
public typealias DirectSubAgentContextualBackendFactory = @Sendable (
    DirectSubAgentRuntime.BackendContext
) throws -> any AgentRuntimeBackend
public typealias DirectSubAgentProfileResolver = @Sendable (
    DirectSubAgentRuntime.RequestedAgentPayload
) -> AgentProfile?
/// Returns the coordinator's response-language section for a root session,
/// `nil` while none is locked.
public typealias DirectSubAgentResponseLanguageSectionProvider = @Sendable (
    _ rootSessionID: String
) async -> String?

/// The error reported when a backend that supports sub-agents was initialized
/// without a contextual backend factory.
public enum DirectSubAgentBackendFactoryError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        "Sub-agent creation is unavailable because no contextual backend factory was provided."
    }
}

public actor DirectSubAgentRuntime {
    /// Terminal agents are historical inspection records, not live runtime
    /// state. Keeping every closed/failed backend and report for the lifetime of
    /// a long session makes that history an unbounded cache.
    static let maximumRetainedTerminalAgents = 32
    static let maximumRetainedTerminalOutputBytes = 262_144
    /// Upper bound on the tool-call durations kept per agent for its
    /// transcript (``ChatSubAgentTranscript/toolDurations``): the oldest are
    /// evicted first, so a long-lived agent keeps those of its latest calls.
    static let maximumRetainedToolCallDurationsPerAgent = 512

    /// Upper bound for shared-chat-derived prompts queued for one agent. It
    /// matches twice the bus mailbox capacity, so a fast producer cannot grow
    /// the pending-prompt queue without limit while the agent processes one
    /// LLM round-trip at a time. Undelivered messages stay in the bounded
    /// mailbox and are drained when the queue has capacity again.
    static let maximumPendingSharedChatPromptsPerAgent =
        AgentSharedChat.maximumMailboxMessages * 2

    /// Maximum idle time (seconds) a task-bound agent may remain in standby
    /// after completing its attempt, waiting for coordinator or peer messages.
    /// Re-armed on every standby turn; enforced by the periodic reaper.
    static let standbyIdleTimeout: TimeInterval = 900
    /// Upper bound on the number of standby turns a single agent may perform
    /// before the reaper closes it. Prevents unbounded ping-pong between peers.
    static let maximumStandbyTurnsPerAgent = 24
    /// Maximum number of agents that may be simultaneously in standby for one
    /// root session. Oldest standby agents are released first (LRU).
    static let maximumStandbyAgentsPerRootSession = 8
    /// Period of the standby reaper cycle that enforces the idle timeout and
    /// the turn budget.
    static let standbyReaperInterval: TimeInterval = 60

    public static func unavailableContextualBackendFactory(
        _ context: BackendContext
    ) throws -> any AgentRuntimeBackend {
        throw DirectSubAgentBackendFactoryError.unavailable
    }

    public let backendFactory: DirectSubAgentContextualBackendFactory
    public let profileResolver: DirectSubAgentProfileResolver
    /// Supplies the authoritative model catalog snapshot that delegation is
    /// validated against. Public initializers fail closed by default by loading
    /// the live settings snapshot.
    public let modelCatalogProvider: DirectSubAgentModelCatalogProvider
    /// Supplies the profiles that role-based delegation (`profileRole`)
    /// chooses from. Defaults to the persisted profiles.
    public let profileCatalogProvider: DirectSubAgentProfileCatalogProvider
    let coordinatesLiveManifestReads: Bool
    public var taskOrchestrator: SessionTaskOrchestrator?
    /// The parent session's prompt-skill tool provider, propagated to each
    /// delegated sub-agent so that `skills.list` and `skills.read` remain
    /// intrinsic and always-on at every delegation depth.
    public var promptSkillToolProvider: AgentToolProvider?
    /// Shared only with the backend descendants of this runtime; unlike tasks it
    /// is never checkpointed or restored.
    public let sharedChat: AgentSharedChat
    /// Profile identity of this coordinator. It is intentionally separate from
    /// the transient agent identity used for collaboration and logging.
    public let parentProfileID: String?
    public let parentProfileName: String?
    /// Present in a child executor so `agent.message` has the real author.
    public let sharedChatSenderID: String?
    /// A child uses its parent root room, not its private backend session id.
    public let sharedChatRootSessionID: String?
    /// Wakes Core transcript observers after a successful delivery. Mailbox
    /// callbacks remain recipient-specific; this callback is room-wide because
    /// coordinator→agent and agent→agent traffic must also be rendered.
    var sharedChatMessageAvailableHandler: (@Sendable (String) -> Void)?
    /// Presentation sink inherited by every delegated backend. It is transient,
    /// never enters task/session persistence, and forwards only tool lifecycles.
    var subAgentToolEventHandler: DirectSubAgentToolEventHandler?
    var subAgentToolEventHandlerRevision: UInt64 = 0
    /// Source of the coordinator's response-language section, read once per
    /// `agent.create` batch. Transient: it never enters persistence.
    var responseLanguageSectionProvider: DirectSubAgentResponseLanguageSectionProvider?
    private var agentStorage: [String: AgentRecord] = [:]
    private var snapshotObservers: [UUID: (String, AsyncStream<[AgentSnapshot]>.Continuation)] = [:]

    public func snapshotEvents(rootSessionID: String) -> AsyncStream<[AgentSnapshot]> {
        let token = UUID()
        let (stream, continuation) = AsyncStream<[AgentSnapshot]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        snapshotObservers[token] = (rootSessionID, continuation)
        continuation.yield(agentStorage.values.filter { $0.rootSessionID == rootSessionID }.map { snapshot(from: $0) })
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSnapshotObserver(token) }
        }
        return stream
    }

    private func removeSnapshotObserver(_ token: UUID) {
        snapshotObservers.removeValue(forKey: token)
    }
    /// Lifecycle-transition failures that happen during global shutdown, when
    /// no individual agent record remains available to carry the error.
    public private(set) var lastLifecycleErrors: [String] = []
    /// The agent registry. Read-only: every write goes through
    /// `mutateAgents`, `mutateAgent` or `mutateAgentInPlace`, which publish
    /// one snapshot broadcast per write.
    var agents: [String: AgentRecord] {
        agentStorage
    }
    /// Applies `body` to the registry in place and publishes one snapshot
    /// broadcast. `body` must not read the registry through `self`: it holds
    /// exclusive access to it. Synchronous, so no suspension can separate a
    /// read inside `body` from its write.
    @discardableResult
    func mutateAgents<T>(_ body: (inout [String: AgentRecord]) -> T) -> T {
        let result = body(&agentStorage)
        // Registry-wide writes (creation, removal, pruning) are rare and may
        // change what any wait observes.
        signalWakeWaiters()
        publishAgentSnapshots()
        return result
    }
    /// Applies `body` to the record of `id` and writes it back into the
    /// registry, then publishes one snapshot broadcast. Returns nil without
    /// writing or publishing when no such agent exists or `predicate` rejects
    /// its record. `body` mutates a copy, so it may still read the registry,
    /// which holds the unchanged record until the write-back. Synchronous, so
    /// no suspension can separate the read from the write and lose a
    /// concurrent update.
    @discardableResult
    func mutateAgent<T>(
        _ id: String,
        where predicate: (AgentRecord) -> Bool = { _ in true },
        _ body: (inout AgentRecord) -> T
    ) -> T? {
        guard var agent = agentStorage[id], predicate(agent) else {
            return nil
        }
        let observedState = agent.waitObservedState
        let result = body(&agent)
        let changesObservedState = agent.waitObservedState != observedState
        agentStorage[id] = agent
        if changesObservedState {
            signalWakeWaiters()
        }
        publishAgentSnapshots()
        return result
    }

    /// Like ``mutateAgent(_:where:_:)``, but `body` mutates the record in
    /// place inside the registry, so a buffer it appends to is not copied
    /// first. `body` must therefore not read the registry through `self`.
    /// Writes and publishes exactly as ``mutateAgent(_:where:_:)`` does.
    @discardableResult
    func mutateAgentInPlace<T>(
        _ id: String,
        where predicate: (AgentRecord) -> Bool = { _ in true },
        _ body: (inout AgentRecord) -> T
    ) -> T? {
        guard let index = agentStorage.index(forKey: id),
              predicate(agentStorage.values[index]) else {
            return nil
        }
        let observedState = agentStorage.values[index].waitObservedState
        let result = body(&agentStorage.values[index])
        if agentStorage.values[index].waitObservedState != observedState {
            signalWakeWaiters()
        }
        publishAgentSnapshots()
        return result
    }

    private func publishAgentSnapshots() {
        for (_, observer) in snapshotObservers {
            observer.1.yield(agentStorage.values.filter { $0.rootSessionID == observer.0 }.map { snapshot(from: $0) })
        }
    }

    /// Advanced by every wake signal. A wait reads it together with the state
    /// it checks, so a change that lands while the wait is still checking
    /// (across one of its awaits) is not lost: the wait returns at once.
    private var wakeGeneration: UInt64 = 0
    /// The suspended waits, resumed by the next wake signal.
    private var wakeWaiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    /// The current wake generation, to pass to
    /// ``waitForWake(after:upTo:)`` once the wait has checked its condition.
    var currentWakeGeneration: UInt64 {
        wakeGeneration
    }

    /// Wakes every suspended wait: an agent changed what waits observe, or a
    /// live message reached a watched mailbox. Waits always re-check their
    /// condition, so a wake that turns out to be irrelevant costs one check.
    func signalWakeWaiters() {
        wakeGeneration &+= 1
        guard !wakeWaiters.isEmpty else { return }
        let waiters = wakeWaiters
        wakeWaiters.removeAll()
        for continuation in waiters.values {
            continuation.resume()
        }
    }

    /// Suspends until a wake signal arrives after `generation`, `timeout`
    /// elapses, or the task is cancelled. Returns at once when a signal
    /// already arrived after `generation`. The timeout keeps polling as the
    /// fallback for changes that raise no signal.
    ///
    /// - Throws: `CancellationError` when the task is cancelled, before or
    ///   during the wait, as `Task.sleep` does.
    func waitForWake(after generation: UInt64, upTo timeout: Duration) async throws {
        try Task.checkCancellation()
        guard wakeGeneration == generation else { return }
        let token = UUID()
        let timer = Task { [weak self] in
            do {
                try await Task.sleep(for: timeout)
            } catch {
                return
            }
            await self?.resumeWakeWaiter(token)
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                if Task.isCancelled {
                    continuation.resume()
                } else {
                    wakeWaiters[token] = continuation
                }
            }
        } onCancel: { [weak self] in
            Task { await self?.resumeWakeWaiter(token) }
        }
        try Task.checkCancellation()
    }

    private func resumeWakeWaiter(_ token: UUID) {
        wakeWaiters.removeValue(forKey: token)?.resume()
    }

    /// Number of suspended waits, for tests.
    var suspendedWakeWaiterCount: Int {
        wakeWaiters.count
    }

    var latestOverviewBatchID: UUID?
    /// One graph-completion observer per root session. Started when the first
    /// task-bound agent enters standby; cancelled in `shutdown`/
    /// `interruptAgents` or when the graph reaches a terminal state.
    var graphObserverTasks: [String: Task<Void, Never>] = [:]
    /// Periodic reaper that enforces standby timeout and turn budget.
    var standbyReaperTask: Task<Void, Never>?

    /// Public construction with a caller-supplied profile resolver and the
    /// live model catalog. Manifest reads stay uncoordinated, so an arbitrary
    /// resolver callback may acquire manifest locks itself.
    public init(
        backendFactory: @escaping DirectSubAgentBackendFactory,
        profileResolver: @escaping DirectSubAgentProfileResolver
    ) {
        self.init(
            contextualBackendFactory: { _ in backendFactory() },
            profileResolver: profileResolver,
            modelCatalogProvider: DirectSubAgentRuntime.liveModelCatalogProvider,
            coordinatesLiveManifestReads: false
        )
    }

    init(
        contextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory,
        profileResolver: @escaping DirectSubAgentProfileResolver,
        modelCatalogProvider: @escaping DirectSubAgentModelCatalogProvider,
        profileCatalogProvider: @escaping DirectSubAgentProfileCatalogProvider
            = DirectSubAgentRuntime.liveProfileCatalogProvider,
        coordinatesLiveManifestReads: Bool,
        sharedChat: AgentSharedChat = AgentSharedChat(),
        sharedChatSenderID: String? = nil,
        sharedChatRootSessionID: String? = nil,
        parentProfileID: String? = nil,
        parentProfileName: String? = nil
    ) {
        self.backendFactory = contextualBackendFactory
        self.profileResolver = profileResolver
        self.modelCatalogProvider = modelCatalogProvider
        self.profileCatalogProvider = profileCatalogProvider
        self.coordinatesLiveManifestReads = coordinatesLiveManifestReads
        self.sharedChat = sharedChat
        self.sharedChatSenderID = sharedChatSenderID?.nilIfBlank
        self.sharedChatRootSessionID = sharedChatRootSessionID?.nilIfBlank
        self.parentProfileID = parentProfileID?.nilIfBlank
        self.parentProfileName = parentProfileName?.nilIfBlank
        self.sharedChatMessageAvailableHandler = nil
        self.subAgentToolEventHandler = nil
    }

    /// Updates the lifecycle sink for existing descendants and future agents.
    /// Synchronization is revision-fenced because actor reentrancy can otherwise
    /// let an older suspended update overwrite a newer handler in a child backend.
    public func updateSubAgentToolEventHandler(_ handler: DirectSubAgentToolEventHandler?) async {
        subAgentToolEventHandler = handler
        subAgentToolEventHandlerRevision &+= 1
        let backends = agents.values.map(\.backend)
        for backend in backends {
            await synchronizeSubAgentToolEventHandler(with: backend)
        }
    }

    func synchronizeSubAgentToolEventHandler(with backend: any AgentRuntimeBackend) async {
        while true {
            let revision = subAgentToolEventHandlerRevision
            let handler = subAgentToolEventHandler
            await backend.updateSubAgentToolEventHandler(handler)
            guard revision == subAgentToolEventHandlerRevision else {
                continue
            }
            return
        }
    }

    public func installTaskOrchestrator(_ orchestrator: SessionTaskOrchestrator) {
        taskOrchestrator = orchestrator
    }

    /// Installs the source of the response-language section for future
    /// delegated agents; agents already created keep their prompt.
    public func updateResponseLanguageSectionProvider(
        _ provider: DirectSubAgentResponseLanguageSectionProvider?
    ) {
        responseLanguageSectionProvider = provider
    }

    /// Stores the parent session's prompt-skill provider so that newly
    /// created sub-agents inherit the same skill selection. Called from
    /// `DirectToolExecutor.updateToolProviders` whenever the parent session
    /// registers or refreshes its tool providers.
    public func installPromptSkillToolProvider(_ provider: AgentToolProvider?) {
        promptSkillToolProvider = provider
    }

    func takeTasklessDelegationReservation(
        from agent: inout AgentRecord
    ) -> (rootSessionID: String, reservationID: UUID)? {
        guard agent.taskID == nil,
              let reservationID = agent.tasklessDelegationReservationID else {
            return nil
        }
        agent.tasklessDelegationReservationID = nil
        return (agent.rootSessionID, reservationID)
    }

    func releaseTasklessDelegationReservation(_ reservation: (rootSessionID: String, reservationID: UUID)?) async {
        guard let reservation,
              let taskOrchestrator else {
            return
        }
        try? await taskOrchestrator.releaseTasklessDelegationReservation(
            sessionID: reservation.rootSessionID,
            reservationID: reservation.reservationID
        )
    }

    public func shutdown() async {
        standbyReaperTask?.cancel()
        standbyReaperTask = nil
        for (_, observer) in graphObserverTasks {
            observer.cancel()
        }
        graphObserverTasks.removeAll()

        let records = Array(agents.values)
        mutateAgents { $0.removeAll() }

        if let taskOrchestrator {
            for record in records {
                if let taskID = record.taskID,
                   let attemptID = record.taskAttemptID {
                    do {
                        _ = try await taskOrchestrator.interruptAttempt(
                            sessionID: record.rootSessionID,
                            taskID: taskID,
                            attemptID: attemptID,
                            reason: "delegated backend shutdown interrupted execution"
                        )
                    } catch {
                        lastLifecycleErrors.append(
                            "Unable to interrupt task \(taskID) during shutdown: \(error.localizedDescription)"
                        )
                    }
                }
                await taskOrchestrator.unregisterExecutionScope(executionSessionID: record.sessionID)
            }
        }
        for record in records {
            record.runTask?.cancel()
            await sharedChat.unregisterParticipant(id: record.id, roomID: record.rootSessionID)
        }
        for record in records {
            // Every record is a child session with its own recall state. The
            // runtime can be torn down without the enclosing runner, so each
            // child must release its state explicitly.
            await MemoryTurnCoordinator.shared.discard(sessionID: record.sessionID)
            await record.backend.updateBorrowedSubAgentToolExecutor(nil)
            await record.backend.shutdown()
        }
        for record in records {
            await releaseTasklessDelegationReservation(
                record.tasklessDelegationReservationID.map {
                    (rootSessionID: record.rootSessionID, reservationID: $0)
                }
            )
        }
    }

    public static func isSubAgentToolName(_ rawName: String) -> Bool {
        guard let canonicalName = canonicalSubAgentToolName(for: rawName) else {
            return false
        }
        return canonicalName.hasPrefix("agent.")
    }

    public static func canonicalSubAgentToolName(for rawName: String) -> String? {
        guard let canonicalName = SubAgentToolRequestCompatibility.canonicalToolName(for: rawName),
              canonicalName.hasPrefix("agent.") else {
            return nil
        }
        return canonicalName
    }

    public func execute(
        rootSessionID: String? = nil,
        toolCall: DirectAgentToolCall,
        workingDirectory: URL,
        allowedToolNames: Set<String>?
    ) async throws -> String {
        let request = Self.normalizedToolRequest(for: toolCall)

        let resolvedRootSessionID = AgentSharedChat.resolvedRoomID(
            sharedChatRootSessionID: sharedChatRootSessionID,
            sessionID: rootSessionID
        )
        switch request.name {
        case "agent.create":
            // The delegating session is the session executing this
            // `agent.create` (a child's `agent.*` calls go to the borrowed
            // executor, which refuses `agent.create`).
            return try await createAgents(
                arguments: request.arguments,
                workingDirectory: workingDirectory,
                parentAllowedToolNames: allowedToolNames,
                rootSessionID: resolvedRootSessionID,
                delegatingSessionID: rootSessionID?.nilIfBlank
            )
        case "agent.list":
            return listAgents(arguments: request.arguments)
        case "agent.get":
            return getAgents(arguments: request.arguments)
        case "agent.message":
            return try await messageSharedChat(
                arguments: request.arguments,
                rootSessionID: resolvedRootSessionID,
                parentAllowedToolNames: allowedToolNames
            )
        case "agent.wait":
            return await waitForAgents(
                arguments: request.arguments,
                roomID: resolvedRootSessionID
            )
        case "agent.close":
            return try await closeAgent(arguments: request.arguments)
        default:
            throw DirectSubAgentRuntimeError.unknownTool(toolCall.name)
        }
    }
}

extension AgentRuntimeConfiguration {
    /// Applies the binding and generation settings already resolved from the
    /// batch's authoritative catalog snapshot. This method never rereads global
    /// settings, so provider routing cannot change after validation or claim.
    public func applyingSubAgentBackendContext(
        _ context: DirectSubAgentRuntime.BackendContext
    ) -> AgentRuntimeConfiguration {
        let identifiedConfiguration = withToolExecutionIdentity(
            agentID: context.sharedChatSenderID,
            agentName: context.requestedName
        ).withProfileIdentity(
            profileID: context.profile?.id,
            profileName: context.profile?.name,
            profileRole: context.profile?.role
        ).withDelegatingSessionID(
            context.delegatingSessionID,
            inheritsFeatureExposures: context.inheritsFeatureExposures
        )
        if locksModelToSession {
            return identifiedConfiguration
        }
        guard let canonicalModelID = context.modelID else {
            return identifiedConfiguration
        }

        let configuration = identifiedConfiguration.withModelID(canonicalModelID)
        guard let selection = context.modelSelection else {
            return configuration
        }
        return configuration.withModelSettings(
            configuredContextWindowLimit: selection.configuredContextWindowLimit,
            generationParameterOverrides: selection.generationParameterOverrides
        )
    }
}
