//
//  MLXMemoryServiceTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 27/05/26.
//

import Foundation
import ZenCODECore
import Testing

@Suite
struct MLXMemoryServiceTests {
    @Test
    func memoryTemplatesDescribeGlobalAndProjectResponsibilities() {
        #expect(MLXMemoryService.defaultGlobalMemoryContent.contains("Lightweight global project index"))
        #expect(MLXMemoryService.defaultGlobalMemoryContent.contains("saved-session pointers keyed by project"))
        #expect(MLXMemoryService.defaultGlobalMemoryContent.contains("latest saved session name/id for each project"))
        #expect(MLXMemoryService.defaultGlobalMemoryContent.contains("user preferences or operating rules"))
        #expect(MLXMemoryService.defaultProjectMemoryContent.contains("Durable project journal"))
        #expect(MLXMemoryService.defaultProjectMemoryContent.contains("Timestamp: YYYY-MM-DD HH:mm TimeZone"))
        #expect(MLXMemoryService.toolUsagePromptSection().contains("project memory as the codebase journal"))
        #expect(MLXMemoryService.toolUsagePromptSection().contains("global memory only as a lightweight project/session index"))
        #expect(MLXMemoryService.toolUsagePromptSection().contains("one active saved-session pointer per project"))
        #expect(MLXMemoryService.toolUsagePromptSection().contains("At the end of a substantial project turn"))

        let projectDefault = MLXProjectContextFileService.defaultContent(
            kind: .memory,
            projectName: "TestProject",
            rootPath: "/tmp/TestProject"
        )
        #expect(projectDefault == MLXMemoryService.defaultProjectMemoryContent)
    }

