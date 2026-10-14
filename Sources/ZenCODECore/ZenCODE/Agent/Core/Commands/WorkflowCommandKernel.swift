// Graph-backed workflow continuation and legacy clarification recognition.

import Foundation
import ToolCore

extension PlanningCommandKernel {
    /// Runtime decision after each coordinator generation in a `/goal` turn.
    /// An open graph is never treated as a successful end turn merely because
    /// the model stopped producing tool calls or prose.
    enum WorkflowTurnDisposition: Equatable, Sendable {
        case completed
        case awaitingClarification
        case blocked
        case continueAutomatically
    }

    /// Explicit heading a `/goal` coordinator must use to request clarification,
    /// mirroring the Planner's mandatory "Planner questions" block. Only this
    /// signal arms the conversational continuation round-trip.
    static let workflowClarificationHeading = "Workflow question"

    /// Transcript text for a workflow armed without coordinator prose.
    static let workflowResumeSignalMessage =
        "(no coordinator message: this workflow was resumed from a previous session)"

    static let workflowUnknownFailureReason = "the turn ended without a result"

    /// Transcript text for a workflow armed after a failed or cancelled turn.
    static func workflowRecoverySignalMessage(reason: String) -> String {
        "(the previous workflow turn did not finish: \(reason). "
            + "Its task graph was preserved so the workflow can be resumed or retried.)"
    }

    /// True when the coordinator used the explicit clarification protocol: a
    /// first non-blank line exactly equal to "Workflow question". Mirrors
    /// ``isPlannerQuestionResponse`` so both round-trips are recognised the same
    /// deterministic, testable way.
    static func isWorkflowClarificationResponse(_ text: String) -> Bool {
        guard let firstLine = text
            .split(whereSeparator: \Character.isNewline)
            .map(String.init)
            .first(where: { $0.nilIfBlank != nil }) else {
            return false
        }
        return firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
            == workflowClarificationHeading
    }

    /// Completion and pauses are graph-backed. Only legacy metadata-free
    /// checkpoints use the exact heading compatibility fallback.
    static func workflowTurnDisposition(
        graph: TaskGraphSnapshot?,
        expectedGraphID: String,
        coordinatorMessage: String?
    ) -> WorkflowTurnDisposition {
        guard let graph,
              graph.id == expectedGraphID,
              graph.source.isWorkflow,
              !graph.state.isTerminal else {
            return .completed
        }
        if let workflow = graph.workflow {
            switch workflow.state {
            case .running: return .continueAutomatically
            case .awaitingUser: return .awaitingClarification
            case .blocked: return .blocked
            case .completed: return .completed
            }
        }
        // Explicit compatibility fallback for schema-1 graphs without metadata.
        if let coordinatorMessage,
           isWorkflowClarificationResponse(coordinatorMessage) {
            return .awaitingClarification
        }
        return .continueAutomatically
    }
}
