//
//  MemoryCleanupTests.swift
//  ZenCODECoreTests
//
//  The pure cleanup planner, exercised on graphs built in memory.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct MemoryCleanupTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private static func date(daysAgo: Double) -> Date {
        now.addingTimeInterval(-daysAgo * 86_400)
    }

    private static func entry(
        _ id: String,
        category: EngineMemoryCategory = .fact,
        content: String? = nil,
        tags: [String] = [],
        daysAgo: Double,
        active: Bool = true,
        accessCount: UInt32 = 0,
        embeddingModel: String? = nil,
        embedding: [Float]? = nil
    ) -> EngineMemoryEntry {
        var entry = EngineMemoryEntry(
            id: id,
            category: category,
            content: content ?? "Entry \(id)",
            tags: tags,
            createdAt: date(daysAgo: daysAgo),
            embedding: embedding,
            embeddingModel: embeddingModel
        )
        entry.active = active
        entry.accessCount = accessCount
        return entry
    }

    private static func graph(_ entries: [EngineMemoryEntry]) -> MemoryGraph {
        var graph = MemoryGraph()
        for entry in entries {
            graph.addMemory(entry)
        }
        return graph
    }

    /// Every forward edge has its reverse entry and vice versa.
    private static func reverseEdgesAreConsistent(_ graph: MemoryGraph) -> Bool {
        var expected: [String: Set<String>] = [:]
        for (source, edges) in graph.edges {
            for edge in edges {
                expected[edge.target, default: []].insert(source)
            }
        }
        let actual = graph.reverseEdges.mapValues(Set.init)
        return expected == actual
    }

    // MARK: - Rule A

    @Test
    func removesOnlyArchivedEntriesOlderThanRetention() {
        let original = Self.graph([
            Self.entry("old-archived", tags: ["shared", "gone"], daysAgo: 40, active: false),
            Self.entry("new-archived", tags: ["shared"], daysAgo: 5, active: false),
            Self.entry("old-active", tags: ["shared"], daysAgo: 400),
        ])
        let (cleaned, report) = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(archivedRetentionDays: 30),
            now: Self.now,
            embeddingModel: nil
        )

        #expect(report.removedArchived.map(\.id) == ["old-archived"])
        #expect(report.archivedStale.isEmpty)
        #expect(report.totalEntries == 3)
        #expect(report.activeEntries == 1)
        #expect(report.archivedEntries == 2)
        #expect(Set(cleaned.memories.keys) == ["new-archived", "old-active"])
        // Removal keeps the graph consistent: the dropped entry's own tag is gone.
        #expect(cleaned.tags["tag:gone"] == nil)
        #expect(cleaned.tags["tag:shared"]?.count == 2)
        #expect(Self.reverseEdgesAreConsistent(cleaned))
    }

    @Test
    func zeroRetentionRemovesEveryArchivedEntry() {
        let original = Self.graph([
            Self.entry("a", daysAgo: 0, active: false),
            Self.entry("b", daysAgo: 1, active: false),
            Self.entry("c", daysAgo: 1),
        ])
        let (cleaned, report) = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(archivedRetentionDays: 0),
            now: Self.now,
            embeddingModel: nil
        )

        #expect(Set(report.removedArchived.map(\.id)) == ["a", "b"])
        #expect(Set(cleaned.memories.keys) == ["c"])
    }

    @Test
    func archivedAgeIsMeasuredFromTheLastChange() {
        var recentlyArchived = Self.entry("recent", daysAgo: 400, active: false)
        recentlyArchived.updatedAt = Self.date(daysAgo: 3)
        let (cleaned, report) = MemoryCleanup.plan(
            Self.graph([recentlyArchived]),
            policy: MemoryCleanupPolicy(archivedRetentionDays: 30),
            now: Self.now,
            embeddingModel: nil
        )

        #expect(report.isEmpty)
        #expect(cleaned.memories.keys.contains("recent"))
    }

    // MARK: - Rule B

    @Test
    func staleThresholdIsScaledByCategoryHalfLife() throws {
        // N = 100: fact/entity 100 d, preference 75 d, correction ~304.2 d.
        let original = Self.graph([
            Self.entry("pref-before", category: .preference, daysAgo: 74),
            Self.entry("pref-after", category: .preference, daysAgo: 76),
            Self.entry("fact-before", category: .fact, daysAgo: 99),
            Self.entry("fact-after", category: .fact, daysAgo: 101),
            Self.entry("correction-at-n", category: .correction, daysAgo: 101),
            Self.entry("correction-before", category: .correction, daysAgo: 300),
            Self.entry("correction-after", category: .correction, daysAgo: 305),
            Self.entry("custom-after", category: .custom("note"), daysAgo: 101),
        ])
        let (cleaned, report) = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(staleInactivityDays: 100),
            now: Self.now,
            embeddingModel: nil
        )

        #expect(Set(report.archivedStale.map(\.id)) == [
            "pref-after", "fact-after", "correction-after", "custom-after",
        ])
        for id in ["pref-before", "fact-before", "correction-at-n", "correction-before"] {
            #expect(try #require(cleaned.memories[id]).active)
        }
        for id in report.archivedStale.map(\.id) {
            let archived = try #require(cleaned.memories[id])
            #expect(!archived.active)
            #expect(archived.updatedAt == Self.now)
        }
        // Archiving keeps the entry, its tags and its edges.
        #expect(cleaned.memories.count == original.memories.count)
        #expect(report.removedArchived.isEmpty)
    }

    @Test
    func staleRuleSkipsRecalledAndSupersededEntries() throws {
        var recalled = Self.entry("recalled", daysAgo: 1_000)
        recalled.touch()
        var superseded = Self.entry("superseded", daysAgo: 1_000)
        superseded.supersededBy = "other"
        let original = Self.graph([
            recalled,
            superseded,
            Self.entry("never-recalled", daysAgo: 1_000),
            Self.entry("already-archived", daysAgo: 1_000, active: false),
        ])
        let (cleaned, report) = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(staleInactivityDays: 180),
            now: Self.now,
            embeddingModel: nil
        )

        #expect(report.archivedStale.map(\.id) == ["never-recalled"])
        #expect(try #require(cleaned.memories["recalled"]).active)
        #expect(try #require(cleaned.memories["superseded"]).active)
        #expect(try #require(cleaned.memories["already-archived"]).updatedAt
            == Self.date(daysAgo: 1_000))
    }

    @Test
    func staleDaysAreClampedToAtLeastOne() {
        #expect(MemoryCleanupPolicy(staleInactivityDays: 0).staleInactivityDays == 1)
        #expect(MemoryCleanupPolicy(staleInactivityDays: -5).staleInactivityDays == 1)
        #expect(MemoryCleanupPolicy(archivedRetentionDays: -3).archivedRetentionDays == 0)
        #expect(!MemoryCleanupPolicy().hasActiveRule)
        #expect(MemoryCleanupPolicy(graphHygiene: true).hasActiveRule)
    }

    @Test
    func entryArchivedByStaleRuleIsNotRemovedInTheSameRun() throws {
        let original = Self.graph([Self.entry("stale", daysAgo: 500)])
        let (cleaned, report) = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(
                archivedRetentionDays: 0,
                staleInactivityDays: 100,
                graphHygiene: true
            ),
            now: Self.now,
            embeddingModel: nil
        )

        #expect(report.archivedStale.map(\.id) == ["stale"])
        #expect(report.removedArchived.isEmpty)
        #expect(report.removedSuperseded.isEmpty)
        #expect(!(try #require(cleaned.memories["stale"]).active))
    }

    // MARK: - Rule C

    @Test
    func hygieneRemovesSupersededEntriesAndTheirEdges() {
        var original = Self.graph([
            Self.entry("older", tags: ["topic"], daysAgo: 2),
            Self.entry("newer", tags: ["topic"], daysAgo: 1),
        ])
        original.supersede(newerID: "newer", olderID: "older")
        #expect(original.memories["older"]?.supersededBy == "newer")

        let (cleaned, report) = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(graphHygiene: true),
            now: Self.now,
            embeddingModel: nil
        )

        #expect(report.removedSuperseded.map(\.id) == ["older"])
        #expect(Set(cleaned.memories.keys) == ["newer"])
        #expect(cleaned.edges["newer"]?.contains { $0.target == "older" } != true)
        #expect(cleaned.tags["tag:topic"]?.count == 1)
        #expect(Self.reverseEdgesAreConsistent(cleaned))
    }

    @Test
    func hygieneRemovesDanglingEdgesAndKeepsReverseEdgesConsistent() {
        var original = Self.graph([
            Self.entry("a", tags: ["t"], daysAgo: 1),
            Self.entry("b", daysAgo: 1),
        ])
        original.addEdge(from: "a", to: "b", kind: .relatesTo(weight: 0.5))
        // Dangling: unknown source, unknown memory target, unknown tag, unknown cluster.
        original.edges["ghost"] = [MemoryEdge(target: "a", kind: .relatesTo(weight: 0.4))]
        original.addEdge(from: "a", to: "missing", kind: .relatesTo(weight: 0.3))
        original.addEdge(from: "b", to: "tag:missing", kind: .hasTag)
        original.addEdge(from: "b", to: "cluster:missing", kind: .inCluster)
        original.rebuildReverseEdges()

        let (cleaned, report) = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(graphHygiene: true),
            now: Self.now,
            embeddingModel: nil
        )

        #expect(report.removedDanglingEdges == 4)
        #expect(cleaned.edges["ghost"] == nil)
        #expect(cleaned.edges["a"]?.map(\.target).sorted() == ["b", "tag:t"])
        #expect(cleaned.edges["b"] == nil)
        #expect(Self.reverseEdgesAreConsistent(cleaned))
        #expect(cleaned.reverseEdges["missing"] == nil)
        #expect(cleaned.reverseEdges["tag:missing"] == nil)
    }

    @Test
    func hygieneDropsEmptyTagsAndClustersAndRecountsTheRest() {
        var original = Self.graph([
            Self.entry("a", tags: ["used"], daysAgo: 1),
            Self.entry("b", tags: ["used"], daysAgo: 1, active: false),
        ])
        original.tags["tag:orphan"] = TagEntry(name: "orphan")
        original.tags["tag:used"]?.count = 9
        original.addCluster(ClusterEntry(id: "kept"))
        original.assign(memoryID: "a", toCluster: "kept")
        original.clusters["cluster:kept"]?.memberCount = 7
        original.addCluster(ClusterEntry(id: "empty"))
        // An edge into the orphan tag from a memory that does not carry it.
        original.addEdge(from: "a", to: "tag:orphan", kind: .hasTag)

        let (cleaned, report) = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(graphHygiene: true),
            now: Self.now,
            embeddingModel: nil
        )

        #expect(report.removedTags == 1)
        #expect(report.removedClusters == 1)
        #expect(report.removedDanglingEdges == 1)
        #expect(cleaned.tags["tag:orphan"] == nil)
        // Active and archived carriers both count.
        #expect(cleaned.tags["tag:used"]?.count == 2)
        #expect(cleaned.clusters["cluster:empty"] == nil)
        #expect(cleaned.clusters["cluster:kept"]?.memberCount == 1)
        #expect(Self.reverseEdgesAreConsistent(cleaned))
    }

    @Test
    func hygieneClearsVectorsFromOtherModelsOnly() throws {
        let original = Self.graph([
            Self.entry("match", daysAgo: 1, embeddingModel: "model-a", embedding: [1, 2]),
            Self.entry("other", daysAgo: 1, embeddingModel: "model-b", embedding: [3, 4]),
            Self.entry("unspecified", daysAgo: 1, embedding: [5, 6]),
            Self.entry("none", daysAgo: 1),
        ])
        let (cleaned, report) = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(graphHygiene: true),
            now: Self.now,
            embeddingModel: "model-a"
        )

        #expect(report.clearedEmbeddings == 2)
        let match = try #require(cleaned.memories["match"])
        #expect(match.embedding == [1, 2])
        #expect(match.embeddingModel == "model-a")
        for id in ["other", "unspecified"] {
            let cleared = try #require(cleaned.memories[id])
            #expect(cleared.embedding == nil)
            #expect(cleared.embeddingModel == nil)
            // Clearing a vector is not a content change.
            #expect(cleared.updatedAt == original.memories[id]?.updatedAt)
        }
        #expect(report.removedSuperseded.isEmpty)
    }

    @Test
    func hygieneClearsEveryVectorWithoutAProvider() {
        let original = Self.graph([
            Self.entry("a", daysAgo: 1, embeddingModel: "model-a", embedding: [1]),
            Self.entry("b", daysAgo: 1, embeddingModel: "model-b", embedding: [2]),
        ])
        let (cleaned, report) = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(graphHygiene: true),
            now: Self.now,
            embeddingModel: nil
        )

        #expect(report.clearedEmbeddings == 2)
        #expect(cleaned.memories.values.allSatisfy { $0.embedding == nil && $0.embeddingModel == nil })
    }

    @Test
    func vectorsAreLeftAloneWhenHygieneIsOff() {
        let original = Self.graph([
            Self.entry("a", daysAgo: 1, embeddingModel: "model-a", embedding: [1]),
        ])
        let (cleaned, report) = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(archivedRetentionDays: 30, staleInactivityDays: 180),
            now: Self.now,
            embeddingModel: nil
        )

        #expect(report.isEmpty)
        #expect(cleaned == original)
    }

    // MARK: - Report

    @Test
    func emptyReportMeansUnchangedGraph() {
        var original = Self.graph([
            Self.entry("a", tags: ["t"], daysAgo: 1, embeddingModel: "model-a", embedding: [1]),
            Self.entry("b", tags: ["t"], daysAgo: 2, accessCount: 3),
        ])
        // A tag count the recount would change on its own must not make an
        // otherwise empty plan look like a change.
        original.tags["tag:t"]?.count = 5
        let policy = MemoryCleanupPolicy(
            archivedRetentionDays: 30,
            staleInactivityDays: 180,
            graphHygiene: true
        )
        let (cleaned, report) = MemoryCleanup.plan(
            original,
            policy: policy,
            now: Self.now,
            embeddingModel: nil
        )
        // "b" has no vector and "a"'s is cleared (no provider), so this is not empty yet.
        #expect(report.clearedEmbeddings == 1)

        let (again, againReport) = MemoryCleanup.plan(
            cleaned,
            policy: policy,
            now: Self.now,
            embeddingModel: nil
        )
        #expect(againReport.isEmpty)
        #expect(again == cleaned)

        let (untouched, emptyReport) = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(archivedRetentionDays: 30, staleInactivityDays: 180),
            now: Self.now,
            embeddingModel: nil
        )
        #expect(emptyReport.isEmpty)
        #expect(untouched == original)

        // With a provider whose model matches the stored vector, hygiene would
        // only recount the tag: nothing counted, nothing changed.
        let (recountOnly, recountReport) = MemoryCleanup.plan(
            original,
            policy: policy,
            now: Self.now,
            embeddingModel: "model-a"
        )
        #expect(recountReport.isEmpty)
        #expect(recountOnly == original)
    }

    @Test
    func planIsPureAndLeavesTheInputUntouched() {
        let original = Self.graph([
            Self.entry("old", daysAgo: 100, active: false),
            Self.entry("stale", daysAgo: 400),
        ])
        let snapshot = original
        _ = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(
                archivedRetentionDays: 30,
                staleInactivityDays: 180,
                graphHygiene: true
            ),
            now: Self.now,
            embeddingModel: nil
        )
        #expect(original == snapshot)
    }

    @Test
    func summariesAreSortedByLastChangeThenIdWithTruncatedTitles() throws {
        let longTitle = String(repeating: "x", count: 200)
        let original = Self.graph([
            Self.entry("b", content: "Timestamp: 2026-01-01\nSecond", daysAgo: 60, active: false),
            Self.entry("a", content: "First", daysAgo: 60, active: false),
            Self.entry("c", content: longTitle, daysAgo: 90, active: false),
            Self.entry("d", content: "  \n ", daysAgo: 70, active: false),
        ])
        let (_, report) = MemoryCleanup.plan(
            original,
            policy: MemoryCleanupPolicy(archivedRetentionDays: 30),
            now: Self.now,
            embeddingModel: nil
        )

        #expect(report.removedArchived.map(\.id) == ["c", "d", "a", "b"])
        let byID = Dictionary(uniqueKeysWithValues: report.removedArchived.map { ($0.id, $0) })
        #expect(try #require(byID["c"]).title.count == 80)
        #expect(try #require(byID["d"]).title == "(untitled)")
        #expect(try #require(byID["b"]).title == "Second")
        #expect(try #require(byID["a"]).category == "fact")
        #expect(try #require(byID["a"]).lastChange == Self.date(daysAgo: 60))
    }
}
