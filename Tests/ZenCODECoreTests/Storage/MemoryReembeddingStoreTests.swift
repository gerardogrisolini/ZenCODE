//
//  MemoryReembeddingStoreTests.swift
//  ZenCODECoreTests
//
//  The store-level re-embedding run and the vector a restore regenerates:
//  scripted embedders only, never the network, never a real graph.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

// MARK: - Doubles

/// A deterministic embedder: the vector depends only on the text, failures are
/// scripted per text and attempt, a hook can run before each answer, and every
/// request is recorded.
private final class ScriptedEmbeddingProvider: EmbeddingProvider {
    let modelID: String
    let dimensions: Int
    private let failure: @Sendable (_ text: String, _ attempt: Int) -> (any Error)?
    private let beforeAnswer: @Sendable (_ text: String) async -> Void
    private let recorded = Mutex<[String]>([])

    init(
        modelID: String = "new-model",
        dimensions: Int = 4,
        failure: @escaping @Sendable (_ text: String, _ attempt: Int) -> (any Error)? = { _, _ in nil },
        beforeAnswer: @escaping @Sendable (_ text: String) async -> Void = { _ in }
    ) {
        self.modelID = modelID
        self.dimensions = dimensions
        self.failure = failure
        self.beforeAnswer = beforeAnswer
    }

    var requests: [String] {
        recorded.withLock { $0 }
    }

    func embed(_ text: String) async throws -> [Float] {
        let attempt = recorded.withLock { requests in
            requests.append(text)
            return requests.filter { $0 == text }.count
        }
        await beforeAnswer(text)
        if let error = failure(text, attempt) {
            throw error
        }
        return Self.vector(for: text, dimensions: dimensions)
    }

    static func vector(for text: String, dimensions: Int) -> [Float] {
        let seed = Float(text.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 1_000 } + 1)
        return (0..<dimensions).map { seed + Float($0) }
    }
}

/// Records every wait instead of sleeping.
private final class SleepRecorder: Sendable {
    private let waits = Mutex<[Duration]>([])

    var recorded: [Duration] {
        waits.withLock { $0 }
    }

    var sleep: @Sendable (Duration) async throws -> Void {
        { [self] delay in waits.withLock { $0.append(delay) } }
    }
}

private struct UnexpectedNetworkUse: Error {}

// MARK: - Tests

