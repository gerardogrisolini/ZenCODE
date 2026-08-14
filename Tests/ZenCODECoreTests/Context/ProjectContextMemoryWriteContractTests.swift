//
//  ProjectContextMemoryWriteContractTests.swift
//  ZenCODECoreTests
//
//  MEMORY.md is a legacy journal: the graph store imports it read-only, exactly
//  once, and durable memory then lives in the engine graph. The generic context
//  file service still exposes the 1.1.x writing entry points, so these tests pin
//  the contract that none of them may create or overwrite the journal — while
//  the read path, and the `AGENTS.md` kind, keep working unchanged.
//

import Foundation
import Testing
import ZenCODECore

@Suite
struct ProjectContextMemoryWriteContractTests {
    private func makeWorkspace() throws -> URL {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-write-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        return rootURL
    }

    private var journal: String {
        """
        # MEMORY.md

        ## Active

        - Timestamp: 2024-01-01 09:00 Europe/Rome
          Summary: hand written journal entry.
        """
    }

    @Test
    func memoryKindIsDeclaredReadOnly() {
        #expect(ProjectContextFileKind.memory.supportsDocumentWrites == false)
        #expect(ProjectContextFileKind.agents.supportsDocumentWrites == true)
    }

    @Test
    func createDefaultDocumentDoesNotCreateMissingMemoryJournal() throws {
        let rootURL = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent(MemoryService.filename)

        #expect(throws: CocoaError.self) {
            _ = try ProjectContextFileService().createDefaultDocument(
                kind: .memory,
                at: rootURL,
                projectName: "Sample"
            )
        }
        // The refusal must happen before any file system effect.
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test
    func createDefaultDocumentReturnsExistingMemoryJournalReadOnly() throws {
        let rootURL = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent(MemoryService.filename)
        try Data(journal.utf8).write(to: fileURL)
        let before = try Data(contentsOf: fileURL)

        let document = try ProjectContextFileService().createDefaultDocument(
            kind: .memory,
            at: rootURL,
            projectName: "Ignored"
        )

        #expect(document.content.contains("hand written journal entry"))
        #expect(try Data(contentsOf: fileURL) == before)
    }

    @Test
    func regenerateDefaultDocumentLeavesAnExistingJournalByteIdentical() throws {
        let rootURL = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent(MemoryService.filename)
        try Data(journal.utf8).write(to: fileURL)
        let before = try Data(contentsOf: fileURL)

        #expect(throws: CocoaError.self) {
            _ = try ProjectContextFileService().regenerateDefaultDocument(
                kind: .memory,
                at: rootURL,
                projectName: "Sample"
            )
        }
        #expect(try Data(contentsOf: fileURL) == before)
    }

    @Test
    func materializeDocumentCannotOverwriteTheJournal() throws {
        let rootURL = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let fileURL = rootURL.appendingPathComponent(MemoryService.filename)
        try Data(journal.utf8).write(to: fileURL)
        let before = try Data(contentsOf: fileURL)

        #expect(throws: CocoaError.self) {
            _ = try ProjectContextFileService().materializeDocument(
                kind: .memory,
                content: "# MEMORY.md\n\nreplaced",
                at: rootURL
            )
        }
        #expect(try Data(contentsOf: fileURL) == before)
    }

    /// The supported direction is still supported: reading an existing journal
    /// is what feeds the one-time import into the graph.
    @Test
    func readingAnExistingJournalStillWorks() throws {
        let rootURL = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try Data(journal.utf8).write(to: rootURL.appendingPathComponent(MemoryService.filename))

        let document = try #require(
            ProjectContextFileService().document(kind: .memory, at: rootURL)
        )
        #expect(document.content.contains("hand written journal entry"))
        #expect(document.fileURL.lastPathComponent == MemoryService.filename)
    }

    /// Control: the writable kind is unaffected by the guard.
    @Test
    func agentsDocumentsAreStillWritable() throws {
        let rootURL = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let service = ProjectContextFileService()

        let created = try service.createDefaultDocument(
            kind: .agents,
            at: rootURL,
            projectName: "Sample"
        )
        #expect(created.content == "# AGENTS.md")

        let materialized = try service.materializeDocument(
            kind: .agents,
            content: "# AGENTS.md\n\n## Build\n\nswift build",
            at: rootURL
        )
        #expect(materialized.content.contains("swift build"))

        let regenerated = try service.regenerateDefaultDocument(
            kind: .agents,
            at: rootURL,
            projectName: "Sample"
        )
        #expect(regenerated.content == "# AGENTS.md")
    }
}
