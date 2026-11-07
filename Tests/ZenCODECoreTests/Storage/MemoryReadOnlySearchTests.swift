//
//  MemoryReadOnlySearchTests.swift
//  ZenCODECoreTests
//
//  Two concerns from the review:
//
//  1. `memory.search` must be truly read-only — the graph file on disk is
//     byte-identical before and after a search, metadata (retrievalCount,
//     confidence, links) is unchanged, and a search never fails because a
//     save errored.
//  2. Memory tests must not depend on the real `ZENCODE_MEMORY_EMBEDDING_ENDPOINT`
//     environment variables. A task-local seam (`MemoryEmbedding.withProvider`)
//     lets tests force "no provider" (no network) or inject a specific provider
//     without mutating the process-global environment.
//

import Foundation
@testable import ZenCODECore
import Testing

// MARK: - Doubles

private actor RecordingPersistence: MemoryPersistence {
    private(set) var saved: [MemoryGraph] = []
    func load() async throws -> MemoryGraph { MemoryGraph() }
    func save(_ graph: MemoryGraph) async throws { saved.append(graph) }
}

private struct AlwaysFailingPersistence: MemoryPersistence {
    struct SaveFailed: Error {}
    func load() async throws -> MemoryGraph { MemoryGraph() }
    func save(_ graph: MemoryGraph) async throws { throw SaveFailed() }
}

// MARK: - Read-only search (store level)

@Suite
struct MemoryReadOnlySearchStoreTests {

    @Test
    func memorySearchLeavesGraphFileByteIdentical() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            // Force "no provider" so the store opens with pure BM25, no network,
            // and the result is deterministic regardless of the developer's shell.
            try await MemoryEmbedding.withProvider(nil) {
                let service = MemoryService()
                _ = try await service.writeEntry(
                    content: "Summary: actors isolate mutable state.",
                    workspaceRootURL: workspace.workspaceURL
                )
                _ = try await service.writeEntry(
                    content: "Summary: structured concurrency guide.",
                    workspaceRootURL: workspace.workspaceURL
                )

                let graphURL = workspace.graphURL()
                let bytesBefore = try Data(contentsOf: graphURL)

                // Multiple searches to prove idempotence and read-only-ness.
                _ = try await service.searchEntries(
                    query: "actors",
                    workspaceRootURL: workspace.workspaceURL,
                    limit: 10
                )
                _ = try await service.searchEntries(
                    query: "structured concurrency",
                    workspaceRootURL: workspace.workspaceURL,
                    limit: 10
                )

                let bytesAfter = try Data(contentsOf: graphURL)
                #expect(bytesBefore == bytesAfter)
            }
        }
    }

    @Test
    func storeSearchSucceedsWhenPersistenceAlwaysFails() async throws {
        let engine = MemoryEngine(persistence: AlwaysFailingPersistence())
        let store = MemoryGraphStore(
            graphURL: URL(fileURLWithPath: "/dev/null/graph.json"),
            engine: engine,
            embedder: nil
        )
        try await engine.insert(
            EngineMemoryEntry(id: "entry", category: .fact, content: "database migrations"),
            persist: false
        )
        // Must not throw — read-only path never calls save.
        let results = try await store.search(query: "database", includeArchived: false, limit: 10)
        #expect(!results.isEmpty)
    }

    @Test
    func automaticRecallAppliesMaintenanceThroughStoreWithoutImmediateSave() async throws {
        let persistence = RecordingPersistence()
        let engine = MemoryEngine(persistence: persistence)
        let store = MemoryGraphStore(
            graphURL: URL(fileURLWithPath: "/dev/null/graph.json"),
            engine: engine,
            embedder: nil
        )
        try await engine.remember("actors isolate mutable state", tags: ["swift"])
        try await engine.remember("structured concurrency actors", tags: ["swift"])

        let retrievalBefore = await engine.snapshot().metadata.retrievalCount
        let savesBefore = await persistence.saved.count

        // The automatic recall path goes through context(for:), which keeps
        // its transactional maintenance.
        _ = try await store.context(for: "actors concurrency")

        let retrievalAfter = await engine.snapshot().metadata.retrievalCount
        let savesAfter = await persistence.saved.count

        #expect(retrievalAfter > retrievalBefore)
        #expect(savesAfter == savesBefore)
    }

    // MARK: - Cold-open (graph file absent)

    @Test
    func coldSearchDoesNotCreateGraphFile() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            #expect(!FileManager.default.fileExists(atPath: graphURL.path))

            let service = MemoryService()

            // A cold search on a workspace with no graph file must not throw,
            // must return no results, and must NOT create the graph file.
            let results = try await service.searchEntries(
                query: "cold",
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(results.isEmpty)

            // The graph file must still not exist after opening an empty graph.
            #expect(!FileManager.default.fileExists(atPath: graphURL.path))

            // A cold read is equally harmless.
            let entries = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(entries.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: graphURL.path))
        }
    }
}

