//
//  ChatSessionController+PlanLifecycle.swift
//  ZenCODE
//
//  The `/plan` lifecycle: start, status, approval, and clear, with the
//  replies the Planner and the approval wait for.
//

import Foundation
import ToolCore

extension ChatSessionController {
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
            await effectivePresenter(for: nil).presentSubmittedCommand(line)
            guard planBrainstorming == nil, pendingPlanApprovalPlanID == nil else {
                return ChatCommandOutcome(notices: [.planDiscussionBlocksMutation])
            }
            return ChatCommandOutcome(
                notices: await saveReusablePlan(fence: fence, source: policy.planSave)
            )
        case .load:
            await effectivePresenter(for: nil).presentSubmittedCommand(line)
            guard planBrainstorming == nil, pendingPlanApprovalPlanID == nil else {
                return ChatCommandOutcome(notices: [.planDiscussionBlocksMutation])
            }
            return ChatCommandOutcome(
                notices: await loadReusablePlan(fence: fence, source: policy.planLoad)
            )
        case .list:
            await effectivePresenter(for: nil).presentSubmittedCommand(line)
            return ChatCommandOutcome(notices: await listSavedPlans())
        case let .delete(target):
            await effectivePresenter(for: nil).presentSubmittedCommand(line)
            return ChatCommandOutcome(
                notices: await deleteSavedPlans(target: target, style: policy.planDelete)
            )
        case .status:
            await effectivePresenter(for: nil).presentSubmittedCommand(line)
            return ChatCommandOutcome(notices: await planStatus(style: policy.planStatus))
        case .approve:
            await effectivePresenter(for: nil).presentSubmittedCommand(line)
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
            await effectivePresenter(for: nil).presentSubmittedCommand(line)
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
            await effectivePresenter(for: nil).presentSubmittedCommand(line)
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

    /// `/plan status`: the open discussion, the Goal request, the active
    /// plan projected from its task graph, which (in the terminal's
    /// sequence) becomes the active plan, and the plans queued after it.
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
        let queue = queuedPlans
        if !queue.isEmpty {
            notices.append(.queuedPlans(queue))
        }
        return notices
    }

    /// `/plan clear`: drops the discussion and the Goal request, then the
    /// active plan and its queued plans, archiving the active plan's task
    /// graph in this session. The saved-plan library is left alone.
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
            state.queuedPlans = []
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
}
