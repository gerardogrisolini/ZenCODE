//
//  ChatSessionController+Planning.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

extension ChatSessionController {
    // MARK: - Planning

    /// Records a structured plan (with task points) as the active plan **without**
    /// creating its task graph. The graph is created exclusively at plan approval,
    /// so changing the plan before approval always produces a graph that matches
    /// the final approved points.
    @discardableResult
    func recordStructuredPlan(
        responseText: String,
        originalGoal: String,
        createdAt: Date = Date(),
        points: [TerminalSessionPlanPoint]
    ) throws(ChatPlanGenerationError) -> Bool {
        guard let plan = try Self.structuredPlan(
            responseText: responseText,
            originalGoal: originalGoal,
            createdAt: createdAt,
            points: points
        ) else {
            return false
        }
        commandState.activePlan = plan
        return true
    }

    /// The unapproved plan a Planner response records, or `nil` when the
    /// response has no text.
    nonisolated static func structuredPlan(
        responseText: String,
        originalGoal: String,
        createdAt: Date = Date(),
        points: [TerminalSessionPlanPoint]
    ) throws(ChatPlanGenerationError) -> TerminalSessionPlan? {
        let consolidatedText = responseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !consolidatedText.isEmpty else {
            return nil
        }
        guard !points.isEmpty else {
            throw ChatPlanGenerationError.structuredTasksUnavailable
        }
        return TerminalSessionPlan(
            id: PlanningCommandKernel.planID(from: points),
            originalGoal: originalGoal,
            consolidatedText: consolidatedText,
            createdAt: createdAt,
            isApproved: false,
            points: points
        )
    }

    /// Clears the planning discussion and closes the Planner agents that
    /// authored it. `expectedCollectionID` limits the clear to one discussion.
    func abandonPlanBrainstorming(
        closeAllPlanAuthors: Bool = false,
        expectedCollectionID: UUID? = nil
    ) async {
        let cleared: (didClear: Bool, state: PlanningCommandRuntimeState?) = stateStore.withLock { store in
            let state = store.commandState.planBrainstorming
            if let expectedCollectionID, state?.collectionID != expectedCollectionID {
                return (false, nil)
            }
            store.commandState.planBrainstorming = nil
            return (true, state)
        }
        guard cleared.didClear else { return }
        let state = cleared.state
        var agentIDs = Set<String>()
        if let plannerAgentID = state?.plannerAgentID {
            agentIDs.insert(plannerAgentID)
        }
        if closeAllPlanAuthors || (state != nil && agentIDs.isEmpty) {
            let snapshots = await runtime.subAgentSnapshots()
            agentIDs.formUnion(
                PlanningCommandKernel.plannerSnapshots(
                    snapshots,
                    rootSessionID: sessionID
                ).map(\.id)
            )
        }
        for agentID in agentIDs {
            _ = await runtime.closeSubAgent(id: agentID)
        }
    }

