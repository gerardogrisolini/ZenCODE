//
//  AgentCoreAppSessionFactory.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public struct AgentCoreAppSessionRequest: Sendable {
    public let sessionID: String
    public let modelID: String?
    public let agentName: String?
    public let workingDirectory: URL
    public let systemPrompt: String?
    public let cacheKey: String?
    public let history: [AgentRuntimeMessage]
    public let allowedToolNames: Set<String>?
    public let selectedToolKeys: Set<String>?
    public let selectedSkillIDs: Set<String>
    public let maxToolRounds: Int
    public let maxOutputTokens: Int?
    public let verboseLogging: Bool
    public let thinkingSelection: AgentThinkingSelection?
    public let preserveThinking: Bool

    public init(
        sessionID: String,
        modelID: String? = nil,
        agentName: String? = nil,
        workingDirectory: URL,
        systemPrompt: String? = nil,
        cacheKey: String? = nil,
        history: [AgentRuntimeMessage] = [],
        allowedToolNames: Set<String>? = nil,
        selectedToolKeys: Set<String>? = nil,
        selectedSkillIDs: Set<String> = [],
        maxToolRounds: Int = AgentToolRoundPolicy.defaultMaxToolRounds,
        maxOutputTokens: Int? = nil,
        verboseLogging: Bool = false,
        thinkingSelection: AgentThinkingSelection? = nil,
        preserveThinking: Bool = false
    ) {
        self.sessionID = sessionID
        self.modelID = modelID
        self.agentName = agentName
        self.workingDirectory = workingDirectory
        self.systemPrompt = systemPrompt
        self.cacheKey = cacheKey
        self.history = history
        self.allowedToolNames = allowedToolNames
        self.selectedToolKeys = selectedToolKeys
        self.selectedSkillIDs = selectedSkillIDs
        self.maxToolRounds = AgentToolRoundPolicy.normalizedMaxToolRounds(maxToolRounds)
        self.maxOutputTokens = maxOutputTokens
        self.verboseLogging = verboseLogging
        self.thinkingSelection = thinkingSelection
        self.preserveThinking = preserveThinking
    }
}

public enum AgentCoreAppSessionFactory {
    public static func makeConfiguration(
        request: AgentCoreAppSessionRequest
    ) throws -> AgentCoreSessionConfiguration {
        let agentConfiguration = try resolvedAgentConfiguration(for: request)
        let allowedToolNames = resolvedAllowedToolNames(
            selectedToolKeys: request.selectedToolKeys,
            explicitAllowedToolNames: request.allowedToolNames,
            selectedAgent: agentConfiguration.selectedAgent
        )
        let effectiveModelID = agentConfiguration.effectiveModelID
        let selectedBinding: AgentModelBinding?
        if request.modelID?.nilIfBlank == nil {
            selectedBinding = agentConfiguration.selectedAgent?.defaultModelBinding
        } else {
            selectedBinding = agentConfiguration.selectedAgent?.modelBinding(
                matching: request.modelID
            )
        }
        let promptSections = resolvedPromptSections(
            providedSystemPrompt: request.systemPrompt,
            cwd: request.workingDirectory.path,
            selectedAgent: agentConfiguration.selectedAgent,
            allowedToolNames: allowedToolNames,
            selectedSkillIDs: request.selectedSkillIDs
        )
        let thinkingSelection = resolvedThinkingSelection(
            request.thinkingSelection,
            explicitModelID: request.modelID,
            agentModelID: selectedBinding?.modelID,
            agentThinkingSelection: selectedBinding?.thinkingSelection
        )
        let cacheKey = scopedCacheKey(
            request.cacheKey,
            sessionID: request.sessionID,
            modelID: effectiveModelID,
            workingDirectory: request.workingDirectory,
            systemPrompt: promptSections.systemPrompt,
            allowedToolNames: allowedToolNames,
            preserveThinking: request.preserveThinking
        )

        return AgentCoreSessionConfigurationBuilder(
            sessionID: request.sessionID,
            modelID: effectiveModelID,
            workingDirectory: request.workingDirectory,
            systemPrompt: promptSections.systemPrompt,
            dynamicContext: promptSections.dynamicContext,
            cacheKey: cacheKey,
            history: request.history,
            allowedToolNames: allowedToolNames,
            maxToolRounds: request.maxToolRounds,
            maxOutputTokens: request.maxOutputTokens,
            verboseLogging: request.verboseLogging,
            appMode: true,
            thinkingSelection: thinkingSelection,
            preserveThinking: request.preserveThinking
        )
        .makeConfiguration()
    }

    public static func resolvedSystemPrompt(
        providedSystemPrompt: String?,
        cwd: String,
        selectedAgent: AgentProfile?,
        allowedToolNames: Set<String>?,
        selectedSkillIDs: Set<String> = []
    ) -> String {
        resolvedPromptSections(
            providedSystemPrompt: providedSystemPrompt,
            cwd: cwd,
            selectedAgent: selectedAgent,
            allowedToolNames: allowedToolNames,
            selectedSkillIDs: selectedSkillIDs
        )
        .combinedPrompt
    }

