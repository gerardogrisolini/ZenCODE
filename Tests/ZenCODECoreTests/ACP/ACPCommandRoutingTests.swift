//
//  ACPCommandRoutingTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

private final class ACPCommandWire: Sendable {
    private let storage = Mutex<[JSONValue]>([])

    var sink: ACPWriter.Sink {
        { [self] data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                storage.withLock { $0.append(value) }
            }
        }
    }

    func updateTexts(kind: String) -> [String] {
        storage.withLock { values in
            values.compactMap { value in
                guard let object = value.objectValue,
                      object["method"] == .string("session/update"),
                      let params = object["params"]?.objectValue,
                      let update = params["update"]?.objectValue,
                      update["sessionUpdate"] == .string(kind) else {
                    return nil
                }
                return update["content"]?.objectValue?["text"]?.stringValue
            }
        }
    }

    func stopReason(for id: Int) -> String? {
        storage.withLock { values in
            values.compactMap { value -> String? in
                guard let object = value.objectValue,
                      object["id"] == .number(Double(id)) else {
                    return nil
                }
                return object["result"]?.objectValue?["stopReason"]?.stringValue
            }.first
        }
    }
}

actor ScriptedACPCommandBackend: AgentRuntimeBackend {
    private var turn = 0
    private var prompts: [String] = []
    private var plannerSnapshot: DirectSubAgentRuntime.AgentSnapshot?
    private var closedPlannerIDs: [String] = []
    private var orchestrator: SessionTaskOrchestrator?
    private var workflowPauseState: TaskGraphWorkflowState = .awaitingUser
    private var interruptNextWorkflow = false
    private var failNextWorkflow = false
    private var pauseBeforeInterruption = false
    private var workflowIsSuspended = false

    func interruptWorkflow(fail: Bool, afterPause: Bool) {
        interruptNextWorkflow = true
        failNextWorkflow = fail
        pauseBeforeInterruption = afterPause
        workflowIsSuspended = false
    }

    func isWorkflowSuspended() -> Bool { workflowIsSuspended }

    func setWorkflowPauseState(_ state: TaskGraphWorkflowState) {
        workflowPauseState = state
    }

    func installTaskOrchestrator(_ orchestrator: SessionTaskOrchestrator) {
        self.orchestrator = orchestrator
    }

    private func pauseWorkflow(sessionID: String, message: String) async throws {
        let orchestrator = try #require(orchestrator)
        let graph = try #require(try await orchestrator.graphSnapshot(sessionID: sessionID))
        _ = try await orchestrator.updateWorkflow(
            sessionID: sessionID, graphID: graph.id,
            state: workflowPauseState, message: message, expectedRevision: graph.revision
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
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}
    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "scripted-acp-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        turn += 1
        prompts.append(prompt)
        if interruptNextWorkflow {
            interruptNextWorkflow = false
            if pauseBeforeInterruption {
                try await pauseWorkflow(sessionID: sessionID, message: "Persisted pause before interruption")
            }
            workflowIsSuspended = true
            if failNextWorkflow {
                throw NSError(domain: "ScriptedWorkflowProvider", code: 1)
            }
            try await Task.sleep(for: .seconds(60))
            try Task.checkCancellation()
        }
        // Workflow prompts are recognised by content, so `/goal` behaves the
        // same regardless of how many planning turns preceded it.
        if prompt.contains("Continue the active /goal workflow automatically") {
            let workflowQuestion = "Which remaining constraint should I apply?"
            try await pauseWorkflow(sessionID: sessionID, message: workflowQuestion)
            await onEvent(.content(workflowQuestion))
            return DirectAgentResponse(
                text: workflowQuestion,
                stopReason: "end_turn",
                modelID: "workflow-model"
            )
        }
        if prompt.contains("Continue the delegated workflow") {
            await onEvent(.content("WORKFLOW CONTINUED"))
            return DirectAgentResponse(
                text: "WORKFLOW CONTINUED",
                stopReason: "end_turn",
                modelID: "workflow-model"
            )
        }
        if prompt.contains("You are the coordinator of a delegated workflow") {
            // No heading: runtime suspension follows the persisted tool state.
            let workflowQuestion = "Which surface should I cover first?"
            try await pauseWorkflow(sessionID: sessionID, message: workflowQuestion)
            await onEvent(.content(workflowQuestion))
            return DirectAgentResponse(
                text: workflowQuestion,
                stopReason: "end_turn",
                modelID: "workflow-model"
            )
        }
        switch turn {
        case 1:
            let question = "# Planner questions\n1. Keep the discussion only in runtime memory?"
            plannerSnapshot = makePlannerSnapshot(
                sessionID: sessionID,
                revision: 1,
                output: question
            )
            await onEvent(.content("COORDINATOR INTERNAL QUESTION"))
            return DirectAgentResponse(
                text: "COORDINATOR INTERNAL QUESTION",
                stopReason: "end_turn",
                modelID: "coordinator-model"
            )
        case 2:
            let finalPlan = """
            Specifiche concordate
            - The discussion is runtime-only.

            Implementation plan
            1. Route /plan through the shared command kernel.
               Dependencies: none
            """
            plannerSnapshot = makePlannerSnapshot(
                sessionID: sessionID,
                revision: 2,
                output: finalPlan
            )
            await onEvent(.content("COORDINATOR INTERNAL FINAL"))
            let todoWrite = DirectAgentToolCall(
                id: "todo-acp-plan",
                name: "todo.write",
                argumentsObject: [
                    "mode": "upsert",
                    "todos": [[
                        "id": "plan-acp12345-1",
                        "content": "Route /plan through the shared command kernel.",
                        "status": "pending",
                        "dependsOn": [String](),
                    ]],
                ],
                argumentsJSON: "{}"
            )
            await onEvent(.toolCallCompleted(
                todoWrite,
                DirectAgentToolResult(output: "updated", summary: "updated")
            ))
            return DirectAgentResponse(
                text: "COORDINATOR INTERNAL FINAL",
                stopReason: "end_turn",
                modelID: "coordinator-model"
            )
        case 3:
            await onEvent(.content("IMPLEMENTATION RESULT"))
            return DirectAgentResponse(
                text: "IMPLEMENTATION RESULT",
                stopReason: "end_turn",
                modelID: "implementation-model"
            )
        default:
            await onEvent(.content("WORKFLOW RESULT"))
            return DirectAgentResponse(
                text: "WORKFLOW RESULT",
                stopReason: "end_turn",
                modelID: "workflow-model"
            )
        }
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        plannerSnapshot.map { [$0] } ?? []
    }

    func closeSubAgent(id: String) async -> Bool {
        guard let snapshot = plannerSnapshot, snapshot.id == id else { return false }
        closedPlannerIDs.append(id)
        plannerSnapshot = makePlannerSnapshot(
            sessionID: snapshot.rootSessionID,
            revision: snapshot.latestOutputRevision,
            output: snapshot.latestOutput ?? "",
            status: .closed
        )
        return true
    }

    func recordedPrompts() -> [String] {
        prompts
    }

    func closedIDs() -> [String] {
        closedPlannerIDs
    }

    private func makePlannerSnapshot(
        sessionID: String,
        revision: UInt64,
        output: String,
        status: DirectSubAgentRuntime.Status = .idle
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: "acp-plan-author",
            rootSessionID: sessionID,
            name: PlanningCommandKernel.planAuthorAgentName,
            role: AgentProfileStore.plannerAgentName,
            profileID: AgentProfileStore.plannerAgentID.uuidString,
            status: status,
            pending: false,
            modelID: "planner-model",
            latestOutput: output,
            latestOutputRevision: revision,
            latestError: nil,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: Double(revision + 1))
        )
    }
}

