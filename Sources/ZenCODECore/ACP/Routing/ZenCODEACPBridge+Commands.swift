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
import ZenCODERuntime

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
    /// Write the answer first, then force a fresh Tasks plan before the reply.
    case immediateTasks(String)

    fileprivate func addingEditorContext(_ editorContext: String?) -> Self {
        guard case let .generate(prompt, purpose, prelude) = self else { return self }
        return .generate(
            prompt: ZenCODEACPBridge.modelPrompt(prompt, editorContext: editorContext),
            purpose: purpose,
            prelude: prelude
        )
    }
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
    case tasks
    case workspace
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
/// The fence is the controller's turn token, taken on the host in the same
/// synchronous step that checks the prompt's reservation. `session/cancel`,
/// `session/close`, and shutdown, the only operations that drop the
/// reservation, clear it (``ChatSessionController/cancelActiveTurn(armingWorkflowRecovery:)``),
/// so the operations check and write their state under the controller's lock
/// against it, and undo their runtime changes once it fails. A command the
/// fence superseded ends `cancelled`, as before: the messages ACP wrote for a
/// changed session never reached the wire, because the prompt checks its
/// reservation again after routing.
extension ZenCODEACPBridge {
    func routeACPCommandTurn(
        operatorLine: String?,
        normalPrompt: String,
        coordinatorLine: String? = nil,
        editorContext: String? = nil,
        agentMention: AgentProfile?,
        turn: ACPPromptTurn
    ) async throws -> ACPCommandTurnRoute {
        let (sessionID, epoch, promptID) = (turn.sessionID, turn.epoch, turn.promptID)
        guard let reservedSession = liveSession(id: sessionID, epoch: epoch) else {
            throw CancellationError()
        }
        let controller = reservedSession.controller
        guard let fence = await host.beginPromptCommandFence(reservedSession.promptReservation(promptID)) else {
            throw CancellationError()
        }
        defer { controller.endCommandFence(fence) }

        // While Telegram drives the slot the editor runs only what takes it
        // back (see `ChatSessionHost.admitLine`); every other line is
        // answered with the refusal and runs nothing. Context cannot take
        // the slot back on the operator's behalf.
        let admission = await host.admitLine(operatorLine ?? "", in: reservedSession.slotID)
        guard var session = liveSession(id: sessionID, epoch: epoch), controller.isCurrent(fence) else {
            throw CancellationError()
        }
        if case let .refused(text) = admission {
            return .immediate(Self.acpImmediateText(text))
        }
        guard let operatorLine else { return .generate(prompt: normalPrompt, purpose: .normal) }

        // Only now that the slot admitted the line: a refused line must not
        // route the session to another agent. The mention keeps the same
        // incarnation and reservation; it updates the configuration, it does
        // not restart the session.
        if let agentMention {
            guard controller.isCurrent(fence),
                  let mentionedSession = applyACPAgentMention(
                      agentMention,
                      sessionID: sessionID,
                      epoch: epoch
                  ) else {
                throw CancellationError()
            }
            session = mentionedSession
        }
        // After the mention: the policy saves the plan as the agent the turn
        // runs on.
        let policy = acpPlanningPolicy(for: session)

        // `/telegram` is not a coordinator command: it is answered here, at
        // once, and never reaches the model (see `routeACPTelegramCommand`).
        if ChatCommandRegistry.commandToken(from: operatorLine) == Self.telegramCommandToken {
            return try await routeACPTelegramCommand(
                operatorLine,
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID
            )
        }

        // `/tasks` is not a coordinator command either: it is answered here,
        // with the graph the terminal and Telegram show and the plan update of
        // the client's Tasks section (see `routeACPTasksCommand`).
        if ChatCommandRegistry.commandToken(from: operatorLine) == Self.tasksCommandToken {
            return try await routeACPTasksCommand(
                operatorLine,
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID,
                fence: fence
            )
        }

        // `/changes` and `/undo` are not coordinator commands either: they are
        // answered here, with the file changes of the last turn, and never reach
        // the model (see `routeACPWorkspaceCommand`).
        if Self.isWorkspaceCommand(operatorLine) {
            return try await routeACPWorkspaceCommand(
                operatorLine,
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID,
                fence: fence
            )
        }

        guard let command = CoordinatorCommandParser.parse(operatorLine) else {
            guard agentMention == nil, !CoordinatorCommandParser.isSlashCommand(operatorLine) else {
                return .generate(prompt: normalPrompt, purpose: .normal)
            }
            let reply = try await routeACPPendingReply(
                operatorLine,
                session: session,
                fence: fence,
                policy: policy
            )
            return reply?.addingEditorContext(editorContext) ?? .generate(prompt: normalPrompt, purpose: .normal)
        }

        let commandLine = coordinatorLine ?? operatorLine
        switch command {
        case .goal:
            let outcome = await controller.runGoalCommand(line: commandLine, fence: fence)
            return try acpRoute(for: outcome, context: .goal, controller: controller, fence: fence)
                .addingEditorContext(editorContext)
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
                line: commandLine,
                fence: fence,
                policy: policy
            )
            return try acpRoute(for: outcome, context: .review, controller: controller, fence: fence)
                .addingEditorContext(editorContext)
        case let .plan(action):
            if case .start = action {
                guard acpSubAgentsAreAvailable(in: session, requiresMessaging: true) else {
                    return .immediate("ZenCODE: /plan requires the sub-agent tools in this ACP session.")
                }
                // A profile catalog that cannot be read fails the prompt.
                _ = try availableACPAgentProfiles()
            }
            let outcome = await controller.runPlanCommand(
                line: commandLine,
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
                .addingEditorContext(editorContext)
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
    /// no route (the caller uses the whole rendered prompt).
    private func routeACPPendingReply(
        _ reply: String,
        session: SessionState,
        fence: ChatCommandFence,
        policy: ChatPlanningCommandPolicy
    ) async throws -> ACPCommandTurnRoute? {
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
                return nil
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
            return nil
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

    /// The ACP message of a command notice: the ACP wording where it differs
    /// from the shared text (``ChatSessionNoticeText``), else the shared text.
    static func acpText(
        for notice: ChatSessionNotice,
        context: ACPCommandNoticeContext
    ) -> String {
        switch notice {
        case let .operationFailed(description):
            return "ZenCODE: \(description)"
        case let .subAgentToolsRequired(command):
            return "ZenCODE: \(command) requires the sub-agent tools in this ACP session."
        // /plan
        case .planMissingGoal:
            return "ZenCODE: /plan requires a goal or one of: save, load, list, delete, status, approve, clear."
        case .planDiscussionBlocksMutation:
            return "ZenCODE: finish the current Planner clarification or use /plan clear before approving, saving, or loading a plan."
        case .planUnavailableForSaving:
            return "ZenCODE: no completed plan is available to save."
        case .runtimeSessionUnavailable:
            switch context {
            case .plan(.clear):
                return "ZenCODE: the ACP session changed before /plan clear completed."
            case .approvalReply:
                return "ZenCODE: the ACP session changed before plan approval completed."
            default:
                return "ZenCODE: the ACP session changed while loading the plan."
            }
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
        case let .planStatus(plan, graph):
            return PlanningCommandKernel.planStatusTable(for: plan, graph: graph)
        case let .queuedPlans(plans):
            return PlanningCommandKernel.queuedPlansMessage(for: plans)
        case .planUnavailableForApproval:
            if case .approvalReply = context {
                return "ZenCODE: no completed plan is available to approve."
            }
            return "ZenCODE: no completed plan is available to approve. Run /plan <goal> first."
        case .planApprovalGoalPrompt:
            return "Before approving this plan, provide a descriptive Goal for the work it represents."
        case .activePlanCleared:
            return "Cleared the active plan and archived its task graph. Saved-plan library copies are unaffected."
        // /goal
        case .workflowBlockedByPlan:
            return "ZenCODE: /goal cannot start while an active plan or planning discussion exists. Finish it or use /plan clear first."
        case let .workflowAlreadyActive(graphID, open):
            return "ZenCODE: a goal workflow is already running (\(graphID), "
                + "\(open) task\(open == 1 ? "" : "s") still open). "
                + "Reply in this session to continue it when it is waiting for you, "
                + "or clear its task graph before starting another /goal."
        default:
            // Every other notice reads in ACP as the shared text, without its
            // trailing newline.
            return ChatSessionNoticeText.text(for: notice)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
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

    /// The bridge's entry of the incarnation `epoch` of `sessionID` while the
    /// prompt `promptID` holds it: the bridge's own liveness, then the host's
    /// reservation, then the entry again after the hop. `nil` as soon as the
    /// prompt was cancelled, released, or its incarnation ended.
    func reservedPromptSession(
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async -> SessionState? {
        guard let session = liveSession(id: sessionID, epoch: epoch),
              await host.holdsPrompt(session.promptReservation(promptID)) else {
            return nil
        }
        return liveSession(id: sessionID, epoch: epoch)
    }

    /// Writes the bridge's entry back only while the prompt `promptID` holds
    /// its incarnation, as ``reservedPromptSession(sessionID:epoch:promptID:)``
    /// checks it; the write itself is one synchronous step on the entry.
    @discardableResult
    func updateReservedPromptSession(
        sessionID: String,
        epoch: UInt64,
        promptID: UUID,
        _ update: (inout SessionState) -> Void
    ) async -> Bool {
        guard await reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else {
            return false
        }
        return updateLiveSession(id: sessionID, epoch: epoch, update)
    }

    func clearACPPlanBrainstorming(
        sessionID: String,
        epoch: UInt64,
        closeAllPlanAuthors: Bool = false,
        expectedCollectionID: UUID? = nil
    ) async {
        guard let session = liveSession(id: sessionID, epoch: epoch) else { return }
        let controller = session.controller
        let brainstorming = controller.commandState.planBrainstorming
        let collectionID = brainstorming?.collectionID
        if let expectedCollectionID, collectionID != expectedCollectionID {
            return
        }
        var agentIDs = Set<String>()
        if let plannerAgentID = brainstorming?.plannerAgentID {
            agentIDs.insert(plannerAgentID)
        }
        if closeAllPlanAuthors || (brainstorming != nil && agentIDs.isEmpty) {
            let snapshots = await sessionRunner.subAgentSnapshots()
            guard let current = liveSession(id: sessionID, epoch: epoch),
                  current.controller.commandState.planBrainstorming?.collectionID == collectionID else {
                return
            }
            agentIDs.formUnion(
                PlanningCommandKernel.plannerSnapshots(
                    snapshots,
                    rootSessionID: sessionID
                ).map(\.id)
            )
        }
        // The discussion is cleared under the controller's lock, inside the
        // step that checks the incarnation, only while it is still the one
        // read above.
        guard updateLiveSession(id: sessionID, epoch: epoch, { live in
            live.controller.stateStore.withLock { state in
                guard state.commandState.planBrainstorming?.collectionID == collectionID else { return }
                state.commandState.planBrainstorming = nil
            }
        }) else {
            return
        }
        for agentID in agentIDs {
            _ = await sessionRunner.closeSubAgent(id: agentID)
        }
    }
}


extension ZenCODEACPBridge {
    /// `text` as an immediate ACP reply: without the one trailing newline the
    /// terminal writes after it.
    static func acpImmediateText(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }
}
