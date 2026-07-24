//
//  AgentCoreAppSessionFactory.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public struct AgentCoreAppSessionRequest: Sendable {
    public let sessionID: String
    public let modelID: String?
    public let agentName: String?
    public let bearerToken: String?
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
        bearerToken: String? = nil,
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
        self.bearerToken = bearerToken
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
        let systemPrompt = resolvedSystemPrompt(
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
            systemPrompt: systemPrompt,
            allowedToolNames: allowedToolNames,
            preserveThinking: request.preserveThinking
        )

        return AgentCoreSessionConfiguration(
            sessionID: request.sessionID,
            modelID: effectiveModelID,
            bearerToken: request.bearerToken ?? agentConfiguration.bearerToken,
            workingDirectory: request.workingDirectory,
            systemPrompt: systemPrompt,
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
    }

    public static func resolvedSystemPrompt(
        providedSystemPrompt: String?,
        cwd: String,
        selectedAgent: AgentProfile?,
        allowedToolNames: Set<String>?,
        selectedSkillIDs: Set<String> = []
    ) -> String {
        let memoryToolEnabled = memoryToolEnabled(allowedToolNames)
        let selectedAgentSection = selectedAgent?.promptSection(memoryToolEnabled: memoryToolEnabled)
        let selectedSkillSection = SystemPromptBuilder.staticSkillSection
        let providedSystemPrompt = providedSystemPrompt?.nilIfBlank

        if let providedSystemPrompt {
            let alreadyHasSkillSection = providedSystemPrompt.contains(
                SystemPromptBuilder.staticSkillSectionMarker
            )
            let contextSections = [
                selectedAgentSection,
                alreadyHasSkillSection ? nil : selectedSkillSection
            ]
            .compactMap { $0?.nilIfBlank }
            let sections = contextSections + [
                providedSystemPrompt,
                SystemPromptBuilder.taskOrchestrationSection(
                    allowedToolNames: allowedToolNames
                ),
                SystemPromptBuilder.responseLanguageSection()
            ]
            .compactMap { $0?.nilIfBlank }
            return sections
                .joined(separator: "\n\n")
        }

        let basePrompt = AgentStandaloneSystemPrompt.prompt(
            cwd: cwd,
            memoryToolEnabled: memoryToolEnabled,
            allowedToolNames: allowedToolNames,
            selectedAgentSection: selectedAgentSection,
            selectedSkillSection: selectedSkillSection
        )
        return basePrompt
    }

    public static func memoryToolEnabled(_ allowedToolNames: Set<String>?) -> Bool {
        guard let allowedToolNames else {
            return true
        }
        return allowedToolNames.contains { $0.hasPrefix("memory.") }
    }

    private static func resolvedAgentConfiguration(
        for request: AgentCoreAppSessionRequest
    ) throws -> AgentConfiguration {
        var arguments = [
            "ZenCODE",
            "--cwd",
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
        if let bearerToken = request.bearerToken?.nilIfBlank {
            arguments.append(contentsOf: ["--bearer-token", bearerToken])
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
        let resolved = ExternalToolAvailability.resolvedAllowedToolNames(resolvedToolNames)
        guard var resolved else {
            return resolved
        }
        // Both skill tools are intrinsic and always-on, so they must remain in
        // any explicit allowlist regardless of the user's tool selection.
        resolved.formUnion(PromptSkillToolProvider.toolNames)
        return resolved
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
            "cwd=\(workingDirectory.standardizedFileURL.path)",
            "system=\(systemPrompt)",
            "tools=\((allowedToolNames ?? []).sorted().joined(separator: ","))",
            "preserveThinking=\(preserveThinking)"
        ].joined(separator: "\u{1f}")
        return "\(appCacheKeyPrefix)\(baseHash):\(stableHash(identityPayload))"
    }

    private static let appCacheKeyPrefix = "app-session-cache-v1:"

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
