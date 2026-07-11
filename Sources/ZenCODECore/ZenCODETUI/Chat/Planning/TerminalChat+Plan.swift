//
//  TerminalChat+Plan.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/07/26.
//

import Foundation

extension TerminalChat {
    /// Read-only canonical tool names a Planner sub-agent may use while preparing
    /// an implementation plan. Planners can inspect the workspace, project
    /// context, memory, web references, and non-mutating Git state, but must not
    /// edit files, run shell commands, or perform mutating Git/memory/task work.
    public static let plannerReadOnlyToolNames: Set<String> = [
        "local.pwd",
        "local.ls",
        "local.readFile",
        "local.readFiles",
        "local.inspectFile",
        "search.glob",
        "search.grep",
        "search.locate",
        "text.head",
        "text.tail",
        "text.sort",
        "text.wc",
        "git.status",
        "git.diff",
        "git.show",
        "git.log",
        "git.branch",
        "git.remote",
        "git.lsFiles",
        "git.grep",
        "git.blame",
        "memory.read",
        "memory.search",
        "todo.read",
        "task.list",
        "task.get",
        "web.search",
        "web.fetch",
    ]

    func handlePlanCommand(_ command: String) -> TerminalSubmittedLineAction {
        let argument = String(command.dropFirst("/plan".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch argument.lowercased() {
        case "status":
            writeSubmittedPrompt(command)
            guard let activePlan else {
                writeSystemMessage("No active plan.\n")
                return .continueChat
            }
            writeMarkdownMessage(Self.planStatusTable(for: activePlan))
            return .continueChat
        case "approve":
            writeSubmittedPrompt(command)
            guard var plan = activePlan,
                  !plan.consolidatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                writeFailureMessage(Self.planUnavailableForApprovalMessage)
                return .continueChat
            }
            plan.isApproved = true
            activePlan = plan
            writeSystemMessage(
                "Approved the active plan. Starting implementation now; /review will use it for coverage verification.\n"
            )
            return .runHiddenPrompt(
                Self.planImplementationPrompt(for: plan),
                purpose: .normal
            )
        case "clear":
            writeSubmittedPrompt(command)
            guard activePlan != nil else {
                writeSystemMessage("No active plan to clear.\n")
                return .continueChat
            }
            activePlan = nil
            writeSystemMessage("Cleared the active plan.\n")
            return .continueChat
        default:
            break
        }

        guard !argument.isEmpty else {
            writeFailureMessage(Self.planMissingGoalMessage)
            return .continueChat
        }

        if !isSubAgentToolEnabled {
            writeFailureMessage(
                """
                ZenCODE: /plan requires the sub-agents tool group. \
                Enable it with /tools (or switch to an agent that includes it) and try again.

                """
            )
            return .continueChat
        }

        let plannerProfile = plannerProfileForDelegation()

//        writeSystemMessage(
//            "Starting planning pass for requested goal via Planner sub-agents...\n"
//        )

        writeSubmittedPrompt(command)

        return .runHiddenPrompt(
            Self.planDelegationPrompt(
                goal: argument,
                planner: plannerProfile
            ),
            purpose: .plan(originalGoal: argument)
        )
    }

    static let planMissingGoalMessage =
        "ZenCODE: /plan requires a goal. "
        + "Use /plan <goal> to describe what should be planned.\n"

    static let planUnavailableForApprovalMessage =
        "ZenCODE: no completed plan is available to approve. "
        + "Run /plan <goal> and wait for it to finish successfully.\n"

    static func planImplementationPrompt(for plan: TerminalSessionPlan) -> String {
        """
        Implement the active approved plan now. Work through its points in order, keep their \
        todo statuses synchronized, validate the changes, and stop when implementation is \
        complete or a real blocker is reached. Do not create another plan and do not wait for \
        an additional user prompt before starting.

        Goal: \(plan.originalGoal)

        Approved plan:
        \(plan.consolidatedText)
        """
    }

    static func planStatusTable(for plan: TerminalSessionPlan) -> String {
        let overallStatus: String
        if plan.isCompleted {
            overallStatus = "completed"
        } else if plan.points.contains(where: { $0.status == .blocked }) {
            overallStatus = "blocked"
        } else if plan.points.contains(where: { $0.status == .inProgress }) {
            overallStatus = "in_progress"
        } else if plan.isApproved {
            overallStatus = "pending"
        } else {
            overallStatus = "awaiting_approval"
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

    static func planPointUpdates(
        from toolCall: DirectAgentToolCall
    ) -> (points: [TerminalSessionPlanPoint], mode: DirectTodoTaskRuntime.TodoWriteMode)? {
        let request = DirectTodoTaskRuntime.normalizedToolRequest(for: toolCall)
        guard request.name == "todo.write",
              let todos = try? DirectTodoTaskRuntime.requestedTodos(from: request.arguments) else {
            return nil
        }
        let points = todos.compactMap { todo -> TerminalSessionPlanPoint? in
            let id = todo.id.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = todo.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard id.hasPrefix("plan-"), !text.isEmpty else {
                return nil
            }
            let status: TerminalSessionPlanPointStatus
            switch todo.status {
            case .pending:
                status = .pending
            case .inProgress:
                status = .inProgress
            case .completed:
                status = .completed
            case .blocked:
                status = .blocked
            }
            return TerminalSessionPlanPoint(id: id, text: text, status: status)
        }
        guard !points.isEmpty else {
            return nil
        }
        return (
            points,
            DirectTodoTaskRuntime.TodoWriteMode(
                rawValue: DirectTodoTaskRuntime.firstString(["mode"], in: request.arguments)
            )
        )
    }

    @discardableResult
    func synchronizeActivePlanStatus(
        from toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> Bool {
        guard !result.isFailure,
              var plan = activePlan,
              plan.isApproved,
              !plan.points.isEmpty,
              let update = Self.planPointUpdates(from: toolCall) else {
            return false
        }
        let wasCompleted = plan.isCompleted
        let updatesByID = Dictionary(
            update.points.map { ($0.id, $0.status) },
            uniquingKeysWith: { _, latest in latest }
        )
        var didChange = false
        for index in plan.points.indices {
            guard let status = updatesByID[plan.points[index].id],
                  plan.points[index].status != status else {
                continue
            }
            plan.points[index].status = status
            didChange = true
        }
        guard didChange else {
            return false
        }
        activePlan = plan
        return !wasCompleted && plan.isCompleted
    }

    private static func escapedPlanTableCell(_ text: String) -> String {
        text
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Resolves the Planner profile used to configure delegated sub-agents.
    /// Prefers a user-configured "Planner" profile from agents.json and falls
    /// back to the built-in default so the command works before any setup.
    func plannerProfileForDelegation() -> AgentProfile {
        let configured = (try? availableAgents()) ?? []
        if let match = configured.first(where: Self.isPlannerProfile) {
            return match
        }
        if let fallback = AgentProfileStore.defaultProfiles().first(where: Self.isPlannerProfile) {
            return fallback
        }
        return AgentProfileStore.defaultProfiles()[0]
    }

    static func isPlannerProfile(_ agent: AgentProfile) -> Bool {
        agent.id.caseInsensitiveCompare(AgentProfileStore.plannerAgentID.uuidString) == .orderedSame
            || agent.name.caseInsensitiveCompare(AgentProfileStore.plannerAgentName) == .orderedSame
    }

    /// Canonical, read-only tool names a Planner sub-agent should receive: the
    /// profile's own tools intersected with the read-only planning allowlist.
    static func plannerSubAgentToolNames(for planner: AgentProfile) -> [String] {
        let profileTools = planner.allowedToolNames()
        let allowed =
            profileTools.isEmpty
            ? plannerReadOnlyToolNames
            : profileTools.intersection(plannerReadOnlyToolNames)
        let resolved = allowed.isEmpty ? plannerReadOnlyToolNames : allowed
        return resolved.sorted()
    }

    static func planDelegationPrompt(
        goal: String,
        planner: AgentProfile
    ) -> String {
        let toolList = plannerSubAgentToolNames(for: planner)
            .map { "\"\($0)\"" }
            .joined(separator: ", ")

        let goalSection = """
            Planning goal requested by the user: \(goal)
            Plan only this requested activity unless the conversation clearly provides \
            required constraints.
            """

        return """
            You are the director of this planning pass. Stay on your current agent profile: \
            do not switch profiles. Delegate the actual planning to Planner sub-agents via \
            sub-agent tools, then read their plans and produce one consolidated \
            implementation plan.

            \(goalSection)

            Delegation rules:
            - Create at least one sub-agent with agent.create using role "Planner" and \
            isolationMode "report" (read-only; it must not edit files or run mutating \
            commands).
            - Restrict each Planner to this read-only planning toolset by passing \
            toolNames: [\(toolList)].
            - When the activity can be partitioned into independent planning areas (for \
            example files/modules to inspect, requirements, tests, risks, migration steps, \
            or docs), spawn multiple Planners in parallel in a single agent.create call. \
            If the activity is small or cannot be partitioned cleanly, a single Planner is \
            fine.
            - Give each Planner a focused prompt describing its assigned planning subset. \
            Ask Planners to inspect only what is needed to make the plan concrete.
            - Ask Planners to report: likely files/areas to touch, implementation phases, \
            dependencies, risks, edge cases, test/validation strategy, open questions, and \
            a recommended order of work.

            After delegating:
            - Wait for the Planners to finish with agent.wait.
            - Read and consolidate their plans into one actionable plan, removing \
            duplicates and resolving conflicts.
            - Before the final response, call todo.write once with mode "upsert" and one \
            item for every actionable implementation point in the consolidated plan. Use \
            a fresh short token shared by this plan and stable IDs "plan-<token>-1", \
            "plan-<token>-2", and so on. Preserve execution order, keep each content field \
            concise, and set every status to "pending". Do not include risks, \
            background notes, open questions, or validation summaries as separate items.
            - The final plan must support this workflow loop: /plan <goal> -> /plan approve \
            (which automatically starts implementation) -> /review -> corrections until the \
            work is complete. Do not tell the user to send another implementation prompt \
            after approval.
            - Do not edit any files yourself in this planning turn. Present the plan, the \
            expected validation, and where /review should be run after implementation.
            - The final planning summary must follow the session response language from \
            the system prompt. Do not answer in English just because this internal planning \
            prompt is written in English.
            """
    }
}

actor TerminalPlanPointCollector {
    private var points: [TerminalSessionPlanPoint] = []
    private var completedPlan: TerminalSessionPlan?

    func apply(
        _ updates: [TerminalSessionPlanPoint],
        mode: DirectTodoTaskRuntime.TodoWriteMode
    ) {
        switch mode {
        case .replace:
            points = updates
        case .append:
            points.append(contentsOf: updates)
        case .upsert:
            var pointsByID = Dictionary(
                points.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            for point in updates {
                pointsByID[point.id] = point
            }
            points = DirectTodoTaskRuntime.orderedValues(
                from: pointsByID,
                preserving: points.map(\.id) + updates.map(\.id)
            )
        }
    }

    func snapshot() -> [TerminalSessionPlanPoint] {
        points
    }

    func recordAutomaticCompletion(_ plan: TerminalSessionPlan) {
        completedPlan = plan
    }

    func automaticallyCompletedPlan() -> TerminalSessionPlan? {
        completedPlan
    }
}
