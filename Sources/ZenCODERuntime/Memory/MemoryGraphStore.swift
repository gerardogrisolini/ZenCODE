//
//  MemoryGraphStore.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Actor-backed adapter over the vendored MemoryEngine graph engine.
//

import Foundation

/// Serializes read-modify-write sequences against one workspace graph.
///
/// The engine is already an actor, but ZenCODE's operations (deduplicating
/// write, content update, archive) are read-modify-write pairs that must not
/// interleave. This actor provides that transaction boundary.
package actor MemoryGraphStore {
    let graphURL: URL
    let engine: MemoryEngine
    /// Kept from `open`: `update`/`write` must embed with the provider the engine
    /// was opened with, or entries would carry vectors the engine refuses to compare.
    /// Internal so the re-embedding run (`MemoryGraphStore+Reembedding.swift`)
    /// embeds with the same provider.
    let embedder: (any EmbeddingProvider)?
    /// Whether recall on this store includes a request to an embedding
    /// endpoint; the turn coordinator sizes its deadline accordingly.
    nonisolated let hasEmbedder: Bool
    /// Shared with the engine so mutation-time embedding degradation is
    /// observable without making the operation fail.
    private let semanticFailureReporter: @Sendable (String) -> Void

    init(
        graphURL: URL,
        engine: MemoryEngine,
        embedder: (any EmbeddingProvider)?,
        semanticFailureReporter: @escaping @Sendable (String) -> Void = MemoryEmbeddingFallback.defaultReporter
    ) {
        self.graphURL = graphURL
        self.engine = engine
        self.embedder = embedder
        self.hasEmbedder = embedder != nil
        self.semanticFailureReporter = semanticFailureReporter
    }

    // MARK: - Opening

    /// Opens the persisted JSON graph, or an empty graph when it is absent.
    /// Opening is read-only; the first mutation persists the graph atomically.
    static func open(
        graphURL: URL,
        semanticFailureReporter: @escaping @Sendable (String) -> Void = MemoryEmbeddingFallback.defaultReporter
    ) async throws -> MemoryGraphStore {
        let embedder = MemoryEmbedding.provider()
        let persistence = JSONMemoryPersistence(url: graphURL)
        let initialGraph: MemoryGraph
        if FileManager.default.fileExists(atPath: graphURL.path) {
            initialGraph = try await persistence.load()
        } else {
            initialGraph = MemoryGraph()
        }

        // The engine persists the full graph atomically on the first mutation.
        let engine = MemoryEngine(
            graph: initialGraph,
            embedder: embedder,
            persistence: persistence,
            selector: ScoreThresholdMemorySelector(),
            semanticFailureReporter: semanticFailureReporter
        )
        return MemoryGraphStore(
            graphURL: graphURL,
            engine: engine,
            embedder: embedder,
            semanticFailureReporter: semanticFailureReporter
        )
    }

    // MARK: - Reads

    // Store-level reads use one coherent snapshot per request: the engine
    // reloads the durable graph under its write lock, overlays local pending
    // recall maintenance onto the copy, and never persists.
    //
    // Every read and mutation takes a `visibility`: the entries one profile
    // owns (see `MemoryAuthorScope`). Reads run on the snapshot restricted to
    // it, mutations treat any other entry as missing. `nil` addresses the whole
    // graph, for maintenance and tests; sessions always pass a scope.

    /// Journal page: newest first, after `offset` matching entries.
    func entries(
        includeArchived: Bool,
        offset: Int,
        limit: Int,
        filter: MemoryEntryFilter,
        visibility: MemoryAuthorScope? = nil
    ) async throws -> [GraphEntry] {
        let graph = try await engine.freshSnapshotForReadOnly().restricted(to: visibility)
        return Self.ordered(graph.memories.values)
            .filter { (includeArchived || $0.active) && filter.matches($0) }
            .dropFirst(max(offset, 0))
            .prefix(max(limit, 0))
            .map { $0 }
    }

    func search(
        query: String,
        includeArchived: Bool,
        limit: Int,
        filter: MemoryEntryFilter = .none,
        visibility: MemoryAuthorScope? = nil
    ) async throws -> [GraphEntry] {
        let cappedLimit = max(limit, 0)
        // Read-only: `memory.search` must not mutate retrievalCount/confidence/links
        // or fail on a save error, so it skips the maintenance `recall` applies.
        // One coherent snapshot serves both the active pipeline and the archived
        // section below, restricted once: the ranking statistics are those of
        // the visible entries.
        let fresh = try await engine.freshSnapshotForReadOnly().restricted(to: visibility)
        // An explicit lookup returns the ranked candidates — lexical/semantic
        // hits, plus their graph neighbourhood only when the cascade is turned
        // on (`maxDepth`, off by default) — up to the requested limit. The
        // recall selector's relative threshold is a guard for what gets injected
        // unasked into a turn; a caller that asked for N results judges them.
        let recalled = try await engine.searchReadOnlyDetailed(
            query,
            scope: .all,
            graph: fresh,
            limit: cappedLimit
        ).candidates
        var active = recalled.map(\.memory).filter { $0.active && filter.matches($0) }

        guard includeArchived else {
            return Array(active.prefix(cappedLimit))
        }

        // Inactive nodes are excluded from both `recall` and the engine's
        // `lexicalBM25` by design, so archived entries are ranked separately,
        // with the same scoring over the archived subset.
        let archivedEntries = fresh.memories.values.filter { !$0.active && filter.matches($0) }
        let archived = MemorySearch.lexicalBM25(
            memories: Array(archivedEntries),
            query: query,
            scope: .all,
            limit: cappedLimit,
            requireActive: false
        ).compactMap { fresh.memories[$0.id] }

        // Reserve part of the budget for archived hits. Appending them after a
        // full page of active results would make an explicitly requested
        // archived entry unreachable whenever the active set fills the limit.
        let archivedBudget = min(archived.count, cappedLimit / 2)
        let activeBudget = max(cappedLimit - archivedBudget, 0)
        active = Array(active.prefix(activeBudget))

        var seen = Set<String>()
        return (active + archived)
            .filter { seen.insert($0.id).inserted }
            .prefix(cappedLimit)
            .map { $0 }
    }

    func entry(id: String, visibility: MemoryAuthorScope? = nil) async throws -> GraphEntry? {
        try await engine.freshSnapshotForReadOnly().restricted(to: visibility).memories[id]
    }

    // MARK: - Mutations

    /// Result of a write: the stored entry, whether it was created, the
    /// active entries that lexically overlap it and, for tags the entry
    /// introduced, existing tags they resemble.
    struct WriteResult: Sendable {
        let entry: GraphEntry
        let created: Bool
        let similar: [SimilarEntry]
        let tagHints: [TagHint]
    }

    /// An active entry that already covers much of a newly written one.
    struct SimilarEntry: Sendable {
        let entry: GraphEntry
        /// BM25 score of the existing entry for the new content, relative to
        /// the new entry's own score for it: 1 means the same words.
        let similarity: Float
    }

    /// A tag the written entry introduced, with existing tags that share a
    /// word with it, most used first.
    struct TagHint: Sendable {
        struct Existing: Sendable {
            let name: String
            let count: Int
        }

        let tag: String
        let existing: [Existing]
    }

    /// Appends a new entry, or returns the existing active entry with the same
    /// content. The duplicate check and insertion share one engine transaction:
    /// each `await` on the engine lets another call re-enter, so a separate
    /// snapshot-decide-write would let concurrent writes both insert. For a
    /// created entry it also reports the active entries it overlaps so the
    /// caller can consolidate instead of keeping two notes on one fact. The
    /// write itself is never blocked: judging whether the overlap is the same
    /// fact remains the caller's call.
    /// - Parameter generatedTimestamp: `true` only when the caller prepended the
    ///   `Timestamp:` annotation itself; the sole case where that line is ignored
    ///   for duplicate detection.
    /// - Parameter visibility: the writing profile's scope: the duplicate check,
    ///   `similar` and `tagHints` only consider its entries, and a created entry
    ///   carries its author. Another author's identical entry is not a
    ///   duplicate.
    func writeDetailed(
        content: String,
        category: GraphCategory,
        tags: [String],
        generatedTimestamp: Bool = false,
        visibility: MemoryAuthorScope? = nil
    ) async throws -> WriteResult {
        let normalizedContent = MemoryContent.normalized(content)
        guard !normalizedContent.isEmpty else {
            throw MemoryServiceError.missingField("content")
        }
        let duplicationKey: MemoryDeduplicationKey = generatedTimestamp
            ? .autoTimestamped(normalizedContent)
            : .literal(normalizedContent)

        // Fast path only: an already-visible duplicate costs no embedding or
        // transaction; the check inside the transaction is authoritative.
        if let existing = Self.activeDuplicate(
            matching: duplicationKey,
            in: await engine.snapshot(),
            visibility: visibility
        ) {
            return WriteResult(entry: existing, created: false, similar: [], tagHints: [])
        }

        let embedded = try await MemoryEmbeddingFallback.embed(
            normalizedContent,
            with: embedder,
            operation: "write",
            reporter: semanticFailureReporter
        )
        let id = MemoryIdentifier.makeNew()
        let (entry, created) = try await engine.transaction { graph -> (GraphEntry, Bool) in
            if let existing = Self.activeDuplicate(matching: duplicationKey, in: graph, visibility: visibility) {
                return (existing, false)
            }
            var entry = GraphEntry(
                id: id,
                category: category,
                content: normalizedContent,
                tags: tags,
                source: MemorySource.tool,
                trust: .medium,
                scope: .project,
                embedding: embedded.values,
                embeddingModel: embedded.model,
                autoGeneratedTimestamp: generatedTimestamp,
                author: visibility?.author
            )
            entry.refreshSearchText()
            graph.addMemory(entry)
            return (entry, true)
        }
        guard created else {
            return WriteResult(entry: entry, created: false, similar: [], tagHints: [])
        }
        // Outside the lock, on the graph that now contains the new entry,
        // restricted to the writer's entries.
        let snapshot = await engine.snapshot().restricted(to: visibility)
        return WriteResult(
            entry: entry,
            created: true,
            similar: Self.similarActiveEntries(to: entry, in: snapshot),
            tagHints: Self.tagHints(for: entry, in: snapshot)
        )
    }

    /// For every tag that only the written entry carries, the existing tags
    /// sharing a word with it (`linux-validation` → `linux`, `validation`),
    /// so vocabulary converges instead of growing one single-use tag per note.
    static func tagHints(for entry: GraphEntry, in graph: MemoryGraph, limit: Int = 5) -> [TagHint] {
        let usage: [(name: String, count: Int)] = graph.tags.values
            .map { (name: $0.name, count: Int($0.count)) }
            .filter { $0.count > 0 }
        return entry.tags.compactMap { tag -> TagHint? in
            let ownCount = usage.first { $0.name == tag }?.count ?? 0
            guard ownCount <= 1 else { return nil }
            let words = Set(MemorySearch.tokens(tag))
            guard !words.isEmpty else { return nil }
            let related = usage
                .filter { $0.name != tag && !words.isDisjoint(with: MemorySearch.tokens($0.name)) }
                .sorted { lhs, rhs in
                    if lhs.count != rhs.count { return lhs.count > rhs.count }
                    return lhs.name < rhs.name
                }
                .prefix(limit)
                .map { TagHint.Existing(name: $0.name, count: $0.count) }
            guard !related.isEmpty else { return nil }
            return TagHint(tag: tag, existing: Array(related))
        }
    }

    /// Fraction of the new entry's own BM25 score (for its content as the
    /// query) that an existing entry must reach to be reported as similar.
    static let similarityThreshold: Float = 0.5
    static let similarityLimit = 3

    /// Active entries whose words cover much of `entry`'s content, scored
    /// relative to the entry itself so the measure does not depend on corpus
    /// statistics. Only the engine's lexical scoring is used: no embedding
    /// request, no network.
    static func similarActiveEntries(
        to entry: GraphEntry,
        in graph: MemoryGraph,
        threshold: Float = similarityThreshold,
        limit: Int = similarityLimit
    ) -> [SimilarEntry] {
        let corpus = graph.memories.values.filter(\.active)
        guard corpus.count > 1 else { return [] }
        let ranking = MemorySearch.lexicalBM25(
            memories: Array(corpus),
            query: entry.content,
            scope: .all,
            limit: corpus.count
        )
        guard let selfScore = ranking.first(where: { $0.id == entry.id })?.score, selfScore > 0 else {
            return []
        }
        return ranking
            .filter { $0.id != entry.id && $0.score / selfScore >= threshold }
            .prefix(limit)
            .compactMap { scored in
                graph.memories[scored.id].map { SimilarEntry(entry: $0, similarity: scored.score / selfScore) }
            }
    }

    /// Replaces the content of an existing entry in place, preserving its id,
    /// creation date, archive state and edges (deliberately NOT `supersede`), so
    /// an id handed to the model stays valid.
    ///
    /// The merge is applied to the entry *as the transaction finds it*, so a
    /// concurrent archive survives an update and vice versa.
    ///
    /// The async embedding cannot be computed inside the transaction and depends
    /// on the stored text (the preserved `Timestamp`), so it is predicted from a
    /// snapshot, verified by the transaction, and re-embedded on a mismatch.
    ///
    /// An entry `visibility` does not allow is not found. The author is never
    /// changed: an entry without one keeps none (see `MemoryAuthorScope`).
    func update(
        id rawIdentifier: String,
        content: String,
        tags: [String]?,
        updatedAt: Date,
        timeZone: TimeZone,
        visibility: MemoryAuthorScope? = nil
    ) async throws -> GraphEntry {
        let id = try MemoryIdentifier.validated(rawIdentifier)
        let normalizedContent = MemoryContent.normalized(content)
        guard !normalizedContent.isEmpty else {
            throw MemoryServiceError.missingField("content")
        }
        guard let current = await engine.snapshot().memories[id],
              visibility?.allows(current) ?? true else {
            throw MemoryServiceError.entryNotFound(rawIdentifier)
        }

        var embedded = try await embedded(
            MemoryService.contentWithUpdateMetadata(
                normalizedContent,
                existingEntry: current,
                updatedAt: updatedAt,
                timeZone: timeZone
            )
        )
        // Without an embedder there is no vector to re-check.
        let verifiesEmbedding = embedder != nil

        for attempt in 0..<Self.maximumUpdateAttempts {
            let pending = embedded
            // Last round: accept a slightly stale embedding rather than fail a
            // user-visible update; it degrades ranking, never corrupts content.
            let acceptsStaleEmbedding = attempt == Self.maximumUpdateAttempts - 1
            let outcome = try await engine.transaction { graph -> UpdateOutcome in
                guard var entry = graph.memories[id],
                      visibility?.allows(entry) ?? true else {
                    return .missing
                }
                let finalContent = MemoryService.contentWithUpdateMetadata(
                    normalizedContent,
                    existingEntry: entry,
                    updatedAt: updatedAt,
                    timeZone: timeZone
                )
                guard acceptsStaleEmbedding
                        || !verifiesEmbedding
                        || pending.content == finalContent else {
                    return .staleEmbedding(finalContent)
                }
                entry.content = finalContent
                // `memory.update` receives caller-authored replacement content.
                // Do not carry timestamp provenance from the previous value:
                // an explicit machine-shaped Timestamp in the replacement must
                // remain semantically significant for later deduplication.
                entry.autoGeneratedTimestamp = false
                if let tags {
                    entry.tags = tags
                }
                entry.updatedAt = updatedAt
                entry.refreshSearchText()
                entry.setEmbedding(pending.values, model: pending.model)
                graph.addMemory(entry)
                return .updated(entry)
            }

            switch outcome {
            case let .updated(entry):
                return entry
            case .missing:
                throw MemoryServiceError.entryNotFound(rawIdentifier)
            case let .staleEmbedding(finalContent):
                embedded = try await self.embedded(finalContent)
            }
        }
        throw MemoryServiceError.entryNotFound(rawIdentifier)
    }

    /// Archives or restores an entry. Only the archive flag and `updatedAt`
    /// change; archiving keeps the vector.
    ///
    /// A restore also gives the entry a vector when the store has an embedder
    /// and the entry has none from its model (the re-embedding run clears the
    /// vectors of archived entries). The vector is computed after the restore
    /// transaction, so an endpoint failure only degrades the entry to BM25 —
    /// reported like any other mutation fallback — and never fails the
    /// restore. It is saved in a second transaction, only if the entry is still
    /// active, has the content that was embedded and still has no compatible
    /// vector. An entry `visibility` does not allow is not found.
    func setArchived(
        _ isArchived: Bool,
        id rawIdentifier: String,
        visibility: MemoryAuthorScope? = nil
    ) async throws -> GraphEntry {
        let id = try MemoryIdentifier.validated(rawIdentifier)
        let updatedAt = Date()
        let entry = try await engine.transaction { graph in
            guard var entry = graph.memories[id],
                  visibility?.allows(entry) ?? true else {
                throw MemoryServiceError.entryNotFound(rawIdentifier)
            }
            // Only the archive flag is touched, so an update that commits
            // around this one keeps its content.
            entry.active = !isArchived
            entry.updatedAt = updatedAt
            graph.addMemory(entry)
            return entry
        }
        guard !isArchived else {
            return entry
        }
        return await embeddedAfterRestore(entry)
    }

    /// The restored entry with a vector from the store's embedder when it
    /// lacked a compatible one, or `entry` unchanged. Never throws: the restore
    /// is already durable, so a failing endpoint, a failing save or a
    /// cancellation only leaves the entry without a vector.
    private func embeddedAfterRestore(_ entry: GraphEntry) async -> GraphEntry {
        guard let embedder,
              entry.active,
              !entry.embeddingMatches(model: embedder.modelID) else {
            return entry
        }
        do {
            let embedded = try await MemoryEmbeddingFallback.embed(
                entry.content,
                with: embedder,
                operation: "restore",
                reporter: semanticFailureReporter
            )
            guard let values = embedded.values, let model = embedded.model else {
                return entry
            }
            let id = entry.id
            let content = entry.content
            return try await engine.transaction { graph -> GraphEntry in
                guard var current = graph.memories[id] else {
                    return entry
                }
                guard current.active,
                      current.content == content,
                      !current.embeddingMatches(model: model) else {
                    return current
                }
                current.setEmbedding(values, model: model)
                graph.memories[id] = current
                return current
            }
        } catch is CancellationError {
            return entry
        } catch {
            semanticFailureReporter(
                MemorySemanticFallbackDiagnostics.mutationFallbackMessage(
                    operation: "restore",
                    error: error
                )
            )
            return entry
        }
    }

    func delete(id rawIdentifier: String, visibility: MemoryAuthorScope? = nil) async throws {
        let id = try MemoryIdentifier.validated(rawIdentifier)
        let removed = try await engine.transaction { graph -> Bool in
            guard let entry = graph.memories[id], visibility?.allows(entry) ?? true else {
                return false
            }
            graph.removeMemory(id: id)
            return true
        }
        guard removed else {
            throw MemoryServiceError.entryNotFound(rawIdentifier)
        }
    }

    // MARK: - Cleanup

    /// What ``cleanup(_:now:)`` would change right now. Reads one coherent
    /// snapshot and mutates nothing: no save, no backup.
    package func cleanupPreview(
        _ policy: MemoryCleanupPolicy,
        now: Date = Date()
    ) async throws -> MemoryCleanupReport {
        let graph = try await engine.freshSnapshotForReadOnly()
        return MemoryCleanup.plan(
            graph,
            policy: policy,
            now: now,
            embeddingModel: embedder?.modelID
        ).report
    }

    /// Cleans the graph in one engine transaction and returns the report of what
    /// was applied.
    ///
    /// The plan is recomputed on the graph the transaction reloads under the
    /// file lock, so the report can differ from an earlier preview when another
    /// process wrote in between. A plan that changes nothing leaves the graph
    /// file and the backup alone. Otherwise the pre-cleanup graph and its
    /// vectors file are first copied next to the graph
    /// (`JSONMemoryPersistence.backupURLs(forGraphAt:)`, replacing any
    /// previous copy) inside the same transaction: a failing backup throws
    /// before anything is saved.
    @discardableResult
    package func cleanup(
        _ policy: MemoryCleanupPolicy,
        now: Date = Date()
    ) async throws -> MemoryCleanupReport {
        let embeddingModel = embedder?.modelID
        let graphURL = graphURL
        return try await engine.transaction { graph in
            let (cleaned, report) = MemoryCleanup.plan(
                graph,
                policy: policy,
                now: now,
                embeddingModel: embeddingModel
            )
            guard !report.isEmpty else { return report }
            try JSONMemoryPersistence.writeBackup(of: graph, forGraphAt: graphURL)
            graph = cleaned
            return report
        }
    }

    // MARK: - Helpers

    /// Each retry is caused by a *concurrent* commit on the same entry; the last
    /// round commits unconditionally.
    private static let maximumUpdateAttempts = 3

    private enum UpdateOutcome: Sendable {
        case updated(GraphEntry)
        case missing
        /// The transaction produced a different text than the one embedded.
        case staleEmbedding(String)
    }

    /// An embedding paired with the exact text it describes.
    private struct EmbeddedContent: Sendable {
        let content: String
        let values: [Float]?
        let model: String?
    }

    private func embedded(_ content: String) async throws -> EmbeddedContent {
        let embedded = try await MemoryEmbeddingFallback.embed(
            content,
            with: embedder,
            operation: "update",
            reporter: semanticFailureReporter
        )
        return EmbeddedContent(
            content: content,
            values: embedded.values,
            model: embedded.model
        )
    }

    /// The active entry a write would duplicate, if any: newest-first (deterministic
    /// when nodes share content) and case-insensitive; what may be ignored is
    /// decided by the key (see ``MemoryDeduplicationKey``). Only entries
    /// `visibility` allows count.
    private static func activeDuplicate(
        matching key: MemoryDeduplicationKey,
        in graph: MemoryGraph,
        visibility: MemoryAuthorScope?
    ) -> GraphEntry? {
        ordered(graph.memories.values).first { entry in
            entry.active && key.matches(entry) && (visibility?.allows(entry) ?? true)
        }
    }

    /// Journal order: newest first, with a stable tie-break.
    private static func ordered(
        _ entries: some Sequence<GraphEntry>
    ) -> [GraphEntry] {
        entries.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }
}
