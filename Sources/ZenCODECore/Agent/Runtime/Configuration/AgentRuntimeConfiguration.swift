//
//  AgentRuntimeConfiguration.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

public import ToolCore
import Foundation

public enum AgentLocalExecAccessMode: CaseIterable, Equatable, Sendable {
    case standard
    case fullAccess

    public var next: AgentLocalExecAccessMode {
        switch self {
        case .standard: return .fullAccess
        case .fullAccess: return .standard
        }
    }

}

/// Dynamic turn context propagated while a runtime backend executes one prompt.
///
/// Tool executors construct ``AgentToolAuthorizationRequest`` values in several
/// modules. Keeping the turn identity in a task-local lets those existing call
/// sites remain source compatible while still binding every authorization
/// request to the prompt that initiated it.
public enum AgentToolAuthorizationContext {
    @TaskLocal public static var turnID: UUID? = nil
}

public struct AgentToolAuthorizationRequest: Sendable, Equatable {
    /// Identifies a delegated sub-agent as the origin of an authorization
    /// request, together with the operator session that owns its delegation
    /// tree.
    ///
    /// A sub-agent runs in its own private session and outlives the turn that
    /// spawned it, so its requests can never match a live turn/session pair.
    /// The runner routes them on this identity instead, which is why the
    /// identity is minted by the runtime from the child tool executor's own
    /// state and is never read from model output or tool arguments: a forgeable
    /// identity would let a call borrow another session's operator consent.
    public struct DelegatedIdentity: Sendable, Equatable {
        /// The delegated agent that issued the tool call.
        public let agentID: String
        /// The operator-facing session that started the delegation tree.
        public let rootSessionID: String

        public init(agentID: String, rootSessionID: String) {
            self.agentID = agentID
            self.rootSessionID = rootSessionID
        }
    }

    /// The unique prompt/turn that owns this authorization request.
    ///
    /// This is optional only for source compatibility with callers that build a
    /// request outside a running agent turn. The runner fails such requests
    /// closed rather than guessing a concurrent prompt handler.
    public let turnID: UUID?
    public let sessionID: String?
    public let toolCallID: String
    public let toolName: String
    public let title: String
    public let kind: String
    public let command: String
    public let workingDirectory: String
    /// Non-nil only for requests raised by a delegated sub-agent. The
    /// coordinator's own executor never sets it, so the turn-scoped path stays
    /// exactly as strict as before.
    public let delegatedIdentity: DelegatedIdentity?

    public init(
        turnID: UUID? = AgentToolAuthorizationContext.turnID,
        sessionID: String?,
        toolCallID: String,
        toolName: String,
        title: String,
        kind: String,
        command: String,
        workingDirectory: String,
        delegatedIdentity: DelegatedIdentity? = nil
    ) {
        self.turnID = turnID
        self.sessionID = sessionID
        self.toolCallID = toolCallID
        self.toolName = toolName
        self.title = title
        self.kind = kind
        self.command = command
        self.workingDirectory = workingDirectory
        self.delegatedIdentity = delegatedIdentity
    }

    /// Returns a copy that differs only in the operator-facing title.
    ///
    /// Presentation is deliberately the only thing this changes: every field
    /// the runner routes on, and every field consent caching keys on (tool name
    /// and command), is carried over untouched.
    public func withTitle(_ title: String) -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            turnID: turnID,
            sessionID: sessionID,
            toolCallID: toolCallID,
            toolName: toolName,
            title: title,
            kind: kind,
            command: command,
            workingDirectory: workingDirectory,
            delegatedIdentity: delegatedIdentity
        )
    }
}

public typealias AgentToolAuthorizationHandler = @Sendable (AgentToolAuthorizationRequest) async -> Bool

public struct AgentToolCall: Sendable {
    public let id: String
    public let name: String
    public let argumentsJSON: String

    public init(
        id: String,
        name: String,
        argumentsJSON: String
    ) {
        self.id = id
        self.name = name
        self.argumentsJSON = argumentsJSON
    }
}

public typealias AgentBorrowedToolCall = AgentToolCall
public typealias AgentToolExecutor = @Sendable (AgentToolCall) async throws -> String
public typealias AgentBorrowedToolExecutor = AgentToolExecutor
public typealias AgentRuntimeBackendFactory = @Sendable (
    AgentRuntimeConfiguration,
    DirectMCPToolRuntime
) throws -> any AgentRuntimeBackend

public struct AgentToolProvider: Sendable {
    public let tools: [ToolDescriptor]
    public let executor: AgentToolExecutor

