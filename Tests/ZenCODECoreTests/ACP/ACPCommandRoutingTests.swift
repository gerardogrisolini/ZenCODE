//
//  ACPCommandRoutingTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

/// One `plan` update as the client received it.
private struct ACPPlan: Equatable {
    struct Entry: Equatable {
        let content: String
        let status: String
    }

    let entries: [Entry]
}

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

    /// The `plan` updates sent, in order. An entry that lost its `content` or
    /// its `status` keeps a placeholder: a malformed plan must never read as an
    /// empty one.
    func plans() -> [ACPPlan] {
        storage.withLock { values in
            values.compactMap { value -> ACPPlan? in
                guard let object = value.objectValue,
                      object["method"] == .string("session/update"),
                      let update = object["params"]?.objectValue?["update"]?.objectValue,
                      update["sessionUpdate"] == .string("plan") else {
                    return nil
                }
                let entries = (update["entries"]?.arrayValue ?? []).map { entry in
                    let fields = entry.objectValue
                    return ACPPlan.Entry(
                        content: fields?["content"]?.stringValue ?? "<missing content>",
                        status: fields?["status"]?.stringValue ?? "<missing status>"
                    )
                }
                return ACPPlan(entries: entries)
            }
        }
    }

    /// The content of every `plan` sent, one array per update.
    func planContents() -> [[String]] {
        plans().map { $0.entries.map(\.content) }
    }

    /// The status of every `plan` sent, one array per update.
    func planStatuses() -> [[String]] {
        plans().map { $0.entries.map(\.status) }
    }

    /// What reached the client, in order: the update kind of each
    /// `session/update`, and `result:<id>` for a reply.
    func timeline() -> [String] {
        storage.withLock { values in
            values.compactMap { value -> String? in
                guard let object = value.objectValue else { return nil }
                if let update = object["params"]?.objectValue?["update"]?.objectValue,
                   let kind = update["sessionUpdate"]?.stringValue {
                    return kind
                }
                guard object["result"] != nil,
                      let id = object["id"]?.numberValue else {
                    return nil
                }
                return "result:\(Int(id))"
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
    private var completesWorkflowDirectly = false
    private var observedToolGrants: [Set<String>?] = []

    func recordedToolGrants() -> [Set<String>?] { observedToolGrants }

    func completeWorkflowDirectly() {
        completesWorkflowDirectly = true
    }

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
        allowedToolNames: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        observedToolGrants.append(allowedToolNames)
    }

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
        allowedToolNames: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        observedToolGrants.append(allowedToolNames)
    }

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
        if completesWorkflowDirectly {
            let owner = try #require(orchestrator)
            if prompt.contains("Work autonomously until the goal is complete") {
                _ = try await owner.createTasks(
                    sessionID: sessionID,
                    tasks: [TaskDefinition(id: "direct", title: "Complete direct work")]
                )
                _ = try await owner.updateTask(
                    sessionID: sessionID, taskID: "direct", update: TaskUpdate(status: .inProgress)
                )
                return DirectAgentResponse(text: "Direct work started", stopReason: "end_turn", modelID: "workflow-model")
            }
            if prompt.contains("Continue the active /goal workflow automatically") {
                let graph = try #require(try await owner.graphSnapshot(sessionID: sessionID))
                if graph.tasks.allSatisfy({ $0.status == .completed }) {
                    _ = try await owner.updateWorkflow(
                        sessionID: sessionID, graphID: graph.id, state: .completed,
                        message: "Whole objective verified", expectedRevision: graph.revision
                    )
                    return DirectAgentResponse(text: "Goal verified", stopReason: "end_turn", modelID: "workflow-model")
                }
                _ = try await owner.updateTask(
                    sessionID: sessionID, taskID: "direct",
                    update: TaskUpdate(status: .completed, output: "Direct work validated")
                )
                return DirectAgentResponse(text: "Direct work complete", stopReason: "end_turn", modelID: "workflow-model")
            }
        }
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
        if prompt.contains("Continue the goal workflow") {
            await onEvent(.content("WORKFLOW CONTINUED"))
            return DirectAgentResponse(
                text: "WORKFLOW CONTINUED",
                stopReason: "end_turn",
                modelID: "workflow-model"
            )
        }
        if prompt.contains("Work autonomously until the goal is complete") {
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
            profileID: AgentProfileRole.planner.rawValue,
            profileRole: .planner,
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

/// Scope the complete test (not just fixture construction): checkpoint writes
/// resolve the support directory again after every suspension.
private struct ACPCommandStorageScope: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-command-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppStorageDirectory.withSupportDirectoryURL(root) {
            try await function()
        }
    }
}

