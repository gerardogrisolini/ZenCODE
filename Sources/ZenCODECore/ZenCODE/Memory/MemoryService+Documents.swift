//
//  MemoryService+Documents.swift
//  ZenCODE
//

import Crypto
import Foundation

extension MemoryService {
    func memoryDocuments(workspaceRootURL: URL?) -> [MemoryDocument] {
        guard let workspaceRootURL else {
            return []
        }
        return [projectMemoryDocument(at: workspaceRootURL)]
    }

    func memoryDocument(
        scope: MemoryScope,
        workspaceRootURL: URL?
    ) throws -> MemoryDocument {
        switch scope {
        case .project:
            guard let workspaceRootURL else {
                throw MemoryServiceError.scopeUnavailable("project")
            }
            return projectMemoryDocument(at: workspaceRootURL)
        }
    }

    private func projectMemoryDocument(at workspaceRootURL: URL) -> MemoryDocument {
        MemoryDocument(
            scope: .project,
            fileURL: workspaceRootURL.standardizedFileURL.appendingPathComponent(Self.filename)
        )
    }

    func readEntries(from document: MemoryDocument) -> [MemoryEntry] {
        guard case let .loaded(entries) = readState(from: document) else {
            return []
        }
        return entries
    }

    /// Mutation paths must not treat an unreadable or malformed journal as an
    /// empty one. Doing so would atomically replace the user's journal with a
    /// newly rendered empty document.
    func readEntriesForMutation(from document: MemoryDocument) throws -> [MemoryEntry] {
        switch readState(from: document) {
        case .missing:
            return []
        case let .loaded(entries):
            return entries
        case .unreadable:
            throw MemoryServiceError.documentUnreadable(document.fileURL.path)
        case .invalid:
            throw MemoryServiceError.invalidDocument(document.fileURL.path)
        }
    }

    private func readState(from document: MemoryDocument) -> MemoryDocumentReadState {
        guard fileManager.fileExists(atPath: document.fileURL.path) else {
            return .missing
        }
        let content: String
        do {
            content = try String(contentsOf: document.fileURL, encoding: .utf8)
        } catch {
            return .unreadable
        }
        guard let entries = parseEntries(from: content, document: document) else {
            return .invalid
        }
        return .loaded(entries)
    }

    private func parseEntries(
        from content: String,
        document: MemoryDocument
    ) -> [MemoryEntry]? {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedContent.isEmpty
                || content.components(separatedBy: .newlines).contains(where: { line in
                    let normalizedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        .lowercased()
                    return normalizedLine == "## active" || normalizedLine == "## archived"
                }) else {
            return nil
        }

        var entries: [MemoryEntry] = []
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
            guard let entry = Self.entry(
                fromEntryContent: currentEntryLines.joined(separator: "\n"),
                scope: document.scope,
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
                  let continuationLine = Self.entryContinuationLine(from: rawLine) else {
                continue
            }
            currentEntryLines.append(continuationLine)
        }
        flushCurrentEntry()
        return encounteredInvalidEntry ? nil : entries
    }

