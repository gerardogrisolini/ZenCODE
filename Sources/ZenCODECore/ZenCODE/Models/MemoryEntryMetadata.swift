//
//  MemoryEntryMetadata.swift
//  ZenCODE
//

import Foundation

/// Structured fields derived from a journal entry's human-readable content.
///
/// Metadata remains embedded in `MemoryEntry.content`, so existing MEMORY.md
/// documents keep their persisted format and older entries remain readable.
nonisolated struct MemoryEntryMetadata: Sendable {
    let timestamp: String?
    let updated: String?
    let summary: String?
    let state: String?
    let next: String?

    init(content: String) {
        let fields = Self.fields(in: content)
        timestamp = fields["timestamp"]
        updated = fields["updated"]
        summary = fields["summary"]
        state = fields["state"]
        next = fields["next"]
    }

    private static let recognizedFieldNames: Set<String> = [
        "timestamp",
        "updated",
        "summary",
        "state",
        "next",
    ]

    private static func fields(in content: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let separator = line.firstIndex(of: ":") else {
                continue
            }

            let name = line[..<separator]
                .lowercased()
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            guard recognizedFieldNames.contains(name), result[name] == nil else {
                continue
            }

            let value = line[line.index(after: separator)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                continue
            }
            result[name] = value
        }
        return result
    }
}

extension MemoryEntry {
    var metadata: MemoryEntryMetadata {
        MemoryEntryMetadata(content: content)
    }
}
