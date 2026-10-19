//
//  ZenCODEACPBridge+AgentMention.swift
//  ZenCODE
//

import Foundation
import ToolCore

struct ACPAgentMentionResolution {
    let agent: AgentProfile
    let prompt: String
}

extension ZenCODEACPBridge {
    func resolveLeadingACPAgentMention(in prompt: String) throws -> ACPAgentMentionResolution? {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedPrompt.hasPrefix("@") else {
            return nil
        }

        let mentionBody = String(trimmedPrompt.dropFirst())
        let splitIndex = mentionBody.firstIndex { $0.isWhitespace }
            ?? mentionBody.endIndex
        let rawMention = String(mentionBody[..<splitIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let mentionKey = Self.acpAgentMentionLookupKey(rawMention)
        guard !mentionKey.isEmpty else {
            return nil
        }

        let agents = try availableACPAgentProfiles()
        guard let agent = agents.first(where: { Self.acpAgentMentionLookupKeys(for: $0).contains(mentionKey) }) else {
            return nil
        }

        let remainingPrompt = String(mentionBody[splitIndex...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ACPAgentMentionResolution(agent: agent, prompt: remainingPrompt)
    }

    func availableACPAgentProfiles() throws -> [AgentProfile] {
        if let hostedAgentProfiles = configuration.hostedAgentProfiles {
            return hostedAgentProfiles
        }
        return try AgentProfileStore.loadRequired()
    }

    func resolvedACPAgentProfile(from params: [String: Any]) throws -> AgentProfile? {
        let rawAgentReference = (params["agentId"] as? String)?.nilIfBlank
            ?? (params["agentID"] as? String)?.nilIfBlank
            ?? (params["agent_id"] as? String)?.nilIfBlank
            ?? (params["agentName"] as? String)?.nilIfBlank
            ?? (params["agent_name"] as? String)?.nilIfBlank
        guard let rawAgentReference else {
            return configuration.selectedAgent
        }

        let lookupKey = Self.acpAgentMentionLookupKey(rawAgentReference)
        guard let agent = try availableACPAgentProfiles().first(where: {
            Self.acpAgentMentionLookupKeys(for: $0).contains(lookupKey)
        }) else {
            throw ACPError.invalidParams("Unknown agent: \(rawAgentReference).")
        }
        return agent
    }

    func acpSessionConfiguration(
        applying agent: AgentProfile,
        to baseConfiguration: AgentCoreSessionConfiguration
    ) async -> AgentCoreSessionConfiguration {
        var allowedToolNames = await resolvedAllowedToolNames(
            agent.allowedToolNames(),
            workingDirectory: baseConfiguration.workingDirectory
        )
        if var effectiveAllowedToolNames = allowedToolNames {
            effectiveAllowedToolNames.formUnion(PromptSkillToolProvider.toolNames)
            allowedToolNames = effectiveAllowedToolNames
        }
        if let effectiveAllowedToolNames = allowedToolNames {
            allowedToolNames = agent.resolvedAllowedToolNames(effectiveAllowedToolNames)
        }
        let modelID = agent.modelID ?? baseConfiguration.modelID
        let promptSections = AgentCoreAppSessionFactory.resolvedPromptSections(
            providedSystemPrompt: nil,
            cwd: baseConfiguration.workingDirectory.path,
            selectedAgent: agent,
            allowedToolNames: allowedToolNames
        )

        return AgentCoreSessionConfiguration(
            sessionID: baseConfiguration.sessionID,
            modelID: modelID,
            agentID: agent.id,
            agentName: agent.name,
            workingDirectory: baseConfiguration.workingDirectory,
            systemPrompt: promptSections.systemPrompt,
            dynamicContext: promptSections.dynamicContext,
            cacheKey: baseConfiguration.cacheKey,
            sessionRevision: baseConfiguration.sessionRevision + 1,
            history: baseConfiguration.history,
            allowedToolNames: allowedToolNames,
            configuredContextWindowLimit: baseConfiguration.configuredContextWindowLimit,
            generationParameterOverrides: baseConfiguration.generationParameterOverrides,
            maxToolRounds: baseConfiguration.maxToolRounds,
            maxOutputTokens: baseConfiguration.maxOutputTokens,
            appMode: baseConfiguration.appMode,
            thinkingSelection: baseConfiguration.thinkingSelection,
            preserveThinking: baseConfiguration.preserveThinking
        )
    }

    static func acpAgentMentionLookupKeys(for agent: AgentProfile) -> Set<String> {
        Set([
            acpAgentMentionLookupKey(agent.id),
            acpAgentMentionLookupKey(agent.name),
            acpAgentMentionLookupKey(agent.displayName)
        ].filter { !$0.isEmpty })
    }

    static func acpAgentMentionLookupKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
            .lowercased()
    }
}
