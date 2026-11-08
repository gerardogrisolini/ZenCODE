//
//  ChatSessionController+ReviewCommand.swift
//  ZenCODE
//
//  `/review`: the review delegated to Reviewer sub-agents.
//

import Foundation
import ToolCore

extension ChatSessionController {
    // MARK: - /review

    /// `/review [scope]`: delegates a review of the tracked file changes, the
    /// approved plan, and the task graph to Reviewer sub-agents.
    func runReviewCommand(
        line: String,
        fence: ChatCommandFence? = nil,
        policy: ChatPlanningCommandPolicy = .terminal
    ) async -> ChatCommandOutcome {
        let argument = ChatCommandRegistry.arguments(
            from: line,
            commandPrefix: "/review"
        )

        if policy.checksSubAgentToolGroup {
            guard isSubAgentToolEnabled else {
                return ChatCommandOutcome(notices: [.subAgentToolsRequired(command: "/review")])
            }
        }

        switch policy.review {
        case .terminal:
            let approvedPlan = activePlan.flatMap {
                $0.isApproved && !$0.consolidatedText.isEmpty ? $0 : nil
            }
            let taskGraph = try? await runtime.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: approvedPlan?.id
            )
            guard lastFileChangeSummary != nil || approvedPlan != nil || taskGraph != nil else {
                return ChatCommandOutcome(notices: [.noChangesToReview])
            }

            let reviewerProfiles = reviewerProfilesForDelegation()
            guard !reviewerProfiles.isEmpty else {
                return ChatCommandOutcome(notices: [.agentRoleUnavailable(.reviewer)])
            }

            await effectivePresenter(for: nil).presentSubmittedCommand(line)

            return Self.commandTurn(
                PlanningCommandKernel.reviewDelegationPrompt(
                    scope: argument,
                    reviewers: reviewerProfiles,
                    changeSummary: lastFileChangeSummary,
                    approvedPlan: approvedPlan,
                    taskGraph: taskGraph
                ),
                purpose: .review
            )
        case let .acp(prompt):
            let reviewerProfiles = reviewerProfilesForDelegation()
            guard !reviewerProfiles.isEmpty else {
                return ChatCommandOutcome(notices: [.agentRoleUnavailable(.reviewer)])
            }
            let approvedPlan = activePlan.flatMap {
                $0.isApproved && $0.consolidatedText.nilIfBlank != nil ? $0 : nil
            }
            let taskGraph = try? await runtime.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: approvedPlan?.id
            )
            let scope: String
            if case let .review(parsedScope) = CoordinatorCommandParser.parse(line) {
                scope = parsedScope
            } else {
                scope = argument
            }
            await effectivePresenter(for: nil).presentSubmittedCommand(line)
            return Self.commandTurn(
                prompt(
                    ChatReviewPromptRequest(
                        scope: scope,
                        reviewers: reviewerProfiles,
                        approvedPlan: approvedPlan,
                        taskGraph: taskGraph
                    )
                ),
                purpose: .review
            )
        }
    }
}
