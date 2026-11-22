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
            context: MemoryToolContext(graphTarget: .workspace(workspace.workspaceURL)),
            memoryService: service
        )
        guard case let .object(result)? = output.rawResult else {
            throw MemoryServiceError.missingField("rawResult")
        }
        return (output.text, result)
    }

    private static func execute(
        _ name: String,
        _ arguments: [String: JSONValue],
        context: MemoryToolContext,
        service: MemoryService
    ) async throws -> (text: String, result: [String: JSONValue]) {
        let output = try await MemoryTool.executeAsync(
            ToolRequest(name: name, arguments: arguments),
            context: context,
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
                target: .workspace(workspace.workspaceURL)
            )
            _ = try await service.writeEntry(
                content: "Summary: the Telegram transport keeps a single private owner chat.",
                target: .workspace(workspace.workspaceURL)
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
    func readPagesWithOffsetAndReportsWhetherMoreRemain() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            for index in 1...5 {
                _ = try await service.writeEntry(
                    content: "Summary: journal entry number \(index).",
                    target: .workspace(workspace.workspaceURL)
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
                target: .workspace(workspace.workspaceURL),
                tags: ["memory", "linux"]
            )
            let memoryOnly = try await service.writeEntry(
                content: "Summary: memory note about the graph.",
                target: .workspace(workspace.workspaceURL),
                tags: ["memory"]
            )
            let correction = try await service.writeEntry(
                content: "Summary: correction note about the graph.",
                target: .workspace(workspace.workspaceURL),
                category: .correction,
                tags: ["memory"]
            )

            let bothTags = try await service.readEntries(
                target: .workspace(workspace.workspaceURL),
                includeArchived: false,
                offset: 0,
                limit: 10,
                filter: MemoryEntryFilter(tags: ["Memory", "LINUX"])
            )
            #expect(bothTags.map(\.id) == [both.id])

            let oneTag = try await service.readEntries(
                target: .workspace(workspace.workspaceURL),
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
                target: .workspace(workspace.workspaceURL)
            )
            _ = try await service.setArchived(true, id: entry.id.uuidString, target: .workspace(workspace.workspaceURL))

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
                target: .workspace(workspace.workspaceURL)
            )
            _ = try await service.setArchived(true, id: entry.id.uuidString, target: .workspace(workspace.workspaceURL))
            #expect(try await service.readEntries(target: .workspace(workspace.workspaceURL), limit: 10).isEmpty)

            let restored = try await Self.execute("memory.restore", [
                "id": .string(entry.id.uuidString)
            ], in: workspace, service: service)
            #expect(restored.result["restored"] == .bool(true))
            #expect(restored.text.hasPrefix("Restored memory entry."))

            let active = try await service.readEntries(target: .workspace(workspace.workspaceURL), limit: 10)
            #expect(active.map(\.id) == [entry.id])
            #expect(active.first?.isArchived == false)
        }
    }

    // MARK: - Stale-path notes on full renderings of a workspace graph

    private static let missingPathsNote =
        "Not found in the current checkout (verify before relying on this entry): "
        + "`Sources/Gone/Sensor.swift`, `Docs/removed.md`."

    /// A workspace whose checkout holds `Sources/Kept/Real.swift` and an empty
    /// `Docs`, so both anchor a relative path while `Sources/Gone/…` and
    /// `Docs/removed.md` are missing.
    private static func makeCheckout() throws -> MemoryTestWorkspace {
        let workspace = try MemoryTestWorkspace()
        let fileManager = FileManager.default
        let kept = workspace.workspaceURL.appendingPathComponent("Sources/Kept", isDirectory: true)
        try fileManager.createDirectory(at: kept, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: kept.appendingPathComponent("Real.swift"))
        try fileManager.createDirectory(
            at: workspace.workspaceURL.appendingPathComponent("Docs", isDirectory: true),
            withIntermediateDirectories: true
        )
        return workspace
    }

    @Test
    func fullReadSearchAndGetNoteCitedPathsMissingFromTheWorkspace() async throws {
        let workspace = try Self.makeCheckout()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let stale = try await service.writeEntry(
                content: """
                Summary: the zeta sensor lives in Sources/Gone/Sensor.swift:42.
                State: documented in Docs/removed.md, see also Sources/Kept/Real.swift.
                """,
                target: .workspace(workspace.workspaceURL)
            )
            let fresh = try await service.writeEntry(
                content: "Summary: the zeta sensor also reads Sources/Kept/Real.swift:7.",
                target: .workspace(workspace.workspaceURL)
            )
            // The note sits right after the content and before the `ID:` line.
            let staleRendering = "\(stale.content)\n\(Self.missingPathsNote)\nID: \(stale.id.uuidString)"
            let freshRendering = "\(fresh.content)\nID: \(fresh.id.uuidString)"

            let read = try await Self.execute("memory.read", [:], in: workspace, service: service)
            #expect(read.text.contains(staleRendering))
            #expect(read.text.contains(freshRendering))

            let searched = try await Self.execute("memory.search", [
                "query": .string("zeta sensor")
            ], in: workspace, service: service)
            #expect(searched.text.contains(staleRendering))
            #expect(searched.text.contains(freshRendering))
            #expect(searched.text.components(separatedBy: "Not found in the current checkout").count == 2)

            let fetched = try await Self.execute("memory.get", [
                "id": .string(stale.id.uuidString)
            ], in: workspace, service: service)
            #expect(fetched.text.contains(staleRendering))
            let fetchedFresh = try await Self.execute("memory.get", [
                "id": .string(fresh.id.uuidString)
            ], in: workspace, service: service)
            #expect(fetchedFresh.text.contains(freshRendering))
            #expect(!fetchedFresh.text.contains("Not found"))

            // The structured result carries the stored content, never the note.
            guard case let .object(payload)? = fetched.result["entry"] else {
                Issue.record("Expected an entry payload.")
                return
            }
            #expect(payload["content"] == .string(stale.content))
            guard case let .array(entries)? = searched.result["entries"] else {
                Issue.record("Expected search entries.")
                return
            }
            for case let .object(entry) in entries {
                guard case let .string(content)? = entry["content"] else {
                    Issue.record("Expected entry content.")
                    return
                }
                #expect(!content.contains("Not found"))
            }
        }
    }

    @Test
    func indexDetailAndMutatingToolsAddNoStalePathNote() async throws {
        let workspace = try Self.makeCheckout()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let stale = try await service.writeEntry(
                content: "Summary: the zeta sensor lives in Sources/Gone/Sensor.swift:42.",
                target: .workspace(workspace.workspaceURL)
            )

            let readIndex = try await Self.execute("memory.read", [
                "detail": .string("index")
            ], in: workspace, service: service)
            #expect(readIndex.text.contains(stale.id.uuidString))
            #expect(!readIndex.text.contains("Not found"))

            let searchIndex = try await Self.execute("memory.search", [
                "query": .string("zeta sensor"), "detail": .string("index")
            ], in: workspace, service: service)
            #expect(searchIndex.text.contains(stale.id.uuidString))
            #expect(!searchIndex.text.contains("Not found"))

            // Write, update, archive and restore render as before.
            let written = try await Self.execute("memory.write", [
                "content": .string("Summary: the omega probe lives in Sources/Gone/Probe.swift.")
            ], in: workspace, service: service)
            #expect(!written.text.contains("Not found"))
            let updated = try await Self.execute("memory.update", [
                "id": .string(stale.id.uuidString),
                "content": .string("Summary: the zeta sensor lives in Sources/Gone/Sensor.swift:43.")
            ], in: workspace, service: service)
            #expect(!updated.text.contains("Not found"))
            let archived = try await Self.execute("memory.archive", [
                "id": .string(stale.id.uuidString)
            ], in: workspace, service: service)
            #expect(!archived.text.contains("Not found"))
            let restored = try await Self.execute("memory.restore", [
                "id": .string(stale.id.uuidString)
            ], in: workspace, service: service)
            #expect(!restored.text.contains("Not found"))
        }
    }

    @Test
    func globalGraphRenderingsAddNoStalePathNote() async throws {
        let workspace = try Self.makeCheckout()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let entry = try await service.writeEntry(
                content: "Summary: the zeta sensor lives in Sources/Gone/Sensor.swift:42.",
                target: .global
            )
            let context = MemoryToolContext(graphTarget: .global)

            let fetched = try await Self.execute("memory.get", [
                "id": .string(entry.id.uuidString)
            ], context: context, service: service)
            #expect(fetched.text.contains(entry.id.uuidString))
            #expect(!fetched.text.contains("Not found"))

            let searched = try await Self.execute("memory.search", [
                "query": .string("zeta sensor")
            ], context: context, service: service)
            #expect(searched.text.contains(entry.id.uuidString))
            #expect(!searched.text.contains("Not found"))

            let read = try await Self.execute("memory.read", [:], context: context, service: service)
            #expect(read.text.contains(entry.id.uuidString))
            #expect(!read.text.contains("Not found"))
        }
    }
}