    static func entry(
        fromEntryContent content: String,
        scope: MemoryScope,
        isArchived: Bool,
        legacyOrdinal: Int = 0
    ) -> MemoryEntry? {
        let trimmedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContent.isEmpty else {
            return nil
        }

        let idPrefix = "[id:"
        if trimmedContent.lowercased().hasPrefix(idPrefix) {
            guard let closingBracket = trimmedContent.firstIndex(of: "]") else {
                return nil
            }
            let rawID = trimmedContent[trimmedContent.index(trimmedContent.startIndex, offsetBy: idPrefix.count)..<closingBracket]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let content = trimmedContent[trimmedContent.index(after: closingBracket)...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let id = UUID(uuidString: rawID), !content.isEmpty else {
                return nil
            }
            return MemoryEntry(
                content: content,
                scope: scope,
                id: id,
                isArchived: isArchived
            )
        }

        return MemoryEntry(
            content: trimmedContent,
            scope: scope,
            id: legacyIdentifier(
                content: trimmedContent,
                scope: scope,
                isArchived: isArchived,
                ordinal: legacyOrdinal
            ),
            isArchived: isArchived
        )
    }

    /// Legacy entries have no persisted identifier. Derive a stable UUIDv8 from
    /// their document position and content so a later mutation can address them;
    /// the next successful write persists that identifier in MEMORY.md.
    static func legacyIdentifier(
        content: String,
        scope: MemoryScope,
        isArchived: Bool,
        ordinal: Int
    ) -> UUID {
        let seed = [
            "zencode-memory-entry-v1",
            scope.rawValue,
            isArchived ? "archived" : "active",
            String(ordinal),
            MemoryEntry.normalizedContent(content),
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

    func writeEntries(
        _ entries: [MemoryEntry],
        to document: MemoryDocument
    ) throws {
        try fileManager.createDirectory(
            at: document.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let activeEntries = entries.filter { !$0.isArchived }
        let archivedEntries = entries.filter(\.isArchived)
        let content = Self.documentContent(
            scope: document.scope,
            activeEntries: activeEntries,
            archivedEntries: archivedEntries
        )
        try content
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appending("\n")
            .write(to: document.fileURL, atomically: true, encoding: .utf8)
    }

    static func documentContent(
        scope: MemoryScope,
        activeEntries: [MemoryEntry],
        archivedEntries: [MemoryEntry]
    ) -> String {
        let template: String
        switch scope {
        case .project:
            template = defaultProjectMemoryContent
        }

        let active = render(entries: activeEntries)
        let archived = render(entries: archivedEntries)
        return template
            .replacingOccurrences(of: "## Active\n\n## Archived", with: "## Active\n\n\(active)\n\n## Archived")
            .replacingOccurrences(of: "## Archived", with: "## Archived\n\n\(archived)")
    }

    static func render(entries: [MemoryEntry]) -> String {
        guard !entries.isEmpty else {
            return ""
        }
        return entries.map { entry in
            let lines = MemoryEntry.normalizedContent(entry.content)
                .components(separatedBy: "\n")
            let firstLine = lines.first ?? ""
            let continuation = lines.dropFirst()
                .map { "  \($0)" }
                .joined(separator: "\n")
            let header = "- [id: \(entry.id.uuidString.uppercased())] \(firstLine)"
            return continuation.isEmpty ? header : "\(header)\n\(continuation)"
        }
        .joined(separator: "\n")
    }

    public static func timestampString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: date)) \(timeZone.identifier)"
    }

    func searchScore(
        entry: MemoryEntry,
        query: String,
        terms: [String]
    ) -> Int {
        let content = entry.content.lowercased()
        let metadata = entry.metadata
        let summary = metadata.summary?.lowercased() ?? ""
        let state = metadata.state?.lowercased() ?? ""
        var score = 0
        var matchedTerms = 0

        if content.contains(query) {
            score += 50
        }
        if summary.contains(query) {
            score += 100
        }
        for term in terms {
            guard content.contains(term) else {
                continue
            }
            matchedTerms += 1
            score += 10
            if summary.contains(term) {
                score += 30
            }
            if state.contains(term) {
                score += 15
            }
        }
        if matchedTerms == terms.count {
            score += 25
        }
        return score
    }

}


struct MemoryDocument {
    let scope: MemoryScope
    let fileURL: URL
}

public enum MemoryServiceError: LocalizedError {
    case missingField(String)
    case scopeUnavailable(String)
    case invalidIdentifier(String)
    case entryNotFound(String)
    case documentUnreadable(String)
    case invalidDocument(String)

    public var errorDescription: String? {
        switch self {
        case let .missingField(field):
            return "Missing memory field: \(field)."
        case let .scopeUnavailable(scope):
            return "The \(scope) memory scope is not available in the current context."
        case let .invalidIdentifier(identifier):
            return "Invalid memory identifier: \(identifier)."
        case let .entryNotFound(identifier):
            return "No memory entry was found for \(identifier)."
        case let .documentUnreadable(path):
            return "MEMORY.md could not be read safely at \(path); it was left unchanged."
        case let .invalidDocument(path):
            return "MEMORY.md has an unrecognized format at \(path); it was left unchanged."
        }
    }
}

private enum MemoryDocumentReadState {
    case missing
    case loaded([MemoryEntry])
    case unreadable
    case invalid
}
