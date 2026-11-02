//
//  TerminalChat+Review.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
import ToolCore

extension TerminalChat {
  /// `/review`, run by the shared controller (see
  /// ``ChatSessionController/runReviewCommand(line:)``).
  func handleReviewCommand(_ command: String) async -> TerminalSubmittedLineAction {
    await terminalAction(presenting: await chatSession.runReviewCommand(line: command))
  }

  var isSubAgentToolEnabled: Bool {
    chatSession.isSubAgentToolEnabled
  }

  /// Resolves the Reviewer profiles `/review` may delegate to: every profile
  /// with the reviewer role visible to the project. An empty result means
  /// the command must stop.
  func reviewerProfilesForDelegation() -> [AgentProfile] {
    chatSession.reviewerProfilesForDelegation()
  }

  nonisolated static func isReviewerProfile(_ agent: AgentProfile) -> Bool {
    AgentProfileStore.isReviewerAgent(agent)
  }

  nonisolated static func reviewDelegationPrompt(
    scope: String,
    reviewer: AgentProfile,
    changeSummary: TurnFileChangeSummary?,
    approvedPlan: TerminalSessionPlan? = nil,
    taskGraph: TaskGraphSnapshot? = nil
  ) -> String {
    PlanningCommandKernel.reviewDelegationPrompt(
      scope: scope,
      reviewer: reviewer,
      changeSummary: changeSummary,
      approvedPlan: approvedPlan,
      taskGraph: taskGraph
    )
  }

  /// With several Reviewer candidates the model may delegate to any of them.
  nonisolated static func reviewDelegationPrompt(
    scope: String,
    reviewers: [AgentProfile],
    changeSummary: TurnFileChangeSummary?,
    approvedPlan: TerminalSessionPlan? = nil,
    taskGraph: TaskGraphSnapshot? = nil
  ) -> String {
    PlanningCommandKernel.reviewDelegationPrompt(
      scope: scope,
      reviewers: reviewers,
      changeSummary: changeSummary,
      approvedPlan: approvedPlan,
      taskGraph: taskGraph
    )
  }

  /// Shared "After delegating" chat guidance for both review prompts.
  nonisolated static let reviewerChatWaitInstructions =
    PlanningCommandKernel.reviewerChatWaitInstructions

  nonisolated static func taskGraphReviewSection(_ graph: TaskGraphSnapshot) -> String {
    PlanningCommandKernel.taskGraphReviewSection(graph)
  }

  nonisolated static func reviewChangeSummarySection(_ summary: TurnFileChangeSummary) -> String {
    PlanningCommandKernel.reviewChangeSummarySection(summary)
  }
}
