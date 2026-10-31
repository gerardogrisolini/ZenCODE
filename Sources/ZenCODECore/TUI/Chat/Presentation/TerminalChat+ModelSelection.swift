//
//  TerminalChat+ModelSelection.swift
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
    /// Adapter of ``ChatSessionController/resolveInitialModel()``.
    public func handleMissingInitialModelSelectionIfNeeded() async throws {
        if let notice = try await chatSession.resolveInitialModel() {
            await writeSessionNotice(notice)
        }
    }

    /// `/models`: adapter of ``ChatSessionController/runModelsCommand(line:)``.
    /// A model applied in place refreshes the status bar
    /// (``selectionDidApply(_:command:)``); a new model's session steps run
    /// through the channel hooks. A failure is written as a notice.
    public func selectModelInteractively() async throws {
        await writeSessionNotices(await chatSession.runModelsCommand().notices)
    }

    /// `/think`: adapter of ``ChatSessionController/runThinkCommand(line:)``.
    public func selectThinkingInteractively() async throws {
        await writeSessionNotices(await chatSession.runThinkCommand().notices)
    }

    public func availableModelManifests() -> [AgentSettingsModelManifest] {
        chatSession.modelCatalog.availableModels()
    }

    /// Returns every configured model. Profile bindings provide a default for
    /// a new session and routing policy for delegated sub-agents; they never
    /// constrain the user's manual `/models` selection.
    public func selectableModelManifests() -> [AgentSettingsModelManifest] {
        availableModelManifests()
    }

    public func selectedAgentModelBinding(
        for model: AgentSettingsModelManifest
    ) -> AgentModelBinding? {
        chatSession.selectedAgentModelBinding(for: model)
    }


    public func promptForModelSelection(
        models: [AgentSettingsModelManifest],
        message: String?
    ) async -> AgentSettingsModelManifest? {
        let choices = chatSession.modelChoices(models, title: message ?? "Available models")
        guard let modelID = await interactionHost.chooseOne(
            title: choices.title,
            items: choices.items,
            selectedID: choices.selectedIDs.first
        ) else {
            return nil
        }
        return models.first { $0.id == modelID }
    }

    public func renderModelList(
        models: [AgentSettingsModelManifest],
        message: String?
    ) async {
        let selectedModelID = currentEffectiveModelID() ?? AgentSettingsStore.selectedModelID()
        if let message {
            await writeSystemMessage("\(message)\n")
        }
        await writeSystemMessage(
            ChatSessionNoticeText.modelListText(models, selectedModelID: selectedModelID)
        )
    }

    public func renderThinkingList(
        model: AgentSettingsModelManifest,
        options: [AgentThinkingSelection],
        selected: AgentThinkingSelection?
    ) async {
        await writeSystemMessage(
            ChatSessionNoticeText.thinkingListText(
                model: model,
                options: options,
                selected: selected
            )
        )
    }

    public func promptForThinkingSelection(
        model: AgentSettingsModelManifest
    ) async -> AgentThinkingSelection? {
        await chatSession.chooseInitialThinking(for: model)
    }

    public func modelSelectionItems(
        _ models: [AgentSettingsModelManifest]
    ) -> [TerminalCheckboxMenuItem<AgentSettingsModelManifest>] {
        ChatSessionController.modelChoiceEntries(models).map { entry in
            TerminalCheckboxMenuItem(
                value: entry.model,
                title: entry.item.title,
                detail: entry.item.detail,
                groupTitle: entry.item.group
            )
        }
    }

    public func thinkingSelectionItems(
        _ options: [AgentThinkingSelection]
    ) -> [TerminalCheckboxMenuItem<AgentThinkingSelection>] {
        options.map { option in
            TerminalCheckboxMenuItem(
                value: option,
                title: option.menuTitle,
                detail: nil
            )
        }
    }

    public func modelThinkingSuffix(
        _ model: AgentSettingsModelManifest
    ) -> String {
        guard let detail = modelThinkingDetail(model) else {
            return ""
        }
        return " [\(detail)]"
    }

    public func modelThinkingDetail(
        _ model: AgentSettingsModelManifest
    ) -> String? {
        guard model.supportsThinking else {
            return nil
        }
        let options = model.availableThinkingSelections
            .map(\.displayTitle)
            .joined(separator: "/")
        guard !options.isEmpty else {
            return nil
        }
        return "thinking: \(options)"
    }

    public func thinkingSuffix(
        _ selection: AgentThinkingSelection?
    ) -> String {
        ChatSessionNoticeText.thinkingSuffix(selection)
    }

    public func preloadCurrentModel(emitStatus: Bool = true) async throws -> String {
        await refreshStatusBarThinkingSelection()
        let loadedModelID = try await sessionRunner.preloadModel(
            configuration: await currentSessionConfiguration()
        ) { @TerminalChatActor event in
            await self.handleModelPreloadEvent(event)
        }
        await finishModelPreload(loadedModelID, emitStatus: emitStatus)
        return loadedModelID
    }

    /// A preload event: the loaded model updates the status bar and is
    /// recorded as printed, so no `loaded model` line follows.
    func handleModelPreloadEvent(_ event: DirectAgentEvent) async {
        switch event {
        case let .modelLoaded(modelID):
            _ = await statusBar.update(modelID: modelID)
            printedModelID = loadedModelDisplayTitle(modelID)
        case .status,
             .diagnostic,
             .thought,
             .metrics,
             .contextWindow,
             .subscriptionUsage,
             .content,
             .toolCallStarted,
             .toolCallCompleted,
             .sessionSnapshot,
             .turnEnded:
            break
        }
    }

    /// The last step of a preload. Without `emitStatus` the loaded model is
    /// recorded as printed even when the backend sent no load event.
    func finishModelPreload(_ loadedModelID: String, emitStatus: Bool) async {
        _ = await statusBar.update(modelID: loadedModelID)
        if !emitStatus {
            printedModelID = loadedModelDisplayTitle(loadedModelID)
        }
    }

    public func printModelIfNeeded(_ modelID: String) async {
        let displayTitle = loadedModelDisplayTitle(modelID)
        guard printedModelID != displayTitle else {
            return
        }
        printedModelID = displayTitle
        await refreshStatusBarThinkingSelection()
        _ = await statusBar.update(modelID: modelID)
        await writeOperationalMessage("ZenCODE loaded model: \(displayTitle)\n")
    }

    public func loadedModelDisplayTitle(_ modelID: String) -> String {
        let trimmedModelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModelID.isEmpty else {
            return modelID
        }

        if let hostedModel = hostedModelManifest(for: modelID) {
            return modelDisplayTitle(hostedModel)
        }

        if let selection = AgentSettingsStore.defaultSelection(
            explicitModelID: currentEffectiveModelID()
        ) {
            switch selection.providerKind {
            case .remoteAPI:
                let providerTitle = selection.remoteProvider?.displayTitle ?? "RemoteAPI"
                return "\(providerTitle) • \(selection.modelID)"
            }
        }

        return trimmedModelID
    }

    public func modelDisplayTitle(_ model: AgentSettingsModelManifest) -> String {
        AgentModelCatalogPresentation.modelTitle(for: model)
    }
}
