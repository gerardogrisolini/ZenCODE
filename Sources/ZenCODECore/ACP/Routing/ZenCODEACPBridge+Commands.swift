//
//  ZenCODEACPBridge+Commands.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  ACP routing of /plan, /goal, /review, and their replies onto the shared
//  planning operations.
//

import Foundation
import ToolCore

enum ACPCommandPromptPurpose: Sendable {
    case normal
    case implementation
    case workflow(graphID: String)
    case review
    case planning(collectionID: UUID)
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

/// The ACP command an outcome answers, which picks the ACP wording of a
/// shared notice: some notices read differently by command, as ACP wrote
/// them.
enum ACPCommandNoticeContext: Sendable {
    case plan(CoordinatorCommand.PlanAction)
    case goal
    case review
    case approvalReply
    case plannerReply
    case workflowReply
}

/// `/plan`, `/goal`, `/review`, and the replies they wait for, on the shared
/// operations of the session's controller
/// (``ChatSessionController/runPlanCommand(line:fence:policy:)``,
/// ``ChatSessionController/runGoalCommand(line:fence:)``,
/// ``ChatSessionController/runReviewCommand(line:fence:policy:)``,
/// ``ChatSessionController/pendingReplyAction(for:fence:policy:)``) with the
/// ACP policy (``ChatPlanningCommandPolicy/acp(savingAgent:fallbackHistory:reviewPrompt:)``).
///
/// ACP keeps around the operations what is its own: the gate on its tool
/// grant, the error of a profile catalog that cannot be read, the projection
/// of a restored `/goal` workflow before a reply, the refresh of the session
/// after `/plan load`, and its wording (``acpText(for:context:)``).
///
/// The fence is the controller's turn token, taken in the same synchronous
/// step that checks the prompt's reservation. `session/cancel`,
/// `session/close`, and shutdown, the only operations that drop the
/// reservation, clear it (``ChatSessionController/cancelActiveTurn(armingWorkflowRecovery:)``),
/// so the operations check and write their state under the controller's lock
/// against it, and undo their runtime changes once it fails. A command the
/// fence superseded ends `cancelled`, as before: the messages ACP wrote for a
/// changed session never reached the wire, because the prompt checks its
/// reservation again after routing.
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
        let controller = session.controller
        let fence = controller.beginCommandFence(sessionID: sessionID)
        defer { controller.endCommandFence(fence) }
        let policy = acpPlanningPolicy(for: session)

        guard let command else {
            guard !hasAgentMention,
                  !CoordinatorCommandParser.isSlashCommand(routedPromptText) else {
                return .generate(prompt: routedPromptText, purpose: .normal)
            }
            return try await routeACPPendingReply(
                routedPromptText,
                session: session,
                fence: fence,
                policy: policy
            )
        }

