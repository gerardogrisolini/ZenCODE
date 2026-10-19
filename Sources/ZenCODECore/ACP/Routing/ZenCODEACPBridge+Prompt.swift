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
        // abandoned silently instead.
        try ensureNotShutDown()
        guard let sessionID = Self.sessionID(from: params),
              var session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        guard case .idle = session.operationState,
              session.activePromptID == nil,
              session.activePromptTask == nil else {
            throw ACPError.invalidParams("A prompt is already running for this session.")
        }

        // Reserve the session synchronously, before the first `await`. Actor
        // reentrancy would otherwise let a second `session/prompt` pass the
        // guard above while this one is suspended parsing or resolving tools.
        let promptID = UUID()
        let epoch = session.epoch
        session.activePromptID = promptID
        session.operationState = .prompting(promptID)
        sessions[sessionID] = session
        var didReleaseReservation = false
        // Track the ACP wrapper handler itself, not only the backend turn:
        // `close`/`shutdown` must be able to wait for this handler's unwind
        // (update flush, snapshot refresh, final reply) before answering.
        let promptHandlerToken = enterPromptHandler(sessionID: sessionID)
        defer { leavePromptHandler(sessionID: sessionID, token: promptHandlerToken) }

        /// Releases the reservation only when it is still ours and the session
        /// is still the same incarnation.
        func releaseReservation() {
            guard !didReleaseReservation else {
                return
            }
            didReleaseReservation = true
            updateLiveSession(id: sessionID, epoch: epoch) { session in
                guard session.activePromptID == promptID,
                      case let .prompting(activePromptID) = session.operationState,
                      activePromptID == promptID else {
                    return
                }
                session.activePromptID = nil
                session.activeWorkflowPromptID = nil
                session.activePromptTask = nil
                session.operationState = .idle
            }
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
            releaseReservation()
            throw error
        }
        releaseReservation()
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
        releaseReservation: () -> Void
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
            session = sessionStateWithCommandState(
                configuration: promptConfiguration,
                selectedAgent: agentMentionResolution.agent,
                epoch: epoch,
                activePromptID: promptID,
                operationState: .prompting(promptID),
                activePlan: session.activePlan,
                planBrainstorming: session.planBrainstorming,
                workflowContinuation: session.workflowContinuation
            )
            guard updateLiveSession(id: sessionID, epoch: epoch, { liveSession in
                liveSession = session
            }) else {
                throw CancellationError()
            }
        } else {
            promptConfiguration = session.configuration
        }

        let coordinatorCommand = CoordinatorCommandParser.parse(routedPromptText)
        let isPlanningReply = coordinatorCommand == nil
            && agentMentionResolution == nil
            && !CoordinatorCommandParser.isSlashCommand(routedPromptText)
            && session.planBrainstorming?.isAwaitingReply == true
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
            releaseReservation()
            return
        }
        guard reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else {
            await sendStopReason(id: id, "cancelled")
            releaseReservation()
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
            releaseReservation()
            return
        case let .generate(prompt, purpose, prelude):
            modelPromptText = prompt
            commandPurpose = purpose
            _ = updateReservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) { live in
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

        guard let liveCommandSession = liveSession(id: sessionID, epoch: epoch),
              liveCommandSession.activePromptID == promptID else {
            throw CancellationError()
        }
        session = liveCommandSession
        promptConfiguration = session.configuration
        if var allowedToolNames = promptConfiguration.allowedToolNames,
           !commandPurpose.additionalToolNames.isEmpty {
            allowedToolNames.formUnion(commandPurpose.additionalToolNames)
            promptConfiguration = sessionConfiguration(from: promptConfiguration, allowedToolNames: allowedToolNames)
        }

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
        guard reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else {
            throw CancellationError()
        }

        sessions[sessionID]?.promptUpdatePipeline = updatePipeline
        sessions[sessionID]?.delegatedToolNotifications.removeAll()
        // Persistent taskless agents may run during a text-only follow-up.
        await ensureTasklessObserver(sessionID: sessionID, epoch: epoch, promptID: promptID)
        await sessionRunner.updateSubAgentToolEventHandler { [weak self] event in
            await self?.presentDelegatedToolEvent(event)
        }
        let planPointCollector = PlanningPointCollector()
        let assistantBlocks = ACPAssistantBlockCollector()
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
        let clientFiles = clientFileSystem?.access(sessionID: sessionID) { [weak self] in
            await self?.canUseClientFileSystem(sessionID: sessionID, epoch: epoch) == true
        }
        let activePromptTask = Task(name: "ZenCODEACPBridge.prompt") {
            try await ClientTextFileSystem.$current.withValue(clientFiles) {
                await sessionRunner.updatePromptSkillSelection(
                    selectedAgentSkills(for: session.selectedAgent),
                    sessionID: promptConfiguration.sessionID
                )
                try Task.checkCancellation()
                guard let currentSession = reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
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
                guard reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else {
                    throw CancellationError()
                }
                var generationPrompt = modelPromptText
                var generationAttachments = attachments
                while true {
                    let response = try await sessionRunner.sendPrompt(
                        configuration: promptConfiguration,
                        prompt: generationPrompt,
                        attachments: generationAttachments,
                        toolProviders: [],
                        onEvent: { event in
                            switch event {
                            case .status, .diagnostic, .modelLoaded:
                                // Runtime lifecycle and diagnostics are not model reasoning.
                                // Model selection is already exposed through ACP configuration.
                                break
                            case let .thought(message):
                                await sendPromptUpdate(
                                    Self.textChunkJSONUpdate(kind: "agent_thought_chunk", text: message)
                                )
                            case .metrics:
                                break
                            case let .contextWindow(status):
                                if let update = Self.usageJSONUpdate(for: status) {
                                    await sendPromptUpdate(update)
                                }
                            case let .subscriptionUsage(status):
                                if let subscriptionData = Self.subscriptionUsageJSONData(for: status) {
                                    // The custom notification bypasses the buffer. In app
                                    // mode it must share the serialized exit point with
                                    // updates, as a flush-then-notify unit; outside app
                                    // mode there is no buffer and it goes straight out.
                                    let params = JSONValue.object([
                                        "sessionId": .string(sessionID),
                                        "subscription": subscriptionData,
                                    ])
                                    if let updatePipeline {
                                        await updatePipeline.enqueue(
                                            .init(kind: .flushThenNotify(method: "_zencode/usage/subscription", params: params))
                                        ).value
                                    } else {
                                        await writer.sendCustomNotification(method: "_zencode/usage/subscription", params: params)
                                    }
                                }
                            case let .content(content):
                                await assistantBlocks.append(content)
                                if !commandPurpose.suppressesCoordinatorContent {
                                    await sendPromptUpdate(
                                        Self.textChunkJSONUpdate(kind: "agent_message_chunk", text: content)
                                    )
                                }
                            case let .toolCallStarted(toolCall):
                                await self.ensureTasklessObserver(
                                    sessionID: sessionID, epoch: epoch, promptID: promptID)
                                await assistantBlocks.finishBlock()
                                await sendPromptUpdate(
                                    Self.toolCallCreateJSONUpdate(for: toolCall, workingDirectory: workspaceURL)
                                )
                            case let .toolCallCompleted(toolCall, result):
                                if case .planning = commandPurpose {
                                    let request = DirectTodoTaskRuntime.normalizedToolRequest(for: toolCall)
                                    if request.name == "todo.write" {
                                        let update =
                                            result.isFailure
                                            ? nil
                                            : PlanningCommandKernel.planPointUpdates(from: toolCall)
                                        await planPointCollector.recordTodoWrite(update)
                                    }
                                }
                                await sendPromptUpdate(
                                    Self.toolCallCompletionJSONUpdate(
                                        for: toolCall,
                                        result: result,
                                        workingDirectory: workspaceURL
                                    )
                                )
                            case .turnEnded:
                                if let updatePipeline {
                                    await updatePipeline.enqueue(.init(kind: .finishThought)).value
                                }
                            case .sessionSnapshot:
                                break
                            }
                        }
                    )
                    // Also covers backends that return without a turnEnded event,
                    // before an automatic workflow continuation starts a new turn.
                    if let updatePipeline {
                        await updatePipeline.enqueue(.init(kind: .finishThought)).value
                    }
                    let completion = PromptCompletion(
                        text: response.text,
                        finalAssistantBlock: await assistantBlocks.lastBlock(),
                        stopReason: Self.acpStopReason(response.stopReason),
                        modelID: response.modelID
                    )
                    if case let .workflow(graphID) = commandPurpose {
                        let graph = try? await sessionRunner.taskGraphSnapshot(sessionID: sessionID, graphID: graphID)
                        let disposition = PlanningCommandKernel.workflowTurnDisposition(
                            graph: graph,
                            expectedGraphID: graphID,
                            coordinatorMessage: completion.finalAssistantBlock
                        )
                        if case .continueAutomatically = disposition, let graph {
                            await assistantBlocks.finishBlock()
                            let goal =
                                session.workflowContinuation?.graphID == graphID
                                ? session.workflowContinuation?.goal ?? ""
                                : ""
                            generationPrompt = PlanningCommandKernel.workflowAutomaticContinuationPrompt(
                                goal: goal,
                                graph: graph
                            )
                            generationAttachments = []
                            continue
                        }
                    }
                    return completion
                }
            }
        }

        // Register the task under the reservation. A `session/cancel` that
        // landed between the reservation and this point already dropped
        // `activePromptID`, so the mutation is skipped and the task must be
        // cancelled here: otherwise the cancel would be silently lost because
        // it had no task to cancel yet.
        var didRegisterPromptTask = false
        let sessionIsLive = updateLiveSession(id: sessionID, epoch: epoch) { session in
            guard session.activePromptID == promptID else {
                return
            }
            session.activePromptTask = activePromptTask
            didRegisterPromptTask = true
        }
        guard sessionIsLive, didRegisterPromptTask else {
            activePromptTask.cancel()
            await finishTaskPresentation()
            throw CancellationError()
        }

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
        func failTurn(reason: String) async {
            if case let .planning(collectionID, _) = commandPurpose {
                await clearACPPlanBrainstorming(sessionID: sessionID, epoch: epoch, expectedCollectionID: collectionID)
            } else if case let .workflow(graphID) = commandPurpose {
                await handleFailedACPWorkflowTurn(
                    graphID: graphID, reason: reason, sessionID: sessionID, epoch: epoch, promptID: promptID
                )
            }
        }

        do {
            var completion = try await activePromptTask.value
            if case .planning = commandPurpose {
                completion = try await finalizeACPPlanningTurn(
                    parent: completion,
                    purpose: commandPurpose,
                    collector: planPointCollector,
                    sessionID: sessionID,
                    epoch: epoch,
                    promptID: promptID
                )
                await sendPromptUpdate(
                    Self.textChunkJSONUpdate(kind: "agent_message_chunk", text: completion.text)
                )
            }
            await settleTurn()
            if case let .workflow(graphID) = commandPurpose {
                await armACPWorkflowContinuationIfNeeded(
                    graphID: graphID,
                    coordinatorMessage: completion.finalAssistantBlock,
                    sessionID: sessionID,
                    epoch: epoch,
                    promptID: promptID
                )
            }

            await sendStopReason(id: id, completion.stopReason)
            releaseReservation()
        } catch is CancellationError {
            await failTurn(reason: "the turn was cancelled")
            await settleTurn()
            await sendStopReason(id: id, "cancelled")
            releaseReservation()
        } catch {
            await failTurn(reason: error.localizedDescription)
            await settleTurn()
            releaseReservation()
            throw error
        }
    }

    /// Projects structured workflow control into the ACP reply route, fenced by
    /// the current prompt reservation. Prose does not suspend new workflows.
    func armACPWorkflowContinuationIfNeeded(
        graphID: String,
        coordinatorMessage: String?,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async {
        let graph = try? await sessionRunner.taskGraphSnapshot(sessionID: sessionID)
        let graphIsOpen = graph?.id == graphID
            && graph?.source.isWorkflow == true
            && graph?.state.isTerminal == false
        _ = updateReservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) { session in
            guard var workflow = session.workflowContinuation,
                  workflow.graphID == graphID else {
                return
            }
            guard graphIsOpen else {
                session.workflowContinuation = nil
                return
            }
            workflow.recordCoordinatorOutput(coordinatorMessage, graph: graph)
            session.workflowContinuation = workflow
        }
    }

    /// Preserves persisted objectives (including zero-task workflows) and arms
    /// recovery without replacing an authoritative structured suspension.
    func handleFailedACPWorkflowTurn(
        graphID: String,
        reason: String,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async {
        let graph = try? await sessionRunner.taskGraphSnapshot(sessionID: sessionID, graphID: graphID)
        guard reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil else { return }
        guard let graph, graph.workflow != nil || !graph.tasks.isEmpty else {
            _ = try? await sessionRunner.removeTaskGraph(id: graphID, sessionID: sessionID)
            _ = updateLiveSession(id: sessionID, epoch: epoch) { session in
                if session.workflowContinuation?.graphID == graphID {
                    session.workflowContinuation = nil
                }
            }
            return
        }
        _ = updateLiveSession(id: sessionID, epoch: epoch) { session in
            var workflow = session.workflowContinuation?.graphID == graphID
                ? session.workflowContinuation!
                : WorkflowCommandRuntimeState(goal: graph.workflow?.originalGoal ?? "", graphID: graphID)
            if !workflow.recordCoordinatorOutput(nil, graph: graph) {
                workflow.armForRecoverableFailure(reason: reason)
            }
            session.workflowContinuation = workflow
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
              var session = sessions[sessionID] else {
            throw ACPError.invalidParams("Unknown or missing sessionId.")
        }
        session.activePromptTask?.cancel()
        // Arm synchronously while this incarnation still owns the reservation.
        // Late prompt completions remain fenced out after activePromptID clears.
        // The reply route projects any newer persisted pause before consuming it.
        if let promptID = session.activePromptID,
           session.activeWorkflowPromptID == promptID,
           var workflow = session.workflowContinuation {
            if !workflow.isAwaitingReply {
                workflow.armForRecoverableFailure(reason: "cancelled")
            }
            session.workflowContinuation = workflow
        }
        session.activePromptTask = nil
        session.activePromptID = nil
        session.activeWorkflowPromptID = nil
        session.operationState = .idle
        sessions[sessionID] = session
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
        let closedSession = sessions.removeValue(forKey: sessionID)
        closedSession?.tasklessObserver?.cancel()
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
        updateSessionSleepAssertion()
        // Quiesce the ACP prompt wrapper before anything else can answer: with
        // the backend turn already cancelled above, its unwind — the buffered
        // update flush, the snapshot refresh and the `cancelled` reply — is
        // guaranteed to finish, and it belongs on the wire strictly before this
        // close's own reply. The runner's `closeSession` below additionally
        // waits for the backend-side prompt tasks it owns.
        await waitForPromptHandlersToDrain(sessionID: sessionID, tokens: promptHandlersToDrain)
        // `AgentCoreSessionRunner` currently keys its state by session id, not
        // ACP incarnation. If a `session/load` recreated this id while the old
        // prompt wrapper was draining, closing the runner now would cancel the
        // new prompt as well. The replacement owns the runner entry from this
        // point, so only tear it down while this close still owns the id.
        if sessions[sessionID] == nil || sessions[sessionID]?.epoch == closedSession?.epoch {
            await sessionRunner.closeSession(id: sessionID)
        }
        // Re-drop in case a racing handler re-created the entry while the
        // runner was closing the session.
        if let resurrected = sessions[sessionID],
           resurrected.epoch == closedSession?.epoch {
            sessions.removeValue(forKey: sessionID)
            updateSessionSleepAssertion()
        }
        // `closeSession` suspends: a shutdown landing there already failed all
        // pending requests, so do not write a late reply.
        try ensureNotShutDown()
        await writer.sendResultIfRequest(id: id, result: .object([:]))
    }
}

/// Keeps ACP content blocks separate across tool boundaries. A model response
/// can contain a question before a tool and a normal summary afterwards; only
/// the latter is the final assistant block of the turn.
actor ACPAssistantBlockCollector {
    private var completedBlocks: [String] = []
    private var currentBlock = ""

    func append(_ content: String) {
        currentBlock.append(content)
    }

    func finishBlock() {
        if currentBlock.nilIfBlank != nil {
            completedBlocks.append(currentBlock)
        }
        currentBlock = ""
    }

    func lastBlock() -> String? {
        currentBlock.nilIfBlank ?? completedBlocks.last?.nilIfBlank
    }
}
