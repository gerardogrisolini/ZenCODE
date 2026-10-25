import Foundation
import ToolCore

extension DirectSubAgentRuntime {
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
        /// Role of the profile the agent was created from; `nil` only for a
        /// snapshot built without a profile.
        public let profileRole: AgentProfileRole?
        /// Stable identity of the transient overview wave containing this agent.
        public let overviewBatchID: UUID?
        /// Whether this snapshot belongs to the runtime's current overview
        /// wave. This is captured by the runtime together with the snapshot so
        /// presentation never has to infer the wave from array order.
        public let isInCurrentOverviewWave: Bool
        public let status: Status
        public let pending: Bool
        /// Stable configured model reference used for presentation. `modelID`
        /// remains the actual identifier most recently reported by the backend.
        public let configuredModelID: String?
        public let modelID: String?
        public let currentActivity: String?
        /// Typed provenance of `currentActivity`. Presentation must branch on
        /// this instead of inspecting the activity text.
        public let currentActivityKind: ActivityKind?
        public let currentActivityRevision: UInt64
        public let currentToolName: String?
        public let currentToolTarget: String?
        /// Generation metrics of the latest turn, already merged by the
        /// runtime. Presentation renders them inline on the model row.
        public let latestMetrics: DirectAgentGenerationMetrics?
        public let latestContentPreview: String?
        public let latestEventAt: Date?
        public let latestOutput: String?
        public let executionRevision: UInt64
        public let completedExecutionRevision: UInt64
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
            profileRole: AgentProfileRole? = nil,
            overviewBatchID: UUID? = nil,
            isInCurrentOverviewWave: Bool = false,
            status: Status,
            pending: Bool,
            configuredModelID: String? = nil,
            modelID: String? = nil,
            currentActivity: String? = nil,
            currentActivityKind: ActivityKind? = nil,
            currentActivityRevision: UInt64 = 0,
            currentToolName: String? = nil,
            currentToolTarget: String? = nil,
            latestMetrics: DirectAgentGenerationMetrics? = nil,
            latestContentPreview: String? = nil,
            latestEventAt: Date? = nil,
            latestOutput: String?,
            executionRevision: UInt64 = 0,
            completedExecutionRevision: UInt64 = 0,
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
            self.profileRole = profileRole
            self.overviewBatchID = overviewBatchID
            self.isInCurrentOverviewWave = isInCurrentOverviewWave
            self.status = status
            self.pending = pending
            self.configuredModelID = configuredModelID?.nilIfBlank
            self.modelID = modelID
            self.currentActivity = currentActivity
            self.currentActivityKind = currentActivityKind
            self.currentActivityRevision = currentActivityRevision
            self.currentToolName = currentToolName
            self.currentToolTarget = currentToolTarget
            self.latestMetrics = latestMetrics
            self.latestContentPreview = latestContentPreview
            self.latestEventAt = latestEventAt
            self.latestOutput = latestOutput
            self.executionRevision = executionRevision
            self.completedExecutionRevision = completedExecutionRevision
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
}
