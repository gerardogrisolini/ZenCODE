//
//  ProjectStorageKeyTests.swift
//  ZenCODE
//
//  The name-based project key shared by the per-project stores. Every test
//  runs in throwaway directories and never touches the real `~/.zencode`.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct ProjectStorageKeyTests {
    /// A throwaway tree with a support directory and a helper to create
    /// project folders inside it.
    private struct Sandbox {
        let root: URL
        let support: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-project-key-\(UUID().uuidString)", isDirectory: true)
                .standardizedFileURL
            support = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        /// Creates (when `create`) and returns a folder under the sandbox.
        func folder(_ relativePath: String, create: Bool = true) throws -> URL {
            let url = root.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
            if create {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            return url
        }
    }

    // MARK: - Identity

    @Test
    func projectNameIsTheTrimmedPrecomposedFolderName() {
        #expect(ProjectStorageKey.projectName(for: URL(fileURLWithPath: "/work/App-Ist-3.0-IOS")) == "App-Ist-3.0-IOS")
        #expect(ProjectStorageKey.projectName(for: URL(fileURLWithPath: "/work/App/", isDirectory: true)) == "App")
        #expect(ProjectStorageKey.projectName(for: URL(fileURLWithPath: "/work/x/../App")) == "App")
        #expect(ProjectStorageKey.projectName(forPath: "/work/ App ") == "App")
        // Decomposed (NFD) and precomposed (NFC) spellings are the same project.
        let decomposed = ProjectStorageKey.projectName(forPath: "/work/Cafe\u{301}")
        #expect(decomposed == "Caf\u{E9}")
        #expect(decomposed.unicodeScalars.count == 4)
        // The filesystem root has no folder name: its path is its name.
        #expect(ProjectStorageKey.projectName(for: URL(fileURLWithPath: "/")) == "/")
    }

    @Test
    func keyIsAReadableStemPlusADigestOfTheExactName() {
        let key = ProjectStorageKey.key(forProjectName: "App-Ist-3.0-IOS")
        #expect(key.hasPrefix("App-Ist-3.0-IOS-"))
        let digest = String(key.dropFirst("App-Ist-3.0-IOS-".count))
        #expect(digest.count == 24)
        #expect(digest.allSatisfy { $0.isHexDigit })
        #expect(digest == String(Data("App-Ist-3.0-IOS".utf8).sha256Hex().prefix(24)))

        // The path does not matter, the name does (case-sensitively).
        #expect(
            ProjectStorageKey.key(for: URL(fileURLWithPath: "/a/App"))
                == ProjectStorageKey.key(for: URL(fileURLWithPath: "/b/c/App"))
        )
        #expect(ProjectStorageKey.key(forProjectName: "App") != ProjectStorageKey.key(forProjectName: "app"))
        #expect(
            ProjectStorageKey.key(for: URL(fileURLWithPath: "/w/Cafe\u{301}"))
                == ProjectStorageKey.key(for: URL(fileURLWithPath: "/w/Caf\u{E9}"))
        )

        // Unsafe characters are folded into the stem; the digest keeps names apart.
        let spaced = ProjectStorageKey.key(forProjectName: "My Project: v2")
        #expect(spaced.hasPrefix("My_Project_v2-"))
        #expect(spaced != ProjectStorageKey.key(forProjectName: "My Project/ v2"))
        #expect(ProjectStorageKey.key(forProjectName: "***").hasPrefix("project-"))
        let long = ProjectStorageKey.key(forProjectName: String(repeating: "a", count: 300))
        #expect(long.count == ProjectStorageKey.maximumStemLength + 1 + 24)

        // Never the global memory directory.
        for name in ["global", "/", String(repeating: "f", count: 64)] {
            let candidate = ProjectStorageKey.key(forProjectName: name)
            #expect(candidate != MemoryGraphLocation.globalDirectoryName)
            #expect(candidate.contains("-"))
        }
    }

    // MARK: - Project memory

    private static func writeMemory(content: String, workspace: URL, support: URL) async throws {
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            _ = try await MemoryService().writeEntryOutcome(content: content, target: .workspace(workspace))
        }
    }

    private static func memoryContents(workspace: URL, support: URL) async throws -> [String] {
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            try await MemoryService().readEntries(
                target: .workspace(workspace),
                includeArchived: false,
                offset: 0,
                limit: 20,
                filter: .none
            ).map(\.content)
        }
    }

    @Test
    func movedProjectKeepsItsMemory() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let original = try sandbox.folder("esselunga/App-Ist-3.0-IOS")
        try await Self.writeMemory(
            content: "Summary: the checkout flow uses the v3 API.",
            workspace: original,
            support: sandbox.support
        )
        let moved = try sandbox.folder("App-Ist-3.0-IOS", create: false)
        try FileManager.default.moveItem(at: original, to: moved)

        let contents = try await Self.memoryContents(workspace: moved, support: sandbox.support)
        #expect(contents.contains { $0.contains("checkout flow uses the v3 API") })
        #expect(
            MemoryGraphLocation.graphDirectoryURL(for: moved).lastPathComponent
                == ProjectStorageKey.key(for: moved)
        )
    }

    @Test
    func foldersWithTheSameNameShareOneMemoryAndOtherNamesDoNot() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let first = try sandbox.folder("a/App")
        let second = try sandbox.folder("b/App")
        let differentCase = try sandbox.folder("c/app")
        try await Self.writeMemory(
            content: "Summary: shared by every folder named App.",
            workspace: first,
            support: sandbox.support
        )

        let shared = try await Self.memoryContents(workspace: second, support: sandbox.support)
        #expect(shared.contains { $0.contains("shared by every folder named App") })
        // The name is compared case-sensitively.
        let other = try await Self.memoryContents(workspace: differentCase, support: sandbox.support)
        #expect(other.isEmpty)
    }

    // MARK: - Saved sessions

    private static func savedSession(name: String, workingDirectory: String) -> TerminalSavedSession {
        let history = [AgentRuntimeMessage(role: .user, content: "hello \(name)")]
        return TerminalSavedSession(
            name: name,
            sessionID: "session-\(name)",
            cacheKey: nil,
            workingDirectoryPath: workingDirectory,
            createdAt: Date(timeIntervalSince1970: 10),
            savedAt: Date(timeIntervalSince1970: 20),
            modelID: "m",
            agentID: nil,
            agentName: nil,
            selectedTools: [],
            selectedSkillIDs: [],
            thinkingSelection: nil,
            systemPrompt: nil,
            history: history,
            checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: "session-\(name)")
        )
    }

    @Test
    func savedSessionsFollowAMovedProjectAndAreSharedBySameNameFolders() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let original = try sandbox.folder("old/App")
        _ = try TerminalSessionStore.save(
            Self.savedSession(name: "fix navigation", workingDirectory: original.path),
            supportDirectoryURL: sandbox.support
        )

        let moved = try sandbox.folder("new/App")
        let sessions = try TerminalSessionStore.savedSessions(for: moved, supportDirectoryURL: sandbox.support)
        #expect(sessions.map(\.name) == ["fix navigation"])
        #expect(
            try TerminalSessionStore.load(
                name: "fix navigation",
                workingDirectory: moved,
                supportDirectoryURL: sandbox.support
            ).sessionID == "session-fix navigation"
        )
        // Another name, even differing only by case, is another project.
        let other = try sandbox.folder("new/app")
        #expect(try TerminalSessionStore.savedSessions(for: other, supportDirectoryURL: sandbox.support).isEmpty)
        #expect(
            TerminalChat.savedSessionCacheKey(name: "x", workingDirectory: original)
                == TerminalChat.savedSessionCacheKey(name: "x", workingDirectory: moved)
        )
    }

    // MARK: - Task graphs and saved plans

    @Test
    func taskGraphsAndSavedPlansFollowAMovedProject() async throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let original = try sandbox.folder("esselunga/App")
        let store = SessionTaskGraphStore(supportDirectoryURL: sandbox.support)
        let orchestrator = SessionTaskOrchestrator(store: store)

        let libraryID = SessionTaskOrchestrator.savedPlanLibrarySessionID(for: original)
        #expect(libraryID == "saved-plans-" + ProjectStorageKey.key(for: original))
        try await orchestrator.registerSession(id: libraryID, workingDirectory: original)
        let savedAt = Date(timeIntervalSince1970: 100)
        _ = try await orchestrator.savePlanDraft(
            TaskGraphSavedPlan(
                plan: TerminalSessionPlan(
                    id: "plan-aaaaaaaa-0001",
                    originalGoal: "Goal",
                    consolidatedText: "Goal. Inspect, implement, and validate.",
                    createdAt: savedAt,
                    points: [TerminalSessionPlanPoint(id: "plan-aaaaaaaa-0001-1", text: "Do it")]
                ),
                savedAt: savedAt,
                savingAgentName: "Planner"
            ),
            sessionID: libraryID,
            tasks: [TaskDefinition(id: "plan-aaaaaaaa-0001-1", title: "Do it")]
        )
        let chat = SessionTaskGraphCheckpoint(
            sessionID: "chat-1",
            currentGraphID: nil,
            graphs: [],
            savedAt: Date(timeIntervalSince1970: 50)
        )
        try store.save(chat, workingDirectory: original)

        let moved = try sandbox.folder("App", create: false)
        try FileManager.default.moveItem(at: original, to: moved)

        #expect(SessionTaskOrchestrator.savedPlanLibrarySessionID(for: moved) == libraryID)
        let plans = await orchestrator.savedTaskPlans(workingDirectory: moved)
        #expect(plans.map(\.graph.id) == ["plan-aaaaaaaa-0001"])
        #expect(try store.load(sessionID: "chat-1", workingDirectory: moved) == chat)
        #expect(
            store.taskGraphsDirectoryURL(workingDirectory: moved).lastPathComponent
                == ProjectStorageKey.key(for: moved)
        )
    }

    // MARK: - Saved-session index

    @Test
    func savedSessionIndexKeepsOneEntryPerProjectName() throws {
        let sandbox = try Sandbox()
        defer { sandbox.remove() }
        let index = SavedSessionsStore(directoryURL: sandbox.support)
        try index.recordSavedSession(
            projectPath: "/esselunga/App", sessionName: "a", sessionID: "1",
            savedAt: Date(timeIntervalSince1970: 1)
        )
        try index.recordSavedSession(
            projectPath: "/work/Other", sessionName: "b", sessionID: "2",
            savedAt: Date(timeIntervalSince1970: 2)
        )
        try index.recordSavedSession(
            projectPath: "/Projects/App", sessionName: "c", sessionID: "3",
            savedAt: Date(timeIntervalSince1970: 3)
        )

        #expect(index.sessions().map(\.projectPath) == ["/Projects/App", "/work/Other"])
        #expect(index.sessions().first?.sessionName == "c")

        let data = try Data(contentsOf: index.sessionsFileURL())
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(json.keys) == ["version", "sessions"])
    }
}
