import Foundation
import Testing
@testable import ZenCODECore

@Suite struct EmbeddingEncodingPersistenceTests {
    private static func graphJSON(
        version: Int,
        embeddingLiteral: String?,
        id: String = "mem_1",
        content: String = "Swift runs on Linux"
    ) -> String {
        let embeddingLine = embeddingLiteral.map { "\"embedding\": \($0),\n" } ?? ""
        return """
        {
          "graph_version": \(version),
          "memories": {
            "\(id)": {
              "id": "\(id)",
              "category": "fact",
              "content": "\(content)",
              "tags": ["swift", "linux"],
              "search_text": "swift runs on linux swift linux",
              "created_at": "2026-08-07T12:00:00Z",
              "updated_at": "2026-08-07T12:00:00Z",
              "access_count": 0,
              "trust": "high",
              "strength": 1,
              "active": true,
              \(embeddingLine)"embedding_model": "example-embedding-v1",
              "confidence": 1.0
            }
          },
          "tags": {
            "tag:swift": {
              "id": "tag:swift",
              "name": "swift",
              "count": 1,
              "created_at": "2026-08-07T12:00:00Z"
            }
          },
          "clusters": {},
          "edges": {
            "\(id)": [{"target":"tag:swift","kind":"has_tag"}]
          },
          "reverse_edges": {"tag:swift":["\(id)"]},
          "metadata": {"retrieval_count":0,"link_discovery_count":0}
        }
        """
    }

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func wireCodingRoundTripsBitPatterns() throws {
        let subnormal = Float.leastNormalMagnitude / 4
        let vectors: [[Float]] = [
            [1.0, 2.5, 3.14159, 1e-3, 123456.789],
            [-1.0, -2.5, -0.0001, -98765.4],
            [0.0, -0.0],
            [subnormal, -subnormal, Float.leastNonzeroMagnitude],
            [Float.greatestFiniteMagnitude, -Float.greatestFiniteMagnitude],
            [Float.infinity, -Float.infinity],
            [Float.nan, 1.0]
        ]
        for vector in vectors {
            let decoded = try #require(
                EmbeddingWireCoding.values(fromBase64: EmbeddingWireCoding.string(from: vector))
            )
            #expect(decoded.count == vector.count)
            for (original, roundTripped) in zip(vector, decoded) {
                if original.isNaN {
                    #expect(roundTripped.isNaN)
                } else {
                    #expect(original.bitPattern == roundTripped.bitPattern)
                }
            }
        }

        #expect(EmbeddingWireCoding.string(from: []) == "")
        #expect(EmbeddingWireCoding.values(fromBase64: "") == [])

        let bytes = EmbeddingWireCoding.data(from: [1.0])
        #expect(Array(bytes) == [0x00, 0x00, 0x80, 0x3F])
    }

    @Test func wireCodingRejectsMalformedPayloads() {
        #expect(EmbeddingWireCoding.values(fromBase64: "not base64!") == nil)
        let fiveBytes = Data([1, 2, 3, 4, 5]).base64EncodedString()
        #expect(EmbeddingWireCoding.values(fromBase64: fiveBytes) == nil)
        #expect(EmbeddingWireCoding.values(from: Data(count: 6)) == nil)
    }

    @Test func loadsVersionTwoNumericArray() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")
        try Data(Self.graphJSON(version: 2, embeddingLiteral: "[1.0, -2.5, 0.0]").utf8).write(to: file)
        let before = try Data(contentsOf: file)

        let graph = try await JSONMemoryPersistence(url: file).load()
        #expect(graph.memories["mem_1"]?.embedding == [1.0, -2.5, 0.0])
        #expect(graph.graphVersion == MemoryGraph.currentGraphVersion)
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func saveWritesVersionFourWithTheVectorInTheVectorsFile() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")
        try Data(Self.graphJSON(version: 2, embeddingLiteral: "[1.0, -2.5, 0.0]").utf8).write(to: file)

        let persistence = JSONMemoryPersistence(url: file)
        let graph = try await persistence.load()
        try await persistence.save(graph)

        let bytes = try Data(contentsOf: file)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("\"graph_version\" : 4"))

        let root = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let memories = try #require(root["memories"] as? [String: Any])
        let entry = try #require(memories["mem_1"] as? [String: Any])
        #expect(entry["embedding"] == nil)
        #expect(entry["embedding_model"] as? String == "example-embedding-v1")

        let vectors = try Data(contentsOf: JSONMemoryPersistence.vectorsURL(forGraphAt: file))
        let record = try #require(MemoryVectorFile.decode(vectors)?["mem_1"])
        #expect(record.components == [1.0, -2.5, 0.0])
        #expect(record.fingerprint == MemoryVectorFile.fingerprint(
            model: "example-embedding-v1",
            content: "Swift runs on Linux"
        ))

        let reloaded = try await JSONMemoryPersistence(url: file).load()
        #expect(reloaded.memories["mem_1"]?.embedding == [1.0, -2.5, 0.0])
        #expect(reloaded.memories["mem_1"]?.embeddingModel == "example-embedding-v1")
        #expect(reloaded == graph)
    }

    /// A large vector is held, saved and reloaded at the stored precision: the
    /// in-memory value is the binary16 rounding of what was assigned, and the
    /// round trip preserves it bit for bit.
    @Test func roundTripPreservesLargeVectorAtTheStoredPrecision() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")

        let vector: [Float] = (0..<4096).map { Float(sin(Double($0)) * 1000) }
        var graph = MemoryGraph()
        graph.addMemory(EngineMemoryEntry(
            id: "vec",
            category: .fact,
            content: "vector",
            embedding: vector,
            embeddingModel: "test-model"
        ))
        let held = try #require(graph.memories["vec"]?.embedding)
        #expect(held.map(\.bitPattern) == vector.map { HalfPrecision.rounded($0).bitPattern })
        try await JSONMemoryPersistence(url: file).save(graph)

        let loaded = try await JSONMemoryPersistence(url: file).load()
        let restored = try #require(loaded.memories["vec"]?.embedding)
        #expect(restored.count == vector.count)
        #expect(zip(held, restored).allSatisfy { $0.bitPattern == $1.bitPattern })
        #expect(loaded.memories["vec"]?.embeddingModel == "test-model")
        #expect(loaded == graph)
    }

    @Test func loadRejectsCorruptBase64Embedding() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")
        try Data(Self.graphJSON(version: 3, embeddingLiteral: "\"@@@not-base64@@@\"").utf8).write(to: file)
        let before = try Data(contentsOf: file)

        let persistence = JSONMemoryPersistence(url: file)
        await #expect(throws: DecodingError.self) {
            _ = try await persistence.load()
        }
        #expect(try Data(contentsOf: file) == before)
    }

    @Test func entryWithoutEmbeddingOmitsTheKey() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("graph.json")

        var graph = MemoryGraph()
        graph.addMemory(EngineMemoryEntry(
            id: "plain",
            category: .fact,
            content: "no vector",
            embeddingModel: "test-model"
        ))
        try await JSONMemoryPersistence(url: file).save(graph)

        let text = String(decoding: try Data(contentsOf: file), as: UTF8.self)
        #expect(!text.contains("\"embedding\" :"))
        #expect(text.contains("\"embedding_model\" :"))

        let loaded = try await JSONMemoryPersistence(url: file).load()
        #expect(loaded.memories["plain"]?.embedding == nil)
    }
}
