//
//  RemoteSubscriptionModelID.swift
//  ZenCODE
//

import Foundation

enum RemoteSubscriptionModelID {
    static func isLLMID(_ value: String?, prefix: String) -> Bool {
        guard let normalizedValue = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalizedValue.isEmpty else {
            return false
        }

        return isPrefix(normalizedValue, prefix: prefix)
    }

    static func selectionID(
        forModelID modelID: String,
        prefix: String,
        defaultModelID: String
    ) -> String {
        "\(prefix):\(normalizedModelID(modelID, defaultModelID: defaultModelID))"
    }

    static func modelID(
        fromLLMID value: String?,
        prefix: String,
        defaultModelID: String
    ) -> String {
        guard let value else {
            return defaultModelID
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return defaultModelID
        }

        let lowercasedValue = trimmedValue.lowercased()
        if lowercasedValue == prefix {
            return defaultModelID
        }
        for separator in [":", "/"] where lowercasedValue.hasPrefix(prefix + separator) {
            let rawModelID = String(trimmedValue.dropFirst(prefix.count + separator.count))
            return normalizedModelID(rawModelID, defaultModelID: defaultModelID)
        }
        return normalizedModelID(trimmedValue, defaultModelID: defaultModelID)
    }

    static func normalizedModelID(_ value: String, defaultModelID: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? defaultModelID : trimmedValue
    }

    private static func isPrefix(_ value: String, prefix: String) -> Bool {
        value == prefix
            || value.hasPrefix(prefix + ":")
            || value.hasPrefix(prefix + "/")
    }
}
