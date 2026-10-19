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
actor MemoryGraphStore {
    let graphURL: URL
    let engine: MemoryEngine
    /// Kept from `open`: `update`/`write` must embed with the provider the engine
    /// was opened with, or entries would carry vectors the engine refuses to compare.
    private let embedder: (any EmbeddingProvider)?
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
            // Product recall is intentionally dependency-free. `learn(from:)`
            // remains an internal engine seam, but opening a product store never
            // installs a network-backed extractor or makes a generation request.
            extractor: NoopMemoryExtractor(),
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

    func entries(includeArchived: Bool, limit: Int) async throws -> [GraphEntry] {
        try await entries(includeArchived: includeArchived, offset: 0, limit: limit, filter: .none)
    }

    /// Journal page: newest first, after `offset` matching entries.
    func entries(
        includeArchived: Bool,
        offset: Int,
        limit: Int,
        filter: MemoryEntryFilter
    ) async throws -> [GraphEntry] {
        let graph = try await engine.freshSnapshotForReadOnly()
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
        filter: MemoryEntryFilter = .none
    ) async throws -> [GraphEntry] {
        let cappedLimit = max(limit, 0)
        // Read-only: `memory.search` must not mutate retrievalCount/confidence/links
        // or fail on a save error, so it skips the maintenance `recall` applies.
        // One coherent snapshot serves both the active pipeline and the archived
        // section below.
        let fresh = try await engine.freshSnapshotForReadOnly()
        // An explicit lookup returns the ranked candidates — lexical/semantic
        // hits plus their graph neighbourhood — up to the requested limit. The
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

    func entry(id: String) async throws -> GraphEntry? {
        try await engine.freshSnapshotForReadOnly().memories[id]
    }

    // MARK: - Automatic turn pipeline

    /// Runs the engine's full analyze → retrieve → select → format pipeline and
    /// returns the ready-to-inject memory block (empty when nothing was selected).
    ///
    /// Deliberately NOT `MemoryEngine.submitContext(_:)` / `takePending()`:
    /// `MemoryEngine.pending` is one unkeyed slot and `MemoryGraphStoreRegistry`
    /// shares one engine per workspace across every session, sub-agent and tool
    /// call, so overlapping turns would hand one session another's memories.
    /// This per-call path keeps each retrieval bound to the prompt that asked.
    func context(
        for prompt: String,
        scope: GraphScope = .all
    ) async throws -> String {
        try await engine.context(for: prompt, scope: scope)
    }

    /// Same memory block using only local ranking: the deadline fallback for
    /// automatic recall. Requires an embedding provider (without one `context(for:)`
    /// is already local BM25). Read-only, so running it beside the full semantic
    /// recall cannot double-apply retrieval maintenance.
    func lexicalFallbackContext(
        for prompt: String,
        scope: GraphScope = .all
    ) async throws -> String? {
        guard embedder != nil else { return nil }
        return try await engine.lexicalContextReadOnly(
            for: prompt,
            scope: scope,
            graph: try await engine.freshSnapshotForReadOnly()
        )
    }

    /// Runs the engine's extractor over `context` and stores what it returns.
    /// Product stores use `NoopMemoryExtractor`, so this is a no-op there; it
    /// remains for tests that inject a deterministic extractor.
    ///
    /// Deliberately NOT `MemoryEngine.learn(from:)`: the engine mints
    /// library-shaped ids (`mem_<millis>_<uuid>`) while every ZenCODE maintenance
    /// path goes through `MemoryIdentifier.validated` (canonical UUIDs only), so
    /// `memory.update`/`memory.archive` could not touch such entries; and `write`'s
    /// normalization and duplicate rule must apply to injected drafts too.
    ///
    /// The batch is one engine transaction, so the duplicate check also covers
    /// repeats within a batch and a failing save stores none of it.
    @discardableResult
    func learn(from context: String) async throws -> [GraphEntry] {
        let drafts = try await engine.extract(from: context)
        var prepared: [GraphEntry] = []
        prepared.reserveCapacity(drafts.count)
        for draft in drafts {
            let normalizedContent = MemoryContent.normalized(draft.content)
            guard !normalizedContent.isEmpty else { continue }
            let embedded = try await MemoryEmbeddingFallback.embed(
                normalizedContent,
                with: embedder,
                operation: "learn",
                reporter: semanticFailureReporter
            )
            var entry = GraphEntry(
                id: MemoryIdentifier.makeNew(),
                category: draft.category,
                content: normalizedContent,
                tags: draft.tags,
                source: draft.source ?? MemorySource.learn,
                trust: draft.trust,
                scope: draft.scope,
                embedding: embedded.values,
                embeddingModel: embedded.model,
                confidence: draft.confidence
            )
            entry.refreshSearchText()
            prepared.append(entry)
        }
        guard !prepared.isEmpty else {
            return []
        }

        let batch = prepared
        // Re-check cancellation just before the atomic transaction to keep the
        // all-or-nothing contract.
        try Task.checkCancellation()
        return try await engine.transaction { graph in
            var stored: [GraphEntry] = []
            for entry in batch {
                // Extracted drafts carry no generated annotation, so their
                // content is compared exactly as authored.
                guard Self.activeDuplicate(
                    matching: .literal(entry.content),
                    in: graph
                ) == nil else {
                    continue
                }
                graph.addMemory(entry)
                stored.append(entry)
            }
            return stored
        }
    }

    /// Flushes the in-memory graph to disk (an explicit checkpoint after direct writes).
    func saveGraph() async throws {
        try await engine.save()
    }

    /// Flushes only automatic-recall maintenance. In particular this must not
    /// persist a deferred insert represented by `needsSave`.
    func flushRecallMaintenance() async throws {
        try await engine.flushRecallMaintenance()
    }

    // MARK: - Mutations

    /// Appends a new entry, or returns the existing active entry with the same
    /// content. The duplicate check and insertion share one engine transaction:
    /// each `await` on the engine lets another call re-enter, so a separate
    /// snapshot-decide-write would let concurrent writes both insert.
    /// - Parameter generatedTimestamp: `true` only when the caller prepended the
    ///   `Timestamp:` annotation itself; the sole case where that line is ignored
    ///   for duplicate detection.
    func write(
        content: String,
        category: GraphCategory,
        tags: [String],
        generatedTimestamp: Bool = false
    ) async throws -> (entry: GraphEntry, created: Bool) {
        let outcome = try await writeDetailed(
            content: content,
            category: category,
            tags: tags,
            generatedTimestamp: generatedTimestamp
        )
        return (outcome.entry, outcome.created)
    }

    /// Result of a write: the stored entry, whether it was created, and the
    /// active entries that lexically overlap it when it was created.
    struct WriteResult: Sendable {
        let entry: GraphEntry
        let created: Bool
        let similar: [SimilarEntry]
    }

    /// An active entry that already covers much of a newly written one.
    struct SimilarEntry: Sendable {
        let entry: GraphEntry
        /// BM25 score of the existing entry for the new content, relative to
        /// the new entry's own score for it: 1 means the same words.
        let similarity: Float
    }

    /// Writes like ``write(content:category:tags:generatedTimestamp:)`` and,
    /// for a created entry, reports the active entries it overlaps so the
    /// caller can consolidate instead of keeping two notes on one fact. The
    /// write itself is never blocked: judging whether the overlap is the same
    /// fact remains the caller's call.
    func writeDetailed(
        content: String,
        category: GraphCategory,
        tags: [String],
        generatedTimestamp: Bool = false
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
            in: await engine.snapshot()
        ) {
            return WriteResult(entry: existing, created: false, similar: [])
        }

        let embedded = try await MemoryEmbeddingFallback.embed(
            normalizedContent,
            with: embedder,
            operation: "write",
            reporter: semanticFailureReporter
        )
        let id = MemoryIdentifier.makeNew()
        let (entry, created) = try await engine.transaction { graph -> (GraphEntry, Bool) in
            if let existing = Self.activeDuplicate(matching: duplicationKey, in: graph) {
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
                autoGeneratedTimestamp: generatedTimestamp
            )
            entry.refreshSearchText()
            graph.addMemory(entry)
            return (entry, true)
        }
        guard created else {
            return WriteResult(entry: entry, created: false, similar: [])
        }
        // Outside the lock, on the graph that now contains the new entry.
        let similar = Self.similarActiveEntries(to: entry, in: await engine.snapshot())
        return WriteResult(entry: entry, created: true, similar: similar)
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
    func update(
        id rawIdentifier: String,
        content: String,
        tags: [String]?,
        updatedAt: Date,
        timeZone: TimeZone
    ) async throws -> GraphEntry {
        let id = try MemoryIdentifier.validated(rawIdentifier)
        let normalizedContent = MemoryContent.normalized(content)
        guard !normalizedContent.isEmpty else {
            throw MemoryServiceError.missingField("content")
        }
        guard let current = await engine.snapshot().memories[id] else {
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
                guard var entry = graph.memories[id] else {
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

    func setArchived(_ isArchived: Bool, id rawIdentifier: String) async throws -> GraphEntry {
        let id = try MemoryIdentifier.validated(rawIdentifier)
        let updatedAt = Date()
        return try await engine.transaction { graph in
            guard var entry = graph.memories[id] else {
                throw MemoryServiceError.entryNotFound(rawIdentifier)
            }
            // Only the archive flag is touched, so an update that commits
            // around this one keeps its content.
            entry.active = !isArchived
            entry.updatedAt = updatedAt
            graph.addMemory(entry)
            return entry
        }
    }

    func delete(id rawIdentifier: String) async throws {
        let id = try MemoryIdentifier.validated(rawIdentifier)
        guard try await engine.forget(id: id) != nil else {
            throw MemoryServiceError.entryNotFound(rawIdentifier)
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
    /// decided by the key (see ``MemoryDeduplicationKey``).
    private static func activeDuplicate(
        matching key: MemoryDeduplicationKey,
        in graph: MemoryGraph
    ) -> GraphEntry? {
        ordered(graph.memories.values).first { $0.active && key.matches($0) }
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

// MARK: - Conservative automatic writer (manual mutation semantics are unchanged)
extension MemoryGraphStore {
    struct LearningSnapshot: Sendable {
        let entries: [GraphEntry]
        let comparison: [String: String]
    }

    /// Term-coverage score used by the automatic writer to pick the lexically
    /// relevant notes it shows for deduplication; an empty query matches every
    /// entry. `memory.search` ranks with BM25 instead (see `search`).
    static func lexicalScore(_ entry: GraphEntry, query: String) -> Int {
        let normalizedQuery = query
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return 1
        }
        let haystack = entry.searchableText
        var score = 0
        if haystack.contains(normalizedQuery) {
            score += 50
        }
        var seenTerms = Set<String>()
        let terms = normalizedQuery
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty && seenTerms.insert($0).inserted }
        guard !terms.isEmpty else {
            return score
        }
        var matchedTerms = 0
        for term in terms where haystack.contains(term) {
            matchedTerms += 1
            score += 10
        }
        if matchedTerms == terms.count {
            score += 25
        }
        return score
    }

    func learningSnapshot(query: String = "") async throws -> LearningSnapshot? {
        let graph = try await engine.freshSnapshotForReadOnly()
        let active = graph.memories.values.filter(\.active)
        let comparison = Dictionary(uniqueKeysWithValues: active.map { ($0.id, $0.content) })
        let scored: [(entry: GraphEntry, score: Int)] = active.map { entry in
            (entry: entry, score: Self.lexicalScore(entry, query: query))
        }
        let relevant = scored.filter { $0.score > 0 }
        let ranked = relevant.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.entry.id < rhs.entry.id
            }
            return lhs.score > rhs.score
        }
        var entries: [GraphEntry] = []
        var characters = 0
        for (entry, _) in ranked {
            guard entries.count < 24, characters + entry.content.count <= 8000,
                  MemoryLearningPrivacy.accepts(entry.content, limit: 1500) else { continue }
            entries.append(entry)
            characters += entry.content.count
        }
        return LearningSnapshot(entries: entries, comparison: comparison)
    }

    /// Atomic current-state/dedup recheck, including manual writes performed
    /// during proposal generation. Any changed comparison set causes a no-op.
    func commitLearning(
        content: String,
        existingID: String?,
        snapshot: LearningSnapshot,
        permit: MemoryLearningPermit,
        event: UUID
    ) async throws -> Bool {
        guard MemoryLearningPrivacy.accepts(content, limit: 1000), permit.canPropose else { return false }
        let expected = snapshot.comparison
        if let existingID, !snapshot.entries.contains(where: { $0.id == existingID }) { return false }
        try Task.checkCancellation()
        return try await engine.transaction { graph in
            try Task.checkCancellation()
            let current = Dictionary(uniqueKeysWithValues: graph.memories.values.filter(\.active).map { ($0.id, $0.content) })
            guard current == expected else { return false }
            let key = Self.learningComparisonKey(content)
            if current.values.contains(where: { Self.learningComparisonKey($0) == key }) { return false }
            // Approximate lexical near-duplicates are rejected unless the model
            // identified that very lookup ID as the entry to update.
            let words = Set(key.split(separator: " "))
            for (id, value) in current where id != existingID {
                let other = Set(Self.learningComparisonKey(value).split(separator: " "))
                let union = words.union(other).count
                if union > 0, Double(words.intersection(other).count) / Double(union) >= 0.8 { return false }
            }
            var updatedContent = content
            if let existingID, let entry = graph.memories[existingID] {
                guard entry.active, entry.scope == .project else { return false }
                // Automatic updates only enrich: never erase manually authored
                // information to fit the budget. An overlong merge is a no-op.
                guard !Self.learningComparisonKey(entry.content).contains(key) else { return false }
                updatedContent = MemoryService.contentWithUpdateMetadata(
                    entry.content + "\nVerified update:\n" + content, existingEntry: entry,
                    updatedAt: Date(), timeZone: .current)
                guard MemoryLearningPrivacy.accepts(updatedContent, limit: 1000) else { return false }
            }
            guard permit.reserve(event: event) else { return false }
            if let existingID {
                guard var entry = graph.memories[existingID], entry.active, entry.scope == .project else { return false }
                entry.content = updatedContent
                entry.updatedAt = Date()
                entry.autoGeneratedTimestamp = false
                entry.setEmbedding(nil, model: nil)
                entry.refreshSearchText()
                graph.addMemory(entry)
            } else {
                var entry = GraphEntry(id: MemoryIdentifier.makeNew(), category: .fact,
                                       content: content, tags: ["automatic", "verified-project"],
                                       source: MemorySource.learn, trust: .medium, scope: .project)
                entry.refreshSearchText()
                graph.addMemory(entry)
            }
            return true
        }
    }

    private static func learningComparisonKey(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("Timestamp:") && !$0.hasPrefix("Updated:") && !$0.hasPrefix("Sources:") }
            .joined(separator: " ").lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
