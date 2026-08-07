//
//  MemoryServiceTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 27/05/26.
//
//  Graph-backed memory facade tests. The durable store is the ZenMemory
//  graph; MEMORY.md is no longer written, only migrated once on first open.
//

import Foundation
import ZenMemory
import ToolCore
@testable import ZenCODECore
import Testing

@Suite
struct MemoryServiceTests {
    @Test
    func memoryTemplatesDescribeProjectResponsibilities() {
        #expect(MemoryService.defaultProjectMemoryContent.contains("Durable project journal"))
        #expect(MemoryService.defaultProjectMemoryContent.contains("Timestamp: YYYY-MM-DD HH:mm TimeZone"))
        #expect(MemoryService.toolUsagePromptSection().contains("Treat durable project memory as first-class context"))
        #expect(!MemoryService.toolUsagePromptSection().localizedCaseInsensitiveContains("global memory"))
        #expect(MemoryService.toolUsagePromptSection().contains("At the end of a substantial project turn"))

        let projectDefault = ProjectContextFileService.defaultContent(
            kind: .memory,
            projectName: "TestProject",
            rootPath: "/tmp/TestProject"
        )
        #expect(projectDefault == MemoryService.defaultProjectMemoryContent)
    }

    @Test
    func emptyTemplateJournalMigratesToEmptyGraph() async throws {
        // The default template has the Active/Archived sections but no entries,
        // so migrating it must seed an empty graph rather than parsing the
        // guidance bullets as memory.
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        try workspace.writeLegacyJournal(MemoryService.defaultProjectMemoryContent)

        try await workspace.withIsolatedSupport {
            let entries = try await MemoryService().readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(entries.isEmpty)
        }
    }

    @Test
    func writingAndReadingEntriesRoundTripsAndDeduplicates() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let first = try await service.writeEntry(
                content: "Summary: the graph store is the durable source.",
                workspaceRootURL: workspace.workspaceURL
            )
            // Identical active content returns the existing entry instead of
            // creating a duplicate.
            let duplicate = try await service.writeEntry(
                content: "Summary: the graph store is the durable source.",
                workspaceRootURL: workspace.workspaceURL
            )
            #expect(duplicate.id == first.id)

