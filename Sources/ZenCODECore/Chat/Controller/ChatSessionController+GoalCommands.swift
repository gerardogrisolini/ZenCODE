//
//  ChatSessionController+GoalCommands.swift
//  ZenCODE
//
//  `/goal`: the workflow command and the reply its workflow awaits.
//

import Foundation

extension ChatSessionController {
    // MARK: - /goal

    /// `/goal <goal>`: creates the workflow task graph and starts the
    /// workflow turn.
    func runGoalCommand(
        line: String,
        fence: ChatCommandFence? = nil
    ) async -> ChatCommandOutcome {
        guard case let .goal(argument) = CoordinatorCommandParser.parse(line) else {
            return ChatCommandOutcome(notices: [.workflowMissingGoal])
        }

        guard !argument.isEmpty else {
            return ChatCommandOutcome(notices: [.workflowMissingGoal])
        }

        guard activePlan == nil, planBrainstorming == nil else {
            return ChatCommandOutcome(notices: [.workflowBlockedByPlan])
        }

        // The orchestrator refuses to create a graph while the current one is an
        // unfinished workflow graph. Answer that with a user-facing explanation
        // instead of leaking `graphNotMutable` from the runtime.
        if let existing = await currentWorkflowGraph(sessionID: sessionID) {
            return ChatCommandOutcome(notices: [
                .workflowAlreadyActive(
                    graphID: existing.id,
                    pendingTaskCount: Self.openTaskCount(in: existing)
                ),
            ])
        }

        // A superseded command creates no graph.
        guard isCommandCurrent(fence) else {
            return Self.superseded
        }
        let graphSessionID = sessionID
        let graphID = "workflow_\(UUID().uuidString.lowercased())"
        do {
            _ = try await runtime.taskOrchestrator.createGraph(
                sessionID: graphSessionID,
                id: graphID,
                source: .workflow,
                state: .active,
                tasks: [],
                originalGoal: argument
            )
        } catch {
            return ChatCommandOutcome(notices: [.operationFailed(description: error.localizedDescription)])
        }

        await effectivePresenter(for: nil).presentSubmittedCommand(line)
        guard commitCommandState(fence, {
            $0.activeWorkflow = WorkflowCommandRuntimeState(goal: argument, graphID: graphID)
        }) else {
            // Superseded after the graph was created: remove it again.
            _ = try? await runtime.removeTaskGraph(id: graphID, sessionID: graphSessionID)
            return Self.superseded
        }

        return Self.commandTurn(
            PlanningCommandKernel.workflowPrompt(goal: argument, graphID: graphID),
            purpose: .workflow(originalGoal: argument, graphID: graphID)
        )
    }

    /// Routes plain text typed while a workflow graph is still open and the
    /// coordinator ended its last turn without finishing the goal — typically
    /// after a clarification question. `nil` when no workflow is waiting for
    /// the operator.
    func workflowContinuationReplyAction(
        for reply: String,
        fence: ChatCommandFence? = nil,
        policy: ChatPlanningCommandPolicy = .terminal
    ) async -> ChatCommandOutcome? {
        guard var workflow = activeWorkflow, workflow.isAwaitingReply else { return nil }
        // The graph may have been cleared, archived, completed or replaced since
        // the workflow turn ended. Never resume a graph that is no longer the
        // session's open workflow graph.
        guard let graph = await currentWorkflowGraph(sessionID: sessionID),
              graph.id == workflow.graphID else {
            commitCommandState(fence) { $0.activeWorkflow = nil }
            return nil
        }
        guard workflow.recordReply(reply) else { return nil }
        let style = policy.workflowReply
        let continuationSessionID = sessionID
        let previousWorkflow = activeWorkflow
        var generation: AgentCoreSessionRunner.SessionGeneration?
        if style == .acp {
            generation = await runtime.currentSessionGeneration(for: continuationSessionID)
            // ACP does not resume once its task is cancelled.
            guard !Task.isCancelled else { return nil }
            guard isCommandCurrent(fence) else { return Self.superseded }
        }
        do {
            let resumedGraph = try await runtime.taskOrchestrator.resumeWorkflow(
                sessionID: continuationSessionID, expectedGraph: graph
            )
            let resumedWorkflow = workflow
            let committed = !Task.isCancelled
                && sessionID == continuationSessionID
                && stateStore.withLock { state in
                    guard fence.map({ state.activeTurnToken == $0.token }) ?? true,
                          state.commandState.activeWorkflow == previousWorkflow else {
                        return false
                    }
                    state.commandState.activeWorkflow = resumedWorkflow
                    return true
                }
            guard committed else {
                if style == .terminal {
                    try? await runtime.taskOrchestrator.rollbackWorkflowResume(
                        sessionID: continuationSessionID, previousGraph: graph, resumedGraph: resumedGraph
                    )
                } else if let generation,
                          await runtime.currentSessionGeneration(for: continuationSessionID) == generation {
                    try? await runtime.taskOrchestrator.rollbackWorkflowResume(
                        sessionID: continuationSessionID, previousGraph: graph, resumedGraph: resumedGraph
                    )
                }
                return ChatCommandOutcome()
            }
        } catch {
            return ChatCommandOutcome(notices: [.operationFailed(description: error.localizedDescription)])
        }

        return Self.commandTurn(
            PlanningCommandKernel.workflowContinuationPrompt(
                state: workflow,
                pendingTaskCount: Self.openTaskCount(in: graph),
                totalTaskCount: graph.tasks.count
            ),
            purpose: .workflow(originalGoal: workflow.goal, graphID: workflow.graphID)
        )
    }
}
