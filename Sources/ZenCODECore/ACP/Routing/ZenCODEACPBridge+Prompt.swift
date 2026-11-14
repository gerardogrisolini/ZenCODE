//
//  ZenCODEACPBridge+Prompt.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

/// The identity of one `session/prompt` turn: the request it answers, the
/// session incarnation it runs on, and the prompt reservation it holds
/// there.
private struct ACPPromptTurn: Sendable {
    let requestID: JSONValue?
    let sessionID: String
    let epoch: UInt64
    let promptID: UUID
}

/// The request of a prompt turn, parsed.
private struct ACPPreparedPrompt {
    let attachments: [AgentRuntimeAttachment]
    /// The prompt text without the agent mention it may start with.
    let routedPromptText: String
    /// The text the turn presents as the user's message.
    let visiblePromptText: String
    let coordinatorCommand: CoordinatorCommand?
    let hasAgentMention: Bool
}

/// What a prompt turn does once routed.
private enum ACPPromptTurnRoute {
    /// The turn ends, answering `stopReason`.
    case finished(stopReason: String)
    /// The turn generates `prompt` for `purpose` on the live `session`.
    case generate(prompt: String, purpose: ACPCommandPromptPurpose, session: ZenCODEACPBridge.SessionState)
}

/// How a prompt turn whose task ran ends.
private enum ACPPromptTurnOutcome {
    /// The turn answers `stopReason`.
    case stopped(stopReason: String)
    /// The turn fails: the error is the request's answer.
    case failed(Error)
}

/// The presentation of a running prompt turn: its update pipeline and the
/// observer of its task graph.
private struct ACPPromptTurnPresentation {
    let pipeline: ACPPromptUpdatePipeline
    let taskPresentation: ACPTaskPresentation
    let graphObserver: Task<Void, Never>
}

extension ZenCODEACPBridge {
    public func prompt(id: JSONValue?, params: [String: Any]) async throws {
        // Check the fence *before* looking the session up. `shutdown()` empties
        // `sessions`, so the reverse order would report "unknown session" and
        // `handleMessage` would turn that into a JSON-RPC error response on a
        // transport that is already closed. A post-shutdown prompt must be
        // abandoned silently instead. `ensureConfigured()` keeps that order and
        // additionally answers `auth_required` while ZenCODE is not set up.
        try ensureConfigured()
        guard let sessionID = Self.sessionID(from: params),
              let knownSession = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        // Track the ACP wrapper handler itself, not only the backend turn, and
        // from before its first suspension: `close`/`shutdown` must be able to
        // wait for this handler's unwind (update flush, snapshot refresh,
        // final reply) before answering, a close landing during the hop to
        // the host below included.
        let promptHandlerToken = enterPromptHandler(sessionID: sessionID)
        defer { leavePromptHandler(sessionID: sessionID, token: promptHandlerToken) }

        // A new session may still be offering the task graphs earlier
        // sessions left incomplete: the prompt waits for the operator's
        // answer, so it runs on the graph resumed. A close that cancelled the
        // offer meanwhile, or a `session/cancel` of this prompt, ends it as
        // the close ends a prompt already running, `cancelled` (silently
        // after a shutdown).
        guard try await waitForResumableTaskGraphOffer(
            sessionID: sessionID,
            epoch: knownSession.epoch,
            promptHandlerToken: promptHandlerToken
        ) else {
            await sendStopReason(id: id, "cancelled")
            return
        }

        // Reserve the session in the host, which checks and reserves in one
        // step: a second `session/prompt` dispatched concurrently finds the
        // reservation taken, whichever of the two the host serves first. A
        // session busy with a turn from Telegram says so (see
        // `promptBusyMessage(slotID:)`).
        let reservation: ChatPromptReservation
        do {
            reservation = try await host.reservePrompt(in: knownSession.slotID)
        } catch ChatSessionHostError.sessionBusy {
            throw acpError(
                for: .sessionBusy,
                busyMessage: await promptBusyMessage(slotID: knownSession.slotID)
            )
        } catch {
            throw acpError(for: error, busyMessage: "A prompt is already running for this session.")
        }
        let promptID = reservation.promptID
        let epoch = reservation.epoch
        // The hop to the host is the first suspension: a close or a shutdown
        // that landed after the host reserved removed the entry. The
        // reservation it left in the host is released again, and the prompt
        // ends as the close ends a prompt already running, `cancelled`
        // (silently after a shutdown).
        guard let session = liveSession(id: sessionID, epoch: epoch) else {
            await host.releasePrompt(reservation)
            try ensureNotShutDown()
            await sendStopReason(id: id, "cancelled")
            return
        }
        var didReleaseReservation = false
        /// Releases the reservation only when it is still ours and the session
        /// is still the same incarnation: the bridge's own prompt state first,
        /// so no reconfiguration finds the host idle while the prompt task is
        /// still registered, then the host's reservation.
        func releaseReservation() async {
            guard !didReleaseReservation else {
                return
            }
            didReleaseReservation = true
            updateLiveSession(id: sessionID, epoch: epoch) { session in
                if session.activePromptTaskID == promptID {
                    session.activePromptTask = nil
                    session.activePromptTaskID = nil
                }
                if session.activeWorkflowPromptID == promptID {
                    session.activeWorkflowPromptID = nil
                }
            }
            await host.releasePrompt(reservation)
        }

        do {
            try await runPrompt(
                id: id,
                params: params,
                sessionID: sessionID,
                session: session,
                promptID: promptID,
                epoch: epoch,
                releaseReservation: releaseReservation
            )
        } catch {
            await releaseReservation()
            throw error
        }
        await releaseReservation()
    }

