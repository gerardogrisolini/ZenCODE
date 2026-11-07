//
//  ChatTaskGraphOverviewTests.swift
//  ZenCODE
//
//  The task-graph overview the shared controller publishes: the threshold and
//  the signature, a session without a graph, the observer (start, debounce,
//  stop, turn-boundary quiescence, session and revision fences) over the
//  scripted runtime with the debounce under the test's control, `/tasks` with
//  its actions and errors, and the terminal's rendering of a publication.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite(.timeLimit(.minutes(1)))
struct ChatTaskGraphOverviewTests {
    private typealias Fixtures = ChatTestFixtures

    // MARK: - Threshold and signature

    @Test
    func aGraphIsSignificantWithMoreThanOneTaskOrATaskThatRanOrNeedsAttention() {
        func graph(_ tasks: [TaskRecord]) -> TaskGraphSnapshot {
            TaskGraphSnapshot(id: "graph", source: .manual, state: .active, tasks: tasks)
        }
        func task(
            _ id: String,
            status: TaskStatus = .pending,
            attempts: [TaskAttempt] = []
        ) -> TaskRecord {
            TaskRecord(id: id, title: "Task \(id)", order: 0, status: status, attempts: attempts)
        }
        let attempt = TaskAttempt(
            id: "attempt",
            ordinal: 1,
            agentID: "worker",
            executor: .subAgent,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1)
        )

        #expect(!ChatTaskGraphOverview.isSignificant(graph([])))
        #expect(!ChatTaskGraphOverview.isSignificant(graph([task("a")])))
        #expect(!ChatTaskGraphOverview.isSignificant(graph([task("a", status: .inProgress)])))
        #expect(!ChatTaskGraphOverview.isSignificant(graph([task("a", status: .completed)])))
        #expect(!ChatTaskGraphOverview.isSignificant(graph([task("a", status: .cancelled)])))
        #expect(ChatTaskGraphOverview.isSignificant(graph([task("a"), task("b")])))
        #expect(ChatTaskGraphOverview.isSignificant(graph([task("a", attempts: [attempt])])))
        #expect(ChatTaskGraphOverview.isSignificant(graph([task("a", status: .blocked)])))
        #expect(ChatTaskGraphOverview.isSignificant(graph([task("a", status: .failed)])))
        #expect(ChatTaskGraphOverview.isSignificant(graph([task("a", status: .awaitingValidation)])))