    /// Replaces the coordinator output of a `/plan` turn with the Planner's
    /// fresh output, records either the clarification or the structured plan,
    /// and returns the Planner response.
    func finalizePlanningTurn(
        parentResponse: DirectAgentResponse,
        originalGoal: String,
        baseline: PlannerTurnBaseline?,
        collectionID: UUID?,
        collector: PlanningPointCollector,
        transcriptTurn: ChatTranscriptTurn,
        observedHistory: [AgentRuntimeMessage]?,
        token: UUID,
        turnSessionID: String
    ) async throws -> DirectAgentResponse {
        guard let baseline,
              let plannerResult = PlanningCommandKernel.plannerResponse(
                  parentResponse: parentResponse,
                  snapshots: await runtime.subAgentSnapshots(),
                  baseline: baseline,
                  rootSessionID: turnSessionID
              ) else {
            throw ChatPlanGenerationError.plannerOutputUnavailable
        }
        guard let collectionID,
              isCurrentTurn(token, sessionID: turnSessionID),
              var brainstorming = commandState.planBrainstorming,
              brainstorming.collectionID == collectionID else {
            throw CancellationError()
        }
        brainstorming.recordPlannerOutput(
            plannerResult.response.text,
            agentID: plannerResult.snapshot.id,
            revision: plannerResult.snapshot.latestOutputRevision
        )
        let response = plannerResult.response
        let isQuestion = PlanningCommandKernel.isPlannerQuestionResponse(response.text)
        let plannerPoints: [TerminalSessionPlanPoint]
        if isQuestion {
            guard !(await collector.hasObservedTodoWrites()) else {
                throw ChatPlanGenerationError.unexpectedStructuredTasksForQuestions
            }
            plannerPoints = []
        } else {
            guard let finalPoints = await collector.finalPlanPoints(
                forFinalText: response.text
            ) else {
                throw ChatPlanGenerationError.structuredTasksUnavailable
            }
            plannerPoints = finalPoints
        }
        guard let generation = await runtime.currentSessionGeneration(for: turnSessionID) else {
            throw ChatPlanGenerationError.sessionHistoryUnavailable
        }
        let historyBeforePlannerCorrection: [AgentRuntimeMessage]
        if let observedHistory {
            historyBeforePlannerCorrection = observedHistory
        } else if let snapshot = await runtime.snapshotSession(id: turnSessionID) {
            historyBeforePlannerCorrection = snapshot.history
        } else {
            historyBeforePlannerCorrection = history
        }
        let correctedPlanningHistory = PlanningCommandKernel.historyByReplacingCoordinatorOutput(
            historyBeforePlannerCorrection,
            with: response.text
        )
        guard await runtime.replaceSessionHistory(
            id: turnSessionID,
            history: correctedPlanningHistory,
            expectedSessionGeneration: generation
        ) else {
            throw ChatPlanGenerationError.sessionHistoryUnavailable
        }
        guard isCurrentTurn(token, sessionID: turnSessionID),
              commandState.planBrainstorming?.collectionID == collectionID else {
            // Cancellation may race the runtime suspension above. Roll back only
            // if no newer turn has changed the history, so an obsolete Planner
            // output can neither survive cancellation nor clobber fresh work.
            if let installed = await runtime.snapshotSession(id: turnSessionID),
               installed.history == correctedPlanningHistory {
                _ = await runtime.replaceSessionHistory(
                    id: turnSessionID,
                    history: historyBeforePlannerCorrection,
                    expectedSessionGeneration: generation
                )
            }
            throw CancellationError()
        }
        history = correctedPlanningHistory
        let structuredPlan = isQuestion
            ? nil
            : try Self.structuredPlan(
                responseText: response.text,
                originalGoal: originalGoal,
                points: plannerPoints
            )
        let recordedBrainstorming = brainstorming
        let didCommit = stateStore.withLock { state in
            guard state.activeTurnToken == token,
                  state.commandState.planBrainstorming?.collectionID == collectionID else {
                return false
            }
            if isQuestion {
                state.commandState.planBrainstorming = recordedBrainstorming
            } else {
                if let structuredPlan {
                    state.commandState.activePlan = structuredPlan
                }
                state.commandState.planBrainstorming = nil
            }
            return true
        }
        guard didCommit else {
            throw CancellationError()
        }
        await transcriptTurn.appendAssistantContent(response.text)
        return response
    }

    // MARK: - Plan progress

