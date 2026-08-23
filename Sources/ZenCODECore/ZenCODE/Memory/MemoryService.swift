//
//  MemoryService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

/// Async facade over the per-workspace MemoryEngine graph.
///
/// The durable store is the graph, not `MEMORY.md`. An existing `MEMORY.md` is
/// imported on first open (in memory only — see ``MemoryGraphStore/open``) and
/// then left untouched on disk as a legacy human-readable artifact.
///
/// `@unchecked Sendable`: the only stored property is a `FileManager`, which is
/// not formally `Sendable` but is documented as safe to call from multiple
/// threads. This type uses it exclusively for path resolution and existence
/// checks, and never assigns a delegate. All mutable state lives behind
/// `MemoryGraphStore`.
public final class MemoryService: @unchecked Sendable {
    public static let filename = "MEMORY.md"
    public static let entriesDidChangeNotification = Notification.Name("MemoryEntriesDidChange")
    public static let defaultProjectMemoryContent: String = """
    # MEMORY.md

    Durable project journal for this workspace.

    Use this file for:
    - concise handoff entries for significant completed work
    - a release or publication record once the version, artifacts, and validation are known
    - current validated project state
    - blockers, caveats, or decisions that affect future work
    - the next logical step for the codebase

    Preferred entry shape:
    - Timestamp: YYYY-MM-DD HH:mm TimeZone
    - Updated: YYYY-MM-DD HH:mm TimeZone, added when an existing entry changes
    - Summary: durable milestone or change, not a command-by-command history
    - State: current validated state, including version/tag and important caveats when relevant
    - Next: next logical open step, or `None currently` when no useful follow-up remains

    Do not use this file for:
    - every command or tool call
    - raw outputs, detailed logs, or large diffs
    - temporary progress, speculative plans, or unverified claims
    - general user preferences or operating rules
    - information already obvious from current files

    ## Active

    ## Archived
    """

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public static func notifyMemoryEntriesChanged() {
        NotificationCenter.default.post(name: entriesDidChangeNotification, object: nil)
    }

    public static func toolUsagePromptSection() -> String {
        toolUsagePromptSection(readOnly: false)
    }

    /// Contextual memory-tool guidance for a constrained tool surface.
    /// This intentionally remains internal: callers keep the established public
    /// no-argument prompt API while session composition can avoid suggesting
    /// unavailable mutations to read-only agents.
    static func toolUsagePromptSection(readOnly: Bool) -> String {
        if readOnly {
            return """
            Memory tools (read-only):
            Treat durable project memory as first-class context, but remember that its contents are not preloaded into this prompt.
            Project memory is a graph. Before each turn ZenCODE automatically recalls entries it deems relevant and injects them as a labelled block. Use `memory.search` for a focused lookup or `memory.read` with `detail: "index"` for a compact overview when more context is needed.
            Semantic similarity requires a configured embedding endpoint; without one, retrieval and recall use BM25 keyword matching.
            Always verify retrieved entries against Git, files, builds, tests, releases, or current user messages before acting; fresh evidence wins when it conflicts with memory.
            This tool surface is read-only: do not claim to create, update, archive, or publish durable memory. Preserve durable facts or release evidence in your response so it can be recorded by an appropriate writer.
            """
        }
        return """
        Memory tools:
        Treat durable project memory as first-class context, but remember that its contents are not preloaded into this prompt.
        Project memory is a graph. Before each turn ZenCODE automatically recalls the entries it deems most relevant to the current prompt and injects them as a labelled block in the outgoing message — you do not need to call a tool for that. When you need more, use `memory.search` (keyword and, when an embedding endpoint is configured, semantic retrieval with reciprocal-rank fusion and graph expansion) or `memory.read` with `detail: "index"` for a compact overview of the full store.
        Semantic similarity requires a configured embedding endpoint; without one, retrieval and recall are pure BM25 keyword matching.
        Always verify the entries you retrieve against Git, files, builds, tests, or current user messages before acting.
        Journal a durable fact when substantial work reaches a verified handoff; architecture, compatibility, dependencies, or persisted formats change; a durable decision, blocker, or caveat affects future work; prior recorded state becomes obsolete; or a release, version, or publication is completed. For a release, record the version or identifier, what was published, and concrete evidence such as its tag, artifact, build, test, or deployment result; a version or changelog edit alone is not evidence that it was published.
        Before writing, search for an active entry about the same durable project fact. Use `memory.update` when that entry should be brought current instead of appending a duplicate; if nothing materially changed, do not write.
        `memory.update` rewrites the entry in place: the entry keeps its id, its creation date and its archive state, so an id stays valid after an update. It preserves the original `Timestamp` and adds an `Updated` timestamp when you omit them.
        Do not write user preferences or operating rules to memory; keep entries scoped to durable project facts.
        Saved-session pointers are maintained programmatically in the sessions index when a session is saved; do not duplicate them with memory tools.
        At the end of a substantial project turn, before the final answer, decide whether project memory should be created, updated, archived, or left unchanged. When a trigger above produced a completed, verified durable fact and mutation tools are available, perform the appropriate mutation before finishing; do not record intentions, unimplemented plans, or unverified results.
        A project journal entry should be concise and structured with `Summary` (the durable milestone or change), `State` (the current verified state and relevant caveats), and `Next` (the next useful open step, or `None currently`); `memory.write` adds `Timestamp` automatically when missing.
        Add `tags` when writing so related entries link together and later retrieval can follow those links.
        Do not write every command or tool call, raw outputs, detailed logs, large diffs, temporary task state, guesses, speculative plans, transient chatter, or facts already obvious from current files.
        Use `memory.archive` when a note is stale, incorrect, or no longer useful; archived entries stop influencing retrieval but are not deleted.
        Prefer fresh evidence from files, tools, builds, tests, or current user messages when it conflicts with memory.
        """
    }

