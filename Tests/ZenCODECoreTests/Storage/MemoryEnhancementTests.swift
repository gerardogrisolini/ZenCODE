//
//  MemoryEnhancementTests.swift
//  ZenCODE
//

import Foundation
import ToolCore
@testable import ZenCODECore
import Testing

@Suite
struct MemoryEnhancementTests {
    @Test
    func metadataIsDerivedWithoutChangingEntryContent() {
        let content = """
        Timestamp: 2026-08-02 10:15 Europe/Rome
        Updated: 2026-08-03 11:20 Europe/Rome
        Summary: compact memory metadata.
        State: the Markdown entry remains the durable source.
        Next: query it only when relevant.
        """

        let entry = MemoryEntry(content: content)
        let metadata = entry.metadata

        #expect(entry.content == content)
        #expect(entry.title == "compact memory metadata.")
        #expect(metadata.timestamp == "2026-08-02 10:15 Europe/Rome")
        #expect(metadata.updated == "2026-08-03 11:20 Europe/Rome")
        #expect(metadata.summary == "compact memory metadata.")
        #expect(metadata.state == "the Markdown entry remains the durable source.")
        #expect(metadata.next == "query it only when relevant.")
    }

    @Test
    func memoryUpdatePreservesIdentityAndOriginalTimestamp() throws {
        let fixture = try TemporaryMemoryWorkspace()
        defer { fixture.remove() }
        let service = MemoryService()
        let original = try service.writeEntry(
            content: """
            Timestamp: 2026-08-01 09:00 Europe/Rome
            Summary: original transport decision.
            State: the first implementation is active.
            Next: validate it.
            """,
            scope: .project,
            workspaceRootURL: fixture.workspaceURL
        )
        let timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
        let updateDate = try #require(DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: timeZone,
            year: 2026,
            month: 8,
            day: 4,
            hour: 16,
            minute: 45
        ).date)

        let output = try MemoryTool.execute(
            ToolRequest(
                name: "memory.update",
                arguments: [
                    "id": .string(original.id.uuidString),
                    "content": .string("""
                    Summary: updated transport decision.
                    State: the validated implementation is active.
                    Next: monitor the release.
                    """)
                ]
            ),
            context: MemoryToolContext(
                workingDirectory: fixture.workspaceURL,
                currentDate: updateDate,
                currentTimeZone: timeZone
            ),
            memoryService: service
        )
        let entries = try service.readEntriesChecked(
            scope: .project,
            workspaceRootURL: fixture.workspaceURL,
            limit: 10
        )
        let updated = try #require(entries.first)

        #expect(entries.count == 1)
        #expect(updated.id == original.id)
        #expect(updated.metadata.timestamp == "2026-08-01 09:00 Europe/Rome")
        #expect(updated.metadata.updated == "2026-08-04 16:45 Europe/Rome")
        #expect(updated.metadata.summary == "updated transport decision.")
        guard case let .object(result)? = output.rawResult else {
            Issue.record("Expected a JSON result from memory.update.")
            return
        }
        #expect(result["updated"] == .bool(true))
    }

    @Test
    func memoryUpdatePreservesArchivedState() throws {
        let fixture = try TemporaryMemoryWorkspace()
        defer { fixture.remove() }
        let service = MemoryService()
        let entry = try service.writeEntry(
            content: """
            Timestamp: 2026-08-01 09:00 Europe/Rome
            Summary: archived project state.
            State: retained for history.
            Next: keep it archived.
            """,
            scope: .project,
            workspaceRootURL: fixture.workspaceURL
        )
        _ = try service.archiveEntry(
            id: entry.id.uuidString,
            scope: .project,
            workspaceRootURL: fixture.workspaceURL
        )

        _ = try service.updateEntry(
            id: entry.id,
            content: """
            Summary: corrected archived project state.
            State: still retained only for history.
            Next: keep it archived.
            """,
            scope: .project,
            workspaceRootURL: fixture.workspaceURL
        )
        let all = try service.readEntriesChecked(
            scope: .project,
            workspaceRootURL: fixture.workspaceURL,
            includeArchived: true,
            limit: 10
        )

        #expect(all.first?.id == entry.id)
        #expect(all.first?.isArchived == true)
        #expect(all.first?.metadata.summary == "corrected archived project state.")
        #expect(try service.readEntriesChecked(
            scope: .project,
            workspaceRootURL: fixture.workspaceURL,
            limit: 10
        ).isEmpty)
    }

    @Test
    func indexDetailReturnsSummaryWithoutFullContent() throws {
        let fixture = try TemporaryMemoryWorkspace()
        defer { fixture.remove() }
        let service = MemoryService()
        try service.writeEntry(
            content: """
            Timestamp: 2026-08-02 10:15 Europe/Rome
            Summary: compact index entry.
            State: full content stays in MEMORY.md.
            Next: query only when relevant.
            """,
            scope: .project,
            workspaceRootURL: fixture.workspaceURL
        )

        let output = try MemoryTool.execute(
            ToolRequest(
                name: "memory.read",
                arguments: ["detail": .string("index")]
            ),
            context: MemoryToolContext(workingDirectory: fixture.workspaceURL),
            memoryService: service
        )
        guard case let .object(result)? = output.rawResult,
              case let .array(entries)? = result["entries"],
              case let .object(first)? = entries.first,
              case let .object(metadata)? = first["metadata"] else {
            Issue.record("Expected an indexed memory entry with metadata.")
            return
        }

        #expect(output.text.contains("Project MEMORY.md index:"))
        #expect(output.text.contains("compact index entry."))
        #expect(result["detail"] == .string("index"))
        #expect(first["content"] == nil)
        #expect(metadata["summary"] == .string("compact index entry."))
        #expect(metadata["state"] == nil)
        #expect(metadata["next"] == nil)
    }

    @Test
    func fullDetailKeepsOriginalContentInJSON() throws {
        let fixture = try TemporaryMemoryWorkspace()
        defer { fixture.remove() }
        let service = MemoryService()
        try service.writeEntry(
            content: "Summary: full result.",
            scope: .project,
            workspaceRootURL: fixture.workspaceURL
        )

        let output = try MemoryTool.execute(
            ToolRequest(name: "memory.read", arguments: [:]),
            context: MemoryToolContext(workingDirectory: fixture.workspaceURL),
            memoryService: service
        )
        guard case let .object(result)? = output.rawResult,
              case let .array(entries)? = result["entries"],
              case let .object(first)? = entries.first else {
            Issue.record("Expected a full memory entry.")
            return
        }

        #expect(result["detail"] == .string("full"))
        #expect(first["content"] == .string("Summary: full result."))
    }

    @Test
    func searchRanksSummaryMatchesAheadOfBodyOnlyMatches() throws {
        let fixture = try TemporaryMemoryWorkspace()
        defer { fixture.remove() }
        let service = MemoryService()
        let summaryMatch = try service.writeEntry(
            content: """
            Timestamp: 2026-08-01 09:00 Europe/Rome
            Summary: transport architecture.
            State: shared NIO is active.
            Next: monitor it.
            """,
            scope: .project,
            workspaceRootURL: fixture.workspaceURL
        )
        _ = try service.writeEntry(
            content: """
            Timestamp: 2026-08-02 09:00 Europe/Rome
            Summary: unrelated maintenance.
            State: transport architecture is mentioned only in the body.
            Next: none.
            """,
            scope: .project,
            workspaceRootURL: fixture.workspaceURL
        )

        let matches = service.searchEntries(
            query: "transport architecture",
            scope: .project,
            workspaceRootURL: fixture.workspaceURL,
            limit: 10
        )

        #expect(matches.first?.id == summaryMatch.id)
    }

    @Test
    func malformedOrDuplicatePersistedIdentifiersAreReportedAndNeverDropped() throws {
        let fixture = try TemporaryMemoryWorkspace()
        defer { fixture.remove() }
        let memoryURL = fixture.workspaceURL.appendingPathComponent(MemoryService.filename)
        let duplicateID = UUID()
        let invalidDocuments: [(name: String, content: String)] = [
            (
                "invalid UUID",
                """
                # MEMORY.md

                ## Active

                - [id: not-a-uuid] Summary: preserve this malformed entry.

                ## Archived
                """
            ),
            (
                "missing closing bracket",
                """
                # MEMORY.md

                ## Active

                - [id: not-a-uuid Summary: preserve this malformed entry.

                ## Archived
                """
            ),
            (
                "empty UUID",
                """
                # MEMORY.md

                ## Active

                - [id: ] Summary: preserve this malformed entry.

                ## Archived
                """
            ),
            (
                "duplicate UUID",
                """
                # MEMORY.md

                ## Active

                - [id: \(duplicateID.uuidString)] Summary: preserve the first entry.
                - [id: \(duplicateID.uuidString)] Summary: preserve the second entry.

                ## Archived
                """
            ),
        ]
        let service = MemoryService()

        for document in invalidDocuments {
            try document.content.write(to: memoryURL, atomically: true, encoding: .utf8)
            let before = try Data(contentsOf: memoryURL)

            for request in [
                ToolRequest(name: "memory.read", arguments: [:]),
                ToolRequest(
                    name: "memory.search",
                    arguments: ["query": .string("preserve")]
                ),
            ] {
                do {
                    _ = try MemoryTool.execute(
                        request,
                        context: MemoryToolContext(workingDirectory: fixture.workspaceURL),
                        memoryService: service
                    )
                    Issue.record("Expected \(request.name) to reject \(document.name).")
                } catch MemoryServiceError.invalidDocument(_) {
                    // Expected: invalid data is not presented as an empty journal.
                }
            }

            do {
                _ = try service.writeEntry(
                    content: "Summary: a new entry must not replace malformed data.",
                    scope: .project,
                    workspaceRootURL: fixture.workspaceURL
                )
                Issue.record("Expected mutation to reject \(document.name).")
            } catch MemoryServiceError.invalidDocument(_) {
                // Expected: the file remains byte-for-byte unchanged.
            }

            #expect(try Data(contentsOf: memoryURL) == before)
        }
    }

    @Test
    func legacyEntriesHaveStableIdentifiersAndPersistThemOnUpdate() throws {
        let fixture = try TemporaryMemoryWorkspace()
        defer { fixture.remove() }
        let memoryURL = fixture.workspaceURL.appendingPathComponent(MemoryService.filename)
        try """
        # MEMORY.md

        ## Active

        - Timestamp: 2026-08-01 09:00 Europe/Rome
          Summary: legacy entry without an explicit id.
          State: it predates persisted memory identifiers.
          Next: update it safely.

        ## Archived
        """.write(to: memoryURL, atomically: true, encoding: .utf8)
        let service = MemoryService()
        let firstRead = try #require(service.readEntries(
            scope: .project,
            workspaceRootURL: fixture.workspaceURL,
            limit: 10
        ).first)
        let secondRead = try #require(service.readEntries(
            scope: .project,
            workspaceRootURL: fixture.workspaceURL,
            limit: 10
        ).first)

        #expect(firstRead.id == secondRead.id)

        _ = try service.updateEntry(
            id: firstRead.id,
            content: """
            Summary: migrated legacy entry.
            State: the identifier is now persisted.
            Next: retain normal update and archive operations.
            """,
            scope: .project,
            workspaceRootURL: fixture.workspaceURL
        )
        let persisted = try String(contentsOf: memoryURL, encoding: .utf8)
        let updated = try #require(service.readEntries(
            scope: .project,
            workspaceRootURL: fixture.workspaceURL,
            limit: 10
        ).first)

        #expect(persisted.contains("[id: \(firstRead.id.uuidString.uppercased())]"))
        #expect(updated.id == firstRead.id)
        #expect(updated.metadata.summary == "migrated legacy entry.")
    }

    @Test
    func concurrentUpdatesRemainSerializableAndPreserveOriginalTimestamp() async throws {
        let fixture = try TemporaryMemoryWorkspace()
        defer { fixture.remove() }
        let service = MemoryService()
        let original = try service.writeEntry(
            content: """
            Timestamp: 2026-08-01 09:00 Europe/Rome
            Summary: initial concurrent state.
            State: ready for updates.
            Next: serialize them.
            """,
            scope: .project,
            workspaceRootURL: fixture.workspaceURL
        )
        let updateCount = 32
        let barrier = MemoryUpdateBarrier(participantCount: updateCount)
        let timeZone = try #require(TimeZone(identifier: "Europe/Rome"))

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<updateCount {
                group.addTask {
                    await barrier.wait()
                    _ = try MemoryService().updateEntry(
                        id: original.id,
                        content: """
                        Summary: concurrent state \(index).
                        State: serialized update \(index).
                        Next: retain one complete winner.
                        """,
                        scope: .project,
                        workspaceRootURL: fixture.workspaceURL,
                        updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                        timeZone: timeZone
                    )
                }
            }
            try await group.waitForAll()
        }

        let entries = try service.readEntriesChecked(
            scope: .project,
            workspaceRootURL: fixture.workspaceURL,
            limit: 10
        )
        let winner = try #require(entries.first)

        #expect(entries.count == 1)
        #expect(winner.id == original.id)
        #expect(winner.metadata.timestamp == "2026-08-01 09:00 Europe/Rome")
        #expect(winner.metadata.updated != nil)
        #expect(winner.metadata.summary?.hasPrefix("concurrent state ") == true)
        #expect(winner.metadata.state?.hasPrefix("serialized update ") == true)
    }

    @Test
    func descriptorsAndPlannerExposeConfiguredMemoryCapabilities() throws {
        let names = Set(MemoryTool.toolDescriptors.map(\.name))
        let planner = try #require(
            AgentProfileStore.defaultProfiles().first {
                $0.id == AgentProfileStore.plannerAgentID.uuidString
            }
        )
        let resolvedPlannerTools = planner.allowedToolNames()

        #expect(names == Set([
            "memory.read",
            "memory.search",
            "memory.write",
            "memory.update",
            "memory.archive",
        ]))
        #expect(resolvedPlannerTools.isSuperset(of: names))
    }
}

private struct TemporaryMemoryWorkspace {
    let rootURL: URL
    let workspaceURL: URL

    init() throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-enhancement-tests-\(UUID().uuidString)", isDirectory: true)
        workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}

private actor MemoryUpdateBarrier {
    private let participantCount: Int
    private var arrivedCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func wait() async {
        arrivedCount += 1
        if arrivedCount == participantCount {
            let continuations = waiters
            waiters.removeAll()
            continuations.forEach { $0.resume() }
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
