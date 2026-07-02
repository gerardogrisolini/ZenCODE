//
//  MLXMemoryService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public final class MLXMemoryService {
    public static let filename = "MEMORY.md"
    public static let entriesDidChangeNotification = Notification.Name("MLXMemoryEntriesDidChange")
    public static let defaultGlobalMemoryContent: String = """
    # MEMORY.md

    Lightweight global project index for sessions that do not start inside a clear workspace.

    Use this file only for:
    - saved-session pointers keyed by project/workspace path
    - the latest saved session name/id for each project when one should be resumed
    - a pointer to the project MEMORY.md that should be read next
    - minimal cross-project routing notes

    Do not use this file for:
    - user preferences or operating rules
    - project implementation history
    - technical decisions, tests, file changes, or task logs
    - anything already clear from the current working directory

    ## Active

    ## Archived
    """

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
    let globalMemoryDirectoryURL: URL?
    /// Serializes read-modify-write operations on MEMORY.md files so concurrent
    /// writes cannot clobber each other (lost update). Recursive so root methods
    /// can call one another without deadlocking.
    private let writeLock = NSRecursiveLock()

    public init(
        fileManager: FileManager = .default,
        globalMemoryDirectoryURL: URL? = nil
    ) {
        self.fileManager = fileManager
        self.globalMemoryDirectoryURL = globalMemoryDirectoryURL
    }

    public static func notifyMemoryEntriesChanged() {
        NotificationCenter.default.post(name: entriesDidChangeNotification, object: nil)
    }

    public static func toolUsagePromptSection() -> String {
        return """
        Memory tools:
        Treat MEMORY.md as first-class durable context, but remember that its contents are not preloaded into this prompt.
        When a current working directory or project is clear, use project memory as the codebase journal; read or search it to answer resume questions like "where are we?" or "what should we do today?", then verify the current state with Git, files, builds, tests, or current user messages before acting.
        Use global memory only as a lightweight project/session index when there is no clear project, such as a generic session asking which project or saved session should be resumed. It may contain one active saved-session pointer per project. Do not consult global memory just to resume a project when the current working directory is already useful.
        Do not write user preferences, operating rules, project implementation history, technical decisions, tests, file changes, or task logs to global memory; global memory should only point to relevant project/workspace paths, their latest saved session, and where to read next.
        Saved-session pointers in global memory are maintained programmatically when a session is saved; do not duplicate them with model-authored `memory.write` calls.
        At the end of a substantial project turn, before the final answer, decide whether the project journal should be updated with `memory.write`.
        Write one project journal entry only when project state changed, a meaningful decision was made, a significant piece of work completed, a real blocker/caveat emerged, or a clear next step should survive future sessions.
        A project journal entry should be concise and structured with `Summary`, `State`, and `Next`; `memory.write` adds `Timestamp` automatically when missing.
        Do not write every command or tool call, raw outputs, detailed logs, large diffs, temporary task state, guesses, or facts already obvious from current files.
        Use `memory.archive` when a note is stale, superseded, incorrect, or no longer useful.
        Prefer fresh evidence from files, tools, builds, tests, or current user messages when it conflicts with memory.
        """
    }

    public func readEntries(
        scope: MLXMemoryScope?,
        for workspaceContext: XcodeWorkspaceContext?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MLXMemoryEntry] {
        readEntries(
            scope: scope,
            workspaceRootURL: workspaceRootURL(for: workspaceContext),
            includeArchived: includeArchived,
            limit: limit
        )
    }

    public func readEntries(
        scope: MLXMemoryScope?,
        workingDirectory: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MLXMemoryEntry] {
        readEntries(
            scope: scope,
            workspaceRootURL: workingDirectory?.standardizedFileURL,
            includeArchived: includeArchived,
            limit: limit
        )
    }

    public func readEntries(
        scope: MLXMemoryScope?,
        workspaceRootURL: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MLXMemoryEntry] {
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
        scope: MLXMemoryScope?,
        for workspaceContext: XcodeWorkspaceContext?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MLXMemoryEntry] {
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
        scope: MLXMemoryScope?,
        workingDirectory: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MLXMemoryEntry] {
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
        scope: MLXMemoryScope?,
        workspaceRootURL: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) -> [MLXMemoryEntry] {
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
        scope: MLXMemoryScope,
        workspaceContext: XcodeWorkspaceContext?
    ) throws -> MLXMemoryEntry {
        try writeEntry(
            content: content,
            scope: scope,
            workspaceRootURL: workspaceRootURL(for: workspaceContext)
        )
    }

    @discardableResult
    public func writeEntry(
        content: String,
        scope: MLXMemoryScope,
        workingDirectory: URL?
    ) throws -> MLXMemoryEntry {
        try writeEntry(
            content: content,
            scope: scope,
            workspaceRootURL: workingDirectory?.standardizedFileURL
        )
    }

    @discardableResult
    public func writeEntry(
        content: String,
        scope: MLXMemoryScope,
        workspaceRootURL: URL?
    ) throws -> MLXMemoryEntry {
        let normalizedContent = MLXMemoryEntry.normalizedContent(content)
        guard !normalizedContent.isEmpty else {
            throw MLXMemoryServiceError.missingField("content")
        }

        return try writeLock.withLock {
            let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
            var entries = readEntries(from: document)
            if let existingEntry = entries.first(where: {
                !$0.isArchived && $0.content.localizedCaseInsensitiveCompare(normalizedContent) == .orderedSame
            }) {
                return existingEntry
            }

            let entry = MLXMemoryEntry(
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
        scope: MLXMemoryScope,
        workspaceRootURL: URL?
    ) throws -> MLXMemoryEntry {
        let normalizedContent = MLXMemoryEntry.normalizedContent(content)
        guard !normalizedContent.isEmpty else {
            throw MLXMemoryServiceError.missingField("content")
        }

        return try writeLock.withLock {
            let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
            var entries = readEntries(from: document)
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw MLXMemoryServiceError.entryNotFound(id.uuidString)
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
        scope: MLXMemoryScope?,
        for workspaceContext: XcodeWorkspaceContext?
    ) throws -> MLXMemoryEntry {
        try archiveEntry(
            id: rawIdentifier,
            scope: scope,
            workspaceRootURL: workspaceRootURL(for: workspaceContext)
        )
    }

    @discardableResult
    public func archiveEntry(
        id rawIdentifier: String,
        scope: MLXMemoryScope?,
        workingDirectory: URL?
    ) throws -> MLXMemoryEntry {
        try archiveEntry(
            id: rawIdentifier,
            scope: scope,
            workspaceRootURL: workingDirectory?.standardizedFileURL
        )
    }

    @discardableResult
    public func archiveEntry(
        id rawIdentifier: String,
        scope: MLXMemoryScope?,
        workspaceRootURL: URL?
    ) throws -> MLXMemoryEntry {
        guard let id = UUID(uuidString: rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw MLXMemoryServiceError.invalidIdentifier(rawIdentifier)
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

            throw MLXMemoryServiceError.entryNotFound(rawIdentifier)
        }
    }

    @discardableResult
    public func setArchived(
        _ isArchived: Bool,
        id: UUID,
        scope: MLXMemoryScope,
        workspaceRootURL: URL?
    ) throws -> MLXMemoryEntry {
        return try writeLock.withLock {
            let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
            var entries = readEntries(from: document)
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw MLXMemoryServiceError.entryNotFound(id.uuidString)
            }
            entries[index].isArchived = isArchived
            try writeEntries(entries, to: document)
            Self.notifyMemoryEntriesChanged()
            return entries[index]
        }
    }

    public func deleteEntry(
        id: UUID,
        scope: MLXMemoryScope,
        workspaceRootURL: URL?
    ) throws {
        try writeLock.withLock {
            let document = try memoryDocument(scope: scope, workspaceRootURL: workspaceRootURL)
            var entries = readEntries(from: document)
            guard let index = entries.firstIndex(where: { $0.id == id }) else {
                throw MLXMemoryServiceError.entryNotFound(id.uuidString)
            }
            entries.remove(at: index)
            try writeEntries(entries, to: document)
            Self.notifyMemoryEntriesChanged()
        }
    }

    public func globalMemoryFileURL() -> URL {
        globalMemoryDirectoryURLResolved().appendingPathComponent(Self.filename)
    }

    @discardableResult
    public func recordSavedSessionIndexEntry(
        projectPath: String,
        sessionName: String,
        sessionID: String,
        savedAt: Date,
        timeZone: TimeZone = .current
    ) throws -> MLXMemoryEntry {
        let normalizedProjectPath = URL(fileURLWithPath: projectPath)
            .standardizedFileURL
            .path
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSessionName = sessionName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedProjectPath.isEmpty else {
            throw MLXMemoryServiceError.missingField("projectPath")
        }
        guard !normalizedSessionName.isEmpty else {
            throw MLXMemoryServiceError.missingField("sessionName")
        }
        guard !normalizedSessionID.isEmpty else {
            throw MLXMemoryServiceError.missingField("sessionID")
        }

        try archiveActiveSavedSessionIndexEntries(forProjectPath: normalizedProjectPath)
        return try writeEntry(
            content: """
            Kind: saved-session
            Timestamp: \(Self.timestampString(savedAt, timeZone: timeZone))
            Project: \(normalizedProjectPath)
            Session: \(normalizedSessionName)
            Session ID: \(normalizedSessionID)
            Next: load this saved session, then read the project MEMORY.md.
            """,
            scope: .global,
            workspaceRootURL: nil
        )
    }

    @discardableResult
    public func ensureGlobalMemoryFileExists() throws -> URL {
        let fileURL = globalMemoryFileURL().standardizedFileURL
        if fileManager.fileExists(atPath: fileURL.path),
           let content = try? String(contentsOf: fileURL, encoding: .utf8),
           !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fileURL
        }

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.defaultGlobalMemoryContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appending("\n")
            .write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL
    }

}
