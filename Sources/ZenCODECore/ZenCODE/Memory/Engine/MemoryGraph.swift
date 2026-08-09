import Foundation

enum EdgeKind: Sendable, Equatable {
    case hasTag
    case inCluster
    case relatesTo(weight: Float)
    case supersedes
    case contradicts
    case derivedFrom

    public var traversalWeight: Float {
        switch self {
        case .hasTag: 0.8
        case .inCluster: 0.6
        case .relatesTo(let weight): weight
        case .supersedes: 0.9
        case .contradicts: 0.3
        case .derivedFrom: 0.7
        }
    }
}

extension EdgeKind: Codable {
    private enum CodingKeys: String, CodingKey { case kind, weight }
    private enum Kind: String, Codable {
        case hasTag = "has_tag"
        case inCluster = "in_cluster"
        case relatesTo = "relates_to"
        case supersedes
        case contradicts
        case derivedFrom = "derived_from"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .hasTag: self = .hasTag
        case .inCluster: self = .inCluster
        case .relatesTo: self = .relatesTo(weight: try container.decodeIfPresent(Float.self, forKey: .weight) ?? 1)
        case .supersedes: self = .supersedes
        case .contradicts: self = .contradicts
        case .derivedFrom: self = .derivedFrom
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .hasTag:
            try container.encode(Kind.hasTag, forKey: .kind)
        case .inCluster:
            try container.encode(Kind.inCluster, forKey: .kind)
        case .relatesTo(let weight):
            try container.encode(Kind.relatesTo, forKey: .kind)
            try container.encode(weight, forKey: .weight)
        case .supersedes:
            try container.encode(Kind.supersedes, forKey: .kind)
        case .contradicts:
            try container.encode(Kind.contradicts, forKey: .kind)
        case .derivedFrom:
            try container.encode(Kind.derivedFrom, forKey: .kind)
        }
    }
}

struct MemoryEdge: Codable, Sendable, Equatable {
    public var target: String
    public var kind: EdgeKind

    public init(target: String, kind: EdgeKind) {
        self.target = target
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey { case target, kind, weight }
    private enum Kind: String, Codable {
        case hasTag = "has_tag"
        case inCluster = "in_cluster"
        case relatesTo = "relates_to"
        case supersedes
        case contradicts
        case derivedFrom = "derived_from"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        target = try c.decode(String.self, forKey: .target)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .hasTag: kind = .hasTag
        case .inCluster: kind = .inCluster
        case .relatesTo: kind = .relatesTo(weight: try c.decodeIfPresent(Float.self, forKey: .weight) ?? 1)
        case .supersedes: kind = .supersedes
        case .contradicts: kind = .contradicts
        case .derivedFrom: kind = .derivedFrom
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(target, forKey: .target)
        switch kind {
        case .hasTag: try c.encode(Kind.hasTag, forKey: .kind)
        case .inCluster: try c.encode(Kind.inCluster, forKey: .kind)
        case .relatesTo(let weight):
            try c.encode(Kind.relatesTo, forKey: .kind)
            try c.encode(weight, forKey: .weight)
        case .supersedes: try c.encode(Kind.supersedes, forKey: .kind)
        case .contradicts: try c.encode(Kind.contradicts, forKey: .kind)
        case .derivedFrom: try c.encode(Kind.derivedFrom, forKey: .kind)
        }
    }
}

struct TagEntry: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var description: String?
    public var count: UInt32
    public var createdAt: Date

    public init(name: String, description: String? = nil, createdAt: Date = Date()) {
        self.id = "tag:\(name)"
        self.name = name
        self.description = description
        self.count = 0
        self.createdAt = createdAt
    }
}

