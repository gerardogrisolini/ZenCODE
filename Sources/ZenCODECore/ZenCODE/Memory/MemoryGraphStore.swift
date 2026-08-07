//
//  MemoryGraphStore.swift
//  ZenCODE
//
//  Actor-backed adapter over the vendored ZenMemory graph engine.
//

import Foundation
import ZenMemory

/// Serializes read-modify-write sequences against one workspace graph.
///
/// The engine is already an actor, but ZenCODE's operations (deduplicating
/// write, content update, archive) are read-modify-write pairs that must not
/// interleave. This actor provides that transaction boundary; it is the
/// graph-era replacement for `FileTransactionCoordinator.withLock(for:)` on
/// MEMORY.md. `FileTransactionCoordinator` itself is unchanged and still serves
/// `SavedSessionsStore`.
actor MemoryGraphStore {
    let graphURL: URL
    private let engine: ZenMemory

    private init(graphURL: URL, engine: ZenMemory) {
        self.graphURL = graphURL
        self.engine = engine
    }

    // MARK: - Opening and migration

    /// Opens the graph for a workspace, migrating a legacy MEMORY.md exactly once.
    ///
    /// Idempotence gate: the presence of the graph file. Migration runs only
    /// when no graph file exists yet; the migration always saves, so the gate
    /// closes permanently after the first open. Entry identity is derived
    /// deterministically from the journal, so even a forced re-run would
    /// converge on the same nodes instead of duplicating them.
    static func open(
        graphURL: URL,
        workspaceRootURL: URL
    ) async throws -> MemoryGraphStore {
        // `FileManager.default` is used deliberately: this runs inside a
        // detached task, and `FileManager` is not `Sendable`, so an injected
        // instance must not cross the isolation boundary. Path resolution
        // (which is what an injected file manager influences) has already
        // happened by the time `graphURL` is computed.
        let fileManager = FileManager.default
        let embedder = MemoryEmbedding.provider()
        let persistence = JSONMemoryPersistence(url: graphURL)

        if !fileManager.fileExists(atPath: graphURL.path) {
            let migrated = try await migratedGraph(
                workspaceRootURL: workspaceRootURL,
                embedder: embedder,
                fileManager: fileManager
            )
            try await persistence.save(migrated)
        }

        let engine = try await ZenMemory.open(
            persistence: persistence,
            embedder: embedder,
            selector: ScoreThresholdMemorySelector()
        )
        return MemoryGraphStore(graphURL: graphURL, engine: engine)
    }

    /// Builds the initial graph from the legacy journal, losslessly.
    private static func migratedGraph(
        workspaceRootURL: URL,
        embedder: (any EmbeddingProvider)?,
        fileManager: FileManager
    ) async throws -> MemoryGraph {
        var graph = MemoryGraph()
        let journalURL = MemoryGraphLocation.legacyJournalURL(for: workspaceRootURL)

        switch LegacyMemoryJournal.read(at: journalURL, fileManager: fileManager) {
        case .missing:
            return graph
        case .unusable:
            // The journal exists but cannot be parsed safely. Refuse to migrate
            // rather than start an empty graph and strand the user's entries.
            throw MemoryServiceError.invalidDocument(journalURL.path)
        case let .loaded(legacyEntries):
            // The journal is newest-first. Preserve that order exactly: use the
            // entry's own Timestamp when it parses, but never let an entry sort
            // above the one that precedes it in the document. Entries without a
            // usable Timestamp inherit a slot just below their predecessor
            // instead of defaulting to "now", which would hoist undated legacy
            // entries to the top of the journal.
            let importedAt = Date()
            var previousCreatedAt: Date?
            for legacy in legacyEntries {
                let ceiling = previousCreatedAt?.addingTimeInterval(-1)
                let parsed = MemoryEntryMetadata(content: legacy.content).timestampDate
                let createdAt: Date = switch (parsed, ceiling) {
                case let (.some(parsed), .some(ceiling)): min(parsed, ceiling)
                case let (.some(parsed), .none): parsed
                case let (.none, .some(ceiling)): ceiling
                case (.none, .none): importedAt
                }
                previousCreatedAt = createdAt

                var entry = MemoryEntry(
                    id: MemoryIdentifier.canonical(legacy.id),
                    category: .fact,
                    content: legacy.content,
                    tags: [],
                    source: migrationSource,
                    trust: .medium,
                    scope: .project,
                    createdAt: createdAt,
                    updatedAt: createdAt,
                    embedding: try await embedder?.embed(legacy.content),
                    embeddingModel: embedder?.modelID
                )
                entry.active = !legacy.isArchived
                graph.addMemory(entry)
            }
            return graph
        }
    }

    static let migrationSource = "memory-md-migration"

    // MARK: - Reads

    func entries(includeArchived: Bool, limit: Int) async -> [MemoryEntry] {
        let graph = await engine.snapshot()
        return Self.ordered(graph.memories.values)
            .filter { includeArchived || $0.active }
            .prefix(max(limit, 0))
            .map { $0 }
    }

    func search(
        query: String,
        includeArchived: Bool,
        limit: Int
    ) async throws -> [MemoryEntry] {
        let cappedLimit = max(limit, 0)
        // Active entries go through the engine's hybrid retrieval
        // (semantic + BM25 fused, then graph cascade).
        let recalled = try await engine.recall(query, scope: .all)
        var active = recalled.map(\.memory).filter(\.active)

        guard includeArchived else {
            return Array(active.prefix(cappedLimit))
        }

        // Inactive nodes are excluded from both `recall` and the engine's
        // `lexicalBM25` by design, so archived entries are matched separately.
        let graph = await engine.snapshot()
        let archived = Self.ordered(graph.memories.values.filter { !$0.active })
            .compactMap { entry -> (entry: MemoryEntry, score: Int)? in
                let score = Self.lexicalScore(entry, query: query)
                return score > 0 ? (entry, score) : nil
            }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.entry.id < rhs.entry.id
            }
            .map(\.entry)

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

    func entry(id: String) async -> MemoryEntry? {
        await engine.snapshot().memories[id]
    }

    // MARK: - Mutations

    /// Appends a new entry, or returns the existing active entry with the same
    /// content instead of creating a duplicate.
    func write(
        content: String,
        category: MemoryCategory,
        tags: [String]
    ) async throws -> (entry: MemoryEntry, created: Bool) {
        let normalizedContent = MemoryContent.normalized(content)
        guard !normalizedContent.isEmpty else {
            throw MemoryServiceError.missingField("content")
        }

        let graph = await engine.snapshot()
        if let existing = Self.ordered(graph.memories.values).first(where: {
            $0.active && $0.content.localizedCaseInsensitiveCompare(normalizedContent) == .orderedSame
        }) {
            return (existing, false)
        }

        let entry = try await engine.remember(
            normalizedContent,
            category: category,
            tags: tags,
            source: MemorySource.tool,
            trust: .medium,
            scope: .project,
            id: MemoryIdentifier.makeNew()
        )
        return (entry, true)
    }

    /// Replaces the content of an existing entry in place, preserving its id.
    ///
    /// This is deliberately NOT `supersede`: the entry keeps its identity, its
    /// creation date, its archive state and its graph edges, so an id handed to
    /// the model stays valid after an update.
    func update(
        id rawIdentifier: String,
        content: String,
        tags: [String]?,
        updatedAt: Date,
        timeZone: TimeZone
    ) async throws -> MemoryEntry {
        let id = try MemoryIdentifier.validated(rawIdentifier)
        let normalizedContent = MemoryContent.normalized(content)
        guard !normalizedContent.isEmpty else {
            throw MemoryServiceError.missingField("content")
        }
        guard var entry = await engine.snapshot().memories[id] else {
            throw MemoryServiceError.entryNotFound(rawIdentifier)
        }

        entry.content = MemoryService.contentWithUpdateMetadata(
            normalizedContent,
            existingEntry: entry,
            updatedAt: updatedAt,
            timeZone: timeZone
        )
        if let tags {
            entry.tags = tags
        }
        entry.updatedAt = updatedAt
        entry.refreshSearchText()
        let embedder = MemoryEmbedding.provider()
        entry.setEmbedding(
            try await embedder?.embed(entry.content),
            model: embedder?.modelID
        )
        try await engine.insert(entry)
        return entry
    }

    func setArchived(_ isArchived: Bool, id rawIdentifier: String) async throws -> MemoryEntry {
        let id = try MemoryIdentifier.validated(rawIdentifier)
        guard var entry = await engine.snapshot().memories[id] else {
            throw MemoryServiceError.entryNotFound(rawIdentifier)
        }
        entry.active = !isArchived
        entry.updatedAt = Date()
        try await engine.insert(entry)
        return entry
    }

    func delete(id rawIdentifier: String) async throws {
        let id = try MemoryIdentifier.validated(rawIdentifier)
        guard try await engine.forget(id: id) != nil else {
            throw MemoryServiceError.entryNotFound(rawIdentifier)
        }
    }

    // MARK: - Helpers

    /// Journal order: newest first, with a stable tie-break.
    private static func ordered(
        _ entries: some Sequence<MemoryEntry>
    ) -> [MemoryEntry] {
        entries.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt > rhs.createdAt
            }
            return lhs.id < rhs.id
        }
    }

    /// Term-coverage score for archived entries, which the engine's retrieval
    /// paths skip. Zero means "no match".
    private static func lexicalScore(_ entry: MemoryEntry, query: String) -> Int {
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
}

