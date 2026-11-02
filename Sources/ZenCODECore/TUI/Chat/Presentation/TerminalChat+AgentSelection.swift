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
    /// `/agents`: adapter of ``ChatSessionController/runAgentsCommand(line:)``,
    /// which interprets the arguments and runs the matching operation (see
    /// ``ChatSessionController/chooseProjectAgents()`` and
    /// ``ChatSessionController/selectAgent(rawSelection:)``). A failure is
    /// written as a notice.
    public func handleAgentsCommand(_ command: String) async throws {
        await writeSessionNotices(await chatSession.runAgentsCommand(line: command).notices)
    }

    /// Adapter of ``ChatSessionController/selectAgent(_:)``. The active tools
    /// of the new session precede the agent switch
    /// (``writeSessionNotice(_:)``).
    public func applyAgentSelection(_ agent: AgentProfile) async throws {
        await writeSessionNotices(try await chatSession.selectAgent(agent).notices)
    }

    public func applyAgentProfile(_ agent: AgentProfile) async {
        await chatSession.applyAgentProfile(agent)
    }

    public func availableAgents() throws -> [AgentProfile] {
        try chatSession.availableAgents()
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
        try ChatSessionController.parseAgentSelection(
            rawSelection,
            availableAgents: availableAgents
        )
    }

    public func printAgentSelectionStatus() async {
        await writeSessionNotice(.selectedAgent(selectedAgent))
    }

    public func renderAgentList(agents: [AgentProfile]) async {
        await writeSessionNotice(
            .availableAgents(
                agents: agents,
                selected: selectedAgent,
                manifestPath: AgentProfileStore.agentsManifestURL().path
            )
        )
    }

    public nonisolated static func agentSelectionDetail(_ agent: AgentProfile) -> String {
        ChatSessionNoticeText.agentDetail(agent)
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
        ChatSessionNoticeText.text(for: .selectedAgent(agent))
    }

    public nonisolated static func renderAgentSelectionUsage() -> String {
        ChatSessionNoticeText.text(for: .agentSelectionUsage)
    }

    public nonisolated static let projectAgentMenuHelpLines = TerminalInteractionHost.focusedMenuHelpLines(
        toggleLabel: "agents",
        confirmLabel: "use agent"
    )

    /// Profiles ticked when the `/agents` menu opens: the saved selection, or
    /// the system profiles when the project has none.
    public nonisolated static func projectAgentMenuInitialAssociation(
        _ agents: [AgentProfile],
        savedSelection: Set<String>?
    ) -> Set<AgentProfile> {
        ChatSessionController.projectAgentMenuInitialAssociation(
            agents,
            savedSelection: savedSelection
        )
    }

    /// Folder name shown in the `/agents` menu title; the path itself when the
    /// folder has no usable last component (for example the filesystem root).
    public nonisolated static func projectDisplayName(_ workspaceRootURL: URL) -> String {
        ChatSessionController.projectDisplayName(workspaceRootURL)
    }

    public nonisolated static func renderProjectAgentAssociation(
        associated: [AgentProfile],
        projectName: String
    ) -> String {
        ChatSessionNoticeText.text(
            for: .projectAgentsAssociated(agents: associated, projectName: projectName)
        )
    }

    public nonisolated static func agentSelectionKey(_ value: String) -> String {
        ChatSessionController.agentSelectionKey(value)
    }
}
