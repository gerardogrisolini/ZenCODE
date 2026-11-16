//
//  SessionTaskGraphResumeTests+Adoption.swift
//  ZenCODE
//
//  Tests for resuming a selected checkpoint graph, removing resumable graphs
//  and adopting an interrupted graph into the current session.
//

import Foundation
import Testing
@testable import ZenCODECore

extension SessionTaskGraphResumeTests {
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
        try store.compareAndSwap(
            SessionTaskGraphCheckpoint(
                sessionID: "previous-session",
                currentGraphID: previouslyCurrent.id,
                graphs: [previouslyCurrent, selected]
            ),
            replacing: nil,
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
        try store.compareAndSwap(
            SessionTaskGraphCheckpoint(
                sessionID: "previous-session",
                currentGraphID: "keep",
                graphs: [obsoleteGraph, keepGraph]
            ),
            replacing: nil,
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

    // MARK: - Adoption into the current session

    /// A graph left by `previous-session` whose first task was running when
    /// that process ended, and a second graph of the same checkpoint.
    private func saveInterruptedCheckpoint(
        store: SessionTaskGraphStore,
        working: URL,
        includesOtherGraph: Bool = true
    ) throws {
        let now = Date()
        let chosen = TaskGraphSnapshot(
            id: "chosen",
            source: .manual,
            state: .active,
            tasks: [
                TaskRecord(
                    id: "running",
                    title: "Running",
                    order: 1,
                    status: .inProgress,
                    execution: TaskExecutionSpec(executor: .subAgent),
                    activeAttemptID: "attempt-1",
                    attempts: [
                        TaskAttempt(
                            id: "attempt-1",
                            ordinal: 1,
                            agentID: "agent-1",
                            executor: .subAgent,
                            status: .running,
                            startedAt: now
                        ),
                    ]
                ),
                TaskRecord(id: "next", title: "Next", order: 2, status: .pending),
            ],
            createdAt: now,
            updatedAt: now.addingTimeInterval(1)
        )
        let other = TaskGraphSnapshot(
            id: "other",
            source: .manual,
            state: .draft,
            tasks: [TaskRecord(id: "later", title: "Later", order: 1, status: .pending)],
            createdAt: now,
            updatedAt: now
        )
        try store.compareAndSwap(
            SessionTaskGraphCheckpoint(
                sessionID: "previous-session",
                currentGraphID: chosen.id,
                graphs: includesOtherGraph ? [chosen, other] : [chosen]
            ),
            replacing: nil,
            workingDirectory: working
        )
    }

    @Test
    func adoptingAGraphMovesItIntoTheCurrentSession() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        try saveInterruptedCheckpoint(store: store, working: working)

        let orchestrator = SessionTaskOrchestrator(store: store)
        let candidates = await orchestrator.resumableTaskGraphCheckpoints(workingDirectory: working)
        let choice = try #require(candidates.first { $0.graphID == "chosen" })
        let adopted = try await orchestrator.adoptResumableTaskGraph(
            choice,
            intoSessionID: "current-session",
            workingDirectory: working
        )

        #expect(adopted.id == "chosen")
        #expect(adopted.state == .active)
        // The attempt of the dead process was interrupted, not carried over.
        let running = try #require(adopted.tasks.first { $0.id == "running" })
        #expect(running.status == .blocked)
        #expect(running.activeAttemptID == nil)
        #expect(running.attempts.map(\.status) == [.interrupted])
        #expect(try await orchestrator.graphSnapshot(sessionID: "current-session")?.id == "chosen")

        // The current session's checkpoint holds it, active and current.
        let target = try #require(try store.load(sessionID: "current-session", workingDirectory: working))
        #expect(target.currentGraphID == "chosen")
        #expect(target.graphs.map(\.id) == ["chosen"])
        #expect(target.graphs.first?.state == .active)
        // The old checkpoint keeps only the graph that was not chosen.
        let source = try #require(try store.load(sessionID: "previous-session", workingDirectory: working))
        #expect(source.graphs.map(\.id) == ["other"])
        #expect(source.currentGraphID == nil)
        #expect(try await orchestrator.graphSnapshot(sessionID: "previous-session", graphID: "chosen") == nil)

        // A later process finds the graph under the current session, and the
        // other graph still where it was.
        let next = SessionTaskOrchestrator(store: store)
        let remaining = await next.resumableTaskGraphCheckpoints(workingDirectory: working)
        #expect(Set(remaining.map(\.id)) == ["current-session/chosen", "previous-session/other"])
        try await next.registerSession(id: "current-session", workingDirectory: working)
        #expect(try await next.graphSnapshot(sessionID: "current-session")?.id == "chosen")
    }

    @Test
    func adoptionRefusesATargetThatAlreadyHoldsAGraphWithTheSameID() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        try saveInterruptedCheckpoint(store: store, working: working)

        let orchestrator = SessionTaskOrchestrator(store: store)
        try await orchestrator.registerSession(id: "current-session", workingDirectory: working)
        _ = try await orchestrator.createGraph(
            sessionID: "current-session",
            id: "chosen",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "mine", title: "Mine")]
        )
        let choice = try #require(
            await orchestrator.resumableTaskGraphCheckpoints(workingDirectory: working)
                .first { $0.sessionID == "previous-session" && $0.graphID == "chosen" }
        )

        await #expect(throws: SessionTaskOrchestratorError.graphAlreadyExists("chosen")) {
            try await orchestrator.adoptResumableTaskGraph(
                choice,
                intoSessionID: "current-session",
                workingDirectory: working
            )
        }

        // Neither session lost its graph.
        let source = try #require(try store.load(sessionID: "previous-session", workingDirectory: working))
        #expect(Set(source.graphs.map(\.id)) == ["chosen", "other"])
        let target = try #require(try store.load(sessionID: "current-session", workingDirectory: working))
        #expect(target.graphs.first?.tasks.map(\.id) == ["mine"])
    }

    @Test
    func adoptionArchivesTheActiveGraphOfTheCurrentSession() async throws {
        let (root, support, working) = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        try saveInterruptedCheckpoint(store: store, working: working)

        let orchestrator = SessionTaskOrchestrator(store: store)
        try await orchestrator.registerSession(id: "current-session", workingDirectory: working)
        _ = try await orchestrator.createGraph(
            sessionID: "current-session",
            id: "current-work",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "mine", title: "Mine")]
        )
        let choice = try #require(
            await orchestrator.resumableTaskGraphCheckpoints(workingDirectory: working)
                .first { $0.graphID == "chosen" }
        )
        try await orchestrator.adoptResumableTaskGraph(
            choice,
            intoSessionID: "current-session",
            workingDirectory: working
        )

        #expect(try await orchestrator.graphSnapshot(sessionID: "current-session")?.id == "chosen")
        #expect(
            try await orchestrator.graphSnapshot(
                sessionID: "current-session",
                graphID: "current-work"
            )?.state == .archived
        )
        // An archived graph is not recovery state: only the adopted one is
        // persisted for the current session.
        let target = try #require(try store.load(sessionID: "current-session", workingDirectory: working))
        #expect(target.graphs.map(\.id) == ["chosen"])
        #expect(target.currentGraphID == "chosen")
    }
}