@Suite(.serialized)
struct ACPCommandRoutingTests {
    @Test
    func acpResolvesAgentMentionBeforePlanCommandButKeepsOriginalCommandVisible() async throws {
        let fixture = try await makeFixture(sessionID: "acp-command-mention")
        try await fixture.bridge.prompt(id: .number(1), params: [
            "sessionId": fixture.sessionID,
            "prompt": "@Developer /plan preserve mentioned command routing",
        ])

        #expect(fixture.wire.updateTexts(kind: "user_message_chunk").last
            == "@Developer /plan preserve mentioned command routing")
        let firstPrompt = try #require(await fixture.backend.recordedPrompts().first)
        #expect(firstPrompt.contains(
            "Planning goal requested by the user: preserve mentioned command routing"
        ))
        #expect(!firstPrompt.contains("@Developer"))
        #expect(
            await fixture.bridge.planStateForTesting(
                sessionID: fixture.sessionID
            ).brainstorming?.isAwaitingReply == true
        )

        // A later mention remains a normal agent-routed prompt rather than a
        // reply consumed by the pending Planner discussion.
        try await fixture.bridge.prompt(id: .number(2), params: [
            "sessionId": fixture.sessionID,
            "prompt": "@Reviewer inspect this independently",
        ])
        #expect(
            await fixture.bridge.planStateForTesting(
                sessionID: fixture.sessionID
            ).brainstorming?.isAwaitingReply == true
        )
        #expect((await fixture.backend.recordedPrompts()).last
            == "inspect this independently")
    }

    @Test
    func acpPlanQuestionsFinalPlanApprovalAndGoalUseSharedHiddenRouting() async throws {
        let fixture = try await makeFixture(sessionID: "acp-command-routing")
        let bridge = fixture.bridge
        let backend = fixture.backend
        let wire = fixture.wire
        let sessionID = fixture.sessionID

        try await bridge.prompt(id: .number(1), params: [
            "sessionId": sessionID,
            "prompt": "/plan unify ACP and Telegram",
        ])

        var state = await bridge.planStateForTesting(sessionID: sessionID)
        #expect(state.activePlan == nil)
        #expect(state.brainstorming?.isAwaitingReply == true)
        #expect(state.brainstorming?.plannerAgentID == "acp-plan-author")
        #expect(wire.updateTexts(kind: "user_message_chunk").contains(
            "/plan unify ACP and Telegram"
        ))
        let firstTurnMessages = wire.updateTexts(kind: "agent_message_chunk")
        #expect(firstTurnMessages.first?.hasPrefix("Agent:") == true)
        #expect(Array(firstTurnMessages.dropFirst()) == [
            "# Planner questions\n1. Keep the discussion only in runtime memory?"
        ])
        #expect(!wire.updateTexts(kind: "agent_message_chunk").contains {
            $0.contains("COORDINATOR INTERNAL")
        })
        #expect(wire.stopReason(for: 1) == "end_turn")

        try await bridge.prompt(id: .number(2), params: [
            "sessionId": sessionID,
            "prompt": "Yes, keep it runtime-only.",
        ])

        state = await bridge.planStateForTesting(sessionID: sessionID)
        let activePlan = try #require(state.activePlan)
        #expect(state.brainstorming == nil)
        #expect(activePlan.id == "plan-acp12345")
        #expect(activePlan.points.map(\.id) == ["plan-acp12345-1"])
        #expect(!activePlan.isApproved)
        let agentTexts = wire.updateTexts(kind: "agent_message_chunk")
        #expect(agentTexts.last?.hasPrefix("Specifiche concordate") == true)
        #expect(!agentTexts.contains { $0.contains("COORDINATOR INTERNAL") })

        let prompts = await backend.recordedPrompts()
        #expect(prompts.count == 2)
        #expect(prompts[0].contains("Planning goal requested by the user: unify ACP and Telegram"))
        #expect(!prompts[0].contains("/plan unify ACP and Telegram\n"))
        #expect(prompts[1].contains("agent.message"))
        #expect(prompts[1].contains("acp-plan-author"))
        #expect(prompts[1].contains("Yes, keep it runtime-only."))

        let history = try #require(
            await bridge.sessionRunner.snapshotSession(id: sessionID)
        ).history
        #expect(history.last?.content.hasPrefix("Specifiche concordate") == true)
        #expect(!history.contains { $0.content.contains("COORDINATOR INTERNAL") })

        try await bridge.prompt(id: .number(3), params: [
            "sessionId": sessionID,
            "prompt": "/plan save",
        ])
        try await bridge.prompt(id: .number(4), params: [
            "sessionId": sessionID,
            "prompt": "/plan status",
        ])
        try await bridge.prompt(id: .number(5), params: [
            "sessionId": sessionID,
            "prompt": "/plan list",
        ])
        #expect(wire.updateTexts(kind: "agent_message_chunk").contains {
            $0.contains("Saved plan: plan-acp12345")
        })
        #expect(wire.updateTexts(kind: "agent_message_chunk").contains {
            $0.contains("## Plan status")
        })
        #expect(wire.updateTexts(kind: "agent_message_chunk").contains {
            $0.contains("## Saved plans")
        })

        try await bridge.prompt(id: .number(6), params: [
            "sessionId": sessionID,
            "prompt": "/plan approve",
        ])
        state = await bridge.planStateForTesting(sessionID: sessionID)
        #expect(state.activePlan?.isApproved == true)
        let planGraph = try #require(
            try await bridge.sessionRunner.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: activePlan.id
            )
        )
        #expect(planGraph.state == .active)
        #expect(planGraph.tasks.map(\.id) == ["plan-acp12345-1"])
        #expect((await backend.recordedPrompts()).last?.contains(
            "Implement the active approved plan now"
        ) == true)

        try await bridge.prompt(id: .number(7), params: [
            "sessionId": sessionID,
            "prompt": "/plan clear",
        ])
        state = await bridge.planStateForTesting(sessionID: sessionID)
        #expect(state.activePlan == nil)
        #expect(state.brainstorming == nil)

        try await bridge.prompt(id: .number(8), params: [
            "sessionId": sessionID,
            "prompt": "/plan load",
        ])
        state = await bridge.planStateForTesting(sessionID: sessionID)
        #expect(state.activePlan?.id == "plan-acp12345")
        #expect(state.activePlan?.isApproved == false)
        #expect(try #require(
            await bridge.sessionRunner.snapshotSession(id: sessionID)
        ).history.contains { $0.content.contains("[Saved plan handoff]") })

        try await bridge.prompt(id: .number(9), params: [
            "sessionId": sessionID,
            "prompt": "/plan clear",
        ])
        try await bridge.prompt(id: .number(10), params: [
            "sessionId": sessionID,
            "prompt": "/goal validate shared workflow routing",
        ])
        let workflowGraphs = try await bridge.sessionRunner.taskGraphSnapshots(
            sessionID: sessionID
        ).filter { graph in
            if case .workflow = graph.source { return true }
            return false
        }
        #expect(workflowGraphs.count == 1)
        #expect((await backend.recordedPrompts()).last?.contains(
            "Goal: validate shared workflow routing"
        ) == true)
        #expect(wire.updateTexts(kind: "user_message_chunk").suffix(4) == [
            "/plan clear",
            "/plan load",
            "/plan clear",
            "/goal validate shared workflow routing",
        ])

        try await bridge.prompt(id: .number(11), params: [
            "sessionId": sessionID,
            "prompt": "/review focus on ACP routing",
        ])
        let reviewPrompt = try #require(await backend.recordedPrompts().last)
        #expect(reviewPrompt.contains("read-only review requested through ACP"))
        #expect(reviewPrompt.contains("Review focus requested by the user: focus on ACP routing"))
        #expect(reviewPrompt.contains(AgentProfileStore.reviewerAgentID.uuidString))
        #expect(reviewPrompt.contains("graph=workflow_"))
        #expect(wire.updateTexts(kind: "user_message_chunk").last
            == "/review focus on ACP routing")
        #expect(wire.stopReason(for: 11) == "end_turn")
    }

    @Test
    func acpRestoreDropsUnfinishedBrainstormingAndClosesItsPlanner() async throws {
        let fixture = try await makeFixture(sessionID: "acp-command-restore")
        try await fixture.bridge.prompt(id: .number(1), params: [
            "sessionId": fixture.sessionID,
            "prompt": "/plan clarify restore behavior",
        ])
        #expect(
            await fixture.bridge.planStateForTesting(
                sessionID: fixture.sessionID
            ).brainstorming?.isAwaitingReply == true
        )

        try await fixture.bridge.restoreSession(
            id: .number(2),
            params: ["sessionId": fixture.sessionID],
            replayHistory: false
        )

        let restored = await fixture.bridge.planStateForTesting(
            sessionID: fixture.sessionID
        )
        #expect(restored.brainstorming == nil)
        #expect(await fixture.backend.closedIDs() == ["acp-plan-author"])

        // The visible question may remain in ordinary history, but it must not
        // be promoted into the persistent plan library after restore.
        try await fixture.bridge.prompt(id: .number(3), params: [
            "sessionId": fixture.sessionID,
            "prompt": "/plan save",
        ])
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").contains {
            $0.contains("no completed plan is available to save")
        })
        #expect(await fixture.bridge.sessionRunner.savedTaskPlans(
            workingDirectory: fixture.bridge.configuration.workingDirectory
        ).isEmpty)
    }

    @Test
    func acpCancelAbandonsThePlannerCollectionInsteadOfLeavingAZombie() async throws {
        let fixture = try await makeFixture(sessionID: "acp-command-cancel")
        try await fixture.bridge.prompt(id: .number(1), params: [
            "sessionId": fixture.sessionID,
            "prompt": "/plan clarify cancellation",
        ])
        #expect(await fixture.bridge.planStateForTesting(
            sessionID: fixture.sessionID
        ).brainstorming?.isAwaitingReply == true)

        try await fixture.bridge.cancel(id: .number(2), params: [
            "sessionId": fixture.sessionID,
        ])

        #expect(await fixture.bridge.planStateForTesting(
            sessionID: fixture.sessionID
        ).brainstorming == nil)
        #expect(await fixture.backend.closedIDs() == ["acp-plan-author"])
    }

    @Test
    func acpRepliesContinueAnOpenWorkflowOnTheSameGraphOnlyWhenItAsked() async throws {
        let fixture = try await makeFixture(sessionID: "acp-workflow-continuation")
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID

        try await bridge.prompt(id: .number(1), params: [
            "sessionId": sessionID,
            "prompt": "/goal ship cross-surface parity",
        ])
        let graph = try #require(try await bridge.sessionRunner.taskGraphSnapshot(
            sessionID: sessionID
        ))
        let armed = try #require(await bridge.workflowStateForTesting(sessionID: sessionID))
        #expect(armed.graphID == graph.id)
        #expect(armed.isAwaitingReply)

        // A plain ACP message continues that same graph, exactly like the TUI.
        try await bridge.prompt(id: .number(2), params: [
            "sessionId": sessionID,
            "prompt": "Start with ACP.",
        ])
        let prompts = await fixture.backend.recordedPrompts()
        let continuationPrompt = try #require(prompts.dropLast().last)
        #expect(continuationPrompt.contains("Continue the delegated workflow"))
        #expect(continuationPrompt.contains("Active workflow task graph: \(graph.id)"))
        #expect(continuationPrompt.contains("Start with ACP."))
        #expect(continuationPrompt.contains("Which surface should I cover first?"))

        // The backend ended that generation with an ordinary progress response
        // while the graph was still open. `/goal` must immediately re-enter the
        // coordinator instead of returning as a normal chat turn.
        let automaticPrompt = try #require(prompts.last)
        #expect(automaticPrompt.contains("Continue the active /goal workflow automatically"))
        #expect(automaticPrompt.contains("Goal: ship cross-surface parity"))
        #expect(automaticPrompt.contains("Active workflow task graph: \(graph.id)"))
        #expect(await bridge.workflowStateForTesting(sessionID: sessionID)?
            .isAwaitingReply == true)

        // A second /goal is refused with an actionable message, not graphNotMutable.
        try await bridge.prompt(id: .number(3), params: [
            "sessionId": sessionID,
            "prompt": "/goal start another one",
        ])
        let refusal = try #require(fixture.wire.updateTexts(kind: "agent_message_chunk").last)
        #expect(refusal.contains("a delegated workflow is already running"))
        #expect(refusal.contains(graph.id))
        #expect(!refusal.localizedCaseInsensitiveContains("graphNotMutable"))
    }

    @Test
    func legacyACPWorkflowSignalUsesOnlyTheFinalAssistantBlockAfterTools() async {
        let questionThenSummary = ACPAssistantBlockCollector()
        await questionThenSummary.append("Workflow question\nWhich surface?")
        await questionThenSummary.finishBlock()
        await questionThenSummary.append("Summary: task list refreshed.")

        var state = WorkflowCommandRuntimeState(goal: "Ship it", graphID: "workflow_test")
        let ignoredSummary = state.recordCoordinatorOutput(await questionThenSummary.lastBlock())
        #expect(!ignoredSummary)
        #expect(!state.isAwaitingReply)

        let progressThenQuestion = ACPAssistantBlockCollector()
        await progressThenQuestion.append("Progress: task list refreshed.")
        await progressThenQuestion.finishBlock()
        await progressThenQuestion.append("Workflow question\nWhich surface?")
        let recordedQuestion = state.recordCoordinatorOutput(await progressThenQuestion.lastBlock())
        #expect(recordedQuestion)
        #expect(state.isAwaitingReply)
    }

    @Test
    func acpFailedWorkflowTurnKeepsANonEmptyGraphAndArmsRecovery() async throws {
        let fixture = try await makeFixture(sessionID: "acp-workflow-recovery")
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        let graphID = "workflow_recovery_case"
        _ = try await bridge.sessionRunner.taskOrchestrator.createGraph(
            sessionID: sessionID,
            id: graphID,
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "t1",
                    title: "Delegated work",
                    execution: TaskExecutionSpec(executor: .subAgent)
                ),
            ]
        )

        let promptID = UUID()
        await bridge.reserveWorkflowPromptForTesting(sessionID: sessionID, promptID: promptID)
        await bridge.handleFailedACPWorkflowTurn(
            graphID: graphID,
            reason: "the turn was cancelled",
            sessionID: sessionID,
            epoch: await bridge.sessionEpochForTesting(sessionID: sessionID),
            promptID: promptID
        )

        let graph = try #require(try await bridge.sessionRunner.taskGraphSnapshot(
            sessionID: sessionID
        ))
        #expect(graph.id == graphID)
        #expect(graph.tasks.count == 1)
        let recovery = try #require(await bridge.workflowStateForTesting(sessionID: sessionID))
        #expect(recovery.graphID == graphID)
        #expect(recovery.isAwaitingReply)
        #expect(recovery.pendingCoordinatorMessage?.contains("the turn was cancelled") == true)
    }

    @Test
    func acpBlockedWorkflowStopsAndRestoreReinjectsItsOriginalObjective() async throws {
        let fixture = try await makeFixture(sessionID: "acp-workflow-blocked")
        await fixture.backend.setWorkflowPauseState(.blocked)
        try await fixture.bridge.prompt(id: .number(1), params: [
            "sessionId": fixture.sessionID, "prompt": "/goal preserve the full objective",
        ])
        let blocked = try #require(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: fixture.sessionID))
        #expect(blocked.workflow?.state == .blocked)
        #expect(blocked.workflow?.originalGoal == "preserve the full objective")
        #expect(await fixture.backend.recordedPrompts().count == 1)
        #expect(fixture.wire.stopReason(for: 1) == "end_turn")
        try await fixture.bridge.restoreSession(
            id: .number(2), params: ["sessionId": fixture.sessionID], replayHistory: false
        )
        try await fixture.bridge.prompt(id: .number(3), params: [
            "sessionId": fixture.sessionID, "prompt": "The external blocker is resolved",
        ])
        let prompts = await fixture.backend.recordedPrompts()
        let continuation = try #require(prompts.first { $0.contains("Continue the delegated workflow") })
        #expect(continuation.contains("Goal: preserve the full objective"))
        #expect(continuation.contains("Active workflow task graph: \(blocked.id)"))
        #expect(continuation.contains("The external blocker is resolved"))
        let after = try #require(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: fixture.sessionID))
        #expect(after.id == blocked.id)
        #expect(after.workflow?.originalGoal == blocked.workflow?.originalGoal)
    }

    @Test
    func staleACPWorkflowFailureCannotArmAnotherPrompt() async throws {
        let fixture = try await makeFixture(sessionID: "acp-workflow-stale")
        let graph = try await fixture.bridge.sessionRunner.taskOrchestrator.createGraph(
            sessionID: fixture.sessionID, id: "workflow-stale", source: .workflow, state: .active,
            tasks: [], originalGoal: "Keep this goal"
        )
        await fixture.bridge.reserveWorkflowPromptForTesting(sessionID: fixture.sessionID, promptID: UUID())
        await fixture.bridge.handleFailedACPWorkflowTurn(
            graphID: graph.id, reason: "stale", sessionID: fixture.sessionID,
            epoch: await fixture.bridge.sessionEpochForTesting(sessionID: fixture.sessionID), promptID: UUID()
        )
        #expect(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: fixture.sessionID) == graph)
        #expect(await fixture.bridge.workflowStateForTesting(sessionID: fixture.sessionID) == nil)
    }

    @Test(arguments: [false, true], [TaskGraphWorkflowState.running, .awaitingUser, .blocked])
    func realSessionCancelRearmsFirstTurnAndConsumedReply(afterReply: Bool, state: TaskGraphWorkflowState) async throws {
        let fixture = try await makeFixture(sessionID: "acp-real-cancel-\(UUID().uuidString)")
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        if afterReply {
            try await bridge.prompt(id: .number(1), params: [
                "sessionId": sessionID, "prompt": "/goal Keep cancel objective",
            ])
        }
        await fixture.backend.setWorkflowPauseState(state)
        await fixture.backend.interruptWorkflow(fail: false, afterPause: state != .running)
        let generation = Task {
            try await bridge.prompt(id: .number(2), params: [
                "sessionId": sessionID,
                "prompt": afterReply ? "First answer" : "/goal Keep cancel objective",
            ])
        }
        defer { generation.cancel() }
        for _ in 0..<500 {
            if await fixture.backend.isWorkflowSuspended() { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await fixture.backend.isWorkflowSuspended())
        let before = try #require(try await bridge.sessionRunner.taskGraphSnapshot(sessionID: sessionID))
        try await bridge.cancel(id: .number(3), params: ["sessionId": sessionID])
        _ = try await generation.value
        #expect(await bridge.workflowStateForTesting(sessionID: sessionID)?.isAwaitingReply == true)
        await fixture.backend.setWorkflowPauseState(.awaitingUser)
        try await bridge.prompt(id: .number(4), params: ["sessionId": sessionID, "prompt": "Retry after real cancel"])
        let prompts = await fixture.backend.recordedPrompts()
        let resumed = try #require(prompts.first { $0.contains("Retry after real cancel") })
        #expect(resumed.contains("Continue the delegated workflow"))
        #expect(resumed.contains("Goal: Keep cancel objective"))
        #expect(resumed.contains("Active workflow task graph: \(before.id)"))
        if state != .running {
            #expect(resumed.contains("Persisted pause before interruption"))
        }
        if afterReply {
            #expect(resumed.contains("First answer"))
        }
        let after = try #require(try await bridge.sessionRunner.taskGraphSnapshot(sessionID: sessionID))
        #expect(after.id == before.id)
        #expect(after.workflow?.originalGoal == before.workflow?.originalGoal)
        #expect(after.tasks == before.tasks)
    }

    @Test(arguments: [TaskGraphWorkflowState.running, .awaitingUser, .blocked])
    func providerFailurePreservesZeroTaskWorkflowAndStructuredPause(state: TaskGraphWorkflowState) async throws {
        let fixture = try await makeFixture(sessionID: "acp-provider-failure-\(UUID().uuidString)")
        await fixture.backend.setWorkflowPauseState(state)
        await fixture.backend.interruptWorkflow(fail: true, afterPause: state != .running)
        do {
            try await fixture.bridge.prompt(id: .number(1), params: [
                "sessionId": fixture.sessionID, "prompt": "/goal Preserve provider failure objective",
            ])
            Issue.record("Il provider simulato deve restituire un errore")
        } catch {
            #expect(await fixture.backend.isWorkflowSuspended())
        }
        let graph = try #require(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: fixture.sessionID))
        #expect(graph.tasks.isEmpty)
        #expect(graph.workflow?.originalGoal == "Preserve provider failure objective")
        #expect(graph.workflow?.state == state)
        let projection = try #require(await fixture.bridge.workflowStateForTesting(sessionID: fixture.sessionID))
        #expect(projection.isAwaitingReply)
        if state != .running {
            #expect(projection.pendingCoordinatorMessage == "Persisted pause before interruption")
        }
    }

    @Test
    func cancellingOrdinaryReservationDoesNotArmStaleWorkflowProjection() async throws {
        let fixture = try await makeFixture(sessionID: "acp-ordinary-cancel-\(UUID().uuidString)")
        let graph = try await fixture.bridge.sessionRunner.taskOrchestrator.createGraph(
            sessionID: fixture.sessionID, id: "ordinary-cancel-workflow", source: .workflow,
            state: .active, tasks: [], originalGoal: "Do not capture ordinary chat"
        )
        await fixture.bridge.installDisarmedWorkflowForTesting(sessionID: fixture.sessionID, graphID: graph.id)
        await fixture.bridge.reserveWorkflowPromptForTesting(sessionID: fixture.sessionID, promptID: UUID())
        try await fixture.bridge.cancel(id: .number(1), params: ["sessionId": fixture.sessionID])
        #expect(await fixture.bridge.workflowStateForTesting(sessionID: fixture.sessionID)?.isAwaitingReply == false)
        #expect(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: fixture.sessionID) == graph)
    }

    private func makeFixture(
        sessionID: String
    ) async throws -> (
        bridge: ZenCODEACPBridge,
        backend: ScriptedACPCommandBackend,
        wire: ACPCommandWire,
        sessionID: String
    ) {
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(sessionID, isDirectory: true)
        let backend = ScriptedACPCommandBackend()
        let wire = ACPCommandWire()
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [
                AgentSettingsModelManifest(
                    id: "test-model",
                    kind: .remoteAPI,
                    modelID: "local/test-model"
                ),
            ],
            runMode: .acp,
            workingDirectory: workingDirectory
        )
        let bridge = ZenCODEACPBridge(
            configuration: configuration,
            writer: ACPWriter(sink: wire.sink),
            backendFactory: { _, _ in backend }
        )
        let sessionConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: workingDirectory,
            systemPrompt: "ACP command routing test",
            cacheKey: nil,
            history: [],
            allowedToolNames: nil
        )
        try await bridge.sessionRunner.createSession(
            configuration: sessionConfiguration
        )
        await bridge.installTestSession(sessionConfiguration)
        return (bridge, backend, wire, sessionID)
    }
}

extension ZenCODEACPBridge {
    fileprivate func installDisarmedWorkflowForTesting(sessionID: String, graphID: String) {
        sessions[sessionID]?.workflowContinuation = WorkflowCommandRuntimeState(goal: "Do not capture ordinary chat", graphID: graphID)
    }

    fileprivate func reserveWorkflowPromptForTesting(sessionID: String, promptID: UUID) {
        sessions[sessionID]?.activePromptID = promptID
        sessions[sessionID]?.operationState = .prompting(promptID)
    }
}
