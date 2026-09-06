//
//  MemoryMarkdownIgnoredTests.swift
//  ZenCODECoreTests
//
//  MEMORY.md is an unrelated workspace artifact, never a memory input.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite
struct MemoryMarkdownIgnoredTests {
    enum ColdOperation: CaseIterable, Sendable {
        case read, search, recall
    }

    @Test(arguments: [false, true], ColdOperation.allCases)
    func markdownIsIgnoredOnColdOpen(malformed: Bool, operation: ColdOperation) async throws {
        // Each operation gets its own UUID workspace and support directory:
        // read must not accidentally warm search or recall through the registry.
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        let markdownURL = workspace.workspaceURL.appendingPathComponent("MEMORY.md")
        let ignoredID = UUID()
        let ignoredContent = "Summary: markdownonlysentinel must never enter the graph."
        let document = malformed
            ? "# MEMORY.md\n\n## Active\n\n- [id: not-a-uuid \(ignoredContent)\n"
            : """
            # MEMORY.md

            ## Active

            - [id: \(ignoredID.uuidString)] Timestamp: 2026-08-01 09:00 UTC
              \(ignoredContent)
              State: unrelated workspace document.
              Next: leave unchanged.

            ## Archived

            - Summary: archivedmarkdownsentinel must also be ignored.
            """
        let originalBytes = Data(document.utf8)
        try originalBytes.write(to: markdownURL)
        let provider = MarkdownIgnoringTestEmbedder()

        try await workspace.withIsolatedSupport {
            try await MemoryEmbedding.withProvider(provider) {
                let service = MemoryService()
                let graphURL = workspace.graphURL()
                let query = "markdownonlysentinel"
                #expect(!FileManager.default.fileExists(atPath: graphURL.path))

                switch operation {
                case .read:
                    let entries = try await service.readEntries(
                        workspaceRootURL: workspace.workspaceURL,
                        includeArchived: true,
                        limit: 100
                    )
                    #expect(entries.isEmpty)
                case .search:
                    let entries = try await service.searchEntries(
                        query: query,
                        workspaceRootURL: workspace.workspaceURL,
                        includeArchived: true,
                        limit: 100
                    )
                    #expect(entries.isEmpty)
                case .recall:
                    let store = try await MemoryGraphStore.open(
                        graphURL: graphURL
                    )
                    try await store.saveGraph()
                    #expect(try await store.context(for: query).isEmpty)
                }

                // Query embedding is allowed; embedding document contents is not.
                #expect(provider.inputs.allSatisfy { $0 == query })
                #expect(try Data(contentsOf: markdownURL) == originalBytes)
                #expect(!FileManager.default.fileExists(atPath: graphURL.path))

                let written = try await service.writeEntry(
                    content: "Summary: JSON-only durable entry.",
                    workspaceRootURL: workspace.workspaceURL
                )
                let persisted = try await JSONMemoryPersistence(url: graphURL).load()
                #expect(persisted.memories.count == 1)
                #expect(persisted.memories[written.id.uuidString]?.content == written.content)
                #expect(written.id != ignoredID)
                #expect(provider.inputs.contains(written.content))
                #expect(!provider.inputs.contains { $0.contains(ignoredContent) })
                #expect(try Data(contentsOf: markdownURL) == originalBytes)

                let reopened = try await MemoryGraphStore.open(
                    graphURL: graphURL
                )
                let entries = try await reopened.entries(includeArchived: true, limit: 100)
                #expect(entries.map(\.id) == [written.id.uuidString])
                #expect(try Data(contentsOf: markdownURL) == originalBytes)
            }
        }
    }

    @Test(arguments: [false, true])
    func existingJSONRemainsAuthoritative(malformed: Bool) async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        let markdownURL = workspace.workspaceURL.appendingPathComponent("MEMORY.md")
        let document = malformed
            ? Data([0xff, 0xfe, 0x00, 0x80])
            : Data("# MEMORY.md\n\n## Active\n\n- Summary: markdownonlysentinel.\n".utf8)
        try document.write(to: markdownURL)
        let provider = MarkdownIgnoringTestEmbedder()

        try await workspace.withIsolatedSupport {
            let graphURL = workspace.graphURL()
            let id = UUID().uuidString
            var graph = MemoryGraph()
            graph.addMemory(EngineMemoryEntry(id: id, category: .fact, content: "JSON authoritative entry"))
            try await JSONMemoryPersistence(url: graphURL).save(graph)
            let graphBytes = try Data(contentsOf: graphURL)

            try await MemoryEmbedding.withProvider(provider) {
                let store = try await MemoryGraphStore.open(
                    graphURL: graphURL
                )
                #expect(try await store.entries(includeArchived: true, limit: 100).map(\.id) == [id])
                #expect(provider.inputs.isEmpty)
                #expect(try Data(contentsOf: graphURL) == graphBytes)
                #expect(try Data(contentsOf: markdownURL) == document)
            }
        }
    }
}

private final class MarkdownIgnoringTestEmbedder: EmbeddingProvider, Sendable {
    let dimensions = 2
    let modelID = "markdown-ignored-test"
    private let recordedInputs = Mutex<[String]>([])

    var inputs: [String] { recordedInputs.withLock { $0 } }

    func embed(_ text: String) async throws -> [Float] {
        recordedInputs.withLock { $0.append(text) }
        return [1, 0]
    }
}
