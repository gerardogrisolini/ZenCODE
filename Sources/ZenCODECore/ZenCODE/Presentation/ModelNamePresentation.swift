//
//  ModelNamePresentation.swift
//  ZenCODE
//

import Foundation

/// Pure display-name transformations; model and binding identities remain unchanged.
enum ModelNamePresentation {
    /// Returns the model portion of `remoteapi:<uuid>:<modelName>`, otherwise `nil`.
    nonisolated static func subAgentModelNameStrippingRemoteAPIPrefix(
        _ modelID: String
    ) -> String? {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("remoteapi:") else {
            return nil
        }
        let afterPrefix = trimmed.dropFirst("remoteapi:".count)
        guard !afterPrefix.isEmpty else {
            return nil
        }
        guard let colonRange = afterPrefix.range(of: ":") else {
            return nil
        }
        let providerSegment = afterPrefix[afterPrefix.startIndex..<colonRange.lowerBound]
        let modelName = afterPrefix[colonRange.upperBound...]
        guard UUID(uuidString: String(providerSegment)) != nil,
              !modelName.isEmpty else {
            return nil
        }
        return String(modelName)
    }

    /// Removes a display prefix when the provider is shown separately, falling
    /// back to the final colon segment only when a provider is present.
    nonisolated static func strippedModelNameForBinding(
        _ modelID: String,
        modelProvider: String?
    ) -> String {
        if let stripped = subAgentModelNameStrippingRemoteAPIPrefix(modelID) {
            return stripped
        }
        guard modelProvider != nil,
              let colonRange = modelID.range(of: ":", options: .backwards) else {
            return modelID
        }
        let modelName = modelID[colonRange.upperBound...]
        return modelName.isEmpty ? modelID : String(modelName)
    }
}
