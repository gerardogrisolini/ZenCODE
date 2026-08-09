import Foundation

let unspecifiedEmbeddingModel = "unspecified"

enum TrustLevel: String, Codable, Sendable, CaseIterable {
    case high
    case medium
    case low
}

enum EngineMemoryScope: String, Codable, Sendable, CaseIterable {
    case project
    case global
    case all

    public var includesProject: Bool { self == .project || self == .all }
    public var includesGlobal: Bool { self == .global || self == .all }
}

enum EngineMemoryCategory: Hashable, Sendable {
    case fact
    case preference
    case entity
    case correction
    case custom(String)

    public var rawValue: String {
        switch self {
        case .fact: "fact"
        case .preference: "preference"
        case .entity: "entity"
        case .correction: "correction"
        case .custom(let value): value
        }
    }
}

extension EngineMemoryCategory: Codable {
    private enum CustomKey: String, CodingKey { case custom }

    public init(from decoder: Decoder) throws {
        if let value = try? decoder.singleValueContainer().decode(String.self) {
            switch value {
            case "fact": self = .fact
            case "preference": self = .preference
            case "entity": self = .entity
            case "correction": self = .correction
            default: self = .custom(value)
            }
            return
        }
        let container = try decoder.container(keyedBy: CustomKey.self)
        self = .custom(try container.decode(String.self, forKey: .custom))
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .custom(let value):
            var container = encoder.container(keyedBy: CustomKey.self)
            try container.encode(value, forKey: .custom)
        default:
            var container = encoder.singleValueContainer()
            try container.encode(rawValue)
        }
    }
}

struct Reinforcement: Codable, Sendable, Equatable {
    public var sessionID: String
    public var messageIndex: Int
    public var timestamp: Date

    public init(sessionID: String, messageIndex: Int, timestamp: Date = Date()) {
        self.sessionID = sessionID
        self.messageIndex = messageIndex
        self.timestamp = timestamp
    }
}

struct EngineMemoryEntry: Codable, Sendable, Identifiable, Equatable {
    public var id: String
    public var category: EngineMemoryCategory
    public var content: String
    public var tags: [String]
    public var searchText: String
    public var createdAt: Date
    public var updatedAt: Date
    public var accessCount: UInt32
    public var source: String?
    public var trust: TrustLevel
    public var strength: UInt32
    public var active: Bool
    public var supersededBy: String?
    public var reinforcements: [Reinforcement]
    public var embedding: [Float]?
    public var embeddingModel: String?
    public var confidence: Float
    public var scope: EngineMemoryScope

    public init(
        id: String? = nil,
        category: EngineMemoryCategory,
        content: String,
        tags: [String] = [],
        source: String? = nil,
        trust: TrustLevel = .medium,
        scope: EngineMemoryScope = .project,
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        embedding: [Float]? = nil,
        embeddingModel: String? = nil,
        confidence: Float = 1.0
    ) {
        self.id = id ?? Self.makeID()
        self.category = category
        self.content = content
        self.tags = tags
        self.searchText = Self.normalizeSearchText(content: content, tags: tags)
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.accessCount = 0
        self.source = source
        self.trust = trust
        self.strength = 1
        self.active = true
        self.supersededBy = nil
        self.reinforcements = []
        self.embedding = embedding
        self.embeddingModel = embeddingModel
        self.confidence = min(max(confidence, 0), 1)
        self.scope = scope
    }

    public var effectiveEmbeddingModel: String {
        embeddingModel ?? unspecifiedEmbeddingModel
    }

    public func embeddingMatches(model: String) -> Bool {
        embedding != nil && effectiveEmbeddingModel == model
    }

    public mutating func refreshSearchText() {
        searchText = Self.normalizeSearchText(content: content, tags: tags)
    }

    public var searchableText: String {
        searchText.isEmpty ? Self.normalizeSearchText(content: content, tags: tags) : searchText
    }

