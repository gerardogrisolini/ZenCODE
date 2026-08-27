//
//  GoalCommandTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@TerminalChatActor
@Suite
struct GoalCommandTests {
    @Test
    func goalCommandCreatesAnActiveDelegatedGraphBeforePrompting() async throws {
        let terminal = try makeTerminal()

        let action = await terminal.submittedLineAction("/goal Ship delegated work")
        guard case let .runHiddenPrompt(prompt, purpose) = action else {
            Issue.record("/goal should start its coordinator prompt")
            return
        }

        let graph = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ))
        #expect(purpose == .workflow(originalGoal: "Ship delegated work", graphID: graph.id))
        #expect(graph.source == .workflow)
        #expect(graph.state == .active)
        #expect(graph.tasks.isEmpty)
        #expect(graph.id.hasPrefix("workflow_"))
        #expect(prompt.contains("Active workflow task graph: \(graph.id)"))
        #expect(prompt.contains("execution.executor set to sub_agent"))
        #expect(prompt.contains("Do not start a task attempt directly with tasks.update"))
        #expect(prompt.contains("Continue working until the stated goal is fully achieved and validated"))
        #expect(prompt.contains("ask the user a focused clarification question instead of guessing"))
    }

    @Test
    func goalCommandRejectsAnActivePlanWithoutCreatingOrReplacingAGraph() async throws {
        let terminal = try makeTerminal()
        let plan = TerminalSessionPlan(
            id: "active-plan",
            originalGoal: "Finish the existing plan",
            consolidatedText: "Keep this plan intact.",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        terminal.activePlan = plan

        let action = await terminal.submittedLineAction("/goal Start another workflow")

        guard case .continueChat = action else {
            Issue.record("/goal must stop when an active plan exists")
            return
        }
        #expect(terminal.activePlan == plan)
        #expect(TerminalChat.workflowActivePlanMessage.contains("active plan"))
        #expect(TerminalChat.workflowActivePlanMessage.contains("/plan clear"))
        #expect(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ) == nil)
    }

    @Test
    func goalCommandDoesNotOverlapAnUnfinishedPlannerDiscussion() async throws {
        let terminal = try makeTerminal()
        var discussion = PlanningCommandRuntimeState(goal: "clarify first")
        discussion.recordPlannerOutput(
            "Planner questions\n1. Choose the compatibility behavior?",
            agentID: "planner-goal-block",
            revision: 1
        )
        terminal.planBrainstorming = discussion

        guard case .continueChat = await terminal.submittedLineAction(
            "/goal must not overlap"
        ) else {
            Issue.record("/goal must not overlap an unfinished /plan discussion")
            return
        }
        #expect(terminal.planBrainstorming == discussion)
        #expect(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ) == nil)
    }

    @Test
    func goalPromptRequiresDelegationWithoutAReadOnlyCoordinatorPolicy() {
        let prompt = TerminalChat.workflowPrompt(
            goal: "Ship delegated work",
            graphID: "workflow_test"
        )

        #expect(prompt.contains("canonical `agents` array"))
        #expect(prompt.contains("task ID in the item's `taskID` field"))
        #expect(prompt.contains("the task graph enforces sub-agent execution"))
        #expect(!prompt.contains("your only direct actions"))
        #expect(!prompt.localizedCaseInsensitiveContains("read-only"))
        #expect(prompt.contains("validation is negative, record the task as failed"))
        #expect(prompt.contains("call tasks.retry"))
        #expect(prompt.contains("new canonical agent.create item containing `taskID`"))
        #expect(prompt.contains("Do not use agent.message to request corrections"))
        #expect(prompt.contains("Stop without achieving the goal only for a genuine blocker"))
        #expect(prompt.contains("resume this same goal graph"))
        #expect(prompt.contains("exhaust the clarification, evidence, suitable-agent, and retry paths"))
        #expect(prompt.contains("acceptance criterion as a follow-up"))
        #expect(!prompt.contains("all tasks are completed or a real blocker is reached"))
        #expect(!prompt.contains("use agent.message to request corrections or"))
    }

    @Test
    func goalCommandRejectsASecondWorkflowWhileOneIsStillOpen() async throws {
        let terminal = try makeTerminal()
        guard case .runHiddenPrompt = await terminal.submittedLineAction("/goal First goal") else {
            Issue.record("/goal should start its coordinator prompt")
            return
        }
        let firstGraph = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ))

        guard case .continueChat = await terminal.submittedLineAction("/goal Second goal") else {
            Issue.record("a second /goal must not start while a workflow is open")
            return
        }

        // The open workflow graph is untouched: no replacement, no archiving.
        let currentGraph = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ))
        #expect(currentGraph.id == firstGraph.id)
        #expect(currentGraph.state == .active)
        #expect(terminal.activeWorkflow?.graphID == firstGraph.id)

        let message = TerminalChat.workflowAlreadyActiveMessage(
            graphID: firstGraph.id,
            pendingTaskCount: 0
        )
        #expect(message.contains(firstGraph.id))
        #expect(message.contains("/tasks clear"))
        #expect(!message.localizedCaseInsensitiveContains("graphNotMutable"))
    }

    @Test
    func aPlainMessageContinuesTheOpenWorkflowOnTheSameGraph() async throws {
        let terminal = try makeTerminal()
        guard case .runHiddenPrompt = await terminal.submittedLineAction(
            "/goal Ship delegated work"
        ) else {
            Issue.record("/goal should start its coordinator prompt")
            return
        }
        let graph = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ))

        // Before the coordinator turn ends nothing is armed: a plain message is
        // an ordinary prompt.
        #expect(terminal.activeWorkflow?.isAwaitingReply == false)
        guard case .runPrompt = await terminal.submittedLineAction("unrelated question") else {
            Issue.record("a plain message must not be captured before the workflow turn ends")
            return
        }

        await terminal.recordWorkflowTurnOutcome(
            graphID: graph.id,
            coordinatorMessage: "Workflow question\nWhich compatibility behavior should I keep?"
        )
        #expect(terminal.activeWorkflow?.isAwaitingReply == true)

        let action = await terminal.submittedLineAction("Keep the existing behavior")
        guard case let .runHiddenPrompt(prompt, purpose) = action else {
            Issue.record("the reply should continue the workflow")
            return
        }

        #expect(purpose == .workflow(originalGoal: "Ship delegated work", graphID: graph.id))
        #expect(prompt.contains("Active workflow task graph: \(graph.id)"))
        #expect(prompt.contains("Keep the existing behavior"))
        #expect(prompt.contains("Which compatibility behavior should I keep?"))
        #expect(prompt.contains("Continue working until the stated goal is fully achieved"))
        #expect(prompt.contains("Use the active workflow graph \(graph.id)"))
        // The reply is consumed once; it does not capture every later message.
        #expect(terminal.activeWorkflow?.isAwaitingReply == false)
        #expect(terminal.activeWorkflow?.exchanges.count == 1)
    }

    @Test
    func workflowContinuationStopsWhenTheGraphIsNoLongerOpen() async throws {
        let terminal = try makeTerminal()
        guard case .runHiddenPrompt = await terminal.submittedLineAction("/goal Ship it") else {
            Issue.record("/goal should start its coordinator prompt")
            return
        }
        let graph = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ))
        await terminal.recordWorkflowTurnOutcome(
            graphID: graph.id,
            coordinatorMessage: "Workflow question\nAnything else to clarify?"
        )
        try await terminal.sessionRunner.clearTaskGraphs(sessionID: terminal.sessionID)

        guard case .runPrompt = await terminal.submittedLineAction("something else entirely") else {
            Issue.record("a cleared workflow must not capture plain messages")
            return
        }
        #expect(terminal.activeWorkflow == nil)
    }

    @Test
    func aFailedFirstWorkflowTurnDiscardsOnlyItsEmptyGraph() async throws {
        let terminal = try makeTerminal()
        guard case .runHiddenPrompt = await terminal.submittedLineAction("/goal Ship it") else {
            Issue.record("/goal should start its coordinator prompt")
            return
        }
        let graph = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ))

        await terminal.handleFailedWorkflowTurn(graphID: graph.id, reason: "boom")

        #expect(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ) == nil)
        #expect(terminal.activeWorkflow == nil)
    }

    @Test
    func aFailedWorkflowTurnKeepsAGraphThatAlreadyHasTasks() async throws {
        let terminal = try makeTerminal()
        let graphID = "workflow_with_tasks"
        _ = try await terminal.sessionRunner.taskOrchestrator.createGraph(
            sessionID: terminal.sessionID,
            id: graphID,
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "t1",
                    title: "Delegated work",
                    execution: TaskExecutionSpec(executor: .subAgent)
                )
            ]
        )
        terminal.activeWorkflow = WorkflowCommandRuntimeState(goal: "Ship it", graphID: graphID)

        await terminal.handleFailedWorkflowTurn(graphID: graphID, reason: "boom")

        let graph = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ))
        #expect(graph.id == graphID)
        #expect(graph.tasks.count == 1)
        // The announced retry path really exists: the workflow stays armed and
        // the next plain message resumes this same graph.
        #expect(terminal.activeWorkflow?.graphID == graphID)
        #expect(terminal.activeWorkflow?.isAwaitingReply == true)
        let recoveryMessage = TerminalChat.workflowRecoverableFailureMessage(
            graphID: graphID,
            pendingTaskCount: 1
        )
        #expect(recoveryMessage.contains("task graph was kept"))
        #expect(recoveryMessage.contains("resumes it on the same task graph"))

        let action = await terminal.submittedLineAction("retry the failed part")
        guard case let .runHiddenPrompt(prompt, purpose) = action else {
            Issue.record("an interrupted workflow must keep a real continuation path")
            return
        }
        #expect(purpose == .workflow(originalGoal: "Ship it", graphID: graphID))
        #expect(prompt.contains("Active workflow task graph: \(graphID)"))
        #expect(prompt.contains("the previous workflow turn did not finish"))
        #expect(prompt.contains("boom"))
        #expect(prompt.contains("tasks.retry any task left"))
    }

    @Test
    func anOrdinaryWorkflowTurnDoesNotCaptureTheNextMessage() async throws {
        let terminal = try makeTerminal()
        guard case .runHiddenPrompt = await terminal.submittedLineAction(
            "/goal Ship delegated work"
        ) else {
            Issue.record("/goal should start its coordinator prompt")
            return
        }
        let graph = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID
        ))

        // A progress report is not the explicit clarification protocol.
        await terminal.recordWorkflowTurnOutcome(
            graphID: graph.id,
            coordinatorMessage: "I delegated two tasks and validated the first one."
        )

        #expect(terminal.activeWorkflow?.graphID == graph.id)
        #expect(terminal.activeWorkflow?.isAwaitingReply == false)
        guard case .runPrompt = await terminal.submittedLineAction("and what about docs?") else {
            Issue.record("a workflow turn without an explicit question must not capture messages")
            return
        }
        let notice = TerminalChat.workflowOpenWithoutQuestionMessage(
            graphID: graph.id,
            pendingTaskCount: 0
        )
        #expect(notice.contains("not waiting for an answer"))
    }

    @Test
    func onlyTheExplicitWorkflowQuestionHeadingArmsTheContinuation() {
        #expect(PlanningCommandKernel.isWorkflowClarificationResponse(
            "Workflow question\n1. Which database?"
        ))
        #expect(!PlanningCommandKernel.isWorkflowClarificationResponse(
            "## Workflow question: which database?"
        ))
        #expect(!PlanningCommandKernel.isWorkflowClarificationResponse(
            "\n  workflow questions\n1. Which database?"
        ))
        #expect(!PlanningCommandKernel.isWorkflowClarificationResponse(
            "I have a workflow question: which database?"
        ))
        #expect(!PlanningCommandKernel.isWorkflowClarificationResponse("Done. All tasks completed."))
        #expect(!PlanningCommandKernel.isWorkflowClarificationResponse(""))

        var state = WorkflowCommandRuntimeState(goal: "Ship it", graphID: "workflow_test")
        let armedByProse = state.recordCoordinatorOutput("Summary of the delegated work.")
        #expect(!armedByProse)
        #expect(!state.isAwaitingReply)
        let armedByQuestion = state.recordCoordinatorOutput("Workflow question\nWhich database?")
        #expect(armedByQuestion)
        #expect(state.isAwaitingReply)
        // A later ordinary turn disarms the round-trip again.
        let stillArmed = state.recordCoordinatorOutput("Progress: two tasks delegated.")
        #expect(!stillArmed)
        #expect(!state.isAwaitingReply)
        let didRecordDisarmedReply = state.recordReply("Postgres")
        #expect(!didRecordDisarmedReply)
    }

    @Test
    func tuiWorkflowSignalUsesOnlyTheFinalAssistantBlockAfterTools() async {
        let tool = DirectAgentToolCall(
            id: "workflow-block-boundary",
            name: "tasks.list",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        let questionThenSummary = TerminalSessionTranscriptTurn(prompt: "goal", attachments: [])
        await questionThenSummary.appendAssistantContent("Workflow question\nWhich database?")
        await questionThenSummary.appendToolCallStarted(tool)
        await questionThenSummary.appendAssistantContent("Summary: task list refreshed.")

        var state = WorkflowCommandRuntimeState(goal: "Ship it", graphID: "workflow_test")
        #expect(!state.recordCoordinatorOutput(await questionThenSummary.lastAssistantContent()))
        #expect(!state.isAwaitingReply)

        let progressThenQuestion = TerminalSessionTranscriptTurn(prompt: "goal", attachments: [])
        await progressThenQuestion.appendAssistantContent("Progress: task list refreshed.")
        await progressThenQuestion.appendToolCallStarted(tool)
        await progressThenQuestion.appendAssistantContent("Workflow question\nWhich database?")
        #expect(state.recordCoordinatorOutput(await progressThenQuestion.lastAssistantContent()))
        #expect(state.isAwaitingReply)
    }

    @Test
    func theGoalPromptDocumentsTheClarificationProtocol() {
        let prompt = TerminalChat.workflowPrompt(
            goal: "Ship delegated work",
            graphID: "workflow_test"
        )
        #expect(prompt.contains("whose very first line is "))
        #expect(prompt.contains("Workflow question"))
        #expect(prompt.contains("Never use that heading for progress reports"))
    }

    @Test
    func resumingAWorkflowGraphRearmsItsContinuationContract() async throws {
        let terminal = try makeTerminal()
        let graphID = "workflow_resumed"
        _ = try await terminal.sessionRunner.taskOrchestrator.createGraph(
            sessionID: terminal.sessionID,
            id: graphID,
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "t1",
                    title: "Delegated work",
                    execution: TaskExecutionSpec(executor: .subAgent)
                )
            ]
        )

        await terminal.writeResumedTaskGraphNotice(
            ResumableTaskGraph(
                sessionID: terminal.sessionID,
                graphID: graphID,
                state: .active,
                source: .workflow,
                totalTaskCount: 1,
                pendingTaskCount: 1,
                updatedAt: Date(timeIntervalSince1970: 1)
            )
        )

        #expect(terminal.activeWorkflow?.graphID == graphID)
        #expect(terminal.activeWorkflow?.isAwaitingReply == true)
        #expect(terminal.activeWorkflow?.pendingSignal == .resumedGraph)

        let action = await terminal.submittedLineAction("continue where you stopped")
        guard case let .runHiddenPrompt(prompt, purpose) = action else {
            Issue.record("a resumed workflow should continue on the same graph")
            return
        }
        #expect(purpose == .workflow(originalGoal: "", graphID: graphID))
        #expect(prompt.contains("Active workflow task graph: \(graphID)"))
        #expect(prompt.contains("continue the workflow already recorded in this task graph"))
    }

    @Test
    func workflowContinuationPromptKeepsTheContractAndDelegationRules() {
        var state = WorkflowCommandRuntimeState(goal: "Ship it", graphID: "workflow_test")
        let didArm = state.recordCoordinatorOutput(
            "Workflow question\nWhich database should I target?"
        )
        #expect(didArm)
        let didRecordReply = state.recordReply("Postgres")
        #expect(didRecordReply)

        let prompt = PlanningCommandKernel.workflowContinuationPrompt(
            state: state,
            pendingTaskCount: 2,
            totalTaskCount: 5
        )

        #expect(prompt.contains("Active workflow task graph: workflow_test"))
        #expect(prompt.contains("Goal: Ship it"))
        #expect(prompt.contains("2 of 5 tasks still open"))
        #expect(prompt.contains("Which database should I target?"))
        #expect(prompt.contains("Postgres"))
        #expect(prompt.contains("Continue working until the stated goal is fully achieved"))
        #expect(prompt.contains("Stop without achieving the goal only for a genuine blocker"))
        #expect(prompt.contains("canonical agent.create"))
        #expect(prompt.contains("Use the active workflow graph workflow_test"))
        #expect(prompt.contains("never create or replace another graph"))
    }

    private func makeTerminal() throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-workflow-command",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(configuration: configuration, stdinIsTerminal: false)
        terminal.selectedToolKeys.insert("sub-agents")
        return terminal
    }
}
