//
//  ZenCODEACPBridge+AgentMention.swift
//  ZenCODE
//

import Foundation
import ToolCore
import ZenCODERuntime

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

    /// Resolves the agent for a session. An explicit `agentId`/`agentName` in
    /// `params` selects any profile. Without one, the agent a restored
    /// session was saved with is kept while its profile still exists, found
    /// by `savedAgentID` and then by `savedAgentName`, as a saved session
    /// loaded from `/sessions` finds it. Otherwise a launch-time default
    /// developer is re-resolved for the session's `workingDirectory` so each
    /// project gets its own default; an agent requested at launch
    /// (`--agent`) is kept as is. A failure to read the project's selection
    /// never breaks session creation: the launch agent is used instead.
    func resolvedACPAgentProfile(
        from params: [String: Any],
        workingDirectory: URL,
        savedAgentID: String? = nil,
        savedAgentName: String? = nil
    ) throws -> AgentProfile? {
        let rawAgentReference = (params["agentId"] as? String)?.nilIfBlank
            ?? (params["agentID"] as? String)?.nilIfBlank
            ?? (params["agent_id"] as? String)?.nilIfBlank
            ?? (params["agentName"] as? String)?.nilIfBlank
            ?? (params["agent_name"] as? String)?.nilIfBlank
        guard let rawAgentReference else {
            if let savedAgent = savedACPAgentProfile(id: savedAgentID, name: savedAgentName) {
                return savedAgent
            }
            if configuration.requestedAgentName != nil || configuration.selectedAgent == nil {
                return configuration.selectedAgent
            }
            return (try? AgentProfileStore.developerProfile(
                in: availableACPAgentProfiles(),
                workspaceRootURL: workingDirectory
            )) ?? configuration.selectedAgent
        }

        let lookupKey = Self.acpAgentMentionLookupKey(rawAgentReference)
        guard let agent = try availableACPAgentProfiles().first(where: {
            Self.acpAgentMentionLookupKeys(for: $0).contains(lookupKey)
        }) else {
            throw ACPError.invalidParams("Unknown agent: \(rawAgentReference).")
        }
        return agent
    }

    /// The profile of the agent a saved session was saved with: by `id`, then
    /// by `name` (``ChatSessionController/agentSelectionKey(_:)``), as
    /// ``ChatSessionController/restoredAgent(for:)`` finds it; `nil` when the
    /// session was saved without one, the profile no longer exists, or the
    /// profiles cannot be read.
    private func savedACPAgentProfile(id: String?, name: String?) -> AgentProfile? {
        guard id != nil || name != nil,
              let agents = try? availableACPAgentProfiles() else {
            return nil
        }
        if let id, let agent = agents.first(where: { $0.id == id }) {
            return agent
        }
        if let name {
            let key = ChatSessionController.agentSelectionKey(name)
            return agents.first { ChatSessionController.agentSelectionKey($0.name) == key }
        }
        return nil
    }

    /// The configuration of the live `session` routed to `agent` for the rest of
    /// the turn, keeping what the session was granted and narrowing it by the
    /// agent's policy, exactly as `session/new` composed it: the client
    /// request's own grant, the tools of the MCP servers the client provided
    /// (or of the features that replaced them), and the prompt-skill tools,
    /// then ``AgentProfile/resolvedAllowedToolNames(_:)``.
    /// Reading the grant back from the session's current configuration would
    /// drop the servers and the request's restriction, and could widen it.
    func acpSessionConfiguration(
        applying agent: AgentProfile,
        to session: SessionState
    ) -> AgentCoreSessionConfiguration {
        let baseConfiguration = session.configuration
        let allowedToolNames = Self.narrowedSessionAllowedToolNames(
            session.baseAllowedToolNames ?? baseConfiguration.allowedToolNames,
            selectedAgent: agent
        )
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
            agentRole: agent.role,
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

    /// Routes the incarnation `epoch` of `sessionID` to `agent`: the session
    /// keeps its epoch, reservation, and controller, and only the
    /// configuration changes. `nil` (and no change) when the incarnation is
    /// gone.
    ///
    /// Call it only once the turn's line was admitted: a line the slot refused
    /// changes nothing (see ``routeACPCommandTurn``).
    func applyACPAgentMention(
        _ agent: AgentProfile,
        sessionID: String,
        epoch: UInt64
    ) -> SessionState? {
        guard let session = liveSession(id: sessionID, epoch: epoch) else {
            return nil
        }
        let configuration = acpSessionConfiguration(applying: agent, to: session)
        let isLive = updateLiveSession(id: sessionID, epoch: epoch) { live in
            live = sessionState(
                configuration: configuration,
                selectedAgent: agent,
                inheriting: live
            )
        }
        guard isLive else {
            return nil
        }
        return liveSession(id: sessionID, epoch: epoch)
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
