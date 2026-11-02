//
//  ChatTurn.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Why a chat turn runs. The purpose selects the extra coordinator tools, the
/// planning and workflow bookkeeping, and whether coordinator content is shown.
public enum ChatTurnPurpose: Sendable, Equatable {
    case normal
    case plan(originalGoal: String)
    /// A `/goal` turn. The graph ID travels with the purpose so the turn can
    /// grant workflow tools, keep the clarification round-trip on the same
    /// graph, and clean up an empty graph when the turn fails or is cancelled.
    case workflow(originalGoal: String, graphID: String)
    case review

    /// Task tools granted while an approved plan is being implemented.
    static let implementationToolNames: Set<String> = [
        "tasks.list", "tasks.get", "tasks.update", "tasks.retry", "tasks.cancel",
    ]

    /// Task tools granted to a `/goal` workflow turn.
    static let workflowToolNames: Set<String> = implementationToolNames.union(["tasks.create"])

    /// Task tools granted to a `/review` turn, which adds its review task to an
    /// active graph before delegating it.
    static let reviewToolNames: Set<String> = [
        "tasks.create", "tasks.list", "tasks.get", "tasks.update",
    ]

    /// The single table of coordinator tools a turn adds to the session grant.
    public func additionalToolNames(activePlan: TerminalSessionPlan?) -> Set<String> {
        switch self {
        case .plan:
            return ["todo.write"]
        case .normal:
            guard let activePlan, activePlan.isApproved, !activePlan.isCompleted else {
                return []
            }
            return Self.implementationToolNames
        case .workflow:
            return Self.workflowToolNames
        case .review:
            return Self.reviewToolNames
        }
    }

    /// Planner turns hide coordinator content: only the Planner's final text
    /// is presented once the turn completes.
    var suppressesCoordinatorContent: Bool {
        if case .plan = self { return true }
        return false
    }
}

/// Everything a channel supplies to run one chat turn.
public struct ChatTurnRequest: Sendable {
    public var prompt: String
    public var attachments: [AgentRuntimeAttachment]
    public var purpose: ChatTurnPurpose
    /// The channel's session configuration, final for this turn. Channels add
    /// the purpose's coordinator tools from the single table in
    /// ``ChatTurnPurpose/additionalToolNames(activePlan:)`` while building it,
    /// because the grant also shapes their system prompt and profile policy.
    public var sessionConfiguration: AgentCoreSessionConfiguration
    /// Per-turn authorization override (for example a remote channel that
    /// owns consent for this turn); `nil` uses the runner default.
    public var authorizeTool: AgentToolAuthorizationHandler?
    /// Evaluated before every model request of the turn, including automatic
    /// workflow continuations.
    public var turnInstructionProvider: (@Sendable () async -> String?)?
    /// Presents this turn instead of the controller's default presenter, for
    /// channels whose presentation is bound to one request (ACP prompts).
    public var presenter: (any ChatSessionPresenter)?
    /// Where the prompt came from, for presenters that record it (see
    /// ``ChatSessionStateReducer``); `nil` lets each one use its default.
    public var origin: ChatTurnOrigin?

    public init(
        prompt: String,
        attachments: [AgentRuntimeAttachment] = [],
        purpose: ChatTurnPurpose = .normal,
        sessionConfiguration: AgentCoreSessionConfiguration,
        authorizeTool: AgentToolAuthorizationHandler? = nil,
        turnInstructionProvider: (@Sendable () async -> String?)? = nil,
        presenter: (any ChatSessionPresenter)? = nil,
        origin: ChatTurnOrigin? = nil
    ) {
        self.prompt = prompt
        self.attachments = attachments
        self.purpose = purpose
        self.sessionConfiguration = sessionConfiguration
        self.authorizeTool = authorizeTool
        self.turnInstructionProvider = turnInstructionProvider
        self.presenter = presenter
        self.origin = origin
    }
}

/// The outcome of a completed chat turn.
public struct ChatTurnResult: Sendable {
    /// The runtime response. For a planning turn this is the Planner response
    /// that replaced the coordinator output.
    public let response: DirectAgentResponse
    /// Final coordinator content block delimited by tool calls, rather than
    /// the runtime's aggregate response text.
    public let finalAssistantBlock: String?
    public let fileChangeSummary: TurnFileChangeSummary?
    /// The approved plan that this turn completed, if any.
    public let automaticallyCompletedPlan: TerminalSessionPlan?
}

/// A failed or cancelled chat turn, with the file changes it still produced.
public struct ChatTurnFailure: Error, Sendable {
    public let underlying: Error
    public let fileChangeSummary: TurnFileChangeSummary?

    public var isCancellation: Bool {
        underlying is CancellationError
    }
}

/// A `/goal` workflow state change the channel may announce to the operator.
public enum ChatWorkflowNotice: Sendable, Equatable {
    /// The coordinator asked a question; the next message answers it.
    case awaitingReply(graphID: String, pendingTaskCount: Int)
    /// The workflow is blocked; the next message resumes it.
    case blocked(graphID: String, message: String)
    /// The graph stays open but nothing waits for a reply.
    case openWithoutQuestion(graphID: String, pendingTaskCount: Int)
    /// A failed or cancelled turn preserved the graph; the next message resumes it.
    case recoverableFailure(graphID: String, pendingTaskCount: Int)
}

/// Transient `/plan` and `/goal` state owned by one chat session.
///
/// Never copy the planning clarification, the approval handshake, or the
/// workflow continuation into snapshots, checkpoints, or persisted session
/// models: only ``activePlan`` and ``queuedPlans`` are session state that
/// channels may persist.
struct ChatCommandState: Sendable, Equatable {
    var activePlan: TerminalSessionPlan?
    /// The plans that follow ``activePlan`` in a Planner sequence, in order.
    /// Invariant: non-empty only while ``activePlan`` is set.
    var queuedPlans: [TerminalSessionPlan]
    /// Ephemeral `/plan` clarification state.
    var planBrainstorming: PlanningCommandRuntimeState?
    /// Ephemeral `/plan` approval state: only the plan being confirmed.
    var pendingPlanApprovalPlanID: String?
    /// Ephemeral `/goal` workflow state used to continue the same graph.
    var activeWorkflow: WorkflowCommandRuntimeState?

    init(
        activePlan: TerminalSessionPlan? = nil,
        queuedPlans: [TerminalSessionPlan] = [],
        planBrainstorming: PlanningCommandRuntimeState? = nil,
        pendingPlanApprovalPlanID: String? = nil,
        activeWorkflow: WorkflowCommandRuntimeState? = nil
    ) {
        self.activePlan = activePlan
        self.queuedPlans = queuedPlans
        self.planBrainstorming = planBrainstorming
        self.pendingPlanApprovalPlanID = pendingPlanApprovalPlanID
        self.activeWorkflow = activeWorkflow
    }
}
