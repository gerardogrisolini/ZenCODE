//
//  MemoryVectorPersistenceTests.swift
//  ZenCODECoreTests (memory engine)
//
//  Graph version 4 on disk: the JSON without vectors and the binary vectors
//  file next to it. Write order, every mix of files from two saves, a vectors
//  file left alone when no vector changes, the v3 → v4 migration, rejection by
//  a v3 build, unusable vectors files, and the in-memory graph equal to the
//  decoded files after every adoption path.
//

import Foundation
import Testing
@testable import ZenCODECore

/// Vectors no binary16 value represents exactly, so a missed rounding shows.
private struct FineGrainedEmbeddingProvider: EmbeddingProvider {
    let modelID: String
    var dimensions = 6

    func embed(_ text: String) async throws -> [Float] {
        Self.vector(for: text, dimensions: dimensions)
    }

    static func vector(for text: String, dimensions: Int = 6) -> [Float] {
        let seed = Double(text.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) % 10_007 })
        return (0..<dimensions).map { Float(sin(seed + Double($0) * 0.7) / 3) }
    }
}

private struct InjectedFailure: Error {}

@Suite struct MemoryVectorPersistenceTests {
    typealias DirectorySnapshot = PersistenceCharacterizationTests.DirectorySnapshot

    private static func makeDirectory() throws -> URL {
        try PersistenceCharacterizationTests.makeDirectory()
    }

    private static func vectorsURL(_ file: URL) -> URL {
        JSONMemoryPersistence.vectorsURL(forGraphAt: file)
    }

    /// Inode and modification time: a republished file changes both.
    private static func fileStamp(_ url: URL) throws -> [String] {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return [
            "\((attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0)",
            "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)",
        ]
    }

    private static func entry(
        _ id: String,
        _ content: String,
        model: String? = "model-a",
        vector: [Float]?,
        tag: String? = nil
    ) -> EngineMemoryEntry {
        EngineMemoryEntry(
            id: id,
            category: .fact,
            content: content,
            tags: [tag ?? "tag-\(id)"],
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            embedding: vector,
            embeddingModel: model
        )
    }

    private static func graph(_ entries: [EngineMemoryEntry]) -> MemoryGraph {
        var graph = MemoryGraph()
        for entry in entries { graph.addMemory(entry) }
        return graph
    }

    /// Equal graphs up to the order of reverse-edge lists, which a decode
    /// rebuilds from the edges.
    private static func expectSameGraph(
        _ lhs: MemoryGraph,
        _ rhs: MemoryGraph,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(lhs.memories == rhs.memories, sourceLocation: sourceLocation)
        #expect(lhs.edges == rhs.edges, sourceLocation: sourceLocation)
        #expect(lhs.tags == rhs.tags, sourceLocation: sourceLocation)
        #expect(lhs.clusters == rhs.clusters, sourceLocation: sourceLocation)
        #expect(lhs.metadata == rhs.metadata, sourceLocation: sourceLocation)
        #expect(lhs.graphVersion == rhs.graphVersion, sourceLocation: sourceLocation)
        #expect(lhs.reverseEdges.mapValues(Set.init) == rhs.reverseEdges.mapValues(Set.init), sourceLocation: sourceLocation)
    }

    /// The invariant: the graph the engine adopted, and the one its persistence
    /// re-primed its cache with, are exactly what decoding the published files
    /// returns — vectors at the stored precision included.
    private static func expectCoherent(
        _ engine: MemoryEngine,
        file: URL,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let decoded = try await JSONMemoryPersistence(url: file).load()
        expectSameGraph(await engine.snapshot(), decoded, sourceLocation: sourceLocation)
        let persistence = try #require(await engine.persistence as? JSONMemoryPersistence, sourceLocation: sourceLocation)
        let decodes = await persistence.diskDecodeCount
        expectSameGraph(try await persistence.reloadReadOnly(), decoded, sourceLocation: sourceLocation)
        #expect(await persistence.diskDecodeCount == decodes, "re-primed cache", sourceLocation: sourceLocation)
        for entry in decoded.memories.values {
            #expect(entry.embedding?.allSatisfy(HalfPrecision.isRepresentable) ?? true, sourceLocation: sourceLocation)
        }
    }

