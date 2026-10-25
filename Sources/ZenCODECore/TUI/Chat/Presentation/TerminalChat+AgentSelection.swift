//
//  TerminalChat+AgentSelection.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import ToolCore

extension TerminalChat {
    public func handleAgentsCommand(_ command: String) async throws {
        let rawArguments = Self.slashCommandArguments(
            from: command,
            commandPrefix: "/agents"
        )

        if rawArguments.isEmpty {
            guard stdinIsTerminal else {
                await printAgentSelectionStatus()
                await renderAgentList(agents: try availableAgents())
                await writeSystemMessage(Self.renderAgentSelectionUsage())
                return
            }

            try await presentProjectAgentMenu()
            return
        }

        switch rawArguments.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "list", "ls", "status":
            await printAgentSelectionStatus()
            await renderAgentList(agents: try availableAgents())
            return
        default:
            break
        }

        let agent = try parseAgentSelection(
            rawArguments,
            availableAgents: try availableAgents()
        )
        try await applyAgentSelection(agent)
    }

    /// Interactive `/agents`: a single multiple-selection menu that associates
    /// profiles with the current project (the only ones the `sub-agents` tool
    /// may delegate to) and picks the active agent.
    ///
    /// - `Enter` saves the ticked profiles and activates the highlighted one;
    ///   the cursor starts on the active agent, so confirming without moving
    ///   keeps it.
    /// - `Esc`/`Q` cancels: nothing is saved and nothing changes.
    /// - A project without a saved selection shows only the system profiles
    ///   ticked, and confirming an unchanged selection does not create the
    ///   file.
    private func presentProjectAgentMenu() async throws {
        let agents = try availableAgents()
        guard !agents.isEmpty else {
            await renderAgentList(agents: agents)
            return
        }

        let workspaceRootURL = configuration.workingDirectory
        let projectName = Self.projectDisplayName(workspaceRootURL)
        let savedSelection = ProjectAgentSelectionStore.load(workspaceRootURL: workspaceRootURL)
        let initialAssociation = Self.projectAgentMenuInitialAssociation(
            agents,
            savedSelection: savedSelection
        )
        let activeKey = selectedAgent.map(ProjectAgentSelectionStore.selectionKey(for:))
        let activeAgent = agents.first {
            ProjectAgentSelectionStore.selectionKey(for: $0) == activeKey
        }
        let items = agents.map { agent in
            TerminalCheckboxMenuItem(
                value: agent,
                title: agent.displayName + (agent == activeAgent ? " *" : ""),
                detail: Self.agentSelectionDetail(agent)
            )
        }

        guard let choice = await TerminalCheckboxMenu.selectWithFocusOffActor(
            title: "Agent profiles · project: \(projectName)",
            items: items,
            selected: initialAssociation,
            focused: activeAgent,
            helpLines: Self.projectAgentMenuHelpLines,
            reservedBottomRows: await statusBar.reservedRowsForOverlay()
        ) else {
            await printAgentSelectionStatus()
            return
        }

        let associationChanged = choice.selected != initialAssociation
        if associationChanged {
            do {
                try ProjectAgentSelectionStore.save(
                    agentIDs: agents
                        .filter { choice.selected.contains($0) }
                        .map(ProjectAgentSelectionStore.selectionIdentifier(for:)),
                    workspaceRootURL: workspaceRootURL
                )
            } catch {
                await writeFailureMessage(
                    "ZenCODE: unable to save the project agents: \(error.localizedDescription)\n"
                )
                return
            }
            await writeSystemMessage(
                Self.renderProjectAgentAssociation(
                    associated: agents.filter { choice.selected.contains($0) },
                    projectName: projectName
                )
            )
        }

        if ProjectAgentSelectionStore.selectionKey(for: choice.focused) != activeKey {
            // The new session builds its prompt from the saved association.
            try await applyAgentSelection(choice.focused)
        } else if associationChanged {
            // Same agent: rebuild the prompt in place, as `/tools` does, so the
            // delegatable roster follows the new association without losing
            // the conversation or reprinting the active tools.
            let printedActiveTools = didPrintActiveTools
            activeSessionSystemPromptOverride = nil
            await updateCurrentSessionToolOptions(discoverExternalTools: false)
            didPrintActiveTools = printedActiveTools
        } else {
            await printAgentSelectionStatus()
        }
    }

    public func applyAgentSelection(_ agent: AgentProfile) async throws {
        let previousManualModelIDOverride = manualModelIDOverride
        let previousManualThinkingSelectionOverride = manualThinkingSelectionOverride
        selectedAgent = agent
        await interactiveReader.setPanelCommandSuggestions(
            await panelSuggestionsForCurrentAgent()
        )
        await applyAgentProfile(agent)
        activeSessionSystemPromptOverride = nil
        activePlan = nil
        pendingPlanApprovalPlanID = nil
        resetResponseLanguageLock()
        // A model explicitly chosen through `/models` is session state, not a
        // property of the selected agent. Retain it across profile changes;
        // only a session without an override falls back to the new profile's
        // default binding.
        manualModelIDOverride = previousManualModelIDOverride
            ?? (configuration.hostedModels == nil ? nil : configuration.modelID)
        manualThinkingSelectionOverride = previousManualModelIDOverride == nil
            ? nil
            : previousManualThinkingSelectionOverride
        await ensureWorkspaceAccessIfNeeded()

        await sessionRunner.shutdownBackendKeepingExternalTools()
        try? await sessionRunner.clearTaskGraphs(sessionID: sessionID)
        printedModelID = nil
        didPrintActiveTools = false
        await statusBar.reset()
        try await createCurrentSession()
        await refreshInitialStatusBarContextWindow()
        _ = try await preloadCurrentModel()
        await printActiveToolsIfNeeded()
        await writeSystemMessage("Switched to agent: \(agent.displayName). Session reset.\n")
    }

    public func applyAgentProfile(_ agent: AgentProfile) async {
        let items = await toolSelectionItems()
        selectedToolKeys = Self.toolSelectionKeys(
            from: agent.tools,
            items: items
        )
        selectedSkillIDs = agent.selectedSkillIDs(
            availableSkills: availableSkills()
        )
    }

    public func availableAgents() throws -> [AgentProfile] {
        if let hostedAgentProfiles = configuration.hostedAgentProfiles {
            return hostedAgentProfiles
        }
        return try AgentProfileStore.loadRequired()
    }

    public func agentSelectionItems() throws -> [TerminalCheckboxMenuItem<AgentProfile>] {
        try availableAgents().map { agent in
            TerminalCheckboxMenuItem(
                value: agent,
                title: agent.displayName,
                detail: Self.agentSelectionDetail(agent)
            )
        }
    }

    public func parseAgentSelection(
        _ rawSelection: String,
        availableAgents: [AgentProfile]
    ) throws -> AgentProfile {
        let token = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = Self.agentSelectionKey(token)
        guard !normalizedToken.isEmpty else {
            throw TerminalAgentSelectionError.unknownAgent(token)
        }

        if let index = Int(token),
           availableAgents.indices.contains(index - 1) {
            return availableAgents[index - 1]
        }

        if let agent = availableAgents.first(where: {
            Self.agentSelectionKey($0.id) == normalizedToken
                || Self.agentSelectionKey($0.name) == normalizedToken
        }) {
            return agent
        }

        throw TerminalAgentSelectionError.unknownAgent(token)
    }

    public func printAgentSelectionStatus() async {
        await writeSystemMessage(Self.renderSelectedAgent(selectedAgent))
    }

    public func renderAgentList(agents: [AgentProfile]) async {
        guard !agents.isEmpty else {
            await writeSystemMessage(
                "No agents configured in \(AgentProfileStore.agentsManifestURL().path).\n"
            )
            return
        }

        await writeSystemMessage("\nAvailable agents:\n")
        for (offset, agent) in agents.enumerated() {
            let marker = selectedAgent == agent ? " *" : ""
            let detail = Self.agentSelectionDetail(agent)
            await writeSystemMessage(
                "  \(offset + 1). \(agent.displayName) - \(detail)\(marker)\n"
            )
        }
        await writeSystemMessage("\n")
    }

    public nonisolated static func agentSelectionDetail(_ agent: AgentProfile) -> String {
        var parts = [agent.role.summary]
        if let modelID = agent.modelID {
            let prefix = agent.modelBindings.count > 1 ? "default model" : "model"
            parts.append("\(prefix): \(modelID)")
        }
        if let thinkingSelection = agent.thinkingSelection {
            parts.append("thinking: \(thinkingSelection.displayTitle)")
        }
        if agent.modelBindings.count > 1 {
            parts.append("bindings: \(agent.modelBindings.count)")
        }
        if !agent.skills.isEmpty {
            parts.append("skills: \(agent.skills.count)")
        }
        return parts.joined(separator: " · ")
    }

    /// Renders the agent model bindings overview as a GFM table through the
    /// shared markdown renderer, reusing its box-drawing table layout and
    /// column fitting. Used by the setup summary.
    public nonisolated static func renderAgentModelBindings(
        agents: [AgentProfile],
        selectedAgent: AgentProfile?
    ) -> String {
        renderAgentModelBindingsTable(
            agents: agents,
            selectedAgent: selectedAgent
        )
    }

    public nonisolated static func renderSelectedAgent(_ agent: AgentProfile?) -> String {
        guard let agent else {
            return "Selected agent: unavailable\n"
        }
        return "Selected agent: \(agent.displayName)\n"
    }

    public nonisolated static func renderAgentSelectionUsage() -> String {
        "Usage: /agents [list|<agent name>|<number>]\n"
    }

    public nonisolated static let projectAgentMenuHelpLines = [
        "↑/↓ move · Space/X toggle project · A all · N none · Enter use agent · Esc/Q cancel"
    ]

    /// Profiles ticked when the `/agents` menu opens: the saved selection, or
    /// the system profiles when the project has none.
    public nonisolated static func projectAgentMenuInitialAssociation(
        _ agents: [AgentProfile],
        savedSelection: Set<String>?
    ) -> Set<AgentProfile> {
        Set(ProjectAgentSelectionStore.filter(agents, selection: savedSelection))
    }

    /// Folder name shown in the `/agents` menu title; the path itself when the
    /// folder has no usable last component (for example the filesystem root).
    public nonisolated static func projectDisplayName(_ workspaceRootURL: URL) -> String {
        let standardized = workspaceRootURL.standardizedFileURL
        return standardized.lastPathComponent.nilIfBlank ?? standardized.path
    }

    public nonisolated static func renderProjectAgentAssociation(
        associated: [AgentProfile],
        projectName: String
    ) -> String {
        guard !associated.isEmpty else {
            return "No agent profile is associated with project \(projectName); "
                + "the sub-agents tool cannot delegate until some are associated with /agents.\n"
        }
        return "Project agents for \(projectName): "
            + "\(associated.map(\.displayName).joined(separator: ", ")).\n"
    }

    public nonisolated static func agentSelectionKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

public enum TerminalAgentSelectionError: LocalizedError {
    case unknownAgent(String)

    public var errorDescription: String? {
        switch self {
        case let .unknownAgent(name):
            return "Unknown agent '\(name)'."
        }
    }
}
