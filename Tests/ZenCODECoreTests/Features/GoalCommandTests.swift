//
//  GoalCommandTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@ChatSessionActor
@Suite
struct GoalCommandTests {
    @Test(arguments: [false, true])
    func goalCommandCreatesAnActivePersistentGraphBeforePrompting(subAgentsEnabled: Bool) async throws {
        let terminal = try makeTerminal(subAgentsEnabled: subAgentsEnabled)
        #expect(terminal.isSubAgentToolEnabled == subAgentsEnabled)

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
        #expect(prompt.contains("execution.executor set to coordinator for direct work or sub_agent for delegated work"))
        #expect(prompt.contains("Delegation is optional, not a prerequisite for /goal"))
        #expect(prompt.contains("delegating that task is the default"))
        #expect(prompt.contains("Decide direct versus delegated execution with cost in mind."))
        #expect(prompt.contains(TaskRecord.delegationCostPolicy))
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

    @Test(arguments: [false, true])
    func aPlainMessageContinuesTheOpenWorkflowOnTheSameGraph(subAgentsEnabled: Bool) async throws {
        let terminal = try makeTerminal(subAgentsEnabled: subAgentsEnabled)
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
        #expect(terminal.chatSession.activeWorkflow?.isAwaitingReply == false)
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
        #expect(terminal.chatSession.activeWorkflow?.isAwaitingReply == true)

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
        #expect(terminal.chatSession.activeWorkflow?.isAwaitingReply == false)
        #expect(terminal.chatSession.activeWorkflow?.exchanges.count == 1)
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

    @Test(arguments: [false, true])
    func structuredBlockerStopsAndResumedCheckpointKeepsTheOriginalGoal(subAgentsEnabled: Bool) async throws {
        let terminal = try makeTerminal(subAgentsEnabled: subAgentsEnabled)
        _ = await terminal.submittedLineAction("/goal Complete the entire approved change")
        let initial = try #require(try await terminal.sessionRunner.taskGraphSnapshot(sessionID: terminal.sessionID))
        await terminal.recordWorkflowTurnOutcome(graphID: initial.id, coordinatorMessage: "Workflow question\nHeading alone")
        #expect(terminal.chatSession.activeWorkflow?.isAwaitingReply == false)
        let blocked = try await terminal.sessionRunner.taskOrchestrator.updateWorkflow(
            sessionID: terminal.sessionID, graphID: initial.id, state: .blocked,
            message: "External service is unavailable; restore access.", expectedRevision: initial.revision
        )
        #expect(PlanningCommandKernel.workflowTurnDisposition(
            graph: blocked, expectedGraphID: initial.id, coordinatorMessage: "Cannot proceed."
        ) == .blocked)
        await terminal.recordWorkflowTurnOutcome(graphID: initial.id, coordinatorMessage: "Cannot proceed.")
        #expect(terminal.chatSession.activeWorkflow?.pendingSignal == .blocked("External service is unavailable; restore access."))

        // Reconstruct the frontend projection exactly as startup recovery does.
        terminal.chatSession.activeWorkflow = nil
        terminal.chatSession.restoreWorkflowProjection(
            from: try await terminal.sessionRunner.taskGraphSnapshot(
                sessionID: terminal.sessionID,
                graphID: initial.id
            )
        )
        #expect(terminal.chatSession.activeWorkflow?.goal == "Complete the entire approved change")
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
            selectedTools: ["sub-agents"], selectedSkillNames: [], thinkingSelection: nil,
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
        #expect(terminal.chatSession.activeWorkflow?.pendingCoordinatorMessage == "Provide saved-session access")
        #expect(terminal.chatSession.activeWorkflow?.goal == "Preserve the full saved objective")
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
                selectedSkillNames: [], thinkingSelection: nil, systemPrompt: "Test", history: [],
                taskGraph: manualGraph ? TaskGraphSnapshot(id: "manual", source: .manual, state: .active) : nil,
                checkpointTree: SessionCheckpointTree.fromLinearHistory([], sessionID: otherID)
            )
            _ = try TerminalSessionStore.save(other, supportDirectoryURL: support)
            terminal.chatSession.activeWorkflow = WorkflowCommandRuntimeState(goal: "Stale", graphID: graph.id)
            let loaded = try TerminalSessionStore.load(name: other.name, workingDirectory: workspace, supportDirectoryURL: support)
            try await terminal.loadSavedSession(loaded)
            #expect(terminal.chatSession.activeWorkflow == nil)
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
        #expect(terminal.chatSession.activeWorkflow?.isAwaitingReply == true)
        if state != .running {
            #expect(terminal.chatSession.activeWorkflow?.pendingCoordinatorMessage == "Persisted pause before interruption")
        }
        guard case let .runHiddenPrompt(_, resumedPurpose) = await terminal.submittedLineAction("Retry interrupted turn") else {
            Issue.record("La generazione fallita deve lasciare un percorso di recovery")
            return
        }
        #expect(resumedPurpose == purpose)
        await terminal.stopTaskGraphObserver()
    }

    private func makeTerminal(subAgentsEnabled: Bool = true) throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-workflow-command",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(configuration: configuration, stdinIsTerminal: false)
        if subAgentsEnabled {
            terminal.selectedToolKeys.insert("sub-agents")
        } else {
            terminal.selectedToolKeys.remove("sub-agents")
        }
        return terminal
    }
}
