//
//  MemoryService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import Synchronization

public final class MemoryService {
    public static let filename = "MEMORY.md"
    public static let entriesDidChangeNotification = Notification.Name("MemoryEntriesDidChange")
    public static let defaultProjectMemoryContent: String = """
    # MEMORY.md

    Durable project journal for this workspace.

    Use this file for:
    - concise handoff entries for significant completed work
    - current validated project state
    - blockers, caveats, or decisions that affect future work
    - the next logical step for the codebase

    Preferred entry shape:
    - Timestamp: YYYY-MM-DD HH:mm TimeZone
    - Updated: YYYY-MM-DD HH:mm TimeZone, added when an existing entry changes
    - Summary: short description of what changed
    - State: current validated state, including important caveats
    - Next: next logical step

    Do not use this file for:
    - every command or tool call
    - raw outputs, detailed logs, or large diffs
    - general user preferences or operating rules
    - information already obvious from current files

    ## Active

    ## Archived
    """

    let fileManager: FileManager
    /// A process-wide coordinator is required because callers commonly create a
    /// fresh `MemoryService` per tool execution. An instance lock would still
    /// permit two instances to lose one another's read-modify-write update.
    static let documentWriteCoordinator = FileTransactionCoordinator.shared

    public init(
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
    }

    public static func notifyMemoryEntriesChanged() {
        NotificationCenter.default.post(name: entriesDidChangeNotification, object: nil)
    }

    public static func toolUsagePromptSection() -> String {
        return """
        Memory tools:
        Treat the project MEMORY.md as first-class durable context, but remember that its contents are not preloaded into this prompt.
        Use project memory as the codebase journal: call `memory.read` with `detail: "index"` for a compact overview or `memory.search` for a focused lookup, then verify the selected entries against Git, files, builds, tests, or current user messages before acting.
        Before writing, search for an active entry about the same durable project fact. Use `memory.update` when that entry should be brought current instead of appending a duplicate; if nothing materially changed, do not write.
        Do not write user preferences or operating rules to memory; keep entries scoped to durable project facts.
        Saved-session pointers are maintained programmatically in the sessions index when a session is saved; do not duplicate them with memory tools.
        At the end of a substantial project turn, before the final answer, decide whether project memory should be created, updated, archived, or left unchanged.
        A project journal entry should be concise and structured with `Summary`, `State`, and `Next`; `memory.write` adds `Timestamp` automatically when missing, while `memory.update` preserves it and adds `Updated` when omitted.
        Do not write every command or tool call, raw outputs, detailed logs, large diffs, temporary task state, guesses, or facts already obvious from current files.
        Use `memory.archive` when a note is stale, incorrect, or no longer useful.
        Prefer fresh evidence from files, tools, builds, tests, or current user messages when it conflicts with memory.
        """
    }

    public func readEntries(
        scope: MemoryScope?,
        workingDirectory: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MemoryEntry] {
        readEntries(
            scope: scope,
            workspaceRootURL: workingDirectory?.standardizedFileURL,
            includeArchived: includeArchived,
            limit: limit
        )
    }

    public func readEntries(
        scope: MemoryScope?,
        workspaceRootURL: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MemoryEntry] {
        memoryDocuments(workspaceRootURL: workspaceRootURL)
            .filter { document in
                scope == nil || document.scope == scope
            }
            .flatMap(readEntries(from:))
            .filter { includeArchived || !$0.isArchived }
            .prefix(max(limit, 0))
            .map { $0 }
    }

    public func searchEntries(
        query: String,
        scope: MemoryScope?,
        workingDirectory: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MemoryEntry] {
        searchEntries(
            query: query,
            scope: scope,
            workspaceRootURL: workingDirectory?.standardizedFileURL,
            includeArchived: includeArchived,
            limit: limit
        )
    }

    public func searchEntries(
        query: String,
        scope: MemoryScope?,
        workspaceRootURL: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MemoryEntry] {
        rankedEntries(
            query: query,
            entries: readEntries(
                scope: scope,
                workspaceRootURL: workspaceRootURL,
                includeArchived: includeArchived,
                limit: .max
            ),
            limit: limit
        )
    }

