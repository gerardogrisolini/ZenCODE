//
//  ChatSessionControllerTests+Plans.swift
//  ZenCODE
//
//  Controller tests for the /plan and /goal workflow turns, with the planner
//  fixtures they script and the plan-turn fence helper.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension ChatSessionControllerTests {
    // MARK: - /plan

    @Test
    func planTurnHidesCoordinatorContentCollectsTodoWritesAndRecordsAnUnapprovedPlan() async throws {
        try await withHarness { harness in
            try await seedPlannerDiscussion(harness)
            let sessionID = harness.sessionID
            await harness.runtime.append { call in
                await call.onEvent(.thought("Drafting the plan."))
                await call.onEvent(.content("COORDINATOR INTERNAL FINAL"))
                await call.onEvent(.toolCallStarted(planTodoWrite))
                await call.onEvent(.toolCallCompleted(
                    planTodoWrite,
                    DirectAgentToolResult(output: "updated", summary: "updated")
                ))
                await call.runtime.setPlannerSnapshots([
                    plannerSnapshot(rootSessionID: sessionID, revision: 2, output: plannerFinalPlan),
                ])
                return DirectAgentResponse(
                    text: "COORDINATOR INTERNAL FINAL",
                    stopReason: "end_turn",
                    modelID: "coordinator-model"
                )
            }

            let result = try await harness.controller.runTurn(
                harness.request("Plan the chat controller", purpose: .plan(originalGoal: planGoal))
            )

            // Coordinator content is never presented; tools and thoughts still are.
            let events = await harness.presenter.events
            #expect(!events.contains { if case .content = $0 { true } else { false } })
            #expect(events == [
                .turnWillStart(prompt: "Plan the chat controller"),
                .thought("Drafting the plan."),
                .toolStarted("todo-plan"),
                .toolCompleted("todo-plan"),
                .toolSettled("todo-plan"),
                .modelTurnDidReturn,
                .turnWillFinish,
            ])

            // The Planner's final text replaces the coordinator response.
            #expect(result.response.text == plannerFinalPlan)
            #expect(result.response.modelID == "planner-model")
            #expect(result.finalAssistantBlock == plannerFinalPlan)

            let plan = try #require(harness.controller.commandState.activePlan)
            #expect(!plan.isApproved)
            #expect(plan.originalGoal == planGoal)
            #expect(plan.consolidatedText == plannerFinalPlan)
            #expect(plan.points.map(\.id) == ["plan-chatctl01-1", "plan-chatctl01-2"])
            #expect(plan.points.map(\.status) == [.pending, .pending])
            #expect(plan.points[1].dependsOn == ["plan-chatctl01-1"])
            #expect(harness.controller.commandState.planBrainstorming == nil)

            // The runtime history carries the Planner output, not the coordinator's.
            let replaced = await harness.runtime.replacedHistories
            #expect(replaced.count == 1)
            #expect(replaced.first?.last?.content == plannerFinalPlan)
            #expect(harness.controller.history.last?.content == plannerFinalPlan)

            let transcript = harness.controller.transcript
            #expect(transcript.contains { $0.role == .assistant && $0.content == plannerFinalPlan })
            #expect(!transcript.contains { $0.content.contains("COORDINATOR INTERNAL") })
        }
    }

    @Test
    func multiPlanTurnRecordsTheFirstPlanAndQueuesTheOthersThenASinglePlanClearsTheQueue() async throws {
        try await withHarness { harness in
            try await seedPlannerDiscussion(harness)
            let sessionID = harness.sessionID
            await harness.runtime.append { call in
                await call.onEvent(.toolCallStarted(twoPlanTodoWrite))
                await call.onEvent(.toolCallCompleted(
                    twoPlanTodoWrite,
                    DirectAgentToolResult(output: "updated", summary: "updated")
                ))
                await call.runtime.setPlannerSnapshots([
                    plannerSnapshot(rootSessionID: sessionID, revision: 2, output: plannerTwoPlanFinalPlan),
                ])
                return DirectAgentResponse(text: "COORDINATOR", stopReason: "end_turn", modelID: "coordinator-model")
            }

            let result = try await harness.controller.runTurn(
                harness.request("Plan the chat controller", purpose: .plan(originalGoal: planGoal))
            )

            #expect(result.response.text == plannerTwoPlanFinalPlan)
            let active = try #require(harness.controller.activePlan)
            #expect(active.id == "plan-chatctl01")
            #expect(!active.isApproved)
            #expect(active.originalGoal == "Piano 1/2: Shared controller — \(planGoal)")
            #expect(active.consolidatedText == plannerTwoPlanFirstSection)
            #expect(active.points.map(\.id) == ["plan-chatctl01-1", "plan-chatctl01-2"])
            #expect(active.points[1].dependsOn == ["plan-chatctl01-1"])
            let queued = harness.controller.queuedPlans
            #expect(queued.map(\.id) == ["plan-chatctl02"])
            #expect(queued.first?.originalGoal == "Piano 2/2: Channels — \(planGoal)")
            #expect(queued.first?.consolidatedText == plannerTwoPlanSecondSection)
            #expect(queued.first?.points.map(\.id) == ["plan-chatctl02-1"])
            #expect(queued.first?.isApproved == false)
            #expect(harness.controller.commandState.planBrainstorming == nil)
            // The whole sequence is the Planner output in the history.
            #expect(harness.controller.history.last?.content == plannerTwoPlanFinalPlan)

            // A later single plan replaces the active plan and clears the queue.
            try await seedPlannerDiscussion(harness)
            await harness.runtime.append { call in
                await call.onEvent(.toolCallStarted(planTodoWrite))
                await call.onEvent(.toolCallCompleted(
                    planTodoWrite,
                    DirectAgentToolResult(output: "updated", summary: "updated")
                ))
                await call.runtime.setPlannerSnapshots([
                    plannerSnapshot(rootSessionID: sessionID, revision: 2, output: plannerFinalPlan),
                ])
                return DirectAgentResponse(text: "COORDINATOR", stopReason: "end_turn", modelID: "coordinator-model")
            }
            _ = try await harness.controller.runTurn(
                harness.request("Plan it again", purpose: .plan(originalGoal: planGoal))
            )

            let single = try #require(harness.controller.activePlan)
            #expect(single.originalGoal == planGoal)
            #expect(single.consolidatedText == plannerFinalPlan)
            #expect(single.points.map(\.id) == ["plan-chatctl01-1", "plan-chatctl01-2"])
            #expect(harness.controller.queuedPlans.isEmpty)
        }
    }

    @Test
    func planTurnWithoutFreshPlannerOutputFailsAndRecordsNoPlan() async throws {
        try await withHarness { harness in
            try await seedPlannerDiscussion(harness)
            await harness.runtime.append { call in
                await call.onEvent(.content("The coordinator tried to answer by itself."))
                return DirectAgentResponse(text: "self", stopReason: "end_turn", modelID: "coordinator-model")
            }

            let failure = try #require(await turnFailure(
                harness.controller,
                harness.request("Plan again", purpose: .plan(originalGoal: planGoal))
            ))

            let error = try #require(failure.underlying as? ChatPlanGenerationError)
            guard case .plannerOutputUnavailable = error else {
                Issue.record("expected plannerOutputUnavailable, got \(error)")
                return
            }
            #expect(!failure.isCancellation)
            #expect(harness.controller.commandState.activePlan == nil)
            #expect(harness.controller.commandState.planBrainstorming == nil)
            #expect(await harness.runtime.replacedHistories.isEmpty)
            #expect(await harness.presenter.events.last == .turnWillFinish)
        }
    }

    // MARK: - /goal

    @Test
    func workflowTurnWithAnOpenGraphContinuesAutomaticallyWithTheContinuationPrompt() async throws {
        try await withHarness { harness in
            let goal = "Ship the chat controller"
            let graph = try await harness.runtime.taskOrchestrator.createGraph(
                sessionID: harness.sessionID,
                id: "workflow_chat_controller",
                source: .workflow,
                state: .active,
                tasks: [],
                originalGoal: goal
            )
            harness.controller.stateStore.withLock {
                $0.commandState.activeWorkflow = WorkflowCommandRuntimeState(
                    goal: goal,
                    graphID: graph.id
                )
            }
            let sessionID = harness.sessionID
            let question = "Which target should I use?"
            await harness.runtime.append { call in
                // The graph stays running: no clarification, no completion.
                await call.onEvent(.content("Planning the work."))
                return DirectAgentResponse(text: "Planning the work.", stopReason: "end_turn", modelID: "m")
            }
            await harness.runtime.append { call in
                let orchestrator = call.runtime.taskOrchestrator
                let current = try #require(try await orchestrator.graphSnapshot(
                    sessionID: sessionID,
                    graphID: graph.id
                ))
                try await orchestrator.updateWorkflow(
                    sessionID: sessionID,
                    graphID: graph.id,
                    state: .awaitingUser,
                    message: question,
                    expectedRevision: current.revision
                )
                await call.onEvent(.content(question))
                return DirectAgentResponse(text: question, stopReason: "end_turn", modelID: "m")
            }
            let instructions = CallCounter()
            let attachment = AgentRuntimeAttachment(
                kind: .image,
                data: Data([0x01]),
                contentType: "image/png",
                originalFilename: "shot.png"
            )

            let result = try await harness.controller.runTurn(harness.request(
                "Start the goal",
                purpose: .workflow(originalGoal: goal, graphID: graph.id),
                attachments: [attachment],
                turnInstructionProvider: { "instruction-\(instructions.next())" }
            ))

            let prompts = await harness.runtime.prompts
            #expect(prompts.count == 2)
            #expect(prompts.first == "Start the goal")
            #expect(prompts.last == PlanningCommandKernel.workflowAutomaticContinuationPrompt(
                goal: goal,
                graph: graph
            ))
            #expect(prompts.last?.contains("Continue the active /goal workflow automatically") == true)
            #expect(prompts.last?.contains("Active workflow task graph: \(graph.id)") == true)
            // Attachments belong to the first request only, and the turn
            // instruction is evaluated again for the continuation.
            #expect(await harness.runtime.attachmentCounts == [1, 0])
            #expect(await harness.runtime.turnInstructions == ["instruction-1", "instruction-2"])

            #expect(await harness.presenter.events == [
                .turnWillStart(prompt: "Start the goal"),
                .content("Planning the work."),
                .modelTurnDidReturn,
                .continueAutomatically,
                .content(question),
                .modelTurnDidReturn,
                .turnWillFinish,
                .workflowNotice(.awaitingReply(graphID: graph.id, pendingTaskCount: 0)),
            ])
            #expect(result.finalAssistantBlock == question)
            let workflow = try #require(harness.controller.commandState.activeWorkflow)
            #expect(workflow.isAwaitingReply)
            #expect(workflow.pendingSignal?.transcriptMessage == question)
        }
    }

    /// Changing the session or cancelling the active turn fences the plan turn.
    @Test(arguments: [false, true])
    func changingTheSessionDuringAPlanTurnDoesNotRecordThePlannerPlan(cancelling: Bool) async throws {
        try await runFencedPlanTurn { harness in
            if cancelling {
                harness.controller.cancelActiveTurn()
            } else {
                harness.controller.sessionID = "another-session"
            }
        }
    }

    /// Runs a `/plan` turn parked mid-flight, applies `invalidate`, then lets
    /// it finish: the obsolete turn must fail as cancelled and record no plan.
    private func runFencedPlanTurn(
        invalidate: @escaping @Sendable @ChatSessionActor (ChatControllerHarness) -> Void
    ) async throws {
        try await withHarness { harness in
            try await seedPlannerDiscussion(harness)
            let sessionID = harness.sessionID
            let gate = TurnGate()
            await harness.runtime.append { call in
                try await gate.parkUntilReleased()
                await call.onEvent(.toolCallCompleted(
                    planTodoWrite,
                    DirectAgentToolResult(output: "updated", summary: "updated")
                ))
                await call.runtime.setPlannerSnapshots([
                    plannerSnapshot(rootSessionID: sessionID, revision: 2, output: plannerFinalPlan),
                ])
                return DirectAgentResponse(text: "COORDINATOR", stopReason: "end_turn", modelID: "m")
            }
            let request = harness.request("Plan the chat controller", purpose: .plan(originalGoal: planGoal))
            let controller = harness.controller
            let turn = Task { try await controller.runTurn(request) }

            await gate.waitUntilParked()
            invalidate(harness)
            gate.release()

            do {
                _ = try await turn.value
                Issue.record("an invalidated /plan turn must not succeed")
            } catch let failure as ChatTurnFailure {
                #expect(failure.isCancellation)
            }
            #expect(harness.controller.commandState.activePlan == nil)
            #expect(harness.controller.commandState.planBrainstorming == nil)
            #expect(await harness.runtime.replacedHistories.isEmpty)
            #expect(harness.controller.transcript.isEmpty)
        }
    }
}

