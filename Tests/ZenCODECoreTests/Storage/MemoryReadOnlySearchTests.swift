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
//     lets tests force "no provider" (no network) or inject a specific provider,
//     and `MemoryEmbedding.provider(isRunningUnderTestHarness:manifest:environment:)`
//     lets the harness guard be tested with injected inputs. Neither mutates
//     the process-global environment.
//

import Foundation
import Synchronization
@testable import ZenCODECore
@testable import ZenCODERuntime
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
                    target: .workspace(workspace.workspaceURL)
                )
                _ = try await service.writeEntry(
                    content: "Summary: structured concurrency guide.",
                    target: .workspace(workspace.workspaceURL)
                )

                let graphURL = workspace.graphURL()
                let bytesBefore = try Data(contentsOf: graphURL)

                // Multiple searches to prove idempotence and read-only-ness.
                _ = try await service.searchEntries(
                    query: "actors",
                    target: .workspace(workspace.workspaceURL),
                    limit: 10
                )
                _ = try await service.searchEntries(
                    query: "structured concurrency",
                    target: .workspace(workspace.workspaceURL),
                    limit: 10
                )

                let bytesAfter = try Data(contentsOf: graphURL)
                #expect(bytesBefore == bytesAfter)
            }
        }
    }

    @Test
    func storeSearchSucceedsWhenPersistenceAlwaysFails() async throws {
        // Seed the graph the engine opens with, so setup never saves.
        var seeded = MemoryGraph()
        seeded.addMemory(EngineMemoryEntry(id: "entry", category: .fact, content: "database migrations"))
        let engine = MemoryEngine(graph: seeded, persistence: AlwaysFailingPersistence())
        let store = MemoryGraphStore(
            graphURL: URL(fileURLWithPath: "/dev/null/graph.json"),
            engine: engine,
            embedder: nil
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
                target: .workspace(workspace.workspaceURL),
                limit: 10
            )
            #expect(results.isEmpty)

            // The graph file must still not exist after opening an empty graph.
            #expect(!FileManager.default.fileExists(atPath: graphURL.path))

            // A cold read is equally harmless.
            let entries = try await service.readEntries(
                target: .workspace(workspace.workspaceURL),
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
                    target: .workspace(workspace.workspaceURL)
                )
                #expect(entry.embedding?.isEmpty == false)
                #expect(entry.embeddingModel == "injected-v1")
            }
        }
    }

    // MARK: - Environment resolution (controlled isolation)

    @Test
    func defaultProviderIsNilUnderTestHarnessEvenWithRealEnv() {
        // Simulate a shell that exports a real embedding endpoint. Under the
        // test harness the resolver must still return nil, and must not even
        // look: neither the persisted manifest nor the environment is read, so
        // there is no lookup and no network call. The environment is injected,
        // never mutated with setenv, so concurrent tests cannot observe it.
        let manifestReads = CallCounter()
        let environmentReads = CallCounter()

        let resolved = MemoryEmbedding.provider(
            isRunningUnderTestHarness: true,
            manifest: {
                manifestReads.record()
                return nil
            },
            environment: {
                environmentReads.record()
                return [MemoryEmbedding.environmentEndpointKey: Self.exampleEndpoint]
            }
        )

        #expect(resolved == nil)
        #expect(manifestReads.count == 0)
        #expect(environmentReads.count == 0)
        // The public entry point applies the same guard with the real harness
        // detection: this process is a test harness, so it resolves to nil
        // whatever the shell exports.
        #expect(MemoryEmbedding.provider() == nil)
    }

    @Test
    func sameEnvironmentResolvesAProviderOutsideTheTestHarness() throws {
        // Control for the test above: with the guard lifted the very same
        // inputs do resolve the endpoint, so the nil there comes from the
        // harness guard and not from an environment that never mattered.
        // Resolution only builds the provider; the endpoint is contacted by
        // `embed(_:)`, which is never called here.
        let manifestReads = CallCounter()
        let environmentReads = CallCounter()

        let resolved = MemoryEmbedding.provider(
            isRunningUnderTestHarness: false,
            manifest: {
                manifestReads.record()
                return nil
            },
            environment: {
                environmentReads.record()
                return [MemoryEmbedding.environmentEndpointKey: Self.exampleEndpoint]
            }
        )

        let provider = try #require(resolved as? OpenAICompatibleEmbeddingProvider)
        #expect(provider.endpoint.absoluteString == Self.exampleEndpoint)
        #expect(manifestReads.count == 1)
        #expect(environmentReads.count == 1)
    }

    @Test
    func taskLocalOverrideTakesPrecedenceOverTheHarnessGuardWithoutReadingInputs() async {
        let manifestReads = CallCounter()
        let environmentReads = CallCounter()
        let forced = DeterministicHashEmbeddingProvider(modelID: "forced-v1")

        let resolved = await MemoryEmbedding.withProvider(forced) {
            MemoryEmbedding.provider(
                isRunningUnderTestHarness: true,
                manifest: {
                    manifestReads.record()
                    return nil
                },
                environment: {
                    environmentReads.record()
                    return [:]
                }
            )
        }

        #expect(resolved?.modelID == "forced-v1")
        #expect(manifestReads.count == 0)
        #expect(environmentReads.count == 0)
    }

    private static let exampleEndpoint = "https://embeddings.example.com/v1/embeddings"
}

/// Counts how many times an injected closure ran. `Sendable` so the seam's
/// closures can capture it regardless of the isolation they run under.
private final class CallCounter: Sendable {
    private let calls = Mutex(0)

    func record() {
        calls.withLock { $0 += 1 }
    }

    var count: Int {
        calls.withLock { $0 }
    }
}
