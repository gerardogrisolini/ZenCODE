import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    // MARK: - Standby lifecycle

    @Test
    func taskBoundAgentEntersStandbyAfterCompletingItsAttempt() async throws {
        let backend = CapturingSubAgentRuntimeBackend(responseText: "done")
        let (orchestrator, runtime) = try await standbyRuntime(backend: backend)

        let agent = try #require(await runtime.snapshots().first)
        let task = try await orchestrator.task(sessionID: "root", taskID: "task-a").task

        // The attempt completed; the task is awaiting validation.
        #expect(task.status == .awaitingValidation)
        #expect(task.activeAttemptID == nil)
        // The agent entered standby, not closed or idle.
        #expect(agent.status == .standby)
        // Standby agents are NOT pending: agent.wait must not block on them.
        #expect(agent.pending == false)

        await runtime.shutdown()
    }

    @Test
    func standbyAgentAcceptsMessagesWhileItsGraphIsActive() async throws {
        let backend = CapturingSubAgentRuntimeBackend(responseText: "done")
        let (_, runtime) = try await standbyRuntime(backend: backend)
        let agent = try #require(await runtime.snapshots().first)
        #expect(agent.status == .standby)
        #expect(await backend.sentPromptCount() == 1)

        // Sending a message should succeed and trigger a second turn.
        _ = try await runtime.messageAgents(
            arguments: [
                "id": .string(agent.id),
                "message": .string("Can you summarize?"),
            ]
        )
        await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agent.id)

        #expect(await backend.sentPromptCount() == 2)

        await runtime.shutdown()
    }

    @Test
    func completedTaskAgentEntersStandbyInManualGraph() async throws {
        let backend = CapturingSubAgentRuntimeBackend(responseText: "done")
        let (orchestrator, runtime) = try await standbyRuntime(
            backend: backend,
            graphID: "manual-graph",
            source: .manual,
            pendingTasks: [TaskDefinition(id: "task-b", title: "Later work")]
        )

        let agent = try #require(await runtime.snapshots().first)
        let task = try await orchestrator.task(sessionID: "root", taskID: "task-a").task

        // The attempt completed; the task is .completed (manual graph, no validation).
        #expect(task.status == .completed)
        #expect(task.activeAttemptID == nil)
        // The graph is still active because task-b is pending.
        let graph = try #require(await orchestrator.graphSnapshot(sessionID: "root", graphID: "manual-graph"))
        #expect(graph.state == .active)
        // The agent entered standby despite its task being .completed, because
        // the graph is still active and the task is not failed/cancelled.
        #expect(agent.status == .standby)
        #expect(agent.pending == false)

        await runtime.shutdown()
    }

    @Test
    func completedTaskAgentAcceptsMessagesWhileGraphIsActive() async throws {
        let backend = CapturingSubAgentRuntimeBackend(responseText: "done")
        let (_, runtime) = try await standbyRuntime(
            backend: backend,
            graphID: "manual-graph",
            source: .manual,
            pendingTasks: [TaskDefinition(id: "task-b", title: "Later work")]
        )
        let agent = try #require(await runtime.snapshots().first)
        #expect(agent.status == .standby)
        #expect(await backend.sentPromptCount() == 1)

        // Sending a message should succeed and trigger a second turn even
        // though the agent's task is already .completed.
        _ = try await runtime.messageAgents(
            arguments: [
                "id": .string(agent.id),
                "message": .string("Can you summarize?"),
            ]
        )
        await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agent.id)

        #expect(await backend.sentPromptCount() == 2)

        await runtime.shutdown()
    }

    @Test
    func standbyTurnDoesNotMutateTheTaskGraph() async throws {
        let backend = CapturingSubAgentRuntimeBackend(responseText: "response")
        let (orchestrator, runtime) = try await standbyRuntime(backend: backend)
        let agent = try #require(await runtime.snapshots().first)

        let taskBeforeStandbyTurn = try await orchestrator.task(
            sessionID: "root",
            taskID: "task-a"
        ).task
        let attemptsBefore = taskBeforeStandbyTurn.attempts.count

        // Trigger a standby turn.
        _ = try await runtime.messageAgents(
            arguments: [
                "id": .string(agent.id),
                "message": .string("Follow-up question"),
            ]
        )
        await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agent.id)

        let taskAfterStandbyTurn = try await orchestrator.task(
            sessionID: "root",
            taskID: "task-a"
        ).task
        #expect(taskAfterStandbyTurn.attempts.count == attemptsBefore)
        #expect(taskAfterStandbyTurn.status == .awaitingValidation)
        #expect(taskAfterStandbyTurn.activeAttemptID == nil)

        await runtime.shutdown()
    }

    @Test
    func standbyAgentIsReleasedWhenGraphCompletes() async throws {
        let backend = CapturingSubAgentRuntimeBackend(responseText: "done")
        let (orchestrator, runtime) = try await standbyRuntime(backend: backend)
        let agent = try #require(await runtime.snapshots().first)
        #expect(agent.status == .standby)

        // Task validation keeps the goal open and the agent in standby until
        // the coordinator explicitly finalizes the whole objective.
        _ = try await orchestrator.validateTaskResult(
            sessionID: "root",
            taskID: "task-a",
            succeeded: true
        )
        let ready = try #require(try await orchestrator.graphSnapshot(
            sessionID: "root",
            graphID: "workflow"
        ))
        #expect(ready.state == .active)
        #expect(await runtime.snapshots().first { $0.id == agent.id }?.status == .standby)
        let graph = try await orchestrator.updateWorkflow(
            sessionID: "root", graphID: ready.id, state: .completed,
            message: nil, expectedRevision: ready.revision
        )
        #expect(graph.state == .completed)

        // Backend shutdown is emitted only after the graph observer has released
        // the resident. It is the lifecycle edge under test, unlike a snapshot
        // poll that may run before the observer is scheduled.
        await backend.waitUntilShutdownCount(1)
        #expect(await runtime.snapshots().first { $0.id == agent.id }?.status == .closed)

        await runtime.shutdown()
    }

    @Test
    func standbyAgentIsSupersededByRetry() async throws {
        let backend = CapturingSubAgentRuntimeBackend(responseText: "done")
        let (orchestrator, runtime) = try await standbyRuntime(
            backend: backend,
            workerName: "worker-1"
        )
        let firstAgent = try #require(await runtime.snapshots().first)
        #expect(firstAgent.status == .standby)

        // Fail validation, then retry.
        _ = try await orchestrator.validateTaskResult(
            sessionID: "root",
            taskID: "task-a",
            succeeded: false,
            failureReason: "validation failed"
        )
        _ = try await orchestrator.retryTask(
            sessionID: "root",
            taskID: "task-a"
        )

        // Create a new agent for the retried task.
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker-2"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()

        let agents = await runtime.snapshots()
        let firstAgentAfter = agents.first { $0.id == firstAgent.id }
        // The first agent was superseded by the retried attempt: a `.standby`
        // resident is closed immediately when a newer attempt claims its task
        // (the release path). Assert the exact terminal status, not just that it
        // left `.standby`.
        #expect(firstAgentAfter?.status == .closed)

        await runtime.shutdown()
    }

    @Test
    func expireStandbyAgentsClosesAgentPastIdleTimeout() async throws {
        let (_, runtime, backend, agent) = try await standbyScenario()
        #expect(agent.status == .standby)

        // The reaper enforces `standbyIdleTimeout` (15 minutes in production).
        // Drive one expiration sweep with a clock past the timeout: the resident
        // is older than the limit, so it is closed and its backend is shut down
        // (no leak).
        let pastTimeout = Date().addingTimeInterval(
            DirectSubAgentRuntime.standbyIdleTimeout + 60
        )
        await runtime.expireStandbyAgents(now: pastTimeout)

        let snapshot = try #require(await runtime.snapshots().first { $0.id == agent.id })
        #expect(snapshot.status == .closed)
        #expect(snapshot.latestError == DirectSubAgentRuntime.standbyIdleTimeoutReason)
        #expect(await backend.shutdownCount() == 1)

        await runtime.shutdown()
    }

    @Test
    func standbyBudgetExhaustionClosesAgentWithoutLeakingBackend() async throws {
        let (_, runtime, backend, agent) = try await standbyScenario()
        #expect(agent.status == .standby)
        let budget = DirectSubAgentRuntime.maximumStandbyTurnsPerAgent

        // The turn budget is enforced at turn completion: each standby turn
        // bumps the counter, and the turn that reaches the limit releases the
        // agent (the same close path the reaper's `expireStandbyAgents` budget
        // branch uses — that branch is an unreachable backstop because the limit
        // is always enforced here first). The first `budget - 1` turns leave it
        // standing by.
        for _ in 0..<(budget - 1) {
            await runtime.recordStandbyTurnCompletion(agentID: agent.id)
        }
        let stillStandby = try #require(await runtime.snapshots().first { $0.id == agent.id })
        #expect(stillStandby.status == .standby)

        await runtime.recordStandbyTurnCompletion(agentID: agent.id)
        let closed = try #require(await runtime.snapshots().first { $0.id == agent.id })
        #expect(closed.status == .closed)
        #expect(closed.latestError == DirectSubAgentRuntime.standbyBudgetExhaustedReason)
        // Backend shut down exactly once: no leaked backend process.
        #expect(await backend.shutdownCount() == 1)

        await runtime.shutdown()
    }

    @Test
    func budgetExhaustedAgentIsClosedNotIdleAndRejectsStaleMessages() async throws {
        let (_, runtime, _, agent) = try await standbyScenario()
        #expect(agent.status == .standby)

        await exhaustStandbyBudget(agentID: agent.id, in: runtime)
        let closed = try #require(await runtime.snapshots().first { $0.id == agent.id })
        // Closed (and shut down) rather than left lingering in `.idle` after the
        // budget-exhausting turn is denied/finished.
        #expect(closed.status == .closed)
        #expect(closed.status != .idle)

        // A stale message to the now-closed agent is rejected instead of
        // reviving it (the authorization path keeps it finished).
        await #expect(throws: DirectSubAgentRuntimeError.self) {
            _ = try await runtime.messageAgents(
                arguments: [
                    "id": .string(agent.id),
                    "message": .string("Another follow-up"),
                ]
            )
        }

        await runtime.shutdown()
    }

    @Test
    func releaseDuringInFlightStandbyTurnClosesAgentAtTurnEnd() async throws {
        let backend = BlockingSubAgentRuntimeBackend(responseText: "follow-up done")
        let (orchestrator, runtime) = try await standbyRuntime(backend: backend)
        let agent = try #require(await runtime.snapshots().first)
        #expect(agent.status == .standby)

        // Drive the release deterministically: stop the async graph observer so
        // only the explicit call below releases the resident.
        await runtime.removeGraphObserver(rootSessionID: "root")

        // Queue a follow-up whose backend turn blocks, so the resident is
        // `.running` while the graph becomes terminal.
        await backend.blockNextPrompt()
        _ = try await runtime.messageAgents(
            arguments: [
                "id": .string(agent.id),
                "message": .string("Summarize the work"),
            ]
        )
        await backend.waitUntilBlocked()

        // The graph completes while the standby turn is in flight.
        _ = try await orchestrator.validateTaskResult(
            sessionID: "root",
            taskID: "task-a",
            succeeded: true
        )
        let ready = try #require(try await orchestrator.graphSnapshot(
            sessionID: "root",
            graphID: "workflow"
        ))
        let graph = try await orchestrator.updateWorkflow(
            sessionID: "root", graphID: ready.id, state: .completed,
            message: nil, expectedRevision: ready.revision
        )
        #expect(graph.state == .completed)

        // Releasing terminated graphs flags the in-flight resident for release
        // (it is NOT closed mid-response). A resident remains, so this returns
        // false.
        let noMoreResidents = await runtime.releaseTerminatedStandbyGraphs(rootSessionID: "root")
        #expect(noMoreResidents == false)
        let inFlight = try #require(await runtime.snapshots().first { $0.id == agent.id })
        #expect(inFlight.status == .running)

        // When the in-flight turn lands, the flagged release is completed and the
        // agent is closed — it never returns to `.standby`.
        await backend.release()
        await backend.waitUntilShutdown()
        #expect(await runtime.snapshots().first { $0.id == agent.id }?.status == .closed)
        #expect(await backend.shutdownCount() == 1)

        await runtime.shutdown()
    }

    @Test
    func interruptAgentsClosesStandbyResidentsAndStopsObserver() async throws {
        let (_, runtime, backend, agent) = try await standbyScenario()
        #expect(agent.status == .standby)
        // Entering standby started both the graph-completion observer and the
        // periodic reaper for this root session.
        #expect(await runtime.graphObserverTasks["root"] != nil)
        #expect(await runtime.standbyReaperTask != nil)

        // Interrupting the root session tears down its standby lifecycle: the
        // observer/reaper are stopped and the standby resident is released.
        let interrupted = await runtime.interruptAgents(rootSessionID: "root")
        #expect(interrupted == 1)

        let snapshot = try #require(await runtime.snapshots().first { $0.id == agent.id })
        #expect(snapshot.status == .closed)
        #expect(await backend.shutdownCount() == 1)
        #expect(await runtime.graphObserverTasks["root"] == nil)
        #expect(await runtime.standbyReaperTask == nil)

        await runtime.shutdown()
    }

    // Note on the git-status refresh behaviour (review #13, last bullet): that
    // predicate lives in the TerminalChat/TUI layer and is not reachable from a
    // `DirectSubAgentRuntime` unit test without driving a real TerminalChat. It
    // is intentionally not covered here to avoid a brittle, host-dependent TUI
    // test; the standby lifecycle the refresh depends on is covered above.
}

