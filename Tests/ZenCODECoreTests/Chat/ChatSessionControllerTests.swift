//
//  ChatSessionControllerTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// Exercises `ChatSessionController` against a scripted `ChatSessionRuntime`,
/// a recording presenter, and a scripted interaction host. No model, network,
/// or terminal is involved: each test scripts the runtime events of a turn and
/// asserts what the controller presents, records, and refuses to write back.
@Suite
struct ChatSessionControllerTests {
    // MARK: - Presentation order

    @Test
    func presenterReceivesEventsInRuntimeOrderAndFinalBlockFollowsTheLastTool() async throws {
        try await withHarness { harness in
            await harness.runtime.append { call in
                let read = scriptedToolCall(id: "tool-read", name: "local.readFile")
                let list = scriptedToolCall(id: "tool-list", name: "local.ls")
                let output = DirectAgentToolResult(output: "ok", summary: "ok")
                await call.onEvent(.thought("Planning the reads. "))
                await call.onEvent(.content("Let me "))
                await call.onEvent(.content("check."))
                await call.onEvent(.toolCallStarted(read))
                await call.onEvent(.toolCallCompleted(read, output))
                await call.onEvent(.content("Now listing."))
                await call.onEvent(.toolCallStarted(list))
                await call.onEvent(.toolCallCompleted(list, output))
                await call.onEvent(.thought("Wrapping up."))
                await call.onEvent(.content("Final "))
                await call.onEvent(.content("answer."))
                await call.onEvent(.turnEnded(.completed))
                return DirectAgentResponse(
                    text: "Let me check.Now listing.Final answer.",
                    stopReason: "end_turn",
                    modelID: "scripted-model"
                )
            }

            let result = try await harness.controller.runTurn(harness.request("Inspect the project"))

            #expect(await harness.presenter.events == [
                .turnWillStart(prompt: "Inspect the project"),
                .thought("Planning the reads. "),
                .content("Let me "),
                .content("check."),
                .toolStarted("tool-read"),
                .toolCompleted("tool-read"),
                .toolSettled("tool-read"),
                .content("Now listing."),
                .toolStarted("tool-list"),
                .toolCompleted("tool-list"),
                .toolSettled("tool-list"),
                .thought("Wrapping up."),
                .content("Final "),
                .content("answer."),
                .turnEnded(.completed),
                .modelTurnDidReturn,
                .turnWillFinish,
            ])
            // The runtime's aggregate text is not the final block: only the
            // content after the last tool call is.
            #expect(result.response.text == "Let me check.Now listing.Final answer.")
            #expect(result.finalAssistantBlock == "Final answer.")
            #expect(result.fileChangeSummary == nil)
            #expect(result.automaticallyCompletedPlan == nil)
            #expect(harness.controller.lastFileChangeSummary == nil)