@Suite(.serialized, ACPCommandStorageScope())
struct ACPCommandRoutingTests {

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
        try await bridge.prompt(id: .number(7), params: [
            "sessionId": sessionID,
            "prompt": "Unify ACP and Telegram plan execution",
        ])
        state = await bridge.planStateForTesting(sessionID: sessionID)
        #expect(state.activePlan?.isApproved == true)
        #expect(state.activePlan?.originalGoal == "Unify ACP and Telegram plan execution")
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

        try await bridge.prompt(id: .number(8), params: [
            "sessionId": sessionID,
            "prompt": "/plan clear",
        ])
        state = await bridge.planStateForTesting(sessionID: sessionID)
        #expect(state.activePlan == nil)
        #expect(state.brainstorming == nil)

        try await bridge.prompt(id: .number(9), params: [
            "sessionId": sessionID,
            "prompt": "/plan load",
        ])
        state = await bridge.planStateForTesting(sessionID: sessionID)
        #expect(state.activePlan?.id == "plan-acp12345")
        #expect(state.activePlan?.isApproved == false)
        #expect(try #require(
            await bridge.sessionRunner.snapshotSession(id: sessionID)
        ).history.contains { $0.content.contains("[Saved plan handoff]") })

        try await bridge.prompt(id: .number(10), params: [
            "sessionId": sessionID,
            "prompt": "/plan clear",
        ])
        try await bridge.prompt(id: .number(11), params: [
            "sessionId": sessionID,
            "prompt": "/goal validate shared workflow routing",
        ])
        let workflowGraphs = try await bridge.sessionRunner.taskOrchestrator.graphSnapshots(
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

        try await bridge.prompt(id: .number(12), params: [
            "sessionId": sessionID,
            "prompt": "/review focus on ACP routing",
        ])
        let reviewPrompt = try #require(await backend.recordedPrompts().last)
        #expect(reviewPrompt.contains("read-only review requested through ACP"))
        #expect(reviewPrompt.contains("Review focus requested by the user: focus on ACP routing"))
        #expect(reviewPrompt.contains("profile \"\(AgentProfileRole.reviewer.rawValue)\""))
        #expect(reviewPrompt.contains("graph=workflow_"))
        #expect(wire.updateTexts(kind: "user_message_chunk").last
            == "/review focus on ACP routing")
        #expect(wire.stopReason(for: 11) == "end_turn")
    }

    @Test
    func acpPlanSavePromotesStructuredHistoryResponseWithEveryTask() async throws {
        let planText = """
        Specifiche concordate
        - Keep compatibility.

        Implementation plan
        1. Add the shared model.
           Dependencies: none
        2. Wire the ACP command.
           Dependencies: 1
        3. Validate every frontend.
           Dependencies: 1, 2
        """
        let fixture = try await makeFixture(
            sessionID: "acp-command-structured-save",
            history: [
                AgentRuntimeMessage(role: .user, content: "Ship the shared routing"),
                AgentRuntimeMessage(role: .assistant, content: planText),
            ]
        )
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID

        try await bridge.prompt(id: .number(1), params: [
            "sessionId": sessionID,
            "prompt": "/plan save",
        ])

        let promoted = try #require(
            await bridge.planStateForTesting(sessionID: sessionID).activePlan
        )
        let taskIDs = (1...3).map { "\(promoted.id)-\($0)" }
        let titles = [
            "Add the shared model.",
            "Wire the ACP command.",
            "Validate every frontend.",
        ]
        let dependencies = [[], [taskIDs[0]], [taskIDs[0], taskIDs[1]]]
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").contains {
            $0.contains("Saved plan: \(promoted.id)")
        })
        #expect(promoted.originalGoal == "Ship the shared routing")
        #expect(promoted.points.map(\.id) == taskIDs)
        #expect(promoted.points.map(\.dependsOn) == dependencies)

        let stored = try #require(await bridge.sessionRunner.savedTaskPlans(
            workingDirectory: bridge.configuration.workingDirectory
        ).first)
        #expect(stored.graph.id == promoted.id)
        #expect(stored.graph.tasks.map(\.id) == taskIDs)
        #expect(stored.graph.tasks.map(\.title) == titles)
        #expect(stored.graph.tasks.map(\.dependsOn) == dependencies)

        try await bridge.prompt(id: .number(2), params: [
            "sessionId": sessionID,
            "prompt": "/plan clear",
        ])
        try await bridge.prompt(id: .number(3), params: [
            "sessionId": sessionID,
            "prompt": "/plan load",
        ])
        let loaded = try #require(
            await bridge.planStateForTesting(sessionID: sessionID).activePlan
        )
        #expect(loaded.id == promoted.id)
        #expect(loaded.points.map(\.id) == taskIDs)
        #expect(loaded.points.map(\.dependsOn) == dependencies)

        try await bridge.prompt(id: .number(4), params: [
            "sessionId": sessionID,
            "prompt": "/plan approve",
        ])
        try await bridge.prompt(id: .number(5), params: [
            "sessionId": sessionID,
            "prompt": "Ship the shared routing safely",
        ])
        let graph = try #require(
            try await bridge.sessionRunner.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: promoted.id
            )
        )
        #expect(graph.state == .active)
        #expect(graph.tasks.map(\.id) == taskIDs)
        #expect(graph.tasks.map(\.dependsOn) == dependencies)
        #expect(!graph.tasks.contains { $0.id.hasSuffix("-implementation") })
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

        // The session controller handles the failed turn while that turn is
        // still the current one.
        let controller = try #require(await bridge.chatSessionControllerForTesting(sessionID: sessionID))
        let token = await controller.beginTurnToken()
        await controller.handleFailedWorkflowTurn(
            graphID: graphID,
            reason: "the turn was cancelled",
            token: token,
            turnSessionID: sessionID
        )

        let graph = try #require(try await bridge.sessionRunner.taskGraphSnapshot(
            sessionID: sessionID
        ))
        #expect(graph.id == graphID)
        #expect(graph.tasks.count == 1)
        let recovery = try #require(await bridge.workflowStateForTesting(sessionID: sessionID))
        #expect(recovery.graphID == graphID)
        #expect(recovery.isAwaitingReply)
        #expect(recovery.pendingSignal?.transcriptMessage.contains("the turn was cancelled") == true)
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
        #expect(resumed.contains("Continue the goal workflow"))
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

    /// Replaces the characterization of task 1
    /// (`telegramOnIsRoutedToTheModelAsAnOrdinaryPrompt`), on purpose: a line
    /// whose command is `/telegram` is now answered at once and never reaches
    /// the model, whether Telegram is configured or not. Without Telegram
    /// settings every such line gets the terminal's unknown-command text
    /// (without its trailing newline, like every immediate ACP reply). With
    /// them, the lines that need no Bot API are answered as in the terminal.
    @Test(arguments: [false, true])
    func telegramLinesAreAnsweredAtOnceAndNeverReachTheModel(telegramConfigured: Bool) async throws {
        try await withTelegramSupportDirectory(telegramConfigured: telegramConfigured) {
            let fixture = try await makeFixture(sessionID: "acp-telegram-route-\(UUID().uuidString)")
            #expect(CoordinatorCommandParser.parse("/telegram on") == nil)

            let expectations: [(line: String, text: String)] = telegramConfigured
                ? [
                    ("/telegram", "Telegram: Configured"),
                    ("/telegram off", "Telegram remote control stopped."),
                    ("/telegram later", "Usage: /telegram [on|off]"),
                ]
                : ["/telegram", "/telegram on", "/telegram off", "/telegram later"].map {
                    ($0, "ZenCODE: unknown command '/telegram'.")
                }
            for expectation in expectations {
                let route = try await fixture.bridge.commandRouteForTesting(
                    sessionID: fixture.sessionID, prompt: expectation.line
                )
                guard case let .immediate(text) = route else {
                    Issue.record("\(expectation.line) must be answered at once, got \(route)")
                    continue
                }
                #expect(text == expectation.text)
            }

            try await fixture.bridge.prompt(id: .number(1), params: [
                "sessionId": fixture.sessionID, "prompt": telegramConfigured ? "/telegram" : "/telegram on",
            ])
            #expect(await fixture.backend.recordedPrompts().isEmpty)
            #expect(fixture.wire.updateTexts(kind: "agent_message_chunk") == [expectations[0].text])
            #expect(fixture.wire.stopReason(for: 1) == "end_turn")
        }
    }

    /// `/telegram on` hands the session's slot to its Telegram channel
    /// through the scripted Bot API, which reads the linked chat; `/telegram`
    /// reports the link as the channel does; `/telegram off` takes the slot
    /// back and stops the link. None of them reaches the model, and while
    /// Telegram drives the slot the editor's prompts are refused.
    @Test(.timeLimit(.minutes(1)))
    func telegramOnHandsTheSlotOverStatusReportsAndOffTakesItBack() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let transport = ACPTelegramScriptedTransport(botID: ACPTelegramTestSupport.uniqueBotID())
            let sessionID = "acp-telegram-on-\(UUID().uuidString)"
            let fixture = try await ACPTelegramBridgeFixture.make(
                root: root, sessionIDs: [sessionID], transport: transport
            )
            let bridge = fixture.bridge

            #expect(try await bridge.immediateTextForTesting(sessionID: sessionID, prompt: "/telegram")
                == "Telegram: Configured")
            #expect(await fixture.telegramChannel(sessionID: sessionID) == nil)

            #expect(try await bridge.immediateTextForTesting(sessionID: sessionID, prompt: "/telegram on")
                == "Telegram remote control is active.\nLinked chat: Test")
            let channel = try #require(await fixture.telegramChannel(sessionID: sessionID))
            #expect(await channel.isActive)
            #expect(await channel.readsIngress)
            #expect(await channel.drivesSlot)
            #expect(await channel.primaryChannelDescription == "editor")
            #expect(await ACPTelegramTestSupport.waitUntil { await transport.pollCount > 0 })

            // The editor is dormant: a prompt is refused without reaching the
            // model, the status is still answered.
            #expect(try await bridge.immediateTextForTesting(sessionID: sessionID, prompt: "Hello from the editor")
                == "ZenCODE: this session is driven from Telegram. Use /telegram off to take it back.")
            #expect(await fixture.backend.prompts.isEmpty)
            let status = try await bridge.immediateTextForTesting(sessionID: sessionID, prompt: "/telegram")
            #expect(status == (await channel.statusText()))
            #expect(status?.hasPrefix("Telegram: ") == true)
            #expect(status?.contains("Linked chat: Test") == true)

            #expect(try await bridge.immediateTextForTesting(sessionID: sessionID, prompt: "/telegram off")
                == "Telegram remote control stopped.")
            #expect(await !channel.isActive)
            #expect(await !channel.readsIngress)
            #expect(await !channel.drivesSlot)
            #expect(await fixture.telegramChannel(sessionID: sessionID) === channel)

            // A failed start answers the terminal's failure text.
            await transport.setGetMeFails(true)
            let failure = try #require(
                try await bridge.immediateTextForTesting(sessionID: sessionID, prompt: "/telegram on")
            )
            let lastError = try #require(await channel.controlState.lastError)
            #expect(failure == "ZenCODE: \(lastError)")
            #expect(await !channel.isActive)
            #expect(await !channel.drivesSlot)
            #expect(await fixture.backend.prompts.isEmpty)
            await bridge.shutdown()
        }
    }

    @Test
    func goalWithoutSubAgentsStartsResumesAndIsDiscoverable() async throws {
        let fixture = try await makeFixture(
            sessionID: "acp-direct-goal-\(UUID().uuidString)", allowedToolNames: ["local.readFile"]
        )
        let names = await fixture.bridge.commandNamesForGoalTesting(sessionID: fixture.sessionID)
        // Without the sub-agent tools `/review` and `/plan` stay hidden; `/tasks`
        // reads and controls the graph either way.
        #expect(names == ["goal", "tasks"])
        try await fixture.bridge.prompt(id: .number(1), params: [
            "sessionId": fixture.sessionID, "prompt": "/goal Preserve direct objective"
        ])
        let graph = try #require(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: fixture.sessionID))
        #expect(graph.workflow?.state == .awaitingUser)
        #expect(graph.workflow?.originalGoal == "Preserve direct objective")
        try await fixture.bridge.prompt(id: .number(2), params: [
            "sessionId": fixture.sessionID, "prompt": "Proceed directly"
        ])
        let prompts = await fixture.backend.recordedPrompts()
        #expect(prompts.contains { $0.contains("Continue the goal workflow") && $0.contains("Proceed directly") })
        #expect(prompts.contains { $0.contains("Continue the active /goal workflow automatically") })
        let resumed = try #require(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: fixture.sessionID))
        #expect(resumed.id == graph.id)
        #expect(resumed.workflow?.originalGoal == graph.workflow?.originalGoal)
        #expect(resumed.workflow?.state == .awaitingUser)
        #expect(await fixture.bridge.commandNamesForGoalTesting(sessionID: fixture.sessionID) == ["goal", "tasks"])
        let expectedGrant = ChatTurnPurpose.workflow(originalGoal: "", graphID: graph.id)
            .additionalToolNames(activePlan: nil)
            .union(["local.readFile"])
        let grants = await fixture.backend.recordedToolGrants()
        #expect(grants.contains(expectedGrant))
        #expect(grants.allSatisfy { $0?.isSubset(of: expectedGrant) == true })
    }

    @Test
    func directGoalAutomaticallyContinuesUntilGraphCompletionWithoutSubAgents() async throws {
        let fixture = try await makeFixture(
            sessionID: "acp-direct-complete-\(UUID().uuidString)", allowedToolNames: ["local.readFile"]
        )
        await fixture.backend.completeWorkflowDirectly()
        try await fixture.bridge.prompt(id: .number(1), params: [
            "sessionId": fixture.sessionID, "prompt": "/goal Complete direct work"
        ])
        let prompts = await fixture.backend.recordedPrompts()
        #expect(prompts.count == 3)
        #expect(prompts.dropFirst().allSatisfy { $0.contains("Continue the active /goal workflow automatically") })
        let graph = try #require(try await fixture.bridge.sessionRunner.taskGraphSnapshot(sessionID: fixture.sessionID))
        #expect(graph.state == .completed)
        #expect(graph.workflow?.state == .completed)
        #expect(graph.tasks.count == 1)
        #expect(graph.tasks.first?.attempts.last?.executor == .coordinator)
        #expect(graph.tasks.first?.attempts.last?.status == .completed)
        #expect(await fixture.bridge.workflowStateForTesting(sessionID: fixture.sessionID) == nil)
    }

    // MARK: - /tasks

    /// A turn that changes the graph publishes the plan while it runs, through
    /// the turn's own presentation, and never sends the same section twice. The
    /// session's first section comes after its reply, as its info and commands
    /// do.
    @Test
    func aTurnThatChangesTheTaskGraphPublishesThePlanWhileItRuns() async throws {
        let fixture = try await makeLiveFixture(sessionID: "acp-tasks-live-\(UUID().uuidString)")
        // The incarnation publishes its first section from its own observer
        // task, which the reply does not wait for.
        #expect(await ACPTelegramTestSupport.waitUntil {
            fixture.wire.timeline().contains("plan")
        })
        let timeline = fixture.wire.timeline()
        let reply = try #require(timeline.firstIndex(of: "result:1"))
        let firstPlan = try #require(timeline.firstIndex(of: "plan"))
        #expect(firstPlan > reply)

        await fixture.backend.completeWorkflowDirectly()
        try await fixture.bridge.prompt(id: .number(2), params: [
            "sessionId": fixture.sessionID, "prompt": "/goal Complete the review surface",
        ])
        let statuses = fixture.wire.planStatuses().filter { !$0.isEmpty }
        let contents = fixture.wire.planContents().filter { !$0.isEmpty }
        // The task exists before the turn that completes it, so the client saw
        // it move, and no section repeated the one before it.
        #expect(statuses.count >= 2)
        #expect(statuses.last == ["completed"])
        #expect(!contents.isEmpty)
        #expect(contents.allSatisfy { $0 == ["Complete direct work"] })
        #expect(zip(statuses, statuses.dropFirst()).allSatisfy { $0 != $1 })
        await fixture.bridge.shutdown()
    }

    /// `/tasks` is advertised and answered at once with the graph the terminal
    /// shows, as the plan update that is the client's Tasks section, and never
    /// reaches the model. `status`, `list`, and `ls` read the same graph;
    /// `show` and `get` answer one task.
    @Test
    func tasksCommandAnswersWithTheGraphAndThePlanSectionWithoutReachingTheModel() async throws {
        let fixture = try await makeFixture(
            sessionID: "acp-tasks-\(UUID().uuidString)", allowedToolNames: ["local.readFile"]
        )
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        // Without the sub-agent tools the catalog holds exactly these two.
        #expect(await bridge.commandNamesForGoalTesting(sessionID: sessionID) == ["goal", "tasks"])

        _ = try await bridge.sessionRunner.taskOrchestrator.createTasks(
            sessionID: sessionID,
            tasks: [
                TaskDefinition(id: "first", title: "Write the ACP answer"),
                TaskDefinition(id: "second", title: "Show the plan section"),
            ]
        )
        for line in ["/tasks", "/tasks status", "/tasks list", "/tasks ls", "/tasks LS"] {
            try await bridge.prompt(id: .number(1), params: ["sessionId": sessionID, "prompt": line])
            let answer = try #require(fixture.wire.updateTexts(kind: "agent_message_chunk").last)
            #expect(fixture.wire.updateTexts(kind: "user_message_chunk").last == line)
            #expect(answer.contains("Tasks:"))
            #expect(answer.contains("Write the ACP answer"))
            #expect(answer.contains("Show the plan section"))
            #expect(fixture.wire.planContents().last == ["Write the ACP answer", "Show the plan section"])
        }

        try await bridge.prompt(id: .number(2), params: [
            "sessionId": sessionID, "prompt": "/tasks show first",
        ])
        let detail = try #require(fixture.wire.updateTexts(kind: "agent_message_chunk").last)
        #expect(detail.contains("## Task `first`"))
        #expect(detail.contains("Write the ACP answer"))

        try await bridge.prompt(id: .number(3), params: [
            "sessionId": sessionID, "prompt": "/tasks GET first",
        ])
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").last?.contains("## Task `first`") == true)

        try await bridge.prompt(id: .number(4), params: ["sessionId": sessionID, "prompt": "/tasks show"])
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").last
            == "ZenCODE: /tasks show requires a task id.")

        try await bridge.prompt(id: .number(5), params: [
            "sessionId": sessionID, "prompt": "/tasks show missing",
        ])
        let missing = try #require(fixture.wire.updateTexts(kind: "agent_message_chunk").last)
        #expect(missing.hasPrefix("ZenCODE: "))
        #expect(await fixture.backend.recordedPrompts().isEmpty)
        #expect(fixture.wire.stopReason(for: 1) == "end_turn")
    }

    /// Without a task graph `/tasks` says so and publishes an empty plan, so a
    /// section left over from an earlier graph is cleared.
    @Test
    func tasksCommandWithoutAGraphSaysSoAndClearsThePlanSection() async throws {
        let fixture = try await makeFixture(sessionID: "acp-tasks-empty-\(UUID().uuidString)")
        try await fixture.bridge.prompt(id: .number(1), params: [
            "sessionId": fixture.sessionID, "prompt": "/tasks",
        ])
        #expect(await fixture.backend.recordedPrompts().isEmpty)
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk") == ["No task graph for this session."])
        #expect(fixture.wire.planContents() == [[]])
    }

    /// `/tasks clear` answers the shared notice and leaves an empty plan
    /// behind; an action the shared command does not know keeps its text and
    /// publishes nothing.
    @Test
    func tasksCommandClearAndUnknownActionKeepTheirOwnAnswers() async throws {
        let fixture = try await makeFixture(sessionID: "acp-tasks-clear-\(UUID().uuidString)")
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        _ = try await bridge.sessionRunner.taskOrchestrator.createTasks(
            sessionID: sessionID,
            tasks: [TaskDefinition(id: "only", title: "Only task")]
        )
        try await bridge.prompt(id: .number(1), params: ["sessionId": sessionID, "prompt": "/tasks clear"])
        #expect(await fixture.backend.recordedPrompts().isEmpty)
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk") == ["Cleared the session task graphs."])
        #expect(fixture.wire.planContents() == [[]])

        try await bridge.prompt(id: .number(2), params: ["sessionId": sessionID, "prompt": "/tasks bogus"])
        #expect(await fixture.backend.recordedPrompts().isEmpty)
        #expect(fixture.wire.updateTexts(kind: "agent_message_chunk").last
            == "ZenCODE: Unknown /tasks action 'bogus'. Use status, show, retry, cancel, or clear.")
        // The unknown action published no plan: the empty one is still the last.
        #expect(fixture.wire.planContents() == [[]])
    }

    /// `/tasks retry` and `/tasks cancel` run the shared lifecycle and answer
    /// with the graph they left, and the plan follows it, so the section never
    /// keeps a state the graph no longer has.
    @Test
    func tasksCommandRetryAndCancelAnswerWithTheGraphTheyLeft() async throws {
        let fixture = try await makeFixture(sessionID: "acp-tasks-lifecycle-\(UUID().uuidString)")
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        _ = try await bridge.sessionRunner.taskOrchestrator.createTasks(
            sessionID: sessionID,
            tasks: [
                TaskDefinition(id: "t1", title: "Retry me"),
                TaskDefinition(id: "t2", title: "Cancel me"),
            ]
        )
        _ = try await bridge.sessionRunner.taskOrchestrator.updateTask(
            sessionID: sessionID, taskID: "t1", update: TaskUpdate(status: .inProgress)
        )
        _ = try await bridge.sessionRunner.taskOrchestrator.updateTask(
            sessionID: sessionID, taskID: "t1", update: TaskUpdate(status: .failed, error: "boom")
        )

        try await bridge.prompt(id: .number(1), params: ["sessionId": sessionID, "prompt": "/tasks retry t1"])
        #expect(fixture.wire.planContents().last == ["Retry me", "Cancel me"])
        #expect(fixture.wire.planStatuses().last == ["pending", "pending"])

        try await bridge.prompt(id: .number(2), params: [
            "sessionId": sessionID, "prompt": "/tasks cancel t2 no longer needed",
        ])
        #expect(fixture.wire.planContents().last == ["Retry me", "[cancelled] Cancel me"])
        #expect(fixture.wire.planStatuses().last == ["pending", "pending"])
        #expect(await fixture.backend.recordedPrompts().isEmpty)
    }

    /// The Tasks section follows the graph outside a prompt too: a graph created
    /// or modified while no turn runs reaches the client, as the terminal's and
    /// the host app's observers publish their overview; a change that leaves the
    /// plan as it is does not send it again.
    @Test
    func aGraphChangedOutsideAPromptPublishesThePlanAutomatically() async throws {
        let fixture = try await makeLiveFixture(sessionID: "acp-tasks-idle-\(UUID().uuidString)")
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        // The session announces the graph it has when it starts: none here.
        #expect(await ACPTelegramTestSupport.waitUntil { fixture.wire.planContents() == [[]] })

        _ = try await bridge.sessionRunner.taskOrchestrator.createTasks(
            sessionID: sessionID,
            tasks: [TaskDefinition(id: "idle", title: "Created outside a prompt")]
        )
        #expect(await ACPTelegramTestSupport.waitUntil {
            fixture.wire.planContents().last == ["Created outside a prompt"]
        })

        // A change that leaves the plan as it is publishes nothing.
        _ = try await bridge.sessionRunner.taskOrchestrator.updateTask(
            sessionID: sessionID,
            taskID: "idle",
            update: TaskUpdate(details: "Only the task details changed")
        )
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.wire.planContents() == [[], ["Created outside a prompt"]])

        _ = try await bridge.sessionRunner.taskOrchestrator.updateTask(
            sessionID: sessionID,
            taskID: "idle",
            update: TaskUpdate(status: .inProgress)
        )
        #expect(await ACPTelegramTestSupport.waitUntil {
            fixture.wire.planStatuses().last == ["in_progress"]
        })
        #expect(fixture.wire.planContents() == [[], ["Created outside a prompt"], ["Created outside a prompt"]])
        #expect(fixture.wire.planStatuses() == [[], ["pending"], ["in_progress"]])

        // The plan the turn's presentation would send next is already
        // presented: a turn publishes it only when the graph changes again.
        try await bridge.prompt(id: .number(2), params: ["sessionId": sessionID, "prompt": "Hello"])
        #expect(fixture.wire.plans().count == 3)
        await bridge.shutdown()
    }

    /// A closed session publishes nothing more: the incarnation's observer is
    /// cancelled with it, so a graph changed afterwards never reaches the client
    /// of a session it no longer has.
    @Test
    func aClosedSessionPublishesNoFurtherPlan() async throws {
        let fixture = try await makeLiveFixture(sessionID: "acp-tasks-closed-\(UUID().uuidString)")
        let bridge = fixture.bridge
        let sessionID = fixture.sessionID
        _ = try await bridge.sessionRunner.taskOrchestrator.createTasks(
            sessionID: sessionID,
            tasks: [TaskDefinition(id: "gone", title: "Before the close")]
        )
        #expect(await ACPTelegramTestSupport.waitUntil {
            fixture.wire.planContents().last == ["Before the close"]
        })

        try await bridge.close(id: .number(2), params: ["sessionId": sessionID])
        #expect(await bridge.testSessionCount() == 0)
        let afterClose = fixture.wire.plans().count

        _ = try? await bridge.sessionRunner.taskOrchestrator.createTasks(
            sessionID: sessionID,
            tasks: [TaskDefinition(id: "later", title: "After the close")]
        )
        try await Task.sleep(for: .milliseconds(300))
        #expect(fixture.wire.plans().count == afterClose)
        await bridge.shutdown()
    }

    /// The observer belongs to the incarnation, not to its configuration: a
    /// same-epoch reconstruction (a refresh, an `@mention`, a reconfiguration)
    /// keeps the running one instead of starting a second.
    @Test
    func aSameEpochReconstructionKeepsTheRunningObserver() async throws {
        let fixture = try await makeLiveFixture(sessionID: "acp-tasks-inherit-\(UUID().uuidString)")
        #expect(await fixture.bridge.taskGraphObserverSurvivesReconstruction(
            sessionID: fixture.sessionID
        ))
        await fixture.bridge.shutdown()
    }

    /// The fixture of the command tests: a bridge on the scripted backend, its
    /// wire, and its working directory, with no session yet.
    private func makeBridge(
        sessionID: String,
        availableAgents: [AgentProfile] = AgentProfileStore.defaultProfiles()
    ) async throws -> (
        bridge: ZenCODEACPBridge,
        backend: ScriptedACPCommandBackend,
        wire: ACPCommandWire,
        workingDirectory: URL
    ) {
        let workingDirectory = AppStorageDirectory.appSupportDirectoryURL()
            .appendingPathComponent(sessionID, isDirectory: true)
        let backend = ScriptedACPCommandBackend()
        let wire = ACPCommandWire()
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableAgents: availableAgents,
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
        return (bridge, backend, wire, workingDirectory)
    }

    /// A bridge whose session is installed directly, without `session/new`:
    /// there is no incarnation task-graph observer, so only a prompt and the
    /// commands publish the plan.
    private func makeFixture(
        sessionID: String,
        allowedToolNames: Set<String>? = nil,
        availableAgents: [AgentProfile] = AgentProfileStore.defaultProfiles(),
        history: [AgentRuntimeMessage] = []
    ) async throws -> (
        bridge: ZenCODEACPBridge,
        backend: ScriptedACPCommandBackend,
        wire: ACPCommandWire,
        sessionID: String
    ) {
        let (bridge, backend, wire, workingDirectory) = try await makeBridge(
            sessionID: sessionID,
            availableAgents: availableAgents
        )
        let sessionConfiguration = AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: "test-model",
            workingDirectory: workingDirectory,
            systemPrompt: "ACP command routing test",
            cacheKey: nil,
            history: history,
            allowedToolNames: allowedToolNames
        )
        try await bridge.sessionRunner.createSession(
            configuration: sessionConfiguration
        )
        await bridge.installTestSession(sessionConfiguration)
        return (bridge, backend, wire, sessionID)
    }

    /// A bridge whose session a `session/new` created, as a client creates it:
    /// the incarnation's task-graph observer runs, so the plan follows the graph
    /// outside a prompt too.
    private func makeLiveFixture(
        sessionID: String
    ) async throws -> (
        bridge: ZenCODEACPBridge,
        backend: ScriptedACPCommandBackend,
        wire: ACPCommandWire,
        sessionID: String
    ) {
        let (bridge, backend, wire, workingDirectory) = try await makeBridge(sessionID: sessionID)
        try await bridge.newSession(id: .number(1), params: ["cwd": workingDirectory.path])
        let liveSessionID = try #require(await bridge.testAnySessionID())
        return (bridge, backend, wire, liveSessionID)
    }

    /// Runs `body` in a fresh UUID support directory of its own, holding a
    /// complete routing-v2 Telegram `settings.json` when `telegramConfigured`.
    /// Every test case gets its own directory, so a configured case can never
    /// leak its settings into an unconfigured one.
    private func withTelegramSupportDirectory(
        telegramConfigured: Bool,
        _ body: () async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-telegram-commands-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await AppStorageDirectory.withSupportDirectoryURL(root) {
            if telegramConfigured {
                try AgentSettingsManifestStore.save(AgentSettingsManifest(
                    models: [],
                    telegram: AgentTelegramSettingsManifest(
                        enabled: true,
                        botToken: "123456:ABCDEF",
                        linkedChatID: 42,
                        ownerUserID: 7,
                        routingVersion: 2,
                        routes: [.init(roomID: "default")]
                    )
                ))
            }
            #expect((AgentSettingsManifestStore.load()?.telegram?.isEnabled == true) == telegramConfigured)
            try await body()
        }
    }
}