    @Test
    func templateGuidanceBulletsAreNotParsedAsMemoryEntries() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-memory-tests-\(UUID().uuidString)", isDirectory: true)
        let globalDirectoryURL = rootURL.appendingPathComponent("global", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let service = MLXMemoryService(globalMemoryDirectoryURL: globalDirectoryURL)
        try service.ensureGlobalMemoryFileExists()
        try MLXMemoryService.defaultProjectMemoryContent
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .appending("\n")
            .write(
                to: workspaceURL.appendingPathComponent(MLXMemoryService.filename),
                atomically: true,
                encoding: .utf8
            )

        #expect(
            service.readEntries(
                scope: .global,
                workspaceRootURL: workspaceURL,
                limit: 10
            ).isEmpty
        )
        #expect(
            service.readEntries(
                scope: .project,
                workspaceRootURL: workspaceURL,
                limit: 10
            ).isEmpty
        )
    }

    @Test
    func globalAndProjectWritesUseDifferentMemoryTemplates() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-memory-tests-\(UUID().uuidString)", isDirectory: true)
        let globalDirectoryURL = rootURL.appendingPathComponent("global", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let service = MLXMemoryService(globalMemoryDirectoryURL: globalDirectoryURL)

        try service.writeEntry(
            content: "Last project: \(workspaceURL.path)",
            scope: .global,
            workspaceRootURL: workspaceURL
        )
        try service.writeEntry(
            content: "Summary: use direct ZenCODE runtime inside mlx-server.",
            scope: .project,
            workspaceRootURL: workspaceURL
        )

        let globalContent = try String(contentsOf: service.globalMemoryFileURL(), encoding: .utf8)
        let projectContent = try String(
            contentsOf: workspaceURL.appendingPathComponent(MLXMemoryService.filename),
            encoding: .utf8
        )

        #expect(globalContent.contains("Lightweight global project index"))
        #expect(globalContent.contains("Last project: \(workspaceURL.path)"))
        #expect(projectContent.contains("Durable project journal"))
        #expect(projectContent.contains("Summary: use direct ZenCODE runtime inside mlx-server."))
        #expect(
            service.readEntries(
                scope: .global,
                workspaceRootURL: workspaceURL,
                limit: 10
            ).count == 1
        )
        #expect(
            service.readEntries(
                scope: .project,
                workspaceRootURL: workspaceURL,
                limit: 10
            ).count == 1
        )
    }

    @Test
    func projectJournalWritesPreserveMultilineEntries() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-memory-tests-\(UUID().uuidString)", isDirectory: true)
        let globalDirectoryURL = rootURL.appendingPathComponent("global", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let service = MLXMemoryService(globalMemoryDirectoryURL: globalDirectoryURL)
        let journalContent = """
        Timestamp: 2026-06-03 11:45 Europe/Rome
        Summary: completed the memory journal framing.
        State: project journal is the resume source; global memory is only an index.
        Next: validate the real resume flow from a fresh session.
        """

        let entry = try service.writeEntry(
            content: journalContent,
            scope: .project,
            workspaceRootURL: workspaceURL
        )
        let projectContent = try String(
            contentsOf: workspaceURL.appendingPathComponent(MLXMemoryService.filename),
            encoding: .utf8
        )
        let readEntry = try #require(
            service.readEntries(
                scope: .project,
                workspaceRootURL: workspaceURL,
                limit: 10
            ).first
        )

        #expect(
            projectContent.contains(
                "- [id: \(entry.id.uuidString.uppercased())] Timestamp: 2026-06-03 11:45 Europe/Rome"
            )
        )
        #expect(projectContent.contains("\n  Summary: completed the memory journal framing."))
        #expect(projectContent.contains("\n  State: project journal is the resume source; global memory is only an index."))
        #expect(projectContent.contains("\n  Next: validate the real resume flow from a fresh session."))
        #expect(readEntry.content == journalContent)
    }

    @Test
    func memoryWriteAddsProjectTimestampWhenMissing() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-memory-tests-\(UUID().uuidString)", isDirectory: true)
        let globalDirectoryURL = rootURL.appendingPathComponent("global", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
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
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let service = MLXMemoryService(globalMemoryDirectoryURL: globalDirectoryURL)
        _ = try MLXMemoryTool.execute(
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
            context: MLXMemoryToolContext(
                workingDirectory: workspaceURL,
                currentDate: date,
                currentTimeZone: timeZone
            ),
            memoryService: service
        )
        let entry = try #require(
            service.readEntries(
                scope: .project,
                workspaceRootURL: workspaceURL,
                limit: 10
            ).first
        )

        #expect(entry.content.hasPrefix("Timestamp: 2026-06-04 15:35 Europe/Rome"))
        #expect(entry.content.contains("Summary: fixed the release install path."))
    }

    @Test
    func globalSavedSessionIndexKeepsLatestSessionPerProject() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-memory-tests-\(UUID().uuidString)", isDirectory: true)
        let globalDirectoryURL = rootURL.appendingPathComponent("global", isDirectory: true)
        let firstProjectURL = rootURL.appendingPathComponent("first", isDirectory: true)
        let secondProjectURL = rootURL.appendingPathComponent("second", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: firstProjectURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondProjectURL,
            withIntermediateDirectories: true
        )

        let service = MLXMemoryService(globalMemoryDirectoryURL: globalDirectoryURL)
        try service.recordSavedSessionIndexEntry(
            projectPath: firstProjectURL.path,
            sessionName: "first checkpoint",
            sessionID: "first-session-old",
            savedAt: Date(timeIntervalSince1970: 100),
            timeZone: TimeZone(identifier: "Europe/Rome")!
        )
        try service.recordSavedSessionIndexEntry(
            projectPath: secondProjectURL.path,
            sessionName: "second checkpoint",
            sessionID: "second-session",
            savedAt: Date(timeIntervalSince1970: 200),
            timeZone: TimeZone(identifier: "Europe/Rome")!
        )
        try service.recordSavedSessionIndexEntry(
            projectPath: firstProjectURL.path,
            sessionName: "first latest",
            sessionID: "first-session-new",
            savedAt: Date(timeIntervalSince1970: 300),
            timeZone: TimeZone(identifier: "Europe/Rome")!
        )

        let activeEntries = service.readEntries(
            scope: .global,
            workspaceRootURL: nil,
            includeArchived: false,
            limit: 10
        )
        let archivedEntries = service.readEntries(
            scope: .global,
            workspaceRootURL: nil,
            includeArchived: true,
            limit: 10
        )
        .filter(\.isArchived)

        #expect(activeEntries.count == 2)
        #expect(activeEntries.contains { $0.content.contains("Project: \(firstProjectURL.path)") })
        #expect(activeEntries.contains { $0.content.contains("Session: first latest") })
        #expect(activeEntries.contains { $0.content.contains("Project: \(secondProjectURL.path)") })
        #expect(activeEntries.contains { $0.content.contains("Session: second checkpoint") })
        #expect(!activeEntries.contains { $0.content.contains("first-session-old") })
        #expect(archivedEntries.count == 1)
        #expect(archivedEntries.first?.content.contains("first-session-old") == true)
    }

    @Test
    func memorySearchPrioritizesProjectEntriesWhenScopeIsAll() throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-memory-tests-\(UUID().uuidString)", isDirectory: true)
        let globalDirectoryURL = rootURL.appendingPathComponent("global", isDirectory: true)
        let workspaceURL = rootURL.appendingPathComponent("workspace", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: rootURL)
        }

        try FileManager.default.createDirectory(
            at: workspaceURL,
            withIntermediateDirectories: true
        )
        let service = MLXMemoryService(globalMemoryDirectoryURL: globalDirectoryURL)
        try service.writeEntry(
            content: "Last project: architecture-lab.",
            scope: .global,
            workspaceRootURL: workspaceURL
        )
        try service.writeEntry(
            content: "Summary: architecture runtime decision.",
            scope: .project,
            workspaceRootURL: workspaceURL
        )

        let output = try MLXMemoryTool.execute(
            ToolRequest(
                name: "memory.search",
                arguments: ["query": .string("architecture")]
            ),
            context: MLXMemoryToolContext(workingDirectory: workspaceURL),
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

    @Test
    func standalonePromptOmitsMemoryInstructionsWhenMemoryToolIsDisabled() {
        let prompt = AgentStandaloneSystemPrompt.prompt(
            cwd: "/tmp/project",
            memoryToolEnabled: false
        )

        #expect(!prompt.contains("Memory tools:"))
        #expect(!prompt.contains("`memory.write`"))
        #expect(!prompt.contains("memory, and delegated sub-agent tools"))
    }

    @Test
    func defaultAgentPromptFollowsActiveMemoryToolState() {
        let defaultAgent = AgentProfileStore.defaultProfiles()[0]
        let withoutMemory = AgentCoreAppSessionFactory.resolvedSystemPrompt(
            providedSystemPrompt: nil,
            cwd: "/tmp/project",
            selectedAgent: defaultAgent,
            allowedToolNames: []
        )
        let withMemory = AgentCoreAppSessionFactory.resolvedSystemPrompt(
            providedSystemPrompt: nil,
            cwd: "/tmp/project",
            selectedAgent: defaultAgent,
            allowedToolNames: ["memory.read", "memory.write"]
        )

        #expect(!withoutMemory.contains("Memory tools:"))
        #expect(!withoutMemory.contains("`memory.write`"))
        #expect(!withoutMemory.contains("memory, and delegated sub-agent tools"))
        #expect(withMemory.contains("Memory tools:"))
        #expect(withMemory.contains("`memory.write`"))
        #expect(withMemory.contains("memory, and delegated sub-agent tools"))
    }

    @Test
    func defaultAgentProfilesIncludeRecommendedOperatingModes() throws {
        let profiles = AgentProfileStore.defaultProfiles()
        let names = Set(profiles.map(\.name))

                #expect(names == Set([
            "Default",
            "Builder",
            "Minimal",
            "Xcode",
            "Reviewer",
            "Planner"
        ]))
        #expect(Set(profiles.map(\.id)).count == profiles.count)
        #expect(try AgentProfileStore.defaultProfile(in: profiles).name == "Default")
    }
}