private enum StandbyFixtureError: Error { case agentNotReady }

/// Builds an active single-task graph and one task-bound agent that has finished
/// its attempt and entered `.standby`. Shared setup for the standby lifecycle
/// tests in this file.
private func standbyScenario(
    responseText: String = "done",
    rootSessionID: String = "root",
    graphID: String = "workflow",
    taskID: String = "task-a"
) async throws -> (
    SessionTaskOrchestrator,
    DirectSubAgentRuntime,
    CapturingSubAgentRuntimeBackend,
    DirectSubAgentRuntime.AgentSnapshot
) {
    let backend = CapturingSubAgentRuntimeBackend(responseText: responseText)
    let (orchestrator, runtime) = try await standbyRuntime(
        backend: backend,
        rootSessionID: rootSessionID,
        graphID: graphID,
        taskID: taskID
    )
    guard let agent = await runtime.snapshots().first,
          agent.status == .standby else {
        throw StandbyFixtureError.agentNotReady
    }
    return (orchestrator, runtime, backend, agent)
}

/// Drives an agent's standby turn counter to the limit, which closes it on the
/// turn that exhausts the budget. Used by the budget/denial tests.
private func exhaustStandbyBudget(
    agentID: String,
    in runtime: DirectSubAgentRuntime
) async {
    for _ in 0..<DirectSubAgentRuntime.maximumStandbyTurnsPerAgent {
        await runtime.recordStandbyTurnCompletion(agentID: agentID)
    }
}

