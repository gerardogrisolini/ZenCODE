//
//  ZenCODEACPBridge+Commands.swift
//  ZenCODE
//
//  Shared /plan and /goal routing for ACP sessions.
//

import Foundation
import ToolCore

enum ACPCommandPromptPurpose: Sendable {
    case normal
    case implementation
    case workflow(graphID: String)
    case review
    case planning(collectionID: UUID, baseline: PlannerTurnBaseline)

    var suppressesCoordinatorContent: Bool {
        if case .planning = self { return true }
        return false
    }

    var additionalToolNames: Set<String> {
        switch self {
        case .normal:
            return []
        case .planning:
            return ["todo.write"]
        case .implementation:
            return ["tasks.list", "tasks.get", "tasks.update", "tasks.retry", "tasks.cancel"]
        case .workflow:
            return [
                "tasks.create", "tasks.list", "tasks.get",
                "tasks.update", "tasks.retry", "tasks.cancel",
            ]
        case .review:
            return ["tasks.create", "tasks.list", "tasks.get", "tasks.update"]
        }
    }
}

enum ACPCommandTurnRoute: Sendable {
    case generate(
        prompt: String,
        purpose: ACPCommandPromptPurpose,
        prelude: String? = nil
    )
    case immediate(String)
}

enum ACPPlanningCommandError: LocalizedError {
    case plannerOutputUnavailable
    case sessionHistoryUnavailable
    case structuredTasksUnavailable
    case unexpectedTasksForQuestions

    var errorDescription: String? {
        switch self {
        case .plannerOutputUnavailable:
            return "The Planner did not produce fresh output for this ACP planning turn."
        case .sessionHistoryUnavailable:
            return "The Planner output could not replace the coordinator output in ACP session history."
        case .structuredTasksUnavailable:
            return "The Planner declared a final plan without registering a valid task for every implementation point."
        case .unexpectedTasksForQuestions:
            return "The Planner asked questions, but the coordinator also registered plan tasks."
        }
    }
}

extension ZenCODEACPBridge {
    func routeACPCommandTurn(
        command: CoordinatorCommand?,
        routedPromptText: String,
        hasAgentMention: Bool,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async throws -> ACPCommandTurnRoute {
        guard let session = reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) else {
            throw CancellationError()
        }

        guard let command else {
            guard !hasAgentMention,
                  !CoordinatorCommandParser.isSlashCommand(routedPromptText),
                  var brainstorming = session.planBrainstorming,
                  brainstorming.isAwaitingReply,
                  brainstorming.recordReply(routedPromptText) else {
                return .generate(prompt: routedPromptText, purpose: .normal)
            }
            guard acpSubAgentsAreAvailable(
                in: session,
                requiresMessaging: true
            ) else {
                return .immediate(
                    "ZenCODE: /plan requires the sub-agent tools in this ACP session."
                )
            }
            let planner = try acpPlannerProfile()
            let snapshots = await sessionRunner.subAgentSnapshots()
            guard updateReservedPromptSession(
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID,
                { $0.planBrainstorming = brainstorming }
            ) else {
                throw CancellationError()
            }
            let baseline = PlannerTurnBaseline(
                state: brainstorming,
                snapshots: snapshots,
                rootSessionID: sessionID
            )
            return .generate(
                prompt: PlanningCommandKernel.planContinuationPrompt(
                    state: brainstorming,
                    planner: planner
                ),
                purpose: .planning(
                    collectionID: brainstorming.collectionID,
                    baseline: baseline
                )
            )
        }

        switch command {
        case let .goal(goal):
            return try await routeACPGoal(
                goal: goal,
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID
            )
        case let .review(scope):
            return await routeACPReview(
                scope: scope,
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID
            )
        case let .plan(action):
            return try await routeACPPlanAction(
                action,
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID
            )
        }
    }

