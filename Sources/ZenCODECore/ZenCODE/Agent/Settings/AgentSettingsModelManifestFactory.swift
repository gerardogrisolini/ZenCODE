//
//  AgentSettingsModelManifestFactory.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public enum AgentSettingsModelManifestFactory {
    public static func remoteAPIModel(
        manifestID: String? = nil,
        title: String?,
        modelID: String,
        providerID: UUID,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        configuredContextWindowLimit: Int?,
        generationParameterOverrides: AgentGenerationParameterOverrides?,
        thinkingSupport: MLXModelThinkingSupport?
    ) -> AgentSettingsModelManifest {
        let provider = AgentRemoteProvider(
            id: providerID,
            name: providerName,
            baseURL: baseURL,
            modelID: modelID,
            chatEndpoint: chatEndpoint
        )
        let resolvedManifestID = manifestID?.nilIfBlank
            ?? "remoteapi:\(providerID.uuidString.lowercased()):\(modelID)"
        return AgentSettingsModelManifest(
            id: resolvedManifestID,
            kind: .remoteAPI,
            title: title,
            llmID: resolvedManifestID,
            modelID: modelID,
            providerID: providerID,
            provider: provider,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            thinkingOptions: agentThinkingOptions(from: thinkingSupport),
            defaultThinkingSelection: agentThinkingSelection(
                from: thinkingSupport?.defaultSelection
            )
        )
    }

    public static func agentThinkingOptions(
        from support: MLXModelThinkingSupport?
    ) -> [AgentThinkingSelection]? {
        guard let support,
              support.supportsThinking else {
            return nil
        }
        let options = support.availableSelections.compactMap(agentThinkingSelection)
        return options.isEmpty ? nil : options
    }

    public static func agentThinkingSelection(
        from selection: MLXThinkingSelection?
    ) -> AgentThinkingSelection? {
        guard let selection else {
            return nil
        }
        return AgentThinkingSelection(rawValue: selection.rawValue)
    }
}
