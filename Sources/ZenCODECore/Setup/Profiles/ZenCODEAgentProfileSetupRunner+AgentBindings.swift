//
//  ZenCODEAgentProfileSetupRunner+AgentBindings.swift
//  ZenCODE
//
//  Per-agent configuration of the model bindings: the binding menu, editing,
//  the binding prompt and its capability question.
//

import Foundation
import ToolCore
import ZenCODERuntime

extension ZenCODEAgentProfileSetupRunner {
    // MARK: - Per-agent binding configuration

    /// The "Model bindings for <agent>" menu. Done returns the agent with the
    /// changes of this visit; Esc discards them and returns the agent as it
    /// was, back in the "Agent model bindings" menu. Esc while adding or
    /// editing a binding returns to this menu with that binding unchanged.
    /// `selectAction`, `promptBinding` (Add model binding) and `editBinding`
    /// (the action menu of a binding) replace the terminal in tests.
    static func configureModelBindingsForAgent(
        _ initialAgent: AgentProfile,
        models: [AgentSettingsModelManifest],
        write: (String) -> Void = { AgentOutput.standardError.writeString($0) },
        selectAction: (
            String,
            [TerminalCheckboxMenuItem<AgentModelBindingMenuAction>],
            AgentModelBindingMenuAction
        ) -> AgentModelBindingMenuAction? = {
            TerminalCheckboxMenu.selectOne(title: $0, items: $1, selected: $2)
        },
        promptBinding: (
            AgentProfile,
            [AgentSettingsModelManifest]
        ) throws -> AgentModelBinding? = {
            try promptModelBinding(for: $0, existingBinding: nil, models: $1)
        },
        editBinding: (
            AgentModelBinding,
            AgentProfile,
            [AgentSettingsModelManifest]
        ) throws -> AgentProfile? = {
            try editModelBinding($0, for: $1, models: $2)
        }
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

            guard let action = selectAction(
                "Model bindings for \(agent.displayName)",
                items,
                .done
            ) else {
                write("\nModel bindings for \(initialAgent.displayName) cancelled; changes not saved.\n\n")
                return initialAgent
            }

            switch action {
            case .done:
                return agent

            case .add:
                let currentAgent = agent
                let prompted = try ZenCODESetupRunner.returningToMenuOnCancel(
                    "Add model binding cancelled.",
                    write: write,
                    { try promptBinding(currentAgent, models) }
                )
                // `nil` (Esc) or `.some(nil)` ("No dedicated model"): nothing to add.
                guard let binding = prompted ?? nil else {
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
                let currentAgent = agent
                let edited = try ZenCODESetupRunner.returningToMenuOnCancel(
                    "Edit binding cancelled.",
                    write: write,
                    { try editBinding(binding, currentAgent, models) }
                )
                // `nil` (Esc in Edit binding) or `.some(nil)` (Esc on the
                // action menu): the binding stays as it was.
                if let updatedAgent = edited ?? nil {
                    agent = updatedAgent
                }
            }
        }
    }

    /// The action menu of one binding: Edit binding, Make default, Remove
    /// binding. Returns the agent with the action applied, or `nil` when the
    /// operator leaves the menu with Esc: the binding is then unchanged.
    /// Esc inside Edit binding throws `ZenCODESetupError.cancelled`, again
    /// with the binding unchanged; choosing "No dedicated model" there removes
    /// it. `selectAction` and `promptBinding` replace the terminal in tests.
    static func editModelBinding(
        _ binding: AgentModelBinding,
        for agent: AgentProfile,
        models: [AgentSettingsModelManifest],
        selectAction: (
            String,
            [TerminalCheckboxMenuItem<AgentModelBindingEditAction>],
            AgentModelBindingEditAction
        ) -> AgentModelBindingEditAction? = {
            TerminalCheckboxMenu.selectOne(title: $0, items: $1, selected: $2)
        },
        promptBinding: (
            AgentProfile,
            AgentModelBinding,
            [AgentSettingsModelManifest]
        ) throws -> AgentModelBinding? = {
            try promptModelBinding(for: $0, existingBinding: $1, models: $2)
        }
    ) throws -> AgentProfile? {
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
        guard let action = selectAction(
            bindingDisplayTitle(binding),
            actions,
            .edit
        ) else {
            return nil
        }

        switch action {
        case .edit:
            guard let updatedBinding = try promptBinding(agent, binding, models) else {
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

    /// Model, thinking and capability of a new or edited binding. Returns
    /// `nil` when the operator chooses "No dedicated model". Esc on any of the
    /// three prompts throws `ZenCODESetupError.cancelled`: unlike `nil`, it
    /// never removes an edited binding.
    static func promptModelBinding(
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
        guard let choice = TerminalCheckboxMenu.selectOne(
            title: existingBinding == nil
                ? "Model for \(agent.displayName)"
                : "Model for \(bindingDisplayTitle(existingBinding!))",
            items: modelChoiceItems(models: selectableModels, existingModelID: existingModelID),
            selected: initialChoice
        ) else {
            throw ZenCODESetupError.cancelled
        }

        switch choice {
        case .noDedicatedModel:
            return nil

        case let .configuredModel(modelID):
            guard let model = models.first(where: { $0.matches(modelID) }) else {
                return existingBinding
            }
            let thinkingSelection = try promptThinkingSelection(
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
            readOnly: agent.readOnly,
            role: agent.role,
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
        guard let value = TerminalCheckboxMenu.promptLine(
            title: "Agent model bindings",
            prompt: "Capability",
            defaultValue: "\(defaultValue)",
            allowEmpty: false
        ) else {
            throw ZenCODESetupError.cancelled
        }
        let parsed = Int(value) ?? defaultValue
        return min(max(parsed, 1), 10)
    }
}