    private func sendStopReason(id: JSONValue?, _ reason: String) async {
        await writer.sendResultIfRequest(id: id, result: JSONValue.acpValue(from: ["stopReason": reason]))
    }

    /// Runs one `session/prompt` turn that holds its reservation, in phases:
    /// prepare (the request's blocks, attachments, and agent mention), route
    /// (the echo of the prompt and the command it carries), execute (the
    /// turn's task on the model and its presentation), and settle.
    ///
    /// Every exit that answers a stop reason goes through `finish`: the
    /// reply first, then the reservation. A failed turn releases the
    /// reservation before its error becomes the reply; a turn that is
    /// cancelled before its task runs throws, and `prompt` releases the
    /// reservation before the request answers `cancelled`.
    private func runPrompt(
        id: JSONValue?,
        params: [String: Any],
        sessionID: String,
        session: SessionState,
        promptID: UUID,
        epoch: UInt64,
        releaseReservation: () async -> Void
    ) async throws {
        let turn = ACPPromptTurn(requestID: id, sessionID: sessionID, epoch: epoch, promptID: promptID)
        func finish(stopReason: String) async {
            await sendStopReason(id: turn.requestID, stopReason)
            await releaseReservation()
        }

        let prepared = try await preparePromptTurn(turn, params: params, session: session)
        switch try await routePromptTurn(turn, prepared) {
        case let .finished(stopReason):
            await finish(stopReason: stopReason)
        case let .generate(prompt, purpose, routedSession):
            let outcome = try await executePromptTurn(
                turn,
                prompt: prompt,
                purpose: purpose,
                attachments: prepared.attachments,
                session: routedSession
            )
            switch outcome {
            case let .stopped(stopReason):
                await finish(stopReason: stopReason)
            case let .failed(error):
                await releaseReservation()
                throw error
            }
        }
    }

