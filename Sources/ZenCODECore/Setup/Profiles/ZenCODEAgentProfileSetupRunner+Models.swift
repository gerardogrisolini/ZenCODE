//
//  ZenCODEAgentProfileSetupRunner+Models.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Bulk setup for associating authorized model bindings to agents.
//

import Foundation
import ToolCore

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

    /// Menu values of "Apply binding presets" and "Reset". The bulk menu uses 0
    /// for "Done" and `index + 1` for agents, so a negative value cannot collide.
    private static let applyBindingPresetsChoice = -1
    private static let resetBindingsChoice = -2

    /// Interactive bulk setup for assigning one or more explicitly authorized
    /// model bindings to each agent. Capability and thinking belong to each
    /// binding, not to the profile as a whole.
    @available(*, deprecated, message: "Pass the setup session's currentManifest")
    public static func configureAgentModels() throws {
        try configureAgentModels(
            currentManifest: AgentSettingsManifestStore.loadRequired()
        )
    }

    public static func configureAgentModels(
        currentManifest: AgentSettingsManifest
    ) throws {
        _ = try configureAgentModels(
            currentManifest: currentManifest,
            currentAgents: nil,
            persist: true
        )
    }

    @discardableResult
    static func configureAgentModels(
        currentManifest: AgentSettingsManifest,
        currentAgents: [AgentProfile]?,
        persist: Bool
    ) throws -> [AgentProfile]? {
        guard TerminalRawInput.supportsInteractiveInput() else {
            throw ZenCODEAgentProfileSetupError.nonInteractiveTerminal
        }

        // Setup may have just replaced providers or models in its in-memory
        // session. Do not read settings.json here: it is only written after
        // setup finishes, so reading it would present the previous catalog.
        let models = AgentModelCatalogPresentation.sorted(currentManifest.models)
        guard !models.isEmpty else {
            AgentOutput.standardError.writeString(
                "\nNo configured models found. Configure providers and models first.\n\n"
            )
            return nil
        }

        var agents = try currentAgents ?? AgentProfileStore.loadRequired()
        AgentOutput.standardError.writeString(
            """

            Agent model bindings
            Assign one or more authorized models to each agent. Each binding has its own \
            capability (1–10) and thinking selection. Bindings are optional: agents without \
            a binding use the main session model and provider, including when delegated.

            """
        )

        while true {
            var items = [
                TerminalCheckboxMenuItem(
                    value: 0,
                    title: "Done",
                    detail: "save and exit"
                ),
                TerminalCheckboxMenuItem(
                    value: Self.applyBindingPresetsChoice,
                    title: "Apply binding presets",
                    detail: "replaces all bindings with \(AgentBindingPresets.filename)"
                ),
                TerminalCheckboxMenuItem(
                    value: Self.resetBindingsChoice,
                    title: "Reset",
                    detail: "remove every agent's bindings"
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

            switch TerminalCheckboxMenu.selectOne(
                title: "Agent model bindings",
                items: items,
                selected: 0,
                header: agentModelSummaryLines(agents)
            ) {
            case nil:
                // Esc/EOF: discard unsaved edits and leave without persisting.
                AgentOutput.standardError.writeString(
                    "\nAgent model bindings not saved.\n\n"
                )
                return nil
            case 0?:
                let normalized = AgentProfileStore.normalizedAgentsForSave(agents)
                if persist {
                    try AgentProfileStore.save(normalized)
                }
                AgentOutput.standardError.writeString(
                    persist
                        ? "\nUpdated: agents.json (\(normalized.count) agents)\n\n"
                        : "\nStaged: agents.json (\(normalized.count) agents)\n\n"
                )
                return normalized
            case Self.applyBindingPresetsChoice?:
                agents = applyBindingPresets(
                    to: agents,
                    configuredProviderNames: currentManifest.providers.map(\.displayTitle),
                    selectProviders: Self.selectBindingPresetProviders
                )
            case Self.resetBindingsChoice?:
                agents = resetBindings(of: agents)
            case let choice?:
                let index = choice - 1
                guard agents.indices.contains(index) else { continue }
                agents[index] = try configureModelBindingsForAgent(agents[index], models: models)
            }
        }
    }

    // MARK: - Binding presets

    /// The "Apply binding presets" action: replaces the bindings of the
    /// in-memory agents with the presets of the providers the operator picks
    /// from the configured providers that have a block in the presets file.
    /// Nothing is written to disk here; "Done" stages or saves the result and
    /// Esc discards it.
    ///
    /// The agents are returned unchanged, and a message says why, when no
    /// ZenCODE source checkout is found, when the file is missing or invalid,
    /// or when no configured provider has a block in it; the provider menu is
    /// not shown in those cases.
    ///
    /// Otherwise `selectProviders` receives the configured providers that have
    /// a block, in file order, and returns the ones to use. `nil` (the operator
    /// cancelled) or an empty set leaves the agents unchanged, with a message.
    /// The selected providers apply in file order, not in selection order, so
    /// the file keeps deciding the priority. It has no default so that callers
    /// must choose explicitly and tests never open a real terminal menu.
    static func applyBindingPresets(
        to agents: [AgentProfile],
        configuredProviderNames: [String],
        url: URL? = AgentBindingPresets.defaultURL(),
        selectProviders: ([String]) -> Set<String>?
    ) -> [AgentProfile] {
        guard let url else {
            AgentOutput.standardError.writeString(
                "\nBinding presets unavailable: no ZenCODE source checkout found.\n\n"
            )
            return agents
        }
        let presets: AgentBindingPresets
        do {
            guard let loaded = try AgentBindingPresets.load(from: url) else {
                AgentOutput.standardError.writeString(
                    "\nBinding presets file not found: \(url.path)\n\n"
                )
                return agents
            }
            presets = loaded
        } catch {
            AgentOutput.standardError.writeString(
                "\n\(error.localizedDescription)\n\n"
            )
            return agents
        }

        let providerNames = presets.applicableProviderNames(for: configuredProviderNames)
        guard !providerNames.isEmpty else {
            AgentOutput.standardError.writeString(
                "\nNo configured provider has a block in \(url.path); bindings unchanged.\n\n"
            )
            return agents
        }

        guard let selected = selectProviders(providerNames) else {
            AgentOutput.standardError.writeString(
                "\nBinding presets not applied.\n\n"
            )
            return agents
        }
        // File order decides the priority, whatever the order of the selection.
        let selectedNames = providerNames.filter(selected.contains)
        guard !selectedNames.isEmpty else {
            AgentOutput.standardError.writeString(
                "\nNo provider selected; bindings unchanged.\n\n"
            )
            return agents
        }

        let updated = presets.applying(
            to: agents,
            configuredProviderNames: selectedNames
        )
        AgentOutput.standardError.writeString(
            "\nApplied binding presets from \(url.path) "
                + "(\(selectedNames.joined(separator: ", "))): "
                + "\(AgentBindingPresets.outcomeDescription(for: updated)).\n\n"
        )
        return updated
    }

    /// The provider menu of "Apply binding presets": a multi-selection checkbox
    /// menu of the given provider names, all checked at first, so Enter alone
    /// uses every one of them. Returns the checked names, or `nil` when the
    /// operator cancels with Esc.
    private static func selectBindingPresetProviders(_ names: [String]) -> Set<String>? {
        TerminalCheckboxMenu.select(
            title: "Binding presets providers",
            items: names.map { TerminalCheckboxMenuItem(value: $0, title: $0, detail: nil) },
            selected: Set(names)
        )
    }

    /// The "Reset" action: removes every binding and every default binding from
    /// the in-memory agents, whatever their source; everything else in the
    /// profiles is untouched. It acts at once, with no confirmation, and writes
    /// nothing to disk: "Done" stages or saves the result and Esc discards it.
    static func resetBindings(of agents: [AgentProfile]) -> [AgentProfile] {
        let removed = AgentBindingPresets.outcomeDescription(for: agents)
        let updated = agents.map {
            profile(basedOn: $0, modelBindings: [], defaultModelBindingID: nil)
        }
        AgentOutput.standardError.writeString(
            "\nReset model bindings: removed \(removed).\n\n"
        )
        return updated
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

    /// Bindings table shown inside the "Agent model bindings" menu frame.
    /// The menu may own the alternate screen, so a table printed beforehand
    /// would only be reachable by scrolling back. The frame consumes four
    /// columns (borders and padding); the table renderer reserves one more.
    private static func agentModelSummaryLines(_ agents: [AgentProfile]) -> [String] {
        let frameColumns = TerminalCheckboxMenu.terminalGeometry().columns
        let table = TerminalChat.renderAgentModelBindingsTable(
            agents: agents,
            selectedAgent: nil,
            columns: max(1, frameColumns - 3)
        )
        var lines = table.components(separatedBy: "\n")
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true {
            lines.removeLast()
        }
        return lines
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
        let modelName = ModelNamePresentation.strippedModelNameForBinding(
            binding.modelID,
            modelProvider: binding.modelProvider
        )
        return binding.modelProvider.map { "\($0) / \(modelName)" } ?? modelName
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
