//
//  ZenCODEAgentProfileSetupRunner+Models.swift
//  ZenCODE
//
//  Bulk setup for associating models and capability values to agents.
//

import Foundation
import ZenCODECore

extension ZenCODEAgentProfileSetupRunner {

    /// Interactive bulk setup: shows every agent and lets the user associate
    /// a dedicated model and a capability value (1–10) to each one.
    /// Agents without a model are left without capability and are excluded
    /// from the delegatable roster passed to the LLM at runtime.
    public static func configureAgentModels() throws {
        guard TerminalRawInput.supportsInteractiveInput() else {
            throw ZenCODEAgentProfileSetupError.nonInteractiveTerminal
        }

        let models = AgentModelCatalogPresentation.sorted(
            AgentSettingsStore.availableModels()
        )
        guard !models.isEmpty else {
            AgentOutput.standardError.writeString(
                "\nNo configured models found. Configure providers and models first.\n\n"
            )
            return
        }

        var agents = try AgentProfileStore.loadRequired()
        AgentOutput.standardError.writeString(
            """

            Agent models & capability
            Assign a model and a capability (1–10) to each agent.
            Agents without a model are excluded from delegation routing.

            """
        )

        while true {
            printAgentModelSummary(agents)

            var items = [
                TerminalCheckboxMenuItem(
                    value: 0,
                    title: "Done",
                    detail: "save and exit"
                )
            ]
            items.append(contentsOf: agents.enumerated().map { index, agent in
                TerminalCheckboxMenuItem(
                    value: index + 1,
                    title: agent.displayName,
                    detail: agentModelSummary(agent),
                    groupTitle: "Configure"
                )
            })

            let choice = TerminalCheckboxMenu.selectOne(
                title: "Agent models & capability",
                items: items,
                selected: 0
            ) ?? 0

            if choice == 0 {
                let normalized = AgentProfileStore.normalizedAgentsForSave(agents)
                try AgentProfileStore.save(normalized)
                AgentOutput.standardError.writeString(
                    "\nUpdated: agents.json (\(normalized.count) agents)\n\n"
                )
                return
            }

            let index = choice - 1
            guard agents.indices.contains(index) else { continue }
            agents[index] = try configureModelForAgent(agents[index], models: models)
        }
    }

    // MARK: - Per-agent configuration

    private static func configureModelForAgent(
        _ agent: AgentProfile,
        models: [AgentSettingsModelManifest]
    ) throws -> AgentProfile {
        let existingModelID = agent.modelID?.nilIfBlank
        let initialChoice = existingModelID.map { modelID in
            models.first(where: { $0.matches(modelID) })
                .map { AgentSetupModelChoice.configuredModel($0.id) }
                ?? .configuredModel(modelID)
        } ?? .noDedicatedModel

        let choice = TerminalCheckboxMenu.selectOne(
            title: "Model for \(agent.displayName)",
            items: modelChoiceItems(models: models, existingModelID: existingModelID),
            selected: initialChoice
        ) ?? initialChoice

        switch choice {
        case .noDedicatedModel:
            return AgentProfile(
                id: agent.id,
                name: agent.name,
                instructions: agent.instructions,
                symbolName: agent.symbolName,
                tools: agent.tools,
                skills: agent.skills,
                modelID: nil,
                modelProvider: nil,
                thinkingSelection: nil,
                capability: nil
            )

        case let .configuredModel(modelID):
            guard let model = models.first(where: { $0.matches(modelID) }) else {
                return agent
            }

            let thinkingSelection = promptThinkingSelection(
                for: model,
                defaultSelection: agent.thinkingSelection
            )

            let defaultCapability = agent.capability ?? 5
            let capability = try promptCapability(
                for: agent.displayName,
                default: defaultCapability
            )

            return AgentProfile(
                id: agent.id,
                name: agent.name,
                instructions: agent.instructions,
                symbolName: agent.symbolName,
                tools: agent.tools,
                skills: agent.skills,
                modelID: model.id,
                modelProvider: modelProviderTitle(for: model),
                thinkingSelection: thinkingSelection,
                capability: capability
            )
        }
    }

    // MARK: - Capability prompt

    private static func promptCapability(
        for agentName: String,
        default defaultValue: Int
    ) throws -> Int {
        AgentOutput.standardError.writeString(
            """

            Capability for \(agentName) (1–10)
            1–3: lightweight model (lookups, simple edits)
            4–6: balanced model (standard implementation)
            7–10: powerful model (complex reasoning, architecture)

            """
        )
        let value = TerminalCheckboxMenu.promptLine(
            title: "Agent models & capability",
            prompt: "Capability",
            defaultValue: "\(defaultValue)",
            allowEmpty: false
        ) ?? "\(defaultValue)"
        let parsed = Int(value) ?? defaultValue
        return min(max(parsed, 1), 10)
    }

    // MARK: - Display

    private static func printAgentModelSummary(_ agents: [AgentProfile]) {
        AgentOutput.standardError.writeString("\n")
        for (index, agent) in agents.enumerated() {
            AgentOutput.standardError.writeString(
                "  \(index + 1). \(agent.displayName) [\(agentModelSummary(agent))]\n"
            )
        }
        AgentOutput.standardError.writeString("\n")
    }

    private static func agentModelSummary(_ agent: AgentProfile) -> String {
        if let modelID = agent.modelID {
            let capability = agent.capability.map { " | capability: \($0)/10" } ?? ""
            return "model: \(modelID)\(capability)"
        }
        return "no model"
    }
}