            let entries = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(entries.count == 1)
            #expect(entries.first?.id == first.id)
            // ZenCODE-authored ids are canonical uppercase UUID text.
            #expect(UUID(uuidString: entries.first?.id ?? "") != nil)
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
                workspaceRootURL: workspace.workspaceURL
            )
            let readEntry = try #require(
                try await service.readEntries(
                    workspaceRootURL: workspace.workspaceURL,
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
            _ = try await MemoryTool.execute(
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
                    workingDirectory: workspace.workspaceURL,
                    currentDate: date,
                    currentTimeZone: timeZone
                ),
                memoryService: service
            )
            let entry = try #require(
                try await service.readEntries(
                    workspaceRootURL: workspace.workspaceURL,
                    limit: 10
                ).first
            )

            #expect(entry.content.hasPrefix("Timestamp: 2026-06-04 15:35 Europe/Rome"))
            #expect(entry.content.contains("Summary: fixed the release install path."))
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
                workspaceRootURL: workspace.workspaceURL
            )

            let output = try await MemoryTool.execute(
                ToolRequest(
                    name: "memory.search",
                    arguments: ["query": .string("architecture")]
                ),
                context: MemoryToolContext(workingDirectory: workspace.workspaceURL),
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
                workspaceRootURL: workspace.workspaceURL
            )
            _ = try await service.writeEntry(
                content: "Summary: database migrations run at startup.",
                workspaceRootURL: workspace.workspaceURL
            )

            let matches = try await service.searchEntries(
                query: "actors mutable state",
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(matches.contains { $0.content.contains("actors") })

            let all = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
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
                workspaceRootURL: workspace.workspaceURL,
                category: .preference,
                tags: ["swift", "concurrency"]
            )

            #expect(entry.category == .preference)
            #expect(entry.tags == ["swift", "concurrency"])
            #expect(entry.trust == .medium)
            #expect(entry.source == "memory.write")
            #expect(entry.scope == .project)

            let read = try #require(
                try await service.entry(
                    id: entry.id,
                    workspaceRootURL: workspace.workspaceURL
                )
            )
            #expect(read.category == .preference)
            #expect(Set(read.tags) == ["swift", "concurrency"])
        }
    }

    @Test
    func savedSessionsIndexKeepsLatestSessionPerProject() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-tests-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        let firstProjectURL = rootURL.appendingPathComponent("first", isDirectory: true)
        let secondProjectURL = rootURL.appendingPathComponent("second", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let store = SavedSessionsStore(directoryURL: storeDirectoryURL)
        try store.recordSavedSession(
            projectPath: firstProjectURL.path,
            sessionName: "first checkpoint",
            sessionID: "first-session-old",
            savedAt: Date(timeIntervalSince1970: 100)
        )
        try store.recordSavedSession(
            projectPath: secondProjectURL.path,
            sessionName: "second checkpoint",
            sessionID: "second-session",
            savedAt: Date(timeIntervalSince1970: 200)
        )
        try store.recordSavedSession(
            projectPath: firstProjectURL.path,
            sessionName: "first latest",
            sessionID: "first-session-new",
            savedAt: Date(timeIntervalSince1970: 300)
        )

        let sessions = store.sessions()

        #expect(store.sessionsFileURL().lastPathComponent == "sessions.json")
        #expect(FileManager.default.fileExists(atPath: store.sessionsFileURL().path))
        #expect(sessions.count == 2)
        #expect(sessions.first?.sessionID == "first-session-new")
        #expect(sessions.first?.sessionName == "first latest")
        #expect(sessions.contains { $0.sessionID == "second-session" })
        #expect(!sessions.contains { $0.sessionID == "first-session-old" })
    }

    @Test
    func savedSessionsIndexRetainsConcurrentWritesAcrossInstances() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("memory-tests-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        let writeCount = 64
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        let barrier = SavedSessionsWriteBarrier(participantCount: writeCount)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<writeCount {
                group.addTask {
                    let directoryURL = index.isMultiple(of: 2)
                        ? storeDirectoryURL
                        : storeDirectoryURL.appendingPathComponent(".")
                    let store = SavedSessionsStore(directoryURL: directoryURL)
                    await barrier.wait()
                    try store.recordSavedSession(
                        projectPath: rootURL.appendingPathComponent("project-\(index)").path,
                        sessionName: "checkpoint \(index)",
                        sessionID: "session-\(index)",
                        savedAt: Date(timeIntervalSince1970: TimeInterval(index))
                    )
                }
            }
            try await group.waitForAll()
        }

        let sessions = SavedSessionsStore(directoryURL: storeDirectoryURL).sessions()
        #expect(sessions.count == writeCount)
        #expect(Set(sessions.map(\.sessionID)) == Set((0..<writeCount).map { "session-\($0)" }))
        #expect(Set(sessions.map(\.projectPath)).count == writeCount)
    }

    @Test
    func standalonePromptOmitsMemoryInstructionsWhenMemoryToolIsDisabled() {
        let prompt = AgentStandaloneSystemPrompt.prompt(
            cwd: "/tmp/project",
            memoryToolEnabled: false
        )

        #expect(!prompt.contains("Memory tools:"))
        #expect(!prompt.contains("`memory.write`"))
        #expect(!prompt.contains("memory, feature, and delegated sub-agent tools"))
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

        #expect(names == Set([
            "Developer",
            "Builder",
            "Minimal",
            "Reviewer",
            "Reporter",
            "Planner"
        ]))
        #expect(Set(profiles.map(\.id)).count == profiles.count)
        #expect(try AgentProfileStore.developerProfile(in: profiles).name == "Developer")
    }
}


private actor SavedSessionsWriteBarrier {
    private let participantCount: Int
    private var arrivedCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(participantCount: Int) {
        self.participantCount = participantCount
    }

    func wait() async {
        arrivedCount += 1
        guard arrivedCount < participantCount else {
            let waitingTasks = waiters
            waiters.removeAll()
            for waiter in waitingTasks {
                waiter.resume()
            }
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
