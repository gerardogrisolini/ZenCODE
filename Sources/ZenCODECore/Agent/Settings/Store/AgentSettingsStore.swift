//
//  AgentSettingsStore.swift
//  ZenCODE
//
//  Read access to the saved settings manifest: effective model, thinking
//  selection, generation parameters and API keys.
//

import Foundation
import ToolCore

public enum AgentSettingsStore {
    public static func resolvedEffectiveModelID(
        explicitModelID: String?,
        agentModelID: String?,
        manifest: AgentSettingsManifest? = AgentSettingsManifestStore.load()
    ) -> String? {
        if let explicitModelID = explicitModelID?.nilIfBlank {
            return explicitModelID
        }

        if let agentModelID = agentModelID?.nilIfBlank,
           manifest?.models.contains(where: { $0.matches(agentModelID) }) == true {
            return agentModelID
        }

        guard let manifest else {
            return nil
        }

        if let selectedModelID = manifest.selectedModelID?.nilIfBlank,
           let model = manifest.models.first(where: { $0.matches(selectedModelID) }) {
            return model.id
        }

        if manifest.models.count == 1 {
            return manifest.models.first?.id
        }

        return nil
    }

    public static func defaultSelection(explicitModelID: String?) -> AgentModelSelection? {
        guard let manifest = AgentSettingsManifestStore.load() else {
            return nil
        }

        if let explicitModelID = explicitModelID?.nilIfBlank {
            return modelSelection(forLLMID: explicitModelID, manifest: manifest)
        }

        if let selectedModelID = manifest.selectedModelID?.nilIfBlank,
           let model = manifest.models.first(where: { $0.matches(selectedModelID) }) {
            return selection(
                for: model,
                manifest: manifest,
                thinkingSelection: manifest.selectedThinkingSelection
            )
        }

        if manifest.models.count == 1,
           let model = manifest.models.first {
            return selection(
                for: model,
                manifest: manifest,
                thinkingSelection: manifest.selectedThinkingSelection
            )
        }

        return nil
    }

    public static func availableModels() -> [AgentSettingsModelManifest] {
        AgentSettingsManifestStore.load()?.models ?? []
    }

    public static func selectedModelID() -> String? {
        guard let manifest = AgentSettingsManifestStore.load(),
              let selectedModelID = manifest.selectedModelID?.nilIfBlank,
              let model = manifest.models.first(where: { $0.matches(selectedModelID) }) else {
            return nil
        }
        return model.id
    }

    public static func selectedThinkingSelection() -> AgentThinkingSelection? {
        guard let manifest = AgentSettingsManifestStore.load(),
              let selectedModelID = manifest.selectedModelID?.nilIfBlank,
              let model = manifest.models.first(where: { $0.matches(selectedModelID) }) else {
            return nil
        }
        return model.thinkingSelection(for: manifest.selectedThinkingSelection)
    }

    public static func thinkingSelection(
        requestedSelection: AgentThinkingSelection?,
        explicitModelID: String?,
        agentModelID: String?,
        agentThinkingSelection: AgentThinkingSelection? = nil,
        manifest: AgentSettingsManifest? = AgentSettingsManifestStore.load()
    ) -> AgentThinkingSelection? {
        let preferredSelection = requestedSelection ?? agentThinkingSelection
        if let explicitModelID = explicitModelID?.nilIfBlank {
            guard let model = manifest?.models.first(where: {
                $0.matches(explicitModelID)
            }) else {
                return preferredSelection
            }
            return model.thinkingSelection(for: preferredSelection)
        }

        if let agentModelID = agentModelID?.nilIfBlank,
           let model = manifest?.models.first(where: {
               $0.matches(agentModelID)
           }) {
            return model.thinkingSelection(for: preferredSelection)
        }

        guard let manifest else {
            return preferredSelection
        }

        if let selectedModelID = manifest.selectedModelID?.nilIfBlank,
           let model = manifest.models.first(where: { $0.matches(selectedModelID) }) {
            return model.thinkingSelection(
                for: preferredSelection ?? manifest.selectedThinkingSelection
            )
        }

        if manifest.models.count == 1,
           let model = manifest.models.first {
            return model.thinkingSelection(
                for: preferredSelection ?? manifest.selectedThinkingSelection
            )
        }

        return preferredSelection
    }

    private static func modelSelection(
        forLLMID llmID: String,
        manifest: AgentSettingsManifest
    ) -> AgentModelSelection? {
        guard let normalizedLLMID = llmID.nilIfBlank,
              let model = manifest.models.first(where: { $0.matches(normalizedLLMID) }) else {
            return nil
        }

        return selection(for: model, manifest: manifest)
    }

    private static func selection(
        for model: AgentSettingsModelManifest,
        manifest: AgentSettingsManifest,
        thinkingSelection: AgentThinkingSelection? = nil
    ) -> AgentModelSelection? {
        let resolvedThinkingSelection = model.thinkingSelection(for: thinkingSelection)
        switch model.kind {
        case .remoteAPI:
            guard let provider = model.provider,
                  let modelID = model.modelID.nilIfBlank else {
                return nil
            }
            let resolvedProvider = provider.withModelID(modelID)
            return AgentModelSelection(
                providerKind: .remoteAPI,
                modelID: modelID,
                remoteProvider: resolvedProvider,
                apiKey: manifest.apiKey(providerID: provider.id),
                configuredContextWindowLimit: model.configuredContextWindowLimit,
                generationParameterOverrides: model.generationParameterOverrides,
                thinkingOptions: model.thinkingOptions,
                thinkingSelection: resolvedThinkingSelection,
                ds4Runtime: model.ds4Runtime
            )
        }
    }

    /// Whether `llmID` names a remote API model by its provider-scoped id
    /// (`<providerKey>:<modelID>`). Subscription (`chatgpt:`, `claude:`) and
    /// DS4 (`ds4:`) ids keep their own resolution and are not matched. The
    /// pre-v15 `remoteapi:` spellings are still recognised so an unresolved
    /// legacy reference fails closed instead of reaching a fallback provider.
    public static func isRemoteLLMIDSyntax(_ llmID: String) -> Bool {
        let trimmed = llmID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("remoteapi:") || trimmed.hasPrefix("remoteapimodel:") {
            return true
        }
        return AgentRemoteProvider.remoteAPIScopedModelID(trimmed) != nil
    }

}
