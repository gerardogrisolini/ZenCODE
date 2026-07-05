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
    public func handleMissingInitialModelSelectionIfNeeded() throws {
        guard currentEffectiveModelID() == nil,
              AgentSettingsStore.selectedModelID() == nil else {
            return
        }

        let models = AgentModelCatalogPresentation.sorted(
            availableModelManifests()
        )
        guard !models.isEmpty else {
            throw TerminalChatError.noConfiguredModels
        }

        if models.count == 1,
           let model = models.first {
            let thinkingSelection = model.resolvedDefaultThinkingSelection
            manualModelIDOverride = model.id
            manualThinkingSelectionOverride = thinkingSelection
            writeSystemMessage(
                "Selected model: \(modelDisplayTitle(model))\(thinkingSuffix(thinkingSelection))\n"
            )
            return
        }

        guard stdinIsTerminal,
              let model = promptForModelSelection(
                  models: models,
                  message: "No model selected for ZenCODE."
              ) else {
            throw TerminalChatError.modelSelectionRequired
        }

        let thinkingSelection = promptForThinkingSelection(model: model)
        manualModelIDOverride = model.id
        manualThinkingSelectionOverride = thinkingSelection
        writeSystemMessage(
            "Selected model: \(modelDisplayTitle(model))\(thinkingSuffix(thinkingSelection))\n"
        )
    }

    public func selectModelInteractively() async throws {
        let models = AgentModelCatalogPresentation.sorted(
            availableModelManifests()
        )
        guard !models.isEmpty else {
            throw TerminalChatError.noConfiguredModels
        }
        guard stdinIsTerminal else {
            renderModelList(models: models, message: nil)
            writeSystemMessage("Model selection requires an interactive terminal.\n")
            return
        }

        let previousEffectiveModelID = currentEffectiveModelID()
        let previousThinkingSelection = currentAgentThinkingSelection()
        guard let selectedModel = promptForModelSelection(
            models: models,
            message: nil
        ) else {
            writeSystemMessage("Model unchanged.\n")
            return
        }

        let selectedThinkingSelection = selectedModel.thinkingSelection(
            for: previousThinkingSelection
        )
        if configuration.hostedModels == nil {
            try AgentSettingsManifestStore.saveSelectedModel(
                modelID: selectedModel.id,
                thinkingSelection: selectedThinkingSelection
            )
        }
        activeSessionSystemPromptOverride = nil
        manualModelIDOverride = selectedModel.id
        manualThinkingSelectionOverride = selectedThinkingSelection

        if previousEffectiveModelID.map(selectedModel.matches) == true {
            let allowedToolNames = await selectedAllowedToolNames()
            try await sessionRunner.updateSessionOptions(
                configuration: currentSessionConfiguration(
                    allowedToolNames: allowedToolNames
                )
            )
            statusBar.reset()
            refreshInitialStatusBarContextWindow()
            if previousThinkingSelection == selectedThinkingSelection {
                return
            }
            return
        }

        await sessionRunner.shutdownBackendKeepingExternalTools()
        printedModelID = nil
        statusBar.reset()
        try await createCurrentSession()
        refreshInitialStatusBarContextWindow()
        _ = try await preloadCurrentModel(emitStatus: configuration.hostedModels != nil)
    }

    public func selectThinkingInteractively() async throws {
        let models = AgentModelCatalogPresentation.sorted(
            availableModelManifests()
        )
        guard !models.isEmpty else {
            throw TerminalChatError.noConfiguredModels
        }

        let effectiveModelID = currentEffectiveModelID()
            ?? AgentSettingsStore.selectedModelID()
        guard let currentModel = effectiveModelID.flatMap({ modelID in
            models.first { $0.matches(modelID) }
        }) else {
            writeSystemMessage("No current model selected. Use /models to choose a model first.\n")
            return
        }

        let options = currentModel.availableThinkingSelections
        guard !options.isEmpty else {
            writeSystemMessage(
                "\(modelDisplayTitle(currentModel)) does not support configurable thinking.\n"
            )
            return
        }

        let previousThinkingSelection = currentAgentThinkingSelection()
        let currentSelection = currentModel.thinkingSelection(
            for: configuration.hostedModels == nil
                ? AgentSettingsStore.selectedThinkingSelection()
                : manualThinkingSelectionOverride
        )
        let defaultSelection = currentSelection ?? currentModel.resolvedDefaultThinkingSelection
        guard stdinIsTerminal else {
            renderThinkingList(
                model: currentModel,
                options: options,
                selected: defaultSelection
            )
            writeSystemMessage("Thinking selection requires an interactive terminal.\n")
            return
        }

        guard let selectedThinkingSelection = TerminalCheckboxMenu.selectOne(
            title: "Thinking / effort for \(modelDisplayTitle(currentModel))",
            items: thinkingSelectionItems(options),
            selected: defaultSelection,
            reservedBottomRows: statusBar.reservedRowsForOverlay()
        ) else {
            writeSystemMessage("Thinking unchanged.\n")
            return
        }

        if configuration.hostedModels == nil {
            try AgentSettingsManifestStore.saveSelectedThinkingSelection(
                selectedThinkingSelection
            )
        }
        manualThinkingSelectionOverride = selectedThinkingSelection

        let allowedToolNames = await selectedAllowedToolNames()
        try await sessionRunner.updateSessionOptions(
            configuration: currentSessionConfiguration(
                allowedToolNames: allowedToolNames
            )
        )
        refreshStatusBarThinkingSelection()

        if previousThinkingSelection == selectedThinkingSelection {
            return
        }
    }

    public func availableModelManifests() -> [AgentSettingsModelManifest] {
        configuration.hostedModels ?? AgentSettingsStore.availableModels()
    }


    public func promptForModelSelection(
        models: [AgentSettingsModelManifest],
        message: String?
    ) -> AgentSettingsModelManifest? {
        let selectedModelID = currentEffectiveModelID() ?? AgentSettingsStore.selectedModelID()
        let selectedModel = selectedModelID.flatMap { modelID in
            models.first { $0.matches(modelID) }
        }
        return TerminalCheckboxMenu.selectOne(
            title: message ?? "Available models",
            items: modelSelectionItems(models),
            selected: selectedModel,
            reservedBottomRows: statusBar.reservedRowsForOverlay()
        )
    }

    public func renderModelList(
        models: [AgentSettingsModelManifest],
        message: String?
    ) {
        let selectedModelID = currentEffectiveModelID() ?? AgentSettingsStore.selectedModelID()
        if let message {
            writeSystemMessage("\(message)\n")
        }
        writeSystemMessage("\nAvailable models:\n")
        var offset = 1
        for group in AgentModelCatalogPresentation.groupedByProvider(models) {
            writeSystemMessage("  \(group.title):\n")
            for model in group.models {
                let marker = selectedModelID.map(model.matches) == true ? " *" : ""
                let title = AgentModelCatalogPresentation.modelTitle(for: model, in: group)
                writeSystemMessage(
                    "    \(offset). \(title)\(marker)\n"
                )
                offset += 1
            }
        }
        writeSystemMessage("\n")
    }

    public func renderThinkingList(
        model: AgentSettingsModelManifest,
        options: [AgentThinkingSelection],
        selected: AgentThinkingSelection?
    ) {
        writeSystemMessage("\nThinking levels for \(modelDisplayTitle(model)):\n")
        for (offset, option) in options.enumerated() {
            let marker = option == selected ? " *" : ""
            writeSystemMessage(
                "  \(offset + 1). \(option.menuTitle)\(marker)\n"
            )
        }
        writeSystemMessage("\n")
    }

    public func promptForThinkingSelection(
        model: AgentSettingsModelManifest
    ) -> AgentThinkingSelection? {
        let options = model.availableThinkingSelections
        guard !options.isEmpty else {
            return nil
        }

        let currentSelection = model.thinkingSelection(
            for: configuration.hostedModels == nil
                ? AgentSettingsStore.selectedThinkingSelection()
                : manualThinkingSelectionOverride
        )
        let defaultSelection = currentSelection ?? model.resolvedDefaultThinkingSelection
        return TerminalCheckboxMenu.selectOne(
            title: "Thinking / effort for \(modelDisplayTitle(model))",
            items: thinkingSelectionItems(options),
            selected: defaultSelection,
            reservedBottomRows: statusBar.reservedRowsForOverlay()
        ) ?? defaultSelection
    }

    public func modelSelectionItems(
        _ models: [AgentSettingsModelManifest]
    ) -> [TerminalCheckboxMenuItem<AgentSettingsModelManifest>] {
        AgentModelCatalogPresentation.groupedByProvider(models).flatMap { group in
            group.models.map { model in
                TerminalCheckboxMenuItem(
                    value: model,
                    title: AgentModelCatalogPresentation.modelTitle(for: model, in: group),
                    detail: nil,
                    groupTitle: group.title
                )
            }
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
        guard let selection else {
            return ""
        }
        return " (thinking: \(selection.displayTitle))"
    }

    public func preloadCurrentModel(emitStatus: Bool = true) async throws -> String {
        refreshStatusBarThinkingSelection()
        let loadedModelID = try await sessionRunner.preloadModel(
            configuration: await currentSessionConfiguration()
        ) { event in
            switch event {
            case let .status(message):
                if emitStatus && self.configuration.verboseLogging {
                    self.writeChatError("[ZenCODE] \(message)\n")
                }
            case let .modelLoaded(modelID):
                _ = self.statusBar.update(modelID: modelID)
                self.printedModelID = self.loadedModelDisplayTitle(modelID)
            case let .modelLoadedDetails(details):
                if emitStatus {
                    self.printLoadedModelDetails(details)
                } else {
                    _ = self.statusBar.update(modelID: details.modelID)
                    _ = self.statusBar.update(modelRuntime: details.runtime)
                }
            case let .modelRuntime(runtime):
                _ = self.statusBar.update(modelRuntime: runtime)
            case .diagnostic,
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
        _ = statusBar.update(modelID: loadedModelID)
        if !emitStatus {
            printedModelID = loadedModelDisplayTitle(loadedModelID)
        }
        return loadedModelID
    }

    public func printModelIfNeeded(_ modelID: String) {
        let displayTitle = loadedModelDisplayTitle(modelID)
        guard printedModelID != displayTitle else {
            return
        }
        printedModelID = displayTitle
        refreshStatusBarThinkingSelection()
        _ = statusBar.update(modelID: modelID)
        printLoadedModelDetails(
            DirectAgentLoadedModelDetails(modelID: modelID)
        )
    }

    public func printLoadedModelDetails(_ details: DirectAgentLoadedModelDetails) {
        let modelID = details.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !modelID.isEmpty else {
            return
        }

        let displayTitle = loadedModelDisplayTitle(modelID)
        printedModelID = displayTitle
        refreshStatusBarThinkingSelection()
        _ = statusBar.update(modelID: modelID)
        _ = statusBar.update(modelRuntime: details.runtime)
        let runtimeLabel = details.runtime?.lowercased().hasPrefix("ds4") == true ? "DS4" : "MLX"
        let loadedModelHeading = "ZenCODE \(runtimeLabel) loaded model"

        guard configuration.verboseLogging else {
            writeOperationalMessage("\(loadedModelHeading): \(displayTitle)\n")
            return
        }

        var lines = [
            "\(loadedModelHeading):",
            "  model: \(modelID)"
        ]
        if let runtime = details.runtime {
            lines.append("  runtime: \(runtime)")
        }
        if let generation = details.generation {
            lines.append("  generation: \(generation)")
        }
        if let penalties = details.penalties {
            lines.append("  penalties: \(penalties)")
        }
        if let kvCache = details.kvCache {
            lines.append("  kv_cache: \(kvCache)")
        }
        writeOperationalMessage(lines.joined(separator: "\n") + "\n")
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
