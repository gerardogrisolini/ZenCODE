//
//  AgentCoreSessionConfiguration.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public struct AgentCoreSessionConfiguration: Sendable {
    public let sessionID: String
    public let modelID: String?
    public let bearerToken: String?
    public let workingDirectory: URL
    public let systemPrompt: String?
    public let cacheKey: String?
    public let sessionRevision: Int
    public let history: [AgentRuntimeMessage]
    public let allowedToolNames: Set<String>?
    public let configuredContextWindowLimit: Int?
    public let generationParameterOverrides: AgentGenerationParameterOverrides
    public let maxToolRounds: Int
    public let maxOutputTokens: Int?
    public let verboseLogging: Bool
    public let appMode: Bool
    public let thinkingSelection: AgentThinkingSelection?
    public let preserveThinking: Bool

    public init(
        sessionID: String,
        modelID: String?,
        bearerToken: String? = nil,
        workingDirectory: URL,
        systemPrompt: String?,
        cacheKey: String?,
        sessionRevision: Int = 0,
        history: [AgentRuntimeMessage],
        allowedToolNames: Set<String>? = nil,
        configuredContextWindowLimit: Int? = nil,
        generationParameterOverrides: AgentGenerationParameterOverrides = AgentGenerationParameterOverrides(),
        maxToolRounds: Int = AgentToolRoundPolicy.defaultMaxToolRounds,
        maxOutputTokens: Int? = nil,
        verboseLogging: Bool = false,
        appMode: Bool = false,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? "agent-core-\(UUID().uuidString.lowercased())"
        self.modelID = modelID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.bearerToken = bearerToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.workingDirectory = workingDirectory
        self.systemPrompt = systemPrompt?.nilIfBlank
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
        self.verboseLogging = verboseLogging
        self.appMode = appMode
        self.thinkingSelection = thinkingSelection
        self.preserveThinking = preserveThinking
    }

    public init(
        sessionID: String,
        modelID: String?,
        bearerToken: String? = nil,
        workingDirectory: String,
        systemPrompt: String?,
        cacheKey: String?,
        sessionRevision: Int = 0,
        history: [AgentRuntimeMessage],
        allowedToolNames: Set<String>? = nil,
        configuredContextWindowLimit: Int? = nil,
        generationParameterOverrides: AgentGenerationParameterOverrides = AgentGenerationParameterOverrides(),
        maxToolRounds: Int = AgentToolRoundPolicy.defaultMaxToolRounds,
        maxOutputTokens: Int? = nil,
        verboseLogging: Bool = false,
        appMode: Bool = false,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        self.init(
            sessionID: sessionID,
            modelID: modelID,
            bearerToken: bearerToken,
            workingDirectory: URL(fileURLWithPath: workingDirectory),
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            sessionRevision: sessionRevision,
            history: history,
            allowedToolNames: allowedToolNames,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    public var workingDirectoryPath: String {
        workingDirectory.path
    }

    public var runtimeConfiguration: AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            bearerToken: bearerToken,
            workingDirectory: workingDirectory,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
            appMode: appMode,
            toolAuthorizationHandler: nil
        )
    }

    public func matchesRuntime(_ other: AgentCoreSessionConfiguration) -> Bool {
        modelID == other.modelID
            && bearerToken == other.bearerToken
            && workingDirectory.standardizedFileURL == other.workingDirectory.standardizedFileURL
            && configuredContextWindowLimit == other.configuredContextWindowLimit
            && generationParameterOverrides == other.generationParameterOverrides
            && maxToolRounds == other.maxToolRounds
            && maxOutputTokens == other.maxOutputTokens
            && verboseLogging == other.verboseLogging
            && appMode == other.appMode
    }

    public func matchesSessionIdentityIgnoringThinking(
        _ other: AgentCoreSessionConfiguration
    ) -> Bool {
        matchesRuntime(other)
            && sessionID == other.sessionID
            && systemPrompt == other.systemPrompt
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
            bearerToken: bearerToken,
            workingDirectory: workingDirectory,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            sessionRevision: sessionRevision + 1,
            history: history,
            allowedToolNames: allowedToolNames,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            maxToolRounds: maxToolRounds,
            maxOutputTokens: maxOutputTokens,
            verboseLogging: verboseLogging,
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
