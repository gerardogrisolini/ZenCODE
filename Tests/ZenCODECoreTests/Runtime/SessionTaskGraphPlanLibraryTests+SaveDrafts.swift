//
//  SessionTaskGraphPlanLibraryTests+SaveDrafts.swift
//  ZenCODE
//
//  Tests for saving plan drafts into the task plan library in one call,
//  including resaving, approved plans, live active graphs and stale
//  checkpoints.
//

import Foundation
import Testing
@testable import ZenCODECore

extension SessionTaskGraphPlanLibraryTests {
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
