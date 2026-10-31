//
//  ChatSessionController+PlanningCommands.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The planning commands shared by every channel: `/plan` (start, the saved
/// plan library, status, approval, clear), `/goal`, `/review`, and the plain
/// replies the commands wait for (the Goal of `/plan approve`, the answer to
/// a Planner question, the answer to a `/goal` workflow question).
///
/// Each command returns a ``ChatCommandOutcome`` with its closing notices and
/// the turn it starts, if any. The echo of the submitted line goes to the
/// presenter (``ChatSessionPresenter/presentSubmittedCommand(_:)``) at the
/// point the terminal wrote it, so a refusal raised before that point is not
/// echoed. Every turn a command starts is a prompt the command built:
/// `locksResponseLanguage` is `false`. The approval of a plan asks the
/// channel to lock its response language through
/// ``ChatSessionChannelHooks/responseLanguageShouldLock()`` instead.
///
/// A channel that routes from another actor passes a ``ChatCommandFence``:
/// every write of the command state is checked against it under the
/// controller's lock, and a command it supersedes writes nothing more, undoes
/// the runtime changes it made, and returns an empty outcome. The
/// ``ChatPlanningCommandPolicy`` selects, command by command, the terminal's
/// sequence or ACP's.
extension ChatSessionController {
    // MARK: - Gates

    /// `true` while the sub-agents tool group is selected, which `/plan` and
    /// `/review` need to delegate.
    var isSubAgentToolEnabled: Bool {
        selection.toolKeys.contains { key in
            key.caseInsensitiveCompare("sub-agents") == .orderedSame
        }
    }

    /// Resolves the Planner profiles `/plan` may delegate to: every profile
    /// with the planner role visible to the project. An empty result means
    /// the command must stop.
    func plannerProfilesForDelegation() -> [AgentProfile] {
        AgentProfileStore.roleDelegationCandidates(
            .planner,
            in: (try? availableAgents()) ?? [],
            workspaceRootURL: workingDirectory
        )
    }

    /// Resolves the Reviewer profiles `/review` may delegate to: every
    /// profile with the reviewer role visible to the project. An empty result
    /// means the command must stop.
    func reviewerProfilesForDelegation() -> [AgentProfile] {
        AgentProfileStore.roleDelegationCandidates(
            .reviewer,
            in: (try? availableAgents()) ?? [],
            workspaceRootURL: workingDirectory
        )
    }

    /// The management runtime the planning and `/tasks` mutations need.
    func requiredManagementRuntime() throws -> any ChatSessionManagementRuntime {
        guard let managementRuntime else {
            throw ChatPlanningCommandError.sessionOperationsUnavailable
        }
        return managementRuntime
    }

    /// A turn of `purpose` with the prompt a command built.
    private static func commandTurn(
        _ prompt: String,
        purpose: ChatTurnPurpose
    ) -> ChatCommandOutcome {
        ChatCommandOutcome(
            action: .startTurn(prompt: prompt, purpose: purpose, locksResponseLanguage: false)
        )
    }

    /// The outcome of a command its fence superseded: nothing to present.
    /// The channel sees the fence fail and ends the request as cancelled.
    private static var superseded: ChatCommandOutcome {
        ChatCommandOutcome()
    }

    // MARK: - /plan

