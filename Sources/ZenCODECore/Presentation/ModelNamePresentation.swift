//
//  ModelNamePresentation.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Pure display-name transformations; model and binding identities remain unchanged.
enum ModelNamePresentation {
    /// Returns the model portion of a remote API model id
    /// `<providerKey>:<modelName>`, otherwise `nil`.
    ///
    /// The id is split on the FIRST colon: OpenRouter model names may contain
    /// colons themselves (`openrouter:deepseek/deepseek-r1:free` presents as
    /// `deepseek/deepseek-r1:free`). Only remote API provider keys are stripped;
    /// subscription (`chatgpt:`, `claude:`) and DS4 (`ds4:`) ids keep their
    /// own presentation.
    nonisolated static func subAgentModelNameStrippingRemoteAPIPrefix(
        _ modelID: String
    ) -> String? {
        AgentRemoteProvider.remoteAPIScopedModelID(modelID)?.modelID
    }

    /// Removes a display prefix when the provider is shown separately. A
    /// remote API id loses its provider key (split on the first colon) in any
    /// case; another known provider key (`chatgpt:`, `claude:`, `ds4:`) is
    /// removed on the first colon only when a provider is present. An
    /// unrecognised prefix falls back to the final colon segment, again only
    /// when a provider is present.
    nonisolated static func strippedModelNameForBinding(
        _ modelID: String,
        modelProvider: String?
    ) -> String {
        if let stripped = subAgentModelNameStrippingRemoteAPIPrefix(modelID) {
            return stripped
        }
        guard modelProvider != nil else {
            return modelID
        }
        if let scoped = AgentRemoteProvider.providerScopedModelID(modelID) {
            return scoped.modelID
        }
        guard let colonRange = modelID.range(of: ":", options: .backwards) else {
            return modelID
        }
        let modelName = modelID[colonRange.upperBound...]
        return modelName.isEmpty ? modelID : String(modelName)
    }
}
