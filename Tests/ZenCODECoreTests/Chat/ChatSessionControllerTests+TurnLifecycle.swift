//
//  ChatSessionControllerTests+TurnLifecycle.swift
//  ZenCODE
//
//  Controller tests for the life of a turn: tool consent, file changes,
//  cancellation, workflow recovery, the turn fence and the turn
//  configuration.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

extension ChatSessionControllerTests {
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
            harness.controller.stateStore.withLock {
                $0.commandState.activeWorkflow = WorkflowCommandRuntimeState(
                    goal: goal,
                    graphID: graph.id
                )
            }
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
            #expect(workflow.pendingSignal?.transcriptMessage
                == PlanningCommandKernel.workflowRecoverySignalMessage(reason: "the turn was cancelled"))
            #expect(try await harness.runtime.taskOrchestrator.graphSnapshot(
                sessionID: harness.sessionID,
                graphID: graph.id
            ) != nil)
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

    /// Changing the session or cancelling the active turn fences the turn.
    @Test(arguments: [false, true])
    func changingTheSessionDuringTheTurnPreventsEveryWriteBack(cancelling: Bool) async throws {
        try await runFencedProgressTurn { harness in
            if cancelling {
                harness.controller.cancelActiveTurn()
            } else {
                harness.controller.sessionID = "another-session"
            }
        }
    }

    // MARK: - Turn configuration

    @Test
    func turnConfigurationAddsThePurposeToolsAndKeepsThePlanProgressOnlyOutsidePlanAndReview() async throws {
        try await withHarness { harness in
            seedApprovedPlan(harness)
            let controller = harness.controller
            let progressHeading = "Active approved plan progress:"

            let plan = await controller.turnSessionConfiguration(
                for: .plan(originalGoal: "Finish the step"),
                responseLanguageSection: nil
            )
            let normal = await controller.turnSessionConfiguration(
                for: .normal,
                responseLanguageSection: nil
            )
            let review = await controller.turnSessionConfiguration(
                for: .review,
                responseLanguageSection: nil
            )

            #expect(plan.dynamicContext?.contains(progressHeading) != true)
            #expect(plan.allowedToolNames?.contains("todo.write") == true)
            #expect(normal.dynamicContext?.contains(progressHeading) == true)
            #expect(normal.dynamicContext?.contains("plan-fence-1 [pending]: Do the thing") == true)
            #expect(normal.allowedToolNames?.isSuperset(of: ["tasks.list", "tasks.update"]) == true)
            #expect(review.dynamicContext?.contains(progressHeading) != true)
            #expect(review.allowedToolNames?.contains("tasks.create") == true)
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

/// An approved plan with one pending point that `progressScript` completes.
@ChatSessionActor
private func seedApprovedPlan(_ harness: ChatControllerHarness) {
    let plan = TerminalSessionPlan(
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
    harness.controller.stateStore.withLock { $0.commandState.activePlan = plan }
}

/// Parks a scripted turn until the test releases it, without sleeping: the
/// script signals that it arrived, then waits for the release or cancellation.
struct TurnGate: Sendable {
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
