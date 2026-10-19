//
//  MemoryAgePolicyTests.swift
//  ZenCODECoreTests
//
//  Age discount of retrieval scores: measured from the last content change,
//  slow half-lives lifted onto a floor, applied per ranking before fusion and
//  to graph neighbours after the cascade; maintenance boosts without touching
//  timestamps and never decays rejected candidates.
//

import Foundation
import Testing
@testable import ZenCODECore

/// Fixed embedder whose vectors are the first component of the text: entries
/// and queries that share the same "topic" word embed identically.
private struct TopicEmbeddingProvider: EmbeddingProvider {
    let modelID = "topic-embedding"

    func embed(_ text: String) async throws -> [Float] {
        let topics = ["alpha", "beta", "gamma"]
        let lowered = text.lowercased()
        return topics.map { lowered.contains($0) ? 1 : 0 }
    }
}

@Suite
struct MemoryAgePolicyTests {
    private static func days(_ count: Double, before reference: Date) -> Date {
        reference.addingTimeInterval(-count * 86_400)
    }

    @Test
    func discountDecaysWithTheCategoryHalfLifeDownToTheFloor() {
        let policy = MemoryAgePolicy.default
        #expect(policy.discount(ageDays: 0, category: .fact) == 1)
        // One half-life: halfway between the floor and 1.
        let halfway = policy.floor + (1 - policy.floor) * 0.5
        #expect(abs(policy.discount(ageDays: 120, category: .fact) - halfway) < 0.01)
        #expect(abs(policy.discount(ageDays: 365, category: .correction) - halfway) < 0.01)
        #expect(abs(policy.discount(ageDays: 90, category: .preference) - halfway) < 0.01)
        // Far beyond the half-life the discount settles on the floor.
        #expect(abs(policy.discount(ageDays: 10_000, category: .fact) - policy.floor) < 0.001)
        // A negative age (clock skew) is treated as fresh.
        #expect(policy.discount(ageDays: -5, category: .entity) == 1)
    }

    @Test
    func freshnessFollowsTheLastContentChange() {
        let now = Date()
        let stale = EngineMemoryEntry(
            category: .fact,
            content: "created long ago and never maintained",
            createdAt: Self.days(200, before: now)
        )
        let maintained = EngineMemoryEntry(
            category: .fact,
            content: "created long ago but updated yesterday",
            createdAt: Self.days(200, before: now),
            updatedAt: Self.days(1, before: now)
        )
        let fresh = EngineMemoryEntry(category: .fact, content: "written today", createdAt: now)

        #expect(maintained.effectiveConfidence(at: now) > stale.effectiveConfidence(at: now))
        #expect(abs(maintained.effectiveConfidence(at: now) - fresh.effectiveConfidence(at: now)) < 0.01)
    }

    @Test
    func boostCountsAccessesWithoutChangingTheContentTimestamp() {
        let created = Date().addingTimeInterval(-50 * 86_400)
        var entry = EngineMemoryEntry(category: .fact, content: "boosted", createdAt: created)
        entry.boostConfidence(by: 0.02)
        entry.touch()
        #expect(entry.accessCount == 2)
        #expect(entry.updatedAt == created)
    }

    @Test
    func olderRelevantEntryOutranksFreshWeakMatch() async throws {
        let now = Date()
        let engine = MemoryEngine(selector: ScoreThresholdMemorySelector())
        // Two query terms matched, written 150 days ago.
        try await engine.insert(
            EngineMemoryEntry(
                id: "old-relevant",
                category: .fact,
                content: "transport architecture decision for the swift server",
                createdAt: Self.days(150, before: now)
            ),
            persist: false
        )
        // One query term matched, written today.
        try await engine.insert(
            EngineMemoryEntry(
                id: "fresh-weak",
                category: .fact,
                content: "transport notes",
                createdAt: now
            ),
            persist: false
        )

        let result = try await engine.searchReadOnlyDetailed("transport architecture")
        #expect(result.candidates.first?.memory.id == "old-relevant")
    }