    public func effectiveConfidence(at date: Date = Date()) -> Float {
        let ageDays = max(0, Float(date.timeIntervalSince(createdAt) / 86_400))
        let halfLife: Float = switch category {
        case .correction: 365
        case .preference: 90
        case .fact: 30
        case .entity: 60
        case .custom: 45
        }
        let decay = expf(-ageDays / halfLife * 0.693)
        let accessBoost = 1 + 0.1 * logf(Float(accessCount) + 1)
        return min(confidence * decay * accessBoost, 1)
    }

    public mutating func boostConfidence(by amount: Float) {
        confidence = min(confidence + amount, 1)
        accessCount &+= 1
        updatedAt = Date()
    }

    public mutating func decayConfidence(by amount: Float) {
        confidence = max(confidence - amount, 0)
    }

    public mutating func touch() {
        updatedAt = Date()
        accessCount &+= 1
    }

    public mutating func reinforce(sessionID: String, messageIndex: Int) {
        strength &+= 1
        updatedAt = Date()
        reinforcements.append(
            Reinforcement(sessionID: sessionID, messageIndex: messageIndex)
        )
    }

    public mutating func supersede(with newID: String) {
        active = false
        supersededBy = newID
    }

    public mutating func setEmbedding(_ values: [Float]?, model: String?) {
        embedding = values
        embeddingModel = model
    }

    public static func normalizeSearchText(content: String, tags: [String]) -> String {
        ([content] + tags)
            .joined(separator: " ")
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .joined(separator: " ")
    }

    private enum CodingKeys: String, CodingKey {
        case id, category, content, tags, searchText, createdAt, updatedAt, accessCount
        case source, trust, strength, active, supersededBy, reinforcements
        case embedding, embeddingModel, confidence, scope
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        category = try c.decode(EngineMemoryCategory.self, forKey: .category)
        content = try c.decode(String.self, forKey: .content)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        searchText = try c.decodeIfPresent(String.self, forKey: .searchText)
            ?? Self.normalizeSearchText(content: content, tags: tags)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        accessCount = try c.decodeIfPresent(UInt32.self, forKey: .accessCount) ?? 0
        source = try c.decodeIfPresent(String.self, forKey: .source)
        trust = try c.decodeIfPresent(TrustLevel.self, forKey: .trust) ?? .medium
        strength = try c.decodeIfPresent(UInt32.self, forKey: .strength) ?? 1
        active = try c.decodeIfPresent(Bool.self, forKey: .active) ?? true
        supersededBy = try c.decodeIfPresent(String.self, forKey: .supersededBy)
        reinforcements = try c.decodeIfPresent([Reinforcement].self, forKey: .reinforcements) ?? []
        embedding = try c.decodeIfPresent([Float].self, forKey: .embedding)
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel)
        confidence = try c.decodeIfPresent(Float.self, forKey: .confidence) ?? 1
        scope = try c.decodeIfPresent(EngineMemoryScope.self, forKey: .scope) ?? .project
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(category, forKey: .category)
        try c.encode(content, forKey: .content)
        try c.encode(tags, forKey: .tags)
        if !searchText.isEmpty { try c.encode(searchText, forKey: .searchText) }
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(accessCount, forKey: .accessCount)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(trust, forKey: .trust)
        try c.encode(strength, forKey: .strength)
        try c.encode(active, forKey: .active)
        try c.encodeIfPresent(supersededBy, forKey: .supersededBy)
        if !reinforcements.isEmpty { try c.encode(reinforcements, forKey: .reinforcements) }
        try c.encodeIfPresent(embedding, forKey: .embedding)
        try c.encodeIfPresent(embeddingModel, forKey: .embeddingModel)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(scope, forKey: .scope)
    }

    private static func makeID() -> String {
        let millis = Int64(Date().timeIntervalSince1970 * 1_000)
        return "mem_\(millis)_\(UUID().uuidString.lowercased())"
    }
}
