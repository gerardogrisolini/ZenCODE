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
}