    @Test
    func weightIsAppliedBeforeReciprocalRankFusion() async throws {
        // With an embedder two rankings are fused by rank. Applying the age
        // weight after fusion would act on near-flat rank scores and sort by
        // age alone; applied before, an entry that leads both lists on
        // relevance keeps the top rank unless freshness reorders a list.
        let now = Date()
        let engine = MemoryEngine(
            embedder: TopicEmbeddingProvider(),
            selector: ScoreThresholdMemorySelector()
        )
        // Leads both the lexical and the semantic list, 100 days old.
        try await engine.insert(
            EngineMemoryEntry(
                id: "leader",
                category: .fact,
                content: "alpha alpha alpha alignment",
                createdAt: Self.days(100, before: now),
                embedding: [1, 0, 0],
                embeddingModel: "topic-embedding"
            ),
            persist: false
        )
        // Fresh, present in both lists but behind the leader on relevance.
        try await engine.insert(
            EngineMemoryEntry(
                id: "runner-up",
                category: .fact,
                content: "alpha alignment with beta details and gamma notes",
                createdAt: now,
                embedding: [1, 1, 1],
                embeddingModel: "topic-embedding"
            ),
            persist: false
        )

        let result = try await engine.searchReadOnlyDetailed("alpha alignment")
        #expect(result.candidates.map(\.memory.id).prefix(2) == ["leader", "runner-up"])
    }

    @Test
    func graphNeighboursCarryTheirOwnWeight() async throws {
        let now = Date()
        let engine = MemoryEngine(selector: ScoreThresholdMemorySelector())
        try await engine.insert(
            EngineMemoryEntry(
                id: "hit",
                category: .fact,
                content: "kafka consumer group tuning",
                tags: ["streaming"],
                createdAt: now
            ),
            persist: false
        )
        // Two neighbours reachable only through the shared tag; same text,
        // different ages.
        try await engine.insert(
            EngineMemoryEntry(
                id: "fresh-neighbour",
                category: .fact,
                content: "schema registry migration",
                tags: ["streaming"],
                createdAt: now
            ),
            persist: false
        )
        try await engine.insert(
            EngineMemoryEntry(
                id: "old-neighbour",
                category: .fact,
                content: "schema registry rollout",
                tags: ["streaming"],
                createdAt: Self.days(300, before: now)
            ),
            persist: false
        )

        let result = try await engine.searchReadOnlyDetailed("kafka consumer")
        let ids = result.candidates.map(\.memory.id)
        #expect(ids.first == "hit")
        let freshIndex = try #require(ids.firstIndex(of: "fresh-neighbour"))
        let oldIndex = try #require(ids.firstIndex(of: "old-neighbour"))
        #expect(freshIndex < oldIndex)
        // The hit keeps its seed score; the neighbours inherit a decayed share
        // of it, discounted by their own age.
        let hitScore = try #require(result.candidates.first?.score)
        let oldScore = try #require(result.candidates.first { $0.memory.id == "old-neighbour" }?.score)
        #expect(oldScore < hitScore)
    }

    @Test
    func rejectedCandidatesAreNotDecayedByDefault() async throws {
        let engine = MemoryEngine(selector: ScoreThresholdMemorySelector())
        #expect(MemoryEngineConfiguration().decayRejectedBy == 0)
        try await engine.insert(
            EngineMemoryEntry(id: "strong", category: .fact, content: "transport architecture for the swift server"),
            persist: false
        )
        try await engine.insert(
            EngineMemoryEntry(id: "weak", category: .fact, content: "transport layer notes"),
            persist: false
        )

        _ = try await engine.recall("transport architecture")

        let graph = await engine.snapshot()
        let strong = try #require(graph.memories["strong"])
        let weak = try #require(graph.memories["weak"])
        #expect(strong.accessCount == 1)
        #expect(weak.accessCount == 0)
        #expect(weak.confidence == 1)
    }
}