@Suite
struct MemoryReembeddingStoreTests {
    private static func open(
        _ graphURL: URL,
        with provider: (any EmbeddingProvider)?,
        reporter: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> MemoryGraphStore {
        try await MemoryEmbedding.withProvider(provider) {
            try await MemoryGraphStore.open(graphURL: graphURL, semanticFailureReporter: reporter)
        }
    }

    @discardableResult
    private static func write(
        _ content: String,
        to graphURL: URL,
        with provider: (any EmbeddingProvider)?
    ) async throws -> GraphEntry {
        let store = try await open(graphURL, with: provider)
        return try await store.write(content: content, category: .fact, tags: []).entry
    }

    private static func options(
        batchSize: Int = 16,
        concurrency: Int = 1,
        probe: Int = 8,
        sleep: SleepRecorder = SleepRecorder()
    ) -> MemoryReembedding.Options {
        var options = MemoryReembedding.Options()
        options.batchSize = batchSize
        options.maximumConcurrentRequests = concurrency
        options.probeEntryCount = probe
        options.sleep = sleep.sleep
        return options
    }

    /// Two active entries without a vector, one with an old-model vector, one
    /// already embedded by `current`, one archived with a vector and one
    /// archived without.
    private struct Seed {
        let missing: [GraphEntry]
        let oldModel: GraphEntry
        let compatible: GraphEntry
        let archivedWithVector: GraphEntry
        let archivedWithout: GraphEntry

        static func make(at graphURL: URL, current: ScriptedEmbeddingProvider) async throws -> Seed {
            let old = ScriptedEmbeddingProvider(modelID: "old-model", dimensions: 3)
            // A separate instance with the same identity, so the requests of
            // `current` only record the run under test.
            let sameModel = ScriptedEmbeddingProvider(modelID: current.modelID, dimensions: current.dimensions)
            let missing = [
                try await write("Summary: first entry without a vector", to: graphURL, with: nil),
                // Normalized on write: the stored text, not this literal, is embedded.
                try await write("  Summary: second entry without a vector  \n", to: graphURL, with: nil),
            ]
            let oldModel = try await write("Summary: embedded by the old model", to: graphURL, with: old)
            let compatible = try await write("Summary: already embedded", to: graphURL, with: sameModel)
            let archivedWithVector = try await write("Summary: archived with a vector", to: graphURL, with: old)
            let archivedWithout = try await write("Summary: archived without a vector", to: graphURL, with: nil)
            let archiver = try await MemoryReembeddingStoreTests.open(graphURL, with: nil)
            _ = try await archiver.setArchived(true, id: archivedWithVector.id)
            _ = try await archiver.setArchived(true, id: archivedWithout.id)
            return Seed(
                missing: missing,
                oldModel: oldModel,
                compatible: compatible,
                archivedWithVector: archivedWithVector,
                archivedWithout: archivedWithout
            )
        }
    }

    // MARK: - Plan

    @Test
    func planCountsEntriesToEmbedAndArchivedVectors() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let provider = ScriptedEmbeddingProvider()
            _ = try await Seed.make(at: graphURL, current: provider)
            let before = try Data(contentsOf: graphURL)

            let store = try await Self.open(graphURL, with: provider)
            let plan = try #require(try await store.reembeddingPlan())

            #expect(plan == MemoryReembeddingPlan(activeEntries: 4, entriesToEmbed: 3, archivedVectors: 1))
            #expect(!plan.isEmpty)
            #expect(store.embeddingModelID == "new-model")
            // Planning reads only: no request, no write.
            #expect(provider.requests.isEmpty)
            #expect(try Data(contentsOf: graphURL) == before)

            let bm25 = try await Self.open(graphURL, with: nil)
            #expect(try await bm25.reembeddingPlan() == nil)
            #expect(bm25.embeddingModelID == nil)
        }
    }

    // MARK: - Run

    @Test
    func runEmbedsActiveEntriesWithTheStoredTextAndClearsArchivedVectors() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let provider = ScriptedEmbeddingProvider()
            let seed = try await Seed.make(at: graphURL, current: provider)
            let before = try await JSONMemoryPersistence(url: graphURL).load()
            let store = try await Self.open(graphURL, with: provider)
            let run = MemoryReembeddingRun(options: Self.options())
            let progress = Mutex<[MemoryReembeddingProgress]>([])

            let summary = try await store.reembed(run: run) { update in
                progress.withLock { $0.append(update) }
            }

            #expect(summary == MemoryReembeddingGraphSummary(
                needed: 3,
                embedded: 3,
                resized: 0,
                failed: 0,
                skipped: 0,
                clearedArchivedVectors: 1
            ))
            #expect(run.abort == nil)
            #expect(run.dimensions == 4)
            let embeddedIDs = seed.missing.map(\.id) + [seed.oldModel.id]
            // Exactly the stored contents of the entries that needed a vector,
            // never the compatible or the archived ones.
            let storedContents = embeddedIDs.compactMap { before.memories[$0]?.content }
            #expect(Set(provider.requests) == Set(storedContents))
            #expect(provider.requests.count == 3)
            #expect(storedContents.contains("Summary: second entry without a vector"))
            #expect(progress.withLock { $0.last } == MemoryReembeddingProgress(processed: 3, failed: 0, total: 3))

            let after = try await JSONMemoryPersistence(url: graphURL).load()
            for id in embeddedIDs {
                let entry = try #require(after.memories[id])
                #expect(entry.embeddingModel == "new-model")
                #expect(entry.embedding == ScriptedEmbeddingProvider.vector(for: entry.content, dimensions: 4))
            }
            #expect(after.memories[seed.compatible.id] == before.memories[seed.compatible.id])
            let archived = try #require(after.memories[seed.archivedWithVector.id])
            #expect(!archived.active)
            #expect(archived.embedding == nil && archived.embeddingModel == nil)
            #expect(after.memories[seed.archivedWithout.id] == before.memories[seed.archivedWithout.id])
            // Only vectors changed: no timestamp, content or flag moved.
            for (id, entry) in after.memories {
                let previous = try #require(before.memories[id])
                #expect(entry.updatedAt == previous.updatedAt)
                #expect(entry.content == previous.content)
                #expect(entry.active == previous.active)
            }
        }
    }

    @Test
    func secondRunFindsEverythingCompatibleAndSendsNothing() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let provider = ScriptedEmbeddingProvider()
            _ = try await Seed.make(at: graphURL, current: provider)
            let store = try await Self.open(graphURL, with: provider)
            _ = try await store.reembed(run: MemoryReembeddingRun(options: Self.options()))
            let afterFirst = try Data(contentsOf: graphURL)

            let again = ScriptedEmbeddingProvider(failure: { _, _ in UnexpectedNetworkUse() })
            let second = try await Self.open(graphURL, with: again)
            #expect(try await second.reembeddingPlan()?.isEmpty == true)
            let summary = try await second.reembed(run: MemoryReembeddingRun(options: Self.options()))

            #expect(summary == MemoryReembeddingGraphSummary())
            #expect(again.requests.isEmpty)
            #expect(try Data(contentsOf: graphURL) == afterFirst)
        }
    }

    @Test
    func runReplacesVectorsOfAnotherLengthOnceTheDimensionIsKnown() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            // Same model identity, shorter vectors: recall would skip them.
            let shorter = ScriptedEmbeddingProvider(modelID: "new-model", dimensions: 4)
            let first = try await Self.write("Summary: short vector one", to: graphURL, with: shorter)
            let second = try await Self.write("Summary: short vector two", to: graphURL, with: shorter)
            let missing = try await Self.write("Summary: no vector yet", to: graphURL, with: nil)
            let provider = ScriptedEmbeddingProvider(modelID: "new-model", dimensions: 8)
            let store = try await Self.open(graphURL, with: provider)

            // The plan cannot see lengths: only the entry without a vector.
            #expect(try await store.reembeddingPlan()?.entriesToEmbed == 1)
            let run = MemoryReembeddingRun(options: Self.options())
            let summary = try await store.reembed(run: run)

            #expect(summary.needed == 3)
            #expect(summary.embedded == 3)
            #expect(summary.resized == 2)
            #expect(run.dimensions == 8)
            let after = try await JSONMemoryPersistence(url: graphURL).load()
            for id in [first.id, second.id, missing.id] {
                #expect(after.memories[id]?.embedding?.count == 8)
            }
        }
    }

    @Test
    func runUsesTheDimensionCarriedFromAnEarlierGraph() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let shorter = ScriptedEmbeddingProvider(modelID: "new-model", dimensions: 4)
            let entry = try await Self.write("Summary: short vector", to: graphURL, with: shorter)
            let provider = ScriptedEmbeddingProvider(modelID: "new-model", dimensions: 8)
            let store = try await Self.open(graphURL, with: provider)
            let run = MemoryReembeddingRun(options: Self.options())
            // An earlier graph of the same run already fixed the dimension.
            #expect(run.recordVector(length: 8))

            let summary = try await store.reembed(run: run)

            #expect(summary.needed == 1)
            #expect(summary.resized == 1)
            #expect(try await JSONMemoryPersistence(url: graphURL).load().memories[entry.id]?.embedding?.count == 8)
        }
    }

    // MARK: - Blocks and stop

    @Test
    func stopAfterTheFirstBlockLeavesOnlyThatBlockOnDisk() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            for index in 0..<5 {
                try await Self.write("Summary: entry \(index)", to: graphURL, with: nil)
            }
            let provider = ScriptedEmbeddingProvider()
            let store = try await Self.open(graphURL, with: provider)
            let run = MemoryReembeddingRun(options: Self.options(batchSize: 2))

            // Esc right after the last answer of the first block.
            let summary = try await store.reembed(run: run) { progress in
                if progress.processed == 2 { run.requestStop() }
            }

            #expect(provider.requests.count == 2)
            #expect(summary.embedded == 2)
            #expect(summary.remaining == 3)
            #expect(run.isStopRequested)
            #expect(!run.acceptsNewRequests)
            let onDisk = try await JSONMemoryPersistence(url: graphURL).load()
            let embedded = onDisk.memories.values.filter { $0.embedding != nil }
            #expect(embedded.count == 2)
            #expect(Set(embedded.map(\.content)) == Set(provider.requests))
        }
    }

    @Test
    func vectorsAreSavedBlockByBlock() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            for index in 0..<5 {
                try await Self.write("Summary: entry \(index)", to: graphURL, with: nil)
            }
            let calls = Mutex(0)
            let vectorsSeen = Mutex<[Int]>([])
            // Before each answer, count the vectors already on disk: a crash
            // at that moment would keep exactly those.
            let provider = ScriptedEmbeddingProvider(beforeAnswer: { _ in
                calls.withLock { $0 += 1 }
                let graph = try? await JSONMemoryPersistence(url: graphURL).load()
                let count = graph?.memories.values.filter { $0.embedding != nil }.count ?? -1
                vectorsSeen.withLock { $0.append(count) }
            })
            let store = try await Self.open(graphURL, with: provider)

            let summary = try await store.reembed(run: MemoryReembeddingRun(options: Self.options(batchSize: 2)))

            #expect(summary.embedded == 5)
            #expect(vectorsSeen.withLock { $0 } == [0, 0, 2, 2, 4])
        }
    }

    // MARK: - Concurrent changes

    @Test
    func contentChangedWhileEmbeddingDoesNotReceiveTheOldVector() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let entry = try await Self.write("Summary: original text", to: graphURL, with: nil)
            let otherSession = try await Self.open(graphURL, with: nil)
            let entryID = entry.id
            // Another session rewrites the entry while its vector is computed.
            let provider = ScriptedEmbeddingProvider(beforeAnswer: { _ in
                _ = try? await otherSession.update(
                    id: entryID,
                    content: "Summary: rewritten text",
                    tags: nil,
                    updatedAt: Date(),
                    timeZone: TimeZone(identifier: "UTC")!
                )
            })
            let store = try await Self.open(graphURL, with: provider)

            let summary = try await store.reembed(run: MemoryReembeddingRun(options: Self.options()))

            #expect(provider.requests == ["Summary: original text"])
            #expect(summary.embedded == 0)
            #expect(summary.skipped == 1)
            let stored = try #require(try await JSONMemoryPersistence(url: graphURL).load().memories[entryID])
            #expect(stored.content.contains("Summary: rewritten text"))
            #expect(stored.embedding == nil)
        }
    }

    // MARK: - Failures

    @Test
    func busyEndpointIsRetriedAfterAWait() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let entry = try await Self.write("Summary: busy once", to: graphURL, with: nil)
            let provider = ScriptedEmbeddingProvider(failure: { _, attempt in
                attempt == 1 ? OpenAICompatibleEmbeddingError.httpStatus(429, "Model busy") : nil
            })
            let sleeps = SleepRecorder()
            let store = try await Self.open(graphURL, with: provider)

            let summary = try await store.reembed(run: MemoryReembeddingRun(options: Self.options(sleep: sleeps)))

            #expect(summary.embedded == 1)
            #expect(summary.failed == 0)
            #expect(provider.requests.count == 2)
            #expect(sleeps.recorded == [.seconds(1)])
            #expect(try await JSONMemoryPersistence(url: graphURL).load().memories[entry.id]?.embedding != nil)
        }
    }

    @Test
    func persistentFailuresAreCountedAndTheRunGoesOn() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let alwaysBusy = try await Self.write("Summary: always busy", to: graphURL, with: nil)
            let rejected = try await Self.write("Summary: rejected request", to: graphURL, with: nil)
            try await Self.write("Summary: fine one", to: graphURL, with: nil)
            try await Self.write("Summary: fine two", to: graphURL, with: nil)
            let provider = ScriptedEmbeddingProvider(failure: { text, _ in
                switch text {
                case "Summary: always busy": OpenAICompatibleEmbeddingError.httpStatus(503, "overloaded")
                case "Summary: rejected request": OpenAICompatibleEmbeddingError.httpStatus(400, "bad input")
                default: nil
                }
            })
            let sleeps = SleepRecorder()
            let store = try await Self.open(graphURL, with: provider)
            let run = MemoryReembeddingRun(options: Self.options(sleep: sleeps))

            let summary = try await store.reembed(run: run)

            #expect(summary.embedded == 2)
            #expect(summary.failed == 2)
            #expect(summary.remaining == 0)
            #expect(run.abort == nil)
            // 5 attempts with growing waits for the retryable failure, a single
            // one for the request the endpoint refuses outright.
            #expect(provider.requests.filter { $0 == "Summary: always busy" }.count == 5)
            #expect(provider.requests.filter { $0 == "Summary: rejected request" }.count == 1)
            #expect(sleeps.recorded == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
            let after = try await JSONMemoryPersistence(url: graphURL).load()
            #expect(after.memories[alwaysBusy.id]?.embedding == nil)
            #expect(after.memories[rejected.id]?.embedding == nil)
        }
    }

    @Test
    func rejectedEndpointStopsTheRunAtOnce() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            for index in 0..<5 {
                try await Self.write("Summary: entry \(index)", to: graphURL, with: nil)
            }
            let provider = ScriptedEmbeddingProvider(failure: { _, _ in
                OpenAICompatibleEmbeddingError.httpStatus(401, "invalid key sk-or-v1-secret")
            })
            let sleeps = SleepRecorder()
            let store = try await Self.open(graphURL, with: provider)
            let run = MemoryReembeddingRun(options: Self.options(sleep: sleeps))

            let summary = try await store.reembed(run: run)

            #expect(run.abort == .endpointRejected(status: 401))
            #expect(provider.requests.count == 1)
            #expect(sleeps.recorded.isEmpty)
            #expect(summary.embedded == 0)
            #expect(summary.failed == 0)
            #expect(summary.remaining == 5)
            let description = ZenCODESetupRunner.memoryReembeddingAbortDescription(try #require(run.abort))
            #expect(description.contains("HTTP 401"))
            #expect(!description.contains("sk-or"))
        }
    }

    @Test
    func failingFirstEntriesStopTheRun() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            for index in 0..<6 {
                try await Self.write("Summary: entry \(index)", to: graphURL, with: nil)
            }
            let provider = ScriptedEmbeddingProvider(failure: { _, _ in
                OpenAICompatibleEmbeddingError.httpStatus(400, "unknown model")
            })
            let store = try await Self.open(graphURL, with: provider)
            let run = MemoryReembeddingRun(options: Self.options(probe: 3))

            let summary = try await store.reembed(run: run)

            #expect(run.abort == .initialRequestsFailed(count: 3, lastFailure: "httpStatus 400"))
            #expect(provider.requests.count == 3)
            #expect(summary.failed == 3)
            #expect(summary.remaining == 3)
        }
    }

    // MARK: - Format

    @Test
    func runKeepsTheFileFormat() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let provider = ScriptedEmbeddingProvider()
            _ = try await Seed.make(at: graphURL, current: provider)
            let store = try await Self.open(graphURL, with: provider)
            _ = try await store.reembed(run: MemoryReembeddingRun(options: Self.options()))

            let json = try #require(
                JSONSerialization.jsonObject(with: Data(contentsOf: graphURL)) as? [String: Any]
            )
            #expect(json["graph_version"] as? Int == Int(MemoryGraph.currentGraphVersion))
            let memories = try #require(json["memories"] as? [String: [String: Any]])
            // The vectors are in the vectors file: the JSON has none, and the
            // re-embedded entries carry exactly the keys of the entry written
            // with that provider in the first place: no new field.
            #expect(memories.values.allSatisfy { $0["embedding"] == nil })
            let embedded = memories.values.filter { $0["embedding_model"] as? String == provider.modelID }
            #expect(embedded.count == 4)
            #expect(Set(embedded.map { Set($0.keys) }).count == 1)
            let vectors = try Data(contentsOf: JSONMemoryPersistence.vectorsURL(forGraphAt: graphURL))
            let records = try #require(MemoryVectorFile.decode(vectors))
            #expect(Set(records.keys) == Set(memories.filter { $0.value["embedding_model"] as? String == provider.modelID }.keys))

            let decoded = try await JSONMemoryPersistence(url: graphURL).load()
            #expect(decoded.graphVersion == MemoryGraph.currentGraphVersion)
            let reopened = try await Self.open(graphURL, with: provider)
            #expect(try await reopened.entries(includeArchived: true, limit: 10).count == 6)
            #expect(try await reopened.reembeddingPlan()?.isEmpty == true)
        }
    }

    // MARK: - Restore

    @Test
    func restoredEntryWithoutAVectorReceivesOne() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let provider = ScriptedEmbeddingProvider()
            let entry = try await Self.write("Summary: archived then restored", to: graphURL, with: nil)
            let store = try await Self.open(graphURL, with: provider)
            let archived = try await store.setArchived(true, id: entry.id)
            #expect(!archived.active)
            #expect(provider.requests.isEmpty)

            let restored = try await store.setArchived(false, id: entry.id)

            #expect(restored.active)
            #expect(restored.embeddingModel == "new-model")
            #expect(restored.embedding == ScriptedEmbeddingProvider.vector(for: restored.content, dimensions: 4))
            #expect(provider.requests == [restored.content])
            let onDisk = try #require(try await JSONMemoryPersistence(url: graphURL).load().memories[entry.id])
            #expect(onDisk == restored)

            // Archiving keeps the vector; restoring with it does not embed again.
            _ = try await store.setArchived(true, id: entry.id)
            #expect(try await store.entry(id: entry.id)?.embedding != nil)
            _ = try await store.setArchived(false, id: entry.id)
            #expect(provider.requests.count == 1)
        }
    }

    @Test
    func restoreSucceedsWhenTheEndpointFails() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let entry = try await Self.write("Summary: restore without endpoint", to: graphURL, with: nil)
            let writer = try await Self.open(graphURL, with: nil)
            _ = try await writer.setArchived(true, id: entry.id)
            let messages = Mutex<[String]>([])
            let failing = ScriptedEmbeddingProvider(failure: { _, _ in
                OpenAICompatibleEmbeddingError.httpStatus(503, "echoed secret sk-test")
            })
            let store = try await Self.open(graphURL, with: failing) { message in
                messages.withLock { $0.append(message) }
            }

            let restored = try await store.setArchived(false, id: entry.id)

            #expect(restored.active)
            #expect(restored.embedding == nil)
            let onDisk = try #require(try await JSONMemoryPersistence(url: graphURL).load().memories[entry.id])
            #expect(onDisk.active)
            #expect(onDisk.embedding == nil)
            let recorded = messages.withLock { $0 }
            #expect(recorded.count == 1)
            #expect(recorded.first?.contains("restore") == true)
            #expect(recorded.first?.contains("httpStatus 503") == true)
            #expect(recorded.first?.contains("sk-test") == false)
        }
    }
}

