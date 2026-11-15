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

    public func availableModelManifests() -> [AgentSettingsModelManifest] {
        chatSession.modelCatalog.availableModels()
    }

    public func preloadCurrentModel(emitStatus: Bool = true) async throws -> String {
        await refreshStatusBarThinkingSelection()
        let loadedModelID = try await sessionRunner.preloadModel(
            configuration: await currentSessionConfiguration()
        ) { @ChatSessionActor event in
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
             .toolCallPreview,
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
