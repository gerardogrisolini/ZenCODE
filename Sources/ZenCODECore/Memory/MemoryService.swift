//
//  MemoryService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

/// Async facade over the per-workspace MemoryEngine graph.
///
/// The durable store is exclusively the per-workspace JSON graph.
///
/// `@unchecked Sendable`: the only stored property is a `FileManager`, which is
/// not formally `Sendable` but is documented as safe to call from multiple
/// threads. This type uses it exclusively for path resolution and existence
/// checks, and never assigns a delegate. All mutable state lives behind
/// `MemoryGraphStore`.
public final class MemoryService: @unchecked Sendable {
    public static let entriesDidChangeNotification = Notification.Name("MemoryEntriesDidChange")
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
            Project memory is a graph. Before each turn ZenCODE automatically recalls entries it deems relevant and injects them as a labelled `<project-memory>` block. When no such block is present, either nothing relevant was found or recall was unavailable for this turn: call `memory.search` before concluding that no prior context exists. Use `memory.search` for a focused lookup, `memory.get` for one entry by id, or `memory.read` with `detail: "index"` for a compact overview when more context is needed; `tags` and `category` narrow reads and searches, and `offset` pages through the journal.
            Semantic similarity requires a configured embedding endpoint; without one, retrieval and recall use BM25 keyword matching.
            Always verify retrieved entries against Git, files, builds, tests, releases, or current user messages before acting; fresh evidence wins when it conflicts with memory.
            This tool surface is read-only: do not claim to create, update, archive, or publish durable memory. Preserve durable facts or release evidence in your response so it can be recorded by an appropriate writer.
            """
        }
        return """
        Memory tools:
        Treat durable project memory as first-class context, but remember that its contents are not preloaded into this prompt.
        Project memory is a graph. Before each turn ZenCODE automatically recalls the entries it deems most relevant to the current prompt and injects them as a labelled `<project-memory>` block in the outgoing message. When no such block is present, either nothing relevant was found or recall was unavailable for this turn: call `memory.search` before concluding that no prior context exists. When you need more, use `memory.search` (keyword and, when an embedding endpoint is configured, semantic retrieval with reciprocal-rank fusion and graph expansion), `memory.get` for one entry by id, or `memory.read` with `detail: "index"` for a compact overview of the full store; `tags` and `category` narrow reads and searches, and `offset` pages through the journal.
        Semantic similarity requires a configured embedding endpoint; without one, retrieval and recall are pure BM25 keyword matching.
        Always verify the entries you retrieve against Git, files, builds, tests, or current user messages before acting.
        Journal a durable fact when substantial work reaches a verified handoff; architecture, compatibility, dependencies, or persisted formats change; a durable decision, blocker, or caveat affects future work; prior recorded state becomes obsolete; or a release, version, or publication is completed. For a release, record the version or identifier, what was published, and concrete evidence such as its tag, artifact, build, test, or deployment result; a version or changelog edit alone is not evidence that it was published.
        Before writing, search for an active entry about the same durable project fact. Use `memory.update` when that entry should be brought current instead of appending a duplicate; if nothing materially changed, do not write. `memory.write` reports similar active entries: if one covers the same fact, consolidate with `memory.update` and archive the other.
        `memory.update` rewrites the entry in place: the entry keeps its id, its creation date and its archive state, so an id stays valid after an update. It preserves the original `Timestamp` and stamps `Updated` with the time of the update.
        Do not write user preferences or operating rules to memory; keep entries scoped to durable project facts.
        Saved-session pointers are maintained programmatically in the sessions index when a session is saved; do not duplicate them with memory tools.
        At the end of a substantial project turn, before the final answer, decide whether project memory should be created, updated, archived, or left unchanged. When a trigger above produced a completed, verified durable fact and mutation tools are available, perform the appropriate mutation before finishing; do not record intentions, unimplemented plans, or unverified results.
        A project journal entry should be concise and structured with `Summary` (the durable milestone or change), `State` (the current verified state and relevant caveats), and `Next` (the next useful open step, or `None currently`); `memory.write` adds `Timestamp` automatically when missing.
        Add `tags` when writing so related entries link together and later retrieval can follow those links.
        Do not write every command or tool call, raw outputs, detailed logs, large diffs, temporary task state, guesses, speculative plans, transient chatter, or facts already obvious from current files.
        Use `memory.archive` when a note is stale, incorrect, or no longer useful; archived entries stop influencing retrieval but are not deleted, and `memory.restore` brings one back.
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
        graphURL(target: .workspace(workspaceRootURL))
    }

    /// Absolute path of the graph backing `target`.
    public func graphURL(target: MemoryGraphTarget) -> URL {
        MemoryGraphLocation.graphURL(for: target, fileManager: fileManager)
    }

    // MARK: - Reads

    public func readEntries(
        workspaceRootURL: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) async throws -> [MemoryEntry] {
        try await readEntries(
            workspaceRootURL: workspaceRootURL,
            includeArchived: includeArchived,
            offset: 0,
            limit: limit,
            filter: .none
        )
    }

    /// Journal page: newest first, skipping `offset` matching entries, narrowed
    /// by `filter`.
    public func readEntries(
        workspaceRootURL: URL?,
        includeArchived: Bool,
        offset: Int,
        limit: Int,
        filter: MemoryEntryFilter
    ) async throws -> [MemoryEntry] {
        try await readEntries(
            target: workspaceRootURL.map(MemoryGraphTarget.workspace),
            includeArchived: includeArchived,
            offset: offset,
            limit: limit,
            filter: filter
        )
    }

    /// Journal page of the graph addressed by `target`.
    public func readEntries(
        target: MemoryGraphTarget?,
        includeArchived: Bool,
        offset: Int,
        limit: Int,
        filter: MemoryEntryFilter
    ) async throws -> [MemoryEntry] {
        try await store(for: target)
            .entries(includeArchived: includeArchived, offset: offset, limit: limit, filter: filter)
            .map { MemoryEntry($0) }
    }

    public func searchEntries(
        query: String,
        workspaceRootURL: URL?,
        includeArchived: Bool = false,
        limit: Int
    ) async throws -> [MemoryEntry] {
        try await searchEntries(
            query: query,
            workspaceRootURL: workspaceRootURL,
            includeArchived: includeArchived,
            limit: limit,
            filter: .none
        )
    }

    /// Ranked lookup narrowed by `filter`.
    public func searchEntries(
        query: String,
        workspaceRootURL: URL?,
        includeArchived: Bool,
        limit: Int,
        filter: MemoryEntryFilter
    ) async throws -> [MemoryEntry] {
        try await searchEntries(
            query: query,
            target: workspaceRootURL.map(MemoryGraphTarget.workspace),
            includeArchived: includeArchived,
            limit: limit,
            filter: filter
        )
    }

    /// Ranked lookup in the graph addressed by `target`, narrowed by `filter`.
    public func searchEntries(
        query: String,
        target: MemoryGraphTarget?,
        includeArchived: Bool,
        limit: Int,
        filter: MemoryEntryFilter
    ) async throws -> [MemoryEntry] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            throw MemoryServiceError.missingField("query")
        }
        return try await store(for: target).search(
            query: normalizedQuery,
            includeArchived: includeArchived,
            limit: limit,
            filter: filter
        ).map { MemoryEntry($0) }
    }

    public func entry(
        id: String,
        workspaceRootURL: URL?
    ) async throws -> MemoryEntry? {
        try await entry(
            id: id,
            target: workspaceRootURL.map(MemoryGraphTarget.workspace)
        )
    }

    public func entry(
        id: String,
        target: MemoryGraphTarget?
    ) async throws -> MemoryEntry? {
        try await store(for: target)
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
        try await writeEntryOutcome(
            content: content,
            target: workspaceRootURL.map(MemoryGraphTarget.workspace),
            category: category,
            tags: tags,
            generatedTimestamp: generatedTimestamp
        )
    }

    /// `writeEntryOutcome` against the graph addressed by `target`.
    func writeEntryOutcome(
        content: String,
        target: MemoryGraphTarget?,
        category: MemoryCategory = .fact,
        tags: [String] = [],
        generatedTimestamp: Bool = false
    ) async throws -> MemoryWriteOutcome {
        let result = try await store(for: target).writeDetailed(
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
            created: result.created,
            similar: result.similar.map {
                MemoryWriteOutcome.Similar(entry: MemoryEntry($0.entry), similarity: $0.similarity)
            },
            tagHints: result.tagHints.map { hint in
                MemoryWriteOutcome.TagHint(
                    tag: hint.tag,
                    existing: hint.existing.map { MemoryWriteOutcome.TagHint.Existing(name: $0.name, count: $0.count) }
                )
            }
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
        try await updateEntry(
            id: id,
            content: content,
            target: workspaceRootURL.map(MemoryGraphTarget.workspace),
            tags: tags,
            updatedAt: updatedAt,
            timeZone: timeZone
        )
    }

    /// Replaces the content of an entry of the graph addressed by `target`.
    @discardableResult
    public func updateEntry(
        id: String,
        content: String,
        target: MemoryGraphTarget?,
        tags: [String]? = nil,
        updatedAt: Date = Date(),
        timeZone: TimeZone = .current
    ) async throws -> MemoryEntry {
        let entry = try await store(for: target).update(
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

    /// Brings an archived entry back into retrieval and recall.
    @discardableResult
    public func restoreEntry(
        id: String,
        workspaceRootURL: URL?
    ) async throws -> MemoryEntry {
        try await setArchived(false, id: id, workspaceRootURL: workspaceRootURL)
    }

    @discardableResult
    public func setArchived(
        _ isArchived: Bool,
        id: String,
        workspaceRootURL: URL?
    ) async throws -> MemoryEntry {
        try await setArchived(
            isArchived,
            id: id,
            target: workspaceRootURL.map(MemoryGraphTarget.workspace)
        )
    }

    @discardableResult
    public func setArchived(
        _ isArchived: Bool,
        id: String,
        target: MemoryGraphTarget?
    ) async throws -> MemoryEntry {
        let entry = try await store(for: target)
            .setArchived(isArchived, id: id)
        Self.notifyMemoryEntriesChanged()
        return MemoryEntry(entry)
    }

    public func deleteEntry(
        id: String,
        workspaceRootURL: URL?
    ) async throws {
        try await deleteEntry(
            id: id,
            target: workspaceRootURL.map(MemoryGraphTarget.workspace)
        )
    }

    public func deleteEntry(
        id: String,
        target: MemoryGraphTarget?
    ) async throws {
        try await store(for: target).delete(id: id)
        Self.notifyMemoryEntriesChanged()
    }

    // MARK: - Store resolution

    private func store(for target: MemoryGraphTarget?) async throws -> MemoryGraphStore {
        guard let target else {
            throw MemoryServiceError.scopeUnavailable("project")
        }
        return try await MemoryGraphStoreRegistry.shared.store(
            graphURL: MemoryGraphLocation.graphURL(
                for: target,
                fileManager: fileManager
            )
        )
    }

    // MARK: - Journal metadata

    /// Preserves the original `Timestamp` (adding one from the update time
    /// when the entry never had it) and stamps `Updated` with the time of the
    /// update, replacing any `Updated` line the caller carried over so the
    /// annotation always reflects the last real change.
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
        let updated = "Updated: \(timestampString(updatedAt, timeZone: timeZone))"
        if let existingIndex = lines.firstIndex(where: { line in
            line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("updated:")
        }) {
            lines[existingIndex] = updated
        } else {
            let insertionIndex = lines.firstIndex { line in
                line.trimmingCharacters(in: .whitespaces)
                    .lowercased()
                    .hasPrefix("timestamp:")
            }
            .map { $0 + 1 } ?? 0
            lines.insert(updated, at: insertionIndex)
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
    /// An active entry that already covers much of the written content.
    struct Similar: Sendable {
        let entry: MemoryEntry
        /// Lexical overlap relative to the new entry itself, in (0, 1].
        let similarity: Float
    }

    /// A tag the write introduced, with existing tags sharing a word with it.
    struct TagHint: Sendable {
        struct Existing: Sendable {
            let name: String
            let count: Int
        }

        let tag: String
        let existing: [Existing]
    }

    let entry: MemoryEntry
    let created: Bool
    /// Active entries overlapping a created entry, strongest first; empty for
    /// a deduplicated write.
    let similar: [Similar]
    /// Single-use tags of a created entry that resemble existing ones.
    let tagHints: [TagHint]

    init(entry: MemoryEntry, created: Bool, similar: [Similar] = [], tagHints: [TagHint] = []) {
        self.entry = entry
        self.created = created
        self.similar = similar
        self.tagHints = tagHints
    }

    /// The store found an equivalent active entry and reused it.
    var deduplicated: Bool { !created }
}

public enum MemoryServiceError: LocalizedError {
    case missingField(String)
    case scopeUnavailable(String)
    case invalidIdentifier(String)
    case entryNotFound(String)

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
        }
    }
}