    /// `/plan` and its subcommands. `line` is the submitted command line.
    func runPlanCommand(
        line: String,
        fence: ChatCommandFence? = nil,
        policy: ChatPlanningCommandPolicy = .terminal
    ) async -> ChatCommandOutcome {
        guard case let .plan(action) = CoordinatorCommandParser.parse(line) else {
            return ChatCommandOutcome(notices: [.planMissingGoal])
        }

        switch action {
        case .save:
            await presenter.presentSubmittedCommand(line)
            guard planBrainstorming == nil, pendingPlanApprovalPlanID == nil else {
                return ChatCommandOutcome(notices: [.planDiscussionBlocksMutation])
            }
            return ChatCommandOutcome(
                notices: await saveReusablePlan(fence: fence, source: policy.planSave)
            )
        case .load:
            await presenter.presentSubmittedCommand(line)
            guard planBrainstorming == nil, pendingPlanApprovalPlanID == nil else {
                return ChatCommandOutcome(notices: [.planDiscussionBlocksMutation])
            }
            return ChatCommandOutcome(
                notices: await loadReusablePlan(fence: fence, source: policy.planLoad)
            )
        case .list:
            await presenter.presentSubmittedCommand(line)
            return ChatCommandOutcome(notices: await listSavedPlans())
        case let .delete(target):
            await presenter.presentSubmittedCommand(line)
            return ChatCommandOutcome(
                notices: await deleteSavedPlans(target: target, style: policy.planDelete)
            )
        case .status:
            await presenter.presentSubmittedCommand(line)
            return ChatCommandOutcome(notices: await planStatus(style: policy.planStatus))
        case .approve:
            await presenter.presentSubmittedCommand(line)
            guard planBrainstorming == nil, pendingPlanApprovalPlanID == nil else {
                return ChatCommandOutcome(notices: [.planDiscussionBlocksMutation])
            }
            guard let plan = activePlan,
                  !plan.consolidatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return ChatCommandOutcome(notices: [.planUnavailableForApproval])
            }
            guard commitCommandState(fence, { $0.pendingPlanApprovalPlanID = plan.id }) else {
                return Self.superseded
            }
            return ChatCommandOutcome(notices: [.planApprovalGoalPrompt])
        case .clear:
            await presenter.presentSubmittedCommand(line)
            return ChatCommandOutcome(
                notices: await clearActivePlan(fence: fence, style: policy.planClear)
            )
        case .missingGoal:
            return ChatCommandOutcome(notices: [.planMissingGoal])
        case let .start(goal):
            if policy.checksSubAgentToolGroup {
                guard isSubAgentToolEnabled else {
                    return ChatCommandOutcome(notices: [.subAgentToolsRequired(command: "/plan")])
                }
            }
            let plannerProfiles = plannerProfilesForDelegation()
            guard !plannerProfiles.isEmpty else {
                return ChatCommandOutcome(notices: [.agentRoleUnavailable(.planner)])
            }
            await presenter.presentSubmittedCommand(line)
            // A new goal abandons the previous collection and closes its author,
            // but the completed active plan remains until a fresh final plan is valid.
            await abandonPlanBrainstorming(closeAllPlanAuthors: true)
            guard commitCommandState(fence, { state in
                state.pendingPlanApprovalPlanID = nil
                state.planBrainstorming = PlanningCommandRuntimeState(goal: goal)
            }) else {
                return Self.superseded
            }
            return Self.commandTurn(
                PlanningCommandKernel.planStartPrompt(goal: goal, planners: plannerProfiles),
                purpose: .plan(originalGoal: goal)
            )
        }
    }

    /// `/plan status`: the open discussion, the Goal request, and the active
    /// plan projected from its task graph, which (in the terminal's
    /// sequence) becomes the active plan.
    private func planStatus(style: ChatPlanningCommandPolicy.Style) async -> [ChatSessionNotice] {
        var notices: [ChatSessionNotice] = []
        if let planBrainstorming {
            notices.append(.planClarificationActive(goal: planBrainstorming.goal))
        }
        if pendingPlanApprovalPlanID != nil {
            notices.append(.planAwaitingApprovalGoal)
        }
        guard let activePlan else {
            if planBrainstorming == nil || style == .acp {
                notices.append(.noActivePlan)
            }
            return notices
        }
        let graph = try? await runtime.taskGraphSnapshot(
            sessionID: sessionID,
            graphID: activePlan.id
        )
        let projectedPlan = graph.map {
            PlanningCommandKernel.plan(activePlan, applying: $0)
        } ?? activePlan
        if style == .terminal {
            self.activePlan = projectedPlan
        }
        notices.append(.planStatus(projectedPlan, graph: graph))
        return notices
    }

    /// `/plan clear`: drops the discussion and the Goal request, then the
    /// active plan, archiving its task graph in this session. The saved-plan
    /// library is left alone.
    private func clearActivePlan(
        fence: ChatCommandFence?,
        style: ChatPlanningCommandPolicy.Style
    ) async -> [ChatSessionNotice] {
        let hadDiscussion = planBrainstorming != nil
        await abandonPlanBrainstorming()
        if style == .terminal {
            commitCommandState(fence) { $0.pendingPlanApprovalPlanID = nil }
        }
        guard let plan = activePlan else {
            return [hadDiscussion ? .planDiscussionCleared : .noPlanToClear]
        }
        var generation: AgentCoreSessionRunner.SessionGeneration?
        if style == .acp {
            guard isCommandCurrent(fence) else {
                return []
            }
            guard let current = await runtime.currentSessionGeneration(for: sessionID) else {
                return [.runtimeSessionUnavailable]
            }
            generation = current
        }
        var previousGraph: TaskGraphSnapshot?
        do {
            previousGraph = try await runtime.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: plan.id
            )
            if previousGraph != nil {
                _ = try await requiredManagementRuntime().archiveTaskGraph(
                    id: plan.id,
                    sessionID: sessionID
                )
            }
        } catch {
            return [.operationFailed(description: error.localizedDescription)]
        }
        guard commitCommandState(fence, { state in
            state.activePlan = nil
            if style == .acp {
                state.pendingPlanApprovalPlanID = nil
            }
        }) else {
            await rollbackTaskGraph(previousGraph, graphID: plan.id, generation: generation)
            return []
        }
        return [.activePlanCleared]
    }

    /// Puts back the task graph a failed or superseded command replaced: the
    /// graph `graphID` is removed and `previousGraph` restored. With a
    /// `generation` (ACP), only while the runtime session is still that
    /// generation, so a recreated session is never touched.
    private func rollbackTaskGraph(
        _ previousGraph: TaskGraphSnapshot?,
        graphID: String,
        generation: AgentCoreSessionRunner.SessionGeneration?
    ) async {
        if let generation {
            guard await runtime.currentSessionGeneration(for: sessionID) == generation else {
                return
            }
        }
        if (try? await runtime.taskGraphSnapshot(
            sessionID: sessionID,
            graphID: graphID
        )) != nil {
            _ = try? await runtime.removeTaskGraph(
                id: graphID,
                sessionID: sessionID
            )
        }
        if let previousGraph {
            _ = try? await managementRuntime?.restoreTaskGraph(
                previousGraph,
                sessionID: sessionID
            )
        }
    }

    // MARK: - /plan approval

    /// Consumes the Goal requested by `/plan approve`. The reply is deliberately
    /// handled as control input: it is not submitted to the model and therefore
    /// cannot become part of a conversation checkpoint. `nil` when no Goal is
    /// requested or the reply is blank.
    func planApprovalGoalReplyAction(
        for reply: String,
        fence: ChatCommandFence? = nil,
        policy: ChatPlanningCommandPolicy = .terminal
    ) async -> ChatCommandOutcome? {
        guard let pendingPlanApprovalPlanID,
              let goal = reply.nilIfBlank else {
            return nil
        }
        let style = policy.approval
        guard let plan = activePlan, plan.id == pendingPlanApprovalPlanID else {
            if style == .acp {
                return ChatCommandOutcome(notices: [.noPendingPlanApproval])
            }
            commitCommandState(fence) { $0.pendingPlanApprovalPlanID = nil }
            return ChatCommandOutcome(notices: [.planUnavailableForApproval])
        }
        var generation: AgentCoreSessionRunner.SessionGeneration?
        if style == .acp {
            guard plan.consolidatedText.nilIfBlank != nil else {
                return ChatCommandOutcome(notices: [.planUnavailableForApproval])
            }
            guard let current = await runtime.currentSessionGeneration(for: sessionID) else {
                return ChatCommandOutcome(notices: [.runtimeSessionUnavailable])
            }
            generation = current
        }
        guard commitCommandState(fence, { $0.pendingPlanApprovalPlanID = nil }) else {
            return Self.superseded
        }
        return await approveActivePlan(
            plan,
            originalGoal: goal,
            fence: fence,
            style: style,
            generation: generation
        )
    }

    /// Creates (or keeps) the plan's task graph, activates it, and records the
    /// Goal in the saved-plan library copy; any failure restores the graph
    /// that was there before. On success the plan is approved and its
    /// implementation turn starts.
    private func approveActivePlan(
        _ sourcePlan: TerminalSessionPlan,
        originalGoal: String,
        fence: ChatCommandFence?,
        style: ChatPlanningCommandPolicy.Style,
        generation: AgentCoreSessionRunner.SessionGeneration?
    ) async -> ChatCommandOutcome {
        var plan = TerminalSessionPlan(
            id: sourcePlan.id,
            originalGoal: originalGoal,
            consolidatedText: sourcePlan.consolidatedText,
            createdAt: sourcePlan.createdAt,
            isApproved: sourcePlan.isApproved,
            points: sourcePlan.points
        )
        // ACP makes the plan the approved active plan before it records the
        // Goal, so a superseded approval never reaches the library.
        let recordsGoalAfterApproval = style == .acp
        var previousGraph: TaskGraphSnapshot?
        var graphWasMutated = false
        let managementRuntime: any ChatSessionManagementRuntime
        do {
            managementRuntime = try requiredManagementRuntime()
            plan = PlanningCommandKernel.planMaterializedForApproval(plan)
            // The task graph is created exclusively at approval time so that
            // changes made to the plan before approval are always reflected.
            previousGraph = try await runtime.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: plan.id
            )
            if !plan.isApproved || previousGraph == nil || previousGraph?.tasks.isEmpty == true {
                if previousGraph != nil {
                    graphWasMutated = true
                    _ = try await runtime.removeTaskGraph(
                        id: plan.id,
                        sessionID: sessionID
                    )
                }
                if style == .acp {
                    // ACP rolls back a creation that failed like any other change.
                    graphWasMutated = true
                }
                _ = try await runtime.taskOrchestrator.createGraph(
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
            _ = try await managementRuntime.activateTaskGraph(
                id: plan.id,
                sessionID: sessionID
            )
            if !recordsGoalAfterApproval {
                // Keep the project-library copy authoritative only after the
                // active graph is valid. A persistence failure is handled by the
                // same rollback path so `/plan list` and the active plan cannot
                // disagree about the Goal.
                try await persistSavedPlanGoal(plan, on: managementRuntime)
            }
        } catch {
            if graphWasMutated {
                await rollbackTaskGraph(previousGraph, graphID: plan.id, generation: generation)
            }
            return ChatCommandOutcome(notices: [.operationFailed(description: error.localizedDescription)])
        }
        plan.isApproved = true
        let approvedPlan = plan
        guard commitCommandState(fence, { state in
            state.activePlan = approvedPlan
            state.pendingPlanApprovalPlanID = nil
        }) else {
            await rollbackTaskGraph(previousGraph, graphID: plan.id, generation: generation)
            return Self.superseded
        }
        if recordsGoalAfterApproval {
            do {
                try await persistSavedPlanGoal(plan, on: managementRuntime)
            } catch {
                await rollbackTaskGraph(previousGraph, graphID: plan.id, generation: generation)
                commitCommandState(fence) { $0.activePlan = sourcePlan }
                return ChatCommandOutcome(notices: [.operationFailed(description: error.localizedDescription)])
            }
        }
        // A loaded plan can be the first turn in a new session. Lock the
        // configured/system response language before its internal English
        // implementation prompt is sent to the model.
        channelHooks?.responseLanguageShouldLock()
        return ChatCommandOutcome(
            notices: [.planApproved],
            action: .startTurn(
                prompt: PlanningCommandKernel.planImplementationPrompt(for: plan),
                purpose: .normal,
                locksResponseLanguage: false
            )
        )
    }

    /// Rewrites the saved-plan library copy of `plan`, if the library holds
    /// one, with the approved Goal.
    private func persistSavedPlanGoal(
        _ plan: TerminalSessionPlan,
        on managementRuntime: any ChatSessionManagementRuntime
    ) async throws {
        let savedPlans = await managementRuntime.savedTaskPlans(
            workingDirectory: workingDirectory
        )
        guard let saved = savedPlans.first(where: { $0.graph.id == plan.id }) else {
            return
        }
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: workingDirectory
        )
        let storedPlan = PlanningCommandKernel.planPreparedForSaving(plan)
        let savedCopy = TaskGraphSavedPlan(
            plan: storedPlan,
            savedAt: saved.snapshot.savedAt,
            savingAgentID: saved.snapshot.savingAgentID,
            savingAgentName: saved.snapshot.savingAgentName
        )
        try await runtime.taskOrchestrator.registerSession(
            id: librarySessionID,
            workingDirectory: workingDirectory
        )
        _ = try await runtime.taskOrchestrator.savePlanDraft(
            savedCopy,
            sessionID: librarySessionID,
            tasks: PlanningCommandKernel.taskDefinitions(for: storedPlan.points)
        )
    }

    // MARK: - Saved-plan library

    /// `/plan save`: stores the active plan, or the latest plan an agent
    /// wrote, in the project's saved-plan library and makes it the active
    /// plan.
    private func saveReusablePlan(
        fence: ChatCommandFence?,
        source: ChatPlanningCommandPolicy.PlanSave,
        savedAt: Date = Date()
    ) async -> [ChatSessionNotice] {
        let candidate: TerminalSessionPlan?
        let savingAgent: AgentProfile?
        switch source {
        case .terminal:
            candidate = reusablePlanCandidate(createdAt: savedAt)
            savingAgent = selection.agent
        case let .acp(agent, fallbackHistory):
            let snapshot = await runtime.snapshotSession(id: sessionID)
            let plan = activePlan ?? PlanningCommandKernel.planFromLatestAssistantMessage(
                in: snapshot?.history ?? fallbackHistory,
                createdAt: savedAt
            )
            candidate = plan?.consolidatedText.nilIfBlank != nil ? plan : nil
            savingAgent = agent
        }
        guard let plan = candidate else {
            return [.planUnavailableForSaving]
        }

        let storedPlan = PlanningCommandKernel.planPreparedForSaving(plan)
        let savedPlan = TaskGraphSavedPlan(
            plan: storedPlan,
            savedAt: savedAt,
            savingAgentID: savingAgent?.id,
            savingAgentName: savingAgent?.name
        )
        let librarySessionID = SessionTaskOrchestrator.savedPlanLibrarySessionID(
            for: workingDirectory
        )
        do {
            try await runtime.taskOrchestrator.registerSession(
                id: librarySessionID,
                workingDirectory: workingDirectory
            )
            _ = try await runtime.taskOrchestrator.savePlanDraft(
                savedPlan,
                sessionID: librarySessionID,
                tasks: PlanningCommandKernel.taskDefinitions(for: storedPlan.points)
            )
        } catch {
            return [.operationFailed(description: error.localizedDescription)]
        }

        guard commitCommandState(fence, { $0.activePlan = plan }) else {
            return []
        }
        return [.planSaved(planID: plan.id)]
    }

    /// The plan `/plan save` stores: the active plan when it has a goal and a
    /// text, otherwise the latest plan in the transcript, then in the history.
    func reusablePlanCandidate(createdAt: Date = Date()) -> TerminalSessionPlan? {
        if let activePlan,
           activePlan.originalGoal.nilIfBlank != nil,
           activePlan.consolidatedText.nilIfBlank != nil {
            return activePlan
        }
        if let plan = PlanningCommandKernel.planFromLatestAssistantMessage(
            in: transcript,
            createdAt: createdAt
        ) {
            return plan
        }
        return PlanningCommandKernel.planFromLatestAssistantMessage(
            in: history,
            createdAt: createdAt
        )
    }

    /// `/plan load`: makes the newest reusable saved plan the unapproved
    /// active plan and adds it to the session context.
    private func loadReusablePlan(
        fence: ChatCommandFence?,
        source: ChatPlanningCommandPolicy.PlanLoad
    ) async -> [ChatSessionNotice] {
        var generation: AgentCoreSessionRunner.SessionGeneration?
        if case .acp = source {
            guard let current = await runtime.currentSessionGeneration(for: sessionID) else {
                return [.runtimeSessionUnavailable]
            }
            generation = current
        }
        guard activePlan == nil else {
            return [.activePlanAlreadyExists]
        }
        let savedPlans = await managementRuntime?.savedTaskPlans(
            workingDirectory: workingDirectory
        ) ?? []
        guard !savedPlans.isEmpty else {
            return [.savedPlanUnavailable]
        }
        guard let savedPlan = PlanningCommandKernel.loadableSavedPlan(from: savedPlans) else {
            return [.savedPlansAllCompleted]
        }

        let plan = PlanningCommandKernel.planPreparedForReuse(savedPlan)
        let contextMessage = AgentRuntimeMessage(
            role: .user,
            content: PlanningCommandKernel.savedPlanContextMessage(savedPlan, plan: plan)
        )

        switch source {
        case .terminal:
            let replacementHistory = history + [contextMessage]
            if await runtime.snapshotSession(id: sessionID) != nil {
                guard await replaceRuntimeSessionHistory(replacementHistory) else {
                    return [.savedPlanContextNotAdded]
                }
            }

            history = replacementHistory
            appendTranscript(contextMessage)
            guard commitCommandState(fence, { $0.activePlan = plan }) else {
                return []
            }
            return [.savedPlanLoaded(plan)]
        case let .acp(fallbackHistory):
            guard let generation else {
                return [.runtimeSessionUnavailable]
            }
            let baseHistory = (await runtime.snapshotSession(id: sessionID))?.history
                ?? fallbackHistory
            let replacementHistory = baseHistory + [contextMessage]
            guard isCommandCurrent(fence) else {
                return []
            }
            guard await runtime.replaceSessionHistory(
                id: sessionID,
                history: replacementHistory,
                expectedSessionGeneration: generation
            ) else {
                return [.savedPlanContextNotAdded]
            }
            guard commitCommandState(fence, { $0.activePlan = plan }) else {
                // Superseded after the replacement: put the history back while
                // the replacement is still the installed one.
                if let installed = await runtime.snapshotSession(id: sessionID),
                   installed.history == replacementHistory {
                    _ = await runtime.replaceSessionHistory(
                        id: sessionID,
                        history: baseHistory,
                        expectedSessionGeneration: generation
                    )
                }
                return []
            }
            return [.savedPlanLoaded(plan)]
        }
    }

    /// Replaces the conversation of the runtime session at its current
    /// generation; `false` when the session has none or the replacement fails.
    private func replaceRuntimeSessionHistory(_ history: [AgentRuntimeMessage]) async -> Bool {
        guard let generation = await runtime.currentSessionGeneration(for: sessionID) else {
            return false
        }
        return await runtime.replaceSessionHistory(
            id: sessionID,
            history: history,
            expectedSessionGeneration: generation
        )
    }

    /// `/plan list`: every saved plan for this project, newest save first,
    /// including entries that were already mirrored as completed so the
    /// library stays inspectable.
    private func listSavedPlans() async -> [ChatSessionNotice] {
        let savedPlans = await managementRuntime?.savedTaskPlans(
            workingDirectory: workingDirectory
        ) ?? []
        guard !savedPlans.isEmpty else {
            return [.noSavedPlans]
        }
        return [.savedPlans(savedPlans)]
    }

    /// `/plan delete`: deletes saved plans from the project library. The
    /// target can be a full plan id, a unique id prefix, or `all`; the parser
    /// hands it over trimmed, `nil` when the command names none. The active
    /// plan of the session and its live task graph are never touched here:
    /// that is `/plan clear`'s session-scoped role.
    private func deleteSavedPlans(
        target: String?,
        style: ChatPlanningCommandPolicy.Style
    ) async -> [ChatSessionNotice] {
        if style == .acp, target == nil {
            return [.planDeleteUsage]
        }
        let savedPlans = await managementRuntime?.savedTaskPlans(
            workingDirectory: workingDirectory
        ) ?? []
        guard !savedPlans.isEmpty else {
            return [.savedPlanUnavailable]
        }
        guard let target else {
            return [.planDeleteUsage]
        }
        switch PlanningCommandKernel.savedPlanDeletionTarget(
            target,
            in: savedPlans.map(\.graph.id)
        ) {
        case .notFound:
            return [.savedPlanNotFound(availablePlanIDs: savedPlans.map(\.graph.id))]
        case let .ambiguous(matches):
            return [.savedPlanAmbiguous(matches: matches)]
        case let .ids(planIDs):
            do {
                let deletedPlanIDs = try await requiredManagementRuntime().deleteSavedTaskPlans(
                    planIDs: planIDs,
                    workingDirectory: workingDirectory
                )
                return [
                    .savedPlansDeleted(
                        planIDs: deletedPlanIDs,
                        activePlanAffected: activePlan.map { planIDs.contains($0.id) } ?? false
                    ),
                ]
            } catch {
                return [.operationFailed(description: error.localizedDescription)]
            }
        }
    }

    // MARK: - Planner replies

    /// Routes plain text received while the Planner is collecting decisions.
    /// When no Planner is visible to the project any longer, the reply is not
    /// recorded so it can be sent again after `/agents`. `nil` when no
    /// Planner question is open.
    func planBrainstormingReplyAction(
        for reply: String,
        fence: ChatCommandFence? = nil
    ) async -> ChatCommandOutcome? {
        guard var brainstorming = planBrainstorming,
              brainstorming.recordReply(reply) else {
            return nil
        }
        let planners = plannerProfilesForDelegation()
        guard !planners.isEmpty else {
            return ChatCommandOutcome(notices: [.agentRoleUnavailable(.planner)])
        }
        let recordedDiscussion = brainstorming
        guard commitCommandState(fence, { $0.planBrainstorming = recordedDiscussion }) else {
            return Self.superseded
        }
        return Self.commandTurn(
            PlanningCommandKernel.planContinuationPrompt(
                state: brainstorming,
                planners: planners
            ),
            purpose: .plan(originalGoal: brainstorming.goal)
        )
    }

    // MARK: - /goal

    /// `/goal <goal>`: creates the workflow task graph and starts the
    /// workflow turn.
    func runGoalCommand(
        line: String,
        fence: ChatCommandFence? = nil
    ) async -> ChatCommandOutcome {
        guard case let .goal(argument) = CoordinatorCommandParser.parse(line) else {
            return ChatCommandOutcome(notices: [.workflowMissingGoal])
        }

        guard !argument.isEmpty else {
            return ChatCommandOutcome(notices: [.workflowMissingGoal])
        }

        guard activePlan == nil, planBrainstorming == nil else {
            return ChatCommandOutcome(notices: [.workflowBlockedByPlan])
        }

        // The orchestrator refuses to create a graph while the current one is an
        // unfinished workflow graph. Answer that with a user-facing explanation
        // instead of leaking `graphNotMutable` from the runtime.
        if let existing = await currentWorkflowGraph(sessionID: sessionID) {
            return ChatCommandOutcome(notices: [
                .workflowAlreadyActive(
                    graphID: existing.id,
                    pendingTaskCount: Self.openTaskCount(in: existing)
                ),
            ])
        }

        // A superseded command creates no graph.
        guard isCommandCurrent(fence) else {
            return Self.superseded
        }
        let graphSessionID = sessionID
        let graphID = "workflow_\(UUID().uuidString.lowercased())"
        do {
            _ = try await runtime.taskOrchestrator.createGraph(
                sessionID: graphSessionID,
                id: graphID,
                source: .workflow,
                state: .active,
                tasks: [],
                originalGoal: argument
            )
        } catch {
            return ChatCommandOutcome(notices: [.operationFailed(description: error.localizedDescription)])
        }

        await presenter.presentSubmittedCommand(line)
        guard commitCommandState(fence, {
            $0.activeWorkflow = WorkflowCommandRuntimeState(goal: argument, graphID: graphID)
        }) else {
            // Superseded after the graph was created: remove it again.
            _ = try? await runtime.removeTaskGraph(id: graphID, sessionID: graphSessionID)
            return Self.superseded
        }

        return Self.commandTurn(
            PlanningCommandKernel.workflowPrompt(goal: argument, graphID: graphID),
            purpose: .workflow(originalGoal: argument, graphID: graphID)
        )
    }

    /// Routes plain text typed while a workflow graph is still open and the
    /// coordinator ended its last turn without finishing the goal — typically
    /// after a clarification question. `nil` when no workflow is waiting for
    /// the operator.
    func workflowContinuationReplyAction(
        for reply: String,
        fence: ChatCommandFence? = nil,
        policy: ChatPlanningCommandPolicy = .terminal
    ) async -> ChatCommandOutcome? {
        guard var workflow = activeWorkflow, workflow.isAwaitingReply else { return nil }
        // The graph may have been cleared, archived, completed or replaced since
        // the workflow turn ended. Never resume a graph that is no longer the
        // session's open workflow graph.
        guard let graph = await currentWorkflowGraph(sessionID: sessionID),
              graph.id == workflow.graphID else {
            commitCommandState(fence) { $0.activeWorkflow = nil }
            return nil
        }
        guard workflow.recordReply(reply) else { return nil }
        let style = policy.workflowReply
        let continuationSessionID = sessionID
        let previousWorkflow = activeWorkflow
        var generation: AgentCoreSessionRunner.SessionGeneration?
        if style == .acp {
            generation = await runtime.currentSessionGeneration(for: continuationSessionID)
            // ACP does not resume once its task is cancelled.
            guard !Task.isCancelled else { return nil }
            guard isCommandCurrent(fence) else { return Self.superseded }
        }
        do {
            let resumedGraph = try await runtime.taskOrchestrator.resumeWorkflow(
                sessionID: continuationSessionID, expectedGraph: graph
            )
            let resumedWorkflow = workflow
            let committed = !Task.isCancelled
                && sessionID == continuationSessionID
                && stateStore.withLock { state in
                    guard fence.map({ state.activeTurnToken == $0.token }) ?? true,
                          state.commandState.activeWorkflow == previousWorkflow else {
                        return false
                    }
                    state.commandState.activeWorkflow = resumedWorkflow
                    return true
                }
            guard committed else {
                if style == .terminal {
                    try? await runtime.taskOrchestrator.rollbackWorkflowResume(
                        sessionID: continuationSessionID, previousGraph: graph, resumedGraph: resumedGraph
                    )
                } else if let generation,
                          await runtime.currentSessionGeneration(for: continuationSessionID) == generation {
                    try? await runtime.taskOrchestrator.rollbackWorkflowResume(
                        sessionID: continuationSessionID, previousGraph: graph, resumedGraph: resumedGraph
                    )
                }
                return ChatCommandOutcome()
            }
        } catch {
            return ChatCommandOutcome(notices: [.operationFailed(description: error.localizedDescription)])
        }

        return Self.commandTurn(
            PlanningCommandKernel.workflowContinuationPrompt(
                state: workflow,
                pendingTaskCount: Self.openTaskCount(in: graph),
                totalTaskCount: graph.tasks.count
            ),
            purpose: .workflow(originalGoal: workflow.goal, graphID: workflow.graphID)
        )
    }

    // MARK: - Pending replies

    /// Routes a plain line to the conversation that is explicitly waiting for
    /// the operator, in this order: the Goal for `/plan approve`, then an open
    /// Planner question, then a `/goal` workflow awaiting the user. `nil` when
    /// nothing is waiting, so the line is an ordinary prompt.
    ///
    /// The channel routes slash commands and live mentions before calling it:
    /// neither is ever absorbed as a reply.
    func pendingReplyAction(
        for reply: String,
        fence: ChatCommandFence? = nil,
        policy: ChatPlanningCommandPolicy = .terminal
    ) async -> ChatCommandOutcome? {
        if let outcome = await planApprovalGoalReplyAction(for: reply, fence: fence, policy: policy) {
            return outcome
        }
        if let outcome = await planBrainstormingReplyAction(for: reply, fence: fence) {
            return outcome
        }
        return await workflowContinuationReplyAction(for: reply, fence: fence, policy: policy)
    }

    // MARK: - /review

    /// `/review [scope]`: delegates a review of the tracked file changes, the
    /// approved plan, and the task graph to Reviewer sub-agents.
    func runReviewCommand(
        line: String,
        fence: ChatCommandFence? = nil,
        policy: ChatPlanningCommandPolicy = .terminal
    ) async -> ChatCommandOutcome {
        let argument = ChatCommandRegistry.arguments(
            from: line,
            commandPrefix: "/review"
        )

        if policy.checksSubAgentToolGroup {
            guard isSubAgentToolEnabled else {
                return ChatCommandOutcome(notices: [.subAgentToolsRequired(command: "/review")])
            }
        }

        switch policy.review {
        case .terminal:
            let approvedPlan = activePlan.flatMap {
                $0.isApproved && !$0.consolidatedText.isEmpty ? $0 : nil
            }
            let taskGraph = try? await runtime.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: approvedPlan?.id
            )
            guard lastFileChangeSummary != nil || approvedPlan != nil || taskGraph != nil else {
                return ChatCommandOutcome(notices: [.noChangesToReview])
            }

            let reviewerProfiles = reviewerProfilesForDelegation()
            guard !reviewerProfiles.isEmpty else {
                return ChatCommandOutcome(notices: [.agentRoleUnavailable(.reviewer)])
            }

            await presenter.presentSubmittedCommand(line)

            return Self.commandTurn(
                PlanningCommandKernel.reviewDelegationPrompt(
                    scope: argument,
                    reviewers: reviewerProfiles,
                    changeSummary: lastFileChangeSummary,
                    approvedPlan: approvedPlan,
                    taskGraph: taskGraph
                ),
                purpose: .review
            )
        case let .acp(prompt):
            let reviewerProfiles = reviewerProfilesForDelegation()
            guard !reviewerProfiles.isEmpty else {
                return ChatCommandOutcome(notices: [.agentRoleUnavailable(.reviewer)])
            }
            let approvedPlan = activePlan.flatMap {
                $0.isApproved && $0.consolidatedText.nilIfBlank != nil ? $0 : nil
            }
            let taskGraph = try? await runtime.taskGraphSnapshot(
                sessionID: sessionID,
                graphID: approvedPlan?.id
            )
            let scope: String
            if case let .review(parsedScope) = CoordinatorCommandParser.parse(line) {
                scope = parsedScope
            } else {
                scope = argument
            }
            await presenter.presentSubmittedCommand(line)
            return Self.commandTurn(
                prompt(
                    ChatReviewPromptRequest(
                        scope: scope,
                        reviewers: reviewerProfiles,
                        approvedPlan: approvedPlan,
                        taskGraph: taskGraph
                    )
                ),
                purpose: .review
            )
        }
    }
}
