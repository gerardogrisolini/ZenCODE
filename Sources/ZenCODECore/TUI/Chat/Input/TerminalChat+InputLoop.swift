//
//  TerminalChat+InputLoop.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

extension TerminalChat {
    /// Mirrors staged attachments into the input panel.  `promptAttempt`
    /// consumes local attachments synchronously, so callers invoke this as
    /// soon as they create an attempt rather than waiting for generation end.
    func synchronizePanelPendingAttachmentCount() async {
        await interactiveReader.setPendingAttachmentCount(pendingAttachments.count)
    }

    func synchronizeLocalExecAccessModeStatusBar() async {
        let accessMode = await sessionRunner.localExecAccessMode()
        await statusBar.update(localExecAccessMode: accessMode)
    }

    /// Routes consent prompts through the terminal's single interactive reader.
    /// The live input panel is suspended around each read so its loop cannot
    /// consume or contend for the operator's keystroke (no second terminal
    /// input device), then resumed. Reading runs off the cooperative executor
    /// so the authorizer actor is not blocked while the operator decides.
    func configureConsentReader(eventQueue: TerminalChatEventQueue) async {
        await permissionAuthorizer.setConsentReader({ @TerminalChatActor [interactiveReader, renderCoordinator, statusBar, weak self] prompt in
            await interactiveReader.stopPanelInput(clearPanel: false)
            let outputCapacity = await statusBar.scrollableOutputRowCapacity()
            await renderCoordinator.beginExternalTerminalPrompt(
                maximumInPlaceRows: outputCapacity
            )
            let answer = await Self.readConsentKeyOffActor(
                reader: interactiveReader,
                prompt: prompt
            )
            // `readSingleKey` terminates the echoed choice with one newline.
            // Add another before restoring the panel so its first rendered row
            // cannot overlap or clip the authorization card's bottom border.
            AgentOutput.standardError.writeString("\n")
            let suggestions = await self?.panelSuggestionsForCurrentAgent() ?? []
            _ = await interactiveReader.resumePanelInput(
                statusBar: statusBar,
                commandSuggestions: suggestions,
                onEvent: { event in
                    _ = await eventQueue.sendWithBackpressure(.input(event))
                }
            )
            await renderCoordinator.endExternalTerminalPrompt()
            return answer
        })
    }

