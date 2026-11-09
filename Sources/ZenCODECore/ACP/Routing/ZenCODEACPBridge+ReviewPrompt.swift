//
//  ZenCODEACPBridge+ReviewPrompt.swift
//  ZenCODE
//
//  The coordinator prompt ACP builds for /review.
//

import ToolCore

extension ZenCODEACPBridge {
    /// ACP's `/review` prompt.
    nonisolated static func acpReviewPrompt(
        scope: String,
        reviewers: [AgentProfile],
        approvedPlan: TerminalSessionPlan?,
        taskGraph: TaskGraphSnapshot?
    ) -> String {
        let focus = scope.nilIfBlank.map {
            "Review focus requested by the user: \($0)"
        } ?? "Review the current workspace changes for correctness and regressions."
        let planBlock = approvedPlan.map { plan in
            """
            Approved plan under verification:
            Original goal: \(plan.originalGoal)

            \(plan.consolidatedText)
            """
        } ?? "No approved plan is attached."
        let graphBlock = taskGraph.map { graph in
            let tasks = graph.tasks.sorted { lhs, rhs in
                lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
            }.map { task in
                "- task=\(task.id) status=\(task.status.rawValue) title=\(task.title)"
            }.joined(separator: "\n")
            return """
            Authoritative task graph snapshot (claims to verify, not proof):
            graph=\(graph.id) state=\(graph.state.rawValue) revision=\(graph.revision)
            \(tasks.isEmpty ? "- no tasks" : tasks)
            """
        } ?? "No task graph is attached; inspect the current workspace changes directly."
        let delegation: String
        if taskGraph?.state == .active {
            delegation = """
            First add one independent review task to the active graph with tasks.create, then call \
            tasks.list with runnableOnly=true and create exactly one Reviewer with agent.create, \
            putting that review task ID in the canonical agents item's taskID field.
            """
        } else {
            delegation = "Create exactly one taskless Reviewer with agent.create."
        }

        return """
        You are the coordinator for a read-only review requested through ACP. Delegate the actual \
        review and do not edit files yourself.

        \(focus)

        \(planBlock)

        \(graphBlock)

        Delegation rules:
        - \(delegation)
        - Use role "Reviewer" and \(AgentProfileStore.delegationProfileClause(reviewers)). The Reviewer must not edit files.
        - Ask it to inspect the relevant current files and validation evidence, not merely trust \
        task status, attempt output, or plan claims.
        - Require concrete findings ordered by severity with file:line references when available, \
        plus missing validation or coverage discrepancies.

        Wait for the Reviewer with agent.wait. Return a concise consolidated review in the session \
        response language. If there are no findings, say so explicitly. Do not make corrections in \
        this turn.
        """
    }
}
