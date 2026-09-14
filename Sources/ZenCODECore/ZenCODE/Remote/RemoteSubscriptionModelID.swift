//
//  RemoteSubscriptionModelID.swift
//  ZenCODE
//

import Foundation

enum RemoteSubscriptionModelID {
    static func selectionID(
        forModelID modelID: String,
        prefix: String
    ) -> String {
        let modelID = normalizedModelID(modelID)
        return modelID.isEmpty ? "" : "\(prefix):\(modelID)"
    }

    static func modelID(
        fromLLMID value: String?,
        prefix: String
    ) -> String {
        guard let value else {
            return ""
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return ""
        }

        let lowercasedValue = trimmedValue.lowercased()
        if lowercasedValue == prefix {
            return ""
        }
        for separator in [":", "/"] where lowercasedValue.hasPrefix(prefix + separator) {
            let rawModelID = String(trimmedValue.dropFirst(prefix.count + separator.count))
            return normalizedModelID(rawModelID)
        }
        return normalizedModelID(trimmedValue)
    }

    private static func normalizedModelID(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue
    }

}
