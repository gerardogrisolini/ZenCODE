//
//  MemoryServiceTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 27/05/26.
//
//  Graph-backed memory facade tests. The durable store is the MemoryEngine
//  graph, loaded from JSON and persisted by mutations.
//

import Foundation
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime
import Testing

@Suite
struct MemoryServiceTests {
    @Test
    func readOnlyMemoryPromptDoesNotSuggestUnavailableMutations() {
        let prompt = MemoryService.toolUsagePromptSection(readOnly: true)

        #expect(prompt.contains("Memory tools (read-only):"))
        #expect(prompt.contains("do not claim to create, update, archive"))
        #expect(prompt.contains("memory.search"))
        #expect(!prompt.contains("Before writing"))
    }

    /// Each memory rule is stated once: the policy in the prompt section, the
    /// tool contracts in the tool descriptions, which are always visible next
    /// to the section and are the only memory guidance delegated agents get.
    @Test
    func memoryPromptKeepsEveryRuleAndLeavesToolContractsToTheDescriptions() throws {
        let full = MemoryService.toolUsagePromptSection(readOnly: false)
        for rule in [
            "Memory tools:",
            "its contents are not preloaded into this prompt",
            "labelled `<project-memory>` block",
            "call `memory.search` before concluding that no prior context exists",
            "`memory.get` for one entry by id",
            "`memory.read` with `detail: \"index\"`",
            "Without a configured embedding endpoint, retrieval and recall are pure BM25 keyword matching.",
            "Always verify the entries you retrieve against Git, files, tools, builds, tests, or current user messages before acting; fresh evidence wins when it conflicts with memory.",
            "Journal a durable fact when substantial work reaches a verified handoff",
            "a version or changelog edit alone is not evidence that it was published",
            "Before writing, search for an active entry about the same durable project fact.",
            "if nothing materially changed, do not write",
            "consolidate with `memory.update` and archive the other",
            "Do not write user preferences or operating rules to memory",
            "Saved-session pointers are maintained programmatically",
            "decide whether project memory should be created, updated, archived, or left unchanged",
            "do not record intentions, unimplemented plans, or unverified results",
            "`Summary` (the durable milestone or change)",
            "Add `tags` when writing so related entries stay linked in the graph and can be filtered with the `tags` argument of `memory.read` and `memory.search`",
            "Do not write every command or tool call",
        ] {
            #expect(full.contains(rule), "missing rule: \(rule)")
        }
        for duplicate in [
            "rewrites the entry in place",
            "Use `memory.archive` when",
            "reciprocal-rank fusion",
            "adds `Timestamp` automatically",
            "Prefer fresh evidence",
            "`offset` pages through the journal",
        ] {
            #expect(!full.contains(duplicate), "duplicate kept: \(duplicate)")
        }
        // Retrieval no longer expands over the graph links (`maxDepth` 0): the
        // guidance must not promise it.
        #expect(!full.contains("follow those links"))

        let readOnly = MemoryService.toolUsagePromptSection(readOnly: true)
        #expect(readOnly.contains("Without a configured embedding endpoint, retrieval and recall use BM25 keyword matching."))
        #expect(readOnly.contains("fresh evidence wins when it conflicts with memory"))
        #expect(!readOnly.contains("`offset` pages through the journal"))

        func description(_ name: String) throws -> String {
            try #require(MemoryTool.toolDescriptors.first { $0.name == name }).description
        }
        #expect(try description("memory.update").contains(
            "Its id, creation date, and archive state remain stable; Timestamp is preserved and Updated is stamped with the time of the update."
        ))
        #expect(try description("memory.archive").contains("stale, incorrect, or no-longer-useful"))
        #expect(try description("memory.archive").contains("is not deleted; memory.restore brings it back"))
        #expect(try description("memory.write").contains("Timestamp is added when missing"))
        #expect(try description("memory.search").contains(
            "BM25 keyword ranking and, when an embedding endpoint is configured, semantic similarity."
        ))
        #expect(try !description("memory.search").contains("graph-related"))
        #expect(try description("memory.search").contains("tags (all required) or category narrow them"))
        #expect(try description("memory.read").contains("offset pages through the journal"))
        #expect(try description("memory.read").contains("tags (all required) or category narrow it"))
    }

    @Test
    func writingAndReadingEntriesRoundTripsAndDeduplicates() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let first = try await service.writeEntry(
                content: "Summary: the graph store is the durable source.",
                target: .workspace(workspace.workspaceURL)
            )
            // Identical active content returns the existing entry instead of
            // creating a duplicate.
            let duplicate = try await service.writeEntry(
                content: "Summary: the graph store is the durable source.",
                target: .workspace(workspace.workspaceURL)
            )
            #expect(duplicate.id == first.id)

            let entries = try await service.readEntries(
                target: .workspace(workspace.workspaceURL),
                limit: 10
            )
            #expect(entries.count == 1)
            #expect(entries.first?.id == first.id)
            // ZenCODE-authored ids are canonical uppercase UUID values.
            #expect(entries.first?.id != nil)
        }
    }

    @Test
    func writePreservesMultilineEntryContent() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        let content = """
        Timestamp: 2026-06-03 11:45 Europe/Rome
        Summary: completed the memory graph framing.
        State: the graph is the resume source.
        Next: validate the real resume flow from a fresh session.
        """

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            _ = try await service.writeEntry(
                content: content,
                target: .workspace(workspace.workspaceURL)
            )
            let readEntry = try #require(
                try await service.readEntries(
                    target: .workspace(workspace.workspaceURL),
                    limit: 10
                ).first
            )

            #expect(readEntry.content == content)
            #expect(readEntry.metadata.summary == "completed the memory graph framing.")
            #expect(readEntry.metadata.state == "the graph is the resume source.")
            #expect(readEntry.metadata.next == "validate the real resume flow from a fresh session.")
        }
    }

    @Test
    func memoryToolWriteAddsTimestampWhenMissing() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        let timeZone = TimeZone(identifier: "Europe/Rome")!
        let date = DateComponents(
            calendar: Calendar(identifier: .gregorian),
            timeZone: timeZone,
            year: 2026,
            month: 6,
            day: 4,
            hour: 15,
            minute: 35
        ).date!

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            _ = try await MemoryTool.executeAsync(
                ToolRequest(
                    name: "memory.write",
                    arguments: [
                        "content": .string("""
                        Summary: fixed the release install path.
                        State: install script points at the published asset.
                        Next: verify install from a fresh checkout.
                        """)
                    ]
                ),
                context: MemoryToolContext(
                    graphTarget: .workspace(workspace.workspaceURL),
                    currentDate: date,
                    currentTimeZone: timeZone
                ),
                memoryService: service
            )
            let entry = try #require(
                try await service.readEntries(
                    target: .workspace(workspace.workspaceURL),
                    limit: 10
                ).first
            )

            #expect(entry.content.hasPrefix("Timestamp: 2026-06-04 15:35 Europe/Rome"))
            #expect(entry.content.contains("Summary: fixed the release install path."))
        }
    }

    @Test
    func memoryToolDeduplicatesTimestampedWritesFromDifferentTurnContexts() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        let firstZone = TimeZone(identifier: "Europe/Rome")!
        let secondZone = TimeZone(identifier: "America/Los_Angeles")!
        let content = """
        Summary: fixed durable graph permissions.
        State: graph and lock are private to the current user.
        Next: validate a fresh process open.
        """

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let first = try await MemoryTool.executeAsync(
                ToolRequest(name: "memory.write", arguments: ["content": .string(content)]),
                context: MemoryToolContext(
                    graphTarget: .workspace(workspace.workspaceURL),
                    currentDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentTimeZone: firstZone
                ),
                memoryService: service
            )
            let second = try await MemoryTool.executeAsync(
                ToolRequest(name: "memory.write", arguments: ["content": .string(content)]),
                context: MemoryToolContext(
                    graphTarget: .workspace(workspace.workspaceURL),
                    // A later minute and a separate context/time zone must not
                    // make Timestamp metadata defeat duplicate detection.
                    currentDate: Date(timeIntervalSince1970: 1_700_003_660),
                    currentTimeZone: secondZone
                ),
                memoryService: service
            )

            guard case let .object(firstResult)? = first.rawResult,
                  case let .object(secondResult)? = second.rawResult else {
                Issue.record("Expected memory.write JSON results.")
                return
            }
            #expect(firstResult["written"] == .bool(true))
            #expect(secondResult["deduplicated"] == .bool(true))
            #expect(
                try await service.readEntries(
                    target: .workspace(workspace.workspaceURL),
                    limit: 10
                ).count == 1
            )
            // The surviving entry keeps the first turn's stamp verbatim: a
            // duplicate is reused, never rewritten.
            let stored = try await service.readEntries(
                target: .workspace(workspace.workspaceURL),
                limit: 10
            )
            #expect(stored.first?.content.hasPrefix("Timestamp: 2023-11-14 23:13 Europe/Rome") == true)
        }
    }

    // MARK: - Deduplication must not swallow authored timestamps

    /// A `Timestamp:` line the author wrote is content, not metadata.
    ///
    /// Ignoring every line that starts with `timestamp:` would merge these two
    /// entries even though only one of them was stamped by the tool, silently
    /// discarding the author's own annotation.
    @Test
    func authoredTimestampKeepsAnEntryDistinctFromAnAutoStampedOne() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        let body = "Summary: release cut for 1.2.4."

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let authored = try await MemoryTool.executeAsync(
                ToolRequest(
                    name: "memory.write",
                    arguments: ["content": .string("Timestamp: sprint kickoff\n\(body)")]
                ),
                context: MemoryToolContext(
                    graphTarget: .workspace(workspace.workspaceURL),
                    currentDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentTimeZone: TimeZone(identifier: "Europe/Rome")!
                ),
                memoryService: service
            )
            let autoStamped = try await MemoryTool.executeAsync(
                ToolRequest(name: "memory.write", arguments: ["content": .string(body)]),
                context: MemoryToolContext(
                    graphTarget: .workspace(workspace.workspaceURL),
                    currentDate: Date(timeIntervalSince1970: 1_700_003_660),
                    currentTimeZone: TimeZone(identifier: "Europe/Rome")!
                ),
                memoryService: service
            )

            #expect(authored.rawResult?.objectValue?["written"]?.boolValue == true)
            #expect(autoStamped.rawResult?.objectValue?["written"]?.boolValue == true)
            let entries = try await service.readEntries(
                target: .workspace(workspace.workspaceURL),
                limit: 10
            )
            #expect(entries.count == 2)
            #expect(entries.contains { $0.content.hasPrefix("Timestamp: sprint kickoff") })
        }
    }

    /// The legacy public write API never generated a stamp, so nothing in the
    /// content it is handed may be ignored: two entries that differ by a
    /// caller-supplied `Timestamp:` remain two entries.
    @Test
    func legacyWriteEntryAPIComparesContentLiterally() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let first = try await service.writeEntry(
                content: "Timestamp: 2024-01-01 09:00 Europe/Rome\nSummary: migrated the journal.",
                target: .workspace(workspace.workspaceURL)
            )
            let second = try await service.writeEntry(
                content: "Timestamp: 2025-02-02 10:00 Europe/Rome\nSummary: migrated the journal.",
                target: .workspace(workspace.workspaceURL)
            )

            #expect(first.id != second.id)
            #expect(
                try await service.readEntries(
                    target: .workspace(workspace.workspaceURL),
                    limit: 10
                ).count == 2
            )
        }
    }

    @Test
    func memorySearchReturnsEntriesWithProjectScope() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            _ = try await service.writeEntry(
                content: "Summary: architecture runtime decision.",
                target: .workspace(workspace.workspaceURL)
            )

            let output = try await MemoryTool.executeAsync(
                ToolRequest(
                    name: "memory.search",
                    arguments: ["query": .string("architecture")]
                ),
                context: MemoryToolContext(graphTarget: .workspace(workspace.workspaceURL)),
                memoryService: service
            )
            guard case let .object(result)? = output.rawResult,
                  case let .array(entries)? = result["entries"],
                  case let .object(firstEntry)? = entries.first else {
                Issue.record("Expected memory.search to return JSON entries.")
                return
            }

            #expect(firstEntry["scope"] == .string("project"))
        }
    }

    @Test
    func developerPromptFollowsActiveMemoryToolState() {
        let developer = AgentProfileStore.defaultProfiles()[0]
        let withoutMemory = AgentCoreAppSessionFactory.resolvedPromptSections(
            providedSystemPrompt: nil,
            cwd: "/tmp/project",
            selectedAgent: developer,
            allowedToolNames: []
        )
        let withMemory = AgentCoreAppSessionFactory.resolvedPromptSections(
            providedSystemPrompt: nil,
            cwd: "/tmp/project",
            selectedAgent: developer,
            allowedToolNames: ["memory.read", "memory.write"]
        )

        #expect(withoutMemory.systemPrompt == withMemory.systemPrompt)
        #expect(!withoutMemory.systemPrompt.contains("Memory tools:"))
        #expect(!withMemory.systemPrompt.contains("Memory tools:"))
        #expect(!withoutMemory.dynamicContext.contains("Memory tools:"))
        #expect(!withoutMemory.dynamicContext.contains("`memory.write`"))
        #expect(withMemory.dynamicContext.contains("Memory tools:"))
        #expect(withMemory.dynamicContext.contains("`memory.write`"))
    }

    @Test
    func recommendedAgentProfilesIncludeOperatingModes() throws {
        let profiles = AgentProfileStore.defaultProfiles()
        let names = Set(profiles.map(\.name))

        var expectedNames: Set<String> = [
            "Developer",
            "Builder",
            "Reviewer",
            "Reporter",
            "Tester",
            "Planner"
        ]
        #if os(macOS)
        expectedNames.insert("Organizer")
        #endif
        #expect(names == expectedNames)
        #expect(Set(profiles.map(\.id)).count == profiles.count)
        #expect(try AgentProfileStore.developerProfile(in: profiles).name == "Developer")
    }
}
