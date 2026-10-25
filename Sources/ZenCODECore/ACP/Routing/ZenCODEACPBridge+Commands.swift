//
//  ZenCODEACPBridge+Commands.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
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
    case generate(prompt: String, purpose: ACPCommandPromptPurpose, prelude: String? = nil)
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
        guard let session = reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            throw CancellationError()
        }

        guard let command else {
            guard !hasAgentMention,
                  !CoordinatorCommandParser.isSlashCommand(routedPromptText) else {
                return .generate(prompt: routedPromptText, purpose: .normal)
            }
            if let pendingPlanApprovalPlanID = session.pendingPlanApprovalPlanID,
               let goal = routedPromptText.nilIfBlank {
                return await approveACPPlan(
                    originalGoal: goal,
                    planID: pendingPlanApprovalPlanID,
                    sessionID: sessionID,
                    epoch: epoch,
                    promptID: promptID
                )
            }
            if var brainstorming = session.planBrainstorming,
               brainstorming.isAwaitingReply,
               brainstorming.recordReply(routedPromptText) {
                guard acpSubAgentsAreAvailable(
                    in: session,
                    requiresMessaging: true
                ) else {
                    return .immediate("ZenCODE: /plan requires the sub-agent tools in this ACP session.")
                }
                let planners = try acpRoleProfiles(.planner, session: session)
                guard !planners.isEmpty else {
                    return .immediate(AgentProfileStore.roleUnavailableForProjectMessage(.planner))
                }
                let snapshots = await sessionRunner.subAgentSnapshots()
                guard updateReservedPromptSession(
                    sessionID: sessionID,
                    epoch: epoch,
                    promptID: promptID,
                    { $0.planBrainstorming = brainstorming }
                ) else {
                    throw CancellationError()
                }
                let baseline = PlannerTurnBaseline(state: brainstorming, snapshots: snapshots, rootSessionID: sessionID)
                return .generate(
                    prompt: PlanningCommandKernel.planContinuationPrompt(
                        state: brainstorming,
                        planners: planners
                    ),
                    purpose: .planning(collectionID: brainstorming.collectionID, baseline: baseline)
                )
            }
            // Cross-surface parity with the TUI and Telegram: a plain message
            // continues an open `/goal` workflow that is explicitly waiting.
            if let workflowRoute = await routeACPWorkflowContinuation(
                reply: routedPromptText,
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID
            ) {
                return workflowRoute
            }
            return .generate(prompt: routedPromptText, purpose: .normal)
        }

        switch command {
        case let .goal(goal):
            return try await routeACPGoal(goal: goal, sessionID: sessionID, epoch: epoch, promptID: promptID)
        case let .review(scope):
            return await routeACPReview(scope: scope, sessionID: sessionID, epoch: epoch, promptID: promptID)
        case let .plan(action):
            return try await routeACPPlanAction(action, sessionID: sessionID, epoch: epoch, promptID: promptID)
        }
    }

    private func routeACPReview(
        scope: String,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async -> ACPCommandTurnRoute {
        guard let session = reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            return .immediate("ZenCODE: the ACP session changed before /review started.")
        }
        guard acpSubAgentsAreAvailable(in: session) else {
            return .immediate("ZenCODE: /review requires the sub-agent tools in this ACP session.")
        }
        let reviewers: [AgentProfile]
        do {
            reviewers = try acpRoleProfiles(.reviewer, session: session)
        } catch {
            return .immediate("ZenCODE: \(error.localizedDescription)")
        }
        guard !reviewers.isEmpty else {
            return .immediate(AgentProfileStore.roleUnavailableForProjectMessage(.reviewer))
        }
        let approvedPlan = session.activePlan.flatMap { plan in
            plan.isApproved && plan.consolidatedText.nilIfBlank != nil ? plan : nil
        }
        let graph = try? await sessionRunner.taskGraphSnapshot(sessionID: sessionID, graphID: approvedPlan?.id)
        guard reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else {
            return .immediate("ZenCODE: the ACP session changed before /review started.")
        }
        return .generate(
            prompt: acpReviewPrompt(
                scope: scope,
                reviewers: reviewers,
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
        guard let session = reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            throw CancellationError()
        }
        guard let goal = goal.nilIfBlank else {
            return .immediate("ZenCODE: /goal requires a goal. Use /goal <goal> to describe the outcome to achieve.")
        }
        guard session.activePlan == nil, session.planBrainstorming == nil else {
            return .immediate(
                "ZenCODE: /goal cannot start while an active plan or planning discussion exists. Finish it or use /plan clear first."
            )
        }
        // Mirror the TUI guard: the orchestrator refuses to create a graph while
        // the current one is an unfinished workflow graph, and the raw
        // `graphNotMutable` error is not actionable for the user.
        if let current = try? await sessionRunner.taskGraphSnapshot(sessionID: sessionID),
           current.source.isWorkflow,
           !current.state.isTerminal {
            let open = current.tasks.filter {
                $0.status != .completed && $0.status != .cancelled
            }.count
            return .immediate(
                "ZenCODE: a goal workflow is already running (\(current.id), "
                    + "\(open) task\(open == 1 ? "" : "s") still open). "
                    + "Reply in this session to continue it when it is waiting for you, "
                    + "or clear its task graph before starting another /goal."
            )
        }

        let graphID = "workflow_\(UUID().uuidString.lowercased())"
        do {
            _ = try await sessionRunner.taskOrchestrator.createGraph(
                sessionID: sessionID,
                id: graphID,
                source: .workflow,
                state: .active,
                tasks: [],
                originalGoal: goal
            )
        } catch {
            return .immediate("ZenCODE: \(error.localizedDescription)")
        }
        guard reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else {
            _ = try? await sessionRunner.removeTaskGraph(id: graphID, sessionID: sessionID)
            throw CancellationError()
        }
        // Track the transient reply transcript. The graph owns the original
        // objective and structured workflow state; a new workflow starts running.
        guard updateReservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID,
            {
                $0.workflowContinuation = WorkflowCommandRuntimeState(goal: goal, graphID: graphID)
            }
        ) else {
            _ = try? await sessionRunner.removeTaskGraph(id: graphID, sessionID: sessionID)
            throw CancellationError()
        }
        return .generate(
            prompt: PlanningCommandKernel.workflowPrompt(goal: goal, graphID: graphID),
            purpose: .workflow(graphID: graphID)
        )
    }

    /// Routes a plain ACP message back into an open `/goal` workflow when that
    /// workflow explicitly armed a continuation (clarification question or an
    /// interrupted turn with a preserved graph). Returns `nil` when nothing is
    /// armed, so the message stays an ordinary prompt.
    func routeACPWorkflowContinuation(
        reply: String,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async -> ACPCommandTurnRoute? {
        guard let session = reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            return nil
        }
        let currentGraph = try? await sessionRunner.taskGraphSnapshot(sessionID: sessionID)
        var projectedWorkflow = session.workflowContinuation
        if projectedWorkflow == nil, let graph = currentGraph,
           graph.source.isWorkflow, !graph.state.isTerminal {
            var restored = WorkflowCommandRuntimeState(goal: graph.workflow?.originalGoal ?? "", graphID: graph.id)
            if graph.workflow != nil, graph.workflow?.state != .running {
                restored.recordCoordinatorOutput(nil, graph: graph)
            } else {
                restored.armForResumedGraph()
            }
            projectedWorkflow = restored
        }
        if let graph = currentGraph, graph.id == projectedWorkflow?.graphID,
           graph.workflow != nil, graph.workflow?.state != .running {
            projectedWorkflow?.recordCoordinatorOutput(nil, graph: graph)
        }
        guard var workflow = projectedWorkflow, workflow.isAwaitingReply else { return nil }
        // Never resume a graph that is no longer the session's open workflow.
        guard let graph = currentGraph,
              graph.id == workflow.graphID,
              graph.source.isWorkflow,
              !graph.state.isTerminal else {
            _ = updateReservedPromptSession(
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID,
                { $0.workflowContinuation = nil }
            )
            return nil
        }
        guard workflow.recordReply(reply) else { return nil }
        let runnerGeneration = await sessionRunner.currentSessionGeneration(for: sessionID)
        guard !Task.isCancelled, reservedPromptSession(
            sessionID: sessionID, epoch: epoch, promptID: promptID
        ) != nil else { return nil }
        let resumedGraph: TaskGraphSnapshot
        do {
            resumedGraph = try await sessionRunner.taskOrchestrator.resumeWorkflow(
                sessionID: sessionID, expectedGraph: graph
            )
        } catch {
            return .immediate("ZenCODE: \(error.localizedDescription)")
        }
        guard !Task.isCancelled, updateReservedPromptSession(
            sessionID: sessionID,
            epoch: epoch,
            promptID: promptID,
            { $0.workflowContinuation = workflow }
        ) else {
            if let runnerGeneration,
               await sessionRunner.isCurrentSessionGeneration(runnerGeneration, for: sessionID) {
                try? await sessionRunner.taskOrchestrator.rollbackWorkflowResume(
                    sessionID: sessionID, previousGraph: graph, resumedGraph: resumedGraph
                )
            }
            return nil
        }
        let openCount = graph.tasks.filter {
            $0.status != .completed && $0.status != .cancelled
        }.count
        return .generate(
            prompt: PlanningCommandKernel.workflowContinuationPrompt(
                state: workflow,
                pendingTaskCount: openCount,
                totalTaskCount: graph.tasks.count
            ),
            purpose: .workflow(graphID: workflow.graphID)
        )
    }

    private func routeACPPlanAction(
        _ action: CoordinatorCommand.PlanAction,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async throws -> ACPCommandTurnRoute {
        guard let session = reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            throw CancellationError()
        }
        let blocksMutation = session.planBrainstorming != nil || session.pendingPlanApprovalPlanID != nil
        switch action {
        case .save where blocksMutation, .load where blocksMutation, .approve where blocksMutation:
            return .immediate(
                "ZenCODE: finish the current Planner clarification or use /plan clear before approving, saving, or loading a plan."
            )
        case .missingGoal:
            return .immediate(
                "ZenCODE: /plan requires a goal or one of: save, load, list, delete, status, approve, clear."
            )
        case let .start(goal):
            guard acpSubAgentsAreAvailable(
                in: session,
                requiresMessaging: true
            ) else {
                return .immediate("ZenCODE: /plan requires the sub-agent tools in this ACP session.")
            }
            let planners = try acpRoleProfiles(.planner, session: session)
            guard !planners.isEmpty else {
                return .immediate(AgentProfileStore.roleUnavailableForProjectMessage(.planner))
            }
            await clearACPPlanBrainstorming(sessionID: sessionID, epoch: epoch, closeAllPlanAuthors: true)
            guard reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else {
                throw CancellationError()
            }
            let brainstorming = PlanningCommandRuntimeState(goal: goal)
            let snapshots = await sessionRunner.subAgentSnapshots()
            let baseline = PlannerTurnBaseline(state: brainstorming, snapshots: snapshots, rootSessionID: sessionID)
            guard updateReservedPromptSession(
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID,
                { $0.planBrainstorming = brainstorming; $0.pendingPlanApprovalPlanID = nil }
            ) else {
                throw CancellationError()
            }
            return .generate(
                prompt: PlanningCommandKernel.planStartPrompt(goal: goal, planners: planners),
                purpose: .planning(collectionID: brainstorming.collectionID, baseline: baseline)
            )
        case .save:
            return .immediate(await saveACPPlan(sessionID: sessionID, epoch: epoch, promptID: promptID))
        case .load:
            return .immediate(await loadACPPlan(sessionID: sessionID, epoch: epoch, promptID: promptID))
        case .list:
            return .immediate(await listACPPlans(session: session))
        case let .delete(target):
            return .immediate(await deleteACPPlan(target: target, session: session))
        case .status:
            return .immediate(await acpPlanStatus(session: session))
        case .approve:
            return await requestACPPlanApprovalGoal(sessionID: sessionID, epoch: epoch, promptID: promptID)
        case .clear:
            return await clearACPPlan(sessionID: sessionID, epoch: epoch, promptID: promptID)
        }
    }

    /// Profiles with `role` that `/plan` or `/review` may delegate to in the
    /// project of this ACP session (its working directory). An empty result
    /// means the command must stop.
    private func acpRoleProfiles(
        _ role: AgentProfileRole,
        session: SessionState
    ) throws -> [AgentProfile] {
        AgentProfileStore.roleDelegationCandidates(
            role,
            in: try availableACPAgentProfiles(),
            workspaceRootURL: URL(fileURLWithPath: session.cwd, isDirectory: true)
        )
    }

    private func acpReviewPrompt(
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

    func acpSubAgentsAreAvailable(
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

    func reservedPromptSession(
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
    func updateReservedPromptSession(
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
}


extension ZenCODEACPBridge {
    func availableCommandsUpdate(for session: SessionState) -> JSONValue {
        var commands: [JSONValue] = [.object([
            "name": .string("goal"),
            "description": .string("Work until the goal is complete or genuinely blocked"),
            "input": .object(["hint": .string("Goal to achieve")])
        ])]
        if acpSubAgentsAreAvailable(in: session) {
            for (name, description) in [("review", "Review with delegated agents"), ("plan", "Create or manage a plan")] {
                commands.append(.object([
                    "name": .string(name), "description": .string(description),
                    "input": .object(["hint": .string("Instructions or subcommand")])
                ]))
            }
        }
        return .object(["sessionUpdate": .string("available_commands_update"), "availableCommands": .array(commands)])
    }

    func publishAvailableCommands(sessionID: String, epoch: UInt64) async {
        guard let session = liveSession(id: sessionID, epoch: epoch) else { return }
        let update = availableCommandsUpdate(for: session)
        guard session.presentedCommands != update else { return }
        sessions[sessionID]?.presentedCommands = update
        await writer.sendSessionUpdate(sessionID: sessionID, update: update)
    }
}
