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

    func handlePlanCommand(_ command: String) async -> TerminalSubmittedLineAction {
        let argument = String(command.dropFirst("/plan".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch argument.lowercased() {
        case "status":
            writeSubmittedPrompt(command)
            guard let activePlan else {
                writeSystemMessage("No active plan.\n")
                return .continueChat
            }
            let graph = try? await sessionRunner.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: activePlan.id
            )
            let projectedPlan = graph.map {
                Self.plan(activePlan, applying: $0)
            } ?? activePlan
            self.activePlan = projectedPlan
            writeMarkdownMessage(Self.planStatusTable(for: projectedPlan, graph: graph))
            return .continueChat
        case "approve":
            writeSubmittedPrompt(command)
            guard var plan = activePlan,
                  !plan.consolidatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                writeFailureMessage(Self.planUnavailableForApprovalMessage)
                return .continueChat
            }
            do {
                if try await sessionRunner.taskGraphSnapshot(
                    sessionID: sessionID,
                    graphID: plan.id
                ) == nil,
                   !plan.points.isEmpty {
                    _ = try await sessionRunner.taskOrchestrator.createGraph(
                        sessionID: sessionID,
                        id: plan.id,
                        source: .plan(planID: plan.id),
                        state: .draft,
                        tasks: Self.taskDefinitions(for: plan.points),
                        makeCurrent: true,
                        archivePreviousCurrent: true
                    )
                }
                if try await sessionRunner.taskGraphSnapshot(
                    sessionID: sessionID,
                    graphID: plan.id
                ) != nil {
                    _ = try await sessionRunner.activateTaskGraph(
                        id: plan.id,
                        sessionID: sessionID
                    )
                }
            } catch {
                writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
                return .continueChat
            }
            plan.isApproved = true
            activePlan = plan
            writeSystemMessage(
                "Approved the active plan and activated its task graph. Starting implementation now; /review will verify task claims against real files.\n"
            )
            return .runHiddenPrompt(
                Self.planImplementationPrompt(for: plan),
                purpose: .normal
            )
        case "clear":
            writeSubmittedPrompt(command)
            guard let plan = activePlan else {
                writeSystemMessage("No active plan to clear.\n")
                return .continueChat
            }
            do {
                if try await sessionRunner.taskGraphSnapshot(
                    sessionID: sessionID,
                    graphID: plan.id
                ) != nil {
                    _ = try await sessionRunner.archiveTaskGraph(
                        id: plan.id,
                        sessionID: sessionID
                    )
                }
            } catch {
                writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
                return .continueChat
            }
            activePlan = nil
            writeSystemMessage("Cleared the active plan and archived its task graph.\n")
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
        guard !plan.points.isEmpty else {
            return """
            Implement the active approved legacy plan now. Work through its written steps in \
            order, validate the changes, and stop when implementation is complete or a real \
            blocker is reached. This saved plan has no structured task graph, so do not invent \
            task IDs or replace the plan.

            Goal: \(plan.originalGoal)

            Approved plan:
            \(plan.consolidatedText)
            """
        }
        return """
        Implement the active approved plan now, using the session task graph as the control \
        plane. Start by calling task.list with runnableOnly=true. Execute small tasks directly, \
        delegate independent read-only/report tasks in one agent.create batch using each taskID, \
        and run at most one isolationMode=implementation sub-agent at a time because all \
        implementation agents share the working directory. Before direct work, transition that \
        task to in_progress with task.update; after implementation record output and either \
        complete report work or move implementation work to awaiting_validation. Validate \
        implementation tasks independently before marking them completed. Repeat until the \
        graph is completed or a real blocker is recorded. Respect dependencies, never claim a \
        task twice, use task.retry only explicitly, and do not recreate or replace the approved \
        plan.

        Goal: \(plan.originalGoal)

        Approved plan:
        \(plan.consolidatedText)
        """
    }

    static func planStatusTable(for plan: TerminalSessionPlan) -> String {
        planStatusTable(for: plan, graph: nil)
    }

    static func planStatusTable(
        for plan: TerminalSessionPlan,
        graph: TaskGraphSnapshot?
    ) -> String {
        let overallStatus: String
        if let graph {
            switch graph.state {
            case .draft:
                overallStatus = "awaiting_approval"
            case .completed, .cancelled, .archived:
                overallStatus = graph.state.rawValue
            case .active:
                if graph.tasks.contains(where: { $0.status == .failed }) {
                    overallStatus = "failed"
                } else if graph.tasks.contains(where: { $0.status == .blocked }) {
                    overallStatus = "blocked"
                } else if graph.tasks.contains(where: { $0.status == .inProgress }) {
                    overallStatus = "in_progress"
                } else if graph.tasks.contains(where: { $0.status == .awaitingValidation }) {
                    overallStatus = "awaiting_validation"
                } else if graph.tasks.contains(where: { $0.status == .cancelled }) {
                    overallStatus = "cancelled"
                } else {
                    overallStatus = "active"
                }
            }
        } else if plan.isCompleted {
            overallStatus = "completed"
        } else if plan.points.contains(where: { $0.status == .failed }) {
            overallStatus = "failed"
        } else if plan.points.contains(where: { $0.status == .blocked }) {
            overallStatus = "blocked"
        } else if plan.points.contains(where: { $0.status == .inProgress }) {
            overallStatus = "in_progress"
        } else if plan.points.contains(where: { $0.status == .awaitingValidation }) {
            overallStatus = "awaiting_validation"
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

    static func plan(
        _ plan: TerminalSessionPlan,
        applying graph: TaskGraphSnapshot
    ) -> TerminalSessionPlan {
        var projected = plan
        let tasksByID = Dictionary(uniqueKeysWithValues: graph.tasks.map { ($0.id, $0) })
        for index in projected.points.indices {
            guard let task = tasksByID[projected.points[index].id] else { continue }
            projected.points[index].status = planPointStatus(for: task.status)
            projected.points[index].dependsOn = task.dependsOn
        }
        return projected
    }

    static func planPointStatus(for status: TaskStatus) -> TerminalSessionPlanPointStatus {
        switch status {
        case .pending: .pending
        case .inProgress: .inProgress
        case .awaitingValidation: .awaitingValidation
        case .completed: .completed
        case .blocked: .blocked
        case .failed: .failed
        case .cancelled: .cancelled
        }
    }

    static func taskDefinitions(
        for points: [TerminalSessionPlanPoint]
    ) -> [TaskDefinition] {
        points.enumerated().map { index, point in
            let dependencies: [String]
            if point.hasExplicitDependencies {
                dependencies = point.dependsOn
            } else if index > 0 {
                dependencies = [points[index - 1].id]
            } else {
                dependencies = []
            }
            return TaskDefinition(
                id: point.id,
                title: point.text,
                order: index + 1,
                dependsOn: dependencies
            )
        }
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
            return TerminalSessionPlanPoint(
                id: id,
                text: text,
                status: status,
                dependsOn: todo.dependsOn ?? [],
                hasExplicitDependencies: todo.dependsOn != nil
            )
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

    func synchronizeTaskGraphFromLegacyTodo(
        toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) async {
        guard !result.isFailure,
              let plan = activePlan,
              plan.isApproved,
              let update = Self.planPointUpdates(from: toolCall) else {
            return
        }

        for point in update.points {
            guard var view = try? await sessionRunner.taskOrchestrator.task(
                sessionID: sessionID,
                taskID: point.id,
                graphID: plan.id
            ) else { continue }
            switch point.status {
            case .pending:
                if view.task.status == .failed || view.task.status == .blocked {
                    view = (try? await sessionRunner.taskOrchestrator.retryTask(
                        sessionID: sessionID,
                        taskID: point.id,
                        graphID: plan.id
                    )) ?? view
                }
            case .inProgress:
                if view.task.status == .pending {
                    view = (try? await sessionRunner.taskOrchestrator.updateTask(
                        sessionID: sessionID,
                        taskID: point.id,
                        graphID: plan.id,
                        update: TaskUpdate(status: .inProgress)
                    )) ?? view
                }
            case .completed:
                if view.task.status == .pending {
                    view = (try? await sessionRunner.taskOrchestrator.updateTask(
                        sessionID: sessionID,
                        taskID: point.id,
                        graphID: plan.id,
                        update: TaskUpdate(status: .inProgress)
                    )) ?? view
                }
                if view.task.status == .inProgress {
                    _ = try? await sessionRunner.taskOrchestrator.updateTask(
                        sessionID: sessionID,
                        taskID: point.id,
                        graphID: plan.id,
                        update: TaskUpdate(status: .completed)
                    )
                } else if view.task.status == .awaitingValidation {
                    _ = try? await sessionRunner.taskOrchestrator.validateTaskResult(
                        sessionID: sessionID,
                        taskID: point.id,
                        succeeded: true,
                        evidence: [
                            TaskEvidence(
                                kind: "legacy_todo_bridge",
                                summary: "Legacy plan progress reported completion."
                            )
                        ]
                    )
                }
            case .blocked:
                if view.task.status == .pending || view.task.status == .inProgress
                    || view.task.status == .awaitingValidation {
                    _ = try? await sessionRunner.taskOrchestrator.updateTask(
                        sessionID: sessionID,
                        taskID: point.id,
                        graphID: plan.id,
                        update: TaskUpdate(
                            status: .blocked,
                            statusReason: "legacy plan progress reported a blocker"
                        )
                    )
                }
            case .awaitingValidation, .failed, .cancelled:
                break
            }
        }
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
            on. Keep every status "pending". Include dependsOn for every item: use the stable \
            IDs of prerequisite points, or an explicit empty array for independent points. \
            If the Planner did not specify dependencies, use a safe sequential chain. Do not \
            include risks, background notes, open questions, or validation summaries as \
            separate items.
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
    case structuredTasksUnavailable

    var errorDescription: String? {
        switch self {
        case .plannerOutputUnavailable:
            return "The Planner agent did not produce a completed plan. The current agent "
                + "was not allowed to substitute its own plan; run /plan <goal> again."
        case .sessionHistoryUnavailable:
            return "The Planner produced a plan, but ZenCODE could not replace the current "
                + "agent's response in the session history. The plan was not recorded."
        case .structuredTasksUnavailable:
            return "The Planner produced text but did not register a valid structured task list; "
                + "the previous plan and task graph were left unchanged."
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
