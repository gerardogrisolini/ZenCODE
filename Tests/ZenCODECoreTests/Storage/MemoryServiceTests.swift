//
//  MemoryServiceTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 27/05/26.
//
//  Graph-backed memory facade tests. The durable store is the MemoryEngine
//  graph; MEMORY.md is no longer written, only migrated in memory on first
//  open and persisted by the first mutation.
//

import Foundation
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
        #expect(MemoryService.toolUsagePromptSection().contains("release, version, or publication"))
        #expect(MemoryService.toolUsagePromptSection().contains("concrete evidence"))
        #expect(MemoryService.toolUsagePromptSection().contains("speculative plans"))
        #expect(MemoryService.defaultProjectMemoryContent.contains("release or publication record"))
        #expect(MemoryService.defaultProjectMemoryContent.contains("unverified claims"))
        #expect(MemoryService.defaultProjectMemoryContent.contains("durable milestone or change"))
        #expect(MemoryService.defaultProjectMemoryContent.contains("None currently"))
        #expect(MemoryService.toolUsagePromptSection().contains("architecture, compatibility, dependencies, or persisted formats"))
        #expect(MemoryService.toolUsagePromptSection().contains("perform the appropriate mutation before finishing"))
        #expect(MemoryService.toolUsagePromptSection().contains("version or changelog edit alone"))
    }

    @Test
    func readOnlyMemoryPromptDoesNotSuggestUnavailableMutations() {
        let prompt = MemoryService.toolUsagePromptSection(readOnly: true)

        #expect(prompt.contains("Memory tools (read-only):"))
        #expect(prompt.contains("do not claim to create, update, archive"))
        #expect(prompt.contains("memory.search"))
        #expect(!prompt.contains("Before writing"))
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
                    workingDirectory: workspace.workspaceURL,
                    currentDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentTimeZone: firstZone
                ),
                memoryService: service
            )
            let second = try await MemoryTool.executeAsync(
                ToolRequest(name: "memory.write", arguments: ["content": .string(content)]),
                context: MemoryToolContext(
                    workingDirectory: workspace.workspaceURL,
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
                    workspaceRootURL: workspace.workspaceURL,
                    limit: 10
                ).count == 1
            )
            // The surviving entry keeps the first turn's stamp verbatim: a
            // duplicate is reused, never rewritten.
            let stored = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
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
                    workingDirectory: workspace.workspaceURL,
                    currentDate: Date(timeIntervalSince1970: 1_700_000_000),
                    currentTimeZone: TimeZone(identifier: "Europe/Rome")!
                ),
                memoryService: service
            )
            let autoStamped = try await MemoryTool.executeAsync(
                ToolRequest(name: "memory.write", arguments: ["content": .string(body)]),
                context: MemoryToolContext(
                    workingDirectory: workspace.workspaceURL,
                    currentDate: Date(timeIntervalSince1970: 1_700_003_660),
                    currentTimeZone: TimeZone(identifier: "Europe/Rome")!
                ),
                memoryService: service
            )

            #expect(authored.rawResult?.objectValue?["written"]?.boolValue == true)
            #expect(autoStamped.rawResult?.objectValue?["written"]?.boolValue == true)
            let entries = try await service.readEntries(
                workspaceRootURL: workspace.workspaceURL,
                limit: 10
            )
            #expect(entries.count == 2)
            #expect(entries.contains { $0.content.hasPrefix("Timestamp: sprint kickoff") })
        }
    }

    @Test
    func machineShapedAuthoredTimestampKeepsAnEntryDistinctFromAnAutoStampedOne() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        let body = "Summary: release cut for 1.2.5."

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let context = MemoryToolContext(
                workingDirectory: workspace.workspaceURL,
                currentDate: Date(timeIntervalSince1970: 1_700_000_000),
                currentTimeZone: TimeZone(identifier: "Europe/Rome")!
            )
            let authored = try await MemoryTool.executeAsync(
                ToolRequest(
                    name: "memory.write",
                    arguments: ["content": .string("Timestamp: 2024-01-01 09:00 Europe/Rome\n\(body)")]
                ),
                context: context,
                memoryService: service
            )
            let autoStamped = try await MemoryTool.executeAsync(
                ToolRequest(name: "memory.write", arguments: ["content": .string(body)]),
                context: context,
                memoryService: service
            )

            #expect(authored.rawResult?.objectValue?["written"]?.boolValue == true)
            #expect(autoStamped.rawResult?.objectValue?["written"]?.boolValue == true)
            #expect(try await service.readEntries(workspaceRootURL: workspace.workspaceURL, limit: 10).count == 2)
        }
    }

    /// Two entries differing only inside a fenced code block are different
    /// entries, even when the differing line happens to look like the journal
    /// field.
    @Test
    func timestampInsideACodeBlockStaysSignificant() async throws {
        let workspace = try MemoryTestWorkspace()
        defer { workspace.remove() }
        func sample(_ value: String) -> String {
            """
            Summary: documented the log format.
            ```
            Timestamp: \(value)
            ```
            """
        }

        try await workspace.withIsolatedSupport {
            let service = MemoryService()
            let context = MemoryToolContext(
                workingDirectory: workspace.workspaceURL,
                currentDate: Date(timeIntervalSince1970: 1_700_000_000),
                currentTimeZone: TimeZone(identifier: "Europe/Rome")!
            )
            _ = try await MemoryTool.executeAsync(
                ToolRequest(
                    name: "memory.write",
                    arguments: ["content": .string(sample("2024-01-01 09:00 Europe/Rome"))]
                ),
                context: context,
                memoryService: service
            )
            let second = try await MemoryTool.executeAsync(
                ToolRequest(
                    name: "memory.write",
                    arguments: ["content": .string(sample("2025-02-02 10:00 Europe/Rome"))]
                ),
                context: context,
                memoryService: service
            )

            #expect(second.rawResult?.objectValue?["written"]?.boolValue == true)
            #expect(second.rawResult?.objectValue?["deduplicated"]?.boolValue == false)
            #expect(
                try await service.readEntries(
                    workspaceRootURL: workspace.workspaceURL,
                    limit: 10
                ).count == 2
            )
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
                workspaceRootURL: workspace.workspaceURL
            )
            let second = try await service.writeEntry(
                content: "Timestamp: 2025-02-02 10:00 Europe/Rome\nSummary: migrated the journal.",
                workspaceRootURL: workspace.workspaceURL
            )

            #expect(first.id != second.id)
            #expect(
                try await service.readEntries(
                    workspaceRootURL: workspace.workspaceURL,
                    limit: 10
                ).count == 2
            )
        }
    }

    /// Only the exact generated rendering is ignorable. A first line that
    /// merely starts with the field name is authored content.
    @Test
    func onlyTheGeneratedTimestampRenderingIsIgnorable() {
        #expect(MemoryAutoTimestamp.isGeneratedLine("Timestamp: 2024-01-01 09:00 Europe/Rome"))
        #expect(!MemoryAutoTimestamp.isGeneratedLine("Timestamp: 2024-01-01 09:00"))
        #expect(!MemoryAutoTimestamp.isGeneratedLine("Timestamp: 2024-01-01"))
        #expect(!MemoryAutoTimestamp.isGeneratedLine("Timestamp: yesterday"))
        #expect(!MemoryAutoTimestamp.isGeneratedLine("Timestamp: 2024-13-45 99:99 Europe/Rome"))
        #expect(!MemoryAutoTimestamp.isGeneratedLine("Timestamp: 2024-01-01 09:00 Not/AZone"))
        #expect(!MemoryAutoTimestamp.isGeneratedLine("timestamp: 2024-01-01 09:00 Europe/Rome"))
        #expect(!MemoryAutoTimestamp.isGeneratedLine("Updated: 2024-01-01 09:00 Europe/Rome"))

        // Only the first line, and only when something follows it.
        #expect(
            MemoryAutoTimestamp.strippingGeneratedLine(
                from: "Timestamp: 2024-01-01 09:00 Europe/Rome\nSummary: x"
            ) == "Summary: x"
        )
        #expect(
            MemoryAutoTimestamp.strippingGeneratedLine(
                from: "Summary: x\nTimestamp: 2024-01-01 09:00 Europe/Rome"
            ) == nil
        )
        #expect(
            MemoryAutoTimestamp.strippingGeneratedLine(
                from: "Timestamp: 2024-01-01 09:00 Europe/Rome"
            ) == nil
        )
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

            let output = try await MemoryTool.executeAsync(
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
            #expect(entry.trust == "medium")
            #expect(entry.source == "memory.write")
            #expect(entry.scope == .project)

            let read = try #require(
                try await service.entry(
                    id: entry.id.uuidString,
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
    func savedSessionsIndexCreatesPrivateFilesystemEntries() throws {
        #if canImport(Darwin) || canImport(Glibc)
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("saved-sessions-permissions-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let store = SavedSessionsStore(directoryURL: storeDirectoryURL)
        try store.recordSavedSession(
            projectPath: rootURL.appendingPathComponent("project", isDirectory: true).path,
            sessionName: "private checkpoint",
            sessionID: "private-session",
            savedAt: Date(timeIntervalSince1970: 1)
        )

        #expect(try savedSessionsPOSIXMode(of: storeDirectoryURL, fileManager: fileManager) == 0o700)
        #expect(try savedSessionsPOSIXMode(of: store.sessionsFileURL(), fileManager: fileManager) == 0o600)
        let filenames = try fileManager.contentsOfDirectory(atPath: storeDirectoryURL.path)
        #expect(!filenames.contains { $0.hasSuffix(".tmp") })
        #else
        return
        #endif
    }

    @Test
    func savedSessionsIndexTightensPermissiveExistingEntriesWithoutChangingData() throws {
        #if canImport(Darwin) || canImport(Glibc)
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("saved-sessions-permissions-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let store = SavedSessionsStore(directoryURL: storeDirectoryURL)
        try store.recordSavedSession(
            projectPath: rootURL.appendingPathComponent("project", isDirectory: true).path,
            sessionName: "legacy checkpoint",
            sessionID: "legacy-session",
            savedAt: Date(timeIntervalSince1970: 2)
        )
        let fileURL = store.sessionsFileURL()
        let originalData = try Data(contentsOf: fileURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: storeDirectoryURL.path
        )
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: fileURL.path
        )

        let sessions = store.sessions()

        #expect(sessions.count == 1)
        #expect(sessions.first?.sessionID == "legacy-session")
        #expect(try Data(contentsOf: fileURL) == originalData)
        #expect(try savedSessionsPOSIXMode(of: storeDirectoryURL, fileManager: fileManager) == 0o700)
        #expect(try savedSessionsPOSIXMode(of: fileURL, fileManager: fileManager) == 0o600)
        #else
        return
        #endif
    }

    @Test
    func savedSessionsIndexRejectsDestinationSymlinkWithoutTouchingTarget() throws {
        #if canImport(Darwin) || canImport(Glibc)
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("saved-sessions-permissions-\(UUID().uuidString)", isDirectory: true)
        let storeDirectoryURL = rootURL.appendingPathComponent("store", isDirectory: true)
        let targetURL = rootURL.appendingPathComponent("unrelated.json")
        defer { try? fileManager.removeItem(at: rootURL) }

        try fileManager.createDirectory(at: storeDirectoryURL, withIntermediateDirectories: true)
        let targetData = Data("unrelated target".utf8)
        try targetData.write(to: targetURL)
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: 0o644)],
            ofItemAtPath: targetURL.path
        )
        try fileManager.createSymbolicLink(
            at: storeDirectoryURL.appendingPathComponent(SavedSessionsStore.filename),
            withDestinationURL: targetURL
        )

        let store = SavedSessionsStore(directoryURL: storeDirectoryURL)
        do {
            try store.recordSavedSession(
                projectPath: rootURL.appendingPathComponent("project", isDirectory: true).path,
                sessionName: "should fail",
                sessionID: "symlink-session",
                savedAt: Date(timeIntervalSince1970: 3)
            )
            Issue.record("Saved sessions must reject a destination symlink.")
        } catch {
            // Expected: SensitiveFilePermissions fails closed for symlinks.
        }

        #expect(try Data(contentsOf: targetURL) == targetData)
        #expect(try savedSessionsPOSIXMode(of: targetURL, fileManager: fileManager) == 0o644)
        #else
        return
        #endif
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
    func standalonePromptReflectsMemoryToolSurface() {
        let readOnlyPrompt = AgentStandaloneSystemPrompt.prompt(
            cwd: "/tmp/project",
            memoryToolEnabled: true,
            allowedToolNames: ["memory.read", "memory.search"]
        )
        let mutatingPrompt = AgentStandaloneSystemPrompt.prompt(
            cwd: "/tmp/project",
            memoryToolEnabled: true,
            allowedToolNames: ["memory.read", "memory.write"]
        )
        let withoutMemoryPrompt = AgentStandaloneSystemPrompt.prompt(
            cwd: "/tmp/project",
            memoryToolEnabled: false
        )

        #expect(readOnlyPrompt.contains("Memory tools (read-only):"))
        #expect(readOnlyPrompt.contains("do not claim to create, update, archive"))
        #expect(!readOnlyPrompt.contains("Before writing"))
        #expect(mutatingPrompt.contains("Memory tools:"))
        #expect(!mutatingPrompt.contains("Memory tools (read-only):"))
        #expect(mutatingPrompt.contains("`memory.write`"))
        #expect(!withoutMemoryPrompt.contains("Memory tools:"))
        #expect(!withoutMemoryPrompt.contains("`memory.write`"))
        #expect(!withoutMemoryPrompt.contains("memory, feature, and delegated sub-agent tools"))
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


#if canImport(Darwin) || canImport(Glibc)
private func savedSessionsPOSIXMode(of url: URL, fileManager: FileManager) throws -> Int {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    guard let permissions = attributes[.posixPermissions] as? NSNumber else {
        throw SavedSessionsPOSIXTestError.missingPermissions(url)
    }
    return permissions.intValue & 0o777
}

private enum SavedSessionsPOSIXTestError: Error {
    case missingPermissions(URL)
}
#endif

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
