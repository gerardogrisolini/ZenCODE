//
//  ChatSessionController+ThinkingSelection.swift
//  ZenCODE
//
//  Thinking-level selection: the thinking menu, `/think`, and the level
//  chosen when the session starts.
//

import Foundation

extension ChatSessionController {
    // MARK: - Thinking

    private enum ThinkingMenuState {
        case unavailable(ChatSessionNotice)
        case available(
            model: AgentSettingsModelManifest,
            options: [AgentThinkingSelection],
            selected: AgentThinkingSelection?
        )
    }

    /// The thinking menu of the current model; `nil` without a current model
    /// or when its thinking is not configurable.
    func thinkingChoices() throws -> ChatChoiceList? {
        guard case let .available(choices) = try thinkingMenu() else {
            return nil
        }
        return choices
    }

    /// The thinking menu of the current model, or the notice that says why
    /// there is none (``ChatSessionNotice/noCurrentModel``,
    /// ``ChatSessionNotice/thinkingNotSupported(model:)``), as `/think`
    /// answers. Throws when no model is configured.
    func thinkingMenu() throws -> ChatChoiceMenuState {
        switch try thinkingMenuState() {
        case let .unavailable(notice):
            return .unavailable(notice)
        case let .available(model, options, selected):
            return .available(thinkingChoices(for: model, options: options, selected: selected))
        }
    }

    /// The ID of the model whose levels ``thinkingMenu()`` lists; `nil` when
    /// it lists none. Throws when no model is configured.
    func thinkingMenuModelID() throws -> String? {
        guard case let .available(model, _, _) = try thinkingMenuState() else {
            return nil
        }
        return model.id
    }

    private func thinkingChoices(
        for model: AgentSettingsModelManifest,
        options: [AgentThinkingSelection],
        selected: AgentThinkingSelection?
    ) -> ChatChoiceList {
        ChatChoiceList(
            title: "Thinking / effort for \(AgentModelCatalogPresentation.modelTitle(for: model))",
            items: options.map { option in
                ChatChoiceItem(id: option.rawValue, title: option.menuTitle)
            },
            selectedIDs: selected.map { [$0.rawValue] } ?? []
        )
    }

    private func thinkingMenuState() throws -> ThinkingMenuState {
        let models = modelCatalog.sortedModels()
        guard !models.isEmpty else {
            throw TerminalChatError.noConfiguredModels
        }

        let effectiveModelID = currentEffectiveModelID()
            ?? AgentSettingsStore.selectedModelID()
        guard let currentModel = ChatModelCatalog.model(
            matching: effectiveModelID,
            in: models
        ) else {
            return .unavailable(.noCurrentModel)
        }

        let options = ChatModelCatalog.thinkingOptions(for: currentModel)
        guard !options.isEmpty else {
            return .unavailable(.thinkingNotSupported(model: currentModel))
        }
        return .available(
            model: currentModel,
            options: options,
            selected: defaultThinkingMenuSelection(for: currentModel)
        )
    }

    /// The level a thinking menu starts on: the configured level (the
    /// session's own one when the host supplies the models), else the
    /// model's default.
    private func defaultThinkingMenuSelection(
        for model: AgentSettingsModelManifest
    ) -> AgentThinkingSelection? {
        let currentSelection = model.thinkingSelection(
            for: modelCatalog.persistsSelections
                ? AgentSettingsStore.selectedThinkingSelection()
                : selection.thinkingOverride
        )
        return currentSelection ?? model.resolvedDefaultThinkingSelection
    }

    /// `/think`: asks the host for a thinking level of the current model and
    /// applies it.
    public func chooseThinking() async throws -> ChatSelectionOutcome {
        let model: AgentSettingsModelManifest
        let options: [AgentThinkingSelection]
        let selected: AgentThinkingSelection?
        switch try thinkingMenuState() {
        case let .unavailable(notice):
            return ChatSelectionOutcome(notices: [notice])
        case let .available(currentModel, currentOptions, currentSelection):
            model = currentModel
            options = currentOptions
            selected = currentSelection
        }
        guard host.capabilities.contains(.singleChoice) else {
            return ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(
                    .thinkingSelection(model: model, options: options, selected: selected)
                ),
            ])
        }

        let choices = thinkingChoices(for: model, options: options, selected: selected)
        guard let thinkingID = await host.chooseOne(
            title: choices.title,
            items: choices.items,
            selectedID: choices.selectedIDs.first
        ), let thinkingSelection = options.first(where: { $0.rawValue == thinkingID }) else {
            return ChatSelectionOutcome(notices: [.thinkingUnchanged])
        }
        return try await selectThinking(thinkingSelection)
    }

    /// Makes `thinkingSelection` the session's thinking level and the user's
    /// default, updating the session in place.
    public func selectThinking(
        _ thinkingSelection: AgentThinkingSelection
    ) async throws -> ChatSelectionOutcome {
        try modelCatalog.saveThinkingSelection(thinkingSelection)
        selection.thinkingOverride = thinkingSelection
        await presentSessionStateChanged()
        try await updateRuntimeSessionOptions()
        return ChatSelectionOutcome(change: .sessionUpdated)
    }

    /// The thinking level for a model chosen at startup; a cancelled menu
    /// keeps the default level.
    public func chooseInitialThinking(
        for model: AgentSettingsModelManifest
    ) async -> AgentThinkingSelection? {
        let options = ChatModelCatalog.thinkingOptions(for: model)
        guard !options.isEmpty else {
            return nil
        }

        let defaultSelection = defaultThinkingMenuSelection(for: model)
        let choices = thinkingChoices(for: model, options: options, selected: defaultSelection)
        guard let thinkingID = await host.chooseOne(
            title: choices.title,
            items: choices.items,
            selectedID: choices.selectedIDs.first
        ) else {
            return defaultSelection
        }
        return options.first { $0.rawValue == thinkingID } ?? defaultSelection
    }
}
