import Foundation

public protocol MemoryPersistence: Sendable {
    func load() async throws -> MemoryGraph
    func save(_ graph: MemoryGraph) async throws
}

public enum MemoryPersistenceError: Error, Sendable, Equatable {
    /// The graph file was written by a newer engine than this build supports.
    /// The file is rejected and left byte-identical on disk.
    case unsupportedGraphVersion(UInt32)
}

public actor JSONMemoryPersistence: MemoryPersistence {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() async throws -> MemoryGraph {
        guard FileManager.default.fileExists(atPath: url.path) else { return MemoryGraph() }
        let data = try Data(contentsOf: url)

        // Reject future formats before attempting a full decode: the schema may
        // have changed in ways this build cannot interpret. load() never writes,
        // so rejecting here keeps the file byte-identical.
        let envelopeDecoder = JSONDecoder()
        envelopeDecoder.keyDecodingStrategy = .convertFromSnakeCase
        if let envelope = try? envelopeDecoder.decode(GraphVersionEnvelope.self, from: data),
           let version = envelope.graphVersion,
           version > MemoryGraph.currentGraphVersion {
            throw MemoryPersistenceError.unsupportedGraphVersion(version)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var graph = try decoder.decode(MemoryGraph.self, from: data)
        graph.rebuildReverseEdges()

        // Older versions (or files without an explicit version) are decoded by
        // the current schema: every newer field is optional with a contract
        // default (`scope` -> `.project`, `active` -> `true`, ...). Normalize
        // the in-memory version to the current one so the next save writes the
        // current format; the on-disk file is only rewritten by an explicit
        // save, never by loading.
        if graph.graphVersion < MemoryGraph.currentGraphVersion {
            graph.graphVersion = MemoryGraph.currentGraphVersion
        }
        return graph
    }

    public func save(_ graph: MemoryGraph) async throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(graph)
        try data.write(to: url, options: .atomic)
    }

    /// Minimal envelope used only to read `graph_version` before full decoding.
    private struct GraphVersionEnvelope: Decodable {
        let graphVersion: UInt32?
    }
}

public actor InMemoryPersistence: MemoryPersistence {
    private var graph: MemoryGraph

    public init(graph: MemoryGraph = MemoryGraph()) {
        self.graph = graph
    }

    public func load() async throws -> MemoryGraph { graph }
    public func save(_ graph: MemoryGraph) async throws { self.graph = graph }
}
