//
//  MemoryAuthorScopeTests.swift
//  ZenCODECoreTests
//
//  Memory ownership: every entry records the name of the profile that wrote
//  it and a profile sees and changes only its own entries. Entries without an
//  author belong to Developer in a project graph and stay visible to every
//  profile in the global graph. The first two tests characterize the graph
//  file: a graph without authors decodes and saves back unchanged, and an
//  author round-trips.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite
struct MemoryAuthorScopeTests {
    // MARK: - Fixtures

    /// A version-4 graph written before entries had an author.
    private static let authorlessGraphJSON = """
    {
      "graph_version": 4,
      "memories": {
        "mem_active": {
          "id": "mem_active",
          "category": "fact",
          "content": "Summary: written before authors existed.",
          "tags": ["legacy"],
          "search_text": "summary written before authors existed legacy",
          "created_at": "2026-08-07T12:00:00Z",
          "updated_at": "2026-08-07T12:00:00Z",
          "access_count": 1,
          "trust": "medium",
          "strength": 1,
          "active": true,
          "confidence": 0.75,
          "scope": "project"
        },
        "mem_archived": {
          "id": "mem_archived",
          "category": "preference",
          "content": "Summary: archived before authors existed.",
          "tags": [],
          "created_at": "2026-08-07T12:00:00Z",
          "updated_at": "2026-08-08T12:00:00Z",
          "access_count": 0,
          "trust": "high",
          "strength": 1,
          "active": false,
          "confidence": 1.0,
          "scope": "project"
        }
      },
      "tags": {
        "tag:legacy": {"id": "tag:legacy", "name": "legacy", "count": 1, "created_at": "2026-08-07T12:00:00Z"}
      },
      "clusters": {},
      "edges": {
        "mem_active": [{"target": "tag:legacy", "kind": "has_tag"}]
      },
      "reverse_edges": {"tag:legacy": ["mem_active"]},
      "metadata": {"retrieval_count": 0, "link_discovery_count": 0}
    }
    """

    private static let recallEnvironment = [
        MemoryAutomationSettings.environmentAutoRecallKey: "1",
        MemoryAutomationSettings.environmentRecallTimeoutKey: "5000",
    ]

