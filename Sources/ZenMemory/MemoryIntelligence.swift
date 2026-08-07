import Foundation

public struct MemoryQueryPlan: Codable, Sendable, Equatable {
    public var shouldRecall: Bool
    public var queries: [String]
    public var tags: [String]
    public var entities: [String]
    public var intent: String?

    public init(
        shouldRecall: Bool = true,
        queries: [String] = [],
        tags: [String] = [],
        entities: [String] = [],
        intent: String? = nil
    ) {
        self.shouldRecall = shouldRecall
        self.queries = Self.uniqueNonEmpty(queries)
        self.tags = Self.uniqueNonEmpty(tags)
        self.entities = Self.uniqueNonEmpty(entities)
        self.intent = intent?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public static func direct(_ prompt: String) -> MemoryQueryPlan {
        let value = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return MemoryQueryPlan(shouldRecall: !value.isEmpty, queries: value.isEmpty ? [] : [value])
    }

    private static func uniqueNonEmpty(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { return nil }
            let key = value.lowercased()
            guard seen.insert(key).inserted else { return nil }
            return value
        }
    }
}

public protocol MemoryQueryAnalyzer: Sendable {
    func analyze(_ prompt: String) async throws -> MemoryQueryPlan
}

/// Zero-cost default analyzer. It treats the current prompt as the retrieval query.
/// Replace it with an LLM-backed analyzer when semantic query rewriting is useful.
public struct DirectMemoryQueryAnalyzer: MemoryQueryAnalyzer {
    public init() {}

    public func analyze(_ prompt: String) async throws -> MemoryQueryPlan {
        .direct(prompt)
    }
}

public protocol MemorySelector: Sendable {
    func select(
        context: String,
        candidates: [MemoryCandidate],
        limit: Int
    ) async throws -> [MemoryCandidate]
}

/// Dependency-free selector that keeps the highest-scoring candidates.
public struct TopScoreMemorySelector: MemorySelector {
    public var minimumScore: Float

    public init(minimumScore: Float = 0) {
        self.minimumScore = minimumScore
    }

    public func select(
        context: String,
        candidates: [MemoryCandidate],
        limit: Int
    ) async throws -> [MemoryCandidate] {
        guard limit > 0 else { return [] }
        return candidates
            .filter { $0.score >= minimumScore }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score { return lhs.memory.id < rhs.memory.id }
                return lhs.score > rhs.score
            }
            .prefix(limit)
            .map { $0 }
    }
}

public struct MemoryDraft: Codable, Sendable, Equatable {
    public var content: String
    public var category: MemoryCategory
    public var tags: [String]
    public var source: String?
    public var trust: TrustLevel
    public var scope: MemoryScope
    public var confidence: Float

    public init(
        content: String,
        category: MemoryCategory = .fact,
        tags: [String] = [],
        source: String? = nil,
        trust: TrustLevel = .medium,
        scope: MemoryScope = .project,
        confidence: Float = 1
    ) {
        self.content = content.trimmingCharacters(in: .whitespacesAndNewlines)
        self.category = category
        self.tags = tags
        self.source = source
        self.trust = trust
        self.scope = scope
        self.confidence = min(max(confidence, 0), 1)
    }
}

public protocol MemoryExtractor: Sendable {
    func extract(from context: String) async throws -> [MemoryDraft]
}

public struct NoopMemoryExtractor: MemoryExtractor {
    public init() {}
    public func extract(from context: String) async throws -> [MemoryDraft] { [] }
}

public struct MemoryRecallResult: Sendable, Equatable {
    public var plan: MemoryQueryPlan
    public var candidates: [MemoryCandidate]
    public var selected: [MemoryCandidate]

    public init(
        plan: MemoryQueryPlan,
        candidates: [MemoryCandidate],
        selected: [MemoryCandidate]
    ) {
        self.plan = plan
        self.candidates = candidates
        self.selected = selected
    }
}

public protocol MemoryContextFormatter: Sendable {
    func format(_ memories: [MemoryCandidate]) -> String
}

/// Formats selected memories as a compact block that can be inserted into an agent prompt.
public struct BulletMemoryContextFormatter: MemoryContextFormatter {
    public var heading: String
    public var includeScores: Bool

    public init(heading: String = "Relevant memory", includeScores: Bool = false) {
        self.heading = heading
        self.includeScores = includeScores
    }

    public func format(_ memories: [MemoryCandidate]) -> String {
        guard !memories.isEmpty else { return "" }
        let lines = memories.map { candidate in
            if includeScores {
                return "- [\(String(format: "%.3f", candidate.score))] \(candidate.memory.content)"
            }
            return "- \(candidate.memory.content)"
        }
        return ([heading + ":"] + lines).joined(separator: "\n")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