struct ClusterEntry: Codable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var centroid: [Float]
    public var memberCount: UInt32
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, name: String? = nil, centroid: [Float] = [], createdAt: Date = Date()) {
        self.id = id.hasPrefix("cluster:") ? id : "cluster:\(id)"
        self.name = name
        self.centroid = centroid
        self.memberCount = 0
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

struct GraphMetadata: Codable, Sendable, Equatable {
    public var lastClusterUpdate: Date?
    public var retrievalCount: UInt64
    public var linkDiscoveryCount: UInt64

    public init(lastClusterUpdate: Date? = nil, retrievalCount: UInt64 = 0, linkDiscoveryCount: UInt64 = 0) {
        self.lastClusterUpdate = lastClusterUpdate
        self.retrievalCount = retrievalCount
        self.linkDiscoveryCount = linkDiscoveryCount
    }
}

struct MemoryGraph: Codable, Sendable, Equatable {
    public static let currentGraphVersion: UInt32 = 2

    /// Assumed `graph_version` for files written before the version key
    /// existed. Their schema matches the earliest versioned format; loading
    /// decodes them with the current contract defaults and normalizes them to
    /// `currentGraphVersion` in memory. The on-disk file is only rewritten by
    /// an explicit save, never by loading.
    public static let legacyGraphVersion: UInt32 = 1

    public var graphVersion: UInt32
    public var memories: [String: EngineMemoryEntry]
    public var tags: [String: TagEntry]
    public var clusters: [String: ClusterEntry]
    public var edges: [String: [MemoryEdge]]
    public var reverseEdges: [String: [String]]
    public var metadata: GraphMetadata

    public init(
        graphVersion: UInt32 = MemoryGraph.currentGraphVersion,
        memories: [String: EngineMemoryEntry] = [:],
        tags: [String: TagEntry] = [:],
        clusters: [String: ClusterEntry] = [:],
        edges: [String: [MemoryEdge]] = [:],
        reverseEdges: [String: [String]] = [:],
        metadata: GraphMetadata = .init()
    ) {
        self.graphVersion = graphVersion
        self.memories = memories
        self.tags = tags
        self.clusters = clusters
        self.edges = edges
        self.reverseEdges = reverseEdges
        self.metadata = metadata
    }

    // Explicit Codable: `graph_version` is optional on the wire so files that
    // predate the version key decode with a defined legacy default instead of
    // failing with keyNotFound. Every coding key below matches the synthesized
    // names exactly (camelCase here, snake_case on the wire through the
    // persistence key strategies), so existing files keep their wire format.
    private enum CodingKeys: String, CodingKey {
        case graphVersion, memories, tags, clusters, edges, reverseEdges, metadata
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        graphVersion = try c.decodeIfPresent(UInt32.self, forKey: .graphVersion)
            ?? Self.legacyGraphVersion
        memories = try c.decode([String: EngineMemoryEntry].self, forKey: .memories)
        tags = try c.decode([String: TagEntry].self, forKey: .tags)
        clusters = try c.decode([String: ClusterEntry].self, forKey: .clusters)
        edges = try c.decode([String: [MemoryEdge]].self, forKey: .edges)
        reverseEdges = try c.decode([String: [String]].self, forKey: .reverseEdges)
        metadata = try c.decode(GraphMetadata.self, forKey: .metadata)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(graphVersion, forKey: .graphVersion)
        try c.encode(memories, forKey: .memories)
        try c.encode(tags, forKey: .tags)
        try c.encode(clusters, forKey: .clusters)
        try c.encode(edges, forKey: .edges)
        try c.encode(reverseEdges, forKey: .reverseEdges)
        try c.encode(metadata, forKey: .metadata)
    }

    public var memoryCount: Int { memories.count }
    public var nodeCount: Int { memories.count + tags.count + clusters.count }
    public var edgeCount: Int { edges.values.reduce(0) { $0 + $1.count } }

    @discardableResult
    public mutating func addMemory(_ input: EngineMemoryEntry) -> String {
        var entry = input
        entry.refreshSearchText()
        let id = entry.id

        if let previous = memories[id] {
            removeTagEdges(for: previous)
        }

        memories[id] = entry
        for tagName in entry.tags {
            ensureTag(tagName)
            let tagID = "tag:\(tagName)"
            addEdgeInternal(from: id, to: tagID, kind: .hasTag)
            tags[tagID]?.count &+= 1
        }
        return id
    }

    @discardableResult
    public mutating func removeMemory(id: String) -> EngineMemoryEntry? {
        guard let entry = memories.removeValue(forKey: id) else { return nil }
        removeTagEdges(for: entry)

        if let outgoing = edges.removeValue(forKey: id) {
            for edge in outgoing {
                reverseEdges[edge.target]?.removeAll { $0 == id }
                if reverseEdges[edge.target]?.isEmpty == true { reverseEdges[edge.target] = nil }
            }
        }

        if let incoming = reverseEdges.removeValue(forKey: id) {
            for source in incoming {
                edges[source]?.removeAll { $0.target == id }
                if edges[source]?.isEmpty == true { edges[source] = nil }
            }
        }
        return entry
    }

    public mutating func updateMemory(_ entry: EngineMemoryEntry) {
        _ = addMemory(entry)
    }

    public mutating func addTag(_ tag: String, to memoryID: String) {
        guard var memory = memories[memoryID], !memory.tags.contains(tag) else { return }
        memory.tags.append(tag)
        memory.refreshSearchText()
        memories[memoryID] = memory
        ensureTag(tag)
        let tagID = "tag:\(tag)"
        addEdge(from: memoryID, to: tagID, kind: .hasTag)
        tags[tagID]?.count &+= 1
    }

    public mutating func addCluster(_ cluster: ClusterEntry) {
        clusters[cluster.id] = cluster
    }

    public mutating func assign(memoryID: String, toCluster clusterID: String) {
        let normalized = clusterID.hasPrefix("cluster:") ? clusterID : "cluster:\(clusterID)"
        guard memories[memoryID] != nil, clusters[normalized] != nil else { return }
        addEdge(from: memoryID, to: normalized, kind: .inCluster)
        clusters[normalized]?.memberCount &+= 1
        clusters[normalized]?.updatedAt = Date()
    }

    public mutating func addEdge(from: String, to: String, kind: EdgeKind) {
        if edges[from]?.contains(where: { $0.target == to && $0.kind == kind }) == true { return }
        addEdgeInternal(from: from, to: to, kind: kind)
    }

    public mutating func removeEdge(from: String, to: String, kind: EdgeKind) {
        edges[from]?.removeAll { $0.target == to && $0.kind == kind }
        if edges[from]?.isEmpty == true { edges[from] = nil }
        reverseEdges[to]?.removeAll { $0 == from }
        if reverseEdges[to]?.isEmpty == true { reverseEdges[to] = nil }
    }

    public func outgoingEdges(from id: String) -> [MemoryEdge] { edges[id] ?? [] }
    public func incomingNodes(to id: String) -> [String] { reverseEdges[id] ?? [] }

    /// Creates a `relatesTo` edge between two memories and records link
    /// discovery.
    ///
    /// The guard makes this a **no-op when either endpoint no longer exists or
    /// has been deactivated** (archived/superseded). Co-relevance links are
    /// discovered during retrieval maintenance, which runs after the selector
    /// `await`; a concurrent `forget` or archive can remove or deactivate one of
    /// the endpoints in that window. Without the guard the edge — and its
    /// reverse-edge — would dangle forever. Tag and cluster edges are created
    /// through ``addEdge(from:to:kind:)`` and ``assign(memoryID:toCluster:)``,
    /// which are unaffected.
    public mutating func linkMemories(from: String, to: String, weight: Float) {
        guard let source = memories[from], source.active,
              let target = memories[to], target.active else { return }
        addEdge(from: from, to: to, kind: .relatesTo(weight: min(max(weight, 0), 1)))
        metadata.linkDiscoveryCount &+= 1
    }

    public mutating func supersede(newerID: String, olderID: String) {
        guard memories[newerID] != nil, var older = memories[olderID] else { return }
        addEdge(from: newerID, to: olderID, kind: .supersedes)
        older.supersede(with: newerID)
        memories[olderID] = older
    }

    public mutating func markContradiction(_ firstID: String, _ secondID: String) {
        addEdge(from: firstID, to: secondID, kind: .contradicts)
        addEdge(from: secondID, to: firstID, kind: .contradicts)
    }

    public mutating func cascadeRetrieve(
        seeds: [ScoredMemoryID],
        maxDepth: Int = 2,
        maxResults: Int = 10,
        edgeDecay: Float = 0.7,
        scope: EngineMemoryScope = .all
    ) -> [ScoredMemoryID] {
        metadata.retrievalCount &+= 1
        guard maxResults > 0 else { return [] }

        struct QueueItem {
            var id: String
            var score: Float
            var depth: Int
        }

        /// A memory may be seeded, traversed, or returned only when it is
        /// active and inside the requested scope. Archived nodes never enter
        /// the queue, so they cannot act as bridges to their neighbours.
        func isRetrievable(_ id: String) -> Bool {
            guard let memory = memories[id] else { return false }
            return memory.active && MemorySearch.scopeAllows(memory.scope, requested: scope)
        }

        var visited = Set<String>()
        var results: [String: Float] = [:]
        var queue: [QueueItem] = []
        var cursor = 0

        for seed in seeds where isRetrievable(seed.id) {
            queue.append(.init(id: seed.id, score: seed.score, depth: 0))
            results[seed.id] = max(results[seed.id] ?? -.infinity, seed.score)
        }

        while cursor < queue.count {
            let item = queue[cursor]
            cursor += 1
            guard !visited.contains(item.id) else { continue }
            visited.insert(item.id)
            guard item.depth < maxDepth, isRetrievable(item.id) else { continue }

            for edge in outgoingEdges(from: item.id) {
                let target = edge.target
                guard !visited.contains(target) else { continue }
                let decay = powf(edgeDecay, Float(item.depth + 1))
                let newScore = item.score * edge.kind.traversalWeight * decay

                if target.hasPrefix("tag:") || target.hasPrefix("cluster:") {
                    for sourceID in incomingNodes(to: target) where isRetrievable(sourceID) && !visited.contains(sourceID) {
                        if newScore > (results[sourceID] ?? -.infinity) {
                            results[sourceID] = newScore
                            queue.append(.init(id: sourceID, score: newScore, depth: item.depth + 1))
                        }
                    }
                } else if isRetrievable(target), newScore > (results[target] ?? -.infinity) {
                    results[target] = newScore
                    queue.append(.init(id: target, score: newScore, depth: item.depth + 1))
                }
            }
        }

        return results
            .map { ScoredMemoryID(id: $0.key, score: $0.value) }
            .sorted {
                if $0.score == $1.score { return $0.id < $1.id }
                return $0.score > $1.score
            }
            .prefix(maxResults)
            .map { $0 }
    }

    public mutating func rebuildReverseEdges() {
        reverseEdges.removeAll(keepingCapacity: true)
        for (source, sourceEdges) in edges {
            for edge in sourceEdges {
                if reverseEdges[edge.target]?.contains(source) != true {
                    reverseEdges[edge.target, default: []].append(source)
                }
            }
        }
    }

    private mutating func ensureTag(_ name: String) {
        let id = "tag:\(name)"
        if tags[id] == nil { tags[id] = TagEntry(name: name) }
    }

    private mutating func addEdgeInternal(from: String, to: String, kind: EdgeKind) {
        edges[from, default: []].append(MemoryEdge(target: to, kind: kind))
        if reverseEdges[to]?.contains(from) != true {
            reverseEdges[to, default: []].append(from)
        }
    }

    private mutating func removeTagEdges(for entry: EngineMemoryEntry) {
        for tagName in entry.tags {
            let tagID = "tag:\(tagName)"
            removeEdge(from: entry.id, to: tagID, kind: .hasTag)
            if var tag = tags[tagID] {
                tag.count = tag.count > 0 ? tag.count - 1 : 0
                if tag.count == 0 { tags[tagID] = nil } else { tags[tagID] = tag }
            }
        }
    }
}
