//
//  AgentCoreSessionConfiguration.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public struct AgentCoreSessionConfiguration: Sendable {
    public let sessionID: String
    public let modelID: String?
    public let agentID: String?
    public let agentName: String?
    public let workingDirectory: URL
    public let systemPrompt: String?
    /// Session-specific context is delivered as the first user message rather
    /// than changing the cacheable system instruction prefix.
    public let dynamicContext: String?
    public let cacheKey: String?
    public let sessionRevision: Int
    public let history: [AgentRuntimeMessage]
    public let allowedToolNames: Set<String>?
    public let configuredContextWindowLimit: Int?
    public let generationParameterOverrides: AgentGenerationParameterOverrides
    public let maxToolRounds: Int
    public let maxOutputTokens: Int?
    public let appMode: Bool
    public let thinkingSelection: AgentThinkingSelection?
    public let preserveThinking: Bool

    public init(
        sessionID: String,
        modelID: String?,
        agentID: String? = nil,
        agentName: String? = nil,
        workingDirectory: URL,
        systemPrompt: String?,
        dynamicContext: String? = nil,
        cacheKey: String?,
        sessionRevision: Int = 0,
        history: [AgentRuntimeMessage],
        allowedToolNames: Set<String>? = nil,
        configuredContextWindowLimit: Int? = nil,
        generationParameterOverrides: AgentGenerationParameterOverrides = AgentGenerationParameterOverrides(),
        maxToolRounds: Int = AgentToolRoundPolicy.defaultMaxToolRounds,
        maxOutputTokens: Int? = nil,
        appMode: Bool = false,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "agent-core-\(UUID().uuidString.lowercased())"
        self.modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.agentID = agentID?.nilIfBlank
        self.agentName = agentName?.nilIfBlank
        self.workingDirectory = workingDirectory
        self.systemPrompt = systemPrompt?.nilIfBlank
        self.dynamicContext = dynamicContext?.nilIfBlank
        self.cacheKey = cacheKey?.nilIfBlank
        self.sessionRevision = sessionRevision
        self.history = history
        self.allowedToolNames = allowedToolNames.map {
            Set($0.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty })
        }
        self.configuredContextWindowLimit = configuredContextWindowLimit.map {
            min(max($0, 1), 1_048_576)
        }
        self.generationParameterOverrides = generationParameterOverrides.normalized()
        self.maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(maxToolRounds)
        self.maxOutputTokens = maxOutputTokens.map { max(1, $0) }
        self.appMode = appMode
        self.thinkingSelection = thinkingSelection
        self.preserveThinking = preserveThinking
    }

    public init(
        sessionID: String,
        modelID: String?,
        agentID: String? = nil,
        agentName: String? = nil,
        workingDirectory: String,
        systemPrompt: String?,
        dynamicContext: String? = nil,
        cacheKey: String?,
        sessionRevision: Int = 0,
        history: [AgentRuntimeMessage],
        allowedToolNames: Set<String>? = nil,
        configuredContextWindowLimit: Int? = nil,
        generationParameterOverrides: AgentGenerationParameterOverrides = AgentGenerationParameterOverrides(),
        maxToolRounds: Int = AgentToolRoundPolicy.defaultMaxToolRounds,
        maxOutputTokens: Int? = nil,
        appMode: Bool = false,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        self.init(
            sessionID: sessionID,
            modelID: modelID,
            agentID: agentID,
            agentName: agentName,
            workingDirectory: URL(fileURLWithPath: workingDirectory),
            systemPrompt: systemPrompt,
            dynamicContext: dynamicContext,
            cacheKey: cacheKey,
            sessionRevision: sessionRevision,
            history: history,
            allowedToolNames: allowedToolNames,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            appMode: appMode,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    public var workingDirectoryPath: String {
        workingDirectory.path
    }

    /// Projects the shared runtime fields and adds the model-scoped settings
    /// this session owns.
    public var runtimeConfiguration: AgentRuntimeConfiguration {
        projectedRuntimeConfiguration(
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            agentID: agentID,
            agentName: agentName
        )
    }

    public func matchesRuntime(_ other: AgentCoreSessionConfiguration) -> Bool {
        modelID == other.modelID
            && agentID == other.agentID
            && agentName == other.agentName
            && workingDirectory.standardizedFileURL == other.workingDirectory.standardizedFileURL
            && configuredContextWindowLimit == other.configuredContextWindowLimit
            && generationParameterOverrides == other.generationParameterOverrides
            && maxToolRounds == other.maxToolRounds
            && maxOutputTokens == other.maxOutputTokens
            && appMode == other.appMode
    }

    public func matchesSessionIdentityIgnoringThinking(
        _ other: AgentCoreSessionConfiguration
    ) -> Bool {
        matchesRuntime(other)
            && sessionID == other.sessionID
            && systemPrompt == other.systemPrompt
            && dynamicContext == other.dynamicContext
            && cacheKey == other.cacheKey
            && sessionRevision == other.sessionRevision
            && allowedToolNames == other.allowedToolNames
    }

    public func matchesSessionIdentity(
        _ other: AgentCoreSessionConfiguration
    ) -> Bool {
        matchesSessionIdentityIgnoringThinking(other)
            && thinkingSelection == other.thinkingSelection
            && preserveThinking == other.preserveThinking
    }

    public func withModelID(_ modelID: String?) -> AgentCoreSessionConfiguration {
        copy(modelID: modelID, thinkingSelection: thinkingSelection)
    }

    public func withThinkingSelection(
        _ thinkingSelection: AgentThinkingSelection?
    ) -> AgentCoreSessionConfiguration {
        copy(modelID: modelID, thinkingSelection: thinkingSelection)
    }

    private func copy(
        modelID: String?,
        thinkingSelection: AgentThinkingSelection?
    ) -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: modelID,
            agentID: agentID,
            agentName: agentName,
            workingDirectory: workingDirectory,
            systemPrompt: systemPrompt,
            dynamicContext: dynamicContext,
            cacheKey: cacheKey,
            sessionRevision: sessionRevision + 1,
            history: history,
            allowedToolNames: allowedToolNames,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            appMode: appMode,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }
}

extension AgentCoreSessionConfiguration: Equatable {
    public static func == (
        lhs: AgentCoreSessionConfiguration,
        rhs: AgentCoreSessionConfiguration
    ) -> Bool {
        lhs.matchesSessionIdentity(rhs)
    }
}