    /// Parses the turn's request: its content blocks and attachments, the
    /// agent mention it may start with, and the command it carries.
    private func preparePromptTurn(
        _ turn: ACPPromptTurn,
        params: [String: Any],
        session initialSession: SessionState
    ) async throws -> ACPPreparedPrompt {
        var session = initialSession
        let promptBlocks = promptBlocks(from: params)
        let rawPromptText = PromptContentFormatter.renderPromptText(from: promptBlocks)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = Self.promptAttachments(
            from: promptBlocks,
            renderedPromptText: rawPromptText,
            cwd: session.cwd
        )
        let promptText = rawPromptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let agentMentionResolution = try resolveLeadingACPAgentMention(in: promptText)
        let routedPromptText = agentMentionResolution?.prompt ?? promptText
        guard !routedPromptText.isEmpty || !attachments.isEmpty else {
            throw ACPError.invalidParams("session/prompt requires prompt text or attachments.")
        }

        if let agentMentionResolution {
            let promptConfiguration = await acpSessionConfiguration(
                applying: agentMentionResolution.agent,
                to: session.configuration
            )
            // Keep the same incarnation and reservation: routing to another
            // agent updates the configuration, it does not restart the session.
            let isLive = updateLiveSession(id: turn.sessionID, epoch: turn.epoch) { live in
                live = sessionState(
                    configuration: promptConfiguration,
                    selectedAgent: agentMentionResolution.agent,
                    inheriting: live
                )
            }
            guard isLive, let mentionedSession = liveSession(id: turn.sessionID, epoch: turn.epoch) else {
                throw CancellationError()
            }
            session = mentionedSession
        }

        let coordinatorCommand = CoordinatorCommandParser.parse(routedPromptText)
        let isPlanningReply = coordinatorCommand == nil
            && agentMentionResolution == nil
            && !CoordinatorCommandParser.isSlashCommand(routedPromptText)
            && session.controller.commandState.planBrainstorming?.isAwaitingReply == true
        // Commands remain visible exactly as the client sent them (including an
        // optional leading agent mention); only their hidden operational prompt
        // is substituted before generation.
        let visibleSource = coordinatorCommand != nil || isPlanningReply
            ? promptText
            : routedPromptText
        let visiblePromptText = visibleSource.isEmpty
            ? "Analyze the attached media."
            : visibleSource
        return ACPPreparedPrompt(
            attachments: attachments,
            routedPromptText: routedPromptText,
            visiblePromptText: visiblePromptText,
            coordinatorCommand: coordinatorCommand,
            hasAgentMention: agentMentionResolution != nil
        )
    }

    /// Presents the prompt as the client sent it, then chooses what the turn
    /// does with it: a command answered at once, or a generation.
    private func routePromptTurn(
        _ turn: ACPPromptTurn,
        _ prepared: ACPPreparedPrompt
    ) async throws -> ACPPromptTurnRoute {
        await sendUserMessageChunk(sessionID: turn.sessionID, text: prepared.visiblePromptText)
        await sendSessionInfoUpdate(sessionID: turn.sessionID, title: promptTitle(from: prepared.visiblePromptText))

        let commandRoute: ACPCommandTurnRoute
        do {
            commandRoute = try await routeACPCommandTurn(
                command: prepared.coordinatorCommand,
                routedPromptText: prepared.routedPromptText,
                hasAgentMention: prepared.hasAgentMention,
                sessionID: turn.sessionID,
                epoch: turn.epoch,
                promptID: turn.promptID
            )
        } catch is CancellationError {
            return .finished(stopReason: "cancelled")
        }
        guard await reservedPromptSession(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID) != nil else {
            return .finished(stopReason: "cancelled")
        }
        switch commandRoute {
        case let .immediate(message):
            await writer.sendSessionUpdate(
                sessionID: turn.sessionID,
                update: Self.textChunkJSONUpdate(kind: "agent_message_chunk", text: message)
            )
            return .finished(stopReason: "end_turn")
        case let .generate(prompt, purpose, prelude):
            _ = await updateReservedPromptSession(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID) { live in
                if case .workflow = purpose {
                    live.activeWorkflowPromptID = turn.promptID
                } else {
                    live.activeWorkflowPromptID = nil
                }
            }
            if let prelude {
                await writer.sendSessionUpdate(
                    sessionID: turn.sessionID,
                    update: Self.textChunkJSONUpdate(kind: "agent_message_chunk", text: prelude)
                )
            }
            guard let liveCommandSession = await reservedPromptSession(
                sessionID: turn.sessionID,
                epoch: turn.epoch,
                promptID: turn.promptID
            ) else {
                throw CancellationError()
            }
            return .generate(prompt: prompt, purpose: purpose, session: liveCommandSession)
        }
    }