    private static func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-author-scope-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Runs `body` with the support directory in a throwaway tree and no
    /// embedding provider, so recall and search are local BM25.
    private static func withIsolatedMemory(
        _ body: @escaping @Sendable (MemoryTestWorkspace) async throws -> Void
    ) async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            try await MemoryEmbedding.withProvider(nil) {
                try await body(workspace)
            }
        }
    }

    /// The automatic recall block of one turn, as the session runner asks for it.
    private static func recall(
        _ prompt: String,
        target: MemoryGraphTarget,
        author: String?
    ) async -> String? {
        await MemoryAutomationSettings.withEnvironment(recallEnvironment) {
            await MemoryTurnCoordinator(visibleWarning: { _ in }).memoryBlock(
                sessionID: "author-scope-\(UUID().uuidString)",
                graphTarget: target,
                prompt: prompt,
                author: author
            )
        }
    }

    /// One `memory.*` call, as the tool executor makes it for a profile.
    @discardableResult
    private static func tool(
        _ name: String,
        _ arguments: [String: JSONValue],
        target: MemoryGraphTarget,
        author: String?
    ) async throws -> ToolExecutionOutput {
        try await MemoryTool.executeAsync(
            ToolRequest(name: name, arguments: arguments),
            context: MemoryToolContext(graphTarget: target, author: author)
        )
    }

    // MARK: - Persistence

    @Test
    func aGraphWithoutAuthorsDecodesAndSavesBackUnchanged() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.graph.json")
        try Data(Self.authorlessGraphJSON.utf8).write(to: source)

        let loaded = try await JSONMemoryPersistence(url: source).load()
        #expect(loaded.memories.count == 2)
        #expect(loaded.memories.values.allSatisfy { $0.author == nil })

        let first = directory.appendingPathComponent("first.graph.json")
        try await JSONMemoryPersistence(url: first).save(loaded)
        let firstBytes = try Data(contentsOf: first)
        #expect(!String(decoding: firstBytes, as: UTF8.self).contains("\"author\""))
        #expect(try JSONMemoryPersistence.encodeGraph(loaded) == firstBytes)

        let reloaded = try await JSONMemoryPersistence(url: first).load()
        #expect(reloaded.memories == loaded.memories)
        let second = directory.appendingPathComponent("second.graph.json")
        try await JSONMemoryPersistence(url: second).save(reloaded)
        #expect(try Data(contentsOf: second) == firstBytes)
    }

    @Test
    func anAuthorRoundTripsThroughTheGraphFileAndTheEntryDTO() async throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("memory.graph.json")
        let createdAt = Date(timeIntervalSince1970: 1_780_000_000)
        var graph = MemoryGraph()
        graph.addMemory(EngineMemoryEntry(
            id: "mem_owned",
            category: .fact,
            content: "Summary: written by a profile.",
            createdAt: createdAt,
            author: "Promoter"
        ))
        graph.addMemory(EngineMemoryEntry(
            id: "mem_unowned",
            category: .fact,
            content: "Summary: written by no profile.",
            createdAt: createdAt
        ))

        try await JSONMemoryPersistence(url: file).save(graph)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let memories = try #require(json["memories"] as? [String: [String: Any]])
        #expect(memories["mem_owned"]?["author"] as? String == "Promoter")
        #expect(memories["mem_unowned"]?.keys.contains("author") == false)

        let loaded = try await JSONMemoryPersistence(url: file).load()
        #expect(loaded.memories["mem_owned"]?.author == "Promoter")
        #expect(loaded.memories["mem_unowned"]?.author == nil)
        #expect(MemoryEntry(try #require(loaded.memories["mem_owned"])).author == "Promoter")

        // The public DTO: additive, absent when `nil`, and a 1.1.x payload
        // still decodes.
        let dto = MemoryEntry(content: "Summary: a DTO with an author.", author: "Promoter")
        #expect(try JSONDecoder().decode(MemoryEntry.self, from: JSONEncoder().encode(dto)).author == "Promoter")
        let legacyPayload = #"{"id":"\#(UUID().uuidString)","scope":"project","content":"Summary: old.","isArchived":false}"#
        let legacy = try JSONDecoder().decode(MemoryEntry.self, from: Data(legacyPayload.utf8))
        #expect(legacy.author == nil)
        let reencoded = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        #expect(reencoded["author"] == nil)
    }

    // MARK: - The rule

    @Test
    func authorNamesCompareWithoutRegardToCaseOrSurroundingWhitespace() async throws {
        let project = MemoryGraphTarget.workspace(URL(fileURLWithPath: "/tmp/author-scope", isDirectory: true))
        let promoter = MemoryAuthorScope(profileName: "  Promoter ", graphTarget: project)
        #expect(promoter.author == "Promoter")
        #expect(MemoryAuthorScope(profileName: nil, graphTarget: project).author == "Developer")
        #expect(MemoryAuthorScope(profileName: "   ", graphTarget: project).author == "Developer")

        let shouting = EngineMemoryEntry(category: .fact, content: "Summary: x.", author: "PROMOTER")
        #expect(promoter.allows(shouting))
        #expect(MemoryAuthorScope(profileName: "promoter", graphTarget: project).allows(shouting))
        #expect(!MemoryAuthorScope(profileName: "Developer", graphTarget: project).allows(shouting))

        // No author, or a blank one, is the same thing.
        for unowned in [
            EngineMemoryEntry(category: .fact, content: "Summary: y."),
            EngineMemoryEntry(category: .fact, content: "Summary: z.", author: "  "),
        ] {
            #expect(MemoryAuthorScope(profileName: "DEVELOPER", graphTarget: project).allows(unowned))
            #expect(MemoryAuthorScope(profileName: nil, graphTarget: project).allows(unowned))
            #expect(!promoter.allows(unowned))
            #expect(MemoryAuthorScope(profileName: "Promoter", graphTarget: .global).allows(unowned))
        }

        // Through the service: written as one spelling, owned by every other.
        try await Self.withIsolatedMemory { workspace in
            let target = MemoryGraphTarget.workspace(workspace.workspaceURL)
            let service = MemoryService()
            let written = try await service.writeEntryOutcome(
                content: "Summary: the launch announcement goes out on Tuesday.",
                target: target,
                author: " Promoter "
            ).entry
            #expect(written.author == "Promoter")
            #expect(try await service.entry(id: written.id.uuidString, target: target, author: "promoter")?.id == written.id)
            let updated = try await service.updateEntry(
                id: written.id.uuidString,
                content: "Summary: the launch announcement goes out on Wednesday.",
                target: target,
                author: "PROMOTER"
            )
            #expect(updated.author == "Promoter")
            #expect(try await service.entry(id: written.id.uuidString, target: target, author: "Developer") == nil)
        }
    }

    @Test
    func retrievalStatisticsAndMaintenanceCoverOnlyTheVisibleEntries() async throws {
        var graph = MemoryGraph()
        for index in 0..<3 {
            graph.addMemory(EngineMemoryEntry(
                id: "dev-\(index)",
                category: .fact,
                content: "Summary: flange calibration note \(index).",
                author: "Developer"
            ))
        }
        graph.addMemory(EngineMemoryEntry(id: "pro-0", category: .fact, content: "Summary: flange launch alpha.", author: "Promoter"))
        graph.addMemory(EngineMemoryEntry(id: "pro-1", category: .fact, content: "Summary: flange launch beta.", author: "Promoter"))
        let engine = MemoryEngine(graph: graph)
        let promoter = MemoryAuthorScope(
            profileName: "Promoter",
            graphTarget: .workspace(URL(fileURLWithPath: "/tmp/author-scope", isDirectory: true))
        )

        let whole = try await engine.retrieveAndSelectDetailed("flange alpha", scope: .all)
        #expect(whole.lexicalScale.documentCount == 5)
        let visible = try await engine.retrieveAndSelectDetailed("flange alpha", scope: .all, visibility: promoter)
        #expect(visible.lexicalScale.documentCount == 2)
        #expect(Set(visible.candidates.map(\.memory.id)) == ["pro-0", "pro-1"])

        let recalled = try await engine.recallDetailed("flange alpha", visibility: promoter)
        #expect(!recalled.selected.isEmpty)
        #expect(recalled.selected.allSatisfy { $0.memory.id.hasPrefix("pro-") })
        let after = await engine.snapshot()
        for id in recalled.selected.map(\.memory.id) {
            #expect(after.memories[id]?.accessCount == 1)
        }
        for index in 0..<3 {
            #expect(after.memories["dev-\(index)"] == graph.memories["dev-\(index)"])
        }
    }

    // MARK: - Sessions and tools

    @Test
    func aProfileNeitherSeesNorChangesAnotherProfilesEntries() async throws {
        try await Self.withIsolatedMemory { workspace in
            let target = MemoryGraphTarget.workspace(workspace.workspaceURL)
            let service = MemoryService()
            let developers = try await service.writeEntryOutcome(
                content: "Summary: the quantum flange calibrates every frobnicator.",
                target: target,
                author: "Developer"
            ).entry
            let promoters = try await service.writeEntryOutcome(
                content: "Summary: the launch announcement goes out on Tuesday.",
                target: target,
                author: "Promoter"
            ).entry
            #expect(developers.author == "Developer")
            #expect(promoters.author == "Promoter")
            let developerID = developers.id.uuidString

            // Recall.
            let prompt = "how do I calibrate the frobnicator"
            let developerBlock = try #require(await Self.recall(prompt, target: target, author: "Developer"))
            #expect(developerBlock.contains(developerID))
            let promoterBlock = await Self.recall(prompt, target: target, author: "Promoter")
            #expect(promoterBlock?.contains(developerID) != true)

            // read, search and get.
            let read = try await Self.tool("memory.read", ["includeArchived": .bool(true)], target: target, author: "Promoter")
            #expect(read.text.contains(promoters.id.uuidString))
            #expect(!read.text.contains(developerID))
            let search = try await Self.tool("memory.search", ["query": .string("frobnicator flange")], target: target, author: "Promoter")
            #expect(!search.text.contains(developerID))
            #expect(try await service.searchEntries(query: "frobnicator", target: target, author: "Promoter", limit: 10).isEmpty)
            await #expect(throws: MemoryServiceError.self) {
                try await Self.tool("memory.get", ["id": .string(developerID)], target: target, author: "Promoter")
            }

            // update, archive, restore and delete: not found.
            await #expect(throws: MemoryServiceError.self) {
                try await Self.tool(
                    "memory.update",
                    ["id": .string(developerID), "content": .string("Summary: rewritten by another profile.")],
                    target: target,
                    author: "Promoter"
                )
            }
            await #expect(throws: MemoryServiceError.self) {
                try await Self.tool("memory.archive", ["id": .string(developerID)], target: target, author: "Promoter")
            }
            await #expect(throws: MemoryServiceError.self) {
                try await Self.tool("memory.restore", ["id": .string(developerID)], target: target, author: "Promoter")
            }
            await #expect(throws: MemoryServiceError.self) {
                try await service.deleteEntry(id: developerID, target: target, author: "Promoter")
            }

            // The owner still has it, untouched, and its tools show the author.
            let owned = try #require(try await service.entry(id: developerID, target: target, author: "Developer"))
            #expect(owned.content == developers.content)
            #expect(!owned.isArchived)
            let get = try await Self.tool("memory.get", ["id": .string(developerID)], target: target, author: "Developer")
            #expect(get.text.contains("Author: Developer"))
            guard case let .object(result)? = get.rawResult, case let .object(entry)? = result["entry"] else {
                Issue.record("memory.get returned no entry object")
                return
            }
            #expect(entry["author"] == .string("Developer"))
        }
    }

    @Test
    func anEntryWithoutAnAuthorBelongsToDeveloperInAProjectGraph() async throws {
        try await Self.withIsolatedMemory { workspace in
            let target = MemoryGraphTarget.workspace(workspace.workspaceURL)
            // Written as before authors existed: no scope, no author.
            let store = try await MemoryGraphStoreRegistry.shared.store(graphURL: workspace.graphURL())
            let legacy = try await store.writeDetailed(
                content: "Summary: the quantum flange calibrates every frobnicator.",
                category: .fact,
                tags: []
            ).entry
            #expect(legacy.author == nil)
            let id = legacy.id
            let service = MemoryService()
            let prompt = "how do I calibrate the frobnicator"

            // Developer and a session without a profile own it.
            for author in ["Developer", nil] as [String?] {
                #expect(try await service.entry(id: id, target: target, author: author)?.id.uuidString == id)
                #expect(try await service.readEntries(target: target, author: author, limit: 10).map(\.id.uuidString) == [id])
                #expect(await Self.recall(prompt, target: target, author: author)?.contains(id) == true)
            }

            // Promoter does not see it and cannot change it.
            #expect(try await service.entry(id: id, target: target, author: "Promoter") == nil)
            #expect(try await service.readEntries(target: target, author: "Promoter", limit: 10).isEmpty)
            #expect(await Self.recall(prompt, target: target, author: "Promoter") == nil)
            await #expect(throws: MemoryServiceError.self) {
                try await service.setArchived(true, id: id, target: target, author: "Promoter")
            }

            // Its owner updates it; the entry is not migrated: still no author.
            let updated = try await service.updateEntry(
                id: id,
                content: "Summary: the quantum flange calibrates every frobnicator twice.",
                target: target,
                author: "Developer"
            )
            #expect(updated.author == nil)
            #expect(try await service.entry(id: id, target: target, author: nil)?.content.contains("twice") == true)
        }
    }

    @Test
    func anEntryWithoutAnAuthorStaysVisibleToEveryProfileOfTheGlobalGraph() async throws {
        try await Self.withIsolatedMemory { _ in
            let store = try await MemoryGraphStoreRegistry.shared.store(graphURL: MemoryGraphLocation.globalGraphURL())
            let legacy = try await store.writeDetailed(
                content: "Summary: the machine-wide archive lives on the NAS.",
                category: .fact,
                tags: []
            ).entry
            let service = MemoryService()

            for organizer in ["Organizer", "Archivist"] {
                #expect(try await service.entry(id: legacy.id, target: .global, author: organizer)?.id.uuidString == legacy.id)
                #expect(try await service.searchEntries(query: "archive", target: .global, author: organizer, limit: 10)
                    .map(\.id.uuidString) == [legacy.id])
                #expect(await Self.recall("where does the machine-wide archive live", target: .global, author: organizer)?
                    .contains(legacy.id) == true)
            }

            // What an organizer writes there is its own.
            let written = try await service.writeEntryOutcome(
                content: "Summary: invoices are filed by quarter.",
                target: .global,
                author: "Organizer"
            ).entry
            #expect(written.author == "Organizer")
            #expect(try await service.entry(id: written.id.uuidString, target: .global, author: "Organizer") != nil)
            #expect(try await service.entry(id: written.id.uuidString, target: .global, author: "Archivist") == nil)
        }
    }

    @Test
    func theSameContentWrittenByTwoAuthorsMakesTwoEntries() async throws {
        try await Self.withIsolatedMemory { workspace in
            let target = MemoryGraphTarget.workspace(workspace.workspaceURL)
            let service = MemoryService()
            let content = "Summary: the release pipeline signs every artifact with the hardware key."
            let developers = try await service.writeEntryOutcome(
                content: content,
                target: target,
                author: "Developer",
                tags: ["release"]
            )
            let promoters = try await service.writeEntryOutcome(
                content: content,
                target: target,
                author: "Promoter",
                tags: ["release-pipeline"]
            )
            #expect(developers.created)
            #expect(promoters.created)
            #expect(developers.entry.id != promoters.entry.id)
            // Another author's identical entry is neither similar nor a source
            // of tag hints.
            #expect(promoters.similar.isEmpty)
            #expect(promoters.tagHints.isEmpty)

            // The same author's entry is a duplicate, and similar.
            let again = try await service.writeEntryOutcome(content: content, target: target, author: "Developer")
            #expect(!again.created)
            #expect(again.entry.id == developers.entry.id)
            let near = try await service.writeEntryOutcome(
                content: content + " Again.",
                target: target,
                author: "Developer",
                tags: ["release-pipeline"]
            )
            #expect(near.created)
            #expect(near.similar.map(\.entry.id) == [developers.entry.id])
            #expect(near.tagHints.map(\.tag) == ["release-pipeline"])
            #expect(near.tagHints.first?.existing.map(\.name) == ["release"])

            #expect(try await service.readEntries(target: target, author: "Promoter", limit: 10)
                .map(\.id) == [promoters.entry.id])
        }
    }

    @Test
    func theAutomaticWriterWorksAsTheSessionProfile() async throws {
        try await Self.withIsolatedMemory { workspace in
            let target = MemoryGraphTarget.workspace(workspace.workspaceURL)
            let content = "Summary: Widget indexes are one-based."
            let developers = try await MemoryService().writeEntryOutcome(
                content: content,
                target: target,
                author: "Developer"
            ).entry
            let store = try await MemoryGraphStoreRegistry.shared.store(graphURL: workspace.graphURL())

            // Promoter is shown none of Developer's notes, and the same fact is
            // not a duplicate of an entry it does not own.
            let promoter = MemoryAuthorScope(profileName: "Promoter", graphTarget: target)
            let promoterSnapshot = try #require(try await store.learningSnapshot(query: "Widget", visibility: promoter))
            #expect(promoterSnapshot.entries.isEmpty)
            #expect(promoterSnapshot.comparison.isEmpty)
            #expect(try await store.commitLearning(
                content: content,
                existingID: nil,
                snapshot: promoterSnapshot,
                permit: MemoryLearningPermit(),
                event: UUID()
            ))
            let promoterEntries = try await MemoryService().readEntries(target: target, author: "Promoter", limit: 10)
            #expect(promoterEntries.count == 1)
            #expect(promoterEntries.first?.author == "Promoter")
            #expect(promoterEntries.first?.id != developers.id)

            // Developer's writer sees only its own note and rejects the duplicate.
            let developer = MemoryAuthorScope(profileName: "Developer", graphTarget: target)
            let developerSnapshot = try #require(try await store.learningSnapshot(query: "Widget", visibility: developer))
            #expect(developerSnapshot.entries.map(\.id) == [developers.id.uuidString])
            let duplicateCommitted = try await store.commitLearning(
                content: content,
                existingID: nil,
                snapshot: developerSnapshot,
                permit: MemoryLearningPermit(),
                event: UUID()
            )
            #expect(!duplicateCommitted)
        }
    }
}
