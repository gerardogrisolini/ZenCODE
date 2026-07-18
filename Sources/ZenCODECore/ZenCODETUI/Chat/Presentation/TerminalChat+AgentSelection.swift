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

extension TerminalChat {
    public func handleAgentsCommand(_ command: String) async throws {
        let rawArguments = String(command.dropFirst("/agents".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if rawArguments.isEmpty {
            guard stdinIsTerminal else {
                await printAgentSelectionStatus()
                await renderAgentList(agents: try availableAgents())
                await writeSystemMessage(Self.renderAgentSelectionUsage())
                return
            }

            let selectedAgent = TerminalCheckboxMenu.selectOne(
                title: "Agent profiles",
                items: try agentSelectionItems(),
                selected: selectedAgent,
                reservedBottomRows: await statusBar.reservedRowsForOverlay()
            )
            if let selectedAgent {
                try await applyAgentSelection(selectedAgent)
            } else {
                await printAgentSelectionStatus()
            }
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

    public func applyAgentSelection(_ agent: AgentProfile) async throws {
        let previousManualModelIDOverride = manualModelIDOverride
        let previousManualThinkingSelectionOverride = manualThinkingSelectionOverride
        selectedAgent = agent
        await interactiveReader.setPanelCommandSuggestions(commandSuggestionsForCurrentAgent())
        await applyAgentProfile(agent)
        activeSessionSystemPromptOverride = nil
        activePlan = nil
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

    public static func agentSelectionDetail(_ agent: AgentProfile) -> String {
        var parts = [agentPurposeSummary(agent)]
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

    private static func agentPurposeSummary(_ agent: AgentProfile) -> String {
        switch agent.id.lowercased() {
        case AgentProfileStore.developerAgentID.uuidString.lowercased():
            return "General software development with web, memory, and sub-agents"
        case AgentProfileStore.builderAgentID.uuidString.lowercased():
            return "Create, build, and manage Swift feature tools"
        case AgentProfileStore.minimalAgentID.uuidString.lowercased():
            return "Minimal tools and concise replies"
        case AgentProfileStore.xcodeAgentID.uuidString.lowercased():
            return "ACP agent for Xcode with Xcode-native tools"
        case AgentProfileStore.reviewerAgentID.uuidString.lowercased():
            return "Read-only reviewer for delegated code review"
        case AgentProfileStore.reporterAgentID.uuidString.lowercased():
            return "Read-only code analysis and evidence-based reports"
        case AgentProfileStore.plannerAgentID.uuidString.lowercased():
            return "Read-only planner for implementation workflows"
        default:
            return customAgentToolSummary(agent.tools)
        }
    }

    private static func customAgentToolSummary(_ tools: [String]) -> String {
        let visibleTools = tools.filter { tool in
            let trimmedTool = tool.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmedTool != TerminalToolSelectionCatalog.featureBuilderKey
                && !trimmedTool.hasPrefix("feature.")
        }
        guard !visibleTools.isEmpty else {
            return "No tools enabled"
        }

        let labels: [(String, String)] = [
            ("shell", "shell"),
            ("files", "files"),
            ("text", "text"),
            (TerminalToolSelectionCatalog.featurePackageKey(id: "search-tools"), "search"),
            (TerminalToolSelectionCatalog.featurePackageKey(id: "git-tools"), "git"),
            (TerminalToolSelectionCatalog.featurePackageKey(id: "swift-tools"), "swift"),
            ("memory", "memory"),
            (TerminalToolSelectionCatalog.featurePackageKey(id: "web-tools"), "web"),
            ("sub-agents", "sub-agents"),
            (TerminalToolSelectionCatalog.featurePackageKey(id: "xcode-tools"), "Xcode"),
            (TerminalToolSelectionCatalog.featurePackageKey(id: "figma-tools"), "Figma")
        ]
        let selectedLabels = labels.compactMap { pair in
            visibleTools.contains(pair.0) ? pair.1 : nil
        }
        let unknownCount = visibleTools.filter { tool in
            !labels.contains { pair in pair.0 == tool }
        }.count
        let summaryLabels = unknownCount > 0
            ? selectedLabels + ["\(unknownCount) custom"]
            : selectedLabels
        return "Tools: \(summaryLabels.joined(separator: ", "))"
    }

    public static func renderSelectedAgent(_ agent: AgentProfile?) -> String {
        guard let agent else {
            return "Selected agent: unavailable\n"
        }
        return "Selected agent: \(agent.displayName)\n"
    }

    public static func renderAgentSelectionUsage() -> String {
        "Usage: /agents [list|<agent name>|<number>]\n"
    }

    public static func agentSelectionKey(_ value: String) -> String {
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
