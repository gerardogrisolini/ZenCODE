//
//  MemoryService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

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
    /// Serializes read-modify-write operations on MEMORY.md files so concurrent
    /// writes cannot clobber each other (lost update). Recursive so root methods
    /// can call one another without deadlocking.
    private let writeLock = NSRecursiveLock()

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
        Use project memory as the codebase journal; read or search it to answer resume questions like "where are we?" or "what should we do today?", then verify the current state with Git, files, builds, tests, or current user messages before acting.
        Do not write user preferences or operating rules to memory; keep entries scoped to durable project facts.
        Saved-session pointers are maintained programmatically in the sessions index when a session is saved; do not duplicate them with `memory.write` calls.
        At the end of a substantial project turn, before the final answer, decide whether the project journal should be updated with `memory.write`.
        Write one project journal entry only when project state changed, a meaningful decision was made, a significant piece of work completed, a real blocker/caveat emerged, or a clear next step should survive future sessions.
        A project journal entry should be concise and structured with `Summary`, `State`, and `Next`; `memory.write` adds `Timestamp` automatically when missing.
        Do not write every command or tool call, raw outputs, detailed logs, large diffs, temporary task state, guesses, or facts already obvious from current files.
        Use `memory.archive` when a note is stale, superseded, incorrect, or no longer useful.
        Prefer fresh evidence from files, tools, builds, tests, or current user messages when it conflicts with memory.
        """
    }

    public func readEntries(
        scope: MemoryScope?,
        for workspaceContext: XcodeWorkspaceContext?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MemoryEntry] {
        readEntries(
            scope: scope,
            workspaceRootURL: workspaceRootURL(for: workspaceContext),
            includeArchived: includeArchived,
            limit: limit
        )
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
        for workspaceContext: XcodeWorkspaceContext?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MemoryEntry] {
        searchEntries(
            query: query,
            scope: scope,
            workspaceRootURL: workspaceRootURL(for: workspaceContext),
            includeArchived: includeArchived,
            limit: limit
        )
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
        let terms = query
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else {
            return readEntries(
                scope: scope,
                workspaceRootURL: workspaceRootURL,
                includeArchived: includeArchived,
                limit: limit
            )
        }

        return readEntries(
            scope: scope,
            workspaceRootURL: workspaceRootURL,
            includeArchived: includeArchived,
            limit: .max
        )
        .map { entry in
            (entry: entry, score: searchScore(entry: entry, terms: terms))
        }
        .filter { $0.score > 0 }
        .sorted { lhs, rhs in
            if lhs.score != rhs.score {
                return lhs.score > rhs.score
            }
            return lhs.entry.scope.rawValue < rhs.entry.scope.rawValue
        }
        .prefix(max(limit, 0))
        .map(\.entry)
    }

    @discardableResult
    public func writeEntry(
        content: String,
        scope: MemoryScope,
        workspaceContext: XcodeWorkspaceContext?
    ) throws -> MemoryEntry {
        try writeEntry(
            content: content,
            scope: scope,
            workspaceRootURL: workspaceRootURL(for: workspaceContext)
        )
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

        return try writeLock.withLock {
            let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
            var entries = readEntries(from: document)
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

        return try writeLock.withLock {
            let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
            var entries = readEntries(from: document)
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
        for workspaceContext: XcodeWorkspaceContext?
    ) throws -> MemoryEntry {
        try archiveEntry(
            id: rawIdentifier,
            scope: scope,
            workspaceRootURL: workspaceRootURL(for: workspaceContext)
        )
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

        return try writeLock.withLock {
            let documents = memoryDocuments(workspaceRootURL: workspaceRootURL)
                .filter { scope == nil || $0.scope == scope }
            for document in documents {
                var entries = readEntries(from: document)
                guard let index = entries.firstIndex(where: { $0.id == id }) else {
                    continue
                }

                entries[index].isArchived = true
                try writeEntries(entries, to: document)
                Self.notifyMemoryEntriesChanged()
                return entries[index]
            }

            throw MemoryServiceError.entryNotFound(rawIdentifier)
        }
    }

    @discardableResult
    public func setArchived(
        _ isArchived: Bool,
        id: UUID,
        scope: MemoryScope,
        workspaceRootURL: URL?
    ) throws -> MemoryEntry {
        return try writeLock.withLock {
            let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
            var entries = readEntries(from: document)
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
        try writeLock.withLock {
            let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
            var entries = readEntries(from: document)
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw MemoryServiceError.entryNotFound(id.uuidString)
            }
            entries.remove(at: index)
            try writeEntries(entries, to: document)
            Self.notifyMemoryEntriesChanged()
        }
    }

}
