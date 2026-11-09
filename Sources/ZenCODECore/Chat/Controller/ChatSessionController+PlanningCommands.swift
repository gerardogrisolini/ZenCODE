//
//  ChatSessionController+PlanningCommands.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// The planning commands shared by every channel: `/plan` (start, the saved
/// plan library, status, approval, clear), `/goal`, `/review`, and the plain
/// replies the commands wait for (the Goal of `/plan approve`, the answer to
/// a Planner question, the answer to a `/goal` workflow question).
///
/// The commands live in `ChatSessionController+PlanLifecycle.swift` (`/plan`),
/// `+PlanLibrary.swift` (the saved plans), `+GoalCommands.swift` (`/goal`) and
/// `+ReviewCommand.swift` (`/review`). This file keeps what they share: the
/// gates, `commandTurn` and `superseded`, and the routing of a plain line to the
/// reply a command waits for.
///
/// Each command returns a ``ChatCommandOutcome`` with its closing notices and
/// the turn it starts, if any. The echo of the submitted line goes to the
/// presenter (``ChatSessionPresenter/presentSubmittedCommand(_:)``) at the
/// point the terminal wrote it, so a refusal raised before that point is not
/// echoed. Every turn a command starts is a prompt the command built:
/// `locksResponseLanguage` is `false`. The approval of a plan asks the
/// channel to lock its response language through
/// ``ChatSessionChannelHooks/responseLanguageShouldLock()`` instead.
///
/// A channel that routes from another actor passes a ``ChatCommandFence``:
/// every write of the command state is checked against it under the
/// controller's lock, and a command it supersedes writes nothing more, undoes
/// the runtime changes it made, and returns an empty outcome. The
/// ``ChatPlanningCommandPolicy`` selects, command by command, the terminal's
/// sequence or ACP's.
extension ChatSessionController {
    // MARK: - Gates

    /// `true` while the sub-agents tool group is selected, which `/plan` and
    /// `/review` need to delegate.
    var isSubAgentToolEnabled: Bool {
        selection.toolKeys.contains { key in
            key.caseInsensitiveCompare("sub-agents") == .orderedSame
        }
    }

    /// Resolves the Planner profiles `/plan` may delegate to: every profile
    /// with the planner role visible to the project. An empty result means
    /// the command must stop.
    func plannerProfilesForDelegation() -> [AgentProfile] {
        AgentProfileStore.roleDelegationCandidates(
            .planner,
            in: (try? availableAgents()) ?? [],
            workspaceRootURL: workingDirectory
        )
    }

    /// Resolves the Reviewer profiles `/review` may delegate to: every
    /// profile with the reviewer role visible to the project. An empty result
    /// means the command must stop.
    func reviewerProfilesForDelegation() -> [AgentProfile] {
        AgentProfileStore.roleDelegationCandidates(
            .reviewer,
            in: (try? availableAgents()) ?? [],
            workspaceRootURL: workingDirectory
        )
    }

    /// The management runtime the planning and `/tasks` mutations need.
    func requiredManagementRuntime() throws -> any ChatSessionManagementRuntime {
        guard let managementRuntime else {
            throw ChatPlanningCommandError.sessionOperationsUnavailable
        }
        return managementRuntime
    }

    /// A turn of `purpose` with the prompt a command built.
    static func commandTurn(
        _ prompt: String,
        purpose: ChatTurnPurpose
    ) -> ChatCommandOutcome {
        ChatCommandOutcome(
            action: .startTurn(prompt: prompt, purpose: purpose, locksResponseLanguage: false)
        )
    }

    /// The outcome of a command its fence superseded: nothing to present.
    /// The channel sees the fence fail and ends the request as cancelled.
    static var superseded: ChatCommandOutcome {
        ChatCommandOutcome()
    }

    // MARK: - Pending replies

    /// Routes a plain line to the conversation that is explicitly waiting for
    /// the operator, as the terminal does: the Goal for `/plan approve`, then
    /// an open Planner question, then a `/goal` workflow awaiting the user.
    /// `nil` when nothing is waiting, so the line is an ordinary prompt.
    ///
    /// The channel routes slash commands and live mentions before calling it:
    /// neither is ever absorbed as a reply.
    public func pendingReplyAction(for reply: String) async -> ChatCommandOutcome? {
        await pendingReplyAction(for: reply, fence: nil, policy: .terminal)
    }

    /// Routes a plain line to the conversation that is explicitly waiting for
    /// the operator, in this order: the Goal for `/plan approve`, then an open
    /// Planner question, then a `/goal` workflow awaiting the user. `nil` when
    /// nothing is waiting, so the line is an ordinary prompt.
    ///
    /// The channel routes slash commands and live mentions before calling it:
    /// neither is ever absorbed as a reply.
    func pendingReplyAction(
        for reply: String,
        fence: ChatCommandFence? = nil,
        policy: ChatPlanningCommandPolicy = .terminal
    ) async -> ChatCommandOutcome? {
        if let outcome = await planApprovalGoalReplyAction(for: reply, fence: fence, policy: policy) {
            return outcome
        }
        if let outcome = await planBrainstormingReplyAction(for: reply, fence: fence) {
            return outcome
        }
        return await workflowContinuationReplyAction(for: reply, fence: fence, policy: policy)
    }
}
