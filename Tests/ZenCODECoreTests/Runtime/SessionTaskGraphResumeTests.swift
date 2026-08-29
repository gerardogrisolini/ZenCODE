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
    func savedPlanDraftIsDiscoverableWithoutLookingLikeInterruptedWork() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let writer = SessionTaskOrchestrator(store: store)
        let savedAt = Date(timeIntervalSince1970: 200)
        let plan = TerminalSessionPlan(
            id: "plan-saved",
            originalGoal: "Persist a plan",
            consolidatedText: "Inspect, implement, and test.",
            createdAt: Date(timeIntervalSince1970: 100),
            points: [
                TerminalSessionPlanPoint(id: "plan-saved-1", text: "Inspect")
            ]
        )
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: working
        )
        try await writer.registerSession(
            id: librarySessionID,
            workingDirectory: working
        )
        _ = try await writer.savePlanDraft(
            TaskGraphSavedPlan(
                plan: plan,
                savedAt: savedAt,
                savingAgentName: "Planner"
            ),
            sessionID: librarySessionID,
            tasks: [TaskDefinition(id: "plan-saved-1", title: "Inspect")]
        )

        let reader = SessionTaskOrchestrator(store: store)
        #expect(await reader.resumableTaskGraphCheckpoints(
            workingDirectory: working
        ).isEmpty)
        let savedPlans = await reader.savedTaskPlans(workingDirectory: working)
        let saved = try #require(savedPlans.first)
        #expect(saved.librarySessionID == librarySessionID)
        #expect(saved.graph.id == plan.id)
        #expect(saved.snapshot.plan == plan)
        #expect(saved.snapshot.savedAt == savedAt)
        #expect(saved.snapshot.savingAgentName == "Planner")
        let otherProject = root.appendingPathComponent("other-project", isDirectory: true)
        #expect(await reader.savedTaskPlans(workingDirectory: otherProject).isEmpty)
    }

    @Test
    func savedPlanEnumerationSkipsMalformedPointMetadata() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: working
        )
        let malformedPlan = TerminalSessionPlan(
            id: "plan-malformed",
            originalGoal: "Malformed plan",
            consolidatedText: "Duplicate point identifiers",
            points: [
                TerminalSessionPlanPoint(id: "plan-malformed-1", text: "First"),
                TerminalSessionPlanPoint(id: "plan-malformed-1", text: "Duplicate"),
            ]
        )
        let graph = TaskGraphSnapshot(
            id: malformedPlan.id,
            source: .plan(planID: malformedPlan.id),
            state: .draft,
            tasks: [TaskRecord(id: "plan-malformed-1", title: "First", order: 1)],
            savedPlan: TaskGraphSavedPlan(plan: malformedPlan)
        )
        try store.save(
            SessionTaskGraphCheckpoint(
                sessionID: librarySessionID,
                currentGraphID: nil,
                graphs: [graph]
            ),
            workingDirectory: working
        )

        let reader = SessionTaskOrchestrator(store: store)
        #expect(await reader.savedTaskPlans(workingDirectory: working).isEmpty)
    }

    @Test
    func taskGraphWithoutSavedPlanStillDecodesAsSchemaOne() throws {
        let graph = TaskGraphSnapshot(
            id: "legacy-graph",
            source: .manual,
            state: .draft,
            tasks: [TaskRecord(id: "task", title: "Task", order: 1)]
        )
        let encoder = PropertyListEncoder()
        let data = try encoder.encode(graph)
        let propertyList = try #require(
            try PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
            ) as? [String: Any]
        )
        #expect(propertyList["savedPlan"] == nil)

        let decoded = try PropertyListDecoder().decode(
            TaskGraphSnapshot.self,
            from: data
        )
        #expect(decoded == graph)
        #expect(decoded.savedPlan == nil)
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
    func resumeScanDeletesLegacyTerminalOnlyOrdinaryCheckpoint() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let terminal = TaskGraphSnapshot(
            id: "terminal",
            source: .manual,
            state: .completed,
            tasks: [TaskRecord(id: "done", title: "Done", order: 1, status: .completed)]
        )
        try store.save(
            SessionTaskGraphCheckpoint(
                sessionID: "legacy-terminal",
                currentGraphID: terminal.id,
                graphs: [terminal]
            ),
            workingDirectory: working
        )

        let reader = SessionTaskOrchestrator(store: store)
        #expect(await reader.resumableTaskGraphCheckpoints(workingDirectory: working).isEmpty)
        #expect(try store.load(sessionID: "legacy-terminal", workingDirectory: working) == nil)
    }

    @Test
    func resumeScanCompactsLegacyMixedOrdinaryCheckpoint() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let terminal = TaskGraphSnapshot(
            id: "terminal",
            source: .manual,
            state: .completed,
            tasks: [TaskRecord(id: "done", title: "Done", order: 1, status: .completed)]
        )
        let resumable = TaskGraphSnapshot(
            id: "resume",
            source: .manual,
            state: .active,
            tasks: [TaskRecord(id: "pending", title: "Pending", order: 1)]
        )
        try store.save(
            SessionTaskGraphCheckpoint(
                sessionID: "legacy-mixed",
                currentGraphID: terminal.id,
                graphs: [terminal, resumable]
            ),
            workingDirectory: working
        )

        let reader = SessionTaskOrchestrator(store: store)
        let discovered = await reader.resumableTaskGraphCheckpoints(workingDirectory: working)
        #expect(discovered.map(\.graphID) == [resumable.id])
        let compacted = try #require(
            try store.load(sessionID: "legacy-mixed", workingDirectory: working)
        )
        #expect(compacted.graphs == [resumable])
        #expect(compacted.currentGraphID == nil)
    }

    @Test
    func resumeScanNeverPrunesSavedPlanNamespace() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let terminal = TaskGraphSnapshot(
            id: "saved-terminal",
            source: .manual,
            state: .completed,
            tasks: [TaskRecord(id: "done", title: "Done", order: 1, status: .completed)]
        )
        let checkpoint = SessionTaskGraphCheckpoint(
            sessionID: "saved-plans-legacy-project-key",
            currentGraphID: terminal.id,
            graphs: [terminal],
            savedAt: Date(timeIntervalSince1970: 123)
        )
        try store.save(checkpoint, workingDirectory: working)

        let reader = SessionTaskOrchestrator(store: store)
        #expect(await reader.resumableTaskGraphCheckpoints(workingDirectory: working).isEmpty)
        #expect(
            try store.load(
                sessionID: checkpoint.sessionID,
                workingDirectory: working
            ) == checkpoint
        )
    }

    @Test
    func staleLegacyCleanupDoesNotOverwriteNewerWriterCheckpoint() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let terminal = TaskGraphSnapshot(
            id: "terminal",
            source: .manual,
            state: .completed,
            tasks: [TaskRecord(id: "done", title: "Done", order: 1, status: .completed)]
        )
        let stale = SessionTaskGraphCheckpoint(
            sessionID: "race",
            currentGraphID: terminal.id,
            graphs: [terminal]
        )
        try store.save(stale, workingDirectory: working)
        let newerGraph = TaskGraphSnapshot(
            id: "new-work",
            source: .manual,
            state: .active,
            tasks: [TaskRecord(id: "pending", title: "Pending", order: 1)]
        )
        let newer = SessionTaskGraphCheckpoint(
            sessionID: stale.sessionID,
            currentGraphID: newerGraph.id,
            graphs: [newerGraph]
        )
        // Simulate another runtime publishing after the scanner loaded `stale`.
        try store.save(newer, workingDirectory: working)

        let reader = SessionTaskOrchestrator(store: store)
        await reader.pruneLegacyCheckpoint(
            stale,
            keeping: [],
            workingDirectory: working,
            store: store
        )
        #expect(try store.load(sessionID: stale.sessionID, workingDirectory: working) == newer)
    }

    @Test
    func ordinaryCheckpointPrunesTerminalGraphsAndDeletesWhenNothingIsResumable() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        try await orchestrator.registerSession(id: "session", workingDirectory: working)
        _ = try await orchestrator.createGraph(
            sessionID: "session",
            id: "first",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "first-task", title: "First")]
        )
        _ = try await orchestrator.createGraph(
            sessionID: "session",
            id: "second",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "second-task", title: "Second")]
        )

        // Starting the second graph archives the first. Its terminal history
        // stays in memory but cannot accumulate in the recovery checkpoint.
        let checkpoint = try #require(
            try store.load(sessionID: "session", workingDirectory: working)
        )
        #expect(checkpoint.graphs.map(\.id) == ["second"])
        #expect(checkpoint.currentGraphID == "second")

        _ = try await orchestrator.archiveGraph(id: "second", sessionID: "session")
        // No graph can be restored, so remove the ordinary checkpoint entirely.
        #expect(
            try store.load(sessionID: "session", workingDirectory: working) == nil
        )
    }

    @Test
    func completingOrdinaryGraphDeletesItsRecoveryCheckpoint() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        try await orchestrator.registerSession(id: "session", workingDirectory: working)
        _ = try await orchestrator.createGraph(
            sessionID: "session",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task", title: "Task")]
        )
        _ = try await orchestrator.updateTask(
            sessionID: "session",
            taskID: "task",
            graphID: "graph",
            update: TaskUpdate(status: .inProgress, output: "started")
        )
        _ = try await orchestrator.updateTask(
            sessionID: "session",
            taskID: "task",
            graphID: "graph",
            update: TaskUpdate(status: .completed, output: "done")
        )

        #expect(
            try store.load(sessionID: "session", workingDirectory: working) == nil
        )
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
    func concurrentOrchestratorsRejectStaleCheckpointInsteadOfLosingUpdate() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let first = SessionTaskOrchestrator(store: store)
        let stale = SessionTaskOrchestrator(store: store)
        try await first.registerSession(id: "shared-session", workingDirectory: working)
        try await stale.registerSession(id: "shared-session", workingDirectory: working)

        _ = try await first.createGraph(
            sessionID: "shared-session",
            id: "first-plan",
            source: .manual,
            tasks: [TaskDefinition(id: "first", title: "First")]
        )

        await #expect(throws: SessionTaskGraphStoreError.self) {
            _ = try await stale.createGraph(
                sessionID: "shared-session",
                id: "stale-plan",
                source: .manual,
                tasks: [TaskDefinition(id: "stale", title: "Stale")]
            )
        }

        let loadedCheckpoint = try store.load(
            sessionID: "shared-session",
            workingDirectory: working
        )
        let checkpoint = try #require(loadedCheckpoint)
        #expect(checkpoint.graphs.map(\.id) == ["first-plan"])
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
