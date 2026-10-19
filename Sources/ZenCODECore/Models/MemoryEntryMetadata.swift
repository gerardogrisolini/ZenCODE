//
//  MemoryEntryMetadata.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Structured fields derived from a journal entry's human-readable content.
///
/// Metadata remains embedded in `MemoryEntry.content`; graph entries need no
/// separate persisted metadata fields.
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

    /// Whether `line` is one of the journal's timestamp annotations
    /// (`Timestamp:` / `Updated:`), which never make a useful title.
    static func isTimestampLine(_ line: String) -> Bool {
        let lowered = line.trimmingCharacters(in: .whitespaces).lowercased()
        return lowered.hasPrefix("timestamp:") || lowered.hasPrefix("updated:")
    }

    /// `Summary:` when present, otherwise the first line that is not a
    /// timestamp annotation; `nil` when the content has no such line.
    static func titleLine(of content: String) -> String? {
        let metadata = MemoryEntryMetadata(content: content)
        if let summary = metadata.summary {
            return summary
        }
        return content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !isTimestampLine($0) }
    }

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

extension GraphEntry {
    var metadata: MemoryEntryMetadata {
        MemoryEntryMetadata(content: content)
    }
}

extension MemoryEntryMetadata {
    /// Parses the journal `Timestamp:` field back into a `Date`.
    ///
    /// Used by the graph migration so an imported entry keeps its original
    /// creation date instead of the import date. Returns `nil` when the field
    /// is absent or not in the journal's `yyyy-MM-dd HH:mm ZoneID` shape.
    var timestampDate: Date? {
        guard let timestamp else {
            return nil
        }
        return Self.date(fromTimestamp: timestamp)
    }

    static func date(fromTimestamp timestamp: String) -> Date? {
        let components = timestamp.split(separator: " ", omittingEmptySubsequences: true)
        guard components.count >= 2 else {
            return nil
        }
        let dateAndTime = components.prefix(2).joined(separator: " ")
        let zoneIdentifier = components.count >= 3 ? String(components[2]) : nil

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = zoneIdentifier.flatMap { TimeZone(identifier: $0) }
            ?? TimeZone(abbreviation: zoneIdentifier ?? "")
            ?? .current
        return formatter.date(from: dateAndTime)
    }
}
