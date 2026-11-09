//
//  MemoryLexicalCorpusTests.swift
//  ZenCODECoreTests
//
//  The pre-tokenized BM25 corpus shared by the queries of one retrieval must
//  score and order exactly like ranking each query on its own.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite
struct MemoryLexicalCorpusTests {
    private static let memories: [EngineMemoryEntry] = {
        var archived = EngineMemoryEntry(
            id: "archived",
            category: .fact,
            content: "Archived memory about the session runner tests",
            tags: ["memory"]
        )
        archived.active = false
        return [
            EngineMemoryEntry(id: "runner", category: .fact, content: "AgentCoreSessionRunner validates the session memory", tags: ["runner"]),
            EngineMemoryEntry(id: "memoria", category: .fact, content: "La memoria del progetto è stata validata dai test", tags: ["memoria", "test"], scope: .global),
            EngineMemoryEntry(id: "swift", category: .preference, content: "Swift tests run on Linux and macOS; tests tests tests", tags: ["swift-linux"], scope: .all),
            EngineMemoryEntry(id: "http", category: .entity, content: "HTTPServer exposes the memory.graph.json endpoint", tags: []),
            EngineMemoryEntry(id: "empty", category: .fact, content: "!!!", tags: []),
            EngineMemoryEntry(id: "release", category: .correction, content: "Release 5.0.0 released with arm64 sha256 checks", tags: ["release"], scope: .global),
            archived
        ]
    }()

    private static let queries = [
        "session memory",
        "memoria validata test",
        "tests tests swift",
        "HTTPServer endpoint",
        "!!!",
        "arm64 release",
        "nothing matches this",
        "memory memory runner"
    ]

    @Test
    func corpusScoresMatchTheReferenceBM25BitForBit() {
        for scope in [EngineMemoryScope.all, .project, .global] {
            for requireActive in [true, false] {
                for limit in [0, 1, 3, 10] {
                    for query in Self.queries {
                        let expected = Self.referenceBM25(
                            memories: Self.memories,
                            query: query,
                            scope: scope,
                            limit: limit,
                            requireActive: requireActive
                        )
                        let actual = MemorySearch.lexicalBM25(
                            memories: Self.memories,
                            query: query,
                            scope: scope,
                            limit: limit,
                            requireActive: requireActive
                        )
                        #expect(actual == expected, "query=\(query) scope=\(scope) limit=\(limit) requireActive=\(requireActive)")
                    }
                }
            }
        }
    }

    @Test
    func batchRankingEqualsQueryByQueryRanking() async throws {
        let index = BM25MemoryIndex()
        for scope in [EngineMemoryScope.all, .project, .global] {
            for limit in [0, 2, 10] {
                let batch = try await index.search(
                    queries: Self.queries,
                    memories: Self.memories,
                    scope: scope,
                    limit: limit
                )
                var single: [[ScoredMemoryID]] = []
                for query in Self.queries {
                    single.append(try await index.search(
                        query: query,
                        memories: Self.memories,
                        scope: scope,
                        limit: limit
                    ))
                }
                #expect(batch == single, "scope=\(scope) limit=\(limit)")
                #expect(batch.count == Self.queries.count)
            }
        }
        // The batch is not trivially empty: some queries do rank entries.
        let ranked = try await index.search(queries: Self.queries, memories: Self.memories, scope: .all, limit: 10)
        #expect(ranked.contains { !$0.isEmpty })
    }