/// A controllable `AgentRuntimeBackend` whose `sendPrompt` suspends until
/// `release()` is called, so a standby follow-up turn can be held in flight
/// while a test mutates the task graph. The first turn (the task attempt)
/// completes normally because the gate is armed only after standby is reached.
private actor BlockingSubAgentRuntimeBackend: AgentRuntimeBackend {
    private let responseText: String
    private var shutdownCalls = 0
    private var sentPrompts = 0
    private var shouldBlock = false
    private var released = false
    private var blocked = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var shutdownWaiters: [CheckedContinuation<Void, Never>] = []

    init(responseText: String = "done") {
        self.responseText = responseText
    }

    func blockNextPrompt() {
        shouldBlock = true
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { continuation in
            blockedWaiters.append(continuation)
        }
    }

    func shutdownCount() -> Int {
        shutdownCalls
    }

    func waitUntilShutdown() async {
        guard shutdownCalls == 0 else { return }
        await withCheckedContinuation { continuation in
            shutdownWaiters.append(continuation)
        }
    }

    func sentPromptCount() -> Int {
        sentPrompts
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        sentPrompts += 1
        if shouldBlock {
            shouldBlock = false
            // `released` guards against a `release()` that arrived before this
            // turn suspended: if so, skip the gate entirely (no deadlock).
            if !released {
                blocked = true
                let waiters = blockedWaiters
                blockedWaiters.removeAll()
                for waiter in waiters {
                    waiter.resume()
                }
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    self.continuation = continuation
                }
                blocked = false
            }
            released = false
        }
        return DirectAgentResponse(
            text: responseText,
            stopReason: "stop",
            modelID: "test-model"
        )
    }

    func createSession(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func createSessionIfNeeded(
        id _: String,
        cwd _: String,
        systemPrompt _: String?,
        history _: [AgentRuntimeMessage],
        cacheKey _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) async {}

    func shutdown() async {
        shutdownCalls += 1
        let waiters = shutdownWaiters
        shutdownWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }
}

