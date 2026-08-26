//
//  TerminalChat+Plan.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/07/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    func handlePlanCommand(_ command: String) async -> TerminalSubmittedLineAction {
        guard case let .plan(action) = CoordinatorCommandParser.parse(command) else {
            await writeFailureMessage(Self.planMissingGoalMessage)
            return .continueChat
        }

        switch action {
        case .save:
            await writeSubmittedPrompt(command)
            guard planBrainstorming == nil else {
                await writeFailureMessage(Self.planDiscussionBlocksMutationMessage)
                return .continueChat
            }
            await saveReusablePlan()
            return .continueChat
        case .load:
            await writeSubmittedPrompt(command)
            guard planBrainstorming == nil else {
                await writeFailureMessage(Self.planDiscussionBlocksMutationMessage)
                return .continueChat
            }
            await loadReusablePlan()
            return .continueChat
        case .list:
            await writeSubmittedPrompt(command)
            await listSavedPlans()
            return .continueChat
        case let .delete(target):
            await writeSubmittedPrompt(command)
            await deleteSavedPlan(
                argument: target.map { "delete \($0)" } ?? "delete"
            )
            return .continueChat
        case .status:
            await writeSubmittedPrompt(command)
            if let planBrainstorming {
                await writeSystemMessage(
                    "Planner clarification is active for: \(planBrainstorming.goal)\n"
                )
            }
            guard let activePlan else {
                if planBrainstorming == nil {
                    await writeSystemMessage("No active plan.\n")
                }
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
            await writeMarkdownMessage(Self.planStatusTable(for: projectedPlan, graph: graph))
            return .continueChat
        case .approve:
            await writeSubmittedPrompt(command)
            guard planBrainstorming == nil else {
                await writeFailureMessage(Self.planDiscussionBlocksMutationMessage)
                return .continueChat
            }
            guard var plan = activePlan,
                  !plan.consolidatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                await writeFailureMessage(Self.planUnavailableForApprovalMessage)
                return .continueChat
            }
            plan = Self.planMaterializedForApproval(plan)
            do {
                // The task graph is created exclusively at approval time so that
                // changes made to the plan before approval are always reflected.
                // On first approval, remove any stale graph and (re)create it from
                // the current plan points. On re-approval, preserve progress.
                let existingGraph = try await sessionRunner.taskGraphSnapshot(
                    sessionID: sessionID,
                    graphID: plan.id
                )
                if !plan.isApproved || existingGraph == nil || existingGraph?.tasks.isEmpty == true {
                    if existingGraph != nil {
                        _ = try await sessionRunner.removeTaskGraph(
                            id: plan.id,
                            sessionID: sessionID
                        )
                    }
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
                _ = try await sessionRunner.activateTaskGraph(
                    id: plan.id,
                    sessionID: sessionID
                )
            } catch {
                await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
                return .continueChat
            }
            plan.isApproved = true
            activePlan = plan
            // A loaded plan can be the first turn in a new session. Lock the
            // configured/system response language before its internal English
            // implementation prompt is sent to the model.
            lockResponseLanguageIfNeeded()
            await writeSystemMessage(
                "Approved the active plan and activated its task graph. Starting implementation now; /review will verify task claims against real files.\n\n"
            )
            return .runHiddenPrompt(
                Self.planImplementationPrompt(for: plan),
                purpose: .normal
            )
        case .clear:
            await writeSubmittedPrompt(command)
            let hadDiscussion = planBrainstorming != nil
            await abandonPlanBrainstorming()
            guard let plan = activePlan else {
                await writeSystemMessage(
                    hadDiscussion
                        ? "Cleared the unfinished planning discussion.\n"
                        : "No active plan or planning discussion to clear.\n"
                )
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
                await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
                return .continueChat
            }
            activePlan = nil
            await writeSystemMessage(
                "Cleared the active plan and archived its task graph in this session. "
                    + "Saved-plan library copies are unaffected; use /plan delete to remove those.\n"
            )
            return .continueChat
        case .missingGoal:
            await writeFailureMessage(Self.planMissingGoalMessage)
            return .continueChat
        case let .start(goal):
            if !isSubAgentToolEnabled {
                await writeFailureMessage(
                    """
                    ZenCODE: /plan requires the sub-agents tool group. \
                    Enable it with /tools (or switch to an agent that includes it) and try again.

                    """
                )
                return .continueChat
            }

            let plannerProfile = plannerProfileForDelegation()
            await writeSubmittedPrompt(command)
            // A new goal abandons the previous collection and closes its author,
            // but the completed active plan remains until a fresh final plan is valid.
            await abandonPlanBrainstorming(closeAllPlanAuthors: true)
            planBrainstorming = TerminalPlanBrainstormingState(goal: goal)

            return .runHiddenPrompt(
                Self.planDelegationPrompt(
                    goal: goal,
                    planner: plannerProfile
                ),
                purpose: .plan(originalGoal: goal)
            )
        }
    }

    /// Routes plain text received while the Planner is collecting decisions.
    /// Slash commands and mentions are handled by `submittedLineAction` before
    /// this method is reached.
    func handlePlanBrainstormingReply(_ reply: String) -> TerminalSubmittedLineAction? {
        guard var brainstorming = planBrainstorming,
              brainstorming.recordReply(reply) else {
            return nil
        }
        planBrainstorming = brainstorming
        let planner = plannerProfileForDelegation()
        return .runHiddenPrompt(
            PlanningCommandKernel.planContinuationPrompt(
                state: brainstorming,
                planner: planner
            ),
            purpose: .plan(originalGoal: brainstorming.goal)
        )
    }

    func abandonPlanBrainstorming(
        closeAllPlanAuthors: Bool = false,
        expectedCollectionID: UUID? = nil
    ) async {
        let state = planBrainstorming
        if let expectedCollectionID,
           state?.collectionID != expectedCollectionID {
            return
        }
        planBrainstorming = nil
        var agentIDs = Set<String>()
        if let plannerAgentID = state?.plannerAgentID {
            agentIDs.insert(plannerAgentID)
        }
        if closeAllPlanAuthors || (state != nil && agentIDs.isEmpty) {
            let snapshots = await sessionRunner.subAgentSnapshots()
            agentIDs.formUnion(
                PlanningCommandKernel.plannerSnapshots(
                    snapshots,
                    rootSessionID: sessionID
                ).map(\.id)
            )
        }
        for agentID in agentIDs {
            _ = await sessionRunner.closeSubAgent(id: agentID)
        }
    }

    nonisolated static let planMissingGoalMessage =
        "ZenCODE: /plan requires a goal. Use /plan <goal> to describe what should "
        + "be planned, or a subcommand: save, load, list, delete, status, approve, clear.\n"

    nonisolated static let planUnavailableForApprovalMessage =
        "ZenCODE: no completed plan is available to approve. "
        + "Run /plan <goal> and wait for it to finish successfully.\n"

    nonisolated static let planDiscussionBlocksMutationMessage =
        "ZenCODE: finish the current Planner clarification or use /plan clear before "
        + "approving, saving, or loading a plan.\n"

    nonisolated static let planUnavailableForSavingMessage =
        "ZenCODE: no plan is available to save. Run /plan <goal>, or ask an agent "
        + "to produce a plan before using /plan save.\n"

    nonisolated static let savedPlanUnavailableMessage =
        "ZenCODE: no saved plan is available for this project. Use /plan save first.\n"

    nonisolated static let savedPlansAllTerminalMessage =
        "ZenCODE: every saved plan for this project is already completed. "
        + "Use /plan list to review them or /plan delete <plan|all> to remove them.\n"

    nonisolated static let planDeleteUsageMessage =
        "ZenCODE: /plan delete requires a plan id, a unique id prefix, or all. "
        + "Use /plan list to review saved plans.\n"

    func saveReusablePlan(savedAt: Date = Date()) async {
        guard let plan = reusablePlanCandidate(createdAt: savedAt) else {
            await writeFailureMessage(Self.planUnavailableForSavingMessage)
            return
        }

        let storedPlan = Self.planPreparedForSaving(plan)
        let savedPlan = taskGraphSavedPlan(for: storedPlan, savedAt: savedAt)
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: configuration.workingDirectory
        )
        do {
            try await sessionRunner.taskOrchestrator.registerSession(
                id: librarySessionID,
                workingDirectory: configuration.workingDirectory
            )
            _ = try await sessionRunner.taskOrchestrator.savePlanDraft(
                savedPlan,
                sessionID: librarySessionID,
                tasks: Self.taskDefinitions(for: storedPlan.points)
            )
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            return
        }

        activePlan = plan
        await writeSystemMessage(
            "Saved plan: \(plan.id). Use /plan load in a new session to review or revise it.\n"
        )
    }

    func loadReusablePlan() async {
        guard activePlan == nil else {
            await writeFailureMessage(
                "ZenCODE: an active plan already exists. Use /plan clear before loading a saved plan.\n"
            )
            return
        }
        let savedPlans = await sessionRunner.savedTaskPlans(
            workingDirectory: configuration.workingDirectory
        )
        guard !savedPlans.isEmpty else {
            await writeFailureMessage(Self.savedPlanUnavailableMessage)
            return
        }
        guard let savedPlan = Self.loadableSavedPlan(from: savedPlans) else {
            await writeFailureMessage(Self.savedPlansAllTerminalMessage)
            return
        }

        let plan = Self.planPreparedForReuse(savedPlan)
        let contextMessage = AgentRuntimeMessage(
            role: .user,
            content: Self.savedPlanContextMessage(savedPlan, plan: plan)
        )
        let replacementHistory = activeSessionHistory + [contextMessage]

        if await sessionRunner.snapshotSession(id: sessionID) != nil {
            guard await sessionRunner.replaceSessionHistory(
                id: sessionID,
                history: replacementHistory
            ) else {
                await writeFailureMessage(
                    "ZenCODE: the saved plan could not be added to the current session context.\n"
                )
                return
            }
        }

        activeSessionHistory = replacementHistory
        activeSessionTranscript.append(contextMessage)
        activePlan = plan
        await writeMarkdownMessage(
            "Loaded saved plan `\(plan.id)` as an unapproved active plan.\n\n"
                + plan.consolidatedText
                + "\n\nUse /plan approve when it is ready to implement."
        )
    }

    /// Lists every saved plan for this project, newest save first, including
    /// entries that were already mirrored as completed so the library stays
    /// inspectable.
    func listSavedPlans() async {
        let savedPlans = await sessionRunner.savedTaskPlans(
            workingDirectory: configuration.workingDirectory
        )
        guard !savedPlans.isEmpty else {
            await writeSystemMessage(Self.savedPlanUnavailableMessage)
            return
        }
        await writeMarkdownMessage(Self.savedPlansListMessage(for: savedPlans))
    }

    /// Deletes saved plans from the project library. The target can be a full
    /// plan id, a unique id prefix, or `all`. The active plan of the current
    /// session and its live task graph are never touched here: that is
    /// /plan clear's session-scoped role.
    func deleteSavedPlan(argument: String) async {
        let savedPlans = await sessionRunner.savedTaskPlans(
            workingDirectory: configuration.workingDirectory
        )
        guard !savedPlans.isEmpty else {
            await writeFailureMessage(Self.savedPlanUnavailableMessage)
            return
        }
        guard let target = Self.planDeleteTarget(from: argument) else {
            await writeFailureMessage(Self.planDeleteUsageMessage)
            return
        }
        switch Self.savedPlanDeletionTarget(
            target,
            in: savedPlans.map(\.graph.id)
        ) {
        case .notFound:
            await writeFailureMessage(
                Self.planDeleteNotFoundMessage(
                    availablePlanIDs: savedPlans.map(\.graph.id)
                )
            )
        case let .ambiguous(matches):
            await writeFailureMessage(
                Self.planDeleteAmbiguousMessage(matches: matches)
            )
        case let .ids(planIDs):
            do {
                let deletedPlanIDs = try await sessionRunner.deleteSavedTaskPlans(
                    planIDs: planIDs,
                    workingDirectory: configuration.workingDirectory
                )
                await writeSystemMessage(
                    Self.planDeleteSuccessMessage(
                        deletedPlanIDs: deletedPlanIDs,
                        activePlanAffected: activePlan.map { planIDs.contains($0.id) } ?? false
                    )
                )
            } catch {
                await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
            }
        }
    }

    typealias SavedPlanDeletionResolution = PlanningCommandKernel.SavedPlanDeletionResolution

    /// Resolves the target of /plan delete among the known saved-plan ids:
    /// `all` selects everything, an exact id wins, and otherwise a unique id
    /// prefix is accepted so users do not have to retype full plan UUIDs.
    nonisolated static func savedPlanDeletionTarget(
        _ target: String,
        in planIDs: [String]
    ) -> SavedPlanDeletionResolution {
        PlanningCommandKernel.savedPlanDeletionTarget(target, in: planIDs)
    }

    /// Extracts the delete target from the raw /plan argument, e.g.
    /// "delete plan-1234" → "plan-1234".
    nonisolated static func planDeleteTarget(from argument: String) -> String? {
        guard let separator = argument.firstIndex(where: \.isWhitespace) else {
            return nil
        }
        let target = argument[argument.index(after: separator)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return target.isEmpty ? nil : target
    }

    /// A saved plan stays loadable only while its library graph is still a
    /// reusable draft; completed entries are historical.
    nonisolated static func loadableSavedPlan(
        from savedPlans: [SavedTaskPlan]
    ) -> SavedTaskPlan? {
        PlanningCommandKernel.loadableSavedPlan(from: savedPlans)
    }

    nonisolated static func planDeleteNotFoundMessage(
        availablePlanIDs: [String]
    ) -> String {
        PlanningCommandKernel.planDeleteNotFoundMessage(
            availablePlanIDs: availablePlanIDs
        )
    }

    nonisolated static func planDeleteAmbiguousMessage(
        matches: [String]
    ) -> String {
        PlanningCommandKernel.planDeleteAmbiguousMessage(matches: matches)
    }

    nonisolated static func planDeleteSuccessMessage(
        deletedPlanIDs: [String],
        activePlanAffected: Bool
    ) -> String {
        PlanningCommandKernel.planDeleteSuccessMessage(
            deletedPlanIDs: deletedPlanIDs,
            activePlanAffected: activePlanAffected
        )
    }

    nonisolated static func savedPlansListMessage(
        for savedPlans: [SavedTaskPlan]
    ) -> String {
        PlanningCommandKernel.savedPlansListMessage(for: savedPlans)
    }

    func reusablePlanCandidate(createdAt: Date = Date()) -> TerminalSessionPlan? {
        if let activePlan,
           activePlan.originalGoal.nilIfBlank != nil,
           activePlan.consolidatedText.nilIfBlank != nil {
            return activePlan
        }
        if let plan = Self.planFromLatestAssistantMessage(
            in: activeSessionTranscript,
            createdAt: createdAt
        ) {
            return plan
        }
        return Self.planFromLatestAssistantMessage(
            in: activeSessionHistory,
            createdAt: createdAt
        )
    }

    func taskGraphSavedPlan(
        for plan: TerminalSessionPlan,
        savedAt: Date = Date()
    ) -> TaskGraphSavedPlan {
        TaskGraphSavedPlan(
            plan: plan,
            savedAt: savedAt,
            savingAgentID: selectedAgent?.id,
            savingAgentName: selectedAgent?.name
        )
    }

    nonisolated static func planPreparedForSaving(
        _ plan: TerminalSessionPlan
    ) -> TerminalSessionPlan {
        PlanningCommandKernel.planPreparedForSaving(plan)
    }

    nonisolated static func planFromLatestAssistantMessage(
        in messages: [AgentRuntimeMessage],
        createdAt: Date = Date()
    ) -> TerminalSessionPlan? {
        PlanningCommandKernel.planFromLatestAssistantMessage(
            in: messages,
            createdAt: createdAt
        )
    }

    nonisolated static func planPreparedForReuse(
        _ savedPlan: SavedTaskPlan
    ) -> TerminalSessionPlan {
        PlanningCommandKernel.planPreparedForReuse(savedPlan)
    }

    /// Gives a legacy text-only plan one stable task at approval time rather
    /// than attempting to infer an unreliable task breakdown from prose.
    /// This keeps every approved plan on the same task-graph control plane.
    nonisolated static func planMaterializedForApproval(
        _ plan: TerminalSessionPlan
    ) -> TerminalSessionPlan {
        PlanningCommandKernel.planMaterializedForApproval(plan)
    }

    nonisolated static func savedPlanContextMessage(
        _ savedPlan: SavedTaskPlan,
        plan: TerminalSessionPlan
    ) -> String {
        PlanningCommandKernel.savedPlanContextMessage(savedPlan, plan: plan)
    }

    nonisolated static let planAuthorAgentName = PlanningCommandKernel.planAuthorAgentName

    nonisolated static func planImplementationPrompt(for plan: TerminalSessionPlan) -> String {
        PlanningCommandKernel.planImplementationPrompt(for: plan)
    }

    nonisolated static func planStatusTable(for plan: TerminalSessionPlan) -> String {
        PlanningCommandKernel.planStatusTable(for: plan, graph: nil)
    }

    nonisolated static func planStatusTable(
        for plan: TerminalSessionPlan,
        graph: TaskGraphSnapshot?
    ) -> String {
        PlanningCommandKernel.planStatusTable(for: plan, graph: graph)
    }

    nonisolated static func plan(
        _ plan: TerminalSessionPlan,
        applying graph: TaskGraphSnapshot
    ) -> TerminalSessionPlan {
        PlanningCommandKernel.plan(plan, applying: graph)
    }

    nonisolated static func planPointStatus(for status: TaskStatus) -> TerminalSessionPlanPointStatus {
        PlanningCommandKernel.planPointStatus(for: status)
    }

    nonisolated static func taskDefinitions(
        for points: [TerminalSessionPlanPoint]
    ) -> [TaskDefinition] {
        PlanningCommandKernel.taskDefinitions(for: points)
    }

    nonisolated static func planPointUpdates(
        from toolCall: DirectAgentToolCall
    ) -> (points: [TerminalSessionPlanPoint], mode: DirectTodoTaskRuntime.TodoWriteMode)? {
        PlanningCommandKernel.planPointUpdates(from: toolCall)
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

    nonisolated static func isPlannerProfile(_ agent: AgentProfile) -> Bool {
        agent.id.caseInsensitiveCompare(AgentProfileStore.plannerAgentID.uuidString) == .orderedSame
            || agent.name.caseInsensitiveCompare(AgentProfileStore.plannerAgentName) == .orderedSame
    }

    nonisolated static func planDelegationPrompt(
        goal: String,
        planner: AgentProfile
    ) -> String {
        PlanningCommandKernel.planStartPrompt(goal: goal, planner: planner)
    }

    nonisolated static func planContinuationDelegationPrompt(
        goal: String,
        exchanges: [TerminalPlanBrainstormingState.Exchange],
        planner: AgentProfile
    ) -> String {
        var state = TerminalPlanBrainstormingState(goal: goal)
        state.exchanges = exchanges
        return PlanningCommandKernel.planContinuationPrompt(
            state: state,
            planner: planner
        )
    }

    nonisolated static func isPlannerQuestionResponse(_ text: String) -> Bool {
        PlanningCommandKernel.isPlannerQuestionResponse(text)
    }

    nonisolated static func plannerAuthoredPlanResponse(
        parentResponse: DirectAgentResponse,
        snapshots: [DirectSubAgentRuntime.AgentSnapshot],
        excludingAgentIDs: Set<String> = []
    ) -> DirectAgentResponse? {
        let eligibleSnapshots = snapshots.filter { !excludingAgentIDs.contains($0.id) }
        let baseline = PlannerTurnBaseline(
            state: nil,
            snapshots: [],
            rootSessionID: nil
        )
        return PlanningCommandKernel.plannerResponse(
            parentResponse: parentResponse,
            snapshots: eligibleSnapshots,
            baseline: baseline,
            rootSessionID: nil
        )?.response
    }

    nonisolated static func isPlannerSnapshotProfile(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> Bool {
        PlanningCommandKernel.isPlannerSnapshotProfile(snapshot)
    }

    nonisolated static func historyByReplacingPlanCoordinatorOutput(
        _ history: [AgentRuntimeMessage],
        with plannerOutput: String
    ) -> [AgentRuntimeMessage] {
        PlanningCommandKernel.historyByReplacingCoordinatorOutput(
            history,
            with: plannerOutput
        )
    }
}

enum TerminalPlanGenerationError: LocalizedError {
    case plannerOutputUnavailable
    case sessionHistoryUnavailable
    case structuredTasksUnavailable
    case unexpectedStructuredTasksForQuestions

    var errorDescription: String? {
        switch self {
        case .plannerOutputUnavailable:
            return "The Planner agent did not produce fresh output for this planning turn. The current agent "
                + "was not allowed to substitute its own plan; run /plan <goal> again."
        case .sessionHistoryUnavailable:
            return "The Planner produced a plan, but ZenCODE could not replace the current "
                + "agent's response in the session history. The plan was not recorded."
        case .structuredTasksUnavailable:
            return "The Planner produced text but did not register a valid structured task list; "
                + "the previous plan and task graph were left unchanged."
        case .unexpectedStructuredTasksForQuestions:
            return "The Planner asked clarification questions, but the coordinator also registered plan tasks; "
                + "the previous plan and task graph were left unchanged."
        }
    }
}

typealias TerminalPlanPointCollector = PlanningPointCollector
