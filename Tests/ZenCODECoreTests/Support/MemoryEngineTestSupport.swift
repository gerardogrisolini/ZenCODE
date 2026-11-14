//
//  MemoryEngineTestSupport.swift
//  ZenCODE
//
//  Fixtures the memory tests use to build engines and graphs: production goes
//  through `MemoryGraphStore`, which constructs its engine directly and writes
//  every entry through `MemoryEngine.transaction(_:)`.
//

import Foundation
@testable import ZenCODECore

extension MemoryEngine {
    /// An engine over the graph `persistence` loads.
    static func open(
        persistence: any MemoryPersistence,
        lexicalIndex: any MemoryIndex = BM25MemoryIndex(),
        embedder: (any EmbeddingProvider)? = nil,
        queryAnalyzer: any MemoryQueryAnalyzer = DirectMemoryQueryAnalyzer(),
        selector: any MemorySelector = TopScoreMemorySelector(),
        contextFormatter: any MemoryContextFormatter = BulletMemoryContextFormatter(),
        configuration: MemoryEngineConfiguration = .init(),
        semanticFailureReporter: @escaping @Sendable (String) -> Void = MemoryEmbeddingFallback.defaultReporter
    ) async throws -> MemoryEngine {
        let graph = try await persistence.load()
        return MemoryEngine(
            graph: graph,
            lexicalIndex: lexicalIndex,
            embedder: embedder,
            persistence: persistence,
            queryAnalyzer: queryAnalyzer,
            selector: selector,
            contextFormatter: contextFormatter,
            configuration: configuration,
            semanticFailureReporter: semanticFailureReporter
        )
    }

    /// Embeds `content` with the engine's embedder and stores it in one
    /// transaction.
    @discardableResult
    func remember(
        _ content: String,
        category: EngineMemoryCategory = .fact,
        tags: [String] = [],
        source: String? = nil,
        trust: TrustLevel = .medium,
        scope: EngineMemoryScope = .project,
        confidence: Float = 1,
        id: String? = nil
    ) async throws -> EngineMemoryEntry {
        let stored = try await embeddedEntry(
            content, operation: "write", id: id, category: category, tags: tags,
            source: source, trust: trust, scope: scope, confidence: confidence
        )
        // The embedding is computed above, outside the lock: only the graph
        // mutation itself has to be serialized.
        try await transaction { $0.addMemory(stored) }
        return stored
    }

    private func embeddedEntry(
        _ content: String,
        operation: String,
        id: String?,
        category: EngineMemoryCategory,
        tags: [String],
        source: String?,
        trust: TrustLevel,
        scope: EngineMemoryScope,
        confidence: Float
    ) async throws -> EngineMemoryEntry {
        let embedded = try await MemoryEmbeddingFallback.embed(
            content,
            with: embedder,
            operation: operation,
            reporter: semanticFailureReporter
        )
        var entry = EngineMemoryEntry(
            id: id,
            category: category,
            content: content,
            tags: tags,
            source: source,
            trust: trust,
            scope: scope,
            embedding: embedded.values,
            embeddingModel: embedded.model,
            confidence: confidence
        )
        entry.refreshSearchText()
        return entry
    }
}

extension MemoryGraph {
    /// Creates a `relatesTo` edge between two memories and records link
    /// discovery; a no-op when either endpoint is missing or inactive.
    mutating func linkMemories(from: String, to: String, weight: Float) {
        guard let source = memories[from], source.active,
              let target = memories[to], target.active else { return }
        addEdge(from: from, to: to, kind: .relatesTo(weight: min(max(weight, 0), 1)))
        metadata.linkDiscoveryCount &+= 1
    }

    /// Adds `memoryID` to the cluster `clusterID` (with or without its
    /// `cluster:` prefix); a no-op when either is missing.
    mutating func assign(memoryID: String, toCluster clusterID: String) {
        let normalized = clusterID.hasPrefix("cluster:") ? clusterID : "cluster:\(clusterID)"
        guard memories[memoryID] != nil, clusters[normalized] != nil else { return }
        addEdge(from: memoryID, to: normalized, kind: .inCluster)
        clusters[normalized]?.memberCount &+= 1
        clusters[normalized]?.updatedAt = Date()
    }

    /// Marks `olderID` as superseded by `newerID`, with a `supersedes` edge.
    mutating func supersede(newerID: String, olderID: String) {
        guard memories[newerID] != nil, var older = memories[olderID] else { return }
        addEdge(from: newerID, to: olderID, kind: .supersedes)
        older.active = false
        older.supersededBy = newerID
        memories[olderID] = older
    }
}

/// Dependency-free deterministic embedder for tests: a signed feature-hashing
/// bag-of-words encoder, NOT a semantic language model.
struct DeterministicHashEmbeddingProvider: EmbeddingProvider {
    let modelID: String
    let dimensions: Int

    init(dimensions: Int = 128, modelID: String = "zenmemory-hash-v1") {
        precondition(dimensions > 0)
        self.dimensions = dimensions
        self.modelID = modelID
    }

    func embed(_ text: String) async throws -> [Float] {
        var vector = Array(repeating: Float.zero, count: dimensions)
        for token in MemorySearch.tokens(text) {
            let hash = fnv1a64(token)
            let index = Int(hash % UInt64(dimensions))
            let sign: Float = (hash & (1 << 63)) == 0 ? 1 : -1
            vector[index] += sign
        }
        let norm = sqrtf(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private func fnv1a64(_ value: String) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash
    }
}