    @Test
    func defaultBatchImplementationForwardsEveryQueryInOrder() async throws {
        let index = RecordingMemoryIndex()
        let rankings = try await index.search(
            queries: ["first", "second", "third"],
            memories: Self.memories,
            scope: .project,
            limit: 4
        )
        #expect(index.calls.withLock { $0 } == ["first|project|4", "second|project|4", "third|project|4"])
        #expect(rankings == [
            [ScoredMemoryID(id: "first", score: 1)],
            [ScoredMemoryID(id: "second", score: 1)],
            [ScoredMemoryID(id: "third", score: 1)]
        ])
    }

    @Test
    func metadataRankingMatchesTheReference() {
        let cases: [(tags: [String], entities: [String])] = [
            (["memory", "Test"], []),
            ([], ["AgentCoreSessionRunner", "HTTPServer"]),
            (["release"], ["memoria"]),
            (["runner"], ["!!!"]),
            ([], [])
        ]
        for (tags, entities) in cases {
            for scope in [EngineMemoryScope.all, .project, .global] {
                let expected = Self.referenceMetadataRanking(memories: Self.memories, tags: tags, entities: entities, scope: scope)
                let actual = MemorySearch.metadataRanking(memories: Self.memories, tags: tags, entities: entities, scope: scope)
                #expect(actual == expected, "tags=\(tags) entities=\(entities) scope=\(scope)")
            }
        }
    }

    // MARK: - Reference implementations (the per-call scoring before the shared corpus)

    private static func referenceBM25(
        memories: [EngineMemoryEntry],
        query: String,
        scope: EngineMemoryScope,
        limit: Int,
        k1: Float = 1.2,
        b: Float = 0.75,
        requireActive: Bool
    ) -> [ScoredMemoryID] {
        guard limit > 0 else { return [] }
        let queryTokens = MemorySearch.tokens(query)
        guard !queryTokens.isEmpty else { return [] }

        let documents: [(EngineMemoryEntry, [String])] = memories
            .filter { (!requireActive || $0.active) && MemorySearch.scopeAllows($0.scope, requested: scope) }
            .map { ($0, MemorySearch.tokens($0.searchableText)) }

        guard !documents.isEmpty else { return [] }
        let averageLength = Float(documents.reduce(0) { $0 + $1.1.count }) / Float(documents.count)
        guard averageLength > 0 else { return [] }

        let querySet = Set(queryTokens)
        var documentFrequency: [String: Int] = [:]
        for (_, documentTokens) in documents {
            for token in Set(documentTokens) where querySet.contains(token) {
                documentFrequency[token, default: 0] += 1
            }
        }

        return documents.compactMap { entry, documentTokens -> ScoredMemoryID? in
            guard !documentTokens.isEmpty else { return nil }
            var frequencies: [String: Int] = [:]
            for token in documentTokens { frequencies[token, default: 0] += 1 }

            var score: Float = 0
            for token in queryTokens {
                guard let tfValue = frequencies[token], tfValue > 0 else { continue }
                let n = Float(documents.count)
                let df = Float(documentFrequency[token] ?? 0)
                let idf = logf(1 + (n - df + 0.5) / (df + 0.5))
                let tf = Float(tfValue)
                let dl = Float(documentTokens.count)
                let denominator = tf + k1 * (1 - b + b * dl / averageLength)
                score += idf * (tf * (k1 + 1)) / denominator
            }

            return score > 0 ? ScoredMemoryID(id: entry.id, score: score) : nil
        }
        .sorted {
            if $0.score == $1.score { return $0.id < $1.id }
            return $0.score > $1.score
        }
        .prefix(limit)
        .map { $0 }
    }

    private static func referenceMetadataRanking(
        memories: [EngineMemoryEntry],
        tags: [String],
        entities: [String],
        scope: EngineMemoryScope,
        limit: Int = 10
    ) -> [ScoredMemoryID] {
        guard limit > 0, !tags.isEmpty || !entities.isEmpty else { return [] }
        let wantedTags = Set(tags.map { $0.lowercased() })
        let entityTokens = entities.flatMap(MemorySearch.tokens)

        return memories.compactMap { memory -> ScoredMemoryID? in
            guard memory.active, MemorySearch.scopeAllows(memory.scope, requested: scope) else { return nil }
            let memoryTags = Set(memory.tags.map { $0.lowercased() })
            let tagMatches = wantedTags.intersection(memoryTags).count
            let documentTokens = Set(MemorySearch.tokens(memory.content))
            let entityMatches = entityTokens.reduce(into: 0) { count, token in
                if documentTokens.contains(token) { count += 1 }
            }
            let score = Float(tagMatches) * 2 + Float(entityMatches)
            return score > 0 ? ScoredMemoryID(id: memory.id, score: score) : nil
        }
        .sorted {
            if $0.score == $1.score { return $0.id < $1.id }
            return $0.score > $1.score
        }
        .prefix(limit)
        .map { $0 }
    }
}

/// A custom index that only implements the single-query requirement, so the
/// batch call goes through the protocol's default implementation.
private final class RecordingMemoryIndex: MemoryIndex, Sendable {
    let calls = Mutex<[String]>([])

    func search(
        query: String,
        memories: [EngineMemoryEntry],
        scope: EngineMemoryScope,
        limit: Int
    ) async throws -> [ScoredMemoryID] {
        calls.withLock { $0.append("\(query)|\(scope)|\(limit)") }
        return [ScoredMemoryID(id: query, score: 1)]
    }
}