    /// Runs the turn's task on the model, with the turn's update pipeline
    /// and task-graph presentation around it, and settles the turn once the
    /// task ends.
    private func executePromptTurn(
        _ turn: ACPPromptTurn,
        prompt modelPromptText: String,
        purpose commandPurpose: ACPCommandPromptPurpose,
        attachments: [AgentRuntimeAttachment],
        session: SessionState
    ) async throws -> ACPPromptTurnOutcome {
        let controller = session.controller
        let chatPurpose = Self.chatTurnPurpose(for: commandPurpose, session: session)
        let promptConfiguration = session.configuration.addingAllowedToolNames(
            controller.additionalToolNames(for: chatPurpose)
        )
        let updatePipeline = makePromptUpdatePipeline(turn, modelID: promptConfiguration.modelID)
        // ACP locations must be absolute. Relative tool arguments are resolved
        // by the tools against the session workspace, not against the agent
        // process directory chosen by the launching client.
        let workspaceURL = URL(fileURLWithPath: session.cwd)

        // The session may have been closed, replaced, or shut down while the
        // prompt was being prepared; never start generation for a dead session.
        guard await reservedPromptSession(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID) != nil else {
            throw CancellationError()
        }

        let presentation = await startPromptTurnPresentation(turn, session: session, pipeline: updatePipeline)
        let clientFiles = clientTextFileSystem(sessionID: turn.sessionID, epoch: turn.epoch)
        let presenter = ACPPromptPresenter(
            sessionID: turn.sessionID,
            workspaceURL: workspaceURL,
            writer: writer,
            updatePipeline: updatePipeline,
            ensureTasklessObserver: { [weak self] in
                await self?.ensureTasklessObserver(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID)
            },
            claimDelegatedToolNotification: { [weak self] notificationID in
                await self?.claimDelegatedToolNotification(
                    notificationID, sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID
                ) ?? false
            }
        )
        let activePromptTask = Task(name: "ZenCODEACPBridge.prompt") {
            try await ClientTextFileSystem.$current.withValue(clientFiles) {
                await applySelectedAgentSkills(
                    sessionID: promptConfiguration.sessionID,
                    selectedAgent: session.selectedAgent
                )
                try Task.checkCancellation()
                guard let currentSession = await reservedPromptSession(
                    sessionID: turn.sessionID,
                    epoch: turn.epoch,
                    promptID: turn.promptID
                ) else {
                    throw CancellationError()
                }
                let commands = availableCommandsUpdate(for: currentSession)
                if currentSession.presentedCommands != commands {
                    sessions[turn.sessionID]?.presentedCommands = commands
                    await Self.sendPromptUpdate(commands, through: updatePipeline)
                }
                if !currentSession.hasPresentedInitialConfiguration {
                    // Claim before suspending. This flag belongs to this live ACP
                    // incarnation, not to the backend conversation or its snapshot.
                    sessions[turn.sessionID]?.hasPresentedInitialConfiguration = true
                    await Self.sendPromptUpdate(
                        Self.textChunkJSONUpdate(
                            kind: "agent_message_chunk",
                            text: initialConfigurationSummary(for: currentSession)
                        ),
                        through: updatePipeline
                    )
                    // In app mode, do not leave the summary buffered until the
                    // first model event: it must already be visible before generation.
                    await Self.flushPromptUpdates(through: updatePipeline)
                }
                try Task.checkCancellation()
                guard await reservedPromptSession(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID) != nil else {
                    throw CancellationError()
                }
                let result = try await controller.runTurn(
                    ChatTurnRequest(
                        prompt: modelPromptText,
                        attachments: attachments,
                        purpose: chatPurpose,
                        sessionConfiguration: promptConfiguration,
                        presenter: presenter
                    )
                )
                return PromptCompletion(
                    text: result.response.text,
                    finalAssistantBlock: result.finalAssistantBlock,
                    stopReason: Self.acpStopReason(result.response.stopReason),
                    modelID: result.response.modelID,
                    fileChangeSummary: result.fileChangeSummary
                )
            }
        }
        try await registerPromptTurnTask(activePromptTask, turn, session: session, presentation: presentation)

        let outcome: ACPPromptTurnOutcome
        do {
            let completion = try await activePromptTask.value
            if case .planning = commandPurpose {
                await Self.sendPromptUpdate(
                    Self.textChunkJSONUpdate(kind: "agent_message_chunk", text: completion.text),
                    through: updatePipeline
                )
            }
            outcome = .stopped(stopReason: completion.stopReason)
        } catch {
            // The controller already cleaned up a turn it ran. A turn that
            // stopped before reaching it can only have been cancelled; keep
            // the Planner discussion bound to this live incarnation.
            if !(error is ChatTurnFailure),
               case let .planning(collectionID) = commandPurpose {
                await clearACPPlanBrainstorming(sessionID: turn.sessionID, epoch: turn.epoch, expectedCollectionID: collectionID)
            }
            let underlying = (error as? ChatTurnFailure)?.underlying ?? error
            outcome = underlying is CancellationError
                ? .stopped(stopReason: "cancelled")
                : .failed(Self.acpPromptError(for: underlying))
        }
        // Settled once the outcome is known, after the planning text or the
        // brainstorming cleanup it may owe: the order the turn always had.
        await settlePromptTurn(turn, presentation, preservingAllowedToolNames: session.allowedToolNames)
        return outcome
    }

