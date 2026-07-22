//
//  ZenCODEAgentProfileSetupRunner+Models.swift
//  ZenCODE
//
//  Bulk setup for associating authorized model bindings to agents.
//

import Foundation
import ZenCODECore

extension ZenCODEAgentProfileSetupRunner {
    private enum AgentModelBindingMenuAction: Hashable {
        case done
        case add
        case edit(String)
    }

    private enum AgentModelBindingEditAction: Hashable {
        case edit
        case makeDefault
        case remove
    }

    /// Interactive bulk setup for assigning one or more explicitly authorized
    /// model bindings to each agent. Capability and thinking belong to each
    /// binding, not to the profile as a whole.
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

            Agent model bindings
            Assign one or more authorized models to each agent. Each binding has its own \
            capability (1–10) and thinking selection. Agents without a binding remain \
            selectable but are excluded from dedicated-model delegation routing.

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
                title: "Agent model bindings",
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
            agents[index] = try configureModelBindingsForAgent(agents[index], models: models)
        }
    }

    // MARK: - Per-agent binding configuration

    private static func configureModelBindingsForAgent(
        _ initialAgent: AgentProfile,
        models: [AgentSettingsModelManifest]
    ) throws -> AgentProfile {
        var agent = initialAgent

        while true {
            var items: [TerminalCheckboxMenuItem<AgentModelBindingMenuAction>] = [
                TerminalCheckboxMenuItem(
                    value: .done,
                    title: "Done",
                    detail: "keep the current bindings"
                ),
                TerminalCheckboxMenuItem(
                    value: .add,
                    title: "Add model binding",
                    detail: "authorize another model for this agent",
                    groupTitle: "Actions"
                )
            ]
            items.append(contentsOf: agent.modelBindings.map { binding in
                TerminalCheckboxMenuItem(
                    value: .edit(binding.id),
                    title: bindingDisplayTitle(binding),
                    detail: bindingDetail(binding, agent: agent),
                    groupTitle: "Bindings"
                )
            })

            let action = TerminalCheckboxMenu.selectOne(
                title: "Model bindings for \(agent.displayName)",
                items: items,
                selected: .done
            ) ?? .done

            switch action {
            case .done:
                return agent

            case .add:
                guard let binding = try promptModelBinding(
                    for: agent,
                    existingBinding: nil,
                    models: models
                ) else {
                    continue
                }
                var bindings = agent.modelBindings
                bindings.append(binding)
                let defaultBindingID = agent.defaultModelBindingID ?? binding.id
                agent = profile(
                    basedOn: agent,
                    modelBindings: bindings,
                    defaultModelBindingID: defaultBindingID
                )

            case let .edit(bindingID):
                guard let binding = agent.modelBindings.first(where: { $0.id == bindingID }) else {
                    continue
                }
                agent = try editModelBinding(
                    binding,
                    for: agent,
                    models: models
                )
            }
        }
    }

    private static func editModelBinding(
        _ binding: AgentModelBinding,
        for agent: AgentProfile,
        models: [AgentSettingsModelManifest]
    ) throws -> AgentProfile {
        let actions: [TerminalCheckboxMenuItem<AgentModelBindingEditAction>] = [
            TerminalCheckboxMenuItem(
                value: .edit,
                title: "Edit binding",
                detail: "change model, thinking, or capability"
            ),
            TerminalCheckboxMenuItem(
                value: .makeDefault,
                title: "Make default",
                detail: binding.id == agent.defaultModelBindingID
                    ? "current default"
                    : "use this binding when no model is specified"
            ),
            TerminalCheckboxMenuItem(
                value: .remove,
                title: "Remove binding",
                detail: "the model will no longer be available to this agent"
            )
        ]
        let action = TerminalCheckboxMenu.selectOne(
            title: bindingDisplayTitle(binding),
            items: actions,
            selected: .edit
        ) ?? .edit

        switch action {
        case .edit:
            guard let updatedBinding = try promptModelBinding(
                for: agent,
                existingBinding: binding,
                models: models
            ) else {
                let remainingBindings = agent.modelBindings.filter { $0.id != binding.id }
                return profile(
                    basedOn: agent,
                    modelBindings: remainingBindings,
                    defaultModelBindingID: agent.defaultModelBindingID == binding.id
                        ? nil
                        : agent.defaultModelBindingID
                )
            }
            let bindings = agent.modelBindings.map {
                $0.id == binding.id ? updatedBinding : $0
            }
            return profile(
                basedOn: agent,
                modelBindings: bindings,
                defaultModelBindingID: agent.defaultModelBindingID
            )

        case .makeDefault:
            return profile(
                basedOn: agent,
                modelBindings: agent.modelBindings,
                defaultModelBindingID: binding.id
            )

        case .remove:
            let remainingBindings = agent.modelBindings.filter { $0.id != binding.id }
            return profile(
                basedOn: agent,
                modelBindings: remainingBindings,
                defaultModelBindingID: agent.defaultModelBindingID == binding.id
                    ? nil
                    : agent.defaultModelBindingID
            )
        }
    }

    private static func promptModelBinding(
        for agent: AgentProfile,
        existingBinding: AgentModelBinding?,
        models: [AgentSettingsModelManifest]
    ) throws -> AgentModelBinding? {
        let existingModelID = existingBinding?.modelID.nilIfBlank
        let unavailableBindingIDs = Set(
            agent.modelBindings
                .filter { $0.id != existingBinding?.id }
                .map { $0.modelID.lowercased() }
        )
        let selectableModels = models.filter { model in
            !unavailableBindingIDs.contains(model.id.lowercased())
                && !unavailableBindingIDs.contains(model.modelID.lowercased())
                && !unavailableBindingIDs.contains(model.llmID?.lowercased() ?? "")
        }
        let initialChoice = existingModelID.map { modelID in
            selectableModels.first(where: { $0.matches(modelID) })
                .map { AgentSetupModelChoice.configuredModel($0.id) }
                ?? .configuredModel(modelID)
        } ?? .noDedicatedModel
        let choice = TerminalCheckboxMenu.selectOne(
            title: existingBinding == nil
                ? "Model for \(agent.displayName)"
                : "Model for \(bindingDisplayTitle(existingBinding!))",
            items: modelChoiceItems(models: selectableModels, existingModelID: existingModelID),
            selected: initialChoice
        ) ?? initialChoice

        switch choice {
        case .noDedicatedModel:
            return nil

        case let .configuredModel(modelID):
            guard let model = models.first(where: { $0.matches(modelID) }) else {
                return existingBinding
            }
            let thinkingSelection = promptThinkingSelection(
                for: model,
                defaultSelection: existingBinding?.thinkingSelection
            )
            let capability = try promptCapability(
                for: "\(agent.displayName) / \(AgentModelCatalogPresentation.modelTitle(for: model))",
                default: existingBinding?.capability ?? 5
            )
            return AgentModelBinding(
                id: existingBinding?.id ?? model.id,
                modelID: model.id,
                modelProvider: modelProviderTitle(for: model),
                thinkingSelection: thinkingSelection,
                capability: capability
            )
        }
    }

    static func profile(
        basedOn agent: AgentProfile,
        modelBindings: [AgentModelBinding],
        defaultModelBindingID: String?
    ) -> AgentProfile {
        AgentProfile(
            id: agent.id,
            name: agent.name,
            instructions: agent.instructions,
            symbolName: agent.symbolName,
            tools: agent.tools,
            skills: agent.skills,
            modelBindings: modelBindings,
            defaultModelBindingID: defaultModelBindingID
        )
    }

    // MARK: - Capability prompt

    private static func promptCapability(
        for bindingName: String,
        default defaultValue: Int
    ) throws -> Int {
        AgentOutput.standardError.writeString(
            """

            Capability for \(bindingName) (1–10)
            1–3: lightweight model (lookups, simple edits)
            4–6: balanced model (standard implementation)
            7–10: powerful model (complex reasoning, architecture)

            """
        )
        let value = TerminalCheckboxMenu.promptLine(
            title: "Agent model bindings",
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
        for agent in agents {
            let lines = TerminalChat.renderAgentModelBindings(for: agent, selectedAgent: nil)
            AgentOutput.standardError.writeString(lines.joined(separator: "\n") + "\n")
        }
        AgentOutput.standardError.writeString("\n")
    }

    static func agentModelSummary(_ agent: AgentProfile) -> String {
        guard !agent.modelBindings.isEmpty else {
            return "no dedicated model bindings"
        }
        let defaultBindingID = agent.defaultModelBinding?.id
        let models = agent.modelBindings.map { binding in
            let marker = binding.id == defaultBindingID ? "[default] " : ""
            return "\(marker)\(bindingDisplayTitle(binding))"
        }
        return "\(agent.modelBindings.count) binding\(agent.modelBindings.count == 1 ? "" : "s") | models: \(models.joined(separator: ", "))"
    }

    static func bindingDisplayTitle(_ binding: AgentModelBinding) -> String {
        binding.modelProvider.map { "\($0) / \(binding.modelID)" } ?? binding.modelID
    }

    static func bindingDetail(
        _ binding: AgentModelBinding,
        agent: AgentProfile
    ) -> String {
        var values = [
            binding.capability.map { "capability: \($0)/10" } ?? "capability: unset"
        ]
        if let thinkingSelection = binding.thinkingSelection {
            values.append("thinking: \(thinkingSelection.displayTitle)")
        }
        if binding.id == agent.defaultModelBindingID {
            values.append("default")
        }
        return values.joined(separator: " · ")
    }
}