    func runInteractivePanelLoop() async throws {
        let eventQueue = interactiveRuntimeEventQueueForTesting ?? TerminalChatEventQueue()
        // This loop owns the only Telegram ingress consumer, so replies to a
        // forwarded card can actually be delivered while it runs.
        readsTelegramIngress = true
        defer { readsTelegramIngress = false }
        // SIGWINCH is handled by the status-bar actor, but reader ownership
        // belongs to this one FIFO consumer. The handler only enqueues the
        // collapse notification, so it cannot form an actor callback cycle.
        await statusBar.setSharedChatReaderCollapseHandler { observationID in
            _ = await eventQueue.sendWithBackpressure(
                .sharedChatReaderCollapsed(observationID: observationID)
            )
        }
        var queuedPrompts = TerminalQueuedPromptBuffer()
        var generationTask: Task<Void, Never>?
        let remoteTranscriptions = telegramVoiceTranscriptions
        let telegramForwardingTask = startTelegramForwardingTask(eventQueue: eventQueue)
        // Persistent polling failures are told to the operator through this
        // FIFO. The handler runs on the service actor and must not block, so
        // it only offers the event; `lastError` keeps the detail if the queue
        // is momentarily full.
        await telegramControlService.setPollHealthHandler { notice in
            _ = eventQueue.offer(.telegramPollHealthChanged(notice))
        }
        // The room follows the live session id: `/new` and `/resume` swap it and
        // delegated agents then register in the new room, so the observation is
        // rebound instead of silently watching a retired one.
        var sharedChatRoomID = sessionID
        var sharedChatObservation = await startInteractiveSharedChatObservation(
            roomID: sharedChatRoomID,
            eventQueue: eventQueue
        )
        var isGenerating = false
        var isQueuedPromptStartScheduled = false
        // This history is terminal-local and bounded. It is deliberately not
        // routed through the session store, so opening the reader can never
        // affect transcripts or snapshots.
        var sharedChatReadingBuffer = TerminalSharedChatReadingBuffer()
        var isSharedChatReaderOpen = false
        // Readable mention handles for the current roster (handle → participant
        // id). Refreshed whenever the participant list changes so the parser
        // always routes by the latest stable id behind a readable `@handle`.
        var readableSharedChatMentionHandles = await sessionRunner.sharedChatMentionHandles(
            rootSessionID: sharedChatRoomID
        )

        /// Builds a dock snapshot after fetching the current participant roster.
        /// All callers run on this loop's serialized context, preserving the
        /// former fetch → map → buffer-projection ordering.
        func sharedChatReaderEntries() async -> [TerminalSharedChatReaderEntry] {
            let participants = await sessionRunner.sharedChatParticipants(rootSessionID: sharedChatRoomID)
            let participantMap = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })
            return sharedChatReadingBuffer.messages.map {
                TerminalSharedChatReaderEntry(message: $0, participantMap: participantMap)
            }
        }

        defer {
            // Stop producers before terminating the queue so no task keeps
            // running (or keeps this chat alive) after the loop exits, and any
            // event racing the teardown is dropped instead of buffered forever.
            generationTask?.cancel()
            telegramForwardingTask.cancel()
            sharedChatObservation.task.cancel()
            // `defer` cannot suspend. This synchronous fallback closes admission
            // and cancels any transcription if a future early-exit path is added;
            // the current exits await cleanup explicitly below.
            remoteTranscriptions.cancelAll()
            eventQueue.finish()
            // This loop owns exactly one subscriber. Session teardown performs
            // room-wide stop; detaching here must never end another TUI/ACP
            // observer that is still handling live messages.
            let observation = sharedChatObservation.observation
            Task(name: "ZenCODE.TUI.shared-chat-detach") { [sessionRunner] in
                await sessionRunner.detachSharedChatObservation(observation)
            }
            Task(name: "ZenCODE.TUI.shared-chat-reader-remove") { [statusBar] in
                await statusBar.removeSharedChatReader()
            }
            // Synchronous fallback for early exits; the normal exit path stops
            // voice mode explicitly below.
            let realtimeVoice = realtimeVoiceController
            let dictationVoice = dictationVoiceController
            realtimeVoiceController = nil
            dictationVoiceController = nil
            voiceActivationKey = nil
            Task(name: "ZenCODE.TUI.voice-stop") {
                await realtimeVoice?.stop()
                await dictationVoice?.stop()
            }
        }

        func scheduleQueuedPromptIfNeeded() {
            guard !isGenerating,
                  !queuedPrompts.isEmpty,
                  !isQueuedPromptStartScheduled else {
                return
            }
            isQueuedPromptStartScheduled = true
            // This is the one lifecycle producer whose caller is the consumer
            // itself. It cannot await a full queue inline without deadlocking
            // the event loop, so its single coalesced task applies the same
            // backpressure after the current event returns to the loop.
            Task(name: "ZenCODE.TUI.next-queued-prompt") {
                _ = await eventQueue.sendWithBackpressure(.startNextQueuedPrompt)
            }
        }

        /// Mirrors terminal activity into the Core auto-trigger. A queued prompt
        /// keeps this observer busy, so a shared-chat message waits for a free
        /// turn instead of racing the operator's own work. The declaration is
        /// scoped to this terminal's observation: another live consumer of the
        /// same room can never clear it.
        func synchronizeSharedChatConsumerBusyState() async {
            await sessionRunner.setSharedChatConsumerBusy(
                isGenerating || !queuedPrompts.isEmpty,
                observation: sharedChatObservation.observation
            )
        }

        /// Follows a session swap (`/new`, `/resume`) without losing live
        /// coordination: the retired room is released back to the Core and the
        /// new one is observed from its first message.
        func rebindSharedChatObservationIfNeeded(force: Bool = false) async {
            guard force || sharedChatRoomID != sessionID else { return }
            let retiredObservation = sharedChatObservation
            retiredObservation.task.cancel()
            await sessionRunner.detachSharedChatObservation(retiredObservation.observation)
            // A finished stream is not an active observation. Remove rather
            // than collapse its dock; a replacement attachment below restores
            // the intentionally persistent compact zero-message dock.
            await statusBar.removeSharedChatReader()
            sharedChatRoomID = sessionID
            sharedChatObservation = await startInteractiveSharedChatObservation(
                roomID: sharedChatRoomID,
                eventQueue: eventQueue
            )
            sharedChatReadingBuffer = TerminalSharedChatReadingBuffer()
            isSharedChatReaderOpen = false
            await showCompactSharedChatDock()
            interactiveReader.setSharedChatReaderOpen(false)
            readableSharedChatMentionHandles = await sessionRunner.sharedChatMentionHandles(
                rootSessionID: sharedChatRoomID
            )
            // A new room invalidates the Telegram receipt map: a reply to a card
            // from the retired room must not be routed into this one.
            await rebindTelegramSharedChatRelay(roomID: sharedChatRoomID)
            await synchronizeSharedChatConsumerBusyState()
        }

        func showCompactSharedChatDock() async {
            await statusBar.setSharedChatReader(
                entries: [],
                unreadCount: 0,
                isExpanded: false,
                observationID: sharedChatObservation.observation.id
            )
        }

        func refreshQueuedPromptCount() async {
            await interactiveReader.setQueuedPromptCount(queuedPrompts.count)
            await synchronizeSharedChatConsumerBusyState()
        }

        @discardableResult
        func startPanelInput() async -> Bool {
            if bypassInteractivePanelInputForTesting {
                return true
            }
            let didStart = await interactiveReader.startPanelInput(
                statusBar: statusBar,
                commandSuggestions: await panelSuggestionsForCurrentAgent()
            ) { event in
                _ = await eventQueue.sendWithBackpressure(.input(event))
            }
            return await syncPanelAfterOpening(didStart)
        }

        func resumePanelInput() async -> Bool {
            if bypassInteractivePanelInputForTesting { return true }
            let didStart = await interactiveReader.resumePanelInput(
                statusBar: statusBar,
                commandSuggestions: await panelSuggestionsForCurrentAgent()
            ) { event in
                _ = await eventQueue.sendWithBackpressure(.input(event))
            }
            return await syncPanelAfterOpening(didStart)
        }

        func syncPanelAfterOpening(_ didStart: Bool) async -> Bool {
            guard didStart else { return false }
            await interactiveReader.setPanelProcessing(isGenerating)
            await interactiveReader.setQueuedPromptCount(queuedPrompts.count)
            await synchronizePanelPendingAttachmentCount()
            return true
        }

        func stopPanelInput(clearPanel: Bool = true) async {
            await interactiveReader.stopPanelInput(clearPanel: clearPanel)
        }

        func startGeneration(attempt: TerminalPromptAttempt) async {
            // Hidden/synthetic turns do not necessarily write a submitted
            // prompt, so every generation entry point reopens automatic local
            // progress independently of the visible-prompt renderer.
            await renderCoordinator.beginTranscriptTurn()
            isGenerating = true
            onInteractiveGenerationStateForTesting?(true)
            didRefreshGitStatusDuringCurrentPrompt = false
            // Declare the busy state before the first suspension so the Core
            // cannot authorise a synthetic turn in the window between this
            // decision and the prompt reaching `sendPrompt`.
            await synchronizeSharedChatConsumerBusyState()
            // `promptAttempt` has already consumed local staged attachments.
            // Update the panel before the response starts, not only once it
            // completes, so its badge never advertises stale attachments.
            await synchronizePanelPendingAttachmentCount()
            await statusBar.beginRequest()
            await statusBar.setProcessing(true)
            await interactiveReader.setPanelProcessing(true)
            generationTask = Task(name: "ZenCODE.TUI.queued-prompt-generation") {
                let result = await self.generationResult(for: attempt)
                // Delivery runs in one detached task so cancelling this generation
                // cannot turn a full queue into a lost completion that leaves the
                // terminal marked as generating; queue teardown ends it promptly.
                let completionDelivery = Task.detached(
                    name: "ZenCODE.TUI.generation-completion-delivery"
                ) {
                    await eventQueue.sendWithBackpressure(.generationCompleted(result))
                }
                _ = await completionDelivery.value
            }
        }

        func startDirectPrompt(_ prompt: String, origin: TerminalPromptOrigin) async {
            let attempt = promptAttempt(prompt: prompt, origin: origin)
            if origin == .local {
                await writeSubmittedPrompt(prompt)
            } else {
                await writeTelegramSubmittedPrompt(prompt)
            }
            await startGeneration(attempt: attempt)
        }

        await synchronizeLocalExecAccessModeStatusBar()

        await configureConsentReader(eventQueue: eventQueue)
        // The panel pulls live mentions while a mention token is being edited,
        // so the roster list stays correct even if a push refresh was missed.
        await installSharedChatMentionSuggestionsProvider()

        guard await startPanelInput() else {
            await remoteTranscriptions.cancelAllAndWait(shuttingDown: true)
            await statusBar.stop()
            throw TerminalChatError.interactivePromptUnavailable
        }
        // An attached observation is the active-chat signal. Show its compact
        // indicator even before the first message arrives.
        await showCompactSharedChatDock()
        // Voice mode follows the active agent and its effective model.
        await reevaluateVoiceMode(eventQueue: eventQueue)
        func handleSubmittedPanelLine(
            _ line: String,
            origin: TerminalPromptOrigin = .local
        ) async -> Bool {
            let shouldSuspendPanel = origin == .local && Self.shouldSuspendPanelInput(for: line)
            if shouldSuspendPanel {
                await stopPanelInput(clearPanel: false)
                await renderCoordinator.setOverviewPublishingSuspended(true)
            }

            let action = await submittedLineAction(line, origin: origin)
            if shouldSuspendPanel {
                await renderCoordinator.setOverviewPublishingSuspended(false)
            }
            // A command may have switched the agent, the model or the session.
            await reevaluateVoiceMode(eventQueue: eventQueue)

            switch action {
            case .continueChat:
                if shouldSuspendPanel {
                    _ = await resumePanelInput()
                }
                return true
            case .exitChat:
                generationTask?.cancel()
                return false
            case .requestSetup:
                requestedRuntimeSetup = true
                generationTask?.cancel()
                return false
            case let .runPrompt(prompt):
                if shouldSuspendPanel {
                    _ = await resumePanelInput()
                }
                await startDirectPrompt(prompt, origin: origin)
                return true
            case let .runHiddenPrompt(prompt, purpose):
                if shouldSuspendPanel {
                    _ = await resumePanelInput()
                }
                await startGeneration(
                    attempt: promptAttempt(
                        prompt: prompt,
                        origin: origin,
                        isUserVisible: false,
                        purpose: purpose
                    )
                )
                return true
            case let .prefillPrompt(prompt):
                if shouldSuspendPanel {
                    _ = await resumePanelInput()
                }
                await interactiveReader.setPanelText(prompt)
                return true
            }
        }

        eventLoop: for await event in eventQueue.events {
            // A slash command may have swapped the session between two events.
            await rebindSharedChatObservationIfNeeded()
            await reevaluateVoiceMode(eventQueue: eventQueue)
            // Cancelling an AsyncStream observation cannot remove work it
            // already put in this FIFO. Treat every room-bound event from the
            // retired room as stale. A stale trigger is explicitly declined in
            // *its own* room, which requeues its batch without interacting with
            // the replacement session; stale render/roster events are ignored.
            if event.sharedChatRoomID != nil,
               !event.belongsToActiveSharedChatRoom(
                   observedRoomID: sharedChatRoomID,
                   sessionID: sessionID
               ) {
                if case let .sharedChatAutoTrigger(trigger) = event {
                    // The retired room has no observation left here, so this is
                    // an ownerless requeue: it returns the batch, never a turn.
                    await sessionRunner.declineSharedChatAutoTrigger(
                        id: trigger.id,
                        rootSessionID: trigger.roomID
                    )
                }
                continue
            }
            switch event {
            case let .input(inputEvent):
                switch inputEvent {
                case let .submitted(line):
                    // A valid leading mention is live control input, not a
                    // regular prompt. Route it before the busy/queued-prompt
                    // branches so an operator can reach active agents and the
                    // coordinator while the terminal is generating. The Core
                    // coordinator still serializes any coordinator turn.
                    switch Self.parseSharedChatMention(
                        from: line,
                        readableHandles: readableSharedChatMentionHandles
                    ) {
                    case let .route(route):
                        await sendSharedChatMention(route)
                        continue
                    case .missingText:
                        await writeFailureMessage(
                            "ZenCODE message: add a message after the live mention.\n"
                        )
                        continue
                    case .none:
                        break
                    }
                    if !isGenerating, !queuedPrompts.isEmpty {
                        guard queuedPrompts.enqueue(
                            TerminalQueuedPrompt(text: line, origin: .local)
                        ) else {
                            await writeFailureMessage(
                                "ZenCODE: prompt queue is full; wait for a queued prompt to start.\n"
                            )
                            continue
                        }
                        await refreshQueuedPromptCount()
                        scheduleQueuedPromptIfNeeded()
                        continue
                    }

                    if isGenerating {
                        switch Self.submittedLineRole(for: line) {
                        case .empty, .prompt:
                            guard queuedPrompts.enqueue(
                                TerminalQueuedPrompt(text: line, origin: .local)
                            ) else {
                                await writeFailureMessage(
                                    "ZenCODE: prompt queue is full; wait for the current prompt to finish.\n"
                                )
                                continue
                            }
                            await refreshQueuedPromptCount()
                            continue
                        case .slashCommand:
                            if Self.isAvailableDuringGeneration(for: line) {
                                break
                            }
                            await writeFailureMessage(generatingSlashCommandMessage(for: line))
                            continue
                        }
                    }

                    guard await handleSubmittedPanelLine(line) else {
                        break eventLoop
                    }
                case .cancelRequested:
                    generationTask?.cancel()
                    await interruptVoicePlayback()
                case .toggleAccessModeRequested:
                    let accessMode = await sessionRunner.toggleLocalExecAccessMode()
                    await statusBar.update(localExecAccessMode: accessMode)
                    await writeAccessModeChangeMessage(accessMode)
                    await interactiveReader.refreshPanel()
                case .toggleSharedChatReaderRequested:
                    let entries = await sharedChatReaderEntries()
                    // The dock is rendered by the status bar in the panel's
                    // reserved rows; generation and the normal input loop keep running.
                    guard !isSharedChatReaderOpen else {
                        sharedChatReadingBuffer.closeReader()
                        await withBottomOverlayTransition {
                            await statusBar.setSharedChatReader(
                                entries: entries,
                                unreadCount: sharedChatReadingBuffer.unreadCount,
                                isExpanded: false,
                                observationID: sharedChatObservation.observation.id
                            )
                        }
                        isSharedChatReaderOpen = false
                        interactiveReader.setSharedChatReaderOpen(false)
                        continue
                    }
                    // Opening is a single status-bar transaction that reports whether
                    // a payload row was actually shown; only then is it committed
                    // as a reader action, so selection/read state follows a visible
                    // payload.
                    let didExpand = await withBottomOverlayTransition {
                        await statusBar.expandSharedChatReader(
                            entries: entries,
                            unreadCount: sharedChatReadingBuffer.readerOpeningUnreadCount,
                            selection: .message(sharedChatReadingBuffer.readerOpeningMessageID),
                            observationID: sharedChatObservation.observation.id
                        )
                    }
                    guard didExpand else {
                        // Nothing was committed: the compact dock keeps
                        // advertising the unread traffic instead of hiding it.
                        continue
                    }
                    sharedChatReadingBuffer.openReader()
                    isSharedChatReaderOpen = true
                    interactiveReader.setSharedChatReaderOpen(true)
                case let .sharedChatReaderNavigation(action):
                    guard isSharedChatReaderOpen else { continue }
                    await withBottomOverlayTransition {
                        let unreadCountBeforeNavigation = sharedChatReadingBuffer.unreadCount
                        sharedChatReadingBuffer.navigate(action)
                        await statusBar.navigateSharedChatReader(action)
                        // The status bar owns the visual selection, while the
                        // terminal-local buffer owns the read marker. Refresh only
                        // when visiting an unread message changed that marker;
                        // `navigateSharedChatReader` has already applied the
                        // selection so `replace` preserves it by message ID.
                        if sharedChatReadingBuffer.unreadCount != unreadCountBeforeNavigation {
                            let entries = await sharedChatReaderEntries()
                            await statusBar.setSharedChatReader(
                                entries: entries,
                                unreadCount: sharedChatReadingBuffer.unreadCount,
                                isExpanded: true,
                                observationID: sharedChatObservation.observation.id
                            )
                        }
                    }
                case .endOfInput:
                    generationTask?.cancel()
                    break eventLoop
                }
            case let .sharedChatReaderCollapsed(observationID):
                // A resize already committed the compact dock. Apply the other
                // three reader states in this serialized runtime loop, and
                // ignore a late callback from a retired observer.
                guard let observationID, observationID == sharedChatObservation.observation.id else {
                    continue
                }
                // Reconcile on this FIFO after any suspended refresh so the collapse
                // is authoritative. A resize can change wrapping, so unlike a
                // manual toggle the old physical anchor cannot be kept.
                await renderCoordinator.relinquishSubAgentOverviewOwnership()
                await statusBar.collapseSharedChatReader(ownedBy: observationID)
                sharedChatReadingBuffer.closeReader()
                isSharedChatReaderOpen = false
                interactiveReader.setSharedChatReaderOpen(false)
            case let .generationCompleted(result):
                generationTask = nil
                isGenerating = false
                onInteractiveGenerationStateForTesting?(false)
                await statusBar.setProcessing(false)
                await interactiveReader.setPanelProcessing(false)
                // The prompt consumed whatever was staged, so the indicator must
                // not keep advertising attachments that already left.
                await synchronizePanelPendingAttachmentCount()
                await finishPromptResult(result)
                if case let .success(success) = result {
                    await speakVoiceResponse(success.finalAssistantContent)
                }
                await refreshSharedChatPanelSuggestions()
                await refreshStatusBarGitStatusSummaryAfterPromptIfNeeded()
                // Release the room only once the queue state is final, so the
                // Core re-offers a pending batch exactly when the terminal is
                // genuinely idle.
                await synchronizeSharedChatConsumerBusyState()
                scheduleQueuedPromptIfNeeded()
            case let .telegramPollHealthChanged(notice):
                await writeTelegramPollHealthNotice(notice)
            case let .telegramRouteInvalidated(lease):
                guard activeTelegramTurnOrigin?.telegramLease == lease else { continue }
                generationTask?.cancel()
                generationTask = nil
                isGenerating = false
                await statusBar.setProcessing(false)
                await interactiveReader.setPanelProcessing(false)
                await endTelegramTurnProgressReporting()
                await telegramRouteRuntimeState.teardown(lease: lease)
                telegramCommandReplyBindings = telegramCommandReplyBindings.filter {
                    $0.value.lease != lease
                }
                if telegramActiveRouteLease == lease {
                    telegramActiveRouteLease = nil
                    await telegramSharedChatRelay.deactivate()
                }
                scheduleQueuedPromptIfNeeded()
            case .startNextQueuedPrompt:
                isQueuedPromptStartScheduled = false
                guard !isGenerating, !queuedPrompts.isEmpty else {
                    continue
                }
                let nextPrompt = queuedPrompts.dequeue()!
                await refreshQueuedPromptCount()
                guard await validateTelegramOrigin(nextPrompt.origin) else {
                    scheduleQueuedPromptIfNeeded()
                    continue
                }
                if nextPrompt.mode == .directPrompt {
                    await startDirectPrompt(nextPrompt.text, origin: nextPrompt.origin)
                    continue
                }
                guard await handleSubmittedPanelLine(
                    nextPrompt.text,
                    origin: nextPrompt.origin
                ) else {
                    break eventLoop
                }
                scheduleQueuedPromptIfNeeded()
            case let .sharedChatMessages(_, messages):
                // Relay first: Telegram delivery is tracked by the relay's own
                // ledger, not by the terminal reader buffer, which is rebuilt on
                // a forced reattach and would resend the replayed transcript.
                await forwardSharedChatMessagesToTelegram(
                    messages,
                    roomID: sharedChatRoomID
                )
                // Turn starts arrive as a separate Core auto-trigger. The reader
                // buffer deduplicates by identity, so replays never update the dock
                // or its unread counter twice.
                let newMessages = sharedChatReadingBuffer.append(messages)
                guard !newMessages.isEmpty else { continue }
                let entries = await sharedChatReaderEntries()
                await withBottomOverlayTransition {
                    await statusBar.setSharedChatReader(
                        entries: entries,
                        unreadCount: sharedChatReadingBuffer.unreadCount,
                        isExpanded: isSharedChatReaderOpen,
                        observationID: sharedChatObservation.observation.id
                    )
                }
                await refreshSharedChatPanelSuggestions()
            case let .sharedChatObservationEnded(_, observationID):
                // Ignore a delayed completion from an observation we already
                // retired. A current stream ending is a lifecycle boundary even
                // if the session/room identifier was reused by the backend.
                guard observationID == sharedChatObservation.observation.id else {
                    continue
                }
                await rebindSharedChatObservationIfNeeded(force: true)
            case let .sharedChatAutoTrigger(trigger):
                // The Core authorised exactly one synthetic turn. Do not publish
                // an idle update before claiming it: another observer may take
                // the broadcast while this event waits in our FIFO, and its
                // claim must remain intact until it starts its turn.
                guard trigger.roomID == sharedChatRoomID, trigger.roomID == sessionID else {
                    await sessionRunner.declineSharedChatAutoTrigger(
                        id: trigger.id,
                        rootSessionID: trigger.roomID
                    )
                    continue
                }
                guard !isGenerating, queuedPrompts.isEmpty else {
                    // A real local busy state still has to be visible before
                    // declining, otherwise the requeued batch could be offered
                    // straight back to this occupied terminal.
                    await synchronizeSharedChatConsumerBusyState()
                    // Ownerless on purpose: this may be a re-offered duplicate
                    // of a trigger this terminal already claimed, and returning
                    // an unclaimed batch must never release a running turn.
                    await sessionRunner.declineSharedChatAutoTrigger(
                        id: trigger.id,
                        rootSessionID: trigger.roomID
                    )
                    continue
                }
                // Every observer receives this broadcast. Claiming is atomic in
                // the Core and is recorded against this observation, so a second
                // terminal/headless consumer may have already taken it while the
                // event waited in our FIFO. Only the winner opens the turn, and
                // only the winner can later release it.
                let claim = await sessionRunner.resolveSharedChatAutoTrigger(
                    id: trigger.id,
                    observation: sharedChatObservation.observation,
                    resolution: .started
                )
                guard claim == .acquired else {
                    continue
                }
                await startGeneration(
                    attempt: promptAttempt(
                        prompt: trigger.prompt,
                        origin: takeTelegramSharedChatOrigin(for: trigger.messages) ?? .local,
                        isUserVisible: false
                    )
                )
            case .sharedChatParticipantsChanged:
                // Room binding was verified before entering this switch.
                readableSharedChatMentionHandles = await sessionRunner.sharedChatMentionHandles(
                    rootSessionID: sharedChatRoomID
                )
                await refreshSharedChatPanelSuggestions()
            case let .telegramMessage(message):
                if let draftID = message.stoppedMessageGenerationDraftID {
                    // Correlate the stop to the current reporter's native draft.
                    // A delayed update for a retired/rebound turn is inert.
                    if let origin = activeTelegramTurnOrigin,
                       await validateTelegramOrigin(origin),
                       origin.telegramLease?.effectiveMessageThreadID == message.topicID,
                       let reporter = activeTelegramProgressReporter,
                       await reporter.ownsStoppedDraft(chatID: message.chatID, draftID: draftID) {
                        generationTask?.cancel()
                    }
                    continue
                }
                let didQueuePrompt = await handleTelegramRuntimeMessage(
                    message,
                    eventQueue: eventQueue,
                    queuedPrompts: &queuedPrompts,
                    transcriptions: remoteTranscriptions,
                    isSessionGenerating: isGenerating
                )
                if didQueuePrompt {
                    await refreshQueuedPromptCount()
                    scheduleQueuedPromptIfNeeded()
                }
            case let .voicePromptCompleted(result):
                switch result.outcome {
                case let .success(prompt):
                    if isGenerating || !queuedPrompts.isEmpty {
                        guard !queuedPrompts.isRedundantVoiceTurnMarker(prompt) else {
                            continue
                        }
                        guard queuedPrompts.enqueue(
                            TerminalQueuedPrompt(
                                text: prompt,
                                origin: result.origin,
                                mode: .directPrompt
                            )
                        ) else {
                            let message = "ZenCODE: prompt queue is full; voice prompt was not queued."
                            await writeFailureMessage(message + "\n")
                            await sendTelegramSystemMessageIfLinked(
                                message,
                                origin: result.origin
                            )
                            continue
                        }
                        await refreshQueuedPromptCount()
                        scheduleQueuedPromptIfNeeded()
                    } else {
                        await startDirectPrompt(prompt, origin: result.origin)
                    }
                case let .failure(message):
                    await writeFailureMessage("ZenCODE: \(message)\n")
                    await sendTelegramSystemMessageIfLinked(
                        "Voice transcription failed: \(message)",
                        origin: result.origin
                    )
                }
            }
        }

        // Teardown paths that bypass `finishPromptResult` (end-of-input during
        // generation, cancellation) must still retire the turn's Telegram
        // reporting. Finish the queue BEFORE joining the cancelled generation:
        // its detached completion delivery can only conclude once the queue is
        // finished, since this loop no longer consumes it. `finish()` is
        // idempotent, so the teardown defer stays safe. Joining first also stops
        // a cancelled `generateResponse` from opening a reporting session after
        // the retirement below.
        eventQueue.finish()
        if let generation = generationTask {
            generationTask = nil
            generation.cancel()
            _ = await generation.value
        }
        // This loop is ending for good: stop the task-graph observer (and its
        // in-flight debounce) without restarting it, so no observer-driven
        // render can run during or after the turn retirement below.
        await stopTaskGraphObserver()
        await finalizeTelegramTurnProgressReporting()
        await remoteTranscriptions.cancelAllAndWait(shuttingDown: true)
        await stopVoiceMode()

        await stopPanelInput()
    }
}
