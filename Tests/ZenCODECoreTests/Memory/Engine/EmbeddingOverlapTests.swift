//
//  EmbeddingOverlapTests.swift
//  ZenCODECoreTests (memory engine)
//
//  The embedding request of a retrieval does not depend on the local lexical
//  ranking, so it starts before it: the endpoint's latency overlaps the BM25
//  pass over the graph instead of following it.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

/// A flag set once, readable from any task.
private final class Flag: Sendable {
    private let value = Atomic<Bool>(false)

    func set() { value.store(true, ordering: .releasing) }
    var isSet: Bool { value.load(ordering: .acquiring) }
}

private struct SignallingEmbeddingProvider: EmbeddingProvider {
    let modelID = "overlap-test-model"
    let requested: Flag

    func embed(_ text: String) async throws -> [Float] {
        requested.set()
        return [1, 0]
    }
}

/// A BM25 index that, before ranking, waits a bounded time for the embedding
/// request and records whether it had started by then.
private struct EmbeddingAwareIndex: MemoryIndex {
    let embeddingRequested: Flag
    let sawEmbeddingRequest: Flag

    func search(
        query: String,
        memories: [EngineMemoryEntry],
        scope: EngineMemoryScope,
        limit: Int
    ) async throws -> [ScoredMemoryID] {
        let deadline = ContinuousClock.now + .seconds(2)
        while !embeddingRequested.isSet, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        if embeddingRequested.isSet { sawEmbeddingRequest.set() }
        return try await BM25MemoryIndex().search(
            query: query, memories: memories, scope: scope, limit: limit
        )
    }
}

@Suite
struct EmbeddingOverlapTests {
    @Test
    func embeddingRequestStartsBeforeTheLexicalRankingEnds() async throws {
        var graph = MemoryGraph()
        graph.addMemory(
            EngineMemoryEntry(id: "a", category: .fact, content: "Swift actors protect mutable state")
        )
        let embeddingRequested = Flag()
        let sawEmbeddingRequest = Flag()
        let engine = MemoryEngine(
            graph: graph,
            lexicalIndex: EmbeddingAwareIndex(
                embeddingRequested: embeddingRequested,
                sawEmbeddingRequest: sawEmbeddingRequest
            ),
            embedder: SignallingEmbeddingProvider(requested: embeddingRequested)
        )

        let results = try await engine.recall("Swift actors")

        #expect(sawEmbeddingRequest.isSet)
        #expect(results.contains { $0.memory.id == "a" })
    }
}
