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

  func handleReviewCommand(_ command: String) async -> TerminalSubmittedLineAction {
    let argument = String(command.dropFirst("/review".count))
      .trimmingCharacters(in: .whitespacesAndNewlines)

    if !isSubAgentToolEnabled {
      await writeFailureMessage(
        """
        ZenCODE: /review requires the sub-agents tool group. \
        Enable it with /tools (or switch to an agent that includes it) and try again.

        """
      )
      return .continueChat
    }

    let approvedPlan = activePlan.flatMap {
      $0.isApproved && !$0.consolidatedText.isEmpty ? $0 : nil
    }
    let taskGraph = try? await sessionRunner.taskGraphSnapshot(
      sessionID: sessionID,
      graphID: approvedPlan?.id
    )
    guard lastFileChangeSummary != nil || approvedPlan != nil || taskGraph != nil else {
      await writeSystemMessage("No tracked session file changes to review.\n")
      return .continueChat
    }

    let reviewerProfile = reviewerProfileForDelegation()

//    await writeSystemMessage(
//      argument.isEmpty
//        ? "Starting review of session changes...\n"
//        : "Starting review of session changes with requested focus...\n"
//    )
      await writeSubmittedPrompt("/review")

    return .runHiddenPrompt(
      Self.reviewDelegationPrompt(
        scope: argument,
        reviewer: reviewerProfile,
        changeSummary: lastFileChangeSummary,
        approvedPlan: approvedPlan,
        taskGraph: taskGraph
      ),
      purpose: .review
    )
  }

  var isSubAgentToolEnabled: Bool {
    selectedToolKeys.contains { key in
      key.caseInsensitiveCompare("sub-agents") == .orderedSame
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
    changeSummary: TurnFileChangeSummary?,
    approvedPlan: TerminalSessionPlan? = nil,
    taskGraph: TaskGraphSnapshot? = nil
  ) -> String {
    let approvedPlan = approvedPlan.flatMap {
      $0.isApproved && !$0.consolidatedText.isEmpty ? $0 : nil
    }
    if approvedPlan == nil, taskGraph == nil, let changeSummary {
      return legacyReviewDelegationPrompt(
        scope: scope,
        reviewer: reviewer,
        changeSummary: changeSummary
      )
    }
    guard approvedPlan != nil || taskGraph != nil else {
      return ""
    }

    let taskGraphBlock = taskGraph.map { graph in
      """
        Authoritative task graph snapshot (claims to verify, not trusted proof):
        \(taskGraphReviewSection(graph))
        """
    } ?? "No task graph snapshot is available; classify plan coverage from files and mark unverifiable claims unverified."

    let toolList = reviewerSubAgentToolNames(for: reviewer)
      .map { "\"\($0)\"" }
      .joined(separator: ", ")

    let scopeSection: String
    if scope.isEmpty, approvedPlan != nil {
      scopeSection = """
        Verify the approved plan and task graph against the current state of the files they \
        implicate. When tracked session changes are also provided, review those changes for \
        code quality and correctness. Do not broaden scope to unrelated repository concerns.
        """
    } else if scope.isEmpty {
      scopeSection = """
        Verify the task graph against the current state of the files implicated by its tasks. \
        When tracked session changes are also provided, review those changes for code quality \
        and correctness. Do not broaden scope to unrelated repository concerns.
        """
    } else {
      let coverageScope = approvedPlan == nil ? "task graph" : "approved plan and task graph"
      scopeSection = """
        Review focus requested by the user: \(scope)
        Apply this focus only within the \(coverageScope) and any tracked session changes. \
        Do not broaden the review to unrelated files, history, journal context, or other \
        workspace concerns.
        """
    }

    let coverageTarget = approvedPlan == nil ? "task graph" : "approved plan and task graph"
    let changeSummaryBlock: String
    let codeReviewDelegationRules: String
    if let changeSummary {
      changeSummaryBlock = """
        Session change surface:
        \(reviewChangeSummarySection(changeSummary))
        """
      codeReviewDelegationRules = """
        - Create one or more separate code-quality/correctness Reviewers for the tracked \
        change surface. If a task graph is active, first add one independent review task per \
        Reviewer to that graph, including a single Reviewer, then call tasks.list with \
        runnableOnly=true and pass each taskID to agent.create. Without an active graph, do \
        this before using more than one Reviewer. Partition independent files or concerns when \
        useful; a single taskless code Reviewer is sufficient only for a small self-contained \
        change.
        - Code-quality Reviewers may inspect listed current files for context, but must \
        base findings on the listed session changes only. Ask them to report correctness \
        bugs, regressions, security/concurrency issues, missing tests, and convention \
        violations with file:line references and severity.
        """
    } else {
      changeSummaryBlock = """
        No tracked file-change summary is available. Perform coverage verification against the \
        current files implicated by the \(coverageTarget).
        """
      codeReviewDelegationRules = """
        - This is coverage-only mode. Do not assign a generic code-quality review, report \
        unrelated findings, or characterize current code as a new change or regression \
        without a tracked change summary.
        """
    }

    let approvedPlanBlock = approvedPlan.map { plan in
      """
        Approved plan under verification:
        Original goal: \(plan.originalGoal)

        \(plan.consolidatedText)
        """
    } ?? "No approved plan is attached; use the authoritative task graph as the coverage contract."

    return """
      You are the director of this review. Stay on your current agent profile: do \
      not switch profiles. Delegate the actual review to Reviewer sub-agents via the \
      sub-agent tools, then read their reviews and produce a correction plan.

      \(scopeSection)

      \(changeSummaryBlock)

      \(approvedPlanBlock)

      \(taskGraphBlock)

      Critical evidence rule:
      - A task marked completed is an assertion to verify, not proof that the code is correct.
      - Attempt output and recorded evidence are leads only; verify them against current files \
      and, where available, real validation results.
      - A task in awaiting_validation is not completed and must never be reported as validated.

      Delegation rules:
      - Create the sub-agents with agent.create using role "Reviewer" and \
      isolationMode "report" (read-only; they must not edit files).
      - Restrict each Reviewer to this read-only toolset by passing \
      toolNames: [\(toolList)].
      - If a task graph is active, append one independent review task per Reviewer to that \
      graph, including a single Reviewer; call tasks.list with runnableOnly=true and pass each \
      runnable taskID to agent.create. Without an active graph, define that workflow before \
      using multiple Reviewers. If a taskless Reviewer is already active, wait for it to finish \
      and close it before activating a graph; it cannot be retroactively bound to a task.
      - Create at least one dedicated Reviewer for plan coverage or task-graph coverage.
      - The coverage Reviewer must verify the current state of the files implicated by the plan \
      or task graph, not merely the latest diff. It may inspect files needed to verify tasks and \
      plan items, but must not perform a generic review of the whole repository.
      - Require the plan-coverage Reviewer to classify every task as exactly one of: \
      implemented, validated, unverified, failed, deviated, cancelled, or blocked. \
      "Validated" requires independent evidence in current files or actual validation output; \
      use "implemented" when code exists but validation is absent, and "unverified" when a \
      completion claim cannot be established. Use deviated when implementation differs from \
      the plan and explain whether the deviation is acceptable.
      \(codeReviewDelegationRules)

      After delegating:
      - Wait for the Reviewers to finish with agent.wait.
      - Read and consolidate their reviews into a single prioritized summary grouped \
      by severity, removing duplicates.
      - Include a distinct task/plan coverage report with one classification per task, concrete \
      file:line references whenever available, and explicit discrepancies between the plan, \
      task status, attempts, evidence, and real files.
      - If the findings warrant changes, compile a concrete correction plan: the \
      files or areas to change, the intended fix for each, and the suggested order. \
      Do not edit any files yourself in this turn; present the plan and let the user \
      decide whether to proceed.
      - The final review summary and correction plan must follow the session response \
      language from the system prompt. Do not answer in English just because this \
      internal review prompt is written in English.
      """
  }

  static func taskGraphReviewSection(_ graph: TaskGraphSnapshot) -> String {
    var lines = [
      "graph=\(graph.id) state=\(graph.state.rawValue) revision=\(graph.revision)",
    ]
    for task in graph.tasks.sorted(by: { lhs, rhs in
      if lhs.order != rhs.order { return lhs.order < rhs.order }
      return lhs.id < rhs.id
    }) {
      let dependencies = task.dependsOn.isEmpty
        ? "none"
        : task.dependsOn.joined(separator: ",")
      lines.append(
        "- task=\(task.id) status=\(task.status.rawValue) revision=\(task.revision) depends_on=\(dependencies) title=\(reviewInline(task.title))"
      )
      if !task.acceptanceCriteria.isEmpty {
        lines.append("  acceptance criteria:")
        lines.append(contentsOf: task.acceptanceCriteria.map { "  - \(reviewInline($0))" })
      }
      for attempt in task.attempts {
        var attemptLine = "  attempt #\(attempt.ordinal) id=\(attempt.id) status=\(attempt.status.rawValue) executor=\(attempt.executor.rawValue)"
        if let agentID = attempt.agentID { attemptLine += " agent=\(agentID)" }
        lines.append(attemptLine)
        if let output = attempt.output?.nilIfBlank {
          lines.append("    output: \(reviewInline(String(output.prefix(2_000))))")
        }
        if let error = attempt.error?.nilIfBlank {
          lines.append("    error: \(reviewInline(String(error.prefix(2_000))))")
        }
      }
      if let result = task.result {
        if let output = result.output?.nilIfBlank,
           output != task.attempts.last?.output {
          lines.append("  result_output: \(reviewInline(String(output.prefix(2_000))))")
        }
        if let error = result.error?.nilIfBlank,
           error != task.attempts.last?.error {
          lines.append("  result_error: \(reviewInline(String(error.prefix(2_000))))")
        }
        if let validatedAt = result.validatedAt {
          lines.append("  validated_at: \(validatedAt.ISO8601Format())")
        }
        for evidence in result.evidence {
          let location = evidence.location.map { " location=\($0)" } ?? ""
          lines.append("  evidence kind=\(evidence.kind)\(location): \(reviewInline(evidence.summary))")
        }
      }
      if let reason = task.statusReason?.nilIfBlank {
        lines.append("  status_reason: \(reviewInline(reason))")
      }
    }
    return lines.joined(separator: "\n")
  }

  private static func reviewInline(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: " ")
      .replacingOccurrences(of: "\n", with: " ")
      .replacingOccurrences(of: "\r", with: " ")
  }

  private static func legacyReviewDelegationPrompt(
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

    return """
      You are the director of this review. Stay on your current agent profile: do \
      not switch profiles. Delegate the actual review to Reviewer sub-agents via the \
      sub-agent tools, then read their reviews and produce a correction plan.

      \(scopeSection)

      Session change surface:
      \(reviewChangeSummarySection(changeSummary))

      Delegation rules:
      - Create the sub-agents with agent.create using role "Reviewer" and \
      isolationMode "report" (read-only; they must not edit files).
      - Restrict each Reviewer to this read-only toolset by passing \
      toolNames: [\(toolList)].
      - When the review surface can be partitioned into independent areas (for \
      example distinct files, modules, or concerns), first call tasks.create once \
      with one independent review task per area, then call tasks.list with \
      runnableOnly=true and spawn multiple Reviewers with the corresponding taskID \
      values in a single agent.create call. If a task graph is already active, add a \
      task and use taskID even for a single Reviewer. If a taskless Reviewer is already \
      active, wait for it to finish and close it before activating a graph. If the change \
      is small or cannot be partitioned cleanly, a single self-contained Reviewer is fine.
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
