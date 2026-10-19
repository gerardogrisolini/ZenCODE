//
//  MemoryToolSurfaceTests.swift
//  ZenCODECoreTests
//
//  Tool-surface additions: similar-entry hints on write, paging and filters
//  on read/search, memory.get, memory.restore, a refreshed `Updated:` line
//  on update, and titles that skip timestamp annotations.
//

import Foundation
import ToolCore
@testable import ZenCODECore
import Testing

@Suite
struct MemoryToolSurfaceTests {
    private static func execute(
        _ name: String,
        _ arguments: [String: JSONValue],
        in workspace: MemoryTestWorkspace,
        service: MemoryService
    ) async throws -> (text: String, result: [String: JSONValue]) {
        let output = try await MemoryTool.executeAsync(
            ToolRequest(name: name, arguments: arguments),
            context: MemoryToolContext(workingDirectory: workspace.workspaceURL),
            memoryService: service
        )
        guard case let .object(result)? = output.rawResult else {
            throw MemoryServiceError.missingField("rawResult")
        }
        return (output.text, result)
    }

    @Test
    func descriptorsExposeGetAsReadOnlyAndRestoreAsMutating() {
        #expect(MemoryTool.readOnlyToolDescriptors.map(\.name) == ["memory.read", "memory.search", "memory.get"])
        #expect(MemoryTool.mutatingToolDescriptors.map(\.name) == ["memory.write", "memory.update", "memory.archive", "memory.restore"])
        #expect(MemoryTool.isMemoryToolName("memory.get"))
        #expect(MemoryTool.isMemoryToolName("memory.restore"))
    }

    @Test
    func writeReportsSimilarActiveEntriesWithoutBlockingTheWrite() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let first = try await service.writeEntry(
                content: """
                Summary: prepared release v1.1.3 from 1.1.2, bumped ZenPackageMetadata, updated CHANGELOG and tagged.
                State: build and tests green, tag pushed, artifacts published.
                Next: announce the release.
                """,
                workspaceRootURL: workspace.workspaceURL
            )
            _ = try await service.writeEntry(
                content: "Summary: the Telegram transport keeps a single private owner chat.",
                workspaceRootURL: workspace.workspaceURL
            )

            let overlapping = try await Self.execute("memory.write", [
                "content": .string("""
                Summary: prepared release v1.1.4 from 1.1.3, bumped ZenPackageMetadata, updated CHANGELOG and tagged.
                State: build and tests green, tag pushed, artifacts published.
                Next: announce the release.
                """)
            ], in: workspace, service: service)
            #expect(overlapping.result["written"] == .bool(true))
            guard case let .array(similar)? = overlapping.result["similar"] else {
                Issue.record("Expected a similar array.")
                return
            }
            #expect(similar.count == 1)
            guard case let .object(hint)? = similar.first else {
                Issue.record("Expected a similar object.")
                return
            }
            #expect(hint["id"] == .string(first.id.uuidString))
            #expect(overlapping.text.contains("Similar active entries already exist"))
            #expect(overlapping.text.contains(first.id.uuidString))