            let transcript = harness.controller.transcript
            #expect(transcript.map(\.role) == [
                .user, .assistant, .assistant, .tool, .assistant, .assistant, .tool, .assistant,
            ])
            #expect(transcript.first?.content == "Inspect the project")
            #expect(transcript.map(\.content).filter { !$0.isEmpty && $0 != "ok" }
                == ["Inspect the project", "Let me check.", "Now listing.", "Final answer."])
            #expect(transcript.last?.reasoningContent == "Wrapping up.")
        }
    }

    @Test
    func requestPresenterReplacesTheControllerDefaultForOneTurn() async throws {
        try await withHarness { harness in
            let perTurn = RecordingChatPresenter()
            await harness.runtime.append { call in
                await call.onEvent(.content("bound to the request"))
                return DirectAgentResponse(text: "bound to the request", stopReason: "end_turn", modelID: "m")
            }

            _ = try await harness.controller.runTurn(harness.request("Hello", presenter: perTurn))

            #expect(await perTurn.events == [
                .turnWillStart(prompt: "Hello"),
                .content("bound to the request"),
                .modelTurnDidReturn,
                .turnWillFinish,
            ])
            #expect(await harness.presenter.events.isEmpty)
        }
    }

    @Test
    func aChannelThatDoesNotRetainTheTranscriptNeverAppendsIt() async throws {
        try await withHarness(retainsTranscript: false) { harness in
            await harness.runtime.append { call in
                await call.onEvent(.content("answer"))
                return DirectAgentResponse(text: "answer", stopReason: "end_turn", modelID: "m")
            }

            let result = try await harness.controller.runTurn(harness.request("Question"))

            #expect(result.finalAssistantBlock == "answer")
            #expect(harness.controller.transcript.isEmpty)
        }
    }

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
            harness.controller.commandState.activeWorkflow = WorkflowCommandRuntimeState(
                goal: goal,
                graphID: graph.id
            )
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
            #expect(workflow.pendingCoordinatorMessage == question)
        }
    }

    // MARK: - Tool consent

    @Test
    func gatedToolCallInATurnReachesTheHostOnceThroughTheRunnerDefaultAuthorizer() async throws {
        try await withHarness(hostDecisions: [.allowOnce]) { harness in
            let request = gatedRequest(sessionID: harness.sessionID)
            await harness.runtime.append { call in
                // No per-turn override: the runtime falls back to its default
                // authorization handler, as `AgentCoreSessionRunner` does.
                let approved = await call.authorizeTool?(request) ?? false
                await call.runtime.recordAuthorization(approved)
                return DirectAgentResponse(text: "done", stopReason: "end_turn", modelID: "m")
            }

            _ = try await harness.controller.runTurn(harness.request("Push the branch"))

            #expect(await harness.runtime.authorizationResults == [true])
            let hostRequests = await harness.host.requests
            #expect(hostRequests.count == 1)
            #expect(hostRequests.first?.toolName == "git.push")
            #expect(hostRequests.first?.sessionID == harness.sessionID)
        }
    }

    @Test
    func allowAlwaysSkipsTheSecondRequestUntilTheSessionDecisionsAreRemoved() async throws {
        try await withHarness(hostDecisions: [.allowAlways, .allowOnce]) { harness in
            let sessionID = harness.sessionID
            await harness.runtime.append { call in
                for callID in ["call-1", "call-2"] {
                    let request = gatedRequest(sessionID: sessionID, toolCallID: callID)
                    let approved = await call.authorizeTool?(request) ?? false
                    await call.runtime.recordAuthorization(approved)
                }
                return DirectAgentResponse(text: "done", stopReason: "end_turn", modelID: "m")
            }
            await harness.runtime.append { call in
                let request = gatedRequest(sessionID: sessionID, toolCallID: "call-3")
                let approved = await call.authorizeTool?(request) ?? false
                await call.runtime.recordAuthorization(approved)
                return DirectAgentResponse(text: "done", stopReason: "end_turn", modelID: "m")
            }

            _ = try await harness.controller.runTurn(harness.request("First turn"))

            #expect(await harness.runtime.authorizationResults == [true, true])
            #expect(await harness.host.requestCount == 1)
            #expect(await harness.authorizer.cachedDecisionCount(sessionID: sessionID) == 1)

            await harness.authorizer.removeCachedDecisions(sessionID: sessionID)
            #expect(await harness.authorizer.cachedDecisionCount(sessionID: sessionID) == 0)

            _ = try await harness.controller.runTurn(harness.request("Second turn"))

            #expect(await harness.runtime.authorizationResults == [true, true, true])
            #expect(await harness.host.requestCount == 2)
        }
    }

    @Test
    func denyAlwaysIsRememberedWithoutAskingTheHostAgain() async throws {
        try await withHarness(hostDecisions: [.denyAlways, .allowOnce]) { harness in
            let request = gatedRequest(sessionID: harness.sessionID)

            let first = await harness.authorizer.authorizationOutcome(for: request)
            let second = await harness.authorizer.authorizationOutcome(for: request)

            #expect(first == .denied)
            #expect(second == .denied)
            #expect(await harness.host.requestCount == 1)
        }
    }

    @Test
    func hostWithoutToolConsentRefusesGatedToolsWithoutCallingTheHost() async throws {
        try await withHarness(hostCapabilities: [], hostDecisions: [.allowAlways]) { harness in
            let request = gatedRequest(sessionID: harness.sessionID)
            await harness.runtime.append { call in
                let approved = await call.authorizeTool?(request) ?? true
                await call.runtime.recordAuthorization(approved)
                return DirectAgentResponse(text: "done", stopReason: "end_turn", modelID: "m")
            }

            _ = try await harness.controller.runTurn(harness.request("Push the branch"))

            #expect(await harness.runtime.authorizationResults == [false])
            #expect(await harness.authorizer.authorizationOutcome(for: request) == .unavailable)
            #expect(await harness.host.requestCount == 0)
        }
    }

    @Test
    func toolsOutsideTheGatedSetAreApprovedWithoutTheHost() async throws {
        try await withHarness(hostDecisions: [.denyAlways]) { harness in
            let request = AgentToolAuthorizationRequest(
                turnID: nil,
                sessionID: harness.sessionID,
                toolCallID: "read-1",
                toolName: "local.readFile",
                title: "Read",
                kind: "read",
                command: "Package.swift",
                workingDirectory: harness.workspace.path
            )

            #expect(await harness.authorizer.authorize(request))
            #expect(await harness.host.requestCount == 0)
        }
    }

    // MARK: - File changes

    @Test
    func toolWriteIsPresentedLiveAndTheSummaryIsTheLastEventBeforeReturn() async throws {
        try await withHarness { harness in
            let workspace = harness.workspace
            await harness.runtime.append { call in
                let write = DirectAgentToolCall(
                    id: "write-1",
                    name: "local.writeFile",
                    argumentsObject: ["path": "notes.txt", "content": "hello\n"],
                    argumentsJSON: "{}"
                )
                await call.onEvent(.content("Writing the file."))
                await call.onEvent(.toolCallStarted(write))
                // The runtime reports the call before it touches the disk, so the
                // controller can capture the pre-image.
                await call.onToolWillExecute?(write)
                try Data("hello\n".utf8).write(to: workspace.appendingPathComponent("notes.txt"))
                await call.onEvent(.toolCallCompleted(write, DirectAgentToolResult(
                    output: "Wrote notes.txt",
                    summary: "Wrote notes.txt",
                    fileChanges: [OperationFileChange(path: "notes.txt", oldText: nil, newText: "hello\n")]
                )))
                await call.onEvent(.content("All done."))
                await call.onEvent(.turnEnded(.completed))
                return DirectAgentResponse(
                    text: "Writing the file.All done.",
                    stopReason: "end_turn",
                    modelID: "scripted-model"
                )
            }

            let result = try await harness.controller.runTurn(harness.request("Create notes.txt"))

            #expect(await harness.presenter.events == [
                .turnWillStart(prompt: "Create notes.txt"),
                .content("Writing the file."),
                .toolStarted("write-1"),
                .toolCompleted("write-1"),
                .liveArtifacts(agentID: nil, paths: ["notes.txt"]),
                .toolSettled("write-1"),
                .content("All done."),
                .turnEnded(.completed),
                .modelTurnDidReturn,
                .turnWillFinish,
                .fileChangeSummary(fileCount: 1),
            ])

            let summary = try #require(result.fileChangeSummary)
            #expect(summary.fileCount == 1)
            #expect(summary.entries.first?.path == "notes.txt")
            #expect(summary.entries.first?.status == .added)
            #expect(summary.totalAdditions == 1)
            #expect(summary.totalDeletions == 0)
            #expect(harness.controller.lastFileChangeSummary == summary)
            #expect(result.finalAssistantBlock == "All done.")

            // ACP shows the summary without the terminal-only command hint.
            let acpText = TurnFileChangeSummaryPresentation.text(summary, includesCommandHint: false)
            #expect(acpText.hasPrefix("\n🪬 Summary: 1 file  +1 -0"))
            #expect(acpText.contains("  added notes.txt  +1 -0"))
            #expect(!acpText.contains("/undo"))
            let terminalText = TurnFileChangeSummaryPresentation.text(summary, includesCommandHint: true)
            #expect(terminalText.hasPrefix("\n🪬 Summary: 1 file  +1 -0"))
            #expect(terminalText.contains("Use /undo to revert"))
        }
    }

    @Test
    func changesNobodyReportedAreSealedAndPresentedBeforeTheSummary() async throws {
        try await withHarness { harness in
            let workspace = harness.workspace
            try initializeGitRepository(at: workspace, trackedFile: "tracked.txt", contents: "initial\n")
            await harness.runtime.append { call in
                await call.onEvent(.content("Editing quietly."))
                // No tool event reports this write: only the end-of-turn
                // worktree reconciliation can discover it.
                try Data("edited\n".utf8).write(to: workspace.appendingPathComponent("tracked.txt"))
                return DirectAgentResponse(text: "Editing quietly.", stopReason: "end_turn", modelID: "m")
            }

            let result = try await harness.controller.runTurn(harness.request("Edit tracked.txt"))

            #expect(await harness.presenter.events == [
                .turnWillStart(prompt: "Edit tracked.txt"),
                .content("Editing quietly."),
                .modelTurnDidReturn,
                .sealedArtifacts(paths: ["tracked.txt"]),
                .turnWillFinish,
                .fileChangeSummary(fileCount: 1),
            ])
            let summary = try #require(result.fileChangeSummary)
            #expect(summary.entries.first?.path == "tracked.txt")
            #expect(summary.entries.first?.status == .modified)
            #expect(harness.controller.lastFileChangeSummary == summary)
        }
    }

    // MARK: - Cancellation

    @Test
    func cancellingTheTurnTaskThrowsACancellationFailureAndAppendsThePartialTranscript() async throws {
        try await withHarness { harness in
            let gate = TurnGate()
            await harness.runtime.append { call in
                await call.onEvent(.content("partial answer"))
                try await gate.parkUntilReleased()
                return DirectAgentResponse(text: "never reached", stopReason: "end_turn", modelID: "m")
            }
            let request = harness.request("Long running question")
            let controller = harness.controller
            let turn = Task { try await controller.runTurn(request) }

            await gate.waitUntilParked()
            turn.cancel()

            do {
                _ = try await turn.value
                Issue.record("a cancelled turn must throw")
            } catch let failure as ChatTurnFailure {
                #expect(failure.isCancellation)
                #expect(failure.fileChangeSummary == nil)
            }

            let transcript = controller.transcript
            #expect(transcript.first?.role == .user)
            #expect(transcript.first?.content == "Long running question")
            #expect(transcript.contains { $0.role == .assistant && $0.content == "partial answer" })
            let events = await harness.presenter.events
            #expect(events.last == .turnWillFinish)
            #expect(!events.contains(.modelTurnDidReturn))
        }
    }

    // MARK: - Workflow recovery

    @Test
    func cancelledWorkflowTurnKeepsItsGraphAndArmsRecovery() async throws {
        try await withHarness { harness in
            let goal = "Ship the chat controller"
            let graph = try await harness.runtime.taskOrchestrator.createGraph(
                sessionID: harness.sessionID,
                id: "workflow_recovery",
                source: .workflow,
                state: .active,
                tasks: [],
                originalGoal: goal
            )
            harness.controller.commandState.activeWorkflow = WorkflowCommandRuntimeState(
                goal: goal,
                graphID: graph.id
            )
            let gate = TurnGate()
            await harness.runtime.append { call in
                await call.onEvent(.content("Starting."))
                try await gate.parkUntilReleased()
                return DirectAgentResponse(text: "never reached", stopReason: "end_turn", modelID: "m")
            }
            let request = harness.request(
                "Start the goal",
                purpose: .workflow(originalGoal: goal, graphID: graph.id)
            )
            let controller = harness.controller
            let turn = Task { try await controller.runTurn(request) }

            await gate.waitUntilParked()
            turn.cancel()

            do {
                _ = try await turn.value
                Issue.record("a cancelled workflow turn must throw")
            } catch let failure as ChatTurnFailure {
                #expect(failure.isCancellation)
            }

            #expect(await harness.presenter.events == [
                .turnWillStart(prompt: "Start the goal"),
                .content("Starting."),
                .workflowNotice(.recoverableFailure(graphID: graph.id, pendingTaskCount: 0)),
                .turnWillFinish,
            ])
            let workflow = try #require(controller.commandState.activeWorkflow)
            #expect(workflow.pendingCoordinatorMessage
                == PlanningCommandKernel.workflowRecoverySignalMessage(reason: "the turn was cancelled"))
            #expect(try await harness.runtime.taskOrchestrator.graphSnapshot(
                sessionID: harness.sessionID,
                graphID: graph.id
            ) != nil)
        }
    }

    @Test
    func cancelActiveTurnArmsWorkflowRecoveryOnlyOnRequestAndKeepsAnExistingSignal() async throws {
        try await withHarness { harness in
            let controller = harness.controller
            controller.commandState.activeWorkflow = WorkflowCommandRuntimeState(
                goal: "Ship the chat controller",
                graphID: "workflow_arming"
            )

            controller.cancelActiveTurn()
            #expect(controller.commandState.activeWorkflow?.isAwaitingReply == false)

            controller.cancelActiveTurn(armingWorkflowRecovery: true)
            #expect(controller.commandState.activeWorkflow?.pendingCoordinatorMessage
                == PlanningCommandKernel.workflowRecoverySignalMessage(reason: "cancelled"))

            // A workflow already waiting for the operator keeps its own signal.
            var resumed = WorkflowCommandRuntimeState(goal: "g", graphID: "workflow_arming")
            resumed.armForResumedGraph()
            controller.commandState.activeWorkflow = resumed
            controller.cancelActiveTurn(armingWorkflowRecovery: true)
            #expect(controller.commandState.activeWorkflow == resumed)
        }
    }

    // MARK: - Turn fence

    @Test
    func aCurrentTurnWritesItsPlanProgressAndSnapshotBack() async throws {
        try await withHarness { harness in
            seedApprovedPlan(harness)
            await harness.runtime.append(Self.progressScript(harness: harness, gate: nil))

            let result = try await harness.controller.runTurn(harness.request("Finish the step"))

            let plan = try #require(harness.controller.commandState.activePlan)
            #expect(plan.points.map(\.status) == [.completed])
            #expect(result.automaticallyCompletedPlan?.id == plan.id)
            #expect(harness.controller.history.map(\.content) == ["runtime history"])
            #expect(harness.controller.cacheKey == "runtime-cache")
            #expect(harness.controller.transcript.first?.content == "Finish the step")
        }
    }

    @Test
    func changingTheSessionDuringTheTurnPreventsEveryWriteBack() async throws {
        try await runFencedProgressTurn { harness in
            harness.controller.sessionID = "another-session"
        }
    }

    @Test
    func cancellingTheActiveTurnDuringTheTurnPreventsEveryWriteBack() async throws {
        try await runFencedProgressTurn { harness in
            harness.controller.cancelActiveTurn()
        }
    }

    @Test
    func changingTheSessionDuringAPlanTurnDoesNotRecordThePlannerPlan() async throws {
        try await runFencedPlanTurn { harness in
            harness.controller.sessionID = "another-session"
        }
    }

    @Test
    func cancellingTheActiveTurnDuringAPlanTurnDoesNotRecordThePlannerPlan() async throws {
        try await runFencedPlanTurn { harness in
            harness.controller.cancelActiveTurn()
        }
    }

    // MARK: - Fence helpers

    /// Runs a `.normal` turn parked mid-flight, applies `invalidate`, then lets
    /// it finish: the turn completes normally but writes nothing back.
    private func runFencedProgressTurn(
        invalidate: @escaping @Sendable @ChatSessionActor (ChatControllerHarness) -> Void
    ) async throws {
        try await withHarness { harness in
            seedApprovedPlan(harness)
            let gate = TurnGate()
            await harness.runtime.append(Self.progressScript(harness: harness, gate: gate))
            let stateBefore = harness.controller.commandState
            let request = harness.request("Finish the step")
            let controller = harness.controller
            let turn = Task { try await controller.runTurn(request) }

            await gate.waitUntilParked()
            invalidate(harness)
            gate.release()
            let result = try await turn.value

            #expect(harness.controller.commandState == stateBefore)
            #expect(harness.controller.commandState.activePlan?.points.map(\.status) == [.pending])
            #expect(result.automaticallyCompletedPlan == nil)
            #expect(harness.controller.transcript.isEmpty)
            #expect(harness.controller.history.isEmpty)
            #expect(harness.controller.cacheKey == nil)
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

    /// Script of a turn that parks (when `gate` is set), then completes the
    /// approved plan's only point and reports a session snapshot.
    private static func progressScript(
        harness: ChatControllerHarness,
        gate: TurnGate?
    ) -> ScriptedChatRuntime.Script {
        let sessionID = harness.sessionID
        let workspacePath = harness.workspace.path
        return { call in
            await call.onEvent(.content("working"))
            try await gate?.parkUntilReleased()
            let completion = DirectAgentToolCall(
                id: "todo-progress",
                name: "todo.write",
                argumentsObject: [
                    "mode": "upsert",
                    "todos": [[
                        "id": "plan-fence-1",
                        "content": "Do the thing",
                        "status": "completed",
                        "dependsOn": [String](),
                    ]],
                ],
                argumentsJSON: "{}"
            )
            await call.onEvent(.toolCallCompleted(
                completion,
                DirectAgentToolResult(output: "updated", summary: "updated")
            ))
            await call.onEvent(.sessionSnapshot(AgentRuntimeSessionSnapshot(
                sessionID: sessionID,
                workingDirectoryPath: workspacePath,
                systemPrompt: nil,
                cacheKey: "runtime-cache",
                history: [AgentRuntimeMessage(role: .assistant, content: "runtime history")],
                allowedToolNames: nil,
                thinkingSelection: nil,
                preserveThinking: false
            )))
            return DirectAgentResponse(text: "working", stopReason: "end_turn", modelID: "m")
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

private func scriptedToolCall(id: String, name: String) -> DirectAgentToolCall {
    DirectAgentToolCall(id: id, name: name, argumentsObject: ["path": "."], argumentsJSON: "{}")
}

private func gatedRequest(
    sessionID: String,
    toolCallID: String = "call-1"
) -> AgentToolAuthorizationRequest {
    AgentToolAuthorizationRequest(
        turnID: nil,
        sessionID: sessionID,
        toolCallID: toolCallID,
        toolName: "git.push",
        title: "Push the branch",
        kind: "execute",
        command: "git push origin main",
        workingDirectory: "/tmp/chat-session-controller-tests"
    )
}

private func plannerSnapshot(
    rootSessionID: String,
    revision: UInt64,
    output: String
) -> DirectSubAgentRuntime.AgentSnapshot {
    DirectSubAgentRuntime.AgentSnapshot(
        id: "plan-author-1",
        rootSessionID: rootSessionID,
        name: PlanningCommandKernel.planAuthorAgentName,
        role: AgentProfileStore.plannerAgentName,
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
    harness.controller.commandState.planBrainstorming = discussion
    await harness.runtime.setPlannerSnapshots([
        plannerSnapshot(rootSessionID: harness.sessionID, revision: 1, output: plannerQuestion),
    ])
}

/// An approved plan with one pending point that `progressScript` completes.
@ChatSessionActor
private func seedApprovedPlan(_ harness: ChatControllerHarness) {
    harness.controller.commandState.activePlan = TerminalSessionPlan(
        id: "plan-fence",
        originalGoal: "Finish the step",
        consolidatedText: "Do the thing.",
        isApproved: true,
        points: [
            TerminalSessionPlanPoint(
                id: "plan-fence-1",
                text: "Do the thing",
                hasExplicitDependencies: true
            ),
        ]
    )
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

private func initializeGitRepository(at directory: URL, trackedFile: String, contents: String) throws {
    try Data(contents.utf8).write(to: directory.appendingPathComponent(trackedFile))
    let commands = [
        ["init"],
        ["add", "."],
        [
            "-c", "user.name=Test", "-c", "user.email=test@example.com",
            "-c", "commit.gpgsign=false", "commit", "-m", "initial",
        ],
    ]
    for arguments in commands {
        let process = Process()
        process.executableURL = GitExecutableResolver.executableURL()
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0)
    }
}

/// Runs `body` with a throwaway workspace and a task-local support directory,
/// so no test reads or writes the real application state.
private func withHarness(
    hostCapabilities: ChatChannelCapabilities = [.toolConsent],
    hostDecisions: [ChatConsentDecision?] = [],
    retainsTranscript: Bool = true,
    _ body: @escaping @Sendable @ChatSessionActor (ChatControllerHarness) async throws -> Void
) async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("chat-session-controller-tests-\(UUID().uuidString)", isDirectory: true)
    let support = root.appendingPathComponent("support", isDirectory: true)
    let workspace = root.appendingPathComponent("workspace", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable @ChatSessionActor in
        let harness = ChatControllerHarness(
            workspace: workspace,
            hostCapabilities: hostCapabilities,
            hostDecisions: hostDecisions,
            retainsTranscript: retainsTranscript
        )
        try await body(harness)
    }
}

// MARK: - Test doubles

private struct ChatControllerHarness: Sendable {
    let workspace: URL
    let sessionID: String
    let runtime: ScriptedChatRuntime
    let host: ScriptedChatInteractionHost
    let authorizer: ChatToolConsentAuthorizer
    let presenter: RecordingChatPresenter
    let controller: ChatSessionController

    init(
        workspace: URL,
        hostCapabilities: ChatChannelCapabilities,
        hostDecisions: [ChatConsentDecision?],
        retainsTranscript: Bool
    ) {
        let sessionID = "chat-session-\(UUID().uuidString.lowercased())"
        let host = ScriptedChatInteractionHost(capabilities: hostCapabilities, decisions: hostDecisions)
        let authorizer = ChatToolConsentAuthorizer(host: host)
        let runtime = ScriptedChatRuntime(
            defaultToolAuthorization: { await authorizer.authorize($0) }
        )
        let presenter = RecordingChatPresenter()
        self.workspace = workspace
        self.sessionID = sessionID
        self.runtime = runtime
        self.host = host
        self.authorizer = authorizer
        self.presenter = presenter
        self.controller = ChatSessionController(
            sessionID: sessionID,
            runtime: runtime,
            workingDirectory: workspace,
            presenter: presenter,
            host: host,
            authorizer: authorizer,
            retainsTranscript: retainsTranscript
        )
    }

    func request(
        _ prompt: String,
        purpose: ChatTurnPurpose = .normal,
        attachments: [AgentRuntimeAttachment] = [],
        turnInstructionProvider: (@Sendable () async -> String?)? = nil,
        presenter: (any ChatSessionPresenter)? = nil
    ) -> ChatTurnRequest {
        ChatTurnRequest(
            prompt: prompt,
            attachments: attachments,
            purpose: purpose,
            sessionConfiguration: AgentCoreSessionConfiguration(
                sessionID: sessionID,
                modelID: "scripted-model",
                workingDirectory: workspace,
                systemPrompt: nil,
                cacheKey: nil,
                history: []
            ),
            turnInstructionProvider: turnInstructionProvider,
            presenter: presenter
        )
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

/// Parks a scripted turn until the test releases it, without sleeping: the
/// script signals that it arrived, then waits for the release or cancellation.
private struct TurnGate: Sendable {
    private let parked: AsyncStream<Void>
    private let parkedSignal: AsyncStream<Void>.Continuation
    private let released: AsyncStream<Void>
    private let releasedSignal: AsyncStream<Void>.Continuation

    init() {
        (parked, parkedSignal) = AsyncStream<Void>.makeStream()
        (released, releasedSignal) = AsyncStream<Void>.makeStream()
    }

    /// Called by the script. A cancelled task ends the wait and throws.
    func parkUntilReleased() async throws {
        parkedSignal.yield()
        var iterator = released.makeAsyncIterator()
        _ = await iterator.next()
        try Task.checkCancellation()
    }

    /// Called by the test: returns once the script reached its park point.
    func waitUntilParked() async {
        var iterator = parked.makeAsyncIterator()
        _ = await iterator.next()
    }

    func release() {
        releasedSignal.yield()
    }
}

private actor RecordingChatPresenter: ChatSessionPresenter {
    enum Event: Equatable, Sendable {
        case turnWillStart(prompt: String)
        case status(String)
        case thought(String)
        case content(String)
        case toolStarted(String)
        case toolCompleted(String)
        case toolSettled(String)
        case liveArtifacts(agentID: String?, paths: [String])
        case sealedArtifacts(paths: [String])
        case fileChangeSummary(fileCount: Int)
        case modelTurnDidReturn
        case continueAutomatically
        case turnWillFinish
        case workflowNotice(ChatWorkflowNotice)
        case turnEnded(DirectAgentTurnOutcome.Status)
    }

    private(set) var events: [Event] = []

    func turnWillStart(_ request: ChatTurnRequest) async {
        events.append(.turnWillStart(prompt: request.prompt))
    }

    func presentStatus(_ status: String) async {
        events.append(.status(status))
    }

    func presentThought(_ thought: String) async {
        events.append(.thought(thought))
    }

    func presentAssistantContent(_ content: String) async {
        events.append(.content(content))
    }

    func presentToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        events.append(.toolStarted(toolCall.id))
    }

    func presentToolCallCompleted(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        events.append(.toolCompleted(toolCall.id))
    }

    func presentToolCallSettled(_ toolCall: DirectAgentToolCall, result: DirectAgentToolResult) async {
        events.append(.toolSettled(toolCall.id))
    }

    func presentLiveFileArtifacts(_ turns: [SessionFileArtifactHistory.Turn], agentID: String?) async {
        events.append(.liveArtifacts(
            agentID: agentID,
            paths: turns.flatMap { $0.artifacts.map(\.displayPath) }
        ))
    }

    func presentSealedFileArtifacts(_ turn: SessionFileArtifactHistory.Turn) async {
        events.append(.sealedArtifacts(paths: turn.artifacts.map(\.displayPath)))
    }

    func presentFileChangeSummary(_ summary: TurnFileChangeSummary) async {
        events.append(.fileChangeSummary(fileCount: summary.fileCount))
    }

    func modelTurnDidReturn() async {
        events.append(.modelTurnDidReturn)
    }

    func turnWillContinueAutomatically() async {
        events.append(.continueAutomatically)
    }

    func turnWillFinish() async {
        events.append(.turnWillFinish)
    }

    func presentWorkflowNotice(_ notice: ChatWorkflowNotice) async {
        events.append(.workflowNotice(notice))
    }

    func presentTurnEnded(_ outcome: DirectAgentTurnOutcome) async {
        events.append(.turnEnded(outcome.status))
    }
}

private actor ScriptedChatInteractionHost: ChatInteractionHost {
    nonisolated let capabilities: ChatChannelCapabilities
    private var decisions: [ChatConsentDecision?]
    private(set) var requests: [AgentToolAuthorizationRequest] = []

    init(capabilities: ChatChannelCapabilities, decisions: [ChatConsentDecision?]) {
        self.capabilities = capabilities
        self.decisions = decisions
    }

    var requestCount: Int { requests.count }

    func requestToolConsent(_ request: AgentToolAuthorizationRequest) async -> ChatConsentDecision? {
        requests.append(request)
        return decisions.isEmpty ? nil : decisions.removeFirst()
    }
}

/// A `ChatSessionRuntime` whose model requests are scripted. Each call to
/// `sendPrompt` runs the next appended script, which drives the event stream
/// and the `onToolWillExecute` hook exactly like the real runner would.
private actor ScriptedChatRuntime: ChatSessionRuntime {
    struct Call: Sendable {
        let index: Int
        let authorizeTool: AgentToolAuthorizationHandler?
        let onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)?
        let onEvent: @Sendable (DirectAgentEvent) async -> Void
        let runtime: ScriptedChatRuntime
    }

    typealias Script = @Sendable (Call) async throws -> DirectAgentResponse

    enum ScriptError: Error {
        case missingScript(index: Int)
    }

    nonisolated let taskOrchestrator = SessionTaskOrchestrator()

    private let defaultToolAuthorization: AgentToolAuthorizationHandler?
    private var scripts: [Script] = []
    private var plannerSnapshots: [DirectSubAgentRuntime.AgentSnapshot] = []
    private(set) var prompts: [String] = []
    private(set) var attachmentCounts: [Int] = []
    private(set) var turnInstructions: [String?] = []
    private(set) var authorizationResults: [Bool] = []
    private(set) var replacedHistories: [[AgentRuntimeMessage]] = []

    /// `defaultToolAuthorization` plays the role of the runner's
    /// `defaultToolAuthorizationHandler`: it answers calls whose turn request
    /// did not bring its own handler.
    init(defaultToolAuthorization: AgentToolAuthorizationHandler? = nil) {
        self.defaultToolAuthorization = defaultToolAuthorization
    }

    func append(_ script: @escaping Script) {
        scripts.append(script)
    }

    func setPlannerSnapshots(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        plannerSnapshots = snapshots
    }

    func recordAuthorization(_ approved: Bool) {
        authorizationResults.append(approved)
    }

    func sendPrompt(
        configuration: AgentCoreSessionConfiguration,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        authorizeTool: AgentToolAuthorizationHandler?,
        onToolWillExecute: (@Sendable (DirectAgentToolCall) async -> Void)?,
        toolProviders: [AgentToolProvider],
        turnInstruction: String?,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        let index = prompts.count
        prompts.append(prompt)
        attachmentCounts.append(attachments.count)
        turnInstructions.append(turnInstruction)
        guard index < scripts.count else {
            throw ScriptError.missingScript(index: index)
        }
        let script = scripts[index]
        return try await script(Call(
            index: index,
            authorizeTool: authorizeTool ?? defaultToolAuthorization,
            onToolWillExecute: onToolWillExecute,
            onEvent: onEvent,
            runtime: self
        ))
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        plannerSnapshots
    }

    func closeSubAgent(id: String) async -> Bool {
        true
    }

    func taskGraphSnapshot(sessionID: String, graphID: String?) async throws -> TaskGraphSnapshot? {
        try await taskOrchestrator.graphSnapshot(sessionID: sessionID, graphID: graphID)
    }

    func removeTaskGraph(id: String, sessionID: String) async throws -> TaskGraphSnapshot {
        try await taskOrchestrator.removeGraph(id: id, sessionID: sessionID)
    }

    func snapshotSession(id sessionID: String) async -> AgentRuntimeSessionSnapshot? {
        nil
    }

    func currentSessionGeneration(for sessionID: String) -> AgentCoreSessionRunner.SessionGeneration? {
        AgentCoreSessionRunner.SessionGeneration(rawValue: 1)
    }

    func replaceSessionHistory(
        id sessionID: String,
        history: [AgentRuntimeMessage],
        expectedSessionGeneration: AgentCoreSessionRunner.SessionGeneration
    ) async -> Bool {
        replacedHistories.append(history)
        return true
    }
}
