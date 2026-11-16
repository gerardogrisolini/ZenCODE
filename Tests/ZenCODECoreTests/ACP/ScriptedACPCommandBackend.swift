//
//  ScriptedACPCommandBackend.swift
//  ZenCODE
//
//  The scripted runtime backend of the ACP command tests: it answers each
//  prompt with a canned turn, drives the workflow scenarios, and records the
//  prompts and tool grants it receives.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

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
