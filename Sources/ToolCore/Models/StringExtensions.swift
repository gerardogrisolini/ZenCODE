//
//  StringExtensions.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

extension String {
    /// Returns the trimmed string, or `nil` when the result is empty.
    public var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Returns `nil` when the string is empty (no trimming).
    public var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
