import Foundation

public protocol MemoryPersistence: Sendable {
    func load() async throws -> MemoryGraph
    func save(_ graph: MemoryGraph) async throws
}

public actor JSONMemoryPersistence: MemoryPersistence {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() async throws -> MemoryGraph {
        guard FileManager.default.fileExists(atPath: url.path) else { return MemoryGraph() }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var graph = try decoder.decode(MemoryGraph.self, from: data)
        graph.rebuildReverseEdges()
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
}

public actor InMemoryPersistence: MemoryPersistence {
    private var graph: MemoryGraph

    public init(graph: MemoryGraph = MemoryGraph()) {
        self.graph = graph
    }

    public func load() async throws -> MemoryGraph { graph }
    public func save(_ graph: MemoryGraph) async throws { self.graph = graph }
}