extension ZenCODEACPBridge {
    fileprivate func commandNamesForGoalTesting(sessionID: String) -> [String] {
        availableCommandsForTesting(sessionID: sessionID).compactMap {
            $0.objectValue?["name"]?.stringValue
        }
    }

    fileprivate func availableCommandsForTesting(sessionID: String) -> [JSONValue] {
        guard let session = sessions[sessionID] else { return [] }
        return availableCommandsUpdate(for: session).objectValue?["availableCommands"]?.arrayValue ?? []
    }

    /// Whether a same-epoch reconstruction of `sessionID` inherits the running
    /// task-graph observer, as every refresh, `@mention`, and reconfiguration
    /// does.
    fileprivate func taskGraphObserverSurvivesReconstruction(sessionID: String) -> Bool {
        guard let live = sessions[sessionID],
              let observer = live.taskGraphObserver else {
            return false
        }
        let rebuilt = sessionState(
            configuration: live.configuration,
            selectedAgent: live.selectedAgent,
            inheriting: live
        )
        return rebuilt.epoch == live.epoch
            && rebuilt.taskGraphObserver == observer
            && rebuilt.taskPresentation === live.taskPresentation
    }

    /// The text of the immediate answer to `prompt`, routed as
    /// `session/prompt` routes it; `nil` when the line would start a turn.
    fileprivate func immediateTextForTesting(sessionID: String, prompt: String) async throws -> String? {
        guard case let .immediate(text) = try await commandRouteForTesting(sessionID: sessionID, prompt: prompt) else {
            return nil
        }
        return text
    }

    /// Routes `prompt` the way `session/prompt` does once it holds the
    /// reservation, and returns the route instead of running the turn.
    fileprivate func commandRouteForTesting(sessionID: String, prompt: String) async throws -> ACPCommandTurnRoute {
        guard let session = sessions[sessionID] else { throw CancellationError() }
        let reservation = try await host.reservePrompt(in: session.slotID)
        let route: ACPCommandTurnRoute
        do {
            route = try await routeACPCommandTurn(
                command: CoordinatorCommandParser.parse(prompt),
                routedPromptText: prompt,
                hasAgentMention: false,
                sessionID: sessionID,
                epoch: reservation.epoch,
                promptID: reservation.promptID
            )
        } catch {
            await host.releasePrompt(reservation)
            throw error
        }
        await host.releasePrompt(reservation)
        return route
    }
}