// MARK: - Pure rules

@Suite
struct MemoryReembeddingRulesTests {
    @Test
    func failuresAreClassifiedByStatusAndTransport() {
        typealias Rules = MemoryReembedding
        #expect(Rules.classify(OpenAICompatibleEmbeddingError.httpStatus(429, "")) == .retryable)
        #expect(Rules.classify(OpenAICompatibleEmbeddingError.httpStatus(500, "")) == .retryable)
        #expect(Rules.classify(OpenAICompatibleEmbeddingError.httpStatus(503, "")) == .retryable)
        #expect(Rules.classify(OpenAICompatibleEmbeddingError.httpStatus(401, "")) == .endpointRejected(status: 401))
        #expect(Rules.classify(OpenAICompatibleEmbeddingError.httpStatus(403, "")) == .endpointRejected(status: 403))
        #expect(Rules.classify(OpenAICompatibleEmbeddingError.httpStatus(404, "")) == .endpointRejected(status: 404))
        #expect(Rules.classify(OpenAICompatibleEmbeddingError.httpStatus(400, "")) == .permanent)
        #expect(Rules.classify(OpenAICompatibleEmbeddingError.emptyEmbedding) == .permanent)
        #expect(Rules.classify(RemoteTransportError.timeout) == .retryable)
        #expect(Rules.classify(RemoteTransportError.connectionFailure("reset by api.example.test")) == .retryable)
        #expect(Rules.classify(RemoteTransportError.invalidURL("x")) == .permanent)
        #expect(Rules.classify(URLError(.networkConnectionLost)) == .retryable)
        #expect(Rules.classify(UnexpectedNetworkUse()) == .permanent)
    }

