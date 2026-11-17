//
//  AgentSettingsModelManifestFactory.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public enum AgentSettingsModelManifestFactory {
    public static func remoteAPIModel(
        manifestID: String? = nil,
        title: String?,
        modelID: String,
        providerID: String,
        providerName: String,
        baseURL: String,
        chatEndpoint: AgentRemoteChatEndpoint,
        configuredContextWindowLimit: Int?,
        generationParameterOverrides: AgentGenerationParameterOverrides?,
        thinkingSupport: ModelThinkingSupport?,
        ds4Runtime: AgentDS4RuntimeConfiguration? = nil
    ) -> AgentSettingsModelManifest {
        let provider = AgentRemoteProvider(
            id: providerID,
            name: providerName,
            baseURL: baseURL,
            modelID: modelID,
            chatEndpoint: chatEndpoint,
            ds4Runtime: ds4Runtime
        )
        let resolvedManifestID = manifestID?.nilIfBlank
            ?? AgentRemoteProvider.modelManifestID(providerID: provider.id, modelID: modelID)
        return AgentSettingsModelManifest(
            id: resolvedManifestID,
            kind: .remoteAPI,
            title: title,
            llmID: resolvedManifestID,
            modelID: modelID,
            providerID: provider.id,
            provider: provider,
            configuredContextWindowLimit: configuredContextWindowLimit,
            generationParameterOverrides: generationParameterOverrides,
            thinkingOptions: agentThinkingOptions(from: thinkingSupport),
            defaultThinkingSelection: thinkingSupport?.defaultSelection
        )
    }

    public static func agentThinkingOptions(
        from support: ModelThinkingSupport?
    ) -> [AgentThinkingSelection]? {
        guard let support,
              support.supportsThinking else {
            return nil
        }
        let options = support.availableSelections
        return options.isEmpty ? nil : options
    }
}
