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
