//
//  MemorySearchLimitTests.swift
//  ZenCODECoreTests
//
//  `memory.search` returns ranked candidates up to the requested limit rather
//  than the automatic-recall selection, and ranks archived entries with the
//  same BM25 scoring as active ones.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct MemorySearchLimitTests {
    @Test
    func searchHonoursLimitsAboveTheRecallCap() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            for index in 0..<20 {
                _ = try await service.writeEntry(
                    content: "Summary: redis note \(index) about the cache layer.",
                    workspaceRootURL: workspace.workspaceURL
                )
            }

            let twenty = try await service.searchEntries(
                query: "redis cache",
                workspaceRootURL: workspace.workspaceURL,
                limit: 20
            )
            #expect(twenty.count == 20)

            let fifty = try await service.searchEntries(
                query: "redis cache",
                workspaceRootURL: workspace.workspaceURL,
                limit: 50
            )
            #expect(fifty.count == 20)

            let five = try await service.searchEntries(
                query: "redis cache",
                workspaceRootURL: workspace.workspaceURL,
                limit: 5
            )
            #expect(five.count == 5)
        }
    }

    @Test
    func searchRanksByRelevanceAndKeepsWeakerMatches() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let richer = try await service.writeEntry(
                content: "Summary: transport architecture for the swift server.",
                workspaceRootURL: workspace.workspaceURL
            )
            let weaker = try await service.writeEntry(
                content: "Summary: transport layer notes.",
                workspaceRootURL: workspace.workspaceURL
            )
            _ = try await service.writeEntry(
                content: "Summary: unrelated calendar reminder.",
                workspaceRootURL: workspace.workspaceURL
            )

            let matches = try await service.searchEntries(
                query: "transport architecture",
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(matches.map(\.id) == [richer.id, weaker.id])
        }
    }

    @Test
    func searchSurfacesGraphNeighboursAfterDirectHits() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let direct = try await service.writeEntry(
                content: "Summary: kafka consumer group tuning.",
                workspaceRootURL: workspace.workspaceURL,
                tags: ["streaming"]
            )
            let neighbour = try await service.writeEntry(
                content: "Summary: schema registry migration.",
                workspaceRootURL: workspace.workspaceURL,
                tags: ["streaming"]
            )
            _ = try await service.writeEntry(
                content: "Summary: unrelated calendar reminder.",
                workspaceRootURL: workspace.workspaceURL
            )

            // The neighbour shares no query term; it is reached through the
            // shared tag and ranked below the direct hit.
            let matches = try await service.searchEntries(
                query: "kafka consumer",
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(matches.map(\.id) == [direct.id, neighbour.id])
        }
    }

    @Test
    func archivedEntriesAreRankedByTheSameScoring() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let active = try await service.writeEntry(
                content: "Summary: redis cache layer.",
                workspaceRootURL: workspace.workspaceURL
            )
            let weakerArchived = try await service.writeEntry(
                content: "Summary: redis pubsub notes.",
                workspaceRootURL: workspace.workspaceURL
            )
            let richerArchived = try await service.writeEntry(
                content: "Summary: redis cluster failover runbook.",
                workspaceRootURL: workspace.workspaceURL
            )
            for entry in [weakerArchived, richerArchived] {
                _ = try await service.archiveEntry(
                    id: entry.id.uuidString,
                    workspaceRootURL: workspace.workspaceURL
                )
            }

            let matches = try await service.searchEntries(
                query: "redis cluster",
                workspaceRootURL: workspace.workspaceURL,
                includeArchived: true,
                limit: 10
            )
            #expect(matches.map(\.id) == [active.id, richerArchived.id, weakerArchived.id])
            #expect(matches.filter(\.isArchived).count == 2)

            let activeOnly = try await service.searchEntries(
                query: "redis cluster",
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(activeOnly.map(\.id) == [active.id])
        }
    }

    @Test
    func includeArchivedReservesHalfOfTheLimit() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            for index in 0..<4 {
                _ = try await service.writeEntry(
                    content: "Summary: active redis note \(index).",
                    workspaceRootURL: workspace.workspaceURL
                )
            }
            for index in 0..<4 {
                let entry = try await service.writeEntry(
                    content: "Summary: archived redis note \(index).",
                    workspaceRootURL: workspace.workspaceURL
                )
                _ = try await service.archiveEntry(
                    id: entry.id.uuidString,
                    workspaceRootURL: workspace.workspaceURL
                )
            }

            let matches = try await service.searchEntries(
                query: "redis",
                workspaceRootURL: workspace.workspaceURL,
                includeArchived: true,
                limit: 4
            )
            #expect(matches.count == 4)
            #expect(matches.filter { !$0.isArchived }.count == 2)
            #expect(matches.filter(\.isArchived).count == 2)
            // Active matches lead, archived ones follow.
            #expect(matches.prefix(2).allSatisfy { !$0.isArchived })
        }
    }

    @Test
    func largeLimitSearchLeavesTheGraphFileByteIdentical() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            _ = try await service.writeEntry(
                content: "Summary: postgres connection pooling.",
                workspaceRootURL: workspace.workspaceURL,
                tags: ["database"]
            )
            _ = try await service.writeEntry(
                content: "Summary: postgres index maintenance.",
                workspaceRootURL: workspace.workspaceURL,
                tags: ["database"]
            )
            let graphURL = workspace.graphURL()
            let before = try Data(contentsOf: graphURL)

            let matches = try await service.searchEntries(
                query: "postgres",
                workspaceRootURL: workspace.workspaceURL,
                includeArchived: true,
                limit: 50
            )
            #expect(matches.count == 2)
            #expect(try Data(contentsOf: graphURL) == before)
        }
    }
}
