//
//  MemoryServiceTests+GraphTargets.swift
//  ZenCODE
//
//  Memory service tests for the global and workspace graph targets, recall
//  without an embedder, and the category, tags, and provenance of written
//  entries.
//

import Foundation
import ToolCore
@testable import ZenCODECore
import Testing

extension MemoryServiceTests {
    // MARK: - Graph targets

    @Test
    func globalTargetPersistsItsOwnGraphIsolatedFromTheWorkspace() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let globalURL = MemoryGraphLocation.graphURL(for: .global)
            let expectedGlobalURL = workspace.supportDirectoryURL
                .appendingPathComponent("memory", isDirectory: true)
                .appendingPathComponent("global", isDirectory: true)
                .appendingPathComponent("memory.graph.json", isDirectory: false)
            #expect(globalURL.standardizedFileURL.path == expectedGlobalURL.standardizedFileURL.path)
            #expect(globalURL == MemoryGraphLocation.globalGraphURL())
            #expect(globalURL != workspace.graphURL())
            #expect(workspace.graphURL().deletingLastPathComponent().lastPathComponent != MemoryGraphLocation.globalDirectoryName)
            #expect(MemoryGraphLocation.graphURL(for: .workspace(workspace.workspaceURL)) == workspace.graphURL())
            #expect(!FileManager.default.fileExists(atPath: globalURL.path))

            let globalOutcome = try await service.writeEntryOutcome(
                content: "Summary: the organizer keeps one machine-wide memory graph.",
                target: .global
            )
            #expect(globalOutcome.created)
            #expect(FileManager.default.fileExists(atPath: globalURL.path))
            let persisted = try String(contentsOf: globalURL, encoding: .utf8)
            #expect(persisted.contains("one machine-wide memory graph"))
            // The workspace graph was never created by a global write.
            #expect(!FileManager.default.fileExists(atPath: workspace.graphURL().path))

            let workspaceOutcome = try await service.writeEntryOutcome(
                content: "Summary: the workspace keeps its own project notes.",
                target: .workspace(workspace.workspaceURL)
            )
            #expect(workspaceOutcome.created)
            #expect(FileManager.default.fileExists(atPath: workspace.graphURL().path))

            let globalEntries = try await service.readEntries(
                target: .global,
                includeArchived: false,
                offset: 0,
                limit: 10,
                filter: .none
            )
            #expect(globalEntries.map(\.id) == [globalOutcome.entry.id])

            let workspaceEntries = try await service.readEntries(
                target: .workspace(workspace.workspaceURL),
                includeArchived: false,
                offset: 0,
                limit: 10,
                filter: .none
            )
            #expect(workspaceEntries.map(\.id) == [workspaceOutcome.entry.id])