    public init(
        tools: [ToolDescriptor],
        executor: @escaping AgentToolExecutor
    ) {
        self.tools = ToolDescriptor.canonicalized(tools)
        self.executor = executor
    }
}

public struct AgentRuntimeConfiguration: Sendable {
    public let modelID: String?
    public let workingDirectory: URL
    public let configuredContextWindowLimit: Int?
    public let generationParameterOverrides: AgentGenerationParameterOverrides
    public let maxToolRounds: Int
    public let maxOutputTokens: Int?
    public let appMode: Bool
    public let locksModelToSession: Bool
    public let toolAuthorizationHandler: AgentToolAuthorizationHandler?
    public let agentID: String?
    public let agentName: String?
    /// Stable profile identity used to decide whether a delegated child may
    /// inherit the coordinator's effective session allowlist.
    public let profileID: String?
    public let profileName: String?
    /// Role of the selected profile. Selects the memory graph a session uses
    /// and whether role-based delegation applies; `nil` when no profile is
    /// selected.
    public let profileRole: AgentProfileRole?

    public init(
        modelID: String?,
        workingDirectory: URL,
        configuredContextWindowLimit: Int? = nil,
        generationParameterOverrides: AgentGenerationParameterOverrides = AgentGenerationParameterOverrides(),
        maxToolRounds: Int,
        maxOutputTokens: Int? = nil,
        appMode: Bool = false,
        locksModelToSession: Bool = false,
        toolAuthorizationHandler: AgentToolAuthorizationHandler?,
        agentID: String? = nil,
        agentName: String? = nil,
        profileID: String? = nil,
        profileName: String? = nil,
        profileRole: AgentProfileRole? = nil
    ) {
        self.modelID = modelID?.nilIfBlank
        self.workingDirectory = workingDirectory
        self.configuredContextWindowLimit = configuredContextWindowLimit.map {
            min(max($0, 1), 1_048_576)
        }
        self.generationParameterOverrides = generationParameterOverrides.normalized()
        self.maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(maxToolRounds)
        self.maxOutputTokens = maxOutputTokens
        self.appMode = appMode
        self.locksModelToSession = locksModelToSession
        self.toolAuthorizationHandler = toolAuthorizationHandler
        self.agentID = agentID?.nilIfBlank
        self.agentName = agentName?.nilIfBlank
        self.profileID = profileID?.nilIfBlank
        self.profileName = profileName?.nilIfBlank
        self.profileRole = profileRole
    }

    public func withModelID(_ modelID: String?) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID?.nilIfBlank,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            appMode: appMode,
            locksModelToSession: locksModelToSession,
            toolAuthorizationHandler: toolAuthorizationHandler,
            agentID: agentID,
            agentName: agentName,
            profileID: profileID,
            profileName: profileName,
            profileRole: profileRole
        )
    }

    public func withModelSettings(
        configuredContextWindowLimit: Int?,
        generationParameterOverrides: AgentGenerationParameterOverrides?
    ) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit.map {
                min(max($0, 1), 1_048_576)
            },
            generationParameterOverrides: generationParameterOverrides?
                .normalized()
                ?? AgentGenerationParameterOverrides(),
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            appMode: appMode,
            locksModelToSession: locksModelToSession,
            toolAuthorizationHandler: toolAuthorizationHandler,
            agentID: agentID,
            agentName: agentName,
            profileID: profileID,
            profileName: profileName,
            profileRole: profileRole
        )
    }

    public func withToolAuthorizationHandler(
        _ toolAuthorizationHandler: AgentToolAuthorizationHandler?
    ) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            appMode: appMode,
            locksModelToSession: locksModelToSession,
            toolAuthorizationHandler: toolAuthorizationHandler,
            agentID: agentID,
            agentName: agentName,
            profileID: profileID,
            profileName: profileName,
            profileRole: profileRole
        )
    }

    public func withProfileIdentity(
        profileID: String?,
        profileName: String?,
        profileRole: AgentProfileRole?
    ) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            appMode: appMode,
            locksModelToSession: locksModelToSession,
            toolAuthorizationHandler: toolAuthorizationHandler,
            agentID: agentID,
            agentName: agentName,
            profileID: profileID,
            profileName: profileName,
            profileRole: profileRole
        )
    }

    public func withToolExecutionIdentity(
        agentID: String?,
        agentName: String?
    ) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            appMode: appMode,
            locksModelToSession: locksModelToSession,
            toolAuthorizationHandler: toolAuthorizationHandler,
            agentID: agentID,
            agentName: agentName,
            profileID: profileID,
            profileName: profileName,
            profileRole: profileRole
        )
    }
}