    /// The update pipeline of one turn: the single serialized exit for
    /// app-mode buffering and ChatGPT-only thinking presentation. Non-app
    /// mode still writes every fragment directly. Overlapping `@Sendable`
    /// callbacks must not interleave buffer drains with writer calls, or a
    /// later notification could overtake content an earlier callback had
    /// already claimed; the pipeline chains every unit so the wire order
    /// equals the enqueue order.
    private func makePromptUpdatePipeline(
        _ turn: ACPPromptTurn,
        modelID: String?
    ) -> ACPPromptUpdatePipeline {
        let normalizesChatGPTThoughts = AgentSettingsStore.defaultSelection(
            explicitModelID: modelID
        )?.remoteProvider?.isChatGPTSubscriptionProvider == true
        return ACPPromptUpdatePipeline(
            sessionID: turn.sessionID,
            writer: writer,
            buffer: ACPPromptUpdateBuffer(),
            buffersUpdates: configuration.appMode,
            normalizesChatGPTThoughts: normalizesChatGPTThoughts,
            isValid: { await self.isCurrentPresentation(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID) },
            canDeliver: { await self.canDeliverPresentation(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID) }
        )
    }

    /// Writes `update` through the turn's `pipeline`. Awaiting the unit's
    /// own task preserves the producer's backpressure (the turn does not
    /// advance until the update has actually been written) while the chain
    /// fixes the wire order.
    private static func sendPromptUpdate(_ update: JSONValue, through pipeline: ACPPromptUpdatePipeline) async {
        await pipeline.enqueue(.init(kind: .consume(update))).value
    }

    /// Writes what the turn's `pipeline` buffered.
    private static func flushPromptUpdates(through pipeline: ACPPromptUpdatePipeline) async {
        await pipeline.enqueue(.init(kind: .flush)).value
    }

    /// Gives the live incarnation the turn's update `pipeline` and starts
    /// presenting through it the taskless agents and the task graph.
    private func startPromptTurnPresentation(
        _ turn: ACPPromptTurn,
        session: SessionState,
        pipeline: ACPPromptUpdatePipeline
    ) async -> ACPPromptTurnPresentation {
        updateLiveSession(id: turn.sessionID, epoch: turn.epoch) { live in
            live.promptUpdatePipeline = pipeline
            live.delegatedToolNotifications.removeAll()
        }
        // Persistent taskless agents may run during a text-only follow-up.
        await ensureTasklessObserver(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID)
        let taskPresentation = session.taskPresentation
        let graphEvents = await sessionRunner.taskOrchestrator.events(sessionID: turn.sessionID)
        let graphObserver = Task {
            await publishTaskPresentation(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID,
                                          presentation: taskPresentation, pipeline: pipeline)
            for await _ in graphEvents {
                guard !Task.isCancelled else { return }
                await publishTaskPresentation(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID,
                                              presentation: taskPresentation, pipeline: pipeline)
            }
        }
        return ACPPromptTurnPresentation(
            pipeline: pipeline,
            taskPresentation: taskPresentation,
            graphObserver: graphObserver
        )
    }

