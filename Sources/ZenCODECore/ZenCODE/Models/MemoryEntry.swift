//
//  MemoryEntry.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
//  Public DTO layer for ZenCODECore.
//
//  The durable store is the vendored ZenMemory graph, but ZenMemory is an
//  internal target (not a published product). These public types preserve the
//  ZenCODECore 1.1.x contract — `id: UUID`, `Hashable`, journal-shaped
//  `MemoryScope` — while the graph engine stays hidden behind the facade.
//  New capabilities (category, tags) are surfaced additively on the same DTO.
//

import Foundation
import ZenMemory

// MARK: - Content normalization (shared)

/// Content normalization shared by the journal parser, the tools and the store.
public enum MemoryContent {
    public static func normalized(_ content: String) -> String {
        let normalizedLineEndings = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalizedLineEndings
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[ \t]+"#,
                with: " ",
                options: .regularExpression
            )
    }
}

// MARK: - Collision-free engine references
//
// The `ZenMemory` module name is shadowed by its `ZenMemory` actor, so
// `ZenMemory.MemoryEntry` / `ZenMemory.MemoryScope` / `ZenMemory.MemoryCategory`
// cannot be written. ZenCODECore also declares its own public `MemoryEntry` /
// `MemoryScope` / `MemoryCategory`, so the unqualified names resolve to the
// DTOs. These internal aliases let the graph adapter and migration code refer
// to the engine types without ambiguity.

internal typealias GraphEntry = EngineMemoryEntry
internal typealias GraphScope = EngineMemoryScope
internal typealias GraphCategory = EngineMemoryCategory

// MARK: - Public DTOs

/// The scope of a durable memory entry, matching the pre-graph ZenCODECore
/// contract. Only `project` is surfaced publicly; the engine's richer
/// `.global` / `.all` scopes stay internal to the graph adapter.
public nonisolated enum MemoryScope: String, Codable, CaseIterable, Hashable, Sendable {
    case project
}

/// The category of a memory entry. ZenCODECore exposes the four concrete
/// categories the tool layer writes; the engine's `.custom(String)` case maps
/// to `.fact` at the DTO boundary.
public nonisolated enum MemoryCategory: String, Codable, CaseIterable, Hashable, Sendable {
    case fact
    case preference
    case entity
    case correction

    /// Converts the public DTO category to the engine's category.
    var engineCategory: GraphCategory {
        switch self {
        case .fact: .fact
        case .preference: .preference
        case .entity: .entity
        case .correction: .correction
        }
    }
}

/// A durable project memory entry.
///
/// This is the public ZenCODECore DTO. It carries the original journal-shaped
/// identity (`id: UUID`, `Hashable`) and the additive graph capabilities
/// (`category`, `tags`). The underlying ZenMemory graph node is never exposed.
public nonisolated struct MemoryEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public var scope: MemoryScope
    public var content: String
    public var isArchived: Bool
    public var category: MemoryCategory
    public var tags: [String]
    public var source: String?
    public var trust: String
    public var createdAt: Date
    public var updatedAt: Date
    public var confidence: Float
    public var accessCount: UInt32
    public var embedding: [Float]?
    public var embeddingModel: String?

    public init(
        content: String,
        scope: MemoryScope = .project,
        id: UUID = UUID(),
        isArchived: Bool = false,
        category: MemoryCategory = .fact,
        tags: [String] = [],
        source: String? = nil,
        trust: String = "medium",
        createdAt: Date = Date(),
        updatedAt: Date? = nil,
        confidence: Float = 1.0,
        accessCount: UInt32 = 0,
        embedding: [Float]? = nil,
        embeddingModel: String? = nil
    ) {
        self.id = id
        self.scope = scope
        self.content = MemoryContent.normalized(content)
        self.isArchived = isArchived
        self.category = category
        self.tags = tags
        self.source = source
        self.trust = trust
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.confidence = confidence
        self.accessCount = accessCount
        self.embedding = embedding
        self.embeddingModel = embeddingModel
    }

    public var title: String {
        let firstLine = metadata.summary
            ?? content
                .components(separatedBy: .newlines)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Memory"
        guard firstLine.count > 80 else {
            return firstLine.isEmpty ? "Memory" : firstLine
        }
        return String(firstLine.prefix(77)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }

    /// Structured metadata derived from the entry's journal-shaped content.
    var metadata: MemoryEntryMetadata {
        MemoryEntryMetadata(content: content)
    }

    /// Maps an engine graph node to the public DTO.
    init(_ engine: GraphEntry) {
        self.id = UUID(uuidString: engine.id) ?? UUID()
        self.scope = .project
        self.content = engine.content
        self.isArchived = !engine.active
        self.category = MemoryCategory(rawValue: engine.category.rawValue) ?? .fact
        self.tags = engine.tags
        self.source = engine.source
        self.trust = engine.trust.rawValue
        self.createdAt = engine.createdAt
        self.updatedAt = engine.updatedAt
        self.confidence = engine.confidence
        self.accessCount = engine.accessCount
        self.embedding = engine.embedding
        self.embeddingModel = engine.embeddingModel
    }
}

// MARK: - Backward-compatible Codable
//
// The original 1.1.x `MemoryEntry` payload carried only `id`, `scope`,
// `content`, and `isArchived`. Every field added by the graph era is decoded
// with `decodeIfPresent` and a safe default, so older persisted DTO payloads
// still decode without error.

extension MemoryEntry {
    private enum CodingKeys: String, CodingKey {
        case id, scope, content, isArchived, category, tags
        case source, trust, createdAt, updatedAt, confidence, accessCount
        case embedding, embeddingModel
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        scope = try c.decodeIfPresent(MemoryScope.self, forKey: .scope) ?? .project
        content = try c.decode(String.self, forKey: .content)
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        category = try c.decodeIfPresent(MemoryCategory.self, forKey: .category) ?? .fact
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source)
        trust = try c.decodeIfPresent(String.self, forKey: .trust) ?? "medium"
        let decodedCreated = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        createdAt = decodedCreated
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? decodedCreated
        confidence = try c.decodeIfPresent(Float.self, forKey: .confidence) ?? 1.0
        accessCount = try c.decodeIfPresent(UInt32.self, forKey: .accessCount) ?? 0
        embedding = try c.decodeIfPresent([Float].self, forKey: .embedding)
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(scope, forKey: .scope)
        try c.encode(content, forKey: .content)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encode(category, forKey: .category)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(trust, forKey: .trust)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(accessCount, forKey: .accessCount)
        try c.encodeIfPresent(embedding, forKey: .embedding)
        try c.encodeIfPresent(embeddingModel, forKey: .embeddingModel)
    }
}

// MARK: - Engine-type conveniences (internal)
//
// Journal-shaped presentation helpers for the engine type, used by the graph
// adapter and migration code. Extending through the `GraphEntry` alias works
// because it resolves to the engine's `MemoryEntry` struct.

extension GraphEntry {
    static func normalizedContent(_ content: String) -> String {
        MemoryContent.normalized(content)
    }

    /// ZenCODE archives entries by deactivating the graph node.
    var isArchived: Bool { !active }

    var presentationTitle: String {
        let firstLine = MemoryEntryMetadata(content: content).summary
            ?? content
                .components(separatedBy: .newlines)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Memory"
        guard firstLine.count > 80 else {
            return firstLine.isEmpty ? "Memory" : firstLine
        }
        return String(firstLine.prefix(77)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