    // MARK: - Layout

    @Test func saveWritesAVersionFourJSONWithoutVectorsAndAPrivateVectorsFile() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        var archived = Self.entry("archived", "kept vector", vector: FineGrainedEmbeddingProvider.vector(for: "z"))
        archived.active = false
        let graph = Self.graph([
            Self.entry("a", "first", vector: FineGrainedEmbeddingProvider.vector(for: "a")),
            Self.entry("b", "second", model: nil, vector: FineGrainedEmbeddingProvider.vector(for: "b")),
            Self.entry("plain", "no vector", vector: nil),
            archived,
        ])

        try await JSONMemoryPersistence(url: file).save(graph)

        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["graph_version"] as? Int == 4)
        let memories = try #require(json["memories"] as? [String: [String: Any]])
        #expect(memories.values.allSatisfy { $0["embedding"] == nil })
        #expect(memories["a"]?["embedding_model"] as? String == "model-a")
        #expect(memories["plain"]?["embedding_model"] as? String == "model-a")
        let records = try #require(MemoryVectorFile.decode(Data(contentsOf: Self.vectorsURL(file))))
        #expect(Set(records.keys) == ["a", "b", "archived"])
        let mode = try FileManager.default.attributesOfItem(atPath: Self.vectorsURL(file).path)[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(names == ["memory.graph.json", "memory.graph.json.lock", "memory.graph.json.vectors"])

        let reloaded = try await JSONMemoryPersistence(url: file).load()
        Self.expectSameGraph(reloaded, graph)
        #expect(reloaded.memories["plain"]?.embedding == nil)

        // The same graph yields the same bytes.
        let other = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        let otherFile = other.appendingPathComponent("memory.graph.json")
        try await JSONMemoryPersistence(url: otherFile).save(reloaded)
        #expect(try Data(contentsOf: otherFile) == Data(contentsOf: file))
        #expect(try Data(contentsOf: Self.vectorsURL(otherFile)) == Data(contentsOf: Self.vectorsURL(file)))
    }

    @Test func loadingAVersionFourGraphWritesNothing() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        try await JSONMemoryPersistence(url: file).save(Self.graph([
            Self.entry("a", "first", vector: [0.5, 0.25]),
        ]))
        let before = try DirectorySnapshot(directory)

        let persistence = JSONMemoryPersistence(url: file)
        #expect(try await persistence.load().memories["a"]?.embedding == [0.5, 0.25])
        _ = try await persistence.reloadReadOnly()
        _ = try await JSONMemoryPersistence(url: file).reloadReadOnly()
        _ = try await persistence.transaction { graph in graph.memories.count }

        #expect(try DirectorySnapshot(directory) == before)
        #expect(await persistence.diskDecodeCount == 1)
    }

    // MARK: - Write order and mixed files

    /// The vectors file is published before the JSON: a save interrupted in
    /// between leaves the new vectors with the old JSON, and loading that pair
    /// gives no entry the vector of another text.
    @Test func vectorsArePublishedBeforeTheJSON() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        let persistence = JSONMemoryPersistence(url: file)
        let old = Self.graph([
            Self.entry("edited", "old text", vector: [1, 1]),
            Self.entry("kept", "same text", vector: [2, 2]),
        ])
        try await persistence.save(old)
        let oldJSON = try Data(contentsOf: file)

        var new = old
        new.memories["edited"]?.content = "new text"
        new.memories["edited"]?.setEmbedding([3, 3], model: "model-a")
        new.addMemory(Self.entry("added", "added text", vector: [4, 4]))
        await persistence.setAfterVectorsPublishHook { throw InjectedFailure() }

        await #expect(throws: InjectedFailure.self) {
            try await persistence.save(new)
        }

        // Vectors written, JSON not.
        #expect(try Data(contentsOf: file) == oldJSON)
        #expect(try Data(contentsOf: Self.vectorsURL(file)) == MemoryVectorFile.encode(new))
        let mixed = try await JSONMemoryPersistence(url: file).load()
        #expect(mixed.memories["edited"]?.content == "old text")
        #expect(mixed.memories["edited"]?.embedding == nil)
        #expect(mixed.memories["kept"]?.embedding == [2, 2])
        #expect(mixed.memories["added"] == nil)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains("staging") }
        #expect(leftovers.isEmpty)

        // The next save completes the pair.
        await persistence.setAfterVectorsPublishHook(nil)
        try await persistence.save(new)
        Self.expectSameGraph(try await JSONMemoryPersistence(url: file).load(), new)
    }

    /// Two saves, A then B, and every pairing of their files (as a crash, an
    /// unlocked read during a publish or a partial manual copy can produce):
    /// a vector is only ever found on an entry whose content and model are
    /// those it was computed for.
    @Test func mixingTheFilesOfTwoSavesNeverPairsAVectorWithAnotherText() async throws {
        let root = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stateA = Self.graph([
            Self.entry("edited", "text before", vector: [1, 0]),
            Self.entry("remodelled", "same words", model: "model-a", vector: [2, 0]),
            Self.entry("reembedded", "stable text", vector: [3, 0]),
            Self.entry("kept", "untouched", vector: [4, 0]),
            Self.entry("removed", "deleted in B", vector: [5, 0]),
            Self.entry("cleared", "vector dropped in B", vector: [6, 0]),
        ])
        var stateB = stateA
        stateB.memories["edited"]?.content = "text after"
        stateB.memories["edited"]?.setEmbedding([1, 1], model: "model-a")
        stateB.memories["remodelled"]?.setEmbedding([2, 1], model: "model-b")
        stateB.memories["reembedded"]?.setEmbedding([3, 1], model: "model-a")
        _ = stateB.removeMemory(id: "removed")
        stateB.memories["cleared"]?.setEmbedding(nil, model: nil)
        stateB.addMemory(Self.entry("added", "deleted in B", vector: [7, 1]))

        let saved = try [stateA, stateB].map { graph -> (json: Data, vectors: Data) in
            (try JSONMemoryPersistence.encodeGraph(graph), try MemoryVectorFile.encode(graph))
        }
        let states = [stateA, stateB]
        let corrupt = Data("not a vectors file".utf8)
        let pairs: [(String, Data, Data?)] = [
            ("A+A", saved[0].json, saved[0].vectors),
            ("A+B", saved[0].json, saved[1].vectors),
            ("B+A", saved[1].json, saved[0].vectors),
            ("B+B", saved[1].json, saved[1].vectors),
            ("A+none", saved[0].json, nil),
            ("B+corrupt", saved[1].json, corrupt),
        ]
        var loadedByPair: [String: MemoryGraph] = [:]
        for (name, json, vectors) in pairs {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("memory.graph.json")
            try json.write(to: file)
            if let vectors { try vectors.write(to: Self.vectorsURL(file)) }
            let loaded = try await JSONMemoryPersistence(url: file).load()
            loadedByPair[name] = loaded
            for (id, entry) in loaded.memories {
                guard let vector = entry.embedding else { continue }
                let legitimate = states.contains { state in
                    guard let source = state.memories[id] else { return false }
                    return source.content == entry.content
                        && source.effectiveEmbeddingModel == entry.effectiveEmbeddingModel
                        && source.embedding == vector
                }
                #expect(legitimate, "\(name): \(id) has a vector of another text or model")
            }
        }

        Self.expectSameGraph(try #require(loadedByPair["A+A"]), stateA)
        Self.expectSameGraph(try #require(loadedByPair["B+B"]), stateB)
        let oldWithNew = try #require(loadedByPair["A+B"])
        #expect(oldWithNew.memories["edited"]?.embedding == nil)
        #expect(oldWithNew.memories["remodelled"]?.embedding == nil)
        #expect(oldWithNew.memories["reembedded"]?.embedding == [3, 1])   // same text and model
        #expect(oldWithNew.memories["kept"]?.embedding == [4, 0])
        #expect(oldWithNew.memories["removed"]?.embedding == nil)
        #expect(oldWithNew.memories["cleared"]?.embedding == nil)
        let newWithOld = try #require(loadedByPair["B+A"])
        #expect(newWithOld.memories["edited"]?.embedding == nil)
        #expect(newWithOld.memories["remodelled"]?.embedding == nil)
        #expect(newWithOld.memories["reembedded"]?.embedding == [3, 0])
        #expect(newWithOld.memories["kept"]?.embedding == [4, 0])
        // Same id-less text as the removed entry, but another id: no vector.
        #expect(newWithOld.memories["added"]?.embedding == nil)
        #expect(try #require(loadedByPair["A+none"]).memories.values.allSatisfy { $0.embedding == nil })
        #expect(try #require(loadedByPair["B+corrupt"]).memories.values.allSatisfy { $0.embedding == nil })
    }

    // MARK: - Rewrites

    /// Only a change of what the vectors file holds rewrites it: an access
    /// count, an edge or the text of an entry without a vector republish the
    /// JSON alone, including in a fresh process.
    @Test func theVectorsFileIsRewrittenOnlyWhenAVectorChanges() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        let vectors = Self.vectorsURL(file)
        let persistence = JSONMemoryPersistence(url: file)
        try await persistence.save(Self.graph([
            Self.entry("a", "with vector", vector: FineGrainedEmbeddingProvider.vector(for: "a")),
            Self.entry("b", "other vector", vector: FineGrainedEmbeddingProvider.vector(for: "b")),
            Self.entry("plain", "no vector", vector: nil),
        ]))
        #expect(await persistence.vectorsPublishCount == 1)
        let stamp = try Self.fileStamp(vectors)

        var jsonStamp = try Self.fileStamp(file)
        func expectJSONOnly(_ label: String, _ body: @Sendable (inout MemoryGraph) -> Void, on persistence: JSONMemoryPersistence) async throws {
            let committed = try await persistence.transaction(initialGraph: nil, body)
            #expect(committed.didChange, "\(label)")
            #expect(try Self.fileStamp(vectors) == stamp, "\(label): vectors file republished")
            #expect(try Self.fileStamp(file) != jsonStamp, "\(label): JSON not republished")
            jsonStamp = try Self.fileStamp(file)
        }
        try await expectJSONOnly("access count", { $0.memories["a"]?.accessCount += 1 }, on: persistence)
        try await expectJSONOnly("edge", { $0.linkMemories(from: "a", to: "b", weight: 0.7) }, on: persistence)
        try await expectJSONOnly("text without vector", { $0.memories["plain"]?.content = "edited" }, on: persistence)
        try await expectJSONOnly("model without vector", { $0.memories["plain"]?.embeddingModel = "model-z" }, on: persistence)
        #expect(await persistence.vectorsPublishCount == 1)

        // A fresh process knows the file from its first read.
        let restarted = JSONMemoryPersistence(url: file)
        _ = try await restarted.load()
        try await expectJSONOnly("after restart", { $0.memories["b"]?.accessCount += 1 }, on: restarted)
        #expect(await restarted.vectorsPublishCount == 0)

        // A vector, or the text or model it is bound to, rewrites it.
        _ = try await restarted.transaction { graph in
            graph.memories["a"]?.setEmbedding(FineGrainedEmbeddingProvider.vector(for: "new"), model: "model-a")
        }
        #expect(await restarted.vectorsPublishCount == 1)
        let afterVector = try Self.fileStamp(vectors)
        #expect(afterVector != stamp)
        _ = try await restarted.transaction { graph in graph.memories["b"]?.content = "other vector, edited" }
        #expect(await restarted.vectorsPublishCount == 2)
        #expect(try Self.fileStamp(vectors) != afterVector)
    }

    /// Writing back the binary32 vector an entry was given — what a provider
    /// returns — is no change: the entry already holds its binary16 rounding,
    /// so the transaction reports nothing and neither file is touched.
    @Test func reassigningTheFullPrecisionVectorIsNoChange() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        let raw = FineGrainedEmbeddingProvider.vector(for: "a")
        #expect(!raw.allSatisfy(HalfPrecision.isRepresentable))
        try await JSONMemoryPersistence(url: file).save(Self.graph([Self.entry("a", "text", vector: raw)]))
        let before = try DirectorySnapshot(directory)

        let persistence = JSONMemoryPersistence(url: file)
        let committed = try await persistence.transaction { graph in
            graph.memories["a"]?.setEmbedding(raw, model: "model-a")
            graph.memories["a"]?.embedding = raw
        }
        #expect(committed.didChange == false)
        let engine = try await MemoryEngine.open(persistence: persistence)
        try await engine.transaction { graph in graph.memories["a"]?.setEmbedding(raw, model: "model-a") }
        try await engine.save()

        #expect(try DirectorySnapshot(directory) == before)
    }

    // MARK: - Versions

    /// A version 3 graph loads with its vectors already at the precision the
    /// first save writes, so that save — the first mutation — changes nothing
    /// else; it writes version 4 and the vectors file, and reloading returns
    /// exactly the graph the engine holds.
    @Test func firstSaveMigratesAVersionThreeGraphAtBinary16() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        let raw: [Float] = [0.1, 1.0 / 3.0, -0.7, 1e-6, 0.000_123, 65_000]
        let base64 = EmbeddingWireCoding.string(from: raw)
        let fixture = PersistenceCharacterizationTests.fixtureJSON(.version3)
            .replacingOccurrences(of: "AACAPwAAIMAAAAAAAAAAPg==", with: base64)
        try Data(fixture.utf8).write(to: file)
        let before = try DirectorySnapshot(directory)

        let engine = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: file))
        let loaded = try #require(await engine.snapshot().memories["mem_vec"]?.embedding)
        #expect(loaded.map(\.bitPattern) == raw.map { HalfPrecision.rounded($0).bitPattern })
        for (original, held) in zip(raw, loaded) {
            // Within half a binary16 step of the stored binary32 value.
            let step = HalfPrecision.value(fromBits: HalfPrecision.bits(from: abs(original)) + 1)
                - HalfPrecision.value(fromBits: HalfPrecision.bits(from: abs(original)))
            #expect(abs(original - held) <= step / 2)
        }
        #expect(try DirectorySnapshot(directory) == before)

        try await engine.transaction { graph in graph.memories["mem_plain"]?.accessCount += 1 }

        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(json["graph_version"] as? Int == 4)
        let memories = try #require(json["memories"] as? [String: [String: Any]])
        #expect(memories["mem_vec"]?["embedding"] == nil)
        let record = try #require(MemoryVectorFile.decode(Data(contentsOf: Self.vectorsURL(file)))?["mem_vec"])
        #expect(record.components.map(\.bitPattern) == loaded.map(\.bitPattern))
        try await Self.expectCoherent(engine, file: file)
        #expect(try await JSONMemoryPersistence(url: file).load().memories["mem_vec"]?.embedding == loaded)
    }

    /// What an earlier build does with a version 4 graph, played by a
    /// persistence that supports at most version 3: it refuses every load,
    /// including the reload under the lock, and leaves both files as they are.
    @Test func aVersionThreeBuildRejectsVersionFourAndLeavesBothFiles() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        try await JSONMemoryPersistence(url: file).save(Self.graph([
            Self.entry("a", "text", vector: [0.5, 1]),
        ]))
        let before = try DirectorySnapshot(directory)

        let older = JSONMemoryPersistence(url: file, supportedGraphVersion: 3)
        await #expect(throws: MemoryPersistenceError.unsupportedGraphVersion(4)) {
            _ = try await older.load()
        }
        await #expect(throws: MemoryPersistenceError.unsupportedGraphVersion(4)) {
            _ = try await older.reloadReadOnly()
        }
        await #expect(throws: MemoryPersistenceError.unsupportedGraphVersion(4)) {
            _ = try await older.transaction { graph in graph.memories["a"]?.accessCount += 1 }
        }
        await #expect(throws: MemoryPersistenceError.unsupportedGraphVersion(4)) {
            _ = try await MemoryEngine.open(persistence: older)
        }
        #expect(try DirectorySnapshot(directory) == before)
    }

    // MARK: - Unusable vectors file

    enum Damage: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case missing, garbage, truncated, unknownFormatVersion, unknownComponentType

        var testDescription: String { rawValue }

        func apply(to url: URL) throws {
            var bytes = try Data(contentsOf: url)
            switch self {
            case .missing:
                try FileManager.default.removeItem(at: url)
                return
            case .garbage:
                bytes = Data("{\"this is\": \"not a vectors file\"}".utf8)
            case .truncated:
                bytes = bytes.prefix(bytes.count - 1)
            case .unknownFormatVersion:
                bytes[4] = 2
            case .unknownComponentType:
                bytes[6] = 9
            }
            try bytes.write(to: url)
        }
    }

    /// A missing, corrupt or unknown vectors file is not an error: the graph
    /// loads without vectors (BM25), loading still writes nothing, the entries
    /// count as needing a vector, and the next save rewrites the file.
    @Test(arguments: Damage.allCases)
    func anUnusableVectorsFileLoadsTheGraphWithoutVectors(_ damage: Damage) async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        try await JSONMemoryPersistence(url: file).save(Self.graph([
            Self.entry("a", "first", vector: [0.5, 1]),
            Self.entry("b", "second", vector: [0.25, 1]),
        ]))
        try damage.apply(to: Self.vectorsURL(file))
        let before = try DirectorySnapshot(directory)

        let engine = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: file))
        let loaded = await engine.snapshot()
        #expect(loaded.memories.count == 2)
        #expect(loaded.memories.values.allSatisfy { $0.embedding == nil && $0.embeddingModel == "model-a" })
        #expect(MemoryReembedding.plan(loaded, modelID: "model-a").entriesToEmbed == 2)
        #expect(try DirectorySnapshot(directory) == before)

        try await engine.transaction { graph in graph.memories["a"]?.accessCount += 1 }
        #expect(try MemoryVectorFile.decode(Data(contentsOf: Self.vectorsURL(file))) == [:])
        try await Self.expectCoherent(engine, file: file)
    }

    /// The JSON keeps its contract: a corrupt one is an error, as before.
    @Test func aCorruptJSONIsStillAnError() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        try await JSONMemoryPersistence(url: file).save(Self.graph([Self.entry("a", "first", vector: [1])]))
        try Data("{ not json".utf8).write(to: file)

        await #expect(throws: DecodingError.self) {
            _ = try await JSONMemoryPersistence(url: file).load()
        }
    }

    // MARK: - Adoption paths

    /// Every store path that changes vectors leaves the engine, its reload
    /// cache and the files in agreement, and returns entries holding exactly
    /// the stored vector.
    @Test func everyStorePathLeavesTheEngineEqualToTheDecodedFiles() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        let file = workspace.rootURL.appendingPathComponent("graph", isDirectory: true)
            .appendingPathComponent("memory.graph.json")
        let provider = FineGrainedEmbeddingProvider(modelID: "fine-a")
        let store = try await MemoryEmbedding.withProvider(provider) {
            try await MemoryGraphStore.open(graphURL: file)
        }
        func expectStored(_ entry: GraphEntry, sourceLocation: SourceLocation = #_sourceLocation) async throws {
            let decoded = try await JSONMemoryPersistence(url: file).load().memories[entry.id]
            #expect(entry == decoded, sourceLocation: sourceLocation)
            #expect(entry == (await store.engine.snapshot().memories[entry.id]), sourceLocation: sourceLocation)
        }

        // write (writeDetailed)
        let written = try await store.writeDetailed(content: "Summary: written entry", category: .fact, tags: ["w"]).entry
        #expect(written.embedding?.count == 6)
        try await expectStored(written)
        try await Self.expectCoherent(store.engine, file: file)
        let other = try await store.write(content: "Summary: another entry", category: .fact, tags: ["o"]).entry

        // update
        let updated = try await store.update(
            id: written.id, content: "Summary: written entry, updated", tags: nil,
            updatedAt: Date(), timeZone: TimeZone(identifier: "UTC")!
        )
        #expect(updated.embedding != written.embedding)
        try await expectStored(updated)
        try await Self.expectCoherent(store.engine, file: file)

        // archive, re-embedding run (clears the archived vector), restore
        _ = try await store.setArchived(true, id: other.id)
        _ = try await store.reembed(run: MemoryReembeddingRun())
        #expect(try await JSONMemoryPersistence(url: file).load().memories[other.id]?.embedding == nil)
        let restored = try await store.setArchived(false, id: other.id)
        #expect(restored.embedding?.count == 6)
        try await expectStored(restored)
        try await Self.expectCoherent(store.engine, file: file)

        // recall maintenance replayed by a flush
        for _ in 0..<3 { _ = try await store.context(for: "written entry updated") }
        try await store.engine.flushRecallMaintenance()
        try await Self.expectCoherent(store.engine, file: file)

        // re-embedding blocks with another model, on a second store of the file
        let reembedder = try await MemoryEmbedding.withProvider(FineGrainedEmbeddingProvider(modelID: "fine-b", dimensions: 5)) {
            try await MemoryGraphStore.open(graphURL: file)
        }
        let summary = try await reembedder.reembed(run: MemoryReembeddingRun())
        #expect(summary.embedded == 2)
        try await Self.expectCoherent(reembedder.engine, file: file)
        #expect(try await JSONMemoryPersistence(url: file).load().memories.values.allSatisfy { $0.embedding?.count == 5 })

        // cleanup, which also writes the backup pair
        _ = try await reembedder.setArchived(true, id: other.id)
        _ = try await reembedder.cleanup(
            MemoryCleanupPolicy(archivedRetentionDays: 30),
            now: Date().addingTimeInterval(40 * 86_400)
        )
        try await Self.expectCoherent(reembedder.engine, file: file)
        let backup = try await PersistenceCharacterizationTests.loadCleanupBackup(of: file)
        #expect(backup.memories[other.id]?.active == false)
    }

    /// The engine paths that adopt their own draft instead of a reloaded graph
    /// — an explicit save and a transaction after `insert(persist: false)` —
    /// hold the stored precision as well.
    @Test func engineDraftPathsAdoptTheStoredPrecision() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        let engine = try await MemoryEngine.open(persistence: JSONMemoryPersistence(url: file))
        let raw = FineGrainedEmbeddingProvider.vector(for: "deferred")

        try await engine.insert(Self.entry("deferred", "deferred insert", vector: raw), persist: false)
        #expect(await engine.snapshot().memories["deferred"]?.embedding == HalfPrecision.rounded(raw))
        try await engine.save()
        try await Self.expectCoherent(engine, file: file)

        try await engine.insert(Self.entry("second", "second insert", vector: raw), persist: false)
        try await engine.transaction { graph in graph.memories["deferred"]?.accessCount += 1 }
        try await Self.expectCoherent(engine, file: file)

        let embedded = MemoryEngine(
            embedder: FineGrainedEmbeddingProvider(modelID: "fine-a"),
            persistence: JSONMemoryPersistence(url: file)
        )
        let remembered = try await embedded.remember("remembered through the engine", id: "remembered")
        #expect(remembered.embedding?.allSatisfy(HalfPrecision.isRepresentable) == true)
        #expect(remembered == (await embedded.snapshot().memories["remembered"]))
        try await Self.expectCoherent(embedded, file: file)
    }
}