// MARK: - Fixtures

private let planGoal = "Extract the shared chat controller"

private let plannerQuestion = """
Planner questions
1. Which platforms must the controller support?
"""

private let plannerFinalPlan = """
Specifiche concordate
- The controller is shared by the terminal, ACP, and headless channels.

Implementation plan
1. Extract the shared chat controller.
   Dependencies: none
2. Cover the controller with scripted tests.
   Dependencies: 1
"""

private let planTodoWrite = DirectAgentToolCall(
    id: "todo-plan",
    name: "todo.write",
    argumentsObject: [
        "mode": "upsert",
        "todos": [
            [
                "id": "plan-chatctl01-1",
                "content": "Extract the shared chat controller.",
                "status": "pending",
                "dependsOn": [String](),
            ],
            [
                "id": "plan-chatctl01-2",
                "content": "Cover the controller with scripted tests.",
                "status": "pending",
                "dependsOn": ["plan-chatctl01-1"],
            ],
        ],
    ],
    argumentsJSON: "{}"
)

private let plannerTwoPlanFirstSection = """
Piano 1/2: Shared controller

Specifiche concordate
- The controller is shared by the terminal, ACP, and headless channels.

Implementation plan
1. Extract the shared chat controller.
   Dependencies: none
2. Cover the controller with scripted tests.
   Dependencies: 1
"""