// MARK: - Embedding environment isolation

@Suite(.serialized)
struct MemoryEmbeddingIsolationTests {

    @Test
    func overrideDoesNotLeakOutsideScope() async throws {
        // Baseline: what the unbound resolver returns with no override active.
        // Under the test harness this is nil regardless of env vars; outside
        // the harness it reflects the real environment.
        let baseline = MemoryEmbedding.provider()

        // Inside the scope the override is active.
        let inside = await MemoryEmbedding.withProvider(nil) {
            MemoryEmbedding.provider()
        }
        #expect(inside == nil)

        // Outside the scope the override is gone: the value must match the
        // baseline, whatever it was. The key assertion is that the nil
        // override did not leak here — we do NOT assume the environment is
        // nil, so this test is robust on a developer machine that exports
        // real embedding env vars.
        let outside = MemoryEmbedding.provider()
        #expect(outside?.modelID == baseline?.modelID)
    }

    @Test
    func injectedProviderReachesStoreWrites() async throws {
        // Prove the override propagates through the unstructured Task that the
        // registry uses to open the engine: a written entry carries an embedding
        // vector when a provider is injected, and no vector when forced to nil.
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let provider = DeterministicHashEmbeddingProvider(modelID: "injected-v1")
            try await MemoryEmbedding.withProvider(provider) {
                let service = MemoryService()
                let entry = try await service.writeEntry(
                    content: "Summary: deterministic embedding injection.",
                    workspaceRootURL: workspace.workspaceURL
                )
                #expect(entry.embedding?.isEmpty == false)
                #expect(entry.embeddingModel == "injected-v1")
            }
        }
    }

    // MARK: - Environment resolution (controlled isolation)

    @Test
    func defaultProviderIsNilUnderTestHarnessEvenWithRealEnv() async throws {
        // Simulate the developer's shell exporting real embedding env vars.
        // Under the test harness, provider() must still return nil: no
        // environment lookup, no network call.
        await withScopedEmbeddingEndpoint(
            "https://embeddings.example.com/v1/embeddings"
        ) {
            let resolved = MemoryEmbedding.provider()
            #expect(resolved == nil)
        }
    }
}

/// Sets the legacy `ZENCODE_MEMORY_EMBEDDING_ENDPOINT` env var for the duration of
/// `operation`, restoring the original values on exit.
///
/// This is safe because under the test harness `provider()` never reads the
/// environment (it returns nil before reaching `providerFromEnvironment`), so
/// the setenv cannot leak into a concurrently running test's resolution.
private func withScopedEmbeddingEndpoint(
    _ endpoint: String,
    _ operation: () async throws -> Void
) async rethrows {
    let key = MemoryEmbedding.environmentEndpointKey
    let original = ProcessInfo.processInfo.environment[key]
    setenv(key, endpoint, 1)
    defer {
        if let original {
            setenv(key, original, 1)
        } else {
            unsetenv(key)
        }
    }
    try await operation()
}