    func readEntriesChecked(
        scope: MemoryScope,
        workingDirectory: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) throws -> [MemoryEntry] {
        try readEntriesChecked(
            scope: scope,
            workspaceRootURL: workingDirectory?.standardizedFileURL,
            includeArchived: includeArchived,
            limit: limit
        )
    }

    func readEntriesChecked(
        scope: MemoryScope,
        workspaceRootURL: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) throws -> [MemoryEntry] {
        let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
        let entries = try Self.documentWriteCoordinator.withLock(for: document.fileURL) {
            try readEntriesForMutation(from: document)
        }
        return entries
            .filter { includeArchived || !$0.isArchived }
            .prefix(max(limit, 0))
            .map { $0 }
    }

    func searchEntriesChecked(
        query: String,
        scope: MemoryScope,
        workingDirectory: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) throws -> [MemoryEntry] {
        try rankedEntries(
            query: query,
            entries: readEntriesChecked(
                scope: scope,
                workspaceRootURL: workingDirectory?.standardizedFileURL,
                includeArchived: includeArchived,
                limit: .max
            ),
            limit: limit
        )
    }

    private func rankedEntries(
        query: String,
        entries: [MemoryEntry],
        limit: Int
    ) -> [MemoryEntry] {
        let normalizedQuery = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        var seenTerms = Set<String>()
        let terms = normalizedQuery
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && seenTerms.insert($0).inserted }
        guard !terms.isEmpty else {
            return entries.prefix(max(limit, 0)).map { $0 }
        }