    private func routeACPReview(
        scope: String,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async -> ACPCommandTurnRoute {
        guard let session = reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) else {
            return .immediate("ZenCODE: the ACP session changed before /review started.")
        }
        guard acpSubAgentsAreAvailable(in: session) else {
            return .immediate(
                "ZenCODE: /review requires the sub-agent tools in this ACP session."
            )
        }
        let reviewer: AgentProfile
        do {
            reviewer = try acpReviewerProfile()
        } catch {
            return .immediate("ZenCODE: \(error.localizedDescription)")
        }
        let approvedPlan = session.activePlan.flatMap { plan in
            plan.isApproved && plan.consolidatedText.nilIfBlank != nil ? plan : nil
        }
        let graph = try? await sessionRunner.taskGraphSnapshot(
            sessionID: sessionID,
            graphID: approvedPlan?.id
        )
        guard reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) != nil else {
            return .immediate("ZenCODE: the ACP session changed before /review started.")
        }
        return .generate(
            prompt: acpReviewPrompt(
                scope: scope,
                reviewer: reviewer,
                approvedPlan: approvedPlan,
                taskGraph: graph
            ),
            purpose: .review
        )
    }

    private func routeACPGoal(
        goal: String,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async throws -> ACPCommandTurnRoute {
        guard let session = reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) else {
            throw CancellationError()
        }
        guard let goal = goal.nilIfBlank else {
            return .immediate(
                "ZenCODE: /goal requires a goal. Use /goal <goal> to describe what should be planned and delegated."
            )
        }
        guard session.activePlan == nil, session.planBrainstorming == nil else {
            return .immediate(
                "ZenCODE: /goal cannot start while an active plan or planning discussion exists. Finish it or use /plan clear first."
            )
        }
        guard acpSubAgentsAreAvailable(in: session) else {
            return .immediate(
                "ZenCODE: /goal requires the sub-agent tools in this ACP session."
            )
        }

        let graphID = "workflow_\(UUID().uuidString.lowercased())"
        do {
            _ = try await sessionRunner.taskOrchestrator.createGraph(
                sessionID: sessionID,
                id: graphID,
                source: .workflow,
                state: .active,
                tasks: []
            )
        } catch {
            return .immediate("ZenCODE: \(error.localizedDescription)")
        }
        guard reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) != nil else {
            _ = try? await sessionRunner.removeTaskGraph(
                id: graphID,
                sessionID: sessionID
            )
            throw CancellationError()
        }
        return .generate(
            prompt: PlanningCommandKernel.workflowPrompt(goal: goal, graphID: graphID),
            purpose: .workflow(graphID: graphID)
        )
    }

    private func routeACPPlanAction(
        _ action: CoordinatorCommand.PlanAction,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async throws -> ACPCommandTurnRoute {
        guard let session = reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) else {
            throw CancellationError()
        }

        switch action {
        case .missingGoal:
            return .immediate(
                "ZenCODE: /plan requires a goal or one of: save, load, list, delete, status, approve, clear."
            )
        case let .start(goal):
            guard acpSubAgentsAreAvailable(
                in: session,
                requiresMessaging: true
            ) else {
                return .immediate(
                    "ZenCODE: /plan requires the sub-agent tools in this ACP session."
                )
            }
            let planner = try acpPlannerProfile()
            await clearACPPlanBrainstorming(
                sessionID: sessionID,
                epoch: epoch,
                closeAllPlanAuthors: true
            )
            guard reservedPromptSession(
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID
            ) != nil else {
                throw CancellationError()
            }
            let brainstorming = PlanningCommandRuntimeState(goal: goal)
            let snapshots = await sessionRunner.subAgentSnapshots()
            let baseline = PlannerTurnBaseline(
                state: brainstorming,
                snapshots: snapshots,
                rootSessionID: sessionID
            )
            guard updateReservedPromptSession(
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID,
                { $0.planBrainstorming = brainstorming }
            ) else {
                throw CancellationError()
            }
            return .generate(
                prompt: PlanningCommandKernel.planStartPrompt(goal: goal, planner: planner),
                purpose: .planning(
                    collectionID: brainstorming.collectionID,
                    baseline: baseline
                )
            )
        case .save:
            guard session.planBrainstorming == nil else {
                return .immediate(acpPlanningMutationBlockedMessage)
            }
            return .immediate(
                await saveACPPlan(
                    sessionID: sessionID,
                    epoch: epoch,
                    promptID: promptID
                )
            )
        case .load:
            guard session.planBrainstorming == nil else {
                return .immediate(acpPlanningMutationBlockedMessage)
            }
            return .immediate(
                await loadACPPlan(
                    sessionID: sessionID,
                    epoch: epoch,
                    promptID: promptID
                )
            )
        case .list:
            return .immediate(await listACPPlans(session: session))
        case let .delete(target):
            return .immediate(await deleteACPPlan(target: target, session: session))
        case .status:
            return .immediate(await acpPlanStatus(session: session))
        case .approve:
            guard session.planBrainstorming == nil else {
                return .immediate(acpPlanningMutationBlockedMessage)
            }
            return await approveACPPlan(
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID
            )
        case .clear:
            return await clearACPPlan(
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID
            )
        }
    }

    private var acpPlanningMutationBlockedMessage: String {
        "ZenCODE: finish the current Planner clarification or use /plan clear before approving, saving, or loading a plan."
    }

    private func acpPlannerProfile() throws -> AgentProfile {
        if let planner = AgentProfileStore.roleProfile(
            id: AgentProfileStore.plannerAgentID,
            name: AgentProfileStore.plannerAgentName,
            in: try availableACPAgentProfiles()
        ) { return planner }
        throw ACPError.invalidParams("The Planner agent profile is unavailable.")
    }

    private func acpReviewerProfile() throws -> AgentProfile {
        if let reviewer = AgentProfileStore.roleProfile(
            id: AgentProfileStore.reviewerAgentID,
            name: AgentProfileStore.reviewerAgentName,
            in: try availableACPAgentProfiles()
        ) { return reviewer }
        throw ACPError.invalidParams("The Reviewer agent profile is unavailable.")
    }

    private func acpReviewPrompt(
        scope: String,
        reviewer: AgentProfile,
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
        - Use role "Reviewer" and profile "\(reviewer.id)". The Reviewer must not edit files.
        - Ask it to inspect the relevant current files and validation evidence, not merely trust \
        task status, attempt output, or plan claims.
        - Require concrete findings ordered by severity with file:line references when available, \
        plus missing validation or coverage discrepancies.

        Wait for the Reviewer with agent.wait. Return a concise consolidated review in the session \
        response language. If there are no findings, say so explicitly. Do not make corrections in \
        this turn.
        """
    }

    private func acpSubAgentsAreAvailable(
        in session: SessionState,
        requiresMessaging: Bool = false
    ) -> Bool {
        guard let allowedToolNames = session.allowedToolNames else { return true }
        guard allowedToolNames.contains("agent.create"),
              allowedToolNames.contains("agent.wait") else {
            return false
        }
        return !requiresMessaging || allowedToolNames.contains("agent.message")
    }

    private func reservedPromptSession(
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) -> SessionState? {
        guard let session = liveSession(id: sessionID, epoch: epoch),
              session.activePromptID == promptID,
              case let .prompting(activePromptID) = session.operationState,
              activePromptID == promptID else {
            return nil
        }
        return session
    }

    @discardableResult
    private func updateReservedPromptSession(
        sessionID: String,
        epoch: UInt64,
        promptID: UUID,
        _ update: (inout SessionState) -> Void
    ) -> Bool {
        var didUpdate = false
        let isLive = updateLiveSession(id: sessionID, epoch: epoch) { session in
            guard session.activePromptID == promptID,
                  case let .prompting(activePromptID) = session.operationState,
                  activePromptID == promptID else {
                return
            }
            update(&session)
            didUpdate = true
        }
        return isLive && didUpdate
    }

    func clearACPPlanBrainstorming(
        sessionID: String,
        epoch: UInt64,
        closeAllPlanAuthors: Bool = false,
        expectedCollectionID: UUID? = nil
    ) async {
        guard let session = liveSession(id: sessionID, epoch: epoch) else { return }
        let collectionID = session.planBrainstorming?.collectionID
        if let expectedCollectionID, collectionID != expectedCollectionID {
            return
        }
        let brainstorming = session.planBrainstorming
        var agentIDs = Set<String>()
        if let plannerAgentID = brainstorming?.plannerAgentID {
            agentIDs.insert(plannerAgentID)
        }
        if closeAllPlanAuthors || (brainstorming != nil && agentIDs.isEmpty) {
            let snapshots = await sessionRunner.subAgentSnapshots()
            guard let current = liveSession(id: sessionID, epoch: epoch),
                  current.planBrainstorming?.collectionID == collectionID else {
                return
            }
            agentIDs.formUnion(
                PlanningCommandKernel.plannerSnapshots(
                    snapshots,
                    rootSessionID: sessionID
                ).map(\.id)
            )
        }
        guard updateLiveSession(id: sessionID, epoch: epoch, { state in
            guard state.planBrainstorming?.collectionID == collectionID else { return }
            state.planBrainstorming = nil
        }) else {
            return
        }
        for agentID in agentIDs {
            _ = await sessionRunner.closeSubAgent(id: agentID)
        }
    }

    private func saveACPPlan(
        sessionID: String,
        epoch: UInt64,
        promptID: UUID,
        savedAt: Date = Date()
    ) async -> String {
        guard let session = reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) else {
            return "ZenCODE: the ACP session changed while saving the plan."
        }
        let snapshot = await sessionRunner.snapshotSession(id: sessionID)
        guard reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) != nil else {
            return "ZenCODE: the ACP session changed while saving the plan."
        }
        guard let plan = session.activePlan
                ?? PlanningCommandKernel.planFromLatestAssistantMessage(
                    in: snapshot?.history ?? session.configuration.history,
                    createdAt: savedAt
                ),
              plan.consolidatedText.nilIfBlank != nil else {
            return "ZenCODE: no completed plan is available to save."
        }
        let storedPlan = PlanningCommandKernel.planPreparedForSaving(plan)
        let savedPlan = TaskGraphSavedPlan(
            plan: storedPlan,
            savedAt: savedAt,
            savingAgentID: session.selectedAgent?.id,
            savingAgentName: session.selectedAgent?.name
        )
        let workingDirectory = URL(fileURLWithPath: session.cwd)
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: workingDirectory
        )
        do {
            try await sessionRunner.taskOrchestrator.registerSession(
                id: librarySessionID,
                workingDirectory: workingDirectory
            )
            _ = try await sessionRunner.taskOrchestrator.savePlanDraft(
                savedPlan,
                sessionID: librarySessionID,
                tasks: PlanningCommandKernel.taskDefinitions(for: storedPlan.points)
            )
            guard updateReservedPromptSession(
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID,
                { $0.activePlan = plan }
            ) else {
                return "ZenCODE: the ACP session changed while saving the plan."
            }
            return "Saved plan: \(plan.id). Use /plan load in a new session to review or revise it."
        } catch {
            return "ZenCODE: \(error.localizedDescription)"
        }
    }

    private func loadACPPlan(
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async -> String {
        guard let session = reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) else {
            return "ZenCODE: the ACP session changed while loading the plan."
        }
        guard let runnerGeneration = await sessionRunner.currentSessionGeneration(
            for: sessionID
        ) else {
            return "ZenCODE: the ACP session changed while loading the plan."
        }
        guard session.activePlan == nil else {
            return "ZenCODE: an active plan already exists. Use /plan clear before loading a saved plan."
        }
        let workingDirectory = URL(fileURLWithPath: session.cwd)
        let savedPlans = await sessionRunner.savedTaskPlans(
            workingDirectory: workingDirectory
        )
        guard let savedPlan = PlanningCommandKernel.loadableSavedPlan(from: savedPlans) else {
            return savedPlans.isEmpty
                ? "ZenCODE: no saved plan is available for this project."
                : "ZenCODE: every saved plan for this project is already completed."
        }
        let plan = PlanningCommandKernel.planPreparedForReuse(savedPlan)
        let contextMessage = AgentRuntimeMessage(
            role: .user,
            content: PlanningCommandKernel.savedPlanContextMessage(savedPlan, plan: plan)
        )
        let history = (await sessionRunner.snapshotSession(id: sessionID))?.history
            ?? session.configuration.history
        guard await sessionRunner.replaceSessionHistory(
            id: sessionID,
            history: history + [contextMessage],
            expectedSessionGeneration: runnerGeneration
        ) else {
            return "ZenCODE: the saved plan could not be added to the current ACP session."
        }
        await refreshSessionStateIfAvailable(
            sessionID: sessionID,
            preservingAllowedToolNames: session.allowedToolNames,
            expectedEpoch: epoch,
            expectedPromptID: promptID
        )
        guard updateReservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID,
            { $0.activePlan = plan }
        ) else {
            if let installed = await sessionRunner.snapshotSession(id: sessionID),
               installed.history == history + [contextMessage] {
                _ = await sessionRunner.replaceSessionHistory(
                    id: sessionID,
                    history: history,
                    expectedSessionGeneration: runnerGeneration
                )
            }
            return "ZenCODE: the saved plan could not be added to the current ACP session."
        }
        return "Loaded saved plan `\(plan.id)` as an unapproved active plan.\n\n\(plan.consolidatedText)\n\nUse /plan approve when it is ready."
    }

    private func listACPPlans(session: SessionState) async -> String {
        let savedPlans = await sessionRunner.savedTaskPlans(
            workingDirectory: URL(fileURLWithPath: session.cwd)
        )
        guard !savedPlans.isEmpty else {
            return "ZenCODE: no saved plan is available for this project."
        }
        return PlanningCommandKernel.savedPlansListMessage(for: savedPlans)
    }

    private func deleteACPPlan(target: String?, session: SessionState) async -> String {
        guard let target = target?.nilIfBlank else {
            return "ZenCODE: /plan delete requires a plan id, unique prefix, or all."
        }
        let workingDirectory = URL(fileURLWithPath: session.cwd)
        let savedPlans = await sessionRunner.savedTaskPlans(
            workingDirectory: workingDirectory
        )
        guard !savedPlans.isEmpty else {
            return "ZenCODE: no saved plan is available for this project."
        }
        switch PlanningCommandKernel.savedPlanDeletionTarget(
            target,
            in: savedPlans.map(\.graph.id)
        ) {
        case .notFound:
            return PlanningCommandKernel.planDeleteNotFoundMessage(
                availablePlanIDs: savedPlans.map(\.graph.id)
            )
        case let .ambiguous(matches):
            return PlanningCommandKernel.planDeleteAmbiguousMessage(matches: matches)
        case let .ids(planIDs):
            do {
                let deleted = try await sessionRunner.deleteSavedTaskPlans(
                    planIDs: planIDs,
                    workingDirectory: workingDirectory
                )
                return PlanningCommandKernel.planDeleteSuccessMessage(
                    deletedPlanIDs: deleted,
                    activePlanAffected: session.activePlan.map {
                        planIDs.contains($0.id)
                    } ?? false
                )
            } catch {
                return "ZenCODE: \(error.localizedDescription)"
            }
        }
    }

    private func acpPlanStatus(session: SessionState) async -> String {
        var sections: [String] = []
        if let brainstorming = session.planBrainstorming {
            sections.append("Planner clarification is active for: \(brainstorming.goal)")
        }
        guard let plan = session.activePlan else {
            sections.append("No active plan.")
            return sections.joined(separator: "\n\n")
        }
        let graph = try? await sessionRunner.taskGraphSnapshot(
            sessionID: session.id,
            graphID: plan.id
        )
        let projected = graph.map { PlanningCommandKernel.plan(plan, applying: $0) } ?? plan
        sections.append(PlanningCommandKernel.planStatusTable(for: projected, graph: graph))
        return sections.joined(separator: "\n\n")
    }

    private func approveACPPlan(
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async -> ACPCommandTurnRoute {
        guard let session = reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ), var plan = session.activePlan,
           plan.consolidatedText.nilIfBlank != nil else {
            return .immediate(
                "ZenCODE: no completed plan is available to approve. Run /plan <goal> first."
            )
        }
        guard let runnerGeneration = await sessionRunner.currentSessionGeneration(
            for: sessionID
        ), reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) != nil else {
            return .immediate("ZenCODE: the ACP session changed before plan approval completed.")
        }
        plan = PlanningCommandKernel.planMaterializedForApproval(plan)
        var previousGraph: TaskGraphSnapshot?
        var graphWasMutated = false
        do {
            previousGraph = try await sessionRunner.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: plan.id
            )
            if !plan.isApproved || previousGraph == nil || previousGraph?.tasks.isEmpty == true {
                if previousGraph != nil {
                    graphWasMutated = true
                    _ = try await sessionRunner.removeTaskGraph(
                        id: plan.id,
                        sessionID: sessionID
                    )
                }
                graphWasMutated = true
                _ = try await sessionRunner.taskOrchestrator.createGraph(
                    sessionID: sessionID,
                    id: plan.id,
                    source: .plan(planID: plan.id),
                    state: .draft,
                    tasks: PlanningCommandKernel.taskDefinitions(for: plan.points),
                    makeCurrent: true,
                    archivePreviousCurrent: true
                )
            }
            graphWasMutated = true
            _ = try await sessionRunner.activateTaskGraph(
                id: plan.id,
                sessionID: sessionID
            )
        } catch {
            if graphWasMutated {
                await rollbackACPTaskGraph(
                    previousGraph,
                    graphID: plan.id,
                    sessionID: sessionID,
                    expectedRunnerGeneration: runnerGeneration
                )
            }
            return .immediate("ZenCODE: \(error.localizedDescription)")
        }
        plan.isApproved = true
        guard updateReservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID,
            { $0.activePlan = plan }
        ) else {
            await rollbackACPTaskGraph(
                previousGraph,
                graphID: plan.id,
                sessionID: sessionID,
                expectedRunnerGeneration: runnerGeneration
            )
            return .immediate("ZenCODE: the ACP session changed before plan approval completed.")
        }
        return .generate(
            prompt: PlanningCommandKernel.planImplementationPrompt(for: plan),
            purpose: .implementation,
            prelude: "Approved the active plan and activated its task graph. Starting implementation now."
        )
    }

    private func rollbackACPTaskGraph(
        _ previousGraph: TaskGraphSnapshot?,
        graphID: String,
        sessionID: String,
        expectedRunnerGeneration: AgentCoreSessionRunner.SessionGeneration
    ) async {
        guard await sessionRunner.isCurrentSessionGeneration(
            expectedRunnerGeneration,
            for: sessionID
        ) else {
            return
        }
        if (try? await sessionRunner.taskGraphSnapshot(
            sessionID: sessionID,
            graphID: graphID
        )) != nil {
            _ = try? await sessionRunner.removeTaskGraph(
                id: graphID,
                sessionID: sessionID
            )
        }
        if let previousGraph {
            _ = try? await sessionRunner.restoreTaskGraph(
                previousGraph,
                sessionID: sessionID
            )
        }
    }

    private func clearACPPlan(
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async -> ACPCommandTurnRoute {
        guard let original = reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) else {
            return .immediate("ZenCODE: the ACP session changed before /plan clear completed.")
        }
        let hadDiscussion = original.planBrainstorming != nil
        await clearACPPlanBrainstorming(sessionID: sessionID, epoch: epoch)
        guard let current = reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) else {
            return .immediate("ZenCODE: the ACP session changed before /plan clear completed.")
        }
        guard let plan = current.activePlan else {
            return .immediate(
                hadDiscussion
                    ? "Cleared the unfinished planning discussion."
                    : "No active plan or planning discussion to clear."
            )
        }
        guard let runnerGeneration = await sessionRunner.currentSessionGeneration(
            for: sessionID
        ) else {
            return .immediate("ZenCODE: the ACP session changed before /plan clear completed.")
        }
        var previousGraph: TaskGraphSnapshot?
        do {
            previousGraph = try await sessionRunner.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: plan.id
            )
            if previousGraph != nil {
                _ = try await sessionRunner.archiveTaskGraph(
                    id: plan.id,
                    sessionID: sessionID
                )
            }
        } catch {
            return .immediate("ZenCODE: \(error.localizedDescription)")
        }
        guard updateReservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID,
            { $0.activePlan = nil }
        ) else {
            await rollbackACPTaskGraph(
                previousGraph,
                graphID: plan.id,
                sessionID: sessionID,
                expectedRunnerGeneration: runnerGeneration
            )
            return .immediate("ZenCODE: the ACP session changed before /plan clear completed.")
        }
        return .immediate(
            "Cleared the active plan and archived its task graph. Saved-plan library copies are unaffected."
        )
    }

    func finalizeACPPlanningTurn(
        parent: PromptCompletion,
        purpose: ACPCommandPromptPurpose,
        collector: PlanningPointCollector,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async throws -> PromptCompletion {
        guard case let .planning(collectionID, baseline) = purpose,
              var session = reservedPromptSession(
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID
              ), var brainstorming = session.planBrainstorming,
              brainstorming.collectionID == collectionID else {
            throw CancellationError()
        }
        guard let runnerGeneration = await sessionRunner.currentSessionGeneration(
            for: sessionID
        ), reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) != nil else {
            throw CancellationError()
        }
        let parentResponse = DirectAgentResponse(
            text: parent.text,
            stopReason: parent.stopReason,
            modelID: parent.modelID
        )
        let snapshots = await sessionRunner.subAgentSnapshots()
        guard reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) != nil else {
            throw CancellationError()
        }
        guard let plannerResult = PlanningCommandKernel.plannerResponse(
            parentResponse: parentResponse,
            snapshots: snapshots,
            baseline: baseline,
            rootSessionID: sessionID
        ) else {
            throw ACPPlanningCommandError.plannerOutputUnavailable
        }
        let plannerText = plannerResult.response.text
        brainstorming.recordPlannerOutput(
            plannerText,
            agentID: plannerResult.snapshot.id,
            revision: plannerResult.snapshot.latestOutputRevision
        )

        if PlanningCommandKernel.isPlannerQuestionResponse(plannerText) {
            guard !(await collector.hasObservedTodoWrites()) else {
                throw ACPPlanningCommandError.unexpectedTasksForQuestions
            }
            session.planBrainstorming = brainstorming
        } else {
            guard let points = await collector.finalPlanPoints(
                forFinalText: plannerText
            ) else {
                throw ACPPlanningCommandError.structuredTasksUnavailable
            }
            session.activePlan = TerminalSessionPlan(
                id: PlanningCommandKernel.planID(from: points),
                originalGoal: brainstorming.goal,
                consolidatedText: plannerText,
                isApproved: false,
                points: points
            )
            session.planBrainstorming = nil
        }

        let snapshot = await sessionRunner.snapshotSession(id: sessionID)
        guard reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) != nil else {
            throw CancellationError()
        }
        let currentHistory = snapshot?.history ?? session.configuration.history
        let correctedHistory = PlanningCommandKernel.historyByReplacingCoordinatorOutput(
            currentHistory,
            with: plannerText
        )
        guard await sessionRunner.replaceSessionHistory(
            id: sessionID,
            history: correctedHistory,
            expectedSessionGeneration: runnerGeneration
        ) else {
            throw ACPPlanningCommandError.sessionHistoryUnavailable
        }
        guard reservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID
        ) != nil else {
            // Cancellation may race the runner suspension above. Roll back only
            // if no newer turn has changed the history, so an obsolete Planner
            // output can neither survive cancellation nor clobber fresh work.
            if liveSession(id: sessionID, epoch: epoch) != nil,
               let installed = await sessionRunner.snapshotSession(id: sessionID),
               installed.history == correctedHistory {
                _ = await sessionRunner.replaceSessionHistory(
                    id: sessionID,
                    history: currentHistory,
                    expectedSessionGeneration: runnerGeneration
                )
            }
            throw CancellationError()
        }
        guard updateReservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID,
            { liveSession in
                liveSession.activePlan = session.activePlan
                liveSession.planBrainstorming = session.planBrainstorming
            }
        ) else {
            if liveSession(id: sessionID, epoch: epoch) != nil,
               let installed = await sessionRunner.snapshotSession(id: sessionID),
               installed.history == correctedHistory {
                _ = await sessionRunner.replaceSessionHistory(
                    id: sessionID,
                    history: currentHistory,
                    expectedSessionGeneration: runnerGeneration
                )
            }
            throw CancellationError()
        }

        return PromptCompletion(
            text: plannerText,
            stopReason: parent.stopReason,
            modelID: plannerResult.response.modelID
        )
    }
}