        let trivial = ChatTaskGraphOverview(graph: graph([task("a")]), tasks: [])
        let significant = ChatTaskGraphOverview(graph: graph([task("a"), task("b")]), tasks: [])
        #expect(!trivial.isSignificant)
        #expect(significant.isSignificant)
    }

    @Test
    func theSignatureNamesWhatTheSectionShowsWhateverTheTaskOrder() throws {
        let attempt = TaskAttempt(
            id: "attempt-1",
            ordinal: 1,
            agentID: "worker",
            executor: .subAgent,
            status: .running,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        let first = TaskRecord(
            id: "first",
            title: "First",
            order: 1,
            status: .inProgress,
            activeAttemptID: attempt.id,
            attempts: [attempt],
            revision: 3
        )
        let second = TaskRecord(id: "second", title: "Second", order: 2)
        let graph = TaskGraphSnapshot(
            id: "graph",
            source: .manual,
            state: .active,
            revision: 7,
            tasks: [second, first]
        )

        let signature = ChatTaskGraphOverview.signature(for: graph)
        #expect(signature == "graph:7:active:"
            + "first:3:in_progress:attempt-1:attempt-1:running|second:1:pending:-:")
        #expect(ChatTaskGraphOverview(graph: graph, tasks: []).signature == signature)
        #expect(TerminalChat.taskGraphOverviewSignature(graph) == signature)

        var reordered = graph
        reordered.tasks = [first, second]
        #expect(ChatTaskGraphOverview.signature(for: reordered) == signature)

        var revised = graph
        revised.revision = 8
        #expect(ChatTaskGraphOverview.signature(for: revised) != signature)

        let secondIndex = try #require(graph.tasks.firstIndex { $0.id == "second" })
        var completed = graph
        completed.tasks[secondIndex].status = .completed
        #expect(ChatTaskGraphOverview.signature(for: completed) != signature)

        var retried = graph
        retried.tasks[secondIndex].attempts = [attempt]
        #expect(ChatTaskGraphOverview.signature(for: retried) != signature)

        var revisedTask = graph
        revisedTask.tasks[secondIndex].revision = 2
        #expect(ChatTaskGraphOverview.signature(for: revisedTask) != signature)
    }

    // MARK: - Observer

    @Test
    func theObserverPublishesAChangeOnceTheDebounceElapsesWithTheReservationOfItsArrival() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let gate = DebounceGate()
            controller.taskGraphObserver.sleep = { try await gate.sleep($0) }
            #expect(controller.taskGraphObserverTask == nil)

            await controller.startTaskGraphObserver()
            #expect(controller.taskGraphObserverTask != nil)
            try await Self.createGraph(in: harness)

            // The change is reserved as it arrives; nothing is presented
            // while the debounce runs.
            await harness.presenter.waitForTaskGraphReservations(1)
            await gate.waitForEntries(1)
            #expect(await harness.presenter.taskGraphOverviews.isEmpty)

            await gate.open()
            await harness.presenter.waitForTaskGraphOverviews(1)
            let published = try #require(await harness.presenter.taskGraphOverviews.first)
            #expect(published.origin == .automatic)
            #expect(published.publication == ChatOverviewPublication(revision: 1))
            let overview = try #require(published.overview)
            #expect(overview.graph.id == "graph")
            #expect(overview.tasks.map(\.task.id) == ["first", "second"])
            #expect(await gate.durations == [ChatTaskGraphObserver.debounceInterval])
            #expect(ChatTaskGraphObserver.debounceInterval == .milliseconds(150))

            await controller.stopTaskGraphObserver()
            #expect(controller.taskGraphObserverTask == nil)
        }
    }

    @Test
    func stoppingDropsThePendingPublicationAndEndsTheSubscription() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let gate = DebounceGate()
            controller.taskGraphObserver.sleep = { try await gate.sleep($0) }
            await controller.startTaskGraphObserver()

            try await Self.createGraph(in: harness)
            await harness.presenter.waitForTaskGraphReservations(1)
            await gate.waitForEntries(1)

            await controller.stopTaskGraphObserver()
            #expect(controller.taskGraphObserverTask == nil)
            #expect(controller.taskGraphObserver.pendingPublication == nil)

            // A change after the stop reaches no observer.
            _ = try await harness.runtime.taskOrchestrator.claimTasks(
                sessionID: controller.sessionID,
                claims: [TaskClaim(taskID: "first", agentID: "worker")]
            )
            #expect(await harness.presenter.taskGraphReservations.count == 1)
            #expect(await harness.presenter.taskGraphOverviews.isEmpty)
        }
    }

    @Test
    func theObserverIsFencedOnTheSessionItObserves() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let observedSessionID = controller.sessionID
            let gate = DebounceGate()
            controller.taskGraphObserver.sleep = { try await gate.sleep($0) }
            await controller.startTaskGraphObserver()

            try await Self.createGraph(in: harness)
            await harness.presenter.waitForTaskGraphReservations(1)
            await gate.waitForEntries(1)

            // The session changes while the publication waits: it is dropped.
            controller.sessionID = "chat-session-\(UUID().uuidString.lowercased())"
            await gate.open()
            await controller.taskGraphObserver.pendingPublication?.value
            #expect(await harness.presenter.taskGraphOverviews.isEmpty)

            // The next change of the observed session ends the observer.
            _ = try await harness.runtime.taskOrchestrator.claimTasks(
                sessionID: observedSessionID,
                claims: [TaskClaim(taskID: "first", agentID: "worker")]
            )
            await controller.taskGraphObserverTask?.value
            #expect(await harness.presenter.taskGraphReservations.count == 1)
            #expect(await harness.presenter.taskGraphOverviews.isEmpty)
            await controller.stopTaskGraphObserver()
        }
    }

    // MARK: - /tasks

    @Test
    func statusEchoesTheLineAndPresentsTheGraphAsAnExplicitOverviewReservedBeforeTheRead() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await Self.createGraph(in: harness)
            let expected = try #require(try await ChatTaskGraphOverview.current(
                in: harness.runtime,
                sessionID: controller.sessionID
            ))

            for line in ["/tasks", "/tasks status", "/tasks list", "/tasks LS"] {
                await harness.clearRecords()
                #expect(await controller.runTasksCommand(line: line) == ChatCommandOutcome())
                let events = await harness.presenter.events
                guard case let .taskGraphReservation(publication) = events.dropFirst().first else {
                    Issue.record("\(line): expected a reservation, got \(events)")
                    continue
                }
                #expect(publication != nil)
                #expect(events == [
                    .submittedCommand(line),
                    .taskGraphReservation(publication),
                    .taskGraphOverview(expected, origin: .explicit, publication: publication),
                ])
            }
            // `/tasks` only reads.
            #expect(await harness.runtime.calls.isEmpty)
        }
    }

    @Test
    func showAndGetPresentOneTaskAndAMissingOrUnknownIDFails() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            try await Self.createGraph(in: harness)
            let view = try await harness.runtime.taskOrchestrator.task(
                sessionID: controller.sessionID,
                taskID: "first"
            )

            #expect(await controller.runTasksCommand(line: "/tasks show first")
                == ChatCommandOutcome(notices: [.taskDetail(view)]))
            #expect(await controller.runTasksCommand(line: "/tasks GET first")
                == ChatCommandOutcome(notices: [.taskDetail(view)]))
            #expect(await controller.runTasksCommand(line: "/tasks show")
                == ChatCommandOutcome(notices: [.taskIDRequired(action: "show")]))
            #expect(await controller.runTasksCommand(line: "/tasks get")
                == ChatCommandOutcome(notices: [.taskIDRequired(action: "get")]))
            #expect(await controller.runTasksCommand(line: "/tasks show missing")
                == ChatCommandOutcome(notices: [.operationFailed(
                    description: SessionTaskOrchestratorError.taskNotFound("missing").localizedDescription
                )]))
            // Every line is echoed, and nothing else is presented.
            #expect(await harness.presenter.events == [
                .submittedCommand("/tasks show first"),
                .submittedCommand("/tasks GET first"),
                .submittedCommand("/tasks show"),
                .submittedCommand("/tasks get"),
                .submittedCommand("/tasks show missing"),
            ])
        }
    }

    @Test
    func retryConfirmsBeforeTheGraphThatShowsIt() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let sessionID = controller.sessionID
            let orchestrator = harness.runtime.taskOrchestrator
            try await Self.createGraph(in: harness, taskIDs: ["task-a"])
            let claim = try #require(try await orchestrator.claimTasks(
                sessionID: sessionID,
                claims: [TaskClaim(taskID: "task-a", agentID: "worker")]
            ).first)
            _ = try await orchestrator.failAttempt(
                sessionID: sessionID,
                taskID: "task-a",
                attemptID: claim.attemptID,
                error: "failed"
            )

            #expect(await controller.runTasksCommand(line: "/tasks retry task-a") == ChatCommandOutcome())
            #expect(try await orchestrator.task(sessionID: sessionID, taskID: "task-a").task.status == .pending)
            #expect(await harness.runtime.calls == [
                .retryTask(taskID: "task-a", sessionID: sessionID, expectedRevision: nil),
            ])
            let expected = try #require(try await ChatTaskGraphOverview.current(
                in: harness.runtime,
                sessionID: sessionID
            ))
            #expect(await harness.presenter.events == [
                .submittedCommand("/tasks retry task-a"),
                .sessionNotice(.taskRetried(taskID: "task-a")),
                .taskGraphReservation(ChatOverviewPublication(revision: 1)),
                .taskGraphOverview(
                    expected,
                    origin: .explicit,
                    publication: ChatOverviewPublication(revision: 1)
                ),
            ])
            #expect(ChatSessionNoticeText.text(for: .taskRetried(taskID: "task-a")) == "Retried task task-a.\n")

            // A task the runtime refuses to retry is reported, not confirmed.
            await harness.clearRecords()
            let outcome = await controller.runTasksCommand(line: "/tasks retry task-a")
            guard case .operationFailed = try #require(outcome.notices.first) else {
                Issue.record("expected operationFailed, got \(outcome.notices)")
                return
            }
            #expect(outcome.notices.count == 1)
            #expect(await harness.presenter.events == [.submittedCommand("/tasks retry task-a")])
        }
    }

    @Test
    func cancelPassesTheReasonAndConfirmsBeforeTheGraph() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let sessionID = controller.sessionID
            let orchestrator = harness.runtime.taskOrchestrator
            try await Self.createGraph(in: harness, taskIDs: ["task-a"])
            _ = try await orchestrator.claimTasks(
                sessionID: sessionID,
                claims: [TaskClaim(taskID: "task-a", agentID: "worker")]
            )

            let line = "/tasks cancel task-a user  requested"
            #expect(await controller.runTasksCommand(line: line) == ChatCommandOutcome())
            #expect(try await orchestrator.task(sessionID: sessionID, taskID: "task-a").task.status == .cancelled)
            #expect(await harness.runtime.calls == [
                .cancelTask(taskID: "task-a", sessionID: sessionID, reason: "user requested"),
            ])
            let events = await harness.presenter.events
            #expect(events.count == 4)
            #expect(events.prefix(3) == [
                .submittedCommand(line),
                .sessionNotice(.taskCancelled(taskID: "task-a")),
                .taskGraphReservation(ChatOverviewPublication(revision: 1)),
            ])
            guard case let .taskGraphOverview(overview, origin, publication) = events.last else {
                Issue.record("expected the overview last, got \(events)")
                return
            }
            #expect(overview?.graph.tasks.first?.status == .cancelled)
            #expect(origin == .explicit)
            #expect(publication == ChatOverviewPublication(revision: 1))
            #expect(ChatSessionNoticeText.text(for: .taskCancelled(taskID: "task-a")) == "Cancelled task task-a.\n")

            // Without a reason the runtime gets none.
            try await Self.createGraph(in: harness, id: "second-graph", taskIDs: ["task-b"])
            await harness.clearRecords()
            _ = await controller.runTasksCommand(line: "/tasks cancel task-b")
            #expect(await harness.runtime.calls == [
                .cancelTask(taskID: "task-b", sessionID: sessionID, reason: nil),
            ])
        }
    }

    @Test
    func clearRemovesTheGraphsAndClosesWithItsNotice() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let sessionID = controller.sessionID
            try await Self.createGraph(in: harness)

            #expect(await controller.runTasksCommand(line: "/tasks clear")
                == ChatCommandOutcome(notices: [.taskGraphsCleared]))
            #expect(await harness.runtime.calls == [.clearTaskGraphs(sessionID: sessionID)])
            #expect(await harness.presenter.events == [.submittedCommand("/tasks clear")])
            #expect(try await harness.runtime.taskOrchestrator.graphSnapshot(sessionID: sessionID) == nil)
            #expect(ChatSessionNoticeText.text(for: .taskGraphsCleared) == "Cleared the session task graphs.\n")
        }
    }

    // MARK: - Helpers

    @discardableResult
    @ChatSessionActor
    private static func createGraph(
        in harness: ChatManagementHarness,
        id: String = "graph",
        taskIDs: [String] = ["first", "second"]
    ) async throws -> TaskGraphSnapshot {
        try await harness.runtime.taskOrchestrator.createGraph(
            sessionID: harness.controller.sessionID,
            id: id,
            source: .manual,
            state: .active,
            tasks: taskIDs.map { TaskDefinition(id: $0, title: "Task \($0)") }
        )
    }
}
