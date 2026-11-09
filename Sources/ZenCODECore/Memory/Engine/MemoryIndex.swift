//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation

/// Pluggable lexical retrieval backend used by `MemoryEngine`.
///
/// Implementations receive the current active memory set so they can be stateless,
/// keep a private cache, or maintain an external index such as SQLite FTS5.
protocol MemoryIndex: Sendable {
    func search(
        query: String,
        memories: [EngineMemoryEntry],
        scope: EngineMemoryScope,
        limit: Int
    ) async throws -> [ScoredMemoryID]

    /// One ranking per query, in order, each equal to
    /// ``search(query:memories:scope:limit:)`` for that query over the same
    /// `memories`. The engine ranks all the queries of one retrieval through
    /// it so an implementation can prepare `memories` once; the default
    /// implementation simply searches query by query.
    func search(
        queries: [String],
        memories: [EngineMemoryEntry],
        scope: EngineMemoryScope,
        limit: Int
    ) async throws -> [[ScoredMemoryID]]
}

extension MemoryIndex {
    func search(
        queries: [String],
        memories: [EngineMemoryEntry],
        scope: EngineMemoryScope,
        limit: Int
    ) async throws -> [[ScoredMemoryID]] {
        var rankings: [[ScoredMemoryID]] = []
        rankings.reserveCapacity(queries.count)
        for query in queries {
            rankings.append(try await search(query: query, memories: memories, scope: scope, limit: limit))
        }
        return rankings
    }
}

/// Dependency-free BM25 index. This is the default retrieval backend.
struct BM25MemoryIndex: MemoryIndex {
    public var k1: Float
    public var b: Float

    public init(k1: Float = 1.2, b: Float = 0.75) {
        self.k1 = k1
        self.b = b
    }

    public func search(
        query: String,
        memories: [EngineMemoryEntry],
        scope: EngineMemoryScope,
        limit: Int
    ) async throws -> [ScoredMemoryID] {
        MemorySearch.lexicalBM25(
            memories: memories,
            query: query,
            scope: scope,
            limit: limit,
            k1: k1,
            b: b
        )
    }

    /// Tokenizes `memories` once and ranks every query over that corpus.
    public func search(
        queries: [String],
        memories: [EngineMemoryEntry],
        scope: EngineMemoryScope,
        limit: Int
    ) async throws -> [[ScoredMemoryID]] {
        MemorySearch.lexicalBM25(
            memories: memories,
            queries: queries,
            scope: scope,
            limit: limit,
            k1: k1,
            b: b
        )
    }
}