    public static func resolvedPromptSections(
        providedSystemPrompt: String?,
        cwd: String,
        selectedAgent: AgentProfile?,
        allowedToolNames: Set<String>?,
        selectedSkillIDs: Set<String> = []
    ) -> SystemPromptSections {
        _ = selectedSkillIDs
        if let providedSystemPrompt = providedSystemPrompt?.nilIfBlank {
            return AgentSessionComposition.appProvidedPromptSections(
                providedSystemPrompt,
                cwd: cwd,
                allowedToolNames: allowedToolNames,
                selectedAgent: selectedAgent
            )
        }

        return AgentSessionComposition.standardPromptSections(
            cwd: cwd,
            allowedToolNames: allowedToolNames,
            selectedAgent: selectedAgent
        )
    }

    public static func memoryToolEnabled(_ allowedToolNames: Set<String>?) -> Bool {
        AgentSessionComposition.memoryToolEnabled(allowedToolNames)
    }

    private static func resolvedAgentConfiguration(
        for request: AgentCoreAppSessionRequest
    ) throws -> AgentConfiguration {
        var arguments = [
            "ZenCODE",
            "--working-directory",
            request.workingDirectory.path,
            "--max-tool-rounds",
            "\(AgentToolRoundPolicy.normalizedMaxToolRounds(request.maxToolRounds))"
        ]

        if let modelID = request.modelID?.nilIfBlank {
            arguments.append(contentsOf: ["--model", modelID])
        }
        if let agentName = request.agentName?.nilIfBlank {
            arguments.append(contentsOf: ["--agent", agentName])
        }
        if let maxOutputTokens = request.maxOutputTokens {
            arguments.append(contentsOf: ["--max-output-tokens", "\(max(1, maxOutputTokens))"])
        }
        if request.verboseLogging {
            arguments.append("--verbose")
        }

        return try AgentConfiguration(arguments: arguments, appModeOverride: true)
    }

    static func resolvedAllowedToolNames(
        selectedToolKeys: Set<String>?,
        explicitAllowedToolNames: Set<String>?,
        selectedAgent: AgentProfile?
    ) -> Set<String>? {
        let resolvedToolNames: Set<String>?
        if let explicitAllowedToolNames {
            resolvedToolNames = explicitAllowedToolNames
        } else if let selectedToolKeys {
            let normalizedKeys = selectedToolKeys
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let items = TerminalToolSelectionCatalog.items(featureStatuses: [])
            var allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
                for: Set(normalizedKeys),
                items: items
            )
            allowedToolNames.formUnion(intrinsicAllowedToolNames(for: selectedAgent))
            resolvedToolNames = allowedToolNames
        } else {
            resolvedToolNames = selectedAgent?.allowedToolNames()
        }
        let profileResolvedToolNames = resolvedToolNames.map { toolNames in
            selectedAgent?.resolvedAllowedToolNames(toolNames) ?? toolNames
        }
        // Both skill tools are intrinsic and always-on, so they must remain in
        // any explicit allowlist regardless of the user's tool selection.
        return AgentSessionComposition.allowedToolNamesIncludingIntrinsicSkillTools(
            ExternalToolAvailability.resolvedAllowedToolNames(profileResolvedToolNames)
        )
    }

    private static func intrinsicAllowedToolNames(for selectedAgent: AgentProfile?) -> Set<String> {
        AgentProfileStore.isBuilderAgent(selectedAgent)
            ? AgentProfileStore.featureManagementToolNames
            : []
    }

    static func resolvedThinkingSelection(
        _ requestedSelection: AgentThinkingSelection?,
        explicitModelID: String?,
        agentModelID: String?,
        agentThinkingSelection: AgentThinkingSelection? = nil,
        manifest: AgentSettingsManifest? = AgentSettingsManifestStore.load()
    ) -> AgentThinkingSelection? {
        AgentSettingsStore.thinkingSelection(
            requestedSelection: requestedSelection,
            explicitModelID: explicitModelID,
            agentModelID: agentModelID,
            agentThinkingSelection: agentThinkingSelection,
            manifest: manifest
        )
    }

    private static func scopedCacheKey(
        _ requestedCacheKey: String?,
        sessionID: String,
        modelID: String?,
        workingDirectory: URL,
        systemPrompt: String,
        allowedToolNames: Set<String>?,
        preserveThinking: Bool
    ) -> String? {
        let seed = requestedCacheKey?.nilIfBlank ?? sessionID.nilIfBlank
        guard let seed else {
            return nil
        }

        // The skill selection is intentionally excluded: it is mutable
        // session-scoped state and must not affect the cache identity, so that
        // adding or removing a skill preserves the remote KV-cache prefix.
        let baseHash = cacheKeyBaseHash(from: seed)
        let identityPayload = [
            "model=\(modelID?.nilIfBlank ?? "")",
            "system=\(systemPrompt)",
            "tools=\((allowedToolNames ?? []).sorted().joined(separator: ","))",
            "preserveThinking=\(preserveThinking)"
        ].joined(separator: "\u{1f}")
        return "\(appCacheKeyPrefix)\(baseHash):\(stableHash(identityPayload))"
    }

    private static let appCacheKeyPrefix = "app-session-cache-v2:"

    private static func cacheKeyBaseHash(from rawValue: String) -> String {
        let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmedValue.split(separator: ":", omittingEmptySubsequences: false)
        if trimmedValue.hasPrefix(appCacheKeyPrefix),
           parts.count >= 3,
           !parts[1].isEmpty {
            return String(parts[1])
        }
        return stableHash(trimmedValue)
    }

    private static func stableHash(_ value: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }

}
