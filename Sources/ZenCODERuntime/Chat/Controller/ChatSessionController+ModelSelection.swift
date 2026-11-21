//
//  ChatSessionController+ModelSelection.swift
//  ZenCODE
//
//  Model selection: the model menu, `/models`, and the model a session
//  starts with.
//

import Foundation

extension ChatSessionController {
    // MARK: - Models

    /// The model menu: every available model, grouped by provider, the
    /// current one selected.
    func modelChoices() -> ChatChoiceList {
        modelChoices(modelCatalog.sortedModels(), title: "Available models")
    }

    func modelChoices(
        _ models: [AgentSettingsModelManifest],
        title: String
    ) -> ChatChoiceList {
        let selectedModel = ChatModelCatalog.model(
            matching: menuSelectedModelID(),
            in: models
        )
        return ChatChoiceList(
            title: title,
            items: Self.modelChoiceEntries(models).map(\.item),
            selectedIDs: selectedModel.map { [$0.id] } ?? []
        )
    }

    /// The menu entries of `models`, grouped by provider in presentation
    /// order, each with the model it stands for.
    nonisolated static func modelChoiceEntries(
        _ models: [AgentSettingsModelManifest]
    ) -> [(model: AgentSettingsModelManifest, item: ChatChoiceItem)] {
        ChatModelCatalog.providerGroups(models).flatMap { group in
            group.models.map { model in
                (
                    model: model,
                    item: ChatChoiceItem(
                        id: model.id,
                        title: AgentModelCatalogPresentation.modelTitle(for: model, in: group),
                        group: group.title
                    )
                )
            }
        }
    }

    /// The model a menu starts on: the session's model, or the configured
    /// selection.
    private func menuSelectedModelID() -> String? {
        currentEffectiveModelID() ?? AgentSettingsStore.selectedModelID()
    }

    /// `/models`: asks the host for a model and applies it.
    public func chooseModel() async throws -> ChatSelectionOutcome {
        let models = modelCatalog.sortedModels()
        guard !models.isEmpty else {
            throw TerminalChatError.noConfiguredModels
        }
        guard host.capabilities.contains(.singleChoice) else {
            return ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(
                    .modelSelection(models: models, selectedModelID: menuSelectedModelID())
                ),
            ])
        }

        let choices = modelChoices(models, title: "Available models")
        guard let modelID = await host.chooseOne(
            title: choices.title,
            items: choices.items,
            selectedID: choices.selectedIDs.first
        ) else {
            return ChatSelectionOutcome(notices: [.modelUnchanged])
        }
        return try await selectModel(id: modelID)
    }

    /// Makes `modelID` the session's model and the user's default.
    ///
    /// The thinking level comes from the selected agent's binding for the
    /// model, or stays the current one when the model does not change. The
    /// same model updates the session in place; another model stops the
    /// backend, creates the session anew, and loads the model.
    public func selectModel(id modelID: String) async throws -> ChatSelectionOutcome {
        let models = modelCatalog.sortedModels()
        guard !models.isEmpty else {
            throw TerminalChatError.noConfiguredModels
        }
        guard let selectedModel = models.first(where: { $0.id == modelID })
            ?? ChatModelCatalog.model(matching: modelID, in: models) else {
            throw ChatSelectionError.unknownModel(modelID)
        }

        let previousEffectiveModelID = currentEffectiveModelID()
        let previousThinkingSelection = currentAgentThinkingSelection()
        let keepsModel = previousEffectiveModelID.map(selectedModel.matches) == true
        let selectedThinkingSelection = selectedModel.thinkingSelection(
            for: selectedAgentModelBinding(for: selectedModel)?.thinkingSelection
                ?? (keepsModel ? previousThinkingSelection : nil)
        )
        try modelCatalog.saveModelSelection(
            modelID: selectedModel.id,
            thinking: selectedThinkingSelection
        )
        savedSessionState.systemPromptOverride = nil
        selection.modelIDOverride = selectedModel.id
        selection.thinkingOverride = selectedThinkingSelection
        await presentSessionStateChanged()

        if keepsModel {
            try await updateRuntimeSessionOptions()
            return ChatSelectionOutcome(change: .sessionUpdated)
        }

        await managementRuntime?.shutdownBackendKeepingExternalTools()
        try await recreateSession(reason: .modelChanged)
        return ChatSelectionOutcome(change: .sessionRecreated)
    }

    /// Picks a model when the session starts without one: the only
    /// configured model, or one the host asks for together with its thinking
    /// level. Returns the notice to present, or `nil` when the session
    /// already has a model. Nothing is persisted.
    public func resolveInitialModel() async throws -> ChatSessionNotice? {
        guard currentEffectiveModelID() == nil else {
            return nil
        }

        let models = modelCatalog.sortedModels()
        guard !models.isEmpty else {
            throw TerminalChatError.noConfiguredModels
        }

        if models.count == 1,
           let model = models.first {
            let thinkingSelection = model.thinkingSelection(
                for: selectedAgentModelBinding(for: model)?.thinkingSelection
            )
            selection.modelIDOverride = model.id
            selection.thinkingOverride = thinkingSelection
            await presentSessionStateChanged()
            return .modelSelected(model, thinking: thinkingSelection)
        }

        let choices = modelChoices(models, title: "No model selected for ZenCODE.")
        guard host.capabilities.contains(.singleChoice),
              let modelID = await host.chooseOne(
                  title: choices.title,
                  items: choices.items,
                  selectedID: choices.selectedIDs.first
              ),
              let model = models.first(where: { $0.id == modelID }) else {
            throw TerminalChatError.modelSelectionRequired
        }

        let thinkingSelection = await chooseInitialThinking(for: model)
        selection.modelIDOverride = model.id
        selection.thinkingOverride = thinkingSelection
        await presentSessionStateChanged()
        return .modelSelected(model, thinking: thinkingSelection)
    }
}
