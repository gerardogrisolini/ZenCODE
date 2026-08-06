//
//  DirectSubAgentRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

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

    public static func unavailableContextualBackendFactory(
        _ context: BackendContext
    ) throws -> any AgentRuntimeBackend {
        throw DirectSubAgentBackendFactoryError.unavailable
    }

    public enum Status: String, Sendable {
        case queued
        case running
        case idle
        case failed
        case closed

        public var isPending: Bool {
            self == .queued || self == .running
        }
    }

    /// Actor-internal mutable storage. External callers receive
    /// `AgentSnapshot`, which is a Sendable value projection.
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
        /// Identity of the transient overview "wave" this agent belongs to.
        /// Mutable because an agent that receives new work through
        /// `agent.message` re-joins the wave that is currently on screen.
        var overviewBatchID: UUID
        public let backend: any AgentRuntimeBackend
        public let createdAt: Date
        public var updatedAt: Date
        public var status: Status
        public var pendingPrompts: [String]
        public var latestOutput: String?
        /// Monotonic identity of the latest completed response for transient
        /// presentation. Unlike `updatedAt`, this does not change when the agent
        /// is merely closed or otherwise receives a metadata-only update.
        public var latestOutputRevision: UInt64 = 0
        public var accumulatedOutput: String?
        public var latestError: String?
        public var modelID: String? = nil
        public var currentActivity: String? = nil
        var pendingContentBuffer: String? = nil
        public var currentToolName: String? = nil
        public var currentToolTarget: String? = nil
        public var latestContentPreview: String? = nil
        public var latestEventAt: Date? = nil
        public var runTask: Task<Void, Never>?

        /// True while the agent still owes work: it is queued or running, or it
        /// has prompts waiting for its work loop. The transient overview keeps
        /// every such agent visible.
        var hasWorkInFlight: Bool {
            status.isPending || !pendingPrompts.isEmpty
        }
    }

    public struct AgentWork {
        public let backend: any AgentRuntimeBackend
        public let sessionID: String
        public let prompt: String
    }

    public struct AgentSnapshot: Sendable {
        public let id: String
        public let rootSessionID: String
        public let taskID: String?
        public let taskAttemptID: String?
        public let taskAttemptOrdinal: Int?
        public let name: String
        public let role: String
        public let profileID: String?
        public let profileName: String?
        public let status: Status
        public let pending: Bool
        public let modelID: String?
        public let currentActivity: String?
        public let currentToolName: String?
        public let currentToolTarget: String?
        public let latestContentPreview: String?
        public let latestEventAt: Date?
        public let latestOutput: String?
        public let latestOutputRevision: UInt64
        public let accumulatedOutput: String?
        public let latestError: String?
        public let createdAt: Date
        public let updatedAt: Date

        public init(
            id: String,
            rootSessionID: String = "default",
            taskID: String? = nil,
            taskAttemptID: String? = nil,
            taskAttemptOrdinal: Int? = nil,
            name: String,
            role: String,
            profileID: String? = nil,
            profileName: String? = nil,
            status: Status,
            pending: Bool,
            modelID: String? = nil,
            currentActivity: String? = nil,
            currentToolName: String? = nil,
            currentToolTarget: String? = nil,
            latestContentPreview: String? = nil,
            latestEventAt: Date? = nil,
            latestOutput: String?,
            latestOutputRevision: UInt64 = 0,
            accumulatedOutput: String? = nil,
            latestError: String?,
            createdAt: Date,
            updatedAt: Date
        ) {
            self.id = id
            self.rootSessionID = rootSessionID
            self.taskID = taskID?.nilIfBlank
            self.taskAttemptID = taskAttemptID?.nilIfBlank
            self.taskAttemptOrdinal = taskAttemptOrdinal
            self.name = name
            self.role = role
            self.profileID = profileID?.nilIfBlank
            self.profileName = profileName?.nilIfBlank
            self.status = status
            self.pending = pending
            self.modelID = modelID
            self.currentActivity = currentActivity
            self.currentToolName = currentToolName
            self.currentToolTarget = currentToolTarget
            self.latestContentPreview = latestContentPreview
            self.latestEventAt = latestEventAt
            self.latestOutput = latestOutput
            self.latestOutputRevision = latestOutputRevision
            self.accumulatedOutput = accumulatedOutput
            self.latestError = latestError
            self.createdAt = createdAt
            self.updatedAt = updatedAt
        }
    }

    public struct RequestedAgentPayload: Sendable {
        public let name: String
        public let role: String
        public let profileReference: String?
        public let taskID: String?
        public let prompt: String?

        /// The model reference supplied to `agent.create`, before it is
        /// checked against the resolved profile. A reference may name either
        /// a binding id or its model id.
        public let requestedModelID: String?

        /// The profile-authorized binding selected for this request. This is
        /// intentionally absent until profile resolution has completed.
        public let modelBinding: AgentModelBinding?

        /// Provider selection captured from the same catalog snapshot that
        /// authorized `modelBinding`. It prevents backend creation from repeating
        /// a global lookup after the task has been claimed.
        public let modelSelection: AgentModelSelection?

        /// The actual model selected by the authorized binding. Before
        /// selection this mirrors the request so profile resolvers can still
        /// inspect it.
        public var modelID: String? {
            modelBinding?.modelID ?? requestedModelID
        }

        public var thinkingSelection: AgentThinkingSelection? {
            modelBinding?.thinkingSelection
        }

        public var capability: Int? {
            modelBinding?.capability
        }

        public init(
            name: String,
            role: String,
            profileReference: String? = nil,
            taskID: String? = nil,
            prompt: String? = nil,
            modelID: String? = nil,
            modelBinding: AgentModelBinding? = nil
        ) {
            self.init(
                name: name,
                role: role,
                profileReference: profileReference,
                taskID: taskID,
                prompt: prompt,
                modelID: modelID,
                modelBinding: modelBinding,
                modelSelection: nil
            )
        }

        init(
            name: String,
            role: String,
            profileReference: String?,
            taskID: String?,
            prompt: String?,
            modelID: String?,
            modelBinding: AgentModelBinding?,
            modelSelection: AgentModelSelection?
        ) {
            self.name = name
            self.role = role
            self.profileReference = profileReference?.nilIfBlank
            self.taskID = taskID?.nilIfBlank
            self.prompt = prompt?.nilIfBlank
            self.requestedModelID = modelID?.nilIfBlank
            self.modelBinding = modelBinding
            self.modelSelection = modelSelection
        }

        public func applying(
            modelBinding: AgentModelBinding?
        ) -> RequestedAgentPayload {
            applying(modelBinding: modelBinding, modelSelection: nil)
        }

        func applying(
            modelBinding: AgentModelBinding?,
            modelSelection: AgentModelSelection?
        ) -> RequestedAgentPayload {
            RequestedAgentPayload(
                name: name,
                role: role,
                profileReference: profileReference,
                taskID: taskID,
                prompt: prompt,
                modelID: requestedModelID,
                modelBinding: modelBinding,
                modelSelection: modelSelection
            )
        }
    }

    public struct BackendContext: Sendable {
        public let requestedName: String
        public let requestedRole: String
        public let profile: AgentProfile?
        /// The reference originally provided to `agent.create`, if any.
        public let requestedModelID: String?
        /// The binding selected and authorized by the resolved profile.
        public let modelBinding: AgentModelBinding?
        /// Provider selection captured with `modelBinding` before any task claim.
        public let modelSelection: AgentModelSelection?
        /// Parent session's SwiftFeatureRuntime, propagated so subagents share the
        /// same discovery cache (consent, `--list-tools` results) instead of each
        /// getting a fresh runtime. `nil` for top-level sessions.
        public let swiftFeatureRuntime: SwiftFeatureRuntime?
        /// Transient live-chat bus inherited from the parent executor. It is not
        /// part of a session snapshot or task graph persistence.
        public let sharedChat: AgentSharedChat?
        /// Stable participant identity of this child in `sharedChat`.
        public let sharedChatSenderID: String?
        /// Root room that contains the coordinator and sibling agents.
        public let sharedChatRoomID: String?

        public init(
            requestedName: String,
            requestedRole: String,
            profile: AgentProfile?,
            modelBinding: AgentModelBinding? = nil,
            modelID: String? = nil,
            swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
            sharedChat: AgentSharedChat? = nil,
            sharedChatSenderID: String? = nil,
            sharedChatRoomID: String? = nil
        ) {
            let resolvedBinding: AgentModelBinding?
            if let modelBinding {
                resolvedBinding = modelBinding
            } else if modelID?.nilIfBlank == nil {
                resolvedBinding = profile?.modelBinding(matching: nil)
            } else {
                resolvedBinding = profile?.modelBinding(matching: modelID)
            }
            self.init(
                requestedName: requestedName,
                requestedRole: requestedRole,
                profile: profile,
                modelBinding: resolvedBinding,
                modelSelection: nil,
                modelID: modelID,
                swiftFeatureRuntime: swiftFeatureRuntime,
                sharedChat: sharedChat,
                sharedChatSenderID: sharedChatSenderID,
                sharedChatRoomID: sharedChatRoomID
            )
        }

        init(
            requestedName: String,
            requestedRole: String,
            profile: AgentProfile?,
            modelBinding: AgentModelBinding?,
            modelSelection: AgentModelSelection?,
            modelID: String?,
            swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
            sharedChat: AgentSharedChat? = nil,
            sharedChatSenderID: String? = nil,
            sharedChatRoomID: String? = nil
        ) {
            self.requestedName = requestedName
            self.requestedRole = requestedRole
            self.profile = profile
            self.requestedModelID = modelID?.nilIfBlank
            self.modelBinding = modelBinding
            self.modelSelection = modelSelection
            self.swiftFeatureRuntime = swiftFeatureRuntime
            self.sharedChat = sharedChat
            self.sharedChatSenderID = sharedChatSenderID?.nilIfBlank
            self.sharedChatRoomID = sharedChatRoomID?.nilIfBlank
        }

        /// Returns a copy of this context with the given SwiftFeatureRuntime,
        /// used by DirectToolExecutor to inject its own runtime for subagents.
        public func injecting(
            swiftFeatureRuntime: SwiftFeatureRuntime? = nil,
            sharedChat: AgentSharedChat? = nil,
            sharedChatSenderID: String? = nil,
            sharedChatRoomID: String? = nil
        ) -> BackendContext {
            BackendContext(
                requestedName: requestedName,
                requestedRole: requestedRole,
                profile: profile,
                modelBinding: modelBinding,
                modelSelection: modelSelection,
                modelID: requestedModelID,
                swiftFeatureRuntime: swiftFeatureRuntime ?? self.swiftFeatureRuntime,
                sharedChat: sharedChat ?? self.sharedChat,
                sharedChatSenderID: sharedChatSenderID ?? self.sharedChatSenderID,
                sharedChatRoomID: sharedChatRoomID ?? self.sharedChatRoomID
            )
        }

        public var modelID: String? {
            modelBinding?.modelID.nilIfBlank
        }

        public var thinkingSelection: AgentThinkingSelection? {
            modelBinding?.thinkingSelection
        }

        public var capability: Int? {
            modelBinding?.capability
        }
    }

    public let backendFactory: DirectSubAgentContextualBackendFactory
    public let profileResolver: DirectSubAgentProfileResolver
    /// Supplies the authoritative model catalog snapshot that delegation is
    /// validated against. Public initializers fail closed by default by loading
    /// the live settings snapshot.
    public let modelCatalogProvider: DirectSubAgentModelCatalogProvider
    let coordinatesLiveManifestReads: Bool
    public var taskOrchestrator: SessionTaskOrchestrator?
    /// The parent session's prompt-skill tool provider, propagated to each
    /// delegated sub-agent so that `skills.list` and `skills.read` remain
    /// intrinsic and always-on at every delegation depth.
    public var promptSkillToolProvider: AgentToolProvider?
    /// Shared only with the backend descendants of this runtime; unlike tasks it
    /// is never checkpointed or restored.
    public let sharedChat: AgentSharedChat
    /// Present in a child executor so `agent.message` has the real author.
    public let sharedChatSenderID: String?
    /// A child uses its parent root room, not its private backend session id.
    public let sharedChatRootSessionID: String?
    private var agentStorage: [String: AgentRecord] = [:]
    /// Lifecycle-transition failures that happen during global shutdown, when
    /// no individual agent record remains available to carry the error.
    public private(set) var lastLifecycleErrors: [String] = []
    var agents: [String: AgentRecord] {
        get { agentStorage }
        set { agentStorage = newValue }
    }
    var latestOverviewBatchID: UUID?

    /// Live default with a known read-only resolver; safe to snapshot both
    /// manifests under one lock. The legacy resolver-taking overload below stays
    /// uncoordinated so an arbitrary callback may acquire manifest locks itself.
    public init(
        backendFactory: @escaping DirectSubAgentBackendFactory
    ) {
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
        modelCatalogProvider: @escaping DirectSubAgentModelCatalogProvider
    ) {
        self.init(
            contextualBackendFactory: { _ in backendFactory() },
            profileResolver: profileResolver,
            modelCatalogProvider: modelCatalogProvider,
            coordinatesLiveManifestReads: false
        )
    }

    public init(
        contextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory
    ) {
        self.init(
            contextualBackendFactory: contextualBackendFactory,
            profileResolver: DirectSubAgentRuntime.liveProfileResolver,
            modelCatalogProvider: DirectSubAgentRuntime.liveModelCatalogProvider,
            coordinatesLiveManifestReads: true
        )
    }

    public init(
        contextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory,
        profileResolver: @escaping DirectSubAgentProfileResolver
    ) {
        self.init(
            contextualBackendFactory: contextualBackendFactory,
            profileResolver: profileResolver,
            modelCatalogProvider: DirectSubAgentRuntime.liveModelCatalogProvider,
            coordinatesLiveManifestReads: false
        )
    }

    public init(
        contextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory,
        profileResolver: @escaping DirectSubAgentProfileResolver,
        modelCatalogProvider: @escaping DirectSubAgentModelCatalogProvider
    ) {
        self.init(
            contextualBackendFactory: contextualBackendFactory,
            profileResolver: profileResolver,
            modelCatalogProvider: modelCatalogProvider,
            coordinatesLiveManifestReads: false
        )
    }

    init(
        contextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory,
        profileResolver: @escaping DirectSubAgentProfileResolver,
        modelCatalogProvider: @escaping DirectSubAgentModelCatalogProvider,
        coordinatesLiveManifestReads: Bool,
        sharedChat: AgentSharedChat = AgentSharedChat(),
        sharedChatSenderID: String? = nil,
        sharedChatRootSessionID: String? = nil
    ) {
        self.backendFactory = contextualBackendFactory
        self.profileResolver = profileResolver
        self.modelCatalogProvider = modelCatalogProvider
        self.coordinatesLiveManifestReads = coordinatesLiveManifestReads
        self.sharedChat = sharedChat
        self.sharedChatSenderID = sharedChatSenderID?.nilIfBlank
        self.sharedChatRootSessionID = sharedChatRootSessionID?.nilIfBlank
    }

    public func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) {
        taskOrchestrator = orchestrator
    }

    /// Stores the parent session's prompt-skill provider so that newly
    /// created sub-agents inherit the same skill selection. Called from
    /// `DirectToolExecutor.updateToolProviders` whenever the parent session
    /// registers or refreshes its tool providers.
    public func installPromptSkillToolProvider(
        _ provider: AgentToolProvider?
    ) {
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

    func releaseTasklessDelegationReservation(
        _ reservation: (rootSessionID: String, reservationID: UUID)?
    ) async {
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
                await taskOrchestrator.unregisterExecutionScope(
                    executionSessionID: record.sessionID
                )
            }
        }
        for record in records {
            record.runTask?.cancel()
            await sharedChat.unregisterParticipant(
                id: record.id,
                roomID: record.rootSessionID
            )
        }
        for record in records {
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

        let resolvedRootSessionID = sharedChatRootSessionID
            ?? rootSessionID?.nilIfBlank
            ?? "default"
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
            return await waitForAgents(arguments: request.arguments)
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
        if locksModelToSession {
            return self
        }
        guard let canonicalModelID = context.modelID else {
            return self
        }

        let configuration = withModelID(canonicalModelID)
        guard let selection = context.modelSelection else {
            return configuration
        }
        return configuration.withModelSettings(
            configuredContextWindowLimit: selection.configuredContextWindowLimit,
            generationParameterOverrides: selection.generationParameterOverrides
        )
    }
}