private let plannerTwoPlanSecondSection = """
Piano 2/2: Channels

Specifiche concordate
- Every channel adopts the controller.

Implementation plan
1. Wire the ACP bridge to the controller.
   Dependencies: none
"""

/// A two-plan Planner output: one `Piano N/2` section per plan.
private let plannerTwoPlanFinalPlan = plannerTwoPlanFirstSection + "\n\n" + plannerTwoPlanSecondSection

/// The `todo.write` of `plannerTwoPlanFinalPlan`: one ID prefix per plan.
private let twoPlanTodoWrite = DirectAgentToolCall(
    id: "todo-plans",
    name: "todo.write",
    argumentsObject: [
        "mode": "upsert",
        "todos": [
            [
                "id": "plan-chatctl01-1",
                "content": "Extract the shared chat controller.",
                "status": "pending",
                "dependsOn": [String](),
            ],
            [
                "id": "plan-chatctl01-2",
                "content": "Cover the controller with scripted tests.",
                "status": "pending",
                "dependsOn": ["plan-chatctl01-1"],
            ],
            [
                "id": "plan-chatctl02-1",
                "content": "Wire the ACP bridge to the controller.",
                "status": "pending",
                "dependsOn": [String](),
            ],
        ],
    ],
    argumentsJSON: "{}"
)