/// Starts a task-bound first turn in an active graph, without asserting its
/// outcome. Callers keep their own task/agent checks and shutdown sequence.
private func standbyRuntime(
    backend: any AgentRuntimeBackend,
    rootSessionID: String = "root",
    graphID: String = "workflow",
    source: TaskGraphSource = .workflow,
    taskID: String = "task-a",
    workerName: String = "worker",
    pendingTasks: [TaskDefinition] = []
) async throws -> (SessionTaskOrchestrator, DirectSubAgentRuntime) {
    let orchestrator = SessionTaskOrchestrator()
    _ = try await orchestrator.createGraph(
        sessionID: rootSessionID,
        id: graphID,
        source: source,
        state: .active,
        tasks: [
            TaskDefinition(
                id: taskID,
                title: "Implement",
                execution: TaskExecutionSpec(executor: .subAgent)
            )
        ] + pendingTasks
    )
    let runtime = makeDirectSubAgentRuntime(backend: backend)
    await runtime.installTaskOrchestrator(orchestrator)
    _ = try await runtime.createAgents(
        arguments: [
            "name": .string(workerName),
            "profile": .string("Developer"),
            "taskID": .string(taskID),
            "prompt": .string("Do the work"),
        ],
        workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
        parentAllowedToolNames: nil,
        rootSessionID: rootSessionID
    )
    await runtime.waitForDirectSubAgentTestWorkLoops()
    return (orchestrator, runtime)
}