// MARK: - Identifiers

enum MemoryIdentifier {
    /// Every ZenCODE-authored node uses a canonical uppercase UUID string, so
    /// the identifiers surfaced to the model stay in the shape callers and
    /// existing MEMORY.md `[id: …]` markers already use.
    static func canonical(_ id: UUID) -> String {
        id.uuidString
    }

    static func makeNew() -> String {
        UUID().uuidString
    }

    static func validated(_ rawIdentifier: String) throws -> String {
        let trimmed = rawIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MemoryServiceError.missingField("id")
        }
        guard let uuid = UUID(uuidString: trimmed) else {
            throw MemoryServiceError.invalidIdentifier(rawIdentifier)
        }
        return canonical(uuid)
    }
}

enum MemorySource {
    static let tool = "memory.write"
}

// MARK: - Store registry

/// Process-wide cache of open graph stores, keyed by resolved graph URL.
///
/// Callers commonly build a fresh `MemoryService` per tool execution; without
/// this cache each one would open an independent engine over the same file and
/// they could lose one another's updates.
actor MemoryGraphStoreRegistry {
    static let shared = MemoryGraphStoreRegistry()

    private var stores: [URL: Task<MemoryGraphStore, Error>] = [:]

    func store(
        forWorkspaceRoot workspaceRootURL: URL,
        graphURL: URL
    ) async throws -> MemoryGraphStore {
        if let pending = stores[graphURL] {
            return try await pending.value
        }

        let task = Task {
            try await MemoryGraphStore.open(
                graphURL: graphURL,
                workspaceRootURL: workspaceRootURL
            )
        }
        stores[graphURL] = task
        do {
            return try await task.value
        } catch {
            // A failed open must not be cached, otherwise the workspace stays
            // permanently broken for the lifetime of the process.
            stores[graphURL] = nil
            throw error
        }
    }

    /// Drops cached stores. Used when the support directory is re-pointed.
    func reset() {
        stores.removeAll()
    }
}

