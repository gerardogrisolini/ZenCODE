import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct SessionTaskGraphResumeTests {
    private func makeTemp() throws -> (
        root: URL,
        support: URL,
        working: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SessionTaskGraphResumeTests-\(UUID().uuidString)",
                isDirectory: true
            )
        let support = root.appendingPathComponent("support", isDirectory: true)
        let working = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: working,
            withIntermediateDirectories: true
        )
        return (root, support, working)
    }

    @Test
    func storeEnumeratesValidCheckpointsAndSkipsCorrupt() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let writer = SessionTaskOrchestrator(store: store)

        try await writer.registerSession(id: "session-one", workingDirectory: working)
        _ = try await writer.createGraph(
            sessionID: "session-one",
            id: "graph-one",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "a", title: "A")]
        )
        try await writer.registerSession(id: "session-two", workingDirectory: working)
        _ = try await writer.createGraph(
            sessionID: "session-two",
            id: "graph-two",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "b", title: "B")]
        )

        // A corrupt plist file must not break enumeration.
        let directory = store.taskGraphsDirectoryURL(workingDirectory: working)
        let corruptURL = directory.appendingPathComponent("garbage.plist")
        try Data("not a plist".utf8).write(to: corruptURL)

        let checkpoints = store.loadCheckpoints(workingDirectory: working)
        let sessionIDs = Set(checkpoints.map(\.sessionID))
        #expect(sessionIDs == ["session-one", "session-two"])
        #expect(checkpoints.count == 2)
    }

    @Test
    func resumableCheckpointsFilterToIncompleteGraphsWithPendingTasks() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let now = Date()

        // Active graph with two pending tasks → resumable.
        let activeGraph = TaskGraphSnapshot(
            id: "active-graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskRecord(id: "a", title: "A", order: 1, status: .pending),
                TaskRecord(id: "b", title: "B", order: 2, status: .pending),
            ],
            createdAt: now,
            updatedAt: now
        )
        try store.save(
            SessionTaskGraphCheckpoint(
                sessionID: "active-session",
                currentGraphID: "active-graph",
                graphs: [activeGraph]
            ),
            workingDirectory: working
        )

        // Completed graph → not resumable.
        let completedGraph = TaskGraphSnapshot(
            id: "done-graph",
            source: .manual,
            state: .completed,
            tasks: [TaskRecord(id: "c", title: "C", order: 1, status: .completed)],
            createdAt: now,
            updatedAt: now
        )
        try store.save(
            SessionTaskGraphCheckpoint(
                sessionID: "done-session",
                currentGraphID: "done-graph",
                graphs: [completedGraph]
            ),
            workingDirectory: working
        )

        let reader = SessionTaskOrchestrator(store: store)
        let resumable = await reader.resumableTaskGraphCheckpoints(
            workingDirectory: working
        )
        #expect(resumable.count == 1)
        let only = try #require(resumable.first)
        #expect(only.sessionID == "active-session")
        #expect(only.graphID == "active-graph")
        #expect(only.state == .active)
        #expect(only.totalTaskCount == 2)
        #expect(only.pendingTaskCount == 2)
    }

    @Test
    func activeGraphWithOnlyCompletedTasksIsNotResumable() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let now = Date()
        let graph = TaskGraphSnapshot(
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskRecord(id: "a", title: "A", order: 1, status: .completed)],
            createdAt: now,
            updatedAt: now
        )
        try store.save(
            SessionTaskGraphCheckpoint(
                sessionID: "session",
                currentGraphID: "graph",
                graphs: [graph]
            ),
            workingDirectory: working
        )

        let reader = SessionTaskOrchestrator(store: store)
        let resumable = await reader.resumableTaskGraphCheckpoints(
            workingDirectory: working
        )
        #expect(resumable.isEmpty)
    }

    @Test
    func storelessOrchestratorReturnsNoResumableGraphs() async {
        let orchestrator = SessionTaskOrchestrator(store: nil)
        let resumable = await orchestrator.resumableTaskGraphCheckpoints(
            workingDirectory: URL(fileURLWithPath: "/tmp/does-not-matter")
        )
        #expect(resumable.isEmpty)
    }

    @Test
    func registeringResumedSessionIDRestoresTheGraph() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let writer = SessionTaskOrchestrator(store: store)
        try await writer.registerSession(id: "previous-session", workingDirectory: working)
        _ = try await writer.createGraph(
            sessionID: "previous-session",
            id: "unfinished",
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "task",
                    title: "Task",
                    execution: TaskExecutionSpec(executor: .subAgent)
                )
            ]
        )

        // A fresh process scans the store and picks the resumed session ID.
        let detector = SessionTaskOrchestrator(store: store)
        let resumable = await detector.resumableTaskGraphCheckpoints(
            workingDirectory: working
        )
        let chosen = try #require(resumable.first)

        let continuation = SessionTaskOrchestrator(store: store)
        try await continuation.registerSession(
            id: chosen.sessionID,
            workingDirectory: working
        )
        let graph = try await continuation.graphSnapshot(
            sessionID: chosen.sessionID
        )
        #expect(graph?.id == "unfinished")
        #expect(graph?.tasks.count == 1)
        // Active attempts are interrupted during restore.
        #expect(graph?.state == .active)
    }

    @Test
    func resumingASelectedGraphMakesThatExactGraphCurrent() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let now = Date()
        let previouslyCurrent = TaskGraphSnapshot(
            id: "previous-current",
            source: .manual,
            state: .active,
            tasks: [TaskRecord(id: "old", title: "Old", order: 1, status: .pending)],
            createdAt: now,
            updatedAt: now
        )
        let selected = TaskGraphSnapshot(
            id: "selected",
            source: .manual,
            state: .draft,
            tasks: [TaskRecord(id: "chosen", title: "Chosen", order: 1, status: .pending)],
            createdAt: now,
            updatedAt: now.addingTimeInterval(1)
        )
        try store.save(
            SessionTaskGraphCheckpoint(
                sessionID: "previous-session",
                currentGraphID: previouslyCurrent.id,
                graphs: [previouslyCurrent, selected]
            ),
            workingDirectory: working
        )

        let orchestrator = SessionTaskOrchestrator(store: store)
        let candidates = await orchestrator.resumableTaskGraphCheckpoints(
            workingDirectory: working
        )
        let choice = try #require(candidates.first { $0.graphID == selected.id })
        let resumed = try await orchestrator.resumeTaskGraph(
            choice,
            workingDirectory: working
        )

        #expect(resumed.id == selected.id)
        #expect(resumed.state == .active)
        #expect(try await orchestrator.graphSnapshot(sessionID: "previous-session")?.id == selected.id)
        #expect(
            try await orchestrator.graphSnapshot(
                sessionID: "previous-session",
                graphID: previouslyCurrent.id
            )?.state == .archived
        )
        // `AgentCoreSessionRunner.createSession` registers the same session
        // again; that must not restore the checkpoint's former current graph.
        try await orchestrator.registerSession(
            id: "previous-session",
            workingDirectory: working
        )
        #expect(try await orchestrator.graphSnapshot(sessionID: "previous-session")?.id == selected.id)
        let checkpoint = try #require(
            try store.load(sessionID: "previous-session", workingDirectory: working)
        )
        #expect(checkpoint.currentGraphID == selected.id)
    }

    @Test
    func removingSelectedResumableGraphsPreservesOtherGraphs() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let now = Date()
        let obsoleteGraph = TaskGraphSnapshot(
            id: "obsolete",
            source: .manual,
            state: .active,
            tasks: [TaskRecord(id: "old", title: "Old", order: 1, status: .pending)],
            createdAt: now,
            updatedAt: now
        )
        let keepGraph = TaskGraphSnapshot(
            id: "keep",
            source: .manual,
            state: .active,
            tasks: [TaskRecord(id: "new", title: "New", order: 1, status: .pending)],
            createdAt: now,
            updatedAt: now
        )
        try store.save(
            SessionTaskGraphCheckpoint(
                sessionID: "previous-session",
                currentGraphID: "keep",
                graphs: [obsoleteGraph, keepGraph]
            ),
            workingDirectory: working
        )

        let cleaner = SessionTaskOrchestrator(store: store)
        let resumable = await cleaner.resumableTaskGraphCheckpoints(
            workingDirectory: working
        )
        let obsolete = try #require(resumable.first { $0.graphID == "obsolete" })
        try await cleaner.removeResumableTaskGraphs(
            [obsolete],
            workingDirectory: working
        )

        let remaining = await cleaner.resumableTaskGraphCheckpoints(
            workingDirectory: working
        )
        #expect(remaining.map(\.graphID) == ["keep"])
        let loadedCheckpoint = try store.load(
            sessionID: "previous-session",
            workingDirectory: working
        )
        let checkpoint = try #require(loadedCheckpoint)
        #expect(checkpoint.graphs.map(\.id) == ["keep"])
    }
}