    /// Applies legacy `todo.write` progress to the approved plan. Returns `true`
    /// when this update completed the plan.
    @discardableResult
    func synchronizeActivePlanStatus(
        from toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> Bool {
        guard !result.isFailure,
              let update = PlanningCommandKernel.planPointUpdates(from: toolCall) else {
            return false
        }
        let updatesByID = Dictionary(
            update.points.map { ($0.id, $0.status) },
            uniquingKeysWith: { _, latest in latest }
        )
        return stateStore.withLock { state in
            guard var plan = state.commandState.activePlan,
                  plan.isApproved,
                  !plan.points.isEmpty else {
                return false
            }
            let wasCompleted = plan.isCompleted
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
            state.commandState.activePlan = plan
            return !wasCompleted && plan.isCompleted
        }
    }

    /// Mirrors legacy `todo.write` progress onto the approved plan's task graph.
    func synchronizeTaskGraphFromLegacyTodo(
        toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) async {
        guard !result.isFailure,
              let plan = commandState.activePlan,
              plan.isApproved,
              let update = PlanningCommandKernel.planPointUpdates(from: toolCall) else {
            return
        }
        let orchestrator = runtime.taskOrchestrator
        for point in update.points {
            guard var view = try? await orchestrator.task(
                sessionID: sessionID,
                taskID: point.id,
                graphID: plan.id
            ) else { continue }
            switch point.status {
            case .pending:
                if view.task.status == .failed || view.task.status == .blocked {
                    view = (try? await orchestrator.retryTask(
                        sessionID: sessionID,
                        taskID: point.id,
                        graphID: plan.id
                    )) ?? view
                }
            case .inProgress:
                if view.task.status == .pending {
                    view = (try? await orchestrator.updateTask(
                        sessionID: sessionID,
                        taskID: point.id,
                        graphID: plan.id,
                        update: TaskUpdate(status: .inProgress)
                    )) ?? view
                }
            case .completed:
                if view.task.status == .pending {
                    view = (try? await orchestrator.updateTask(
                        sessionID: sessionID,
                        taskID: point.id,
                        graphID: plan.id,
                        update: TaskUpdate(status: .inProgress)
                    )) ?? view
                }
                if view.task.status == .inProgress {
                    _ = try? await orchestrator.updateTask(
                        sessionID: sessionID,
                        taskID: point.id,
                        graphID: plan.id,
                        update: TaskUpdate(status: .completed)
                    )
                } else if view.task.status == .awaitingValidation {
                    _ = try? await orchestrator.validateTaskResult(
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
                    _ = try? await orchestrator.updateTask(
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

    /// Collects plan points and plan progress from a completed tool call.
    func recordPlanProgress(
        toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult,
        turn: ChatTurnContext
    ) async {
        let planPointUpdate = result.isFailure
            ? nil
            : PlanningCommandKernel.planPointUpdates(from: toolCall)
        switch turn.purpose {
        case .plan:
            let request = DirectTodoTaskRuntime.normalizedToolRequest(for: toolCall)
            if request.name == "todo.write" {
                await turn.collector.recordTodoWrite(planPointUpdate)
            }
        case .normal:
            if planPointUpdate != nil, turn.isCurrent(in: self) {
                if synchronizeActivePlanStatus(from: toolCall, result: result),
                   let plan = commandState.activePlan {
                    await turn.collector.recordAutomaticCompletion(plan)
                }
                await synchronizeTaskGraphFromLegacyTodo(
                    toolCall: toolCall,
                    result: result
                )
            }
        case .review, .workflow:
            break
        }
        if !result.isFailure,
           DirectTaskToolAdapter.isTaskToolName(toolCall.name),
           let currentPlan = commandState.activePlan,
           let graph = try? await runtime.taskGraphSnapshot(
               sessionID: sessionID,
               graphID: currentPlan.id
           ) {
            let wasCompleted = currentPlan.isCompleted
            let projected = PlanningCommandKernel.plan(currentPlan, applying: graph)
            let didProject = updateCommandStateIfCurrent(turn.token, sessionID: turn.sessionID) { state in
                state.activePlan = projected
            }
            if didProject, !wasCompleted && projected.isCompleted {
                await turn.collector.recordAutomaticCompletion(projected)
            }
        }
    }

    // MARK: - Workflows

    /// Projects the authoritative workflow pause after a `/goal` turn. New
    /// workflows never infer control state from prose. A finished or vanished
    /// graph clears the transient projection instead.
    func recordWorkflowTurnOutcome(
        graphID: String,
        coordinatorMessage: String?,
        token: UUID? = nil,
        turnSessionID: String? = nil,
        presenter turnPresenter: (any ChatSessionPresenter)? = nil
    ) async {
        let presenter = turnPresenter ?? self.presenter
        let turnSessionID = turnSessionID ?? sessionID
        guard commandState.activeWorkflow?.graphID == graphID else { return }
        let graph = await currentWorkflowGraph(sessionID: turnSessionID)
        guard sessionID == turnSessionID else { return }
        // `nil`: nothing recorded; `false`: recorded without arming; `true`: armed.
        let recorded: Bool? = stateStore.withLock { state in
            guard token == nil || state.activeTurnToken == token,
                  var workflow = state.commandState.activeWorkflow,
                  workflow.graphID == graphID else { return nil }
            guard let graph, graph.id == graphID else {
                state.commandState.activeWorkflow = nil
                return nil
            }
            let didArm = workflow.recordCoordinatorOutput(coordinatorMessage, graph: graph)
            state.commandState.activeWorkflow = workflow
            return didArm
        }
        guard let didArm = recorded, let graph else { return }
        let pendingTaskCount = Self.openTaskCount(in: graph)
        guard didArm else {
            await presenter.presentWorkflowNotice(
                .openWithoutQuestion(graphID: graph.id, pendingTaskCount: pendingTaskCount)
            )
            return
        }
        if graph.workflow?.state == .blocked {
            await presenter.presentWorkflowNotice(
                .blocked(graphID: graph.id, message: graph.workflow?.message ?? "")
            )
            return
        }
        await presenter.presentWorkflowNotice(
            .awaitingReply(graphID: graph.id, pendingTaskCount: pendingTaskCount)
        )
    }

    /// Handles a workflow turn that failed or was cancelled.
    ///
    /// Legacy empty graphs may be dropped; persisted workflow metadata retains
    /// the objective even before delegation. Structured pauses take precedence
    /// over the transient failure signal.
    func handleFailedWorkflowTurn(
        graphID: String,
        reason: String,
        token: UUID? = nil,
        turnSessionID: String? = nil,
        presenter turnPresenter: (any ChatSessionPresenter)? = nil
    ) async {
        let presenter = turnPresenter ?? self.presenter
        let turnSessionID = turnSessionID ?? sessionID
        let graph = await currentWorkflowGraph(sessionID: turnSessionID)
        guard isCurrentTurn(token, sessionID: turnSessionID) else { return }
        guard let graph, graph.id == graphID else {
            updateCommandStateIfCurrent(token, sessionID: turnSessionID) { state in
                if state.activeWorkflow?.graphID == graphID {
                    state.activeWorkflow = nil
                }
            }
            return
        }
        guard graph.workflow != nil || !graph.tasks.isEmpty else {
            _ = try? await runtime.removeTaskGraph(id: graphID, sessionID: turnSessionID)
            updateCommandStateIfCurrent(token, sessionID: turnSessionID) { state in
                if state.activeWorkflow?.graphID == graphID {
                    state.activeWorkflow = nil
                }
            }
            return
        }
        let didArm = updateCommandStateIfCurrent(token, sessionID: turnSessionID) { state in
            var workflow = state.activeWorkflow?.graphID == graphID
                ? state.activeWorkflow!
                : WorkflowCommandRuntimeState(goal: graph.workflow?.originalGoal ?? "", graphID: graphID)
            if !workflow.recordCoordinatorOutput(nil, graph: graph) {
                workflow.armForRecoverableFailure(reason: reason)
            }
            state.activeWorkflow = workflow
        }
        guard didArm else { return }
        await presenter.presentWorkflowNotice(
            .recoverableFailure(graphID: graphID, pendingTaskCount: Self.openTaskCount(in: graph))
        )
    }

    /// The session's current task graph when it is an unfinished workflow graph.
    func currentWorkflowGraph(sessionID: String) async -> TaskGraphSnapshot? {
        guard let graph = try? await runtime.taskGraphSnapshot(sessionID: sessionID, graphID: nil),
              graph.source.isWorkflow,
              !graph.state.isTerminal else {
            return nil
        }
        return graph
    }

    nonisolated static func openTaskCount(in graph: TaskGraphSnapshot) -> Int {
        graph.tasks.filter { $0.status != .completed && $0.status != .cancelled }.count
    }
}
