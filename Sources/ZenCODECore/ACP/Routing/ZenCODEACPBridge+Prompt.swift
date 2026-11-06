//
//  ZenCODEACPBridge+Prompt.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

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

    private func runPrompt(
        id: JSONValue?,
        params: [String: Any],
        sessionID: String,
        session initialSession: SessionState,
        promptID: UUID,
        epoch: UInt64,
        releaseReservation: () async -> Void
    ) async throws {
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

        var promptConfiguration: AgentCoreSessionConfiguration
        if let agentMentionResolution {
            promptConfiguration = await acpSessionConfiguration(
                applying: agentMentionResolution.agent,
                to: session.configuration
            )
            // Keep the same incarnation and reservation: routing to another
            // agent updates the configuration, it does not restart the session.
            let isLive = updateLiveSession(id: sessionID, epoch: epoch) { live in
                live = sessionState(
                    configuration: promptConfiguration,
                    selectedAgent: agentMentionResolution.agent,
                    inheriting: live
                )
            }
            guard isLive, let mentionedSession = liveSession(id: sessionID, epoch: epoch) else {
                throw CancellationError()
            }
            session = mentionedSession
        } else {
            promptConfiguration = session.configuration
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
        await sendUserMessageChunk(sessionID: sessionID, text: visiblePromptText)
        await sendSessionInfoUpdate(sessionID: sessionID, title: promptTitle(from: visiblePromptText))

        let commandRoute: ACPCommandTurnRoute
        do {
            commandRoute = try await routeACPCommandTurn(
                command: coordinatorCommand,
                routedPromptText: routedPromptText,
                hasAgentMention: agentMentionResolution != nil,
                sessionID: sessionID,
                epoch: epoch,
                promptID: promptID
            )
        } catch is CancellationError {
            await sendStopReason(id: id, "cancelled")
            await releaseReservation()
            return
        }
        guard await reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else {
            await sendStopReason(id: id, "cancelled")
            await releaseReservation()
            return
        }
        let modelPromptText: String
        let commandPurpose: ACPCommandPromptPurpose
        switch commandRoute {
        case let .immediate(message):
            await writer.sendSessionUpdate(
                sessionID: sessionID,
                update: Self.textChunkJSONUpdate(kind: "agent_message_chunk", text: message)
            )
            await sendStopReason(id: id, "end_turn")
            await releaseReservation()
            return
        case let .generate(prompt, purpose, prelude):
            modelPromptText = prompt
            commandPurpose = purpose
            _ = await updateReservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) { live in
                if case .workflow = purpose {
                    live.activeWorkflowPromptID = promptID
                } else {
                    live.activeWorkflowPromptID = nil
                }
            }
            if let prelude {
                await writer.sendSessionUpdate(
                    sessionID: sessionID,
                    update: Self.textChunkJSONUpdate(kind: "agent_message_chunk", text: prelude)
                )
            }
        }

        guard let liveCommandSession = await reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            throw CancellationError()
        }
        session = liveCommandSession
        let controller = session.controller
        let chatPurpose = Self.chatTurnPurpose(for: commandPurpose, session: session)
        promptConfiguration = session.configuration.addingAllowedToolNames(
            controller.additionalToolNames(for: chatPurpose)
        )

        let writer = self.writer
        let appMode = configuration.appMode
        // Single serialized exit point for app-mode buffering and ChatGPT-only
        // thinking presentation. Non-app mode still writes every fragment directly.
        // Overlapping
        // `@Sendable` callbacks must not interleave buffer drains with writer
        // calls, or a later notification could overtake content an earlier
        // callback had already claimed; the pipeline chains every unit so the
        // wire order equals the enqueue order.
        let normalizesChatGPTThoughts = AgentSettingsStore.defaultSelection(
            explicitModelID: promptConfiguration.modelID
        )?.remoteProvider?.isChatGPTSubscriptionProvider == true
        let updatePipeline: ACPPromptUpdatePipeline? = ACPPromptUpdatePipeline(
                sessionID: sessionID,
                writer: writer,
                buffer: ACPPromptUpdateBuffer(),
                buffersUpdates: appMode,
                normalizesChatGPTThoughts: normalizesChatGPTThoughts,
                isValid: { await self.isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) },
                canDeliver: { await self.canDeliverPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) }
            )
        let sessionRunner = self.sessionRunner
        // ACP locations must be absolute. Relative tool arguments are resolved
        // by the tools against the session workspace, not against the agent
        // process directory chosen by the launching client.
        let workspaceURL = URL(fileURLWithPath: session.cwd)

        @Sendable func sendPromptUpdate(_ update: JSONValue) async {
            if let updatePipeline {
                // Awaiting the unit's own task preserves the producer's
                // backpressure (the turn does not advance until the update has
                // actually been written) while the chain fixes the wire order.
                await updatePipeline.enqueue(.init(kind: .consume(update))).value
            } else {
                await writer.sendSessionUpdate(sessionID: sessionID, update: update)
            }
        }

        @Sendable func flushPromptUpdates() async {
            guard let updatePipeline else {
                return
            }
            await updatePipeline.enqueue(.init(kind: .flush)).value
        }

        // The session may have been closed, replaced, or shut down while the
        // prompt was being prepared; never start generation for a dead session.
        guard await reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else {
            throw CancellationError()
        }

        updateLiveSession(id: sessionID, epoch: epoch) { live in
            live.promptUpdatePipeline = updatePipeline
            live.delegatedToolNotifications.removeAll()
        }
        // Persistent taskless agents may run during a text-only follow-up.
        await ensureTasklessObserver(sessionID: sessionID, epoch: epoch, promptID: promptID)
        await sessionRunner.updateSubAgentToolEventHandler { [weak self] event in
            await self?.presentDelegatedToolEvent(event)
        }
        let taskPresentation = session.taskPresentation
        let graphEvents = await sessionRunner.taskOrchestrator.events(sessionID: sessionID)
        let graphObserver = Task {
            guard let updatePipeline else { return }
            await publishTaskPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID,
                                          presentation: taskPresentation, pipeline: updatePipeline)
            for await _ in graphEvents {
                guard !Task.isCancelled else { return }
                await publishTaskPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID,
                                              presentation: taskPresentation, pipeline: updatePipeline)
            }
        }
        func finishTaskPresentation() async {
            if liveSession(id: sessionID, epoch: epoch)?.promptUpdatePipeline === updatePipeline {
                let tasklessObserver = sessions[sessionID]?.tasklessObserver
                sessions[sessionID]?.tasklessObserver = nil
                sessions[sessionID]?.promptUpdatePipeline = nil
                tasklessObserver?.cancel()
                await tasklessObserver?.value
            }
            graphObserver.cancel()
            await graphObserver.value
            if let updatePipeline {
                await publishTaskPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID,
                                              presentation: taskPresentation, pipeline: updatePipeline)
                await updatePipeline.drain()
            }
        }
        let clientFiles = clientTextFileSystem(sessionID: sessionID, epoch: epoch)
        let presenter = ACPPromptPresenter(
            sessionID: sessionID,
            workspaceURL: workspaceURL,
            writer: writer,
            updatePipeline: updatePipeline,
            ensureTasklessObserver: { [weak self] in
                await self?.ensureTasklessObserver(sessionID: sessionID, epoch: epoch, promptID: promptID)
            }
        )
        let activePromptTask = Task(name: "ZenCODEACPBridge.prompt") {
            try await ClientTextFileSystem.$current.withValue(clientFiles) {
                await applySelectedAgentSkills(
                    sessionID: promptConfiguration.sessionID,
                    selectedAgent: session.selectedAgent
                )
                try Task.checkCancellation()
                guard let currentSession = await reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
                    throw CancellationError()
                }
                let commands = availableCommandsUpdate(for: currentSession)
                if currentSession.presentedCommands != commands {
                    sessions[sessionID]?.presentedCommands = commands
                    await sendPromptUpdate(commands)
                }
                if !currentSession.hasPresentedInitialConfiguration {
                    // Claim before suspending. This flag belongs to this live ACP
                    // incarnation, not to the backend conversation or its snapshot.
                    sessions[sessionID]?.hasPresentedInitialConfiguration = true
                    await sendPromptUpdate(
                        Self.textChunkJSONUpdate(
                            kind: "agent_message_chunk",
                            text: initialConfigurationSummary(for: currentSession)
                        ))
                    // In app mode, do not leave the summary buffered until the
                    // first model event: it must already be visible before generation.
                    await flushPromptUpdates()
                }
                try Task.checkCancellation()
                guard await reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else {
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

        // Register the task under the reservation: the bridge's own entry
        // first, so a `session/cancel` that lands from now on finds the task
        // and cancels it, then the host's reservation is checked. A cancel that
        // landed between the reservation and this point already dropped the
        // reservation, so the check fails and the task is cancelled here:
        // otherwise the cancel would be silently lost because it had no task
        // to cancel yet.
        var didRegisterPromptTask = false
        updateLiveSession(id: sessionID, epoch: epoch) { session in
            session.activePromptTask = activePromptTask
            session.activePromptTaskID = promptID
            didRegisterPromptTask = true
        }
        guard didRegisterPromptTask, await host.holdsPrompt(session.promptReservation(promptID)) else {
            activePromptTask.cancel()
            updateLiveSession(id: sessionID, epoch: epoch) { session in
                if session.activePromptTaskID == promptID {
                    session.activePromptTask = nil
                    session.activePromptTaskID = nil
                }
            }
            await finishTaskPresentation()
            throw CancellationError()
        }

        /// Ends the turn: its task presentation, its buffered updates, and
        /// the session snapshot.
        func settleTurn() async {
            await finishTaskPresentation()
            await flushPromptUpdates()
            await refreshSessionStateIfAvailable(
                sessionID: sessionID,
                preservingAllowedToolNames: session.allowedToolNames,
                expectedEpoch: epoch,
                expectedPromptID: promptID
            )
        }
        do {
            let completion = try await activePromptTask.value
            if case .planning = commandPurpose {
                await sendPromptUpdate(
                    Self.textChunkJSONUpdate(kind: "agent_message_chunk", text: completion.text)
                )
            }
            await settleTurn()
            await sendStopReason(id: id, completion.stopReason)
            await releaseReservation()
        } catch {
            // The controller already cleaned up a turn it ran. A turn that
            // stopped before reaching it can only have been cancelled; keep
            // the Planner discussion bound to this live incarnation.
            if !(error is ChatTurnFailure),
               case let .planning(collectionID) = commandPurpose {
                await clearACPPlanBrainstorming(sessionID: sessionID, epoch: epoch, expectedCollectionID: collectionID)
            }
            let underlying = (error as? ChatTurnFailure)?.underlying ?? error
            if underlying is CancellationError {
                await settleTurn()
                await sendStopReason(id: id, "cancelled")
                await releaseReservation()
            } else {
                let promptError = Self.acpPromptError(for: underlying)
                await settleTurn()
                await releaseReservation()
                throw promptError
            }
        }
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
        // `closeSession` suspends: a shutdown landing there already failed all
        // pending requests, so do not write a late reply.
        try ensureNotShutDown()
        await writer.sendResultIfRequest(id: id, result: .object([:]))
    }
}
