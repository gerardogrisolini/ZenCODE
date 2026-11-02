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

    // MARK: - Reading the current graph

    @Test
    func theCurrentOverviewIsTheGraphWithItsTaskViewsOrNothing() async throws {
        try await withChatHarness { harness in
            let sessionID = harness.controller.sessionID
            #expect(try await ChatTaskGraphOverview.current(
                in: harness.runtime,
                sessionID: sessionID
            ) == nil)

            let graph = try await Self.createGraph(in: harness)
            let overview = try #require(try await ChatTaskGraphOverview.current(
                in: harness.runtime,
                sessionID: sessionID
            ))
            let views = try await harness.runtime.taskOrchestrator.listTasks(
                sessionID: sessionID,
                graphID: graph.id
            )
            #expect(overview.graph == graph)
            #expect(overview.tasks == views)
            #expect(overview.signature == ChatTaskGraphOverview.signature(for: graph))
        }
    }

    // MARK: - Publication

    @Test
    func noGraphPresentsNothingAndAGraphBelowTheThresholdIsLeftToTheChannel() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let sessionID = controller.sessionID

            // A session other than the active one is fenced before reserving.
            await controller.publishTaskGraphOverviewIfChanged(observedSessionID: "another-session")
            #expect(await harness.presenter.events.isEmpty)

            await controller.publishTaskGraphOverviewIfChanged(observedSessionID: sessionID)
            try await harness.runtime.seedTaskGraph(Fixtures.taskGraph(id: "single"), sessionID: sessionID)
            await controller.publishTaskGraphOverviewIfChanged(observedSessionID: sessionID)

            #expect(await harness.presenter.taskGraphReservations == [
                ChatOverviewPublication(revision: 1),
                ChatOverviewPublication(revision: 2),
            ])
            let overviews = await harness.presenter.taskGraphOverviews
            #expect(overviews.count == 2)
            #expect(overviews.first?.overview == nil)
            #expect(overviews.first?.origin == .automatic)
            #expect(overviews.first?.publication == ChatOverviewPublication(revision: 1))
            let trivial = try #require(overviews.last?.overview)
            #expect(trivial.graph.id == "single")
            #expect(trivial.tasks.map(\.task.id) == ["single-1"])
            #expect(!trivial.isSignificant)
            #expect(overviews.last?.origin == .automatic)
            #expect(overviews.last?.publication == ChatOverviewPublication(revision: 2))
        }
    }

    @Test
    func aGraphThatChangesWhileItIsReadIsNotPresented() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let sessionID = controller.sessionID
            let orchestrator = harness.runtime.taskOrchestrator
            try await Self.createGraph(in: harness)
            // The change lands between the first read and the revision check.
            await harness.runtime.setTaskGraphReadHook { read in
                guard read == 1 else { return }
                _ = try? await orchestrator.claimTasks(
                    sessionID: sessionID,
                    claims: [TaskClaim(taskID: "first", agentID: "worker")]
                )
            }

            await controller.publishTaskGraphOverviewIfChanged(observedSessionID: sessionID)
            #expect(await harness.presenter.taskGraphReservations == [ChatOverviewPublication(revision: 1)])
            #expect(await harness.presenter.taskGraphOverviews.isEmpty)

            // The change publishes it again, now that the graph holds still.
            await harness.runtime.setTaskGraphReadHook(nil)
            await controller.publishTaskGraphOverviewIfChanged(observedSessionID: sessionID)
            let published = try #require(await harness.presenter.taskGraphOverviews.first)
            let current = try await orchestrator.graphSnapshot(sessionID: sessionID)
            #expect(published.publication == ChatOverviewPublication(revision: 2))
            #expect(published.overview?.graph == current)
            #expect(published.overview?.graph.tasks.first { $0.id == "first" }?.status == .inProgress)
        }
    }

    @Test
    func aPresenterThatReservesNothingGetsEveryOverviewWithoutAReservation() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            await harness.presenter.setReservesTaskGraphPublications(false)
            try await Self.createGraph(in: harness)

            #expect(await controller.runTasksCommand(line: "/tasks") == ChatCommandOutcome())
            await controller.publishTaskGraphOverviewIfChanged(observedSessionID: controller.sessionID)

            #expect(await harness.presenter.taskGraphReservations == [nil, nil])
            let overviews = await harness.presenter.taskGraphOverviews
            #expect(overviews.map { $0.origin } == [.explicit, .automatic])
            #expect(overviews.allSatisfy { $0.publication == nil && $0.overview?.graph.id == "graph" })
        }
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
    func aBurstOfChangesPublishesOnceWithTheLastReservation() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let gate = DebounceGate()
            controller.taskGraphObserver.sleep = { try await gate.sleep($0) }
            await controller.startTaskGraphObserver()

            try await Self.createGraph(in: harness)
            await harness.presenter.waitForTaskGraphReservations(1)
            await gate.waitForEntries(1)
            _ = try await harness.runtime.taskOrchestrator.claimTasks(
                sessionID: controller.sessionID,
                claims: [TaskClaim(taskID: "first", agentID: "worker")]
            )
            await harness.presenter.waitForTaskGraphReservations(2)
            await gate.waitForEntries(2)

            await gate.open()
            await harness.presenter.waitForTaskGraphOverviews(1)
            await controller.taskGraphObserver.pendingPublication?.value

            let overviews = await harness.presenter.taskGraphOverviews
            #expect(overviews.count == 1)
            #expect(overviews.first?.publication == ChatOverviewPublication(revision: 2))
            #expect(overviews.first?.overview?.graph.tasks.first { $0.id == "first" }?.status == .inProgress)
            await controller.stopTaskGraphObserver()
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
    func quiescencePublishesTheLatestGraphOnceAndARestartRecoversWhatChangedMeanwhile() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            let sessionID = controller.sessionID
            let gate = DebounceGate()
            controller.taskGraphObserver.sleep = { try await gate.sleep($0) }
            await controller.startTaskGraphObserver()

            try await Self.createGraph(in: harness)
            await harness.presenter.waitForTaskGraphReservations(1)
            await gate.waitForEntries(1)

            // The debounced publication is drained; the quiescence publishes
            // with a reservation of its own.
            await controller.quiesceTaskGraphObserver()
            #expect(controller.taskGraphObserverTask == nil)
            var overviews = await harness.presenter.taskGraphOverviews
            #expect(overviews.count == 1)
            #expect(overviews.first?.origin == .automatic)
            #expect(overviews.first?.publication == ChatOverviewPublication(revision: 2))
            #expect(overviews.first?.overview?.graph.id == "graph")

            // While the observer is stopped a change reserves nothing; the
            // restart and its fresh publication recover it.
            let claimed = try #require(try await harness.runtime.taskOrchestrator.claimTasks(
                sessionID: sessionID,
                claims: [TaskClaim(taskID: "first", agentID: "worker")]
            ).first)
            #expect(await harness.presenter.taskGraphReservations.count == 2)
            await controller.startTaskGraphObserver()
            await controller.publishTaskGraphOverviewIfChanged(observedSessionID: sessionID)
            overviews = await harness.presenter.taskGraphOverviews
            #expect(overviews.count == 2)
            #expect(overviews.last?.publication == ChatOverviewPublication(revision: 3))
            #expect(overviews.last?.overview?.graph.tasks.first { $0.id == "first" }?.activeAttemptID
                == claimed.attemptID)
            await controller.stopTaskGraphObserver()
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
    func statusWithoutAGraphReservesAndClosesWithNoTaskGraph() async throws {
        try await withChatHarness { harness in
            #expect(await harness.controller.runTasksCommand(line: "/tasks")
                == ChatCommandOutcome(notices: [.noTaskGraph]))
            #expect(await harness.presenter.events == [
                .submittedCommand("/tasks"),
                .taskGraphReservation(ChatOverviewPublication(revision: 1)),
            ])
            #expect(ChatSessionNoticeText.text(for: .noTaskGraph) == "No task graph for this session.\n")
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

    @Test
    func anUnknownActionOrAMissingTaskIDIsRefusedAfterTheEcho() async throws {
        try await withChatHarness { harness in
            let controller = harness.controller
            #expect(await controller.runTasksCommand(line: "/tasks Frobnicate now")
                == ChatCommandOutcome(notices: [.unknownTasksAction(action: "frobnicate")]))
            #expect(await controller.runTasksCommand(line: "/tasks retry")
                == ChatCommandOutcome(notices: [.taskIDRequired(action: "retry")]))
            #expect(await controller.runTasksCommand(line: "/tasks cancel")
                == ChatCommandOutcome(notices: [.taskIDRequired(action: "cancel")]))
            #expect(await harness.presenter.events == [
                .submittedCommand("/tasks Frobnicate now"),
                .submittedCommand("/tasks retry"),
                .submittedCommand("/tasks cancel"),
            ])
            #expect(await harness.runtime.calls.isEmpty)
        }
    }

    @Test
    func theErrorsOfTasksKeepTheirTextAndChannel() {
        let missing = TerminalTaskCommandError.missingTaskID("show")
        let unknown = TerminalTaskCommandError.unknownAction("frobnicate")
        #expect(missing.localizedDescription == "/tasks show requires a task id.")
        #expect(unknown.localizedDescription
            == "Unknown /tasks action 'frobnicate'. Use status, show, retry, cancel, or clear.")
        #expect(ChatSessionNoticeText.text(for: .taskIDRequired(action: "show"))
            == "ZenCODE: \(missing.localizedDescription)\n")
        #expect(ChatSessionNoticeText.text(for: .unknownTasksAction(action: "frobnicate"))
            == "ZenCODE: \(unknown.localizedDescription)\n")
        #expect(ChatSessionNotice.taskIDRequired(action: "show").channel == .failure)
        #expect(ChatSessionNotice.unknownTasksAction(action: "frobnicate").channel == .failure)
    }

    @Test
    func aControllerThatOnlyRunsTurnsReadsTasksButCannotChangeThem() async throws {
        try await withChatHarness { harness in
            let sessionID = harness.controller.sessionID
            let controller = ChatSessionController(
                sessionID: sessionID,
                runtime: harness.runtime,
                environment: harness.controller.environment,
                workingDirectory: harness.workspace,
                presenter: harness.presenter,
                host: harness.host,
                authorizer: harness.controller.authorizer
            )
            try await Self.createGraph(in: harness)
            let unavailable = ChatCommandOutcome(notices: [.operationFailed(
                description: ChatPlanningCommandError.sessionOperationsUnavailable.localizedDescription
            )])

            #expect(await controller.runTasksCommand(line: "/tasks retry first") == unavailable)
            #expect(await controller.runTasksCommand(line: "/tasks cancel first") == unavailable)
            #expect(await controller.runTasksCommand(line: "/tasks clear") == unavailable)
            #expect(await harness.runtime.calls.isEmpty)

            let view = try await harness.runtime.taskOrchestrator.task(sessionID: sessionID, taskID: "first")
            #expect(await controller.runTasksCommand(line: "/tasks show first")
                == ChatCommandOutcome(notices: [.taskDetail(view)]))
            #expect(await controller.runTasksCommand(line: "/tasks") == ChatCommandOutcome())
            #expect(await harness.presenter.taskGraphOverviews.map { $0.origin } == [.explicit])
        }
    }

    // MARK: - Terminal

    @Test @ChatSessionActor
    func theTerminalOrdersItsSectionByReservationAndPresentsAnUnreservedOneAsItComes() async throws {
        let terminal = try Self.makeTerminal()
        let presenter = terminal.chatSession.presenter
        func overview(_ revision: Int, taskCount: Int = 2) -> ChatTaskGraphOverview {
            ChatTaskGraphOverview(
                graph: TaskGraphSnapshot(
                    id: "graph",
                    source: .manual,
                    state: .active,
                    revision: revision,
                    tasks: (0..<taskCount).map { TaskRecord(id: "task-\($0)", title: "Task \($0)", order: $0) }
                ),
                tasks: []
            )
        }
        func lastRenderedSignature() async -> String? {
            await terminal.renderCoordinator.snapshot().lastRenderedTaskGraphOverviewSignature
        }

        // A publication overtaken by a later reservation is dropped.
        let older = try #require(await presenter.reserveTaskGraphOverviewPublication())
        let newer = try #require(await presenter.reserveTaskGraphOverviewPublication())
        #expect(newer.revision > older.revision)
        await presenter.presentTaskGraphOverview(overview(1), origin: .automatic, publication: older)
        #expect(await lastRenderedSignature() == nil)
        await presenter.presentTaskGraphOverview(overview(1), origin: .automatic, publication: newer)
        #expect(await lastRenderedSignature() == overview(1).signature)

        // A reservation drops at once the section deferred behind a tool block.
        let toolCall = presentedToolCall(
            id: "wait-tool",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await terminal.writeToolCallStarted(toolCall)
        await presenter.presentTaskGraphOverview(
            overview(2),
            origin: .automatic,
            publication: await presenter.reserveTaskGraphOverviewPublication()
        )
        #expect(await terminal.renderCoordinator.snapshot().deferredTaskGraphOverviewRender)
        _ = await presenter.reserveTaskGraphOverviewPublication()
        #expect(!(await terminal.renderCoordinator.snapshot().deferredTaskGraphOverviewRender))
        await terminal.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )
        #expect(await lastRenderedSignature() == overview(1).signature)

        // Without a reservation the section is presented as it comes.
        await presenter.presentTaskGraphOverview(overview(3), origin: .automatic, publication: nil)
        #expect(await lastRenderedSignature() == overview(3).signature)

        // Below the threshold an automatic overview is not written; `/tasks`
        // always is, without becoming the remembered section.
        let trivial = overview(4, taskCount: 1)
        await presenter.presentTaskGraphOverview(
            trivial,
            origin: .automatic,
            publication: await presenter.reserveTaskGraphOverviewPublication()
        )
        #expect(await lastRenderedSignature() == overview(3).signature)
        await presenter.presentTaskGraphOverview(
            trivial,
            origin: .explicit,
            publication: await presenter.reserveTaskGraphOverviewPublication()
        )
        #expect(await lastRenderedSignature() == overview(3).signature)

        // No graph forgets the section.
        await presenter.presentTaskGraphOverview(
            nil,
            origin: .automatic,
            publication: await presenter.reserveTaskGraphOverviewPublication()
        )
        #expect(await lastRenderedSignature() == nil)
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

    @ChatSessionActor
    private static func makeTerminal() throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(
                "zencode-task-overview-\(UUID().uuidString)",
                isDirectory: true
            )
        )
        return TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: AgentCoreSessionRunner(taskGraphStore: nil)
        )
    }
}
