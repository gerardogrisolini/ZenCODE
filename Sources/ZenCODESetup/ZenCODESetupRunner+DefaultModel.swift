//
//  ZenCODESetupRunner+DefaultModel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import ZenCODECore

extension ZenCODESetupRunner {
    static func configureDefaultModel(
        in manifest: AgentSettingsManifest
    ) throws -> AgentSettingsManifest {
        guard !manifest.models.isEmpty else {
            throw ZenCODESetupError.noModelsConfigured
        }

        let selectedModelID: String
        if manifest.models.count == 1 {
            selectedModelID = manifest.models[0].id
            AgentOutput.standardError.writeString(
                "Only one model configured: \(manifest.models[0].displayTitle)\n"
            )
        } else {
            selectedModelID = try selectDefaultModel(
                from: manifest.models,
                defaultModelID: manifest.selectedModelID
            )
        }
        let selectedThinkingSelection = setupDefaultThinkingSelection(
            for: manifest.models.first { $0.matches(selectedModelID) },
            existingSelection: manifest.selectedThinkingSelection
        )
        return manifestByUpdatingSelection(
            manifest,
            selectedModelID: selectedModelID,
            selectedThinkingSelection: selectedThinkingSelection
        )
    }

    static func configureDefaultThinking(
        in manifest: AgentSettingsManifest
    ) throws -> AgentSettingsManifest {
        guard !manifest.models.isEmpty else {
            throw ZenCODESetupError.noModelsConfigured
        }

        let selectedModelID = preservedOrFirstSelectedModelID(
            from: manifest.models,
            existingSelectedModelID: manifest.selectedModelID
        )
        guard let model = manifest.models.first(where: { $0.matches(selectedModelID) }) else {
            throw ZenCODESetupError.noModelsConfigured
        }
        guard model.supportsThinking else {
            AgentOutput.standardError.writeString(
                "The selected model does not support thinking options.\n"
            )
            return manifestByUpdatingSelection(
                manifest,
                selectedModelID: selectedModelID,
                selectedThinkingSelection: nil
            )
        }

        let selectedThinkingSelection = try selectDefaultThinkingSelection(
            for: model,
            existingSelection: manifest.selectedThinkingSelection
        )
        return manifestByUpdatingSelection(
            manifest,
            selectedModelID: selectedModelID,
            selectedThinkingSelection: selectedThinkingSelection
        )
    }

    static func manifestByUpdatingSelection(
        _ manifest: AgentSettingsManifest,
        selectedModelID: String?,
        selectedThinkingSelection: AgentThinkingSelection?
    ) -> AgentSettingsManifest {
        AgentSettingsManifest(
            version: manifest.version,
            providers: manifest.providers,
            models: manifest.models,
            selectedModelID: selectedModelID,
            selectedThinkingSelection: selectedThinkingSelection,
            telegram: manifest.telegram,
            voice: manifest.voice,
            remoteAPIKeysByProviderID: manifest.remoteAPIKeysByProviderID,
            localExecAllowedCommands: manifest.localExecAllowedCommands,
            chatGPTSubscriptionCredentials: manifest.chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: manifest.anthropicSubscriptionCredentials
        )
    }

    static func selectedModel(
        in manifest: AgentSettingsManifest
    ) -> AgentSettingsModelManifest? {
        guard let selectedModelID = manifest.selectedModelID else {
            return nil
        }
        return manifest.models.first { $0.matches(selectedModelID) }
    }

    static func selectDefaultModel(
        from models: [AgentSettingsModelManifest],
        defaultModelID: String? = nil
    ) throws -> String {
        let defaultIndex = defaultModelID
            .flatMap { selectedID in models.firstIndex { $0.matches(selectedID) } }
            ?? 0
        let items = models.enumerated().map { index, model in
            TerminalCheckboxMenuItem(
                value: index,
                title: model.displayTitle,
                detail: model.modelID
            )
        }
        let selectedIndex = try promptMenuChoice(
            title: "Default model",
            items: items,
            selected: defaultIndex
        )
        return models[selectedIndex].id
    }


    static func setupDefaultThinkingSelection(
        for model: AgentSettingsModelManifest?,
        existingSelection: AgentThinkingSelection?
    ) -> AgentThinkingSelection? {
        model?.thinkingSelection(for: existingSelection)
    }

    static func selectDefaultThinkingSelection(
        for model: AgentSettingsModelManifest?,
        existingSelection: AgentThinkingSelection?
    ) throws -> AgentThinkingSelection? {
        guard let model,
              !model.availableThinkingSelections.isEmpty else {
            return nil
        }

        let options = model.availableThinkingSelections
        let defaultSelection = setupDefaultThinkingSelection(
            for: model,
            existingSelection: existingSelection
        )
        let defaultIndex = defaultSelection.flatMap { options.firstIndex(of: $0) } ?? 0

        let items = options.enumerated().map { index, option in
            TerminalCheckboxMenuItem(
                value: index,
                title: option.menuTitle,
                detail: option.rawValue
            )
        }
        let selectedIndex = try promptMenuChoice(
            title: "Default thinking for \(model.displayTitle)",
            items: items,
            selected: defaultIndex
        )
        return options[selectedIndex]

    }

}