    /// Ends the turn's presentation: the live incarnation gives the turn's
    /// pipeline and taskless observer back (only while they are still the
    /// turn's), the task-graph observer stops, the last task graph is
    /// published, and the pipeline drains.
    private func finishPromptTurnPresentation(
        _ turn: ACPPromptTurn,
        _ presentation: ACPPromptTurnPresentation
    ) async {
        if liveSession(id: turn.sessionID, epoch: turn.epoch)?.promptUpdatePipeline === presentation.pipeline {
            let tasklessObserver = sessions[turn.sessionID]?.tasklessObserver
            sessions[turn.sessionID]?.tasklessObserver = nil
            sessions[turn.sessionID]?.promptUpdatePipeline = nil
            tasklessObserver?.cancel()
            await tasklessObserver?.value
        }
        presentation.graphObserver.cancel()
        await presentation.graphObserver.value
        await publishTaskPresentation(sessionID: turn.sessionID, epoch: turn.epoch, promptID: turn.promptID,
                                      presentation: presentation.taskPresentation, pipeline: presentation.pipeline)
        await presentation.pipeline.drain()
    }

    /// Registers the turn's task under the reservation: the bridge's own
    /// entry first, so a `session/cancel` that lands from now on finds the
    /// task and cancels it, then the host's reservation is checked. A cancel
    /// that landed between the reservation and this point already dropped
    /// the reservation, so the check fails and the task is cancelled here
    /// (otherwise the cancel would be silently lost because it had no task
    /// to cancel yet), the turn's presentation ends, and the turn throws.
    private func registerPromptTurnTask(
        _ activePromptTask: Task<PromptCompletion, Error>,
        _ turn: ACPPromptTurn,
        session: SessionState,
        presentation: ACPPromptTurnPresentation
    ) async throws {
        var didRegisterPromptTask = false
        updateLiveSession(id: turn.sessionID, epoch: turn.epoch) { session in
            session.activePromptTask = activePromptTask
            session.activePromptTaskID = turn.promptID
            didRegisterPromptTask = true
        }
        guard didRegisterPromptTask, await host.holdsPrompt(session.promptReservation(turn.promptID)) else {
            activePromptTask.cancel()
            updateLiveSession(id: turn.sessionID, epoch: turn.epoch) { session in
                if session.activePromptTaskID == turn.promptID {
                    session.activePromptTask = nil
                    session.activePromptTaskID = nil
                }
            }
            await finishPromptTurnPresentation(turn, presentation)
            throw CancellationError()
        }
    }

    /// Settles the turn: its task presentation, its buffered updates, and
    /// the session snapshot.
    private func settlePromptTurn(
        _ turn: ACPPromptTurn,
        _ presentation: ACPPromptTurnPresentation,
        preservingAllowedToolNames allowedToolNames: Set<String>?
    ) async {
        await finishPromptTurnPresentation(turn, presentation)
        await Self.flushPromptUpdates(through: presentation.pipeline)
        await refreshSessionStateIfAvailable(
            sessionID: turn.sessionID,
            preservingAllowedToolNames: allowedToolNames,
            expectedEpoch: turn.epoch,
            expectedPromptID: turn.promptID
        )
    }

    /// The shared chat purpose of an ACP command turn.
    static func chatTurnPurpose(
        for purpose: ACPCommandPromptPurpose,
        session: SessionState
    ) -> ChatTurnPurpose {
        switch purpose {
        case .normal, .implementation:
            return .normal
        case let .workflow(graphID):
            let workflow = session.controller.commandState.activeWorkflow
            return .workflow(
                originalGoal: workflow?.graphID == graphID ? workflow?.goal ?? "" : "",
                graphID: graphID
            )
        case .review:
            return .review
        case .planning:
            return .plan(originalGoal: session.controller.commandState.planBrainstorming?.goal ?? "")
        }
    }

    /// Planner failures keep their established ACP messages on the wire.
    static func acpPromptError(for error: Error) -> Error {
        guard let planningError = error as? ChatPlanGenerationError else {
            return error
        }
        switch planningError {
        case .plannerOutputUnavailable:
            return ACPPlanningCommandError.plannerOutputUnavailable
        case .sessionHistoryUnavailable:
            return ACPPlanningCommandError.sessionHistoryUnavailable
        case .structuredTasksUnavailable:
            return ACPPlanningCommandError.structuredTasksUnavailable
        case .unexpectedStructuredTasksForQuestions:
            return ACPPlanningCommandError.unexpectedTasksForQuestions
        }
    }