            let unrelated = try await Self.execute("memory.write", [
                "content": .string("Summary: the Linux validation machine runs Swift 6.4.1 on arm64.")
            ], in: workspace, service: service)
            #expect(unrelated.result["similar"] == .array([]))
            #expect(!unrelated.text.contains("Similar active entries"))
        }
    }

    @Test
    func writeSuggestsExistingTagsRelatedToNewOnes() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            for index in 1...3 {
                _ = try await service.writeEntry(
                    content: "Summary: linux note \(index).",
                    workspaceRootURL: workspace.workspaceURL,
                    tags: ["linux"]
                )
            }
            _ = try await service.writeEntry(
                content: "Summary: validation note.",
                workspaceRootURL: workspace.workspaceURL,
                tags: ["validation"]
            )

            let written = try await Self.execute("memory.write", [
                "content": .string("Summary: the arm64 machine validated the build."),
                "tags": .array([.string("linux-validation"), .string("linux")])
            ], in: workspace, service: service)
            #expect(written.result["written"] == .bool(true))
            guard case let .array(hints)? = written.result["tagHints"] else {
                Issue.record("Expected tag hints.")
                return
            }
            // `linux` already exists and is reused: no hint. `linux-validation`
            // is new and shares words with two existing tags, most used first.
            #expect(hints.count == 1)
            guard case let .object(hint)? = hints.first,
                  case let .array(existing)? = hint["existing"] else {
                Issue.record("Expected one hint with existing tags.")
                return
            }
            #expect(hint["tag"] == .string("linux-validation"))
            let names = existing.compactMap { value -> String? in
                guard case let .object(item) = value, case let .string(name)? = item["name"] else { return nil }
                return name
            }
            #expect(names == ["linux", "validation"])
            #expect(written.text.contains("linux-validation is new; existing related tags: linux (4), validation (1)"))

            let plain = try await Self.execute("memory.write", [
                "content": .string("Summary: a note without tags."),
            ], in: workspace, service: service)
            #expect(plain.result["tagHints"] == .array([]))
            #expect(!plain.text.contains("Tag hints"))
        }
    }

    @Test
    func readPagesWithOffsetAndReportsWhetherMoreRemain() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            for index in 1...5 {
                _ = try await service.writeEntry(
                    content: "Summary: journal entry number \(index).",
                    workspaceRootURL: workspace.workspaceURL
                )
            }

            let firstPage = try await Self.execute("memory.read", [
                "limit": .number(2), "detail": .string("index")
            ], in: workspace, service: service)
            #expect(firstPage.result["count"] == .number(2))
            #expect(firstPage.result["offset"] == .number(0))
            #expect(firstPage.result["hasMore"] == .bool(true))
            #expect(firstPage.text.contains("offset 2"))

            let lastPage = try await Self.execute("memory.read", [
                "limit": .number(2), "offset": .number(4), "detail": .string("index")
            ], in: workspace, service: service)
            #expect(lastPage.result["count"] == .number(1))
            #expect(lastPage.result["hasMore"] == .bool(false))
            #expect(!lastPage.text.contains("More entries follow"))
        }
    }

    @Test
    func readAndSearchNarrowByTagsAndCategory() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let both = try await service.writeEntry(
                content: "Summary: memory note validated on linux.",
                workspaceRootURL: workspace.workspaceURL,
                tags: ["memory", "linux"]
            )
            let memoryOnly = try await service.writeEntry(
                content: "Summary: memory note about the graph.",
                workspaceRootURL: workspace.workspaceURL,
                tags: ["memory"]
            )
            let correction = try await service.writeEntry(
                content: "Summary: correction note about the graph.",
                workspaceRootURL: workspace.workspaceURL,
                category: .correction,
                tags: ["memory"]
            )

            let bothTags = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                includeArchived: false,
                offset: 0,
                limit: 10,
                filter: MemoryEntryFilter(tags: ["Memory", "LINUX"])
            )
            #expect(bothTags.map(\.id) == [both.id])

            let oneTag = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                includeArchived: false,
                offset: 0,
                limit: 10,
                filter: MemoryEntryFilter(tags: ["memory"])
            )
            #expect(Set(oneTag.map(\.id)) == [both.id, memoryOnly.id, correction.id])

            let corrections = try await Self.execute("memory.read", [
                "category": .string("correction")
            ], in: workspace, service: service)
            #expect(corrections.result["count"] == .number(1))

            let searched = try await Self.execute("memory.search", [
                "query": .string("note graph"),
                "tags": .array([.string("memory")]),
                "category": .string("fact")
            ], in: workspace, service: service)
            guard case let .array(entries)? = searched.result["entries"] else {
                Issue.record("Expected search entries.")
                return
            }
            let ids = entries.compactMap { value -> String? in
                guard case let .object(entry) = value, case let .string(id)? = entry["id"] else { return nil }
                return id
            }
            #expect(ids.contains(memoryOnly.id.uuidString))
            #expect(!ids.contains(correction.id.uuidString))
        }
    }

    @Test
    func getReturnsOneEntryEvenWhenArchivedAndRejectsUnknownIds() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let entry = try await service.writeEntry(
                content: """
                Summary: archived but still addressable.
                State: kept for the record.
                Next: none.
                """,
                workspaceRootURL: workspace.workspaceURL
            )
            _ = try await service.archiveEntry(id: entry.id.uuidString, workspaceRootURL: workspace.workspaceURL)

            let fetched = try await Self.execute("memory.get", [
                "id": .string(entry.id.uuidString)
            ], in: workspace, service: service)
            #expect(fetched.result["found"] == .bool(true))
            guard case let .object(payload)? = fetched.result["entry"] else {
                Issue.record("Expected an entry payload.")
                return
            }
            #expect(payload["archived"] == .bool(true))
            #expect(payload["content"] == .string(entry.content))
            #expect(fetched.text.contains("Archived: true"))

            await #expect(throws: MemoryServiceError.self) {
                _ = try await Self.execute("memory.get", [
                    "id": .string(UUID().uuidString)
                ], in: workspace, service: service)
            }
        }
    }

    @Test
    func restoreBringsAnArchivedEntryBackIntoReads() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let entry = try await service.writeEntry(
                content: "Summary: restorable fact.",
                workspaceRootURL: workspace.workspaceURL
            )
            _ = try await service.archiveEntry(id: entry.id.uuidString, workspaceRootURL: workspace.workspaceURL)
            #expect(try await service.readEntries(workspaceRootURL: workspace.workspaceURL, limit: 10).isEmpty)

            let restored = try await Self.execute("memory.restore", [
                "id": .string(entry.id.uuidString)
            ], in: workspace, service: service)
            #expect(restored.result["restored"] == .bool(true))
            #expect(restored.text.hasPrefix("Restored memory entry."))

            let active = try await service.readEntries(workspaceRootURL: workspace.workspaceURL, limit: 10)
            #expect(active.map(\.id) == [entry.id])
            #expect(active.first?.isArchived == false)
        }
    }

    @Test
    func updateRefreshesACarriedOverUpdatedLine() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
            let original = try await service.writeEntry(
                content: """
                Timestamp: 2026-08-01 09:00 Europe/Rome
                Updated: 2026-08-02 10:00 Europe/Rome
                Summary: state before the second update.
                """,
                workspaceRootURL: workspace.workspaceURL
            )
            let updateDate = try #require(DateComponents(
                calendar: Calendar(identifier: .gregorian),
                timeZone: timeZone,
                year: 2026, month: 8, day: 9, hour: 12, minute: 30
            ).date)

            // The model copies the old content, stale `Updated:` included.
            let updated = try await service.updateEntry(
                id: original.id.uuidString,
                content: """
                Timestamp: 2026-08-01 09:00 Europe/Rome
                Updated: 2026-08-02 10:00 Europe/Rome
                Summary: state after the second update.
                """,
                workspaceRootURL: workspace.workspaceURL,
                updatedAt: updateDate,
                timeZone: timeZone
            )
            #expect(updated.metadata.timestamp == "2026-08-01 09:00 Europe/Rome")
            #expect(updated.metadata.updated == "2026-08-09 12:30 Europe/Rome")
            let updatedLines = updated.content.components(separatedBy: "\n").filter { $0.hasPrefix("Updated:") }
            #expect(updatedLines.count == 1)
        }
    }

    @Test
    func titlesSkipTimestampAnnotationsWhenThereIsNoSummary() {
        let entry = MemoryEntry(content: """
        Timestamp: 2026-10-19 13:29 Europe/Rome
        Updated: 2026-10-19 14:01 Europe/Rome
        Fixed the flaky recall test on Linux.
        """)
        #expect(entry.title == "Fixed the flaky recall test on Linux.")

        let summarised = MemoryEntry(content: """
        Timestamp: 2026-10-19 13:29 Europe/Rome
        Summary: explicit summary wins.
        Fixed something else.
        """)
        #expect(summarised.title == "explicit summary wins.")

        let onlyTimestamps = MemoryEntry(content: "Timestamp: 2026-10-19 13:29 Europe/Rome")
        #expect(onlyTimestamps.title == "Memory")
    }
}
