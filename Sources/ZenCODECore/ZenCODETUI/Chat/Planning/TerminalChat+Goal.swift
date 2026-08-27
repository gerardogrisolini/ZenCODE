//
//  TerminalChat+Goal.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension TerminalChat {
    func handleWorkflowCommand(_ command: String) async -> TerminalSubmittedLineAction {
        guard case let .goal(argument) = CoordinatorCommandParser.parse(command) else {
            await writeFailureMessage(Self.workflowMissingGoalMessage)
            return .continueChat
        }

        guard !argument.isEmpty else {
            await writeFailureMessage(Self.workflowMissingGoalMessage)
            return .continueChat
        }

        guard activePlan == nil, planBrainstorming == nil else {
            await writeFailureMessage(Self.workflowActivePlanMessage)
            return .continueChat
        }

        // The orchestrator refuses to create a graph while the current one is an
        // unfinished workflow graph. Answer that with a user-facing explanation
        // instead of leaking `graphNotMutable` from the runtime.
        if let existing = await currentWorkflowGraph() {
            await writeFailureMessage(
                Self.workflowAlreadyActiveMessage(
                    graphID: existing.id,
                    pendingTaskCount: Self.openTaskCount(in: existing)
                )
            )
            return .continueChat
        }

        if !isSubAgentToolEnabled {
            await writeFailureMessage(
                """
                ZenCODE: /goal requires the sub-agents tool group. \
                Enable it with /tools (or switch to an agent that includes it) and try again.

                """
            )
            return .continueChat
        }

        let graphID = "workflow_\(UUID().uuidString.lowercased())"
        do {
            _ = try await sessionRunner.taskOrchestrator.createGraph(
                sessionID: sessionID,
                id: graphID,
                source: .workflow,
                state: .active,
                tasks: []
            )
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            return .continueChat
        }

        await writeSubmittedPrompt(command)
        activeWorkflow = WorkflowCommandRuntimeState(goal: argument, graphID: graphID)

        return .runHiddenPrompt(
            Self.workflowPrompt(goal: argument, graphID: graphID),
            purpose: .workflow(originalGoal: argument, graphID: graphID)
        )
    }

    /// Routes plain text typed while a workflow graph is still open and the
    /// coordinator ended its last turn without finishing the goal — typically
    /// after a clarification question. Slash commands and live mentions are
    /// handled by `submittedLineAction` before this method is reached.
    func handleWorkflowContinuationReply(
        _ reply: String
    ) async -> TerminalSubmittedLineAction? {
        guard var workflow = activeWorkflow, workflow.isAwaitingReply else { return nil }
        guard isSubAgentToolEnabled else { return nil }
        // The graph may have been cleared, archived, completed or replaced since
        // the workflow turn ended. Never resume a graph that is no longer the
        // session's open workflow graph.
        guard let graph = await currentWorkflowGraph(), graph.id == workflow.graphID else {
            activeWorkflow = nil
            return nil
        }
        guard workflow.recordReply(reply) else { return nil }
        activeWorkflow = workflow

        return .runHiddenPrompt(
            PlanningCommandKernel.workflowContinuationPrompt(
                state: workflow,
                pendingTaskCount: Self.openTaskCount(in: graph),
                totalTaskCount: graph.tasks.count
            ),
            purpose: .workflow(originalGoal: workflow.goal, graphID: workflow.graphID)
        )
    }

    /// Arms the continuation round-trip only when the workflow turn ended with
    /// the explicit `Workflow question` clarification block while its graph is
    /// still open, and tells the user their next message continues it. Any other
    /// output disarms the round-trip: an ordinary workflow turn must never
    /// capture the user's next message. A finished (or vanished) graph clears
    /// the state instead.
    func recordWorkflowTurnOutcome(
        graphID: String,
        coordinatorMessage: String?
    ) async {
        guard var workflow = activeWorkflow, workflow.graphID == graphID else { return }
        guard let graph = await currentWorkflowGraph(), graph.id == graphID else {
            activeWorkflow = nil
            return
        }
        let didArm = workflow.recordCoordinatorOutput(coordinatorMessage)
        activeWorkflow = workflow
        guard didArm else {
            // Truthful notice: the graph survives, but nothing is waiting for a
            // reply, so the next message is an ordinary chat message.
            await writeSystemMessage(
                Self.workflowOpenWithoutQuestionMessage(
                    graphID: graph.id,
                    pendingTaskCount: Self.openTaskCount(in: graph)
                )
            )
            return
        }
        await writeSystemMessage(
            Self.workflowStillOpenMessage(
                graphID: graph.id,
                pendingTaskCount: Self.openTaskCount(in: graph)
            )
        )
    }

    /// Handles a workflow turn that failed or was cancelled.
    ///
    /// A graph that never received a task is dropped, so a cancelled `/goal`
    /// cannot leave an empty "0 of 0 tasks pending" graph behind for the resume
    /// menu. A graph that already holds delegated tasks is preserved *and* the
    /// continuation round-trip is armed for recovery, so the announced retry
    /// path really exists: the next message resumes that same graph.
    func handleFailedWorkflowTurn(graphID: String, reason: String) async {
        guard let graph = await currentWorkflowGraph(), graph.id == graphID else {
            if activeWorkflow?.graphID == graphID {
                activeWorkflow = nil
            }
            return
        }
        guard !graph.tasks.isEmpty else {
            _ = try? await sessionRunner.removeTaskGraph(id: graphID, sessionID: sessionID)
            if activeWorkflow?.graphID == graphID {
                activeWorkflow = nil
            }
            return
        }
        var workflow = activeWorkflow?.graphID == graphID
            ? activeWorkflow!
            : WorkflowCommandRuntimeState(goal: "", graphID: graphID)
        workflow.armForRecoverableFailure(reason: reason)
        activeWorkflow = workflow
        await writeSystemMessage(
            Self.workflowRecoverableFailureMessage(
                graphID: graphID,
                pendingTaskCount: Self.openTaskCount(in: graph)
            )
        )
    }

    /// The session's current task graph when it is an unfinished workflow graph.
    private func currentWorkflowGraph() async -> TaskGraphSnapshot? {
        guard let graph = try? await sessionRunner.taskGraphSnapshot(sessionID: sessionID),
              graph.source.requiresSubAgentExecution,
              !graph.state.isTerminal else {
            return nil
        }
        return graph
    }

    nonisolated static func openTaskCount(in graph: TaskGraphSnapshot) -> Int {
        graph.tasks.filter { $0.status != .completed && $0.status != .cancelled }.count
    }

    /// Placeholder pending message for a workflow armed without coordinator
    /// prose (a graph resumed from a checkpoint). It keeps `isAwaitingReply`
    /// meaningful without inventing a question the coordinator never asked.
    nonisolated static var workflowResumeMarker: String {
        PlanningCommandKernel.workflowResumeSignalMessage
    }

    nonisolated static let workflowMissingGoalMessage =
        "ZenCODE: /goal requires a goal. "
        + "Use /goal <goal> to describe what should be planned and delegated.\n"

    nonisolated static let workflowActivePlanMessage =
        "ZenCODE: /goal cannot start while an active plan or planning discussion exists. "
        + "Finish it or use /plan clear before starting a workflow.\n"

    nonisolated static func workflowAlreadyActiveMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        "ZenCODE: a delegated workflow is already running (\(graphID), "
            + "\(pendingTaskCount) task\(pendingTaskCount == 1 ? "" : "s") still open). "
            + "Reply in chat to continue it while it is waiting for you, "
            + "review it with /tasks, "
            + "or run /tasks clear before starting another /goal.\n"
    }

    nonisolated static func workflowStillOpenMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        "Workflow \"\(graphID)\" asked a question and is still open "
            + "(\(pendingTaskCount) task\(pendingTaskCount == 1 ? "" : "s") open). "
            + "Your next message answers it on the same task graph; "
            + "use /tasks to review or /tasks clear to stop it.\n"
    }

    /// Notice for a workflow turn that ended without the explicit clarification
    /// block. The graph stays open, but nothing is waiting for a reply.
    nonisolated static func workflowOpenWithoutQuestionMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        "Workflow \"\(graphID)\" is still open "
            + "(\(pendingTaskCount) task\(pendingTaskCount == 1 ? "" : "s") open) "
            + "but it is not waiting for an answer, so your next message is an ordinary "
            + "message. Use /tasks to review it or /tasks clear to stop it.\n"
    }

    /// Notice for a failed or cancelled workflow turn whose graph was preserved.
    nonisolated static func workflowRecoverableFailureMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        "Workflow \"\(graphID)\" was interrupted and its task graph was kept "
            + "(\(pendingTaskCount) task\(pendingTaskCount == 1 ? "" : "s") open). "
            + "Your next message resumes it on the same task graph; "
            + "use /tasks to review or /tasks clear to stop it.\n"
    }

    nonisolated static func workflowPrompt(goal: String, graphID: String) -> String {
        PlanningCommandKernel.workflowPrompt(goal: goal, graphID: graphID)
    }
}