private func plannerSnapshot(
    rootSessionID: String,
    revision: UInt64,
    output: String
) -> DirectSubAgentRuntime.AgentSnapshot {
    DirectSubAgentRuntime.AgentSnapshot(
        id: "plan-author-1",
        rootSessionID: rootSessionID,
        name: PlanningCommandKernel.planAuthorAgentName,
        profileID: AgentProfileRole.planner.rawValue,
        profileRole: .planner,
        status: .idle,
        pending: false,
        modelID: "planner-model",
        latestOutput: output,
        latestOutputRevision: revision,
        latestError: nil,
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: Double(revision + 1))
    )
}

/// Leaves the controller in the middle of a `/plan` discussion: the Planner
/// asked its mandatory first question and the user answered, so a final plan
/// is acceptable. The Planner sub-agent is reported idle at revision 1.
@ChatSessionActor
private func seedPlannerDiscussion(_ harness: ChatControllerHarness) async throws {
    var discussion = PlanningCommandRuntimeState(goal: planGoal)
    discussion.recordPlannerOutput(plannerQuestion, agentID: "plan-author-1", revision: 1)
    let didRecordReply = discussion.recordReply("All Apple platforms.")
    #expect(didRecordReply)
    harness.controller.stateStore.withLock { $0.commandState.planBrainstorming = discussion }
    await harness.runtime.setPlannerSnapshots([
        plannerSnapshot(rootSessionID: harness.sessionID, revision: 1, output: plannerQuestion),
    ])
}

@ChatSessionActor
private func turnFailure(
    _ controller: ChatSessionController,
    _ request: ChatTurnRequest
) async -> ChatTurnFailure? {
    do {
        _ = try await controller.runTurn(request)
        Issue.record("the turn was expected to fail")
        return nil
    } catch let failure as ChatTurnFailure {
        return failure
    } catch {
        Issue.record("the turn threw \(error) instead of a ChatTurnFailure")
        return nil
    }
}

private final class CallCounter: Sendable {
    private let storage = Mutex(0)

    func next() -> Int {
        storage.withLock { value in
            value += 1
            return value
        }
    }
}
