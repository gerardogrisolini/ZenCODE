//
//  ChatPlanningCommandPolicy.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// What a `/review` prompt is built from.
struct ChatReviewPromptRequest: Sendable {
    /// The focus the operator typed after `/review`; empty for none.
    let scope: String
    /// The Reviewer profiles the coordinator may delegate to.
    let reviewers: [AgentProfile]
    /// The approved active plan under verification, if any.
    let approvedPlan: TerminalSessionPlan?
    /// The approved plan's task graph, or the session's current one.
    let taskGraph: TaskGraphSnapshot?
}

/// Where the planning commands depart from the terminal's sequence.
///
/// The planning operations (`/plan`, `/goal`, `/review`, and the replies they
/// wait for) run the terminal's sequence, ``terminal``. ACP ran its own copy
/// of them before it moved onto the shared operations, with gates, history
/// sources, and transaction rules of its own, and its behavior must not
/// change. Each field selects the behavior of one command, and its
/// ``Style/acp`` value (or its payload) names the ACP behavior it keeps.
/// ``acp(savingAgent:fallbackHistory:reviewPrompt:)`` sets every field to it.
/// The channel builds the policy for each command, because some fields carry
/// the session's own state.
///
/// What the policy leaves out stays with the channel: the wording (ACP maps
/// the notices to its own messages), the sub-agent gate of ACP (its tool
/// grant), the error of a profile catalog that cannot be read, and the
/// projection of a restored `/goal` workflow before a reply.
struct ChatPlanningCommandPolicy: Sendable {
    /// One command's behavior.
    enum Style: Sendable, Equatable {
        /// The terminal's sequence.
        case terminal
        /// ACP's sequence before it ran on the shared operations.
        case acp
    }

    /// `/review`.
    enum Review: Sendable {
        /// The terminal's `/review`: it refuses without file changes, an
        /// approved plan, or a task graph, and builds
        /// ``PlanningCommandKernel/reviewDelegationPrompt(scope:reviewers:changeSummary:approvedPlan:taskGraph:)``.
        case terminal
        /// ACP's `/review`: it never refuses for lack of changes; a plan
        /// whose text is blank is no approved plan; the focus is the
        /// argument ``CoordinatorCommandParser`` reads; and `prompt` builds
        /// the prompt (ACP's own, without a change summary).
        case acp(prompt: @Sendable (ChatReviewPromptRequest) -> String)
    }

    /// `/plan save`.
    enum PlanSave: Sendable {
        /// The terminal's candidate
        /// (``ChatSessionController/reusablePlanCandidate(createdAt:)``),
        /// saved by the selected agent.
        case terminal
        /// ACP's candidate: the active plan whatever its goal, otherwise the
        /// latest plan in the runtime session's history (`fallbackHistory`
        /// when the runtime has no session); a candidate without text is
        /// refused; `savingAgent` (the ACP session's agent) is recorded as
        /// the saver.
        case acp(savingAgent: AgentProfile?, fallbackHistory: [AgentRuntimeMessage])
    }

    /// `/plan load`.
    enum PlanLoad: Sendable {
        /// The terminal's load: the context message joins the controller's
        /// history, and the runtime session's history is replaced only when
        /// the runtime has the session.
        case terminal
        /// ACP's load: the runtime session's generation is read first
        /// (without one the command stops with
        /// ``ChatSessionNotice/runtimeSessionUnavailable``); the context
        /// message joins the runtime session's history (`fallbackHistory`
        /// when the runtime has no snapshot) at that generation; and a load
        /// superseded after the replacement puts the history back while the
        /// replacement is still installed.
        case acp(fallbackHistory: [AgentRuntimeMessage])
    }

    /// `/plan <goal>`, `/review`: `true` (the terminal) checks the
    /// sub-agents tool group of the selection. ACP checks its own tool grant
    /// (`agent.create` and `agent.wait`, plus `agent.message` for
    /// `/plan <goal>` and a Planner reply) before calling the operations,
    /// with its own message: the selection's tool groups mean nothing to an
    /// ACP session.
    var checksSubAgentToolGroup = true
    /// `/review`.
    var review: Review = .terminal
    /// `/plan save`.
    var planSave: PlanSave = .terminal
    /// `/plan load`.
    var planLoad: PlanLoad = .terminal
    /// `/plan delete`: ``Style/acp`` answers the usage
    /// (``ChatSessionNotice/planDeleteUsage``) before it reads the library;
    /// the terminal reports an empty library first.
    var planDelete: Style = .terminal
    /// `/plan status`: ``Style/acp`` leaves the active plan as it is (the
    /// terminal keeps the plan projected from the task graph as the active
    /// plan) and reports the missing plan
    /// (``ChatSessionNotice/noActivePlan``) even while a Planner discussion
    /// is open.
    var planStatus: Style = .terminal
    /// `/plan clear`: ``Style/acp`` reads the runtime session's generation
    /// once a plan is there (without one it stops with
    /// ``ChatSessionNotice/runtimeSessionUnavailable``), drops the Goal
    /// request only together with the plan (the terminal drops it first,
    /// with or without a plan), and puts the archived graph back when
    /// superseded, while that generation is current.
    var planClear: Style = .terminal
    /// The Goal of `/plan approve`: ``Style/acp`` keeps the request when the
    /// plan it was asked for is gone (answering
    /// ``ChatSessionNotice/noPendingPlanApproval``; the terminal drops it);
    /// refuses a plan whose text is blank; reads the runtime session's
    /// generation before anything changes (without one it stops with
    /// ``ChatSessionNotice/runtimeSessionUnavailable``); counts a graph
    /// creation that fails as a change to roll back; rolls back only while
    /// that generation is current; and makes the plan the approved active
    /// plan before it records the Goal in the saved-plan library, restoring
    /// the previous plan when that fails (the terminal records the Goal
    /// first).
    var approval: Style = .terminal
    /// The reply to a `/goal` workflow: ``Style/acp`` does not resume once
    /// its task is cancelled, and rolls a resume back only while the runtime
    /// session's generation read before it is current.
    var workflowReply: Style = .terminal

    /// The terminal's sequence for every command.
    static let terminal = ChatPlanningCommandPolicy()

    /// ACP's sequence for every command, with the session's agent and the
    /// history the client gave it (for `/plan save` and `/plan load` when
    /// the runtime has no snapshot), and ACP's `/review` prompt.
    static func acp(
        savingAgent: AgentProfile?,
        fallbackHistory: [AgentRuntimeMessage],
        reviewPrompt: @escaping @Sendable (ChatReviewPromptRequest) -> String
    ) -> ChatPlanningCommandPolicy {
        ChatPlanningCommandPolicy(
            checksSubAgentToolGroup: false,
            review: .acp(prompt: reviewPrompt),
            planSave: .acp(savingAgent: savingAgent, fallbackHistory: fallbackHistory),
            planLoad: .acp(fallbackHistory: fallbackHistory),
            planDelete: .acp,
            planStatus: .acp,
            planClear: .acp,
            approval: .acp,
            workflowReply: .acp
        )
    }
}
