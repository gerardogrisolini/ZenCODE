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
}
