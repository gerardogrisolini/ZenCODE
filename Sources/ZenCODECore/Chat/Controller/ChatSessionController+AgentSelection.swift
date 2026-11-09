//
//  ChatSessionController+AgentSelection.swift
//  ZenCODE
//
//  Agent selection: the agent menu, the project's agent association, and
//  switching the active agent.
//

import Foundation
import ToolCore

extension ChatSessionController {
    // MARK: - Agents

    /// Where the agent profiles are read from, for the missing-manifest
    /// message.
    private var agentsManifestPath: String {
        AgentProfileStore.agentsManifestURL().path
    }

    /// The ID of an agent's menu entry: its persisted selection identifier.
    nonisolated static func agentChoiceID(_ agent: AgentProfile) -> String {
        ProjectAgentSelectionStore.selectionIdentifier(for: agent)
    }

    private nonisolated static func agentChoiceItem(
        _ agent: AgentProfile,
        isCurrent: Bool = false
    ) -> ChatChoiceItem {
        ChatChoiceItem(
            id: agentChoiceID(agent),
            title: agent.displayName,
            detail: ChatSessionNoticeText.agentDetail(agent),
            isCurrent: isCurrent
        )
    }

    /// The agent menu: every available profile, the active one selected.
    func agentChoices() throws -> ChatChoiceList {
        let agents = try availableAgents()
        return ChatChoiceList(
            title: "Agents",
            items: agents.map { Self.agentChoiceItem($0) },
            selectedIDs: Set(agents.filter { $0 == selection.agent }.map(Self.agentChoiceID))
        )
    }

    /// The project's agent menu: every available profile, the ones
    /// associated with the project selected, and the active one marked
    /// current.
    func projectAgentChoices() throws -> ChatChoiceList {
        projectAgentMenu(agents: try availableAgents()).choices
    }

    private struct ProjectAgentMenu {
        let choices: ChatChoiceList
        let projectName: String
        let activeKey: String?
        let activeAgent: AgentProfile?
    }

    private func projectAgentMenu(agents: [AgentProfile]) -> ProjectAgentMenu {
        let projectName = Self.projectDisplayName(workingDirectory)
        let savedSelection = ProjectAgentSelectionStore.load(workspaceRootURL: workingDirectory)
        let initialAssociation = Self.projectAgentMenuInitialAssociation(
            agents,
            savedSelection: savedSelection
        )
        let activeKey = selection.agent.map(ProjectAgentSelectionStore.selectionKey(for:))
        let activeAgent = agents.first {
            ProjectAgentSelectionStore.selectionKey(for: $0) == activeKey
        }
        let choices = ChatChoiceList(
            title: "Agent profiles · project: \(projectName)",
            items: agents.map { agent in
                Self.agentChoiceItem(agent, isCurrent: agent == activeAgent)
            },
            selectedIDs: Set(
                agents.filter { initialAssociation.contains($0) }.map(Self.agentChoiceID)
            )
        )
        return ProjectAgentMenu(
            choices: choices,
            projectName: projectName,
            activeKey: activeKey,
            activeAgent: activeAgent
        )
    }