    @Test
    func failureSummariesNeverQuoteBodiesOrHosts() {
        #expect(MemoryReembedding.failureSummary(
            OpenAICompatibleEmbeddingError.httpStatus(429, "Model busy, key sk-or-v1-abc")
        ) == "httpStatus 429")
        #expect(MemoryReembedding.failureSummary(
            RemoteTransportError.connectionFailure("api.secret-host.test refused")
        ) == "transportError connectionFailure")
        #expect(MemoryReembedding.failureSummary(RemoteTransportError.timeout) == "transportError timeout")
    }

    @Test
    func retryWaitsDoubleFromTheInitialDelay() {
        let options = MemoryReembedding.Options.default
        #expect(options.maximumAttempts == 5)
        #expect(options.maximumConcurrentRequests == 4)
        #expect(options.batchSize == 16)
        #expect((1...4).map { MemoryReembedding.retryDelay(afterAttempt: $0, options: options) }
            == [.seconds(1), .seconds(2), .seconds(4), .seconds(8)])
    }

    @Test
    func compatibilityNeedsTheModelAndTheObservedLength() {
        var entry = EngineMemoryEntry(category: .fact, content: "Summary: x")
        #expect(MemoryReembedding.reason(for: entry, modelID: "m", dimensions: nil) == .missing)
        entry.setEmbedding([1, 2], model: "other")
        #expect(MemoryReembedding.reason(for: entry, modelID: "m", dimensions: nil) == .otherModel)
        entry.setEmbedding([1, 2], model: "m")
        #expect(MemoryReembedding.reason(for: entry, modelID: "m", dimensions: nil) == nil)
        #expect(MemoryReembedding.reason(for: entry, modelID: "m", dimensions: 2) == nil)
        #expect(MemoryReembedding.reason(for: entry, modelID: "m", dimensions: 3) == .otherDimensions)
    }

    @Test
    func runRecordsTheFirstDimensionAndRejectsOthers() {
        let run = MemoryReembeddingRun()
        #expect(run.dimensions == nil)
        #expect(run.recordVector(length: 2_560))
        #expect(run.dimensions == 2_560)
        #expect(!run.recordVector(length: 4_096))
        #expect(run.acceptsNewRequests)
        run.requestStop()
        #expect(!run.acceptsNewRequests)
        #expect(run.abort == nil)
    }

    @Test
    func failuresAfterTheFirstSuccessNeverAbort() {
        var options = MemoryReembedding.Options()
        options.probeEntryCount = 2
        let run = MemoryReembeddingRun(options: options)
        #expect(run.recordVector(length: 4))
        run.recordFailure(.permanent, summary: "httpStatus 400")
        run.recordFailure(.permanent, summary: "httpStatus 400")
        run.recordFailure(.retryable, summary: "httpStatus 503")
        #expect(run.abort == nil)
        run.recordFailure(.endpointRejected(status: 403), summary: "httpStatus 403")
        #expect(run.abort == .endpointRejected(status: 403))
    }
}
