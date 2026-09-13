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
        #expect(graph.workflow?.originalGoal == "Ship delegated work")
        #expect(graph.workflow?.state == .running)
        #expect(graph.state == .active)
        #expect(graph.tasks.isEmpty)
        #expect(graph.id.hasPrefix("workflow_"))
        #expect(prompt.contains("Active workflow task graph: \(graph.id)"))
        #expect(prompt.contains("execution.executor set to sub_agent"))
        #expect(prompt.contains("Do not start a task attempt directly with tasks.update"))
        #expect(prompt.contains("Continue working until the stated goal is fully achieved and validated"))
        #expect(prompt.contains("ask the user a focused clarification question instead of guessing"))
        #expect(prompt.contains("Phase 0 — Identify the objective autonomously"))
        #expect(prompt.contains("observable definition of done"))
        #expect(prompt.contains("Do not ask the user to confirm an objective"))
        #expect(prompt.contains("explicit, testable acceptance criteria"))
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
        #expect(prompt.contains("For profiles without bindings, omit `model` to inherit the main session model"))
        #expect(prompt.contains("only when bindings are configured, the `model` binding"))
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

        _ = try await terminal.sessionRunner.taskOrchestrator.updateWorkflow(
            sessionID: terminal.sessionID, graphID: graph.id,
            state: .awaitingUser, message: "Which compatibility behavior should I keep?",
            expectedRevision: graph.revision
        )
        await terminal.recordWorkflowTurnOutcome(
            graphID: graph.id,
            coordinatorMessage: "Which compatibility behavior should I keep?"
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
        _ = try await terminal.sessionRunner.taskOrchestrator.updateWorkflow(
            sessionID: terminal.sessionID, graphID: graph.id,
            state: .awaitingUser, message: "Anything else to clarify?",
            expectedRevision: graph.revision
        )
        await terminal.recordWorkflowTurnOutcome(
            graphID: graph.id,
            coordinatorMessage: "Anything else to clarify?"
        )
        try await terminal.sessionRunner.clearTaskGraphs(sessionID: terminal.sessionID)

        guard case .runPrompt = await terminal.submittedLineAction("something else entirely") else {
            Issue.record("a cleared workflow must not capture plain messages")
            return
        }
        #expect(terminal.activeWorkflow == nil)
    }

    @Test
    func aFailedFirstWorkflowTurnPreservesItsPersistedObjective() async throws {
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
        ) == graph)
        #expect(terminal.activeWorkflow?.isAwaitingReply == true)
        guard case let .runHiddenPrompt(prompt, purpose) = await terminal.submittedLineAction("retry") else {
            Issue.record("Il workflow vuoto deve restare riprendibile")
            return
        }
        #expect(prompt.contains("Goal: Ship it"))
        #expect(purpose == .workflow(originalGoal: "Ship it", graphID: graph.id))
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
    func legacyWorkflowQuestionHeadingArmsTheContinuation() {
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
    func legacyTUIWorkflowSignalUsesOnlyTheFinalAssistantBlockAfterTools() async {
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
        #expect(prompt.contains("expectedRevision"))
        #expect(prompt.contains("awaiting_user"))
        #expect(prompt.contains("Text alone"))
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
        #expect(prompt.contains("Original goal unavailable"))
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

    @Test
    func legacyWorkflowRuntimeContinuesEveryOpenTurnUnlessItExplicitlyAsks() {
        let graph = TaskGraphSnapshot(
            id: "workflow_test",
            source: .workflow,
            state: .active
        )

        #expect(PlanningCommandKernel.workflowTurnDisposition(
            graph: graph,
            expectedGraphID: graph.id,
            coordinatorMessage: "I created part of the plan."
        ) == .continueAutomatically)
        #expect(PlanningCommandKernel.workflowTurnDisposition(
            graph: graph,
            expectedGraphID: graph.id,
            coordinatorMessage: "Workflow question\nWhich compatibility mode is required?"
        ) == .awaitingClarification)

        var completed = graph
        completed.state = .completed
        #expect(PlanningCommandKernel.workflowTurnDisposition(
            graph: completed,
            expectedGraphID: graph.id,
            coordinatorMessage: "Done."
        ) == .completed)
    }

    @Test
    func automaticWorkflowContinuationReinjectsGoalGraphAndContract() {
        let graph = TaskGraphSnapshot(
            id: "workflow_test",
            source: .workflow,
            state: .active
        )

        let prompt = PlanningCommandKernel.workflowAutomaticContinuationPrompt(
            goal: "Ship the complete feature",
            graph: graph
        )

        #expect(prompt.contains("Continue the active /goal workflow automatically"))
        #expect(prompt.contains("Goal: Ship the complete feature"))
        #expect(prompt.contains("Active workflow task graph: workflow_test"))
        #expect(prompt.contains("no tasks defined"))
        #expect(prompt.contains("not permission to return a progress summary"))
        #expect(prompt.contains("Continue working until the stated goal is fully achieved"))
        #expect(prompt.contains("canonical agent.create"))
    }

    @Test
    func structuredBlockerStopsAndResumedCheckpointKeepsTheOriginalGoal() async throws {
        let terminal = try makeTerminal()
        _ = await terminal.submittedLineAction("/goal Complete the entire approved change")
        let initial = try #require(try await terminal.sessionRunner.taskGraphSnapshot(sessionID: terminal.sessionID))
        await terminal.recordWorkflowTurnOutcome(graphID: initial.id, coordinatorMessage: "Workflow question\nHeading alone")
        #expect(terminal.activeWorkflow?.isAwaitingReply == false)
        let blocked = try await terminal.sessionRunner.taskOrchestrator.updateWorkflow(
            sessionID: terminal.sessionID, graphID: initial.id, state: .blocked,
            message: "External service is unavailable; restore access.", expectedRevision: initial.revision
        )
        #expect(PlanningCommandKernel.workflowTurnDisposition(
            graph: blocked, expectedGraphID: initial.id, coordinatorMessage: "Cannot proceed."
        ) == .blocked)
        await terminal.recordWorkflowTurnOutcome(graphID: initial.id, coordinatorMessage: "Cannot proceed.")
        #expect(terminal.activeWorkflow?.pendingSignal == .blocked("External service is unavailable; restore access."))

        // Reconstruct the frontend projection exactly as startup recovery does.
        terminal.activeWorkflow = nil
        await terminal.writeResumedTaskGraphNotice(ResumableTaskGraph(
            sessionID: terminal.sessionID, graphID: initial.id, state: .active, source: .workflow,
            totalTaskCount: 0, pendingTaskCount: 0, updatedAt: blocked.updatedAt
        ))
        #expect(terminal.activeWorkflow?.goal == "Complete the entire approved change")
        guard case let .runHiddenPrompt(prompt, purpose) = await terminal.submittedLineAction("Access restored") else {
            Issue.record("The user reply must resume the same workflow")
            return
        }
        #expect(prompt.contains("Goal: Complete the entire approved change"))
        #expect(prompt.contains("Access restored"))
        #expect(purpose == .workflow(originalGoal: "Complete the entire approved change", graphID: initial.id))
        let resumed = try #require(try await terminal.sessionRunner.taskGraphSnapshot(sessionID: terminal.sessionID))
        #expect(resumed.id == initial.id)
        #expect(resumed.workflow?.state == .running)
        #expect(resumed.workflow?.originalGoal == initial.workflow?.originalGoal)
    }

    @Test(arguments: [TaskGraphWorkflowState.awaitingUser, .blocked])
    func failurePreservesStructuredPauseBeforeFirstTask(state: TaskGraphWorkflowState) async throws {
        for reason in ["provider unavailable", "cancelled"] {
            let terminal = try makeTerminal()
            _ = await terminal.submittedLineAction("/goal Keep the complete objective")
            let initial = try #require(try await terminal.sessionRunner.taskGraphSnapshot(sessionID: terminal.sessionID))
            let paused = try await terminal.sessionRunner.taskOrchestrator.updateWorkflow(
                sessionID: terminal.sessionID, graphID: initial.id, state: state,
                message: "Choose the required access", expectedRevision: initial.revision
            )
            await terminal.handleFailedWorkflowTurn(graphID: initial.id, reason: reason)
            #expect(try await terminal.sessionRunner.taskGraphSnapshot(sessionID: terminal.sessionID) == paused)
            #expect(terminal.activeWorkflow?.pendingCoordinatorMessage == "Choose the required access")
            guard case let .runHiddenPrompt(prompt, purpose) = await terminal.submittedLineAction("Access supplied") else {
                Issue.record("La sospensione deve conservare il percorso di risposta")
                return
            }
            #expect(prompt.contains("Choose the required access"))
            #expect(purpose == .workflow(originalGoal: "Keep the complete objective", graphID: initial.id))
        }
    }

    @Test(arguments: [TaskGraphWorkflowState.awaitingUser, .blocked])
    func savedSessionRoundTripResumesPersistedGoalAndClearsStaleProjection(state: TaskGraphWorkflowState) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        let support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = CapturingACPBackend()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend },
            taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: support)
        )
        let sessionID = UUID().uuidString
        let graph = try await runner.taskOrchestrator.createGraph(
            sessionID: sessionID, id: "saved-workflow", source: .workflow, state: .active,
            tasks: [TaskDefinition(id: "delegated-work", title: "Keep task identity", execution: TaskExecutionSpec(executor: .subAgent))],
            originalGoal: "Preserve the full saved objective"
        )
        let paused = try await runner.taskOrchestrator.updateWorkflow(
            sessionID: sessionID, graphID: graph.id, state: state,
            message: "Provide saved-session access", expectedRevision: graph.revision
        )
        let history = [AgentRuntimeMessage(role: .user, content: "/goal Preserve the full saved objective")]
        let snapshot = AgentRuntimeSessionSnapshot(
            sessionID: sessionID, workingDirectoryPath: workspace.path,
            systemPrompt: "Test", cacheKey: nil, history: history,
            allowedToolNames: nil, thinkingSelection: nil, preserveThinking: false
        )
        _ = try await runner.saveSession(
            id: sessionID, named: "workflow", fallbackSnapshot: snapshot,
            fallbackCreatedAt: Date(), modelID: "test-model", agentID: nil, agentName: nil,
            selectedTools: ["sub-agents"], selectedSkillIDs: [], thinkingSelection: nil,
            contextWindow: nil, transcriptHistory: history,
            checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: sessionID),
            supportDirectoryURL: support
        )
        let saved = try TerminalSessionStore.load(name: "workflow", workingDirectory: workspace, supportDirectoryURL: support)
        // A new frontend/runner must reconstruct state from disk, not a live projection.
        let restoredRunner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend },
            taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: root.appendingPathComponent("restored"))
        )
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "test-model", availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")],
                workingDirectory: workspace
            ), stdinIsTerminal: false, sessionRunner: restoredRunner
        )
        try await terminal.loadSavedSession(saved)
        #expect(terminal.activeWorkflow?.pendingCoordinatorMessage == "Provide saved-session access")
        #expect(terminal.activeWorkflow?.goal == "Preserve the full saved objective")
        guard case let .runHiddenPrompt(prompt, purpose) = await terminal.submittedLineAction("Saved access supplied") else {
            Issue.record("La risposta dopo loadSavedSession deve riprendere il workflow salvato")
            return
        }
        #expect(prompt.contains("Goal: Preserve the full saved objective"))
        #expect(purpose == .workflow(originalGoal: "Preserve the full saved objective", graphID: graph.id))
        let resumed = try #require(try await restoredRunner.taskGraphSnapshot(sessionID: sessionID))
        #expect(resumed.id == graph.id)
        #expect(resumed.tasks == paused.tasks)
        #expect(resumed.workflow?.state == .running)
        #expect(resumed.workflow?.originalGoal == paused.workflow?.originalGoal)

        for manualGraph in [false, true] {
            let otherID = UUID().uuidString
            let other = TerminalSavedSession(
                name: "ordinary-\(manualGraph)", sessionID: otherID, cacheKey: nil,
                workingDirectoryPath: workspace.path, createdAt: Date(), savedAt: Date(),
                modelID: "test-model", agentID: nil, agentName: nil, selectedTools: ["sub-agents"],
                selectedSkillIDs: [], thinkingSelection: nil, systemPrompt: "Test", history: [],
                taskGraph: manualGraph ? TaskGraphSnapshot(id: "manual", source: .manual, state: .active) : nil,
                checkpointTree: SessionCheckpointTree.fromLinearHistory([], sessionID: otherID)
            )
            _ = try TerminalSessionStore.save(other, supportDirectoryURL: support)
            terminal.activeWorkflow = WorkflowCommandRuntimeState(goal: "Stale", graphID: graph.id)
            let loaded = try TerminalSessionStore.load(name: other.name, workingDirectory: workspace, supportDirectoryURL: support)
            try await terminal.loadSavedSession(loaded)
            #expect(terminal.activeWorkflow == nil)
            guard case .runPrompt = await terminal.submittedLineAction("Ordinary chat") else {
                Issue.record("Un caricamento non-workflow non deve conservare la proiezione precedente")
                return
            }
        }
        await terminal.stopTaskGraphObserver()
    }

    @Test(arguments: [TaskGraphWorkflowState.running, .awaitingUser, .blocked], [false, true])
    func generationFailureOrInterruptRetainsZeroTaskObjective(state: TaskGraphWorkflowState, cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let backend = ScriptedACPCommandBackend()
        let runner = AgentCoreSessionRunner(
            backendFactory: { _, _ in backend },
            taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: root.appendingPathComponent("support"))
        )
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "test-model", availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")],
                workingDirectory: workspace
            ), stdinIsTerminal: false, sessionRunner: runner
        )
        terminal.selectedToolKeys.insert("sub-agents")
        guard case let .runHiddenPrompt(prompt, purpose) = await terminal.submittedLineAction("/goal Keep interrupted objective") else {
            Issue.record("Il goal deve iniziare una generazione")
            return
        }
        let initial = try #require(try await runner.taskGraphSnapshot(sessionID: terminal.sessionID))
        await backend.setWorkflowPauseState(state)
        await backend.interruptWorkflow(fail: !cancel, afterPause: state != .running)
        let generation = Task {
            try await terminal.generateResponse(attempt: TerminalPromptAttempt(
                prompt: prompt, attachments: [], origin: .local, locksResponseLanguage: false, purpose: purpose
            ))
        }
        defer { generation.cancel() }
        if cancel {
            for _ in 0..<500 {
                if await backend.isWorkflowSuspended() { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(await backend.isWorkflowSuspended())
            generation.cancel()
        }
        do {
            _ = try await generation.value
            Issue.record("Il provider deve fallire o essere interrotto")
        } catch {
            #expect(error is TerminalChatGenerationRunError)
        }
        let graph = try #require(try await runner.taskGraphSnapshot(sessionID: terminal.sessionID))
        #expect(graph.id == initial.id)
        #expect(graph.tasks.isEmpty)
        #expect(graph.workflow?.originalGoal == "Keep interrupted objective")
        #expect(graph.workflow?.state == state)
        #expect(terminal.activeWorkflow?.isAwaitingReply == true)
        if state != .running {
            #expect(terminal.activeWorkflow?.pendingCoordinatorMessage == "Persisted pause before interruption")
        }
        guard case let .runHiddenPrompt(_, resumedPurpose) = await terminal.submittedLineAction("Retry interrupted turn") else {
            Issue.record("La generazione fallita deve lasciare un percorso di recovery")
            return
        }
        #expect(resumedPurpose == purpose)
        await terminal.stopTaskGraphObserver()
    }

    @Test
    func legacyEmptyWorkflowStillUsesTheLegacyFailureCleanup() async throws {
        let terminal = try makeTerminal()
        let graph = try await terminal.sessionRunner.taskOrchestrator.createGraph(
            sessionID: terminal.sessionID, id: "legacy-empty", source: .workflow, state: .active, tasks: []
        )
        terminal.activeWorkflow = WorkflowCommandRuntimeState(goal: "", graphID: graph.id)
        await terminal.handleFailedWorkflowTurn(graphID: graph.id, reason: "provider unavailable")
        #expect(try await terminal.sessionRunner.taskGraphSnapshot(sessionID: terminal.sessionID) == nil)
        #expect(terminal.activeWorkflow == nil)
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
