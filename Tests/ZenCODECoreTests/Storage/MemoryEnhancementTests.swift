//
//  MemoryEnhancementTests.swift
//  ZenCODE
//
//  Graph-backed memory enhancement behaviour: in-place update, archive,
//  rendering detail, hybrid recall + relation cascade, confidence decay/boost,
//  JSON persistence round-trip, and the one-shot MEMORY.md migration.
//

import Foundation
import ZenMemory
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
        State: the entry content is the durable source.
        Next: query it only when relevant.
        """

        let entry = ZenCODECore.MemoryEntry(content: content)
        let metadata = entry.metadata

        #expect(entry.content == content)
        #expect(entry.title == "compact memory metadata.")
        #expect(metadata.timestamp == "2026-08-02 10:15 Europe/Rome")
        #expect(metadata.updated == "2026-08-03 11:20 Europe/Rome")
        #expect(metadata.summary == "compact memory metadata.")
        #expect(metadata.state == "the entry content is the durable source.")
        #expect(metadata.next == "query it only when relevant.")
    }

    @Test
    func memoryUpdatePreservesIdentityAndOriginalTimestamp() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let original = try await service.writeEntry(
                content: """
                Timestamp: 2026-08-01 09:00 Europe/Rome
                Summary: original transport decision.
                State: the first implementation is active.
                Next: validate it.
                """,
                workspaceRootURL: workspace.workspaceURL
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

            let output = try await MemoryTool.executeAsync(
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
                    workingDirectory: workspace.workspaceURL,
                    currentDate: updateDate,
                    currentTimeZone: timeZone
                ),
                memoryService: service
            )
            let entries = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            let updated = try #require(entries.first)

            #expect(entries.count == 1)
            #expect(updated.id == original.id)
            #expect(updated.createdAt == original.createdAt)
            #expect(updated.metadata.timestamp == "2026-08-01 09:00 Europe/Rome")
            #expect(updated.metadata.updated == "2026-08-04 16:45 Europe/Rome")
            #expect(updated.metadata.summary == "updated transport decision.")
            guard case let .object(result)? = output.rawResult else {
                Issue.record("Expected a JSON result from memory.update.")
                return
            }
            #expect(result["updated"] == .bool(true))
        }
    }

    @Test
    func memoryUpdatePreservesArchivedState() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let entry = try await service.writeEntry(
                content: "Summary: archived project state.",
                workspaceRootURL: workspace.workspaceURL
            )
            _ = try await service.archiveEntry(
                id: entry.id.uuidString,
                workspaceRootURL: workspace.workspaceURL
            )

            _ = try await service.updateEntry(
                id: entry.id.uuidString,
                content: "Summary: corrected archived project state.",
                workspaceRootURL: workspace.workspaceURL
            )
            let all = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                includeArchived: true,
                limit: 10
            )

            #expect(all.first?.id == entry.id)
            #expect(all.first?.isArchived == true)
            #expect(all.first?.metadata.summary == "corrected archived project state.")
            #expect(try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            ).isEmpty)
        }
    }

    @Test
    func indexDetailReturnsSummaryWithoutFullContent() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            _ = try await service.writeEntry(
                content: """
                Timestamp: 2026-08-02 10:15 Europe/Rome
                Summary: compact index entry.
                State: full content stays in the graph.
                Next: query only when relevant.
                """,
                workspaceRootURL: workspace.workspaceURL
            )

            let output = try await MemoryTool.executeAsync(
                ToolRequest(
                    name: "memory.read",
                    arguments: ["detail": .string("index")]
                ),
                context: MemoryToolContext(workingDirectory: workspace.workspaceURL),
                memoryService: service
            )
            guard case let .object(result)? = output.rawResult,
                  case let .array(entries)? = result["entries"],
                  case let .object(first)? = entries.first,
                  case let .object(metadata)? = first["metadata"] else {
                Issue.record("Expected an indexed memory entry with metadata.")
                return
            }

            #expect(output.text.contains("Project memory index:"))
            #expect(output.text.contains("compact index entry."))
            #expect(result["detail"] == .string("index"))
            #expect(first["content"] == nil)
            #expect(metadata["summary"] == .string("compact index entry."))
            #expect(metadata["state"] == nil)
            #expect(metadata["next"] == nil)
        }
    }

    @Test
    func fullDetailKeepsOriginalContentInJSON() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            _ = try await service.writeEntry(
                content: "Summary: full result.",
                workspaceRootURL: workspace.workspaceURL
            )

            let output = try await MemoryTool.executeAsync(
                ToolRequest(name: "memory.read", arguments: [:]),
                context: MemoryToolContext(workingDirectory: workspace.workspaceURL),
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
    }

    @Test
    func searchRanksRicherTermMatchesAhead() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let richer = try await service.writeEntry(
                content: "Summary: transport architecture for the swift server.",
                workspaceRootURL: workspace.workspaceURL
            )
            _ = try await service.writeEntry(
                content: "Summary: transport layer notes.",
                workspaceRootURL: workspace.workspaceURL
            )

            let matches = try await service.searchEntries(
                query: "transport architecture",
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )

            #expect(matches.first?.id == richer.id)
            // The partial match shares only one of the two query terms and
            // scores roughly 0.26x the top hit, so the score-threshold selector
            // (relative floor 0.5) filters it out instead of returning it as a
            // weak second result. Ranking is preserved for what remains.
            #expect(matches.count == 1)
        }
    }

    @Test
    func weakRecallCandidatesAreDecayedRatherThanBoosted() async throws {
        // Regression: with the passthrough selector every recalled candidate
        // was selected, so weak partial matches were boosted toward confidence
        // 1.0. The score-threshold selector must instead decay them.
        //
        // Maintenance is exercised through the automatic recall path
        // (`store.context`), not `memory.search`: search is read-only and must
        // not mutate retrievalCount/confidence/access/link.
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let strong = try await service.writeEntry(
                content: "Summary: transport architecture for the swift server.",
                workspaceRootURL: workspace.workspaceURL
            )
            let weak = try await service.writeEntry(
                content: "Summary: transport layer notes.",
                workspaceRootURL: workspace.workspaceURL
            )

            let store = try await MemoryGraphStoreRegistry.shared.store(
                forWorkspaceRoot: workspace.workspaceURL,
                graphURL: workspace.graphURL()
            )
            _ = try await store.context(for: "transport architecture")

            let after = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            let strongAfter = try #require(after.first { $0.id == strong.id })
            let weakAfter = try #require(after.first { $0.id == weak.id })

            // The weak hit (~0.26x of the top) was filtered by the 0.5 floor,
            // so only the strong hit was verified and boosted.
            #expect(strongAfter.accessCount == 1)
            #expect(strongAfter.confidence == 1.0)
            // The weak hit was decayed, not boosted: no access bump, confidence
            // fell below the initial 1.0.
            #expect(weakAfter.accessCount == 0)
            #expect(weakAfter.confidence < strongAfter.confidence)
        }
    }

    @Test
    func repeatedRecallsDoNotDenselyConnectTheGraph() async throws {
        // Regression: with the passthrough selector every recall with two or
        // more results linked ALL of them pairwise at weight 0.7, saturating
        // the graph until cascade retrieval returned noise. The threshold
        // selector keeps only strong hits, so co-relevance edges must not
        // accumulate across repeated recalls.
        //
        // Tested through the automatic recall path (`store.context`), not
        // `memory.search`: search is read-only and never creates edges.
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            _ = try await service.writeEntry(
                content: "Summary: transport architecture for the swift server.",
                workspaceRootURL: workspace.workspaceURL
            )
            _ = try await service.writeEntry(
                content: "Summary: transport layer notes.",
                workspaceRootURL: workspace.workspaceURL
            )
            _ = try await service.writeEntry(
                content: "Summary: transport cost analysis report.",
                workspaceRootURL: workspace.workspaceURL
            )

            let store = try await MemoryGraphStoreRegistry.shared.store(
                forWorkspaceRoot: workspace.workspaceURL,
                graphURL: workspace.graphURL()
            )
            // Each query strongly matches exactly one entry; the other two
            // share only the common term and fall below the 0.5 floor. Under
            // the old passthrough selector the first recall alone would have
            // produced a complete triangle of relatesTo edges.
            for query in ["transport architecture", "transport layer", "transport cost"] {
                for _ in 0..<3 {
                    _ = try await store.context(for: query)
                }
            }

            let graph = try await JSONMemoryPersistence(url: workspace.graphURL()).load()
            let coRelevanceEdges = graph.edges.values
                .flatMap { $0 }
                .filter { edge in
                    if case .relatesTo = edge.kind { return true }
                    return false
                }
            #expect(coRelevanceEdges.isEmpty)
            #expect(graph.metadata.linkDiscoveryCount == 0)
        }
    }

    @Test
    func hybridRecallSurfacesRelatedEntriesThroughSharedTags() async throws {
        // The "related" entry shares no query term with the query; it is only
        // reachable because the graph cascades through the shared tag edge.
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let direct = try await service.writeEntry(
                content: "Summary: postgres connection pooling configuration.",
                workspaceRootURL: workspace.workspaceURL,
                tags: ["backend"]
            )
            let related = try await service.writeEntry(
                content: "Summary: background task scheduler workers.",
                workspaceRootURL: workspace.workspaceURL,
                tags: ["backend"]
            )
            let unrelated = try await service.writeEntry(
                content: "Summary: frontend animation spring physics.",
                workspaceRootURL: workspace.workspaceURL,
                tags: ["ui"]
            )

            let matches = try await service.searchEntries(
                query: "postgres pooling",
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            let ids = Set(matches.map(\.id))

            #expect(ids.contains(direct.id))
            #expect(ids.contains(related.id))
            #expect(!ids.contains(unrelated.id))
        }
    }

    @Test
    func confidenceDecaysWithAgeAndVariesByCategory() {
        let now = Date()
        let sixtyDaysAgo = now.addingTimeInterval(-60 * 86_400)
        let fresh = GraphEntry(category: .fact, content: "fresh fact", createdAt: now)
        let oldFact = GraphEntry(category: .fact, content: "old fact", createdAt: sixtyDaysAgo)
        let oldCorrection = GraphEntry(
            category: .correction,
            content: "old correction",
            createdAt: sixtyDaysAgo
        )

        #expect(oldFact.effectiveConfidence(at: now) < fresh.effectiveConfidence(at: now))
        // A 60-day-old fact (30-day half-life) has decayed well below half.
        #expect(oldFact.effectiveConfidence(at: now) < 0.5)
        // Corrections decay far more slowly than facts (365- vs 30-day half-life).
        #expect(oldCorrection.effectiveConfidence(at: now) > oldFact.effectiveConfidence(at: now))
    }

    @Test
    func confidenceBoostAndDecayMoveTheStoredValue() {
        var entry = GraphEntry(category: .fact, content: "boostable fact")
        entry.decayConfidence(by: 0.5)
        #expect(entry.confidence == 0.5)

        let beforeBoost = entry.effectiveConfidence()
        entry.boostConfidence(by: 0.2)
        #expect(entry.confidence == 0.7)
        #expect(entry.accessCount == 1)
        #expect(entry.effectiveConfidence() > beforeBoost)
    }

    @Test
    func graphStatePersistsAcrossReopens() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let graphURL = workspace.graphURL()
            let first = try await service.writeEntry(
                content: "Summary: persisted fact one.",
                workspaceRootURL: workspace.workspaceURL,
                tags: ["persistence"]
            )
            let second = try await service.writeEntry(
                content: "Summary: persisted fact two.",
                workspaceRootURL: workspace.workspaceURL,
                tags: ["persistence"]
            )
            _ = try await service.archiveEntry(
                id: second.id.uuidString,
                workspaceRootURL: workspace.workspaceURL
            )

            #expect(FileManager.default.fileExists(atPath: graphURL.path))

            // A freshly opened store must read the persisted JSON, not the
            // cached in-memory engine.
            let reopened = try await MemoryGraphStore.open(
                graphURL: graphURL,
                workspaceRootURL: workspace.workspaceURL
            )
            let all = await reopened.entries(includeArchived: true, limit: 100)

            #expect(all.count == 2)
            #expect(all.contains { $0.id == first.id.uuidString })
            #expect(all.contains { $0.isArchived && $0.id == second.id.uuidString })
            #expect(Set(all.flatMap(\.tags)) == ["persistence"])
        }
    }

    @Test
    func migratingLegacyJournalIsIdempotent() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        let archivedID = UUID()
        let journal = """
        # MEMORY.md

        ## Active

        - Timestamp: 2026-08-01 09:00 Europe/Rome
          Summary: first legacy entry.
          State: migrated once.
          Next: never duplicate it.

        - Timestamp: 2026-08-02 09:00 Europe/Rome
          Summary: second legacy entry.
          State: also migrated once.
          Next: keep order.

        ## Archived

        - [id: \(archivedID.uuidString)] Timestamp: 2026-07-30 09:00 Europe/Rome
          Summary: archived legacy entry.
          State: retained as inactive.
          Next: stay archived.
        """
        try await workspace.withIsolatedSupport {
            try workspace.writeLegacyJournal(journal)
            let graphURL = workspace.graphURL()

            let first = try await MemoryGraphStore.open(
                graphURL: graphURL,
                workspaceRootURL: workspace.workspaceURL
            )
            let firstEntries = await first.entries(includeArchived: true, limit: 100)
            #expect(firstEntries.count == 3)
            #expect(firstEntries.contains { $0.isArchived })

            // The migration is deterministic (identity is derived from the
            // journal), so a second open re-migrates from MEMORY.md and
            // converges on the same nodes. open no longer persists the graph
            // — the first mutation will — so re-migration is the expected path
            // until a write has created the file.
            let second = try await MemoryGraphStore.open(
                graphURL: graphURL,
                workspaceRootURL: workspace.workspaceURL
            )
            let secondEntries = await second.entries(includeArchived: true, limit: 100)
            #expect(secondEntries.count == firstEntries.count)
            #expect(Set(secondEntries.map(\.id)) == Set(firstEntries.map(\.id)))
        }
    }

    @Test
    func undatedLegacyEntriesDoNotSortAboveDatedOnes() async throws {
        // Regression: undated legacy entries used to default to "now" and were
        // hoisted above their dated predecessors. They must inherit a slot just
        // below the entry that precedes them in the document.
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        let journal = """
        # MEMORY.md

        ## Active

        - Timestamp: 2026-08-05 09:00 Europe/Rome
          Summary: dated newest entry.
          State: should stay on top.
          Next: none.

        - Summary: undated legacy entry.
          State: must not be hoisted above the dated entry above it.
          Next: none.

        - Timestamp: 2026-08-01 09:00 Europe/Rome
          Summary: dated older entry.
          State: should stay below the undated entry.
          Next: none.

        ## Archived
        """
        try await workspace.withIsolatedSupport {
            try workspace.writeLegacyJournal(journal)
            let entries = try await MemoryService().readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            let summaries = entries.compactMap(\.metadata.summary)

            #expect(summaries == [
                "dated newest entry.",
                "undated legacy entry.",
                "dated older entry."
            ])
        }
    }

    @Test
    func archivedEntriesRemainReachableUnderSmallSearchLimit() async throws {
        // Regression: archived hits appended after a full page of active results
        // were unreachable. The store reserves part of the budget for them.
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            _ = try await service.writeEntry(
                content: "Summary: redis cache layer.",
                workspaceRootURL: workspace.workspaceURL
            )
            _ = try await service.writeEntry(
                content: "Summary: redis pubsub layer.",
                workspaceRootURL: workspace.workspaceURL
            )
            let archived = try await service.writeEntry(
                content: "Summary: redis cluster setup notes.",
                workspaceRootURL: workspace.workspaceURL
            )
            _ = try await service.archiveEntry(
                id: archived.id.uuidString,
                workspaceRootURL: workspace.workspaceURL
            )

            let excludingArchived = try await service.searchEntries(
                query: "redis",
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(!excludingArchived.contains { $0.id == archived.id })

            let limited = try await service.searchEntries(
                query: "redis",
                workspaceRootURL: workspace.workspaceURL,
                includeArchived: true,
                limit: 2
            )
            #expect(limited.count == 2)
            #expect(limited.contains { $0.id == archived.id })
        }
    }

    @Test
    func malformedLegacyJournalsAreRejectedAndNeverOverwritten() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
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

        try await workspace.withIsolatedSupport {
            let service = MemoryService()

            for document in invalidDocuments {
                let memoryURL = workspace.workspaceURL
                    .appendingPathComponent(MemoryService.filename)
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
                        _ = try await MemoryTool.executeAsync(
                            request,
                            context: MemoryToolContext(workingDirectory: workspace.workspaceURL),
                            memoryService: service
                        )
                        Issue.record("Expected \(request.name) to reject \(document.name).")
                    } catch MemoryServiceError.invalidDocument {
                        // Expected: invalid data is not presented as an empty journal.
                    }
                }

                do {
                    _ = try await service.writeEntry(
                        content: "Summary: a new entry must not replace malformed data.",
                        workspaceRootURL: workspace.workspaceURL
                    )
                    Issue.record("Expected mutation to reject \(document.name).")
                } catch MemoryServiceError.invalidDocument {
                    // Expected: the file remains byte-for-byte unchanged.
                }

                #expect(try Data(contentsOf: memoryURL) == before)
            }
        }
    }

    @Test
    func legacyEntriesHaveStableIdentifiersAcrossReads() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        let journal = """
        # MEMORY.md

        ## Active

        - Timestamp: 2026-08-01 09:00 Europe/Rome
          Summary: legacy entry without an explicit id.
          State: it predates persisted memory identifiers.
          Next: update it safely.

        ## Archived
        """
        try await workspace.withIsolatedSupport {
            try workspace.writeLegacyJournal(journal)
            let service = MemoryService()
            let firstRead = try #require(try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            ).first)
            let secondRead = try #require(try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            ).first)

            // The deterministic derived identifier is stable across reads.
            #expect(firstRead.id == secondRead.id)
            #expect(firstRead.source == MemoryGraphStore.migrationSource)

            _ = try await service.updateEntry(
                id: firstRead.id.uuidString,
                content: """
                Summary: migrated legacy entry.
                State: the identifier now lives in the graph.
                Next: retain normal update and archive operations.
                """,
                workspaceRootURL: workspace.workspaceURL
            )
            let updated = try #require(try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            ).first)

            #expect(updated.id == firstRead.id)
            #expect(updated.metadata.summary == "migrated legacy entry.")
        }
    }

    @Test
    func concurrentUpdatesRemainSerializableAndPreserveOriginalTimestamp() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let original = try await service.writeEntry(
                content: """
                Timestamp: 2026-08-01 09:00 Europe/Rome
                Summary: initial concurrent state.
                State: ready for updates.
                Next: serialize them.
                """,
                workspaceRootURL: workspace.workspaceURL
            )
            let updateCount = 32
            let barrier = MemoryUpdateBarrier(participantCount: updateCount)
            let timeZone = try #require(TimeZone(identifier: "Europe/Rome"))

            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<updateCount {
                    group.addTask {
                        await barrier.wait()
                        _ = try await MemoryService().updateEntry(
                            id: original.id.uuidString,
                            content: """
                            Summary: concurrent state \(index).
                            State: serialized update \(index).
                            Next: retain one complete winner.
                            """,
                            workspaceRootURL: workspace.workspaceURL,
                            updatedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                            timeZone: timeZone
                        )
                    }
                }
                try await group.waitForAll()
            }

            let entries = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
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
    }

    @Test
    func descriptorsAndPlannerExposeConfiguredReadOnlyMemoryCapabilities() throws {
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
        let readOnlyMemoryNames: Set<String> = ["memory.read", "memory.search"]
        let mutatingMemoryNames = names.subtracting(readOnlyMemoryNames)

        #expect(planner.readOnly)
        #expect(resolvedPlannerTools.isSuperset(of: readOnlyMemoryNames))
        #expect(resolvedPlannerTools.isDisjoint(with: mutatingMemoryNames))
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
