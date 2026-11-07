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

    private func makeDraft(
        id: String,
        goal: String,
        savedAt: Date,
        isApproved: Bool = false
    ) -> SavedPlanDraft {
        var savedPlan = makeSavedPlan(id: id, goal: goal, savedAt: savedAt)
        if isApproved {
            savedPlan = TaskGraphSavedPlan(
                plan: TerminalSessionPlan(
                    id: id,
                    originalGoal: goal,
                    consolidatedText: "\(goal). Inspect, implement, and validate.",
                    createdAt: savedAt,
                    isApproved: true,
                    points: [TerminalSessionPlanPoint(id: "\(id)-1", text: "Do \(goal)")]
                ),
                savedAt: savedAt,
                savingAgentName: "Planner"
            )
        }
        return SavedPlanDraft(
            savedPlan: savedPlan,
            tasks: [TaskDefinition(id: "\(id)-1", title: "Do \(goal)")]
        )
    }

    @Test
    func savePlanDraftsSavesEveryDraftInOneCall() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: working
        )
        try await orchestrator.registerSession(
            id: librarySessionID,
            workingDirectory: working
        )
        let events = await orchestrator.events(sessionID: librarySessionID)
        let first = makeDraft(
            id: "plan-aaaa0001-0001",
            goal: "First step",
            savedAt: Date(timeIntervalSince1970: 100)
        )
        let second = makeDraft(
            id: "plan-aaaa0002-0002",
            goal: "Second step",
            savedAt: Date(timeIntervalSince1970: 200)
        )

        let snapshots = try await orchestrator.savePlanDrafts(
            [first, second],
            sessionID: librarySessionID
        )

        // Snapshots come back in draft order, as non-current drafts.
        #expect(snapshots.map(\.id) == [first.savedPlan.plan.id, second.savedPlan.plan.id])
        #expect(snapshots.allSatisfy { $0.state == .draft })
        #expect(snapshots.map(\.savedPlan) == [first.savedPlan, second.savedPlan])
        #expect(snapshots.map { $0.tasks.map(\.id) } == [
            ["\(first.savedPlan.plan.id)-1"],
            ["\(second.savedPlan.plan.id)-1"],
        ])

        // Both are in the library (newest explicit save first)...
        let savedPlans = await orchestrator.savedTaskPlans(workingDirectory: working)
        #expect(savedPlans.map(\.graph.id) == [second.savedPlan.plan.id, first.savedPlan.plan.id])

        // ...and durable for a fresh orchestrator on the same store.
        let reader = SessionTaskOrchestrator(store: store)
        #expect(
            await reader.savedTaskPlans(workingDirectory: working).map(\.graph.id)
                == [second.savedPlan.plan.id, first.savedPlan.plan.id]
        )

        // The newest pending event is the last graph's creation.
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.kind == .created)
        #expect(event?.graphID == second.savedPlan.plan.id)
    }

    @Test
    func savePlanDraftsResavingAnExistingPlanUpdatesIt() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: working
        )
        let existingID = "plan-bbbb0001-0001"
        try await saveDraft(
            orchestrator,
            savedPlan: makeSavedPlan(
                id: existingID,
                goal: "Original goal",
                savedAt: Date(timeIntervalSince1970: 100)
            ),
            working: working
        )
        let events = await orchestrator.events(sessionID: librarySessionID)

        let revised = makeDraft(
            id: existingID,
            goal: "Revised goal",
            savedAt: Date(timeIntervalSince1970: 300)
        )
        let added = makeDraft(
            id: "plan-bbbb0002-0002",
            goal: "Added goal",
            savedAt: Date(timeIntervalSince1970: 200)
        )
        let snapshots = try await orchestrator.savePlanDrafts(
            [added, revised],
            sessionID: librarySessionID
        )
        #expect(snapshots.map(\.id) == [added.savedPlan.plan.id, existingID])

        let savedPlans = await orchestrator.savedTaskPlans(workingDirectory: working)
        #expect(savedPlans.map(\.graph.id) == [existingID, added.savedPlan.plan.id])
        let updated = try #require(savedPlans.first)
        #expect(updated.snapshot.plan.originalGoal == "Revised goal")
        #expect(updated.graph.state == .draft)
        #expect(updated.graph.tasks.map(\.title) == ["Do Revised goal"])

        // The re-saved plan reports `.updated`, the new one `.created`; the
        // newest pending event belongs to the last draft of the batch.
        var iterator = events.makeAsyncIterator()
        let event = await iterator.next()
        #expect(event?.kind == .updated)
        #expect(event?.graphID == existingID)
    }

    @Test
    func savePlanDraftsWithAnApprovedPlanSavesNothing() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: working
        )
        let existing = makeSavedPlan(
            id: "plan-cccc0001-0001",
            goal: "Pre-existing",
            savedAt: Date(timeIntervalSince1970: 100)
        )
        try await saveDraft(orchestrator, savedPlan: existing, working: working)
        let before = await orchestrator.savedTaskPlans(workingDirectory: working)

        let batch = [
            // A valid update of the pre-existing plan and a valid new plan
            // must both be discarded because the third entry is approved.
            makeDraft(
                id: existing.plan.id,
                goal: "Changed",
                savedAt: Date(timeIntervalSince1970: 200)
            ),
            makeDraft(
                id: "plan-cccc0002-0002",
                goal: "New",
                savedAt: Date(timeIntervalSince1970: 201)
            ),
            makeDraft(
                id: "plan-cccc0003-0003",
                goal: "Approved",
                savedAt: Date(timeIntervalSince1970: 202),
                isApproved: true
            ),
        ]
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await orchestrator.savePlanDrafts(batch, sessionID: librarySessionID)
        }

        #expect(await orchestrator.savedTaskPlans(workingDirectory: working) == before)
        let reader = SessionTaskOrchestrator(store: store)
        #expect(await reader.savedTaskPlans(workingDirectory: working) == before)
    }

    @Test
    func savePlanDraftsRejectsALiveActivePlanGraphAndSavesNothing() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        let sessionID = "terminal-session"
        let activeID = "plan-eeee0001-0001"
        try await orchestrator.registerSession(
            id: sessionID,
            workingDirectory: working
        )
        _ = try await orchestrator.createGraph(
            sessionID: sessionID,
            id: activeID,
            source: .plan(planID: activeID),
            state: .active,
            tasks: [TaskDefinition(id: "\(activeID)-1", title: "Running")]
        )

        let newID = "plan-eeee0002-0002"
        await #expect(throws: SessionTaskOrchestratorError.graphNotMutable(activeID)) {
            try await orchestrator.savePlanDrafts(
                [
                    makeDraft(
                        id: newID,
                        goal: "New",
                        savedAt: Date(timeIntervalSince1970: 100)
                    ),
                    makeDraft(
                        id: activeID,
                        goal: "Running",
                        savedAt: Date(timeIntervalSince1970: 101)
                    ),
                ],
                sessionID: sessionID
            )
        }

        #expect(try await orchestrator.graphSnapshot(sessionID: sessionID, graphID: newID) == nil)
        let active = try #require(
            try await orchestrator.graphSnapshot(sessionID: sessionID, graphID: activeID)
        )
        #expect(active.state == .active)
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

    /// Regression test: deleting the library checkpoint (discardSession) used
    /// to leave the orchestrator's in-memory CAS precondition in place, so the
    /// next /plan save in the same process failed with staleCheckpoint.
    @Test
    func saveAfterDiscardingEntireLibraryDoesNotFailWithStaleCheckpoint() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let orchestrator = SessionTaskOrchestrator(store: store)
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: working
        )

        // save
        try await saveDraft(
            orchestrator,
            savedPlan: makeSavedPlan(
                id: "plan-77777777-1234",
                goal: "First iteration",
                savedAt: Date(timeIntervalSince1970: 100)
            ),
            working: working
        )
        // delete all (the last deletion discards the library session)
        #expect(
            try await orchestrator.deleteSavedTaskPlans(
                planIDs: ["plan-77777777-1234"],
                workingDirectory: working
            ) == ["plan-77777777-1234"]
        )
        #expect(try store.load(
            sessionID: librarySessionID,
            workingDirectory: working
        ) == nil)

        // save again in the same process: must not throw staleCheckpoint.
        let graph = try await saveDraft(
            orchestrator,
            savedPlan: makeSavedPlan(
                id: "plan-88888888-5678",
                goal: "Second iteration",
                savedAt: Date(timeIntervalSince1970: 200)
            ),
            working: working
        )
        #expect(graph.state == .draft)

        // The new checkpoint is durable and readable by a fresh orchestrator.
        let restored = try #require(
            try store.load(
                sessionID: librarySessionID,
                workingDirectory: working
            )
        )
        #expect(restored.graphs.map(\.id) == ["plan-88888888-5678"])
    }
}
