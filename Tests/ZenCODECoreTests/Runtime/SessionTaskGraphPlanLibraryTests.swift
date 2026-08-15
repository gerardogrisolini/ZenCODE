import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct SessionTaskGraphPlanLibraryTests {
    private func makeTemp() throws -> (
        root: URL,
        support: URL,
        working: URL
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SessionTaskGraphPlanLibraryTests-\(UUID().uuidString)",
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

    private func makeSavedPlan(
        id: String,
        goal: String,
        savedAt: Date
    ) -> TaskGraphSavedPlan {
        TaskGraphSavedPlan(
            plan: TerminalSessionPlan(
                id: id,
                originalGoal: goal,
                consolidatedText: "\(goal). Inspect, implement, and validate.",
                createdAt: savedAt,
                points: [
                    TerminalSessionPlanPoint(id: "\(id)-1", text: "Do \(goal)")
                ]
            ),
            savedAt: savedAt,
            savingAgentName: "Planner"
        )
    }

    @discardableResult
    private func saveDraft(
        _ orchestrator: SessionTaskOrchestrator,
        savedPlan: TaskGraphSavedPlan,
        working: URL
    ) async throws -> TaskGraphSnapshot {
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: working
        )
        try await orchestrator.registerSession(
            id: librarySessionID,
            workingDirectory: working
        )
        return try await orchestrator.savePlanDraft(
            savedPlan,
            sessionID: librarySessionID,
            tasks: [
                TaskDefinition(
                    id: "\(savedPlan.plan.id)-1",
                    title: "Do \(savedPlan.plan.originalGoal)"
                )
            ]
        )
    }

    /// Drives a live plan graph to completion so the library mirror path in
    /// `commit` runs exactly as it does in production.
    @discardableResult
    private func completeLivePlanGraph(
        _ orchestrator: SessionTaskOrchestrator,
        planID: String,
        sessionID: String,
        working: URL
    ) async throws -> TaskGraphSnapshot {
        try await orchestrator.registerSession(
            id: sessionID,
            workingDirectory: working
        )
        _ = try await orchestrator.createGraph(
            sessionID: sessionID,
            id: planID,
            source: .plan(planID: planID),
            state: .active,
            tasks: [
                TaskDefinition(id: "\(planID)-1", title: "Do the work")
            ]
        )
        _ = try await orchestrator.updateTask(
            sessionID: sessionID,
            taskID: "\(planID)-1",
            graphID: planID,
            update: TaskUpdate(status: .inProgress, output: "started")
        )
        _ = try await orchestrator.updateTask(
            sessionID: sessionID,
            taskID: "\(planID)-1",
            graphID: planID,
            update: TaskUpdate(status: .completed, output: "done")
        )
        guard let graph = try await orchestrator.graphSnapshot(
            sessionID: sessionID,
            graphID: planID
        ) else {
            throw SessionTaskOrchestratorError.graphNotFound(planID)
        }
        return graph
    }

    @Test
    func deleteSavedTaskPlansRemovesOnlyRequestedPlansAndDiscardsEmptyLibrary() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        let first = makeSavedPlan(
            id: "plan-aaaaaaaa-1111",
            goal: "First plan",
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let second = makeSavedPlan(
            id: "plan-bbbbbbbb-2222",
            goal: "Second plan",
            savedAt: Date(timeIntervalSince1970: 200)
        )
        try await saveDraft(orchestrator, savedPlan: first, working: working)
        try await saveDraft(orchestrator, savedPlan: second, working: working)

        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: working
        )

        let firstDeletion = try await orchestrator.deleteSavedTaskPlans(
            planIDs: [first.plan.id],
            workingDirectory: working
        )
        #expect(firstDeletion == [first.plan.id])
        #expect(
            await orchestrator.savedTaskPlans(workingDirectory: working)
                .map(\.graph.id) == [second.plan.id]
        )
        // The library checkpoint survives while another plan remains.
        #expect(
            try store.load(
                sessionID: librarySessionID,
                workingDirectory: working
            ) != nil
        )

        let secondDeletion = try await orchestrator.deleteSavedTaskPlans(
            planIDs: [second.plan.id],
            workingDirectory: working
        )
        #expect(secondDeletion == [second.plan.id])
        #expect(
            await orchestrator.savedTaskPlans(workingDirectory: working).isEmpty
        )
        // Deleting the last usable plan leaves no empty library residue.
        #expect(
            try store.load(
                sessionID: librarySessionID,
                workingDirectory: working
            ) == nil
        )
    }

    @Test
    func deleteSavedTaskPlansIgnoresUnknownAndDuplicateIDsAndCreatesNoLibrary() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: working
        )

        // Unknown ids on an empty library neither fail nor create a checkpoint.
        #expect(
            try await orchestrator.deleteSavedTaskPlans(
                planIDs: ["plan-missing"],
                workingDirectory: working
            ).isEmpty
        )
        #expect(
            try store.load(
                sessionID: librarySessionID,
                workingDirectory: working
            ) == nil
        )

        let saved = makeSavedPlan(
            id: "plan-cccccccc-3333",
            goal: "Only plan",
            savedAt: Date(timeIntervalSince1970: 300)
        )
        try await saveDraft(orchestrator, savedPlan: saved, working: working)

        let deleted = try await orchestrator.deleteSavedTaskPlans(
            planIDs: [saved.plan.id, "plan-missing", saved.plan.id],
            workingDirectory: working
        )
        #expect(deleted == [saved.plan.id])
        #expect(
            await orchestrator.savedTaskPlans(workingDirectory: working).isEmpty
        )
    }

    @Test
    func completingLivePlanGraphMarksLibraryDraftCompleted() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        let planID = "plan-dddddddd-4444"
        try await saveDraft(
            orchestrator,
            savedPlan: makeSavedPlan(
                id: planID,
                goal: "Mirrored plan",
                savedAt: Date(timeIntervalSince1970: 100)
            ),
            working: working
        )

        let liveGraph = try await completeLivePlanGraph(
            orchestrator,
            planID: planID,
            sessionID: "terminal-session",
            working: working
        )
        #expect(liveGraph.state == .completed)

        // The library copy is mirrored as completed and stays inspectable.
        let savedPlans = await orchestrator.savedTaskPlans(
            workingDirectory: working
        )
        let mirrored = try #require(savedPlans.first)
        #expect(mirrored.graph.id == planID)
        #expect(mirrored.graph.state == .completed)
        // Matching library tasks are mirrored as completed too, so /plan list
        // does not render "completed" next to "0/N".
        #expect(
            mirrored.graph.tasks.allSatisfy { $0.status == .completed }
        )

        // The mirror is durable: a fresh orchestrator sees the same state.
        let reader = SessionTaskOrchestrator(store: store)
        let persisted = try #require(
            await reader.savedTaskPlans(workingDirectory: working).first
        )
        #expect(persisted.graph.state == .completed)
        #expect(
            persisted.graph.tasks.allSatisfy { $0.status == .completed }
        )
    }

    @Test
    func completingLivePlanGraphWithoutLibraryCreatesNoCheckpoint() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        let liveGraph = try await completeLivePlanGraph(
            orchestrator,
            planID: "plan-eeeeeeee-5555",
            sessionID: "terminal-session",
            working: working
        )
        #expect(liveGraph.state == .completed)

        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: working
        )
        #expect(
            try store.load(
                sessionID: librarySessionID,
                workingDirectory: working
            ) == nil
        )
    }

    @Test
    func archivedLivePlanGraphKeepsLibraryDraftReusable() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        let planID = "plan-ffffffff-6666"
        try await saveDraft(
            orchestrator,
            savedPlan: makeSavedPlan(
                id: planID,
                goal: "Reusable plan",
                savedAt: Date(timeIntervalSince1970: 100)
            ),
            working: working
        )

        try await orchestrator.registerSession(
            id: "terminal-session",
            workingDirectory: working
        )
        _ = try await orchestrator.createGraph(
            sessionID: "terminal-session",
            id: planID,
            source: .plan(planID: planID),
            state: .active,
            tasks: [TaskDefinition(id: "\(planID)-1", title: "Do the work")]
        )
        _ = try await orchestrator.archiveGraph(
            id: planID,
            sessionID: "terminal-session"
        )

        let savedPlans = await orchestrator.savedTaskPlans(
            workingDirectory: working
        )
        let draft = try #require(savedPlans.first)
        #expect(draft.graph.id == planID)
        #expect(draft.graph.state == .draft)
    }

    @Test
    func savedTaskPlansOrdersNewestFirstIncludingCompletedEntries() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        let olderID = "plan-11111111-7777"
        try await saveDraft(
            orchestrator,
            savedPlan: makeSavedPlan(
                id: olderID,
                goal: "Older plan",
                savedAt: Date(timeIntervalSince1970: 100)
            ),
            working: working
        )
        _ = try await completeLivePlanGraph(
            orchestrator,
            planID: olderID,
            sessionID: "terminal-session",
            working: working
        )
        try await saveDraft(
            orchestrator,
            savedPlan: makeSavedPlan(
                id: "plan-22222222-8888",
                goal: "Newer plan",
                savedAt: Date(timeIntervalSince1970: 300)
            ),
            working: working
        )

        let savedPlans = await orchestrator.savedTaskPlans(
            workingDirectory: working
        )
        #expect(savedPlans.count == 2)
        #expect(savedPlans.map(\.graph.id) == ["plan-22222222-8888", olderID])
        #expect(savedPlans.last?.graph.state == .completed)
        #expect(savedPlans.first?.graph.state == .draft)
    }

    @Test
    func mirrorKeepsPlansSavedByAnotherOrchestratorOnTheSameStore() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let first = SessionTaskOrchestrator(store: store)
        let second = SessionTaskOrchestrator(store: store)
        let planAID = "plan-11111111-9999"
        let planBID = "plan-22222222-8888"

        // The first orchestrator registers the library and caches [A].
        try await saveDraft(
            first,
            savedPlan: makeSavedPlan(
                id: planAID,
                goal: "Plan A",
                savedAt: Date(timeIntervalSince1970: 100)
            ),
            working: working
        )
        // A second orchestrator on the same store adds B: disk becomes [A, B]
        // while the first orchestrator's in-memory cache still holds [A].
        try await saveDraft(
            second,
            savedPlan: makeSavedPlan(
                id: planBID,
                goal: "Plan B",
                savedAt: Date(timeIntervalSince1970: 200)
            ),
            working: working
        )

        _ = try await completeLivePlanGraph(
            first,
            planID: planAID,
            sessionID: "terminal-session",
            working: working
        )

        // B must survive the mirror: no logical lost update.
        let reader = SessionTaskOrchestrator(store: store)
        let savedPlans = await reader.savedTaskPlans(workingDirectory: working)
        #expect(savedPlans.map(\.graph.id) == [planBID, planAID])
        #expect(savedPlans.first?.graph.state == .draft)
        #expect(savedPlans.last?.graph.state == .completed)
    }

    @Test
    func deleteKeepsPlansSavedByAnotherOrchestratorOnTheSameStore() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let first = SessionTaskOrchestrator(store: store)
        let second = SessionTaskOrchestrator(store: store)
        let planAID = "plan-33333333-7777"
        let planBID = "plan-44444444-6666"

        try await saveDraft(
            first,
            savedPlan: makeSavedPlan(
                id: planAID,
                goal: "Plan A",
                savedAt: Date(timeIntervalSince1970: 100)
            ),
            working: working
        )
        try await saveDraft(
            second,
            savedPlan: makeSavedPlan(
                id: planBID,
                goal: "Plan B",
                savedAt: Date(timeIntervalSince1970: 200)
            ),
            working: working
        )

        let deleted = try await first.deleteSavedTaskPlans(
            planIDs: [planAID],
            workingDirectory: working
        )
        #expect(deleted == [planAID])

        let reader = SessionTaskOrchestrator(store: store)
        #expect(
            await reader.savedTaskPlans(workingDirectory: working)
                .map(\.graph.id) == [planBID]
        )
    }

    @Test
    func mirrorFailureLeavesLiveCommitAndLibraryUnchanged() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        let planID = "plan-55555555-5555"
        let savedPlan = makeSavedPlan(
            id: planID,
            goal: "Broken library",
            savedAt: Date(timeIntervalSince1970: 100)
        )
        // A duplicate graph id makes restoreCheckpoint fail inside the
        // mirror while the checkpoint itself still decodes from disk.
        let libraryGraph = TaskGraphSnapshot(
            id: planID,
            source: .plan(planID: planID),
            state: .draft,
            tasks: [TaskRecord(id: "\(planID)-1", title: "Do", order: 1)],
            savedPlan: savedPlan
        )
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: working
        )
        try store.save(
            SessionTaskGraphCheckpoint(
                sessionID: librarySessionID,
                currentGraphID: nil,
                graphs: [libraryGraph, libraryGraph]
            ),
            workingDirectory: working
        )

        // The live completion must succeed despite the unusable library.
        let liveGraph = try await completeLivePlanGraph(
            orchestrator,
            planID: planID,
            sessionID: "terminal-session",
            working: working
        )
        #expect(liveGraph.state == .completed)

        // The library checkpoint is left exactly as it was.
        let checkpoint = try #require(
            try store.load(
                sessionID: librarySessionID,
                workingDirectory: working
            )
        )
        #expect(checkpoint.graphs.count == 2)
        #expect(checkpoint.graphs.allSatisfy { $0.state == .draft })
    }

    @Test
    func mirrorIsIdempotentAcrossRepeatedCommits() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        let planID = "plan-66666666-4444"
        try await saveDraft(
            orchestrator,
            savedPlan: makeSavedPlan(
                id: planID,
                goal: "Idempotent mirror",
                savedAt: Date(timeIntervalSince1970: 100)
            ),
            working: working
        )
        _ = try await completeLivePlanGraph(
            orchestrator,
            planID: planID,
            sessionID: "terminal-session",
            working: working
        )

        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: working
        )
        let firstRevision = try #require(
            try store.load(
                sessionID: librarySessionID,
                workingDirectory: working
            )?.graphs.first?.revision
        )

        // A further commit on the already-completed live graph must not touch
        // the mirrored library graph again.
        _ = try await orchestrator.updateTask(
            sessionID: "terminal-session",
            taskID: "\(planID)-1",
            graphID: planID,
            update: TaskUpdate(output: "follow-up note")
        )

        let secondRevision = try #require(
            try store.load(
                sessionID: librarySessionID,
                workingDirectory: working
            )?.graphs.first?.revision
        )
        #expect(secondRevision == firstRevision)
    }
}