    /// `/agents`: one menu that associates profiles with the project (the
    /// only ones the `sub-agents` tool may delegate to) and picks the active
    /// agent.
    ///
    /// - Confirming saves the ticked profiles and activates the focused one;
    ///   the cursor starts on the active agent, so confirming without moving
    ///   keeps it.
    /// - Cancelling saves and changes nothing.
    /// - A project without a saved selection starts with only the system
    ///   profiles ticked, and confirming an unchanged selection writes no
    ///   file.
    public func chooseProjectAgents() async throws -> ChatSelectionOutcome {
        guard host.capabilities.contains(.focusedMultipleChoice) else {
            let agents: [AgentProfile]
            do {
                agents = try availableAgents()
            } catch {
                // The selected agent precedes the list that could not be read.
                await effectivePresenter(for: nil).presentSessionNotice(.selectedAgent(selection.agent))
                throw error
            }
            return ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(
                    .agentSelection(
                        agents: agents,
                        selected: selection.agent,
                        manifestPath: agentsManifestPath
                    )
                ),
            ])
        }

        let agents = try availableAgents()
        guard !agents.isEmpty else {
            return ChatSelectionOutcome(notices: [
                .availableAgents(
                    agents: agents,
                    selected: selection.agent,
                    manifestPath: agentsManifestPath
                ),
            ])
        }

        let menu = projectAgentMenu(agents: agents)
        guard let choice = await host.chooseManyWithFocus(
            title: menu.choices.title,
            items: menu.choices.items,
            selectedIDs: menu.choices.selectedIDs,
            focusedID: menu.activeAgent.map(Self.agentChoiceID),
            toggleLabel: "agents",
            confirmLabel: "use agent"
        ) else {
            return ChatSelectionOutcome(notices: [.selectedAgent(selection.agent)])
        }
        return try await applyProjectAgentChoice(
            selectedIDs: choice.selectedIDs,
            focusedID: choice.focusedID,
            agents: agents,
            menu: menu
        )
    }

    /// Applies an answer to the project's agent menu `menu` of `agents`:
    /// the ticked profiles `selectedIDs` and the confirmed row `focusedID`.
    ///
    /// An association that differs from the one the menu started with is
    /// saved and presented; a focused profile other than the active agent is
    /// activated (its new session builds its prompt from the saved
    /// association); otherwise a changed association rebuilds the prompt in
    /// place, and an unchanged one only names the selected agent.
    private func applyProjectAgentChoice(
        selectedIDs: Set<String>,
        focusedID: String?,
        agents: [AgentProfile],
        menu: ProjectAgentMenu
    ) async throws -> ChatSelectionOutcome {
        let associatedAgents = agents.filter {
            selectedIDs.contains(Self.agentChoiceID($0))
        }
        let associationChanged = selectedIDs != menu.choices.selectedIDs
        if associationChanged {
            do {
                try ProjectAgentSelectionStore.save(
                    agentIDs: associatedAgents.map(ProjectAgentSelectionStore.selectionIdentifier(for:)),
                    workspaceRootURL: workingDirectory
                )
            } catch {
                return ChatSelectionOutcome(notices: [
                    .projectAgentsSaveFailed(description: error.localizedDescription),
                ])
            }
            await effectivePresenter(for: nil).presentSessionNotice(
                .projectAgentsAssociated(agents: associatedAgents, projectName: menu.projectName)
            )
        }

        let focusedAgent = agents.first { Self.agentChoiceID($0) == focusedID }
        if let focusedAgent,
           ProjectAgentSelectionStore.selectionKey(for: focusedAgent) != menu.activeKey {
            // The new session builds its prompt from the saved association.
            return try await selectAgent(focusedAgent)
        }
        if associationChanged {
            // Same agent: rebuild the prompt in place, as `/tools` does, so the
            // delegatable roster follows the new association without losing
            // the conversation.
            savedSessionState.systemPromptOverride = nil
            let change = await updateSessionToolOptionsReportingChange(
                discoverExternalTools: false
            ).change
            return ChatSelectionOutcome(change: change)
        }
        return ChatSelectionOutcome(notices: [.selectedAgent(selection.agent)])
    }

    /// Activates the agent `rawSelection` names (its number, ID, or name).
    public func selectAgent(rawSelection: String) async throws -> ChatSelectionOutcome {
        let agent = try Self.parseAgentSelection(
            rawSelection,
            availableAgents: try availableAgents()
        )
        return try await selectAgent(agent)
    }

    /// Activates `agent`: applies its tools and skills, resets the plan and
    /// the task graph, and recreates the session keeping the conversation.
    ///
    /// A model chosen through `/models` is session state, not a property of
    /// the agent, so it is kept with its thinking level; only a session
    /// without one falls back to the agent's default binding.
    public func selectAgent(_ agent: AgentProfile) async throws -> ChatSelectionOutcome {
        let previousModelIDOverride = selection.modelIDOverride
        let previousThinkingOverride = selection.thinkingOverride
        selection.agent = agent
        // Selecting an agent (the same one again included) reads the launch
        // folder anew when the next prompt is composed.
        launchFolderProjectsCache = nil
        await channelHooks?.agentDidChange(agent)
        await applyAgentProfile(agent)
        savedSessionState.systemPromptOverride = nil
        queuedPlans = []
        activePlan = nil
        pendingPlanApprovalPlanID = nil
        selection.modelIDOverride = previousModelIDOverride
            ?? (environment.hostedModels == nil ? nil : environment.explicitModelID)
        selection.thinkingOverride = previousModelIDOverride == nil
            ? nil
            : previousThinkingOverride
        _ = await requestWorkspaceAccessIfNeeded()
        await presentSessionStateChanged()

        await managementRuntime?.shutdownBackendKeepingExternalTools()
        try? await managementRuntime?.clearTaskGraphs(sessionID: sessionID)
        try await recreateSession(reason: .agentSwitched)
        return ChatSelectionOutcome(change: .sessionRecreated, notices: [.agentSwitched(agent)])
    }

    nonisolated static func parseAgentSelection(
        _ rawSelection: String,
        availableAgents: [AgentProfile]
    ) throws -> AgentProfile {
        let token = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = agentSelectionKey(token)
        guard !normalizedToken.isEmpty else {
            throw TerminalAgentSelectionError.unknownAgent(token)
        }

        if let index = Int(token),
           availableAgents.indices.contains(index - 1) {
            return availableAgents[index - 1]
        }

        if let agent = availableAgents.first(where: {
            agentSelectionKey($0.id) == normalizedToken
                || agentSelectionKey($0.name) == normalizedToken
        }) {
            return agent
        }

        throw TerminalAgentSelectionError.unknownAgent(token)
    }

    nonisolated static func agentSelectionKey(_ value: String) -> String {
        TextUtilities.normalizedLookupValue(value)
    }

    /// Profiles ticked when the project's agent menu opens: the saved
    /// selection, or the system profiles when the project has none.
    nonisolated static func projectAgentMenuInitialAssociation(
        _ agents: [AgentProfile],
        savedSelection: Set<String>?
    ) -> Set<AgentProfile> {
        Set(ProjectAgentSelectionStore.filter(agents, selection: savedSelection))
    }

    /// Folder name shown in the project's agent menu title; the path itself
    /// when the folder has no usable last component (for example the
    /// filesystem root).
    nonisolated static func projectDisplayName(_ workspaceRootURL: URL) -> String {
        let standardized = workspaceRootURL.standardizedFileURL
        return standardized.lastPathComponent.nilIfBlank ?? standardized.path
    }
}
