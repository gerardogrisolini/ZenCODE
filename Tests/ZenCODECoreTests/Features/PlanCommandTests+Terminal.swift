//
//  PlanCommandTests+Terminal.swift
//  ZenCODE
//
//  Plan command tests driven through the terminal chat: saving and loading
//  plans, replacing and clearing discussions, todo synchronization, approval,
//  and the helpers they share.
//

import Foundation
import Testing
@testable import ZenCODECore

extension PlanCommandTests {
    @Test
    func planSavePersistsTodoDerivedDraftAndLoadRehydratesANewSession() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlanSaveTests-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: workingDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: workingDirectory
        )
        let source = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: AgentCoreSessionRunner(taskGraphStore: store),
            telegramTransportFactory: nil
        )
        try await source.sessionRunner.taskOrchestrator.registerSession(
            id: source.sessionID,
            workingDirectory: workingDirectory
        )
        let createdAt = Date(timeIntervalSince1970: 100)
        source.chatSession.activePlan = TerminalSessionPlan(
            id: "plan-handoff",
            originalGoal: "Carry the plan into another session",
            consolidatedText: "1. Inspect\n2. Implement",
            createdAt: createdAt,
            isApproved: true,
            points: [
                TerminalSessionPlanPoint(
                    id: "plan-handoff-1",
                    text: "Inspect",
                    status: .completed,
                    hasExplicitDependencies: true
                ),
                TerminalSessionPlanPoint(
                    id: "plan-handoff-2",
                    text: "Implement",
                    status: .inProgress,
                    dependsOn: ["plan-handoff-1"],
                    hasExplicitDependencies: true
                ),
            ]
        )

        #expect(isContinueChat(await source.terminalAction(presenting: source.chatSession.runPlanCommand(line: "/plan save"))))

        let storedPlans = await source.sessionRunner.savedTaskPlans(
            workingDirectory: workingDirectory
        )
        let stored = try #require(storedPlans.first)
        #expect(stored.librarySessionID == SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: workingDirectory
        ))
        #expect(stored.graph.state == .draft)
        #expect(stored.graph.tasks.map(\.title) == ["Inspect", "Implement"])
        #expect(stored.graph.tasks[1].dependsOn == ["plan-handoff-1"])
        #expect(stored.snapshot.plan.id == source.chatSession.activePlan?.id)
        #expect(stored.snapshot.plan.consolidatedText == source.chatSession.activePlan?.consolidatedText)
        #expect(stored.snapshot.plan.isApproved == false)
        #expect(stored.snapshot.plan.points.map(\.status) == [.pending, .pending])
        #expect(await source.sessionRunner.resumableTaskGraphCheckpoints(
            workingDirectory: workingDirectory
        ).isEmpty)

        let sourceSessionID = source.sessionID
        await source.writeSessionNotices(source.chatSession.newSessionCommand().notices)
        #expect(source.sessionID != sourceSessionID)
        #expect(source.chatSession.activePlan == nil)
        #expect(isContinueChat(await source.terminalAction(presenting: source.chatSession.runPlanCommand(line: "/plan load"))))

        let loaded = try #require(source.chatSession.activePlan)
        #expect(loaded.id == "plan-handoff")
        #expect(loaded.originalGoal == "Carry the plan into another session")
        #expect(loaded.consolidatedText == "1. Inspect\n2. Implement")
        #expect(loaded.createdAt == createdAt)
        #expect(loaded.isApproved == false)
        #expect(loaded.points.map(\.status) == [.pending, .pending])
        #expect(loaded.points[1].dependsOn == ["plan-handoff-1"])
        #expect(source.chatSession.history.last?.role == .user)
        #expect(source.chatSession.history.last?.content.contains("[Saved plan handoff]") == true)
        #expect(source.chatSession.history.last?.content.contains("1. Inspect") == true)
    }

    @Test
    func newPlanReplacesOnlyTheDiscussionAndClearCancelsIt() async throws {
        let terminal = try makeTerminal()
        terminal.chatSession.activePlan = TerminalSessionPlan(
            id: "plan-existing",
            originalGoal: "existing goal",
            consolidatedText: "Existing completed draft"
        )
        var discussion = PlanningCommandRuntimeState(goal: "old goal")
        discussion.recordPlannerOutput(
            "Planner questions\n1. Old question?",
            agentID: "missing-old-planner",
            revision: 1
        )
        terminal.chatSession.planBrainstorming = discussion

        let oldCollectionID = discussion.collectionID
        guard case .runHiddenPrompt = await terminal.terminalAction(presenting: terminal.chatSession.runPlanCommand(line: "/plan new goal")) else {
            Issue.record("A new /plan goal should start a fresh hidden turn")
            return
        }
        #expect(terminal.chatSession.activePlan?.id == "plan-existing")
        #expect(terminal.chatSession.planBrainstorming?.goal == "new goal")
        #expect(terminal.chatSession.planBrainstorming?.collectionID != oldCollectionID)

        // A late failure/cancellation from the abandoned turn is fenced by its
        // collection id and cannot clear the replacement discussion.
        await terminal.abandonPlanBrainstorming(
            expectedCollectionID: oldCollectionID
        )
        #expect(terminal.chatSession.planBrainstorming?.goal == "new goal")

        terminal.chatSession.activePlan = nil
        #expect(isContinueChat(await terminal.terminalAction(presenting: terminal.chatSession.runPlanCommand(line: "/plan clear"))))
        #expect(terminal.chatSession.planBrainstorming == nil)
    }

    @Test
    func successfulTodoWritesSynchronizeApprovedPlanAndDetectCompletion() throws {
        let terminal = try makeTerminal()
        terminal.chatSession.activePlan = TerminalSessionPlan(
            originalGoal: "Implement status tracking",
            consolidatedText: "Two steps",
            isApproved: true,
            points: [
                TerminalSessionPlanPoint(id: "plan-1", text: "Implement command"),
                TerminalSessionPlanPoint(id: "plan-2", text: "Run tests"),
            ]
        )
        let result = DirectAgentToolResult(
            output: "updated",
            summary: "updated"
        )

        #expect(!terminal.chatSession.synchronizeActivePlanStatus(
            from: todoWriteCall(items: [
                ("plan-1", "Implement command", "in_progress")
            ]),
            result: result
        ))
        #expect(terminal.chatSession.activePlan?.points.map(\.status) == [.inProgress, .pending])

        #expect(terminal.chatSession.synchronizeActivePlanStatus(
            from: todoWriteCall(items: [
                ("plan-1", "Implement command", "completed"),
                ("plan-2", "Run tests", "completed"),
            ]),
            result: result
        ))
        #expect(terminal.chatSession.activePlan?.isCompleted == true)
        #expect(TerminalChat.planStatusTable(for: try #require(terminal.chatSession.activePlan))
            .contains("**Overall status:** `completed`"))
    }

    @Test
    func approveRequiresACompletedPlanAndClearRemovesIt() async throws {
        let terminal = try makeTerminal()

        #expect(isContinueChat(await terminal.terminalAction(presenting: terminal.chatSession.runPlanCommand(line: "/plan approve"))))
        #expect(terminal.chatSession.activePlan == nil)

        terminal.chatSession.activePlan = TerminalSessionPlan(
            originalGoal: "goal",
            consolidatedText: "plan"
        )
        #expect(isContinueChat(await terminal.terminalAction(presenting: terminal.chatSession.runPlanCommand(line: "/plan approve"))))
        let approvalAction = await terminal.submittedLineAction("Ship the planned work")
        #expect(terminal.chatSession.activePlan?.isApproved == true)
        #expect(terminal.chatSession.activePlan?.originalGoal == "Ship the planned work")
        guard case let .runHiddenPrompt(prompt, purpose) = approvalAction else {
            Issue.record("/plan approve should start implementation immediately")
            return
        }
        #expect(purpose == .normal)
        #expect(prompt.contains("Goal: Ship the planned work"))
        #expect(prompt.contains("Approved plan:\nplan"))

        #expect(isContinueChat(await terminal.terminalAction(presenting: terminal.chatSession.runPlanCommand(line: "/plan clear"))))
        #expect(terminal.chatSession.activePlan == nil)
        #expect(isContinueChat(await terminal.terminalAction(presenting: terminal.chatSession.runPlanCommand(line: "/plan clear"))))
    }

    @Test
    func plannerAuthoredResponseRejectsAnIncompletePlanner() {
        let parentResponse = DirectAgentResponse(
            text: "Default fallback plan",
            stopReason: "end_turn",
            modelID: "default-model"
        )
        let response = PlanningCommandKernel.plannerResponse(
            parentResponse: parentResponse,
            snapshots: [
                subAgentSnapshot(
                    name: PlanningCommandKernel.planAuthorAgentName,
                    status: .running,
                    pending: true,
                    latestOutput: "Draft"
                ),
                subAgentSnapshot(
                    name: "developer-agent",
                    latestOutput: "Default fallback plan"
                ),
            ],
            baseline: PlannerTurnBaseline(state: nil, snapshots: [], rootSessionID: nil),
            rootSessionID: nil
        )?.response

        #expect(response == nil)
    }

    @Test
    func validPlanIsRecordedWithoutGraphAndApprovalCreatesActiveGraph() async throws {
        let terminal = try makeTerminal()
        let points = [
            TerminalSessionPlanPoint(
                id: "plan-graph-1",
                text: "Implement model",
                dependsOn: [],
                hasExplicitDependencies: true
            ),
            TerminalSessionPlanPoint(
                id: "plan-graph-2",
                text: "Run validation",
                dependsOn: ["plan-graph-1"],
                hasExplicitDependencies: true
            ),
        ]

        let plan = try #require(try ChatSessionController.structuredPlan(
            responseText: "1. Implement model\n2. Run validation",
            originalGoal: "Ship graph",
            points: points
        ))
        terminal.chatSession.stateStore.withLock { $0.commandState.activePlan = plan }
        // The task graph is NOT created during plan definition, only at approval.
        #expect(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID,
            graphID: "plan-graph"
        ) == nil)
        #expect(terminal.chatSession.activePlan?.id == "plan-graph")

        #expect(isContinueChat(await terminal.terminalAction(presenting: terminal.chatSession.runPlanCommand(line: "/plan approve"))))
        let approval = await terminal.submittedLineAction("Ship graph execution")
        guard case .runHiddenPrompt = approval else {
            Issue.record("Approval should create and activate the task graph")
            return
        }
        let active = try #require(try await terminal.sessionRunner.taskGraphSnapshot(
            sessionID: terminal.sessionID,
            graphID: "plan-graph"
        ))
        #expect(active.state == .active)
        #expect(active.source == .plan(planID: "plan-graph"))
        #expect(active.tasks.map(\.dependsOn) == [[], ["plan-graph-1"]])

        let receipt = try #require(try await terminal.sessionRunner.taskOrchestrator.claimTasks(
            sessionID: terminal.sessionID,
            claims: [TaskClaim(taskID: "plan-graph-1", agentID: "worker")]
        ).first)
        _ = try await terminal.sessionRunner.taskOrchestrator.completeAttempt(
            sessionID: terminal.sessionID,
            taskID: "plan-graph-1",
            attemptID: receipt.attemptID,
            output: "done",
            requiresValidation: false
        )
        _ = await terminal.terminalAction(presenting: terminal.chatSession.runPlanCommand(line: "/plan status"))
        #expect(terminal.chatSession.activePlan?.points.map(\.status) == [.completed, .pending])
        #expect(try await terminal.sessionRunner.taskOrchestrator.task(
            sessionID: terminal.sessionID,
            taskID: "plan-graph-2"
        ).isRunnable)
    }

    private func makeTerminal() throws -> TerminalChat {
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(
                fileURLWithPath: "/tmp/ZenCODE-plan-command",
                isDirectory: true
            )
        )
        let terminal = TerminalChat(configuration: configuration, stdinIsTerminal: false, telegramTransportFactory: nil)
        terminal.selectedToolKeys.insert("sub-agents")
        return terminal
    }

    private func isContinueChat(_ action: TerminalSubmittedLineAction) -> Bool {
        if case .continueChat = action {
            return true
        }
        return false
    }

    private func todoWriteCall(
        items: [(id: String, content: String, status: String)]
    ) -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: "todo-write",
            name: "todo.write",
            argumentsObject: [
                "mode": "upsert",
                "todos": items.map { item in
                    [
                        "id": item.id,
                        "content": item.content,
                        "status": item.status,
                    ]
                },
            ],
            argumentsJSON: "{}"
        )
    }

    private func subAgentSnapshot(
        name: String,
        status: DirectSubAgentRuntime.Status = .idle,
        pending: Bool = false,
        modelID: String? = nil,
        profileName: String? = AgentProfileStore.plannerAgentName,
        profileRole: AgentProfileRole? = .planner,
        latestOutput: String?,
        updatedAt: Date = Date(timeIntervalSince1970: 100)
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-\(name)",
            name: name,
            profileName: profileName,
            profileRole: profileRole,
            status: status,
            pending: pending,
            modelID: modelID,
            latestOutput: latestOutput,
            latestError: nil,
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: updatedAt
        )
    }
}
