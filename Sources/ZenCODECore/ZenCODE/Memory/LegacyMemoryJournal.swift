//
//  LegacyMemoryJournal.swift
//  ZenCODE
//
//  Parser for the legacy human-readable MEMORY.md journal.
//
//  MEMORY.md is no longer the durable store: the MemoryEngine graph is. This
//  parser exists solely so an existing journal can be imported into the graph
//  once, without losing any entry. The file itself is never rewritten.
//

import Crypto
import Foundation

/// One entry recovered from a legacy `MEMORY.md` document.
struct LegacyJournalEntry: Sendable, Equatable {
    let id: UUID
    let content: String
    let isArchived: Bool
}

/// Outcome of reading a legacy journal document.
enum LegacyJournalReadState: Sendable, Equatable {
    /// No legacy journal exists; there is nothing to migrate.
    case missing
    /// The journal parsed cleanly into zero or more entries.
    case loaded([LegacyJournalEntry])
    /// The journal exists but could not be read or parsed safely.
    ///
    /// Migration must refuse to proceed rather than silently drop entries.
    case unusable

    var entries: [LegacyJournalEntry] {
        if case let .loaded(entries) = self { return entries }
        return []
    }
}

enum LegacyMemoryJournal {
    /// Reads and parses a legacy journal without ever writing to it.
    static func read(
        at url: URL,
        fileManager: FileManager = .default
    ) -> LegacyJournalReadState {
        guard fileManager.fileExists(atPath: url.path) else {
            return .missing
        }
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            return .unusable
        }
        guard let parsed = parseEntries(from: content) else {
            return .unusable
        }
        return .loaded(parsed)
    }

    /// Parses the `## Active` / `## Archived` journal shape.
    ///
    /// Returns `nil` when the document does not look like a ZenCODE journal or
    /// contains a malformed entry.
    static func parseEntries(from content: String) -> [LegacyJournalEntry]? {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedContent.isEmpty
                || content.components(separatedBy: .newlines).contains(where: { line in
                    let normalizedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    return normalizedLine == "## active" || normalizedLine == "## archived"
                }) else {
            return nil
        }

        var entries: [LegacyJournalEntry] = []
        var sectionIsActive = false
        var sectionIsArchived = false
        var currentEntryLines: [String] = []
        var currentEntryIsArchived = false
        var entryOrdinal = 0
        var encounteredInvalidEntry = false

        func flushCurrentEntry() {
            guard !currentEntryLines.isEmpty else {
                return
            }
            defer {
                currentEntryLines.removeAll()
                entryOrdinal += 1
            }
            guard let entry = entry(
                fromEntryContent: currentEntryLines.joined(separator: "\n"),
                isArchived: currentEntryIsArchived,
                legacyOrdinal: entryOrdinal
            ) else {
                encounteredInvalidEntry = true
                return
            }
            guard !entries.contains(where: { $0.id == entry.id }) else {
                encounteredInvalidEntry = true
                return
            }
            entries.append(entry)
        }

        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                flushCurrentEntry()
                let sectionTitle = line
                    .dropFirst(3)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                sectionIsActive = sectionTitle.localizedCaseInsensitiveContains("active")
                sectionIsArchived = sectionTitle.localizedCaseInsensitiveContains("archived")
                continue
            }

            guard sectionIsActive || sectionIsArchived else {
                continue
            }
            if line.hasPrefix("- ") {
                flushCurrentEntry()
                currentEntryLines = [String(line.dropFirst(2))]
                currentEntryIsArchived = sectionIsArchived
                continue
            }

            guard !currentEntryLines.isEmpty,
                  let continuationLine = entryContinuationLine(from: rawLine) else {
                continue
            }
            currentEntryLines.append(continuationLine)
        }
        flushCurrentEntry()
        return encounteredInvalidEntry ? nil : entries
    }

    static func entry(
        fromEntryContent content: String,
        isArchived: Bool,
        legacyOrdinal: Int = 0
    ) -> LegacyJournalEntry? {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            return nil
        }

        let idPrefix = "[id:"
        if trimmedContent.lowercased().hasPrefix(idPrefix) {
            guard let closingBracket = trimmedContent.firstIndex(of: "]") else {
                return nil
            }
            let rawID = trimmedContent[
                trimmedContent.index(trimmedContent.startIndex, offsetBy: idPrefix.count)..<closingBracket
            ].trimmingCharacters(in: .whitespacesAndNewlines)
            let remainder = trimmedContent[trimmedContent.index(after: closingBracket)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = UUID(uuidString: rawID), !remainder.isEmpty else {
                return nil
            }
            return LegacyJournalEntry(
                id: id,
                content: MemoryContent.normalized(remainder),
                isArchived: isArchived
            )
        }

        return LegacyJournalEntry(
            id: legacyIdentifier(
                content: trimmedContent,
                isArchived: isArchived,
                ordinal: legacyOrdinal
            ),
            content: MemoryContent.normalized(trimmedContent),
            isArchived: isArchived
        )
    }

    /// Legacy entries have no persisted identifier. Derive a stable UUIDv8 from
    /// their document position and content so the migrated graph node keeps a
    /// deterministic identity across repeated imports.
    ///
    /// The seed string is byte-identical to the pre-graph implementation, so an
    /// entry that was already addressable by this id stays addressable.
    static func legacyIdentifier(
        content: String,
        isArchived: Bool,
        ordinal: Int
    ) -> UUID {
        let seed = [
            "zencode-memory-entry-v1",
            "project",
            isArchived ? "archived" : "active",
            String(ordinal),
            MemoryContent.normalized(content),
        ].joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func entryContinuationLine(from line: String) -> String? {
        if line.hasPrefix("  ") {
            return String(line.dropFirst(2))
        }
        if line.hasPrefix("\t") {
            return String(line.dropFirst())
        }
        return nil
    }
}
