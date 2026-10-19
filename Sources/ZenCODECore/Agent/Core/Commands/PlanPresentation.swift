// Stable plan status, saved-plan tables, and deletion messages.

import Foundation

extension PlanningCommandKernel {
    static func planDeleteNotFoundMessage(
        availablePlanIDs: [String]
    ) -> String {
        "ZenCODE: no saved plan matches. Available plans: "
            + availablePlanIDs.joined(separator: ", ")
            + ".\n"
    }

    static func planDeleteAmbiguousMessage(
        matches: [String]
    ) -> String {
        "ZenCODE: the plan id prefix is ambiguous: "
            + matches.joined(separator: ", ")
            + ". Provide more characters.\n"
    }

    static func planDeleteSuccessMessage(
        deletedPlanIDs: [String],
        activePlanAffected: Bool
    ) -> String {
        guard !deletedPlanIDs.isEmpty else {
            return "ZenCODE: no saved plans were deleted.\n"
        }
        var message: String
        if deletedPlanIDs.count == 1, let planID = deletedPlanIDs.first {
            message = "Deleted saved plan `\(planID)`.\n"
        } else {
            message = "Deleted \(deletedPlanIDs.count) saved plans.\n"
        }
        if activePlanAffected {
            message += "The active plan in this session is unaffected; use /plan clear to discard it.\n"
        }
        return message
    }

    static func savedPlansListMessage(
        for savedPlans: [SavedTaskPlan]
    ) -> String {
        var lines = [
            "## Saved plans",
            "",
            "**Total:** \(savedPlans.count)",
            "",
            "| Plan | Saved | Status | Items done | Goal |",
            "|---|---|---|---:|---|",
        ]
        for saved in savedPlans {
            let id = saved.graph.id
            let shortID = id.hasPrefix("plan-")
                ? String(id.prefix("plan-".count + 8))
                : String(id.prefix(12))
            let savedAt = saved.snapshot.savedAt.formatted(
                date: .abbreviated,
                time: .shortened
            )
            let completedCount = saved.graph.tasks
                .filter { $0.status == .completed }
                .count
            let goal = saved.snapshot.plan.originalGoal
                .replacingOccurrences(of: "\n", with: " ")
            let truncatedGoal = goal.count > 60
                ? String(goal.prefix(60)) + "…"
                : goal
            lines.append(
                "| `\(shortID)` | \(savedAt) | `\(saved.graph.state.rawValue)` "
                    + "| \(completedCount)/\(saved.graph.tasks.count) "
                    + "| \(escapedPlanTableCell(truncatedGoal)) |"
            )
        }
        lines.append("")
        lines.append(
            "Use /plan load to restore the newest draft, or /plan delete <plan|prefix|all> to remove saved plans."
        )
        return lines.joined(separator: "\n") + "\n"
    }

    static func planStatusTable(
        for plan: TerminalSessionPlan,
        graph: TaskGraphSnapshot?
    ) -> String {
        // Cancelled tasks affect an active graph, but not a standalone plan.
        let statusPriority: [TaskStatus] = [
            .failed, .blocked, .inProgress, .awaitingValidation, .cancelled,
        ]
        let overallStatus: String
        if let graph {
            switch graph.state {
            case .draft:
                overallStatus = "awaiting_approval"
            case .completed, .cancelled, .archived:
                overallStatus = graph.state.rawValue
            case .active:
                overallStatus = statusPriority.first { status in
                    graph.tasks.contains { $0.status == status }
                }?.rawValue ?? "active"
            }
        } else if plan.isCompleted {
            overallStatus = "completed"
        } else {
            overallStatus = statusPriority.dropLast().first { status in
                plan.points.contains { $0.status == planPointStatus(for: status) }
            }?.rawValue ?? (plan.isApproved ? "pending" : "awaiting_approval")
        }

        var lines = [
            "## Plan status",
            "",
            "**Goal:** \(plan.originalGoal)",
            "",
            "**Overall status:** `\(overallStatus)`",
            "",
            "| # | Plan item | Status |",
            "|---:|---|---|",
        ]
        if plan.points.isEmpty {
            lines.append("| 1 | Legacy plan without structured items | `not_tracked` |")
        } else {
            lines.append(contentsOf: plan.points.enumerated().map { index, point in
                "| \(index + 1) | \(escapedPlanTableCell(point.text)) | `\(point.status.rawValue)` |"
            })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func escapedPlanTableCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