    public static func acpStopReason(_ value: String?) -> String {
        switch value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "end_turn", "endturn":
            return "end_turn"
        case "max_tokens", "max_output_tokens", "length":
            return "max_tokens"
        case "max_turn_requests", "tool_round_limit", "too_many_tool_rounds":
            return "max_turn_requests"
        case "refusal", "content_filter", "safety":
            return "refusal"
        case "cancelled", "canceled", "cancel":
            return "cancelled"
        default:
            return "end_turn"
        }
    }

    public func cancel(id: JSONValue?, params: [String: Any]) async throws {
        // After shutdown every prompt was already cancelled and `sessions` is
        // empty; without this fence the handler would answer "unknown session"
        // on a transport that is closing.
        try ensureNotShutDown()
        guard let sessionID = Self.sessionID(from: params),
              let session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        // The task of the prompt being cancelled is read before the hop to the
        // host: it is the only task a cancel may touch, so a prompt reserved
        // right after the host dropped this reservation keeps its own. The
        // host fences the controller and drops the reservation in one step,
        // arming workflow recovery only when the cancelled prompt is the
        // workflow prompt; the cancelled turn can no longer write command
        // state back while it unwinds. The reply route projects any newer
        // persisted pause before consuming the armed recovery. A
        // reconfiguration in progress is not a prompt and is left to its
        // owner. A turn from Telegram (the slot's Telegram channel holds the
        // reservation while it drives the slot) is stopped in the channel too,
        // so it ends now and the chat is told it stopped.
        let cancelledTask = session.activePromptTask
        let cancelledTaskPromptID = session.activePromptTaskID
        let workflowPromptID = session.activeWorkflowPromptID
        // A prompt still waiting for the startup offer of old task graphs has
        // no reservation yet: it is marked, so it ends as `cancelled` once the
        // offer ends (the client answers the offer's pending permission
        // request with `cancelled` itself).
        cancelPromptsAwaitingResumableTaskGraphOffer(sessionID: sessionID, epoch: session.epoch)
        let cancelledPromptID = await host.cancelPrompt(in: session.slotID) { promptID in
            promptID == workflowPromptID
        }
        cancelledTask?.cancel()
        updateLiveSession(id: sessionID, epoch: session.epoch) { live in
            if let cancelledTaskPromptID, live.activePromptTaskID == cancelledTaskPromptID {
                live.activePromptTask = nil
                live.activePromptTaskID = nil
            }
            if let cancelledPromptID, live.activeWorkflowPromptID == cancelledPromptID {
                live.activeWorkflowPromptID = nil
            }
        }
        if let cancelledPromptID {
            await host.stopTelegramTurnIfReserved(cancelledPromptID, in: session.slotID)
        }
        await clearACPPlanBrainstorming(sessionID: sessionID, epoch: session.epoch)
        await writer.sendResultIfRequest(id: id, result: .object([:]))
    }

    public func close(id: JSONValue?, params: [String: Any]) async throws {
        try ensureNotShutDown()
        guard let sessionID = Self.sessionID(from: params) else {
            throw ACPError.invalidParams("session/close requires params.sessionId.")
        }
        await closeACPSession(sessionID: sessionID)
        // `closeACPSession` suspends: a shutdown landing there already failed all
        // pending requests, so do not write a late reply.
        try ensureNotShutDown()
        await writer.sendResultIfRequest(id: id, result: .object([:]))
    }

    /// `session/delete`: ends the session as `session/close` does when the
    /// bridge runs it (``closeACPSession(sessionID:)``, the same path), then
    /// deletes, in every project, the saved sessions of its id that ACP saved
    /// by itself (``deleteAutosavedSessions(sessionID:)``). A session id that
    /// is unknown, already deleted, or has nothing saved answers `{}` too; a
    /// saved session that cannot be removed answers with the error. The saved
    /// sessions of the id that the user saved with `/sessions` stay.
    func deleteSession(id: JSONValue?, params: [String: Any]) async throws {
        try ensureNotShutDown()
        guard let sessionID = Self.sessionID(from: params) else {
            throw ACPError.invalidParams("session/delete requires params.sessionId.")
        }
        // The entry is dropped before the files: no save of this incarnation
        // can write its file again once they are gone.
        if sessions[sessionID] != nil {
            await closeACPSession(sessionID: sessionID)
        }
        var deletionError: Error?
        do {
            try await deleteAutosavedSessions(sessionID: sessionID)
        } catch {
            deletionError = error
        }
        try ensureNotShutDown()
        if let deletionError {
            throw deletionError
        }
        await writer.sendResultIfRequest(id: id, result: .object([:]))
    }

    /// Ends the session `sessionID` for `session/close` and
    /// `session/delete`, up to their reply: the live incarnation, if any, is
    /// dropped before any suspension and retired in the host, its prompts and
    /// lifecycle operations are cancelled and drained, its MCP servers
    /// released, and its slot closed with its runner session.
    func closeACPSession(sessionID: String) async {
        // Drop the session before any suspension so a prompt finishing
        // concurrently cannot restore it through refreshSessionStateIfAvailable.
        // In the same step the host retires the incarnation: its controller is
        // fenced and nothing more is reserved on its slot (no `session/prompt`
        // served late, no turn the slot's Telegram channel reads meanwhile),
        // while the slot itself lives until the drains below are done.
        let closedSession = sessions.removeValue(forKey: sessionID)
        if let closedSession {
            host.retireIncarnation(in: closedSession.slotID, controller: closedSession.controller)
        }
        closedSession?.tasklessObserver?.cancel()
        // Withdraw the startup offer of old task graphs before anything
        // suspends: its pending `session/request_permission` returns, so the
        // offer ends as Start fresh and the prompts waiting for it can be
        // drained below.
        let cancelledTaskGraphOffer = closedSession.flatMap {
            cancelResumableTaskGraphOffer(sessionID: sessionID, epoch: $0.epoch)
        }
        // Snapshot before the first suspension. Teardown below awaits several
        // collaborators; a session recreated with this id during that window
        // owns different prompt handlers and must not hold this close hostage.
        let promptHandlersToDrain = promptHandlerTokensSnapshot(sessionID: sessionID)
        await permissionBroker.removeCachedDecisions(sessionID: sessionID)
        await closedSession?.tasklessObserver?.value
        await closedSession?.promptUpdatePipeline?.drain()
        closedSession?.activePromptTask?.cancel()
        if let closedEpoch = closedSession?.epoch {
            // Invalidate the lifecycle work bound to the incarnation we are
            // closing: a `set_model`, `set_config_option` or restore suspended
            // inside the runner must not complete, re-create the session in the
            // backend, and answer success for a session that is now gone.
            invalidateLifecycleOperations(sessionID: sessionID, epoch: closedEpoch)
            // The MCP servers this session provided are torn down with it.
            // Registrations owned by other sessions or with no session
            // ownership (borrowed/non-ACP installs) survive untouched.
            await sessionRunner.releaseSessionMCPOwnership(sessionID: sessionID, epoch: closedEpoch)
        }
        // The withdrawn offer ends before the drain: nothing of it reaches the
        // wire after this close's reply, and the prompts it held wake up.
        await cancelledTaskGraphOffer?.value
        // Quiesce the ACP prompt wrapper before anything else can answer: with
        // the backend turn already cancelled above, its unwind — the buffered
        // update flush, the snapshot refresh and the `cancelled` reply — is
        // guaranteed to finish, and it belongs on the wire strictly before this
        // close's own reply. The runner's `closeSession` below additionally
        // waits for the backend-side prompt tasks it owns.
        await waitForPromptHandlersToDrain(sessionID: sessionID, tokens: promptHandlersToDrain)
        // The host ends the incarnation and closes the runner session.
        // `AgentCoreSessionRunner` keys its state by session id, not ACP
        // incarnation: if a `session/load` recreated this id while the old
        // prompt wrapper was draining, closing the runner now would cancel the
        // new prompt as well. The host closes the runner session only while no
        // other slot runs the id, so the replacement owns the runner entry
        // from the moment it exists. An id the bridge never ran is closed in
        // the runner directly, as before.
        if let closedSession {
            await host.closeSlot(closedSession.slotID, runtimeSession: .close)
        } else if sessions[sessionID] == nil {
            await sessionRunner.closeSession(id: sessionID)
        }
        // Re-drop in case a racing handler re-created the entry while the
        // runner was closing the session.
        if let resurrected = sessions[sessionID],
           resurrected.epoch == closedSession?.epoch {
            sessions.removeValue(forKey: sessionID)
        }
    }
}
