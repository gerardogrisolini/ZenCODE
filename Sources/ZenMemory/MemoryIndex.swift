import Foundation

/// Pluggable lexical retrieval backend used by `ZenMemory`.
///
/// Implementations receive the current active memory set so they can be stateless,
/// keep a private cache, or maintain an external index such as SQLite FTS5.
public protocol MemoryIndex: Sendable {
    func search(
        query: String,
        memories: [MemoryEntry],
        scope: MemoryScope,
        limit: Int
    ) async throws -> [ScoredMemoryID]
}

/// Dependency-free BM25 index. This is the default retrieval backend.
public struct BM25MemoryIndex: MemoryIndex {
    public var k1: Float
    public var b: Float

    public init(k1: Float = 1.2, b: Float = 0.75) {
        self.k1 = k1
        self.b = b
    }

    public func search(
        query: String,
        memories: [MemoryEntry],
        scope: MemoryScope,
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
}