            // Neither graph can resolve the other's entry.
            #expect(
                try await service.entry(id: globalOutcome.entry.id.uuidString, target: .workspace(workspace.workspaceURL)) == nil
            )
            #expect(
                try await service.entry(id: workspaceOutcome.entry.id.uuidString, target: .global) == nil
            )
            #expect(
                try await service.entry(id: globalOutcome.entry.id.uuidString, target: .global)?.id == globalOutcome.entry.id
            )
        }
    }

    @Test
    func targetVariantsCoverEveryOperationOnTheGlobalGraph() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let alpha = try await service.writeEntryOutcome(
                content: "Summary: alpha quokka finding.",
                target: .global,
                category: .fact,
                tags: ["alpha", "shared"]
            ).entry
            let beta = try await service.writeEntryOutcome(
                content: "Summary: beta quokka preference.",
                target: .global,
                category: .preference,
                tags: ["beta", "shared"]
            ).entry

            // Pagination and filters apply to the addressed graph.
            let shared = try await service.readEntries(
                target: .global,
                includeArchived: false,
                offset: 0,
                limit: 10,
                filter: MemoryEntryFilter(tags: ["shared"])
            )
            #expect(Set(shared.map(\.id)) == [alpha.id, beta.id])
            let secondPage = try await service.readEntries(
                target: .global,
                includeArchived: false,
                offset: 1,
                limit: 1,
                filter: MemoryEntryFilter(tags: ["shared"])
            )
            #expect(secondPage.count == 1)
            let onlyPreference = try await service.readEntries(
                target: .global,
                includeArchived: false,
                offset: 0,
                limit: 10,
                filter: MemoryEntryFilter(category: .preference)
            )
            #expect(onlyPreference.map(\.id) == [beta.id])

            let searched = try await service.searchEntries(
                query: "quokka",
                target: .global,
                includeArchived: false,
                limit: 10,
                filter: MemoryEntryFilter(tags: ["alpha"])
            )
            #expect(searched.map(\.id) == [alpha.id])

            // Update keeps the id and rewrites the content in place.
            let updated = try await service.updateEntry(
                id: alpha.id.uuidString,
                content: "Summary: alpha quokka finding, revised.",
                target: .global
            )
            #expect(updated.id == alpha.id)
            #expect(updated.content.contains("revised"))
            #expect(
                try await service.entry(id: alpha.id.uuidString, target: .global)?.content.contains("revised") == true
            )

            // Archive hides the entry from default reads; restore brings it back.
            let archived = try await service.setArchived(true, id: alpha.id.uuidString, target: .global)
            #expect(archived.isArchived)
            #expect(
                try await service.readEntries(
                    target: .global,
                    includeArchived: false,
                    offset: 0,
                    limit: 10,
                    filter: .none
                ).map(\.id) == [beta.id]
            )
            let restored = try await service.setArchived(false, id: alpha.id.uuidString, target: .global)
            #expect(!restored.isArchived)

            try await service.deleteEntry(id: beta.id.uuidString, target: .global)
            #expect(try await service.entry(id: beta.id.uuidString, target: .global) == nil)
            #expect(
                try await service.readEntries(
                    target: .global,
                    includeArchived: true,
                    offset: 0,
                    limit: 10,
                    filter: .none
                ).map(\.id) == [alpha.id]
            )
        }
    }

    @Test
    func missingTargetReportsScopeUnavailableForEveryOperation() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        await workspace.withIsolatedSupport {
            let service = MemoryService()
            let id = UUID().uuidString

            await #expect(throws: MemoryServiceError.self) {
                try await service.readEntries(
                    target: nil,
                    includeArchived: false,
                    offset: 0,
                    limit: 10,
                    filter: .none
                )
            }
            await #expect(throws: MemoryServiceError.self) {
                try await service.searchEntries(
                    query: "anything",
                    target: nil,
                    includeArchived: false,
                    limit: 10,
                    filter: .none
                )
            }
            await #expect(throws: MemoryServiceError.self) {
                try await service.entry(id: id, target: nil)
            }
            await #expect(throws: MemoryServiceError.self) {
                try await service.writeEntryOutcome(content: "Summary: x.", target: nil)
            }
            await #expect(throws: MemoryServiceError.self) {
                try await service.updateEntry(id: id, content: "Summary: x.", target: nil)
            }
            await #expect(throws: MemoryServiceError.self) {
                try await service.setArchived(true, id: id, target: nil)
            }
            await #expect(throws: MemoryServiceError.self) {
                try await service.deleteEntry(id: id, target: nil)
            }
            // The same `nil` resolution backs the `workspaceRootURL:` wrappers.
            await #expect(throws: MemoryServiceError.self) {
                try await service.readEntries(target: nil, limit: 10)
            }
            #expect(!FileManager.default.fileExists(atPath: MemoryGraphLocation.graphURL(for: .global).path))
        }
    }

    @Test
    func recallWorksWithNoEmbedderAndEntriesCarryNoVector() async throws {
        // Embeddings are opt-in: with no ZENCODE_MEMORY_EMBEDDING_* configured,
        // recall must fall back to pure BM25 and freshly written entries must
        // not store an embedding vector.
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            _ = try await service.writeEntry(
                content: "Summary: actors isolate mutable state.",
                target: .workspace(workspace.workspaceURL)
            )
            _ = try await service.writeEntry(
                content: "Summary: database migrations run at startup.",
                target: .workspace(workspace.workspaceURL)
            )

            let matches = try await service.searchEntries(
                query: "actors mutable state",
                target: .workspace(workspace.workspaceURL),
                limit: 10
            )
            #expect(matches.contains { $0.content.contains("actors") })

            let all = try await service.readEntries(
                target: .workspace(workspace.workspaceURL),
                limit: 10
            )
            #expect(all.allSatisfy { $0.embedding == nil && $0.embeddingModel == nil })
        }
    }

    @Test
    func writeRecordsCategoryTagsAndProvenance() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let entry = try await service.writeEntry(
                content: "Summary: prefer structured concurrency for new networking code.",
                target: .workspace(workspace.workspaceURL),
                category: .preference,
                tags: ["swift", "concurrency"]
            )

            #expect(entry.category == .preference)
            #expect(entry.tags == ["swift", "concurrency"])
            #expect(entry.trust == "medium")
            #expect(entry.source == "memory.write")
            #expect(entry.scope == .project)

            let read = try #require(
                try await service.entry(
                    id: entry.id.uuidString,
                    target: .workspace(workspace.workspaceURL)
                )
            )
            #expect(read.category == .preference)
            #expect(Set(read.tags) == ["swift", "concurrency"])
        }
    }
}
