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

    /// Normalizes a diff/patch file path: trims whitespace, optionally strips a
    /// tab-suffix, rejects empty or `/dev/null`, and optionally strips the
    /// `a/` or `b/` git prefix.
    public static func normalizedPatchPath(
        _ rawValue: String,
        stripGitPrefix: Bool = true,
        stripTabSuffix: Bool = false
    ) -> String? {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if stripTabSuffix, let tab = value.firstIndex(of: "\t") {
            value = String(value[..<tab]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !value.isEmpty, value != "/dev/null" else { return nil }
        if stripGitPrefix, value.hasPrefix("a/") || value.hasPrefix("b/") {
            value = String(value.dropFirst(2))
        }
        guard !value.isEmpty, value != "/dev/null" else { return nil }
        return value
    }
}
