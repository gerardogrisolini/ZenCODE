//
//  TextUtilities.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public enum TextUtilities {
    public static func truncate(
        text: String,
        limit: Int,
        footer: String
    ) -> String {
        guard text.count > limit else {
            return text
        }
        return String(text.prefix(limit)) + footer
    }

    public static func normalizedLookupValue(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}
