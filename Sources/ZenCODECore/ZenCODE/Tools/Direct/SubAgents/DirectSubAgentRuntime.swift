//
//  DirectSubAgentRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

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

    public struct AgentRecord {
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
        let overviewBatchID: UUID
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
        public var modelRuntime: String? = nil
        public var currentActivity: String? = nil
        var pendingContentBuffer: String? = nil
        public var currentToolName: String? = nil
        public var currentToolTarget: String? = nil
        public var latestContentPreview: String? = nil
        public var latestEventAt: Date? = nil
        public var runTask: Task<Void, Never>?
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
        public let modelRuntime: String?
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
            modelRuntime: String? = nil,
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
            self.modelRuntime = modelRuntime
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
        public let allowedToolNames: Set<String>?

        /// The model reference supplied to `agent.create`, before it is
        /// checked against the resolved profile. A reference may name either
        /// a binding id or its model id.
        public let requestedModelID: String?

        /// The profile-authorized binding selected for this request. This is
        /// intentionally absent until profile resolution has completed.
        public let modelBinding: AgentModelBinding?

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
            allowedToolNames: Set<String>? = nil,
            modelID: String? = nil,
            modelBinding: AgentModelBinding? = nil
        ) {
            self.name = name
            self.role = role
            self.profileReference = profileReference?.nilIfBlank
            self.taskID = taskID?.nilIfBlank
            self.prompt = prompt?.nilIfBlank
            self.allowedToolNames = allowedToolNames
            self.requestedModelID = modelID?.nilIfBlank
            self.modelBinding = modelBinding
        }

        public func applying(
            modelBinding: AgentModelBinding?
        ) -> RequestedAgentPayload {
            RequestedAgentPayload(
                name: name,
                role: role,
                profileReference: profileReference,
                taskID: taskID,
                prompt: prompt,
                allowedToolNames: allowedToolNames,
                modelID: requestedModelID,
                modelBinding: modelBinding
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
        /// Parent session's SwiftFeatureRuntime, propagated so subagents share the
        /// same discovery cache (consent, `--list-tools` results) instead of each
        /// getting a fresh runtime. `nil` for top-level sessions.
        public let swiftFeatureRuntime: SwiftFeatureRuntime?

        public init(
            requestedName: String,
            requestedRole: String,
            profile: AgentProfile?,
            modelBinding: AgentModelBinding? = nil,
            modelID: String? = nil,
            swiftFeatureRuntime: SwiftFeatureRuntime? = nil
        ) {
            self.requestedName = requestedName
            self.requestedRole = requestedRole
            self.profile = profile
            self.requestedModelID = modelID?.nilIfBlank
            if let modelBinding {
                self.modelBinding = modelBinding
            } else if modelID?.nilIfBlank == nil {
                self.modelBinding = profile?.modelBinding(matching: nil)
            } else {
                // Do not silently replace an explicit, unmatched model
                // request with the profile default.
                self.modelBinding = profile?.modelBinding(matching: modelID)
            }
            self.swiftFeatureRuntime = swiftFeatureRuntime
        }

        /// Returns a copy of this context with the given SwiftFeatureRuntime,
        /// used by DirectToolExecutor to inject its own runtime for subagents.
        public func injecting(
            swiftFeatureRuntime: SwiftFeatureRuntime?
        ) -> BackendContext {
            BackendContext(
                requestedName: requestedName,
                requestedRole: requestedRole,
                profile: profile,
                modelBinding: modelBinding,
                modelID: requestedModelID,
                swiftFeatureRuntime: swiftFeatureRuntime
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
    public var taskOrchestrator: SessionTaskOrchestrator?
    public var agents: [String: AgentRecord] = [:]
    var latestOverviewBatchID: UUID?

    public init(
        backendFactory: @escaping DirectSubAgentBackendFactory,
        profileResolver: @escaping DirectSubAgentProfileResolver = DirectSubAgentRuntime.defaultProfileResolver
    ) {
        self.backendFactory = { _ in backendFactory() }
        self.profileResolver = profileResolver
    }

    public init(
        contextualBackendFactory: @escaping DirectSubAgentContextualBackendFactory,
        profileResolver: @escaping DirectSubAgentProfileResolver = DirectSubAgentRuntime.defaultProfileResolver
    ) {
        self.backendFactory = contextualBackendFactory
        self.profileResolver = profileResolver
    }

    public func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) {
        taskOrchestrator = orchestrator
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
                    _ = try? await taskOrchestrator.interruptAttempt(
                        sessionID: record.rootSessionID,
                        taskID: taskID,
                        attemptID: attemptID,
                        reason: "delegated backend shutdown interrupted execution"
                    )
                }
                await taskOrchestrator.unregisterExecutionScope(
                    executionSessionID: record.sessionID
                )
            }
        }
        for record in records {
            record.runTask?.cancel()
        }
        for record in records {
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

        switch request.name {
        case "agent.create":
            return try await createAgents(
                arguments: request.arguments,
                workingDirectory: workingDirectory,
                parentAllowedToolNames: allowedToolNames,
                rootSessionID: rootSessionID?.nilIfBlank ?? "default"
            )
        case "agent.list":
            return listAgents(arguments: request.arguments)
        case "agent.get":
            return getAgents(arguments: request.arguments)
        case "agent.message":
            return try await messageAgents(
                arguments: request.arguments,
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
    public func applyingSubAgentBackendContext(
        _ context: DirectSubAgentRuntime.BackendContext
    ) -> AgentRuntimeConfiguration {
        if locksModelToSession {
            return self
        }

        guard let requestedModelID = context.modelID else {
            return self
        }

        guard let selection = AgentSettingsStore.defaultSelection(
            explicitModelID: requestedModelID
        ) else {
            return withModelID(requestedModelID)
        }

        return withModelID(selection.modelID)
            .withModelSettings(
                configuredContextWindowLimit: selection.configuredContextWindowLimit,
                generationParameterOverrides: selection.generationParameterOverrides
            )
    }
}