        switch command {
        case .goal:
            let outcome = await controller.runGoalCommand(line: routedPromptText, fence: fence)
            return try acpRoute(for: outcome, context: .goal, controller: controller, fence: fence)
        case .review:
            guard acpSubAgentsAreAvailable(in: session) else {
                return .immediate("ZenCODE: /review requires the sub-agent tools in this ACP session.")
            }
            do {
                _ = try availableACPAgentProfiles()
            } catch {
                return .immediate("ZenCODE: \(error.localizedDescription)")
            }
            let outcome = await controller.runReviewCommand(
                line: routedPromptText,
                fence: fence,
                policy: policy
            )
            return try acpRoute(for: outcome, context: .review, controller: controller, fence: fence)
        case let .plan(action):
            if case .start = action {
                guard acpSubAgentsAreAvailable(in: session, requiresMessaging: true) else {
                    return .immediate("ZenCODE: /plan requires the sub-agent tools in this ACP session.")
                }
                // A profile catalog that cannot be read fails the prompt.
                _ = try availableACPAgentProfiles()
            }
            let outcome = await controller.runPlanCommand(
                line: routedPromptText,
                fence: fence,
                policy: policy
            )
            if case .load = action, outcome.notices.contains(where: Self.isSavedPlanLoaded) {
                // The runtime session's history now carries the plan.
                await refreshSessionStateIfAvailable(
                    sessionID: sessionID,
                    preservingAllowedToolNames: session.allowedToolNames,
                    expectedEpoch: epoch,
                    expectedPromptID: promptID
                )
            }
            return try acpRoute(for: outcome, context: .plan(action), controller: controller, fence: fence)
        }
    }

    /// The planning policy of `session`: ACP's sequence, with the session's
    /// agent, the history the client gave it, and ACP's `/review` prompt.
    func acpPlanningPolicy(for session: SessionState) -> ChatPlanningCommandPolicy {
        .acp(
            savingAgent: session.selectedAgent,
            fallbackHistory: session.configuration.history,
            reviewPrompt: { request in
                Self.acpReviewPrompt(
                    scope: request.scope,
                    reviewers: request.reviewers,
                    approvedPlan: request.approvedPlan,
                    taskGraph: request.taskGraph
                )
            }
        )
    }

    private static func isSavedPlanLoaded(_ notice: ChatSessionNotice) -> Bool {
        if case .savedPlanLoaded = notice {
            return true
        }
        return false
    }

    /// A plain message: the Goal of `/plan approve`, the answer to a Planner
    /// question, or the reply to a `/goal` workflow, in that order; otherwise
    /// an ordinary prompt.
    private func routeACPPendingReply(
        _ reply: String,
        session: SessionState,
        fence: ChatCommandFence,
        policy: ChatPlanningCommandPolicy
    ) async throws -> ACPCommandTurnRoute {
        let controller = session.controller
        let state = controller.commandState
        let approvalTakesReply = state.pendingPlanApprovalPlanID != nil && reply.nilIfBlank != nil
        let plannerTakesReply = !approvalTakesReply
            && state.planBrainstorming?.isAwaitingReply == true
            && reply.nilIfBlank != nil
        if plannerTakesReply {
            guard acpSubAgentsAreAvailable(in: session, requiresMessaging: true) else {
                return .immediate("ZenCODE: /plan requires the sub-agent tools in this ACP session.")
            }
            // A profile catalog that cannot be read fails the prompt.
            _ = try availableACPAgentProfiles()
        }

        var projection: (stored: WorkflowCommandRuntimeState?, projected: WorkflowCommandRuntimeState)?
        if !approvalTakesReply, !plannerTakesReply {
            let stored = state.activeWorkflow
            guard let projected = await projectedACPWorkflowContinuation(
                stored: stored,
                sessionID: session.id
            ), projected.isAwaitingReply else {
                // Nothing armed: the message stays an ordinary prompt.
                return .generate(prompt: reply, purpose: .normal)
            }
            if projected != stored {
                guard controller.commitCommandState(ifCurrent: fence, { $0.activeWorkflow = projected }) else {
                    throw CancellationError()
                }
                projection = (stored, projected)
            }
        }

        let outcome = await controller.pendingReplyAction(for: reply, fence: fence, policy: policy)
        if let projection, !Self.startsTurn(outcome) {
            // The reply did not resume the workflow, so the projection is not
            // kept: the stored state goes back to what it was, unless the
            // operation itself changed it. This only undoes the projection's
            // own write, so it runs even once the fence failed (a cancellation
            // never touches the workflow while a command routes).
            controller.stateStore.withLock { state in
                if state.commandState.activeWorkflow == projection.projected {
                    state.commandState.activeWorkflow = projection.stored
                }
            }
        }
        guard let outcome, !Self.isEmpty(outcome) else {
            guard controller.isCurrent(fence) else {
                throw CancellationError()
            }
            return .generate(prompt: reply, purpose: .normal)
        }
        let context: ACPCommandNoticeContext = approvalTakesReply
            ? .approvalReply
            : plannerTakesReply ? .plannerReply : .workflowReply
        return try acpRoute(for: outcome, context: context, controller: controller, fence: fence)
    }

    /// The `/goal` workflow a plain message would continue: the one in the
    /// command state, or for a session restored without it the session's
    /// open workflow graph, with the pause the graph persisted. `nil` when
    /// there is none.
    private func projectedACPWorkflowContinuation(
        stored: WorkflowCommandRuntimeState?,
        sessionID: String
    ) async -> WorkflowCommandRuntimeState? {
        let currentGraph = try? await sessionRunner.taskGraphSnapshot(sessionID: sessionID)
        var projectedWorkflow = stored
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
        return projectedWorkflow
    }

    private static func startsTurn(_ outcome: ChatCommandOutcome?) -> Bool {
        if case .startTurn = outcome?.action {
            return true
        }
        return false
    }

    private static func isEmpty(_ outcome: ChatCommandOutcome) -> Bool {
        outcome.notices.isEmpty && outcome.action == .none
    }

    /// The route of a shared command's outcome: the turn it starts, or its
    /// notices as one ACP message. A command its fence superseded ends
    /// `cancelled`.
    private func acpRoute(
        for outcome: ChatCommandOutcome,
        context: ACPCommandNoticeContext,
        controller: ChatSessionController,
        fence: ChatCommandFence
    ) throws -> ACPCommandTurnRoute {
        guard controller.isCurrent(fence) else {
            throw CancellationError()
        }
        switch outcome.action {
        case let .startTurn(prompt, purpose, _):
            switch purpose {
            case .plan:
                let collectionID = controller.stateStore.withLock { state -> UUID? in
                    guard state.activeTurnToken == fence.token else {
                        return nil
                    }
                    return state.commandState.planBrainstorming?.collectionID
                }
                guard let collectionID else {
                    throw CancellationError()
                }
                return .generate(prompt: prompt, purpose: .planning(collectionID: collectionID))
            case let .workflow(_, graphID):
                return .generate(prompt: prompt, purpose: .workflow(graphID: graphID))
            case .review:
                return .generate(prompt: prompt, purpose: .review)
            case .normal:
                guard outcome.notices.contains(.planApproved) else {
                    return .generate(prompt: prompt, purpose: .normal)
                }
                return .generate(
                    prompt: prompt,
                    purpose: .implementation,
                    prelude: "Approved the active plan and activated its task graph. Starting implementation now."
                )
            }
        case .none, .channelCommand:
            let separator: String
            if case .plan(.status) = context {
                separator = "\n\n"
            } else {
                separator = "\n"
            }
            return .immediate(
                outcome.notices
                    .map { Self.acpText(for: $0, context: context) }
                    .joined(separator: separator)
            )
        }
    }

    /// The ACP message of a planning notice, as ACP wrote it.
    static func acpText(
        for notice: ChatSessionNotice,
        context: ACPCommandNoticeContext
    ) -> String {
        switch notice {
        case let .operationFailed(description):
            return "ZenCODE: \(description)"
        case let .agentRoleUnavailable(role):
            return AgentProfileStore.roleUnavailableForProjectMessage(role)
        case let .subAgentToolsRequired(command):
            return "ZenCODE: \(command) requires the sub-agent tools in this ACP session."
        // /plan
        case .planMissingGoal:
            return "ZenCODE: /plan requires a goal or one of: save, load, list, delete, status, approve, clear."
        case .planDiscussionBlocksMutation:
            return "ZenCODE: finish the current Planner clarification or use /plan clear before approving, saving, or loading a plan."
        case .planUnavailableForSaving:
            return "ZenCODE: no completed plan is available to save."
        case let .planSaved(planID):
            return "Saved plan: \(planID). Use /plan load in a new session to review or revise it."
        case .runtimeSessionUnavailable:
            switch context {
            case .plan(.clear):
                return "ZenCODE: the ACP session changed before /plan clear completed."
            case .approvalReply:
                return "ZenCODE: the ACP session changed before plan approval completed."
            default:
                return "ZenCODE: the ACP session changed while loading the plan."
            }
        case .activePlanAlreadyExists:
            return "ZenCODE: an active plan already exists. Use /plan clear before loading a saved plan."
        case .savedPlanUnavailable, .noSavedPlans:
            return "ZenCODE: no saved plan is available for this project."
        case .savedPlansAllCompleted:
            return "ZenCODE: every saved plan for this project is already completed."
        case .savedPlanContextNotAdded:
            return "ZenCODE: the saved plan could not be added to the current ACP session."
        case let .savedPlanLoaded(plan):
            return "Loaded saved plan `\(plan.id)` as an unapproved active plan.\n\n\(plan.consolidatedText)\n\nUse /plan approve when it is ready."
        case let .savedPlans(savedPlans):
            return PlanningCommandKernel.savedPlansListMessage(for: savedPlans)
        case .planDeleteUsage:
            return "ZenCODE: /plan delete requires a plan id, unique prefix, or all."
        case let .savedPlanNotFound(availablePlanIDs):
            return PlanningCommandKernel.planDeleteNotFoundMessage(availablePlanIDs: availablePlanIDs)
        case let .savedPlanAmbiguous(matches):
            return PlanningCommandKernel.planDeleteAmbiguousMessage(matches: matches)
        case let .savedPlansDeleted(planIDs, activePlanAffected):
            return PlanningCommandKernel.planDeleteSuccessMessage(
                deletedPlanIDs: planIDs,
                activePlanAffected: activePlanAffected
            )
        case let .planClarificationActive(goal):
            return "Planner clarification is active for: \(goal)"
        case .planAwaitingApprovalGoal:
            return "A descriptive Goal is required before plan approval can continue."
        case .noActivePlan:
            return "No active plan."
        case let .planStatus(plan, graph):
            return PlanningCommandKernel.planStatusTable(for: plan, graph: graph)
        case .planUnavailableForApproval:
            if case .approvalReply = context {
                return "ZenCODE: no completed plan is available to approve."
            }
            return "ZenCODE: no completed plan is available to approve. Run /plan <goal> first."
        case .planApprovalGoalPrompt:
            return "Before approving this plan, provide a descriptive Goal for the work it represents."
        case .noPendingPlanApproval:
            return "ZenCODE: no pending plan approval is available."
        case .planDiscussionCleared:
            return "Cleared the unfinished planning discussion."
        case .noPlanToClear:
            return "No active plan or planning discussion to clear."
        case .activePlanCleared:
            return "Cleared the active plan and archived its task graph. Saved-plan library copies are unaffected."
        // /goal
        case .workflowMissingGoal:
            return "ZenCODE: /goal requires a goal. Use /goal <goal> to describe the outcome to achieve."
        case .workflowBlockedByPlan:
            return "ZenCODE: /goal cannot start while an active plan or planning discussion exists. Finish it or use /plan clear first."
        case let .workflowAlreadyActive(graphID, open):
            return "ZenCODE: a goal workflow is already running (\(graphID), "
                + "\(open) task\(open == 1 ? "" : "s") still open). "
                + "Reply in this session to continue it when it is waiting for you, "
                + "or clear its task graph before starting another /goal."
        default:
            // The ACP policy raises no other notice from these commands.
            return ChatSessionNoticeText.text(for: notice)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// ACP's `/review` prompt.
    nonisolated static func acpReviewPrompt(
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
