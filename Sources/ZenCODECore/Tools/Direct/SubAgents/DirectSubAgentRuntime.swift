import Foundation
import ToolCore

public typealias DirectSubAgentBackendFactory = @Sendable () -> any AgentRuntimeBackend
public typealias DirectSubAgentContextualBackendFactory = @Sendable (
    DirectSubAgentRuntime.BackendContext
) throws -> any AgentRuntimeBackend
public typealias DirectSubAgentProfileResolver = @Sendable (
    DirectSubAgentRuntime.RequestedAgentPayload
) -> AgentProfile?

/// The error reported when a backend that supports sub-agents was initialized
/// without a contextual backend factory.
public enum DirectSubAgentBackendFactoryError: LocalizedError {
    case unavailable

    public var errorDescription: String? {
        "Sub-agent creation is unavailable because no contextual backend factory was provided."
    }
}

public actor DirectSubAgentRuntime {
    public static let maximumAgentsPerCreate = 8
    /// Terminal agents are historical inspection records, not live runtime
    /// state. Keeping every closed/failed backend and report for the lifetime of
    /// a long session makes that history an unbounded cache.
    static let maximumRetainedTerminalAgents = 32
    static let maximumRetainedTerminalOutputBytes = 262_144

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

    public enum Status: String, Sendable {
        case queued
        case running
        case idle
        case standby
        case failed
        case closed

        public var isPending: Bool {
            self == .queued || self == .running
        }
    }

    /// Which model phase produced `currentActivity`. Presentation selects the
    /// thinking affordance from this value instead of sniffing a marker prefix
    /// out of the activity text, so model-authored content that happens to
    /// start with "🤔 " is never mistaken for reasoning.
    public enum ActivityKind: String, Sendable, Equatable {
        /// Streamed reasoning. `currentActivity` holds the paragraph in
        /// progress, or nil while no non-blank paragraph exists yet.
        case thinking
        /// A completed assistant message projected into the overview.
        case content
    }

    struct AgentRecord {
        public let id: String
        public let sessionID: String
        public let rootSessionID: String
        public let taskID: String?
        public let taskAttemptID: String?
        public let taskAttemptOrdinal: Int?
        var tasklessDelegationReservationID: UUID?
        public let name: String
        public let role: String
        public let profileID: String?
        public let profileName: String?
        /// Role of the profile the agent was created from.
        public let profileRole: AgentProfileRole
        /// Identity of the transient overview "wave" this agent belongs to.
        /// Mutable because an agent that receives new work through
        /// `agent.message` re-joins the wave that is currently on screen.
        var overviewBatchID: UUID
        public let backend: any AgentRuntimeBackend
        public let createdAt: Date
        public var updatedAt: Date
        public var status: Status
        public var pendingPrompts: [String]
        /// Kept index-aligned with `pendingPrompts`. A true entry means the turn
        /// was created by a direct human-operator message and therefore needs a
        /// runtime fallback reply if the model does not call `agent.message`.
        var pendingOperatorReplyFlags: [Bool] = []
        var currentTurnRepliesToOperator = false
        var currentTurnSentOperatorMessage = false
        public var latestOutput: String?
        /// Monotonic identity of the latest completed response for transient
        /// presentation. Unlike `updatedAt`, this does not change when the agent
        /// is merely closed or otherwise receives a metadata-only update.
        /// Monotonic identity of the actual runtime turn, not the output history.
        public var executionRevision: UInt64 = 0
        public var completedExecutionRevision: UInt64 = 0
        public var latestOutputRevision: UInt64 = 0
        public var accumulatedOutput: String?
        public var latestError: String?
        /// Stable configured model reference selected for this agent. Providers
        /// may later report a less-specific runtime model identifier, so the TUI
        /// uses this value to retain the binding's human-readable title.
        public let configuredModelID: String?
        public var modelID: String? = nil
        public var currentActivity: String? = nil
        /// Typed provenance of `currentActivity`; nil when there is no activity.
        public var currentActivityKind: ActivityKind? = nil
        /// Monotonic identity of assistant content promoted into
        /// `currentActivity` at a tool boundary. It lets presentation mirrors
        /// publish every visible 💬 block exactly once across overview refreshes.
        public var currentActivityRevision: UInt64 = 0
        /// The incomplete thinking paragraph currently being streamed, kept in
        /// its raw stream form (a trailing CR is preserved so a CRLF split
        /// across deltas is not mistaken for a paragraph break). Completed
        /// paragraphs are deliberately discarded: the overview owns one rewrite
        /// slot and presents only the latest paragraph.
        var pendingThoughtParagraph: String? = nil
        var pendingContentBuffer: String? = nil
        public var currentToolName: String? = nil
        public var currentToolTarget: String? = nil
        /// Generation metrics accumulated for the turn in progress, folded with
        /// the same semantics the status bar uses for the root session.
        public var latestMetrics: DirectAgentGenerationMetrics? = nil
        /// Set when a new turn starts. The previous turn's counters stay
        /// visible until the first metrics event of the new turn arrives, which
        /// then replaces them instead of accumulating across turns. This
        /// mirrors `TerminalStatusBar.beginRequest()`.
        var shouldReplaceMetricsOnNextUpdate = false
        public var latestContentPreview: String? = nil
        public var latestEventAt: Date? = nil
        public var runTask: Task<Void, Never>?
        /// Single-flight guard for the shared-chat mailbox drain. Only one
        /// drain loop may be active per agent, so a burst of wake-up callbacks
        /// cannot start overlapping loops that double-queue the same batch.
        var isDrainingSharedChatMailbox = false

        /// The graph ID that authorizes this agent's standby. When nil the
        /// agent is not in standby.
        var standbyGraphID: String?
        /// Timestamp of the most recent standby activity (turn or entry).
        var standbySince: Date?
        /// Number of standby turns completed so far.
        var standbyTurns: Int = 0
        /// Set when a newer attempt claims the same task, signalling that
        /// this standby agent must be superseded.
        var supersededByAttemptID: String?
        /// Flagged by `releaseStandbyAgents` (and by the supersede path) while a
        /// standby turn is still running, so `recordStandbyTurnCompletion` and
        /// `concludeTaskBoundTurn` complete the release after the in-flight
        /// response finishes instead of returning the agent to `.standby`.
        var pendingRelease = false
        /// The reason reported when the flagged release is completed.
        var pendingReleaseReason: String?

        /// True while the agent still owes work: it is queued or running, or it
        /// has prompts waiting for its work loop. The transient overview keeps
        /// every such agent visible. Standby agents are intentionally NOT
        /// included: `agent.wait` must return when only standby agents remain.
        var hasWorkInFlight: Bool {
            status.isPending || !pendingPrompts.isEmpty
        }

        /// Clears every in-flight model-phase projection: the visible activity
        /// and its kind plus the private thinking/content buffers and the tool
        /// row. Lifecycle transitions call this so no partial paragraph or
        /// buffered message can survive into the next turn or into a closed
        /// agent.
        mutating func resetActivityState() {
            currentActivity = nil
            currentActivityKind = nil
            pendingThoughtParagraph = nil
            pendingContentBuffer = nil
            currentToolName = nil
            currentToolTarget = nil
        }

        /// Drops heavyweight report prefixes before this inactive record enters
        /// the bounded terminal-history cache. The latest tail is retained because
        /// it contains the final answer and validation summary callers need most.
        mutating func prepareForTerminalRetention() {
            latestOutput = DirectSubAgentRuntime.boundedTerminalOutput(latestOutput)
            accumulatedOutput = DirectSubAgentRuntime.boundedTerminalOutput(accumulatedOutput)
            latestContentPreview = DirectSubAgentRuntime.boundedTerminalOutput(latestContentPreview)
            resetActivityState()
        }
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
    var agents: [String: AgentRecord] {
        get { agentStorage }
        set {
            agentStorage = newValue
            for (_, observer) in snapshotObservers {
                observer.1.yield(newValue.values.filter { $0.rootSessionID == observer.0 }.map { snapshot(from: $0) })
            }
        }
    }
    var latestOverviewBatchID: UUID?
    /// One graph-completion observer per root session. Started when the first
    /// task-bound agent enters standby; cancelled in `shutdown`/
    /// `interruptAgents` or when the graph reaches a terminal state.
    var graphObserverTasks: [String: Task<Void, Never>] = [:]
    /// Periodic reaper that enforces standby timeout and turn budget.
    var standbyReaperTask: Task<Void, Never>?

    /// Live default with a known read-only resolver; safe to snapshot both
    /// manifests under one lock. The legacy resolver-taking overload below stays
    /// uncoordinated so an arbitrary callback may acquire manifest locks itself.
    public init(backendFactory: @escaping DirectSubAgentBackendFactory) {
        self.init(
            contextualBackendFactory: { _ in backendFactory() },
            profileResolver: DirectSubAgentRuntime.liveProfileResolver,
            modelCatalogProvider: DirectSubAgentRuntime.liveModelCatalogProvider,
            coordinatesLiveManifestReads: true
        )
    }

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

    public init(
        backendFactory: @escaping DirectSubAgentBackendFactory,
        profileResolver: @escaping DirectSubAgentProfileResolver,
        modelCatalogProvider: @escaping DirectSubAgentModelCatalogProvider,
        profileCatalogProvider: @escaping DirectSubAgentProfileCatalogProvider
            = DirectSubAgentRuntime.liveProfileCatalogProvider
    ) {
        self.init(
            contextualBackendFactory: { _ in backendFactory() },
            profileResolver: profileResolver,
            modelCatalogProvider: modelCatalogProvider,
            profileCatalogProvider: profileCatalogProvider,
            coordinatesLiveManifestReads: false
        )
    }

    public init(contextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory) {
        self.init(
            contextualBackendFactory: contextualBackendFactory,
            profileResolver: DirectSubAgentRuntime.liveProfileResolver,
            modelCatalogProvider: DirectSubAgentRuntime.liveModelCatalogProvider,
            coordinatesLiveManifestReads: true
        )
    }

    public init(
        contextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory,
        profileResolver: @escaping DirectSubAgentProfileResolver,
        parentProfileID: String? = nil,
        parentProfileName: String? = nil
    ) {
        self.init(
            contextualBackendFactory: contextualBackendFactory,
            profileResolver: profileResolver,
            modelCatalogProvider: DirectSubAgentRuntime.liveModelCatalogProvider,
            coordinatesLiveManifestReads: false,
            parentProfileID: parentProfileID,
            parentProfileName: parentProfileName
        )
    }

    public init(
        contextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory,
        profileResolver: @escaping DirectSubAgentProfileResolver,
        modelCatalogProvider: @escaping DirectSubAgentModelCatalogProvider,
        profileCatalogProvider: @escaping DirectSubAgentProfileCatalogProvider
            = DirectSubAgentRuntime.liveProfileCatalogProvider,
        parentProfileID: String? = nil,
        parentProfileName: String? = nil
    ) {
        self.init(
            contextualBackendFactory: contextualBackendFactory,
            profileResolver: profileResolver,
            modelCatalogProvider: modelCatalogProvider,
            profileCatalogProvider: profileCatalogProvider,
            coordinatesLiveManifestReads: false,
            parentProfileID: parentProfileID,
            parentProfileName: parentProfileName
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
        agents.removeAll()

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
            return try await createAgents(
                arguments: request.arguments,
                workingDirectory: workingDirectory,
                parentAllowedToolNames: allowedToolNames,
                rootSessionID: resolvedRootSessionID
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
