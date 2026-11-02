//
//  TerminalChat+Goal.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    /// `/goal <goal>`, run by the shared controller (see
    /// ``ChatSessionController/runGoalCommand(line:)``).
    func handleWorkflowCommand(_ command: String) async -> TerminalSubmittedLineAction {
        await terminalAction(presenting: await chatSession.runGoalCommand(line: command))
    }

    /// Routes plain text typed while a workflow graph is still open and the
    /// coordinator ended its last turn without finishing the goal — typically
    /// after a clarification question. Slash commands and live mentions are
    /// handled by `submittedLineAction` before this method is reached.
    func handleWorkflowContinuationReply(
        _ reply: String
    ) async -> TerminalSubmittedLineAction? {
        guard let outcome = await chatSession.workflowContinuationReplyAction(for: reply) else {
            return nil
        }
        return await terminalAction(presenting: outcome)
    }

    /// Projects the authoritative workflow pause and explains how to resume it.
    /// New workflows never infer control state from prose. A finished or vanished
    /// graph clears the transient projection instead.
    func recordWorkflowTurnOutcome(
        graphID: String,
        coordinatorMessage: String?
    ) async {
        await chatSession.recordWorkflowTurnOutcome(
            graphID: graphID,
            coordinatorMessage: coordinatorMessage
        )
    }

    /// Handles a workflow turn that failed or was cancelled.
    ///
    /// Legacy empty graphs may be dropped; persisted workflow metadata retains
    /// the objective even before delegation. Structured pauses take precedence
    /// over the transient failure signal.
    func handleFailedWorkflowTurn(graphID: String, reason: String) async {
        await chatSession.handleFailedWorkflowTurn(graphID: graphID, reason: reason)
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

    nonisolated static let workflowMissingGoalMessage = ChatSessionNoticeText.workflowMissingGoalMessage

    nonisolated static let workflowActivePlanMessage = ChatSessionNoticeText.workflowActivePlanMessage

    nonisolated static func workflowAlreadyActiveMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        ChatSessionNoticeText.workflowAlreadyActiveMessage(
            graphID: graphID,
            pendingTaskCount: pendingTaskCount
        )
    }

    nonisolated static func workflowStillOpenMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        ChatSessionNoticeText.workflowStillOpenMessage(
            graphID: graphID,
            pendingTaskCount: pendingTaskCount
        )
    }

    /// Notice for a workflow turn that ended without the explicit clarification
    /// block. The graph stays open, but nothing is waiting for a reply.
    nonisolated static func workflowOpenWithoutQuestionMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        ChatSessionNoticeText.workflowOpenWithoutQuestionMessage(
            graphID: graphID,
            pendingTaskCount: pendingTaskCount
        )
    }

    /// Notice for a failed or cancelled workflow turn whose graph was preserved.
    nonisolated static func workflowRecoverableFailureMessage(
        graphID: String,
        pendingTaskCount: Int
    ) -> String {
        ChatSessionNoticeText.workflowRecoverableFailureMessage(
            graphID: graphID,
            pendingTaskCount: pendingTaskCount
        )
    }

    nonisolated static func workflowPrompt(goal: String, graphID: String) -> String {
        PlanningCommandKernel.workflowPrompt(goal: goal, graphID: graphID)
    }
}
