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
    func storeSearchDoesNotMutateEngineGraphMetadata() async throws {
        let persistence = RecordingPersistence()
        let engine = MemoryEngine(persistence: persistence)
        let store = MemoryGraphStore(
            graphURL: URL(fileURLWithPath: "/dev/null/graph.json"),
            engine: engine,
            embedder: nil
        )
        try await engine.remember("actors isolate mutable state", tags: ["swift"])

        let retrievalBefore = await engine.snapshot().metadata.retrievalCount
        let confidenceBefore = await engine.snapshot().memories.mapValues(\.confidence)
        let edgesBefore = await engine.snapshot().edges

        _ = try await store.search(query: "actors", includeArchived: false, limit: 10)
        _ = try await store.search(query: "mutable", includeArchived: false, limit: 10)

        let retrievalAfter = await engine.snapshot().metadata.retrievalCount
        let confidenceAfter = await engine.snapshot().memories.mapValues(\.confidence)
        let edgesAfter = await engine.snapshot().edges

        #expect(retrievalAfter == retrievalBefore)
        #expect(confidenceAfter == confidenceBefore)
        #expect(edgesAfter == edgesBefore)

        let saves = await persistence.saved.count
        #expect(saves == 1) // Only the initial remember persisted.
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
    func automaticRecallStillAppliesMaintenanceThroughStore() async throws {
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
        #expect(savesAfter > savesBefore)
    }

    // MARK: - Cold-open (graph file absent)

    @Test
    func coldSearchDoesNotCreateGraphFile() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        // Seed a legacy journal so the cold open has real migration work to do.
        try workspace.writeLegacyJournal("""
        # MEMORY.md

        ## Active

        - Timestamp: 2026-08-01 09:00 Europe/Rome
          Summary: cold open must not persist.
          State: the graph file must not be created on a read-only path.
          Next: verify no graph file exists after a cold search.
        """)

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            #expect(!FileManager.default.fileExists(atPath: graphURL.path))

            let service = MemoryService()

            // A cold search on a workspace with no graph file must not throw,
            // must return migrated results, and must NOT create the graph file.
            let results = try await service.searchEntries(
                query: "cold",
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(!results.isEmpty)

            // The graph file must still not exist — open migrated in memory.
            #expect(!FileManager.default.fileExists(atPath: graphURL.path))

            // A cold read is equally harmless.
            let entries = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(!entries.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: graphURL.path))
        }
    }

    @Test
    func coldSearchDoesNotFailWhenGraphDirectoryIsReadOnly() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try workspace.writeLegacyJournal("""
        # MEMORY.md

        ## Active

        - Timestamp: 2026-08-01 09:00 Europe/Rome
          Summary: read-only directory cold open.
          State: must not throw and must not create files.
          Next: keep MEMORY.md untouched.
        """)

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let graphDir = graphURL.deletingLastPathComponent()

            // Pre-create the directory where the graph file would be written,
            // then make it read-only. Any premature save during open would
            // fail with a permission error.
            try FileManager.default.createDirectory(
                at: graphDir,
                withIntermediateDirectories: true
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o555],
                ofItemAtPath: graphDir.path
            )
            defer {
                // Restore write permission so the workspace cleanup succeeds.
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o755],
                    ofItemAtPath: graphDir.path
                )
            }

            // The cold open + search must succeed despite the read-only
            // directory: open migrates in memory and never calls save.
            let store = try await MemoryGraphStore.open(
                graphURL: graphURL,
                workspaceRootURL: workspace.workspaceURL
            )
            let results = try await store.search(
                query: "directory",
                includeArchived: false,
                limit: 10
            )
            #expect(!results.isEmpty)

            // No graph file was created.
            #expect(!FileManager.default.fileExists(atPath: graphURL.path))
        }
    }

    @Test
    func firstMutationPersistsMigratedGraph() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try workspace.writeLegacyJournal("""
        # MEMORY.md

        ## Active

        - Timestamp: 2026-08-01 09:00 Europe/Rome
          Summary: migrated entry persisted on first write.
          State: the graph must appear on disk only after a mutation.
          Next: confirm both legacy and new entries are on disk.
        """)

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let service = MemoryService()

            // Cold read: migration in memory, no file.
            let before = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(!before.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: graphURL.path))

            // First mutation: the full graph (migration + new entry) is
            // persisted atomically.
            _ = try await service.writeEntry(
                content: "Summary: the write that triggers persistence.",
                workspaceRootURL: workspace.workspaceURL
            )
            #expect(FileManager.default.fileExists(atPath: graphURL.path))

            // A fresh open must load from disk and see both entries.
            let reopened = try await MemoryGraphStore.open(
                graphURL: graphURL,
                workspaceRootURL: workspace.workspaceURL
            )
            let all = await reopened.entries(includeArchived: true, limit: 100)
            #expect(all.count == before.count + 1)
        }
    }
}

// MARK: - Embedding environment isolation

@Suite(.serialized)
struct MemoryEmbeddingIsolationTests {

    @Test
    func forcedNilOverrideIgnoresEnvironment() async throws {
        // The override takes precedence over the real environment: forcing nil
        // guarantees no provider and therefore no network call, regardless of
        // what the developer's shell exports.
        let resolved = await MemoryEmbedding.withProvider(nil) {
            MemoryEmbedding.provider()
        }
        #expect(resolved == nil)
    }

    @Test
    func forcedProviderOverrideWins() async throws {
        let injected = DeterministicHashEmbeddingProvider(modelID: "test-embed-v1")
        let resolved = await MemoryEmbedding.withProvider(injected) {
            MemoryEmbedding.provider()
        }
        #expect(resolved?.modelID == "test-embed-v1")
    }

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
    func concurrentOverridesDoNotInterfere() async throws {
        let providerA = DeterministicHashEmbeddingProvider(modelID: "model-a")
        let providerB = DeterministicHashEmbeddingProvider(modelID: "model-b")

        async let a = resolveModelID(with: providerA)
        async let b = resolveModelID(with: providerB)

        #expect(try await a == "model-a")
        #expect(try await b == "model-b")
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

    @Test
    func forcedNilProviderReachesStoreWrites() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            try await MemoryEmbedding.withProvider(nil) {
                let service = MemoryService()
                let entry = try await service.writeEntry(
                    content: "Summary: no embedding provider.",
                    workspaceRootURL: workspace.workspaceURL
                )
                #expect(entry.embedding == nil)
                #expect(entry.embeddingModel == nil)
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

    @Test
    func forcedProviderWinsEvenWithRealEnvUnderTestHarness() async throws {
        // Even with real env vars set AND the test-harness guard, an explicit
        // task-local override must win — tests can still inject providers.
        let injected = DeterministicHashEmbeddingProvider(modelID: "override-wins")
        await withScopedEmbeddingEndpoint(
            "https://embeddings.example.com/v1/embeddings"
        ) {
            let resolved = await MemoryEmbedding.withProvider(injected) {
                MemoryEmbedding.provider()
            }
            #expect(resolved?.modelID == "override-wins")
        }
    }

    // MARK: - Helpers

    private func resolveModelID(with provider: any EmbeddingProvider) async throws -> String? {
        try await MemoryEmbedding.withProvider(provider) {
            // Yield to encourage potential interleaving between concurrent tasks.
            try await Task.sleep(for: .milliseconds(1))
            return MemoryEmbedding.provider()?.modelID
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