    public static func timestampString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(formatter.string(from: date)) \(timeZone.identifier)"
    }

    /// Absolute path of the graph backing a workspace.
    public func graphURL(workspaceRootURL: URL) -> URL {
        MemoryGraphLocation.graphURL(for: workspaceRootURL, fileManager: fileManager)
    }

    // MARK: - Reads

    public func readEntries(
        workspaceRootURL: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) async throws -> [MemoryEntry] {
        try await store(for: workspaceRootURL)
            .entries(includeArchived: includeArchived, limit: limit)
            .map { MemoryEntry($0) }
    }

    public func searchEntries(
        query: String,
        workspaceRootURL: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) async throws -> [MemoryEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw MemoryServiceError.missingField("query")
        }
        return try await store(for: workspaceRootURL).search(
            query: normalizedQuery,
            includeArchived: includeArchived,
            limit: limit
        ).map { MemoryEntry($0) }
    }

    public func entry(
        id: String,
        workspaceRootURL: URL?
    ) async throws -> MemoryEntry? {
        try await store(for: workspaceRootURL)
            .entry(id: MemoryIdentifier.validated(id))
            .map { MemoryEntry($0) }
    }

    // MARK: - Mutations

    @discardableResult
    public func writeEntry(
        content: String,
        workspaceRootURL: URL?,
        category: MemoryCategory = .fact,
        tags: [String] = []
    ) async throws -> MemoryEntry {
        try await writeEntryOutcome(
            content: content,
            workspaceRootURL: workspaceRootURL,
            category: category,
            tags: tags
        ).entry
    }

    /// Writes an entry and reports whether it was actually created.
    ///
    /// The store deduplicates against active entries, so a write can legitimately
    /// resolve to an existing entry. `writeEntry` must keep returning a plain
    /// `MemoryEntry` to preserve the public 1.1.x contract, so the created flag
    /// is propagated internally through this variant instead. The tool layer
    /// uses it to report a truthful `written` / `deduplicated` result rather than
    /// claiming every call wrote something.
    ///
    /// `generatedTimestamp` must stay `false` for every caller that did not
    /// itself prepend the `Timestamp:` annotation: the public 1.1.x entry point
    /// below therefore keeps a literal duplicate check.
    func writeEntryOutcome(
        content: String,
        workspaceRootURL: URL?,
        category: MemoryCategory = .fact,
        tags: [String] = [],
        generatedTimestamp: Bool = false
    ) async throws -> MemoryWriteOutcome {
        let result = try await store(for: workspaceRootURL).write(
            content: content,
            category: category.engineCategory,
            tags: tags,
            generatedTimestamp: generatedTimestamp
        )
        if result.created {
            Self.notifyMemoryEntriesChanged()
        }
        return MemoryWriteOutcome(
            entry: MemoryEntry(result.entry),
            created: result.created
        )
    }

    /// Replaces the content of an entry in place, preserving its id.
    @discardableResult
    public func updateEntry(
        id: String,
        content: String,
        workspaceRootURL: URL?,
        tags: [String]? = nil,
        updatedAt: Date = Date(),
        timeZone: TimeZone = .current
    ) async throws -> MemoryEntry {
        let entry = try await store(for: workspaceRootURL).update(
            id: id,
            content: content,
            tags: tags,
            updatedAt: updatedAt,
            timeZone: timeZone
        )
        Self.notifyMemoryEntriesChanged()
        return MemoryEntry(entry)
    }

    @discardableResult
    public func archiveEntry(
        id: String,
        workspaceRootURL: URL?
    ) async throws -> MemoryEntry {
        try await setArchived(true, id: id, workspaceRootURL: workspaceRootURL)
    }

    @discardableResult
    public func setArchived(
        _ isArchived: Bool,
        id: String,
        workspaceRootURL: URL?
    ) async throws -> MemoryEntry {
        let entry = try await store(for: workspaceRootURL)
            .setArchived(isArchived, id: id)
        Self.notifyMemoryEntriesChanged()
        return MemoryEntry(entry)
    }

    public func deleteEntry(
        id: String,
        workspaceRootURL: URL?
    ) async throws {
        try await store(for: workspaceRootURL).delete(id: id)
        Self.notifyMemoryEntriesChanged()
    }

    // MARK: - Store resolution

    private func store(for workspaceRootURL: URL?) async throws -> MemoryGraphStore {
        guard let workspaceRootURL else {
            throw MemoryServiceError.scopeUnavailable("project")
        }
        let standardizedRoot = workspaceRootURL.standardizedFileURL
        return try await MemoryGraphStoreRegistry.shared.store(
            forWorkspaceRoot: standardizedRoot,
            graphURL: MemoryGraphLocation.graphURL(
                for: standardizedRoot,
                fileManager: fileManager
            )
        )
    }

    // MARK: - Journal metadata

    /// Preserves the original `Timestamp` and stamps `Updated` when the caller
    /// did not supply them.
    static func contentWithUpdateMetadata(
        _ content: String,
        existingEntry: GraphEntry,
        updatedAt: Date,
        timeZone: TimeZone
    ) -> String {
        var lines = MemoryContent.normalized(content)
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

/// Outcome of a memory write, including whether an entry was actually created.
///
/// Internal on purpose: the public write API keeps returning `MemoryEntry` to
/// preserve the 1.1.x contract, and this carries the extra bit the tool layer
/// needs to describe the result honestly.
struct MemoryWriteOutcome: Sendable {
    let entry: MemoryEntry
    let created: Bool

    /// The store found an equivalent active entry and reused it.
    var deduplicated: Bool { !created }
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
            return "MEMORY.md has an unrecognized format at \(path); it was left unchanged and not migrated."
        }
    }
}