// MARK: - Embeddings

enum MemoryEmbedding {
    static let environmentEndpointKey = "ZENCODE_MEMORY_EMBEDDING_ENDPOINT"
    static let environmentModelKey = "ZENCODE_MEMORY_EMBEDDING_MODEL"
    static let environmentAPIKeyKey = "ZENCODE_MEMORY_EMBEDDING_API_KEY"

    /// Embeddings are opt-in. With no provider configured, `recall` uses pure
    /// BM25 lexical seeds and entries store no vector. The default
    /// `DeterministicHashEmbeddingProvider` is a feature-hashing bag-of-words
    /// encoder, not a semantic model, so fusing it with BM25 added noise rather
    /// than signal; it remains available but is no longer wired in by default.
    ///
    /// An OpenAI-compatible provider can be opted into through the environment
    /// without changing the graph format: entries record the `embeddingModel`
    /// they were embedded with, and the engine only compares vectors from a
    /// matching model, so a provider change degrades to lexical BM25 retrieval
    /// instead of returning wrong matches.
    static func provider() -> (any EmbeddingProvider)? {
        let environment = ProcessInfo.processInfo.environment
        guard let rawEndpoint = environment[environmentEndpointKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawEndpoint.isEmpty,
              let endpoint = URL(string: rawEndpoint),
              let model = environment[environmentModelKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !model.isEmpty else {
            return nil
        }
        let apiKey = environment[environmentAPIKeyKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return OpenAICompatibleEmbeddingProvider(
            endpoint: endpoint,
            model: model,
            apiKey: (apiKey?.isEmpty == false) ? apiKey : nil
        )
    }
}

// MARK: - Retrieval selection

/// Deterministic, offline score-threshold selector.
///
/// Replaces the engine's default `TopScoreMemorySelector(minimumScore: 0)`.
/// With that default, `select` returns every candidate up to `maxResults`, so
/// in `maintainAfterRetrieval` every retrieved entry is boosted and none is
/// ever decayed (confidence flattens toward 1.0), and `selected.count >= 2` is
/// nearly always true so every recall links all its results pairwise at weight
/// 0.7, saturating the graph until cascade retrieval degenerates into noise.
///
/// This selector keeps only candidates at or above a fraction of the top
/// candidate's score. That restores decay for weak candidates and limits
/// co-relevance linking to genuinely strong matches. It makes no LLM call and
/// no network request: BM25/cascade scores have no absolute scale (they depend
/// on corpus statistics), so the threshold is relative to the best hit in each
/// recall rather than a fixed cutoff.
struct ScoreThresholdMemorySelector: MemorySelector {
    /// A candidate is selected when its score is at least this fraction of the
    /// strongest candidate's score. `0.5` keeps entries within a factor of two
    /// of the best match — conservative enough to retain a cluster of genuinely
    /// relevant hits, aggressive enough to decay the long tail pulled in by
    /// graph expansion.
    let relativeThreshold: Float

    init(relativeThreshold: Float = 0.5) {
        self.relativeThreshold = relativeThreshold
    }

    func select(
        context: String,
        candidates: [MemoryCandidate],
        limit: Int
    ) async throws -> [MemoryCandidate] {
        guard limit > 0 else { return [] }
        // `recallDetailed` hands candidates in score-descending order, but a
        // selector's contract must not rely on the caller's ordering, so sort
        // defensively before deriving the threshold from the strongest hit.
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.score == rhs.score { return lhs.memory.id < rhs.memory.id }
            return lhs.score > rhs.score
        }
        guard let topScore = ordered.first?.score, topScore > 0 else {
            // No positive top score: the relative threshold cannot
            // discriminate, so fall back to rank order, still honouring `limit`.
            return Array(ordered.prefix(limit))
        }
        let floor = topScore * relativeThreshold
        return ordered.filter { $0.score >= floor }.prefix(limit).map { $0 }
    }
}
