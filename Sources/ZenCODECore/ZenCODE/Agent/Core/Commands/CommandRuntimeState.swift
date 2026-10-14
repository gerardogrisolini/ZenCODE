// Transient command discussions and Planner turn fencing; never persisted.

import Foundation
import ToolCore

/// Runtime-only Planner discussion state. This type intentionally does not
/// conform to `Codable`: saved sessions, plan-library entries, and task-graph
/// checkpoints must never restore an unfinished clarification loop.
struct PlanningCommandRuntimeState: Sendable, Equatable {
    struct Exchange: Sendable, Equatable {
        let plannerMessage: String
        let userReply: String
    }

    let collectionID: UUID
    let goal: String
    var plannerAgentID: String?
    var plannerOutputRevision: UInt64?
    var exchanges: [Exchange]
    var pendingPlannerMessage: String?

    init(goal: String, collectionID: UUID = UUID()) {
        self.collectionID = collectionID
        self.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        self.plannerAgentID = nil
        self.plannerOutputRevision = nil
        self.exchanges = []
        self.pendingPlannerMessage = nil
    }

    var isAwaitingReply: Bool {
        pendingPlannerMessage?.nilIfBlank != nil
    }

    mutating func recordReply(_ reply: String) -> Bool {
        guard let pendingPlannerMessage = pendingPlannerMessage?.nilIfBlank,
              let normalizedReply = reply.nilIfBlank else {
            return false
        }
        exchanges.append(
            Exchange(
                plannerMessage: pendingPlannerMessage,
                userReply: normalizedReply
            )
        )
        self.pendingPlannerMessage = nil
        return true
    }

    mutating func recordPlannerOutput(
        _ text: String,
        agentID: String,
        revision: UInt64
    ) {
        plannerAgentID = agentID
        plannerOutputRevision = revision
        pendingPlannerMessage = PlanningCommandKernel.isPlannerQuestionResponse(text) ? text : nil
    }
}

/// Transient frontend projection and reply transcript for the persisted /goal workflow.
/// The checkpoint owns the original goal and structured control state, not this transcript.
struct WorkflowCommandRuntimeState: Sendable, Equatable {
    struct Exchange: Sendable, Equatable {
        let coordinatorMessage: String
        let userReply: String
    }

    /// Explicit persisted pauses and transient recovery/resume signals may
    /// capture the next plain user message. Ordinary prose arms nothing on new workflows.
    enum ContinuationSignal: Sendable, Equatable {
        /// The graph awaits a user answer (legacy graphs may use the old heading).
        case clarification(String)
        case blocked(String)
        /// The workflow graph was restored from a previous session, so no
        /// coordinator prose exists for it.
        case resumedGraph
        /// The last workflow turn failed or was cancelled while its persisted
        /// objective or delegated tasks were preserved for a retry.
        case recoverableFailure(String)

        /// Human-readable text recorded in the continuation transcript.
        var transcriptMessage: String {
            switch self {
            case let .clarification(text), let .blocked(text):
                return text
            case .resumedGraph:
                return PlanningCommandKernel.workflowResumeSignalMessage
            case let .recoverableFailure(reason):
                return PlanningCommandKernel.workflowRecoverySignalMessage(reason: reason)
            }
        }
    }

    /// The workflow graph this state belongs to. Every continuation turn must
    /// re-inject it so the coordinator keeps working on the same graph.
    let graphID: String
    /// The original /goal argument from its checkpoint; empty only for legacy graphs.
    let goal: String
    var exchanges: [Exchange]
    /// The explicit signal that armed the continuation round-trip, if any. Only
    /// its presence lets the next plain user message continue this workflow.
    private(set) var pendingSignal: ContinuationSignal?

    init(goal: String, graphID: String) {
        self.graphID = graphID
        self.goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        self.exchanges = []
        self.pendingSignal = nil
    }

    var isAwaitingReply: Bool {
        pendingSignal != nil
    }

    /// The message shown to the coordinator as "what you asked last", derived
    /// from the armed signal.
    var pendingCoordinatorMessage: String? {
        pendingSignal?.transcriptMessage
    }

    /// Projects authoritative persisted state. Only legacy checkpoints without
    /// workflow metadata retain the old heading protocol until their first resume.
    @discardableResult
    mutating func recordCoordinatorOutput(_ text: String?, graph: TaskGraphSnapshot? = nil) -> Bool {
        if let graph, let workflow = graph.workflow {
            guard graph.id == graphID, !graph.state.isTerminal else {
                pendingSignal = nil
                return false
            }
            switch workflow.state {
            case .running, .completed: pendingSignal = nil
            case .awaitingUser: pendingSignal = .clarification(workflow.message ?? "Workflow awaiting user input.")
            case .blocked: pendingSignal = .blocked(workflow.message ?? "Workflow blocked.")
            }
            return pendingSignal != nil
        }
        guard let text = text?.nilIfBlank,
              PlanningCommandKernel.isWorkflowClarificationResponse(text) else {
            pendingSignal = nil
            return false
        }
        pendingSignal = .clarification(text)
        return true
    }

    /// Arms the round-trip for a graph restored from a previous session.
    mutating func armForResumedGraph() {
        pendingSignal = .resumedGraph
    }

    /// Arms the round-trip after a failed or cancelled turn that preserved its
    /// workflow graph, including metadata-only objectives before delegation.
    mutating func armForRecoverableFailure(reason: String) {
        pendingSignal = .recoverableFailure(
            reason.nilIfBlank ?? PlanningCommandKernel.workflowUnknownFailureReason
        )
    }

    mutating func disarm() {
        pendingSignal = nil
    }

    mutating func recordReply(_ reply: String) -> Bool {
        guard let pendingSignal,
              let normalizedReply = reply.nilIfBlank else {
            return false
        }
        exchanges.append(
            Exchange(
                coordinatorMessage: pendingSignal.transcriptMessage,
                userReply: normalizedReply
            )
        )
        self.pendingSignal = nil
        return true
    }
}

struct PlannerTurnBaseline: Sendable, Equatable {
    let expectedAgentID: String?
    let expectedRevision: UInt64?
    let expectedAgentWasAvailable: Bool
    let revisionsByAgentID: [String: UInt64]
    /// A newly started `/plan` discussion must receive the Planner's mandatory
    /// question block before it can accept a final plan.
    let requiresInitialQuestion: Bool

    init(
        state: PlanningCommandRuntimeState?,
        snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        rootSessionID: String?
    ) {
        expectedAgentID = state?.plannerAgentID
        expectedRevision = state?.plannerOutputRevision
        requiresInitialQuestion = state?.plannerAgentID == nil
            && state?.plannerOutputRevision == nil
            && state?.exchanges.isEmpty == true
            && state?.pendingPlannerMessage == nil
        let plannerSnapshots = PlanningCommandKernel.plannerSnapshots(
            snapshots,
            rootSessionID: rootSessionID
        )
        expectedAgentWasAvailable = plannerSnapshots.contains { snapshot in
            snapshot.id == state?.plannerAgentID && snapshot.status != .closed
        }
        revisionsByAgentID = Dictionary(
            uniqueKeysWithValues: plannerSnapshots.map {
                ($0.id, $0.latestOutputRevision)
            }
        )
    }
}