        return entries
            .enumerated()
            .map { offset, entry in
                (
                    entry: entry,
                    offset: offset,
                    score: searchScore(
                        entry: entry,
                        query: normalizedQuery,
                        terms: terms
                    )
                )
            }
            .filter { $0.score > 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score {
                    return lhs.score > rhs.score
                }
                return lhs.offset < rhs.offset
            }
            .prefix(max(limit, 0))
            .map(\.entry)
    }

    @discardableResult
    public func writeEntry(
        content: String,
        scope: MemoryScope,
        workingDirectory: URL?
    ) throws -> MemoryEntry {
        try writeEntry(
            content: content,
            scope: scope,
            workspaceRootURL: workingDirectory?.standardizedFileURL
        )
    }

    @discardableResult
    public func writeEntry(
        content: String,
        scope: MemoryScope,
        workspaceRootURL: URL?
    ) throws -> MemoryEntry {
        let normalizedContent = MemoryEntry.normalizedContent(content)
        guard !normalizedContent.isEmpty else {
            throw MemoryServiceError.missingField("content")
        }

        let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
        return try Self.documentWriteCoordinator.withLock(for: document.fileURL) {
            var entries = try readEntriesForMutation(from: document)
            if let existingEntry = entries.first(where: {
                !$0.isArchived && $0.content.localizedCaseInsensitiveCompare(normalizedContent) == .orderedSame
            }) {
                return existingEntry
            }

            let entry = MemoryEntry(
                content: normalizedContent,
                scope: scope
            )
            entries.insert(entry, at: 0)
            try writeEntries(entries, to: document)
            Self.notifyMemoryEntriesChanged()
            return entry
        }
    }

    @discardableResult
    public func updateEntry(
        id: UUID,
        content: String,
        scope: MemoryScope,
        workspaceRootURL: URL?,
        updatedAt: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> MemoryEntry {
        let normalizedContent = MemoryEntry.normalizedContent(content)
        guard !normalizedContent.isEmpty else {
            throw MemoryServiceError.missingField("content")
        }

        let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
        return try Self.documentWriteCoordinator.withLock(for: document.fileURL) {
            var entries = try readEntriesForMutation(from: document)
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw MemoryServiceError.entryNotFound(id.uuidString)
            }

            entries[index].content = Self.contentWithUpdateMetadata(
                normalizedContent,
                existingEntry: entries[index],
                updatedAt: updatedAt,
                timeZone: timeZone
            )
            try writeEntries(entries, to: document)
            Self.notifyMemoryEntriesChanged()
            return entries[index]
        }
    }

    @discardableResult
    public func replaceEntry(
        id: UUID,
        content: String,
        scope: MemoryScope,
        workspaceRootURL: URL?
    ) throws -> MemoryEntry {
        let normalizedContent = MemoryEntry.normalizedContent(content)
        guard !normalizedContent.isEmpty else {
            throw MemoryServiceError.missingField("content")
        }

        let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
        return try Self.documentWriteCoordinator.withLock(for: document.fileURL) {
            var entries = try readEntriesForMutation(from: document)
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw MemoryServiceError.entryNotFound(id.uuidString)
            }

            entries[index].content = normalizedContent
            try writeEntries(entries, to: document)
            Self.notifyMemoryEntriesChanged()
            return entries[index]
        }
    }

    @discardableResult
    public func archiveEntry(
        id rawIdentifier: String,
        scope: MemoryScope?,
        workingDirectory: URL?
    ) throws -> MemoryEntry {
        try archiveEntry(
            id: rawIdentifier,
            scope: scope,
            workspaceRootURL: workingDirectory?.standardizedFileURL
        )
    }

    @discardableResult
    public func archiveEntry(
        id rawIdentifier: String,
        scope: MemoryScope?,
        workspaceRootURL: URL?
    ) throws -> MemoryEntry {
        guard let id = UUID(uuidString: rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MemoryServiceError.invalidIdentifier(rawIdentifier)
        }

        let documents = memoryDocuments(workspaceRootURL: workspaceRootURL)
            .filter { scope == nil || $0.scope == scope }
        for document in documents {
            let archivedEntry: MemoryEntry? = try Self.documentWriteCoordinator.withLock(for: document.fileURL) {
                var entries = try readEntriesForMutation(from: document)
                guard let index = entries.firstIndex(where: { $0.id == id }) else {
                    return nil
                }

                entries[index].isArchived = true
                try writeEntries(entries, to: document)
                Self.notifyMemoryEntriesChanged()
                return entries[index]
            }
            if let archivedEntry {
                return archivedEntry
            }
        }
        throw MemoryServiceError.entryNotFound(rawIdentifier)
    }

    @discardableResult
    public func setArchived(
        _ isArchived: Bool,
        id: UUID,
        scope: MemoryScope,
        workspaceRootURL: URL?
    ) throws -> MemoryEntry {
        let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
        return try Self.documentWriteCoordinator.withLock(for: document.fileURL) {
            var entries = try readEntriesForMutation(from: document)
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw MemoryServiceError.entryNotFound(id.uuidString)
            }
            entries[index].isArchived = isArchived
            try writeEntries(entries, to: document)
            Self.notifyMemoryEntriesChanged()
            return entries[index]
        }
    }

    public func deleteEntry(
        id: UUID,
        scope: MemoryScope,
        workspaceRootURL: URL?
    ) throws {
        let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
        try Self.documentWriteCoordinator.withLock(for: document.fileURL) {
            var entries = try readEntriesForMutation(from: document)
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw MemoryServiceError.entryNotFound(id.uuidString)
            }
            entries.remove(at: index)
            try writeEntries(entries, to: document)
            Self.notifyMemoryEntriesChanged()
        }
    }

    private static func contentWithUpdateMetadata(
        _ content: String,
        existingEntry: MemoryEntry,
        updatedAt: Date,
        timeZone: TimeZone
    ) -> String {
        var lines = MemoryEntry.normalizedContent(content)
            .components(separatedBy: .newlines)
        let metadata = MemoryEntryMetadata(content: content)
        if metadata.timestamp == nil {
            let timestamp = existingEntry.metadata.timestamp
                ?? timestampString(updatedAt, timeZone: timeZone)
            lines.insert("Timestamp: \(timestamp)", at: 0)
        }
        if metadata.updated == nil {
            let updated = timestampString(updatedAt, timeZone: timeZone)
            let insertionIndex = lines.firstIndex { line in
                line.trimmingCharacters(in: .whitespaces)
                    .lowercased()
                    .hasPrefix("timestamp:")
            }
            .map { $0 + 1 } ?? 0
            lines.insert("Updated: \(updated)", at: insertionIndex)
        }
        return lines.joined(separator: "\n")
    }

}
