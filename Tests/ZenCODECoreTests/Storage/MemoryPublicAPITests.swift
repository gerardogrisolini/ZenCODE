//
//  MemoryPublicAPITests.swift
//  ZenCODECoreTests
//
//  Verifies ZenCODECore's public memory DTOs and its async `MemoryService`
//  facade: `MemoryEntry` keeps `id: UUID` and decodes payloads written before
//  the graph era, the DTOs carry the engine's data, and a write reports
//  whether it created an entry or reused an equivalent one.
//

import Foundation
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing

@Suite
struct MemoryPublicAPITests {

    // MARK: - MemoryEntry DTO contract

    @Test
    func memoryEntryCodableRoundTrips() throws {
        let original = MemoryEntry(
            content: "Summary: codable round-trip.",
            category: .preference,
            tags: ["api", "compat"]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MemoryEntry.self, from: data)
        #expect(decoded.id == original.id)
        #expect(decoded.content == original.content)
        #expect(decoded.category == .preference)
        #expect(decoded.tags == ["api", "compat"])
    }

    @Test
    func memoryEntryCodableBackwardCompatibleWithLegacyPayload() throws {
        // Simulates a 1.1.x payload that only carried id, scope, content, isArchived.
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000002",
          "scope": "project",
          "content": "Summary: legacy entry.",
          "isArchived": false
        }
        """
        let decoded = try JSONDecoder().decode(MemoryEntry.self, from: Data(legacyJSON.utf8))
        #expect(decoded.id == UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        #expect(decoded.scope == .project)
        #expect(decoded.content == "Summary: legacy entry.")
        #expect(decoded.isArchived == false)
        // New fields receive safe defaults.
        #expect(decoded.category == .fact)
        #expect(decoded.tags.isEmpty)
        #expect(decoded.trust == "medium")
        #expect(decoded.confidence == 1.0)
    }

    // MARK: - MemoryScope / MemoryCategory contract

    @Test
    func memoryCategoryIsHashableAndCodable() throws {
        let categories: Set<MemoryCategory> = [.fact, .preference, .entity, .correction, .fact]
        #expect(categories.count == 4)

        let data = try JSONEncoder().encode(MemoryCategory.preference)
        let decoded = try JSONDecoder().decode(MemoryCategory.self, from: data)
        #expect(decoded == .preference)
    }

    // MARK: - DTO preserves engine data

    @Test
    func dtoConversionPreservesContentAndCategory() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let written = try await service.writeEntry(
                content: "Summary: facade preserves data.",
                target: .workspace(workspace.workspaceURL),
                category: .entity,
                tags: ["dto"]
            )
            #expect(written.category == .entity)
            #expect(written.tags == ["dto"])
            #expect(written.scope == .project)
            #expect(written.isArchived == false)

            let read = try await service.readEntries(
                target: .workspace(workspace.workspaceURL),
                limit: 5
            )
            #expect(read.count == 1)
            #expect(read.first?.content == written.content)
            #expect(read.first?.id == written.id)
        }
    }

    /// A read without a workspace throws, which is what the tool layer relies
    /// on to report a missing workspace instead of silently reading nothing.
    @Test
    func asyncReadWithNilWorkspaceThrows() async {
        let service = MemoryService()
        await #expect(throws: MemoryServiceError.self) {
            try await service.readEntries(target: nil, limit: 10)
        }
    }

    // MARK: - memory.write reports created vs deduplicated

    @Test
    func memoryWriteReportsCreatedThenDeduplicated() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let context = MemoryToolContext(graphTarget: .workspace(workspace.workspaceURL))
            let request = ToolRequest(
                name: "memory.write",
                arguments: ["content": .string("Summary: dedup contract.\nState: first write.")]
            )

            let first = try await MemoryTool.executeAsync(request, context: context)
            #expect(first.rawResult?.objectValue?["written"]?.boolValue == true)
            #expect(first.rawResult?.objectValue?["deduplicated"]?.boolValue == false)
            #expect(first.text.contains("Saved memory entry"))

            // Same content again: the store deduplicates, so the tool must not
            // claim a second write.
            let second = try await MemoryTool.executeAsync(request, context: context)
            #expect(second.rawResult?.objectValue?["written"]?.boolValue == false)
            #expect(second.rawResult?.objectValue?["deduplicated"]?.boolValue == true)
            #expect(second.text.contains("Duplicate"))
            #expect(!second.text.contains("Saved memory entry"))

            // The reused entry is the original one, so its id stays usable.
            let firstID = first.rawResult?.objectValue?["entry"]?.objectValue?["id"]?.stringValue
            let secondID = second.rawResult?.objectValue?["entry"]?.objectValue?["id"]?.stringValue
            #expect(firstID != nil)
            #expect(firstID == secondID)

            // And only one entry actually exists.
            let stored = try await MemoryService().readEntries(
                target: .workspace(workspace.workspaceURL),
                limit: 10
            )
            #expect(stored.count == 1)
        }
    }

    @Test
    func writeEntryOutcomePropagatesCreatedFlag() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let first = try await service.writeEntryOutcome(
                content: "Summary: outcome flag.",
                target: .workspace(workspace.workspaceURL)
            )
            #expect(first.created)
            #expect(first.deduplicated == false)

            let second = try await service.writeEntryOutcome(
                content: "Summary: outcome flag.",
                target: .workspace(workspace.workspaceURL)
            )
            #expect(second.created == false)
            #expect(second.deduplicated)
            #expect(second.entry.id == first.entry.id)

            // The public signature is unchanged and still yields the entry.
            let viaPublicAPI = try await service.writeEntry(
                content: "Summary: outcome flag.",
                target: .workspace(workspace.workspaceURL)
            )
            #expect(viaPublicAPI.id == first.entry.id)
        }
    }
}
