//
//  TerminalChat+Review.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation

extension TerminalChat {
  /// Read-only canonical tool names a Reviewer sub-agent may use, regardless of
  /// how the Reviewer profile is configured. Acts as a safety allowlist so the
  /// delegated reviewers can inspect only the session change surface and current
  /// files, but never mutate the workspace or broaden scope through git/memory.
  public static let reviewerReadOnlyToolNames: Set<String> = [
    "local.pwd",
    "local.ls",
    "local.readFile",
    "local.inspectFile",
    "search.glob",
    "search.grep",
    "search.locate",
    "text.head",
    "text.tail",
    "text.wc",
  ]

  func handleReviewCommand(_ command: String) -> TerminalSubmittedLineAction {
    let argument = String(command.dropFirst("/review".count))
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if !isOrchestrationToolEnabled {
      writeFailureMessage(
        """
        ZenCODE: /review requires the orchestration tool group. \
        Enable it with /tools (or switch to an agent that includes it) and try again.

        """
      )
      return .continueChat
    }

    guard let summary = lastFileChangeSummary else {
      writeSystemMessage("No tracked session file changes to review.\n")
      return .continueChat
    }

    let reviewerProfile = reviewerProfileForDelegation()

//    writeSystemMessage(
//      argument.isEmpty
//        ? "Starting review of session changes...\n"
//        : "Starting review of session changes with requested focus...\n"
//    )
      writeSubmittedPrompt("/review")

    return .runHiddenPrompt(
      Self.reviewDelegationPrompt(
        scope: argument,
        reviewer: reviewerProfile,
        changeSummary: summary
      )
    )
  }

  var isOrchestrationToolEnabled: Bool {
    selectedToolKeys.contains { key in
      key.caseInsensitiveCompare("orchestration") == .orderedSame
    }
  }

  /// Resolves the Reviewer profile used to configure the delegated sub-agents.
  /// Prefers a user-configured "Reviewer" profile from agents.json and falls
  /// back to the built-in default so the command works before any setup.
  func reviewerProfileForDelegation() -> AgentProfile {
    let configured = (try? availableAgents()) ?? []
    if let match = configured.first(where: Self.isReviewerProfile) {
      return match
    }
    if let fallback = AgentProfileStore.defaultProfiles().first(where: Self.isReviewerProfile) {
      return fallback
    }
    return AgentProfileStore.defaultProfiles()[0]
  }

  static func isReviewerProfile(_ agent: AgentProfile) -> Bool {
    agent.id.caseInsensitiveCompare(AgentProfileStore.reviewerAgentID.uuidString) == .orderedSame
      || agent.name.caseInsensitiveCompare(AgentProfileStore.reviewerAgentName) == .orderedSame
  }

  /// Canonical, read-only tool names a Reviewer sub-agent should receive: the
  /// profile's own tools intersected with the read-only safety allowlist.
  static func reviewerSubAgentToolNames(for reviewer: AgentProfile) -> [String] {
    let profileTools = reviewer.allowedToolNames()
    let allowed =
      profileTools.isEmpty
      ? reviewerReadOnlyToolNames
      : profileTools.intersection(reviewerReadOnlyToolNames)
    let resolved = allowed.isEmpty ? reviewerReadOnlyToolNames : allowed
    return resolved.sorted()
  }

  static func reviewDelegationPrompt(
    scope: String,
    reviewer: AgentProfile,
    changeSummary: TurnFileChangeSummary
  ) -> String {
        let toolList = reviewerSubAgentToolNames(for: reviewer)
      .map { "\"\($0)\"" }
      .joined(separator: ", ")

    let scopeSection: String
    if scope.isEmpty {
      scopeSection = """
        Review only the tracked file changes made during the current session. Do \
        not derive extra scope from unrelated workspace, history, or journal \
        context.
        """
    } else {
      scopeSection = """
        Review focus requested by the user: \(scope)
        Apply this focus only within the tracked file changes made during the \
        current session. Do not broaden the review to unrelated files, history, \
        journal context, or other workspace changes.
        """
    }

    let changeSummarySection = reviewChangeSummarySection(changeSummary)

    return """
      You are the director of this review. Stay on your current agent profile: do \
      not switch profiles. Delegate the actual review to Reviewer sub-agents via the \
      orchestration tools, then read their reviews and produce a correction plan.

      \(scopeSection)

      Session change surface:
      \(changeSummarySection)

      Delegation rules:
      - Create the sub-agents with agent.create using role "Reviewer" and \
      isolationMode "report" (read-only; they must not edit files).
      - Restrict each Reviewer to this read-only toolset by passing \
      toolNames: [\(toolList)].
      - When the review surface can be partitioned into independent areas (for \
      example distinct files, modules, or concerns), spawn multiple Reviewers in \
      parallel, one per area, in a single agent.create call so they run \
      concurrently. If the change is small or cannot be partitioned cleanly, a \
      single Reviewer is fine.
      - Give each Reviewer a focused prompt describing its assigned subset of the \
      session change surface above. Reviewers may inspect the listed current files \
      for context, but must base findings on the listed session changes only.
      - Ask Reviewers to report concrete findings: correctness bugs, regressions, \
      security/concurrency issues, missing tests, and style/convention violations, \
      each with file:line references and a severity.

      After delegating:
      - Wait for the Reviewers to finish with agent.wait.
      - Read and consolidate their reviews into a single prioritized summary grouped \
      by severity, removing duplicates.
      - If the findings warrant changes, compile a concrete correction plan: the \
      files or areas to change, the intended fix for each, and the suggested order. \
      Do not edit any files yourself in this turn; present the plan and let the user \
      decide whether to proceed.
      - The final review summary and correction plan must follow the session response \
      language from the system prompt. Do not answer in English just because this \
      internal review prompt is written in English.
      """
  }

  static func reviewChangeSummarySection(_ summary: TurnFileChangeSummary) -> String {
    var lines = [
      "Files: \(summary.fileCount)  +\(summary.totalAdditions) -\(summary.totalDeletions)"
    ]

    for entry in summary.entries {
      lines.append(
        "- \(entry.status.rawValue) \(entry.path)  +\(entry.additions) -\(entry.deletions)"
      )

      guard !entry.isBinary else {
        lines.append("  Binary file; inspect the current file only if useful for context.")
        continue
      }

      let patch = entry.patch?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .nilIfBlank
      if let patch {
        lines.append("  Patch:")
        lines.append("  ```diff")
        lines.append(patch.indentedForReviewChangeSummary())
        lines.append("  ```")
      } else {
        lines.append("  No text patch available; inspect this file only as needed for context.")
      }
    }

    return lines.joined(separator: "\n")
  }
}

private extension String {
  func indentedForReviewChangeSummary() -> String {
    split(separator: "\n", omittingEmptySubsequences: false)
      .map { "  " + String($0) }
      .joined(separator: "\n")
  }
}
