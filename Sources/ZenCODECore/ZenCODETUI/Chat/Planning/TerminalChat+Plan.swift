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

    static let planAuthorAgentName = "plan-author"

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
            You are only the coordinator for this planning pass. Stay on your current agent \
            profile, but do not author, draft, consolidate, rewrite, or improve the plan \
            yourself. The Planner agent is the sole author of the final plan.

            \(goalSection)

            Planner authoring rules:
            - Create exactly one sub-agent with agent.create. Use name \
            "\(planAuthorAgentName)", role "Planner", profile "\(planner.id)", and isolationMode \
            "report" (read-only; it must not edit files or run mutating commands).
            - Restrict the Planner to this read-only planning toolset by passing \
            toolNames: [\(toolList)].
            - Give that Planner the complete requested goal and every relevant constraint \
            from the conversation. Explicitly tell it that it, not the current coordinator, \
            must inspect the workspace as needed and write the complete final plan.
            - Require the Planner's final response to include an ordered, numbered \
            "Implementation plan" whose items are directly actionable, plus likely \
            files/areas to touch, dependencies, risks, edge cases, open questions, and the \
            test/validation strategy.
            - Require the Planner to support this workflow loop: /plan <goal> -> /plan \
            approve (which automatically starts implementation) -> /review -> corrections \
            until the work is complete. It must not tell the user to send another \
            implementation prompt after approval.
            - Require the Planner's final response to follow the session response language \
            from the system prompt. It must not answer in English merely because this \
            internal coordination prompt is written in English.
            - Do not create supporting Planners or split authorship across multiple agents. \
            The single Planner must own the complete plan from investigation through final \
            wording.

            After delegating:
            - Wait for the Planner to finish with agent.wait.
            - If its output is failed, empty, or missing required planning detail, ask that \
            same Planner to correct it with agent.message and wait again. Never fill gaps or \
            produce a replacement plan yourself.
            - Before the final response, call todo.write once with mode "upsert" and one \
            item for every numbered implementation point authored by the Planner. Copy each \
            point's wording and order without reinterpretation. Use a fresh short token \
            shared by this plan and stable IDs "plan-<token>-1", "plan-<token>-2", and so \
            on. Keep every status "pending". Do not include risks, background notes, open \
            questions, or validation summaries as separate items.
            - Your final response must be exactly the Planner's latest output, verbatim. Do \
            not add an introduction or conclusion, summarize it, change its wording, reorder \
            it, or wrap it in a quotation or code block.
            - Do not edit any files yourself in this planning turn.
            """
    }

    static func plannerAuthoredPlanResponse(
        parentResponse: DirectAgentResponse,
        snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        excludingAgentIDs: Set<String> = []
    ) -> DirectAgentResponse? {
        let completedAuthors = snapshots.filter { snapshot in
            !excludingAgentIDs.contains(snapshot.id)
                && snapshot.name.caseInsensitiveCompare(planAuthorAgentName) == .orderedSame
                && snapshot.role.caseInsensitiveCompare(
                    AgentProfileStore.plannerAgentName
                ) == .orderedSame
                && isPlannerSnapshotProfile(snapshot)
                && snapshot.isolationMode == .report
                && snapshot.status == .idle
                && !snapshot.pending
                && snapshot.latestOutput?.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty == false
        }
        guard completedAuthors.count == 1,
              let author = completedAuthors.first,
              let text = author.latestOutput,
              text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            return nil
        }
        return DirectAgentResponse(
            text: text,
            stopReason: parentResponse.stopReason,
            modelID: author.modelID?.nilIfBlank ?? parentResponse.modelID
        )
    }

    static func isPlannerSnapshotProfile(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> Bool {
        snapshot.profileID?.caseInsensitiveCompare(
            AgentProfileStore.plannerAgentID.uuidString
        ) == .orderedSame
            || snapshot.profileName?.caseInsensitiveCompare(
                AgentProfileStore.plannerAgentName
            ) == .orderedSame
    }

    static func historyByReplacingPlanCoordinatorOutput(
        _ history: [AgentRuntimeMessage],
        with plannerOutput: String
    ) -> [AgentRuntimeMessage] {
        guard let turnStart = history.lastIndex(where: { $0.role == .user }) else {
            return history + [AgentRuntimeMessage(role: .assistant, content: plannerOutput)]
        }

        var correctedHistory = Array(history[...turnStart])
        correctedHistory.append(contentsOf: history[history.index(after: turnStart)...].filter {
            !($0.role == .assistant && $0.toolCalls.isEmpty)
        })
        correctedHistory.append(
            AgentRuntimeMessage(role: .assistant, content: plannerOutput)
        )
        return correctedHistory
    }
}

enum TerminalPlanGenerationError: LocalizedError {
    case plannerOutputUnavailable
    case sessionHistoryUnavailable

    var errorDescription: String? {
        switch self {
        case .plannerOutputUnavailable:
            return "The Planner agent did not produce a completed plan. The current agent "
                + "was not allowed to substitute its own plan; run /plan <goal> again."
        case .sessionHistoryUnavailable:
            return "The Planner produced a plan, but ZenCODE could not replace the current "
                + "agent's response in the session history. The plan was not recorded."
        }
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
