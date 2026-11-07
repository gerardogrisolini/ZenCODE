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
    /// An open `/subagent` detail closes first: the consent takes the input,
    /// and the dialog answers the keys the detail would otherwise receive.
    func configureConsentReader(eventQueue: TerminalChatEventQueue) async {
        await permissionAuthorizer.setConsentReader({ @ChatSessionActor [interactiveReader, renderCoordinator, statusBar, weak self] prompt in
            await self?.closeSubAgentDetail(reason: .consent)
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
        let eventQueue = TerminalChatEventQueue()
        // An observation replays the room's retained transcript. Voice mode
        // announces only what is sent from now on, never that replay; taken
        // before the observation starts so a message sent in between is new.
        voiceSession.announcementsSince = Date.now
        // `/voice on` feeds dictated utterances into this FIFO.
        voiceEventQueue = eventQueue
        // SIGWINCH is handled by the status-bar actor, but reader ownership
        // belongs to this one FIFO consumer. The handler only enqueues the
        // collapse notification, so it cannot form an actor callback cycle.
        await statusBar.setSharedChatReaderCollapseHandler { observationID in
            _ = await eventQueue.sendWithBackpressure(
                .sharedChatReaderCollapsed(observationID: observationID)
            )
        }
        var queuedPrompts = ChatPromptQueue<TerminalPromptOrigin>()
        var generationTask: Task<Void, Never>?
        // The reservation of the turn running now, held in the session host
        // so the slot's other channel sees the session busy (see
        // `ChatSessionHost.reservePrompt`); `nil` for a turn the terminal
        // adopted from Telegram, whose reservation the channel holds.
        var promptReservation: ChatPromptReservation?
        // The ending of a turn the terminal adopted from Telegram reaches
        // this FIFO as a generation completion until the loop ends.
        loopEventQueue = eventQueue
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
            sharedChatObservation.task.cancel()
            eventQueue.finish()
            loopEventQueue = nil
            if let promptReservation {
                sessionHost.releasePrompt(promptReservation)
            }
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
            let voice = voiceSession.detachController()
            voiceEventQueue = nil
            voiceModeHost.loop = nil
            Task(name: "ZenCODE.TUI.voice-stop") {
                await voice?.stop()
            }
        }

        func scheduleQueuedPromptIfNeeded() {
            // While Telegram drives the slot the queue waits, whole, for
            // `/telegram off` (see `handleSubmittedPanelLine`).
            guard !isGenerating,
                  !queuedPrompts.isEmpty,
                  !isQueuedPromptStartScheduled,
                  sessionHost.activeChannel(in: terminalSlotID) == .primary else {
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
            let voiceAnnouncementsSince = Date.now
            sharedChatObservation = await startInteractiveSharedChatObservation(
                roomID: sharedChatRoomID,
                eventQueue: eventQueue
            )
            sharedChatReadingBuffer = TerminalSharedChatReadingBuffer()
            isSharedChatReaderOpen = false
            // The retired room's messages are never announced in the new one,
            // and an announcement of its being read stops here.
            await voiceSession.targetDidChange(announcingMessagesSince: voiceAnnouncementsSince)
            await showCompactSharedChatDock()
            interactiveReader.setSharedChatReaderOpen(false)
            readableSharedChatMentionHandles = await sessionRunner.sharedChatMentionHandles(
                rootSessionID: sharedChatRoomID
            )
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
            let didStart = await interactiveReader.startPanelInput(
                statusBar: statusBar,
                commandSuggestions: await panelSuggestionsForCurrentAgent()
            ) { event in
                _ = await eventQueue.sendWithBackpressure(.input(event))
            }
            return await syncPanelAfterOpening(didStart)
        }

        func resumePanelInput() async -> Bool {
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
            // Every turn the terminal starts passes here: none starts while
            // Telegram drives the slot.
            guard await admitTerminalInput() else { return }
            // The turn is reserved in the session host, so the slot's Telegram
            // channel sees the session busy and never runs a turn alongside.
            // A reservation that fails (the channel's own turn still runs
            // after `/telegram off`) queues the prompt instead.
            do {
                promptReservation = try sessionHost.reservePrompt(in: terminalSlotID)
            } catch {
                guard queuedPrompts.enqueue(
                    ChatQueuedPrompt<TerminalPromptOrigin>(
                        text: attempt.prompt, origin: attempt.origin, mode: .directPrompt
                    )
                ) else {
                    await writeFailureMessage(
                        "ZenCODE: prompt queue is full; wait for the current prompt to finish.\n"
                    )
                    return
                }
                await refreshQueuedPromptCount()
                return
            }
            // Hidden/synthetic turns do not necessarily write a submitted
            // prompt, so every generation entry point reopens automatic local
            // progress independently of the visible-prompt renderer.
            await renderCoordinator.beginTranscriptTurn()
            isGenerating = true
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
            // Asked before the prompt takes the staged attachments or is
            // echoed; `startGeneration` asks again for the other turns.
            guard await admitTerminalInput() else { return }
            let attempt = promptAttempt(prompt: prompt, origin: origin)
            await writeSubmittedPrompt(prompt)
            await startGeneration(attempt: attempt)
        }

        /// A turn from Telegram was running when `/telegram off` took the
        /// slot back: the loop treats it as its own from here on, and its
        /// ending arrives as a generation completion.
        func adoptRunningTurnIfNeeded() async {
            guard takeAdoptedTurnIfNeeded(), !isGenerating else { return }
            isGenerating = true
            await synchronizeSharedChatConsumerBusyState()
            // Not redundant with the presenter's `turnDidMoveToChannel`: a
            // turn whose prompt is reserved before it opens, or after it
            // finished, is adopted without moving.
            await statusBar.beginRequest()
            await statusBar.setProcessing(true)
            await interactiveReader.setPanelProcessing(true)
        }

        await synchronizeLocalExecAccessModeStatusBar()

        await configureConsentReader(eventQueue: eventQueue)
        // The panel pulls live mentions while a mention token is being edited,
        // so the roster list stays correct even if a push refresh was missed.
        await installSharedChatMentionSuggestionsProvider()

        guard await startPanelInput() else {
            await statusBar.stop()
            throw TerminalChatError.interactivePromptUnavailable
        }
        // An attached observation is the active-chat signal. Show its compact
        // indicator even before the first message arrives.
        await showCompactSharedChatDock()
        func handleSubmittedPanelLine(
            _ line: String,
            origin: TerminalPromptOrigin = .local
        ) async -> Bool {
            let shouldSuspendPanel = origin == .local && Self.shouldSuspendPanelInput(for: line)
            let wasDormant = sessionHost.activeChannel(in: terminalSlotID) != .primary
            if shouldSuspendPanel {
                await stopPanelInput(clearPanel: false)
                await renderCoordinator.setOverviewPublishingSuspended(true)
            }

            let action = await submittedLineAction(line, origin: origin)
            // A `/subagent` detail the command left open keeps the overviews
            // suspended: its external-writer phase releases them when it
            // closes (`closeSubAgentDetail`).
            if shouldSuspendPanel, !isSubAgentDetailOpen {
                await renderCoordinator.setOverviewPublishingSuspended(false)
            }
            // `/telegram off` while a turn from Telegram runs: the loop takes
            // the turn over before it handles anything else.
            await adoptRunningTurnIfNeeded()
            // `/telegram off` gave the slot back: the prompts queued before
            // `/telegram on` run now, or once the adopted turn ends.
            if wasDormant, sessionHost.activeChannel(in: terminalSlotID) == .primary {
                scheduleQueuedPromptIfNeeded()
            }

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

        /// A typed or dictated line. Returns `false` when the loop must end.
        func handleSubmittedInputLine(_ line: String) async -> Bool {
            // While Telegram drives the slot the terminal runs only what takes
            // it back; everything else is refused before it is routed. The
            // one admission of a line: a queued line starts only while the
            // terminal drives its slot, and the line-by-line fallback never
            // hands its slot over.
            guard await admitTerminalLine(line) else {
                return true
            }
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
                return true
            case .missingText:
                await writeFailureMessage(
                    "ZenCODE message: add a message after the live mention.\n"
                )
                return true
            case .none:
                break
            }
            // While Telegram drives the slot the queue waits for
            // `/telegram off`, which runs now instead of queuing behind it.
            if !isGenerating, !queuedPrompts.isEmpty,
               sessionHost.activeChannel(in: terminalSlotID) == .primary {
                guard queuedPrompts.enqueue(
                    ChatQueuedPrompt<TerminalPromptOrigin>(text: line, origin: .local)
                ) else {
                    await writeFailureMessage(
                        "ZenCODE: prompt queue is full; wait for a queued prompt to start.\n"
                    )
                    return true
                }
                await refreshQueuedPromptCount()
                scheduleQueuedPromptIfNeeded()
                return true
            }

            if isGenerating {
                switch Self.submittedLineRole(for: line) {
                case .empty, .prompt:
                    guard queuedPrompts.enqueue(
                        ChatQueuedPrompt<TerminalPromptOrigin>(text: line, origin: .local)
                    ) else {
                        await writeFailureMessage(
                            "ZenCODE: prompt queue is full; wait for the current prompt to finish.\n"
                        )
                        return true
                    }
                    await refreshQueuedPromptCount()
                    return true
                case .slashCommand:
                    if Self.isAvailableDuringGeneration(for: line) {
                        break
                    }
                    await writeFailureMessage(generatingSlashCommandMessage(for: line))
                    return true
                }
            }

            return await handleSubmittedPanelLine(line)
        }

        /// A dictated slash-like utterance always runs as a plain prompt.
        func handleVoicePromptCompleted(_ result: TerminalVoicePromptResult) async {
            switch result.outcome {
            case let .success(prompt):
                // A dictation is never a command, whatever it reads: while
                // Telegram drives the slot it is refused, a dictated `/exit`
                // or `/telegram off` included.
                guard await admitTerminalInput() else { return }
                if isGenerating || !queuedPrompts.isEmpty {
                    guard queuedPrompts.enqueue(
                        ChatQueuedPrompt<TerminalPromptOrigin>(
                            text: prompt,
                            origin: result.origin,
                            mode: .directPrompt
                        )
                    ) else {
                        let message = "ZenCODE: prompt queue is full; voice prompt was not queued."
                        await writeFailureMessage(message + "\n")
                        return
                    }
                    await refreshQueuedPromptCount()
                    scheduleQueuedPromptIfNeeded()
                } else {
                    await startDirectPrompt(prompt, origin: result.origin)
                }
            case let .failure(message):
                await writeFailureMessage("ZenCODE: \(message)\n")
            }
        }

        /// Repaints the dock from the reading buffer, e.g. after new messages
        /// or once voice mode consumed one.
        func refreshSharedChatDock() async {
            let entries = await sharedChatReaderEntries()
            await withBottomOverlayTransition {
                await statusBar.setSharedChatReader(
                    entries: entries,
                    unreadCount: sharedChatReadingBuffer.unreadCount,
                    isExpanded: isSharedChatReaderOpen,
                    observationID: sharedChatObservation.observation.id
                )
            }
        }

        // What voice mode asks of this loop (see `TerminalVoiceModeHost`):
        // the room it observes, its reader, and how a dictated line or
        // prompt runs. Removed by the teardown above.
        voiceModeHost.loop = TerminalVoiceModeHost.LoopBindings(
            participants: {
                await self.sessionRunner.sharedChatParticipants(rootSessionID: sharedChatRoomID)
            },
            isUnread: { sharedChatReadingBuffer.isUnread($0) },
            markRead: { id in
                // Reading aloud consumes the message like opening it in the dock.
                sharedChatReadingBuffer.markRead(id: id)
                await refreshSharedChatDock()
            },
            submitLine: { line in
                await handleSubmittedInputLine(line)
            },
            submitPrompt: { result in
                await handleVoicePromptCompleted(result)
            }
        )

        eventLoop: for await event in eventQueue.events {
            // A slash command may have swapped the session between two events.
            await rebindSharedChatObservationIfNeeded()
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
                    guard await handleSubmittedInputLine(line) else {
                        break eventLoop
                    }
                case .cancelRequested:
                    generationTask?.cancel()
                    // A turn adopted from Telegram runs without a task of
                    // this loop: the slot's channel stops it.
                    if isGenerating, generationTask == nil {
                        await stopAdoptedTurn()
                    }
                    await interruptVoicePlayback()
                case .toggleAccessModeRequested:
                    // The session Telegram drives keeps its access mode.
                    guard await admitTerminalInput() else { continue }
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
                case let .subAgentDetail(action):
                    // The reader emits these only while the detail is open;
                    // Esc (and `q` in the agent list) close it through the
                    // controller's `onClosed`.
                    await handleSubAgentDetailAction(action)
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
                // The channel that drives the slot now presents the ending,
                // decided once here. The terminal releases the turn's
                // reservation first. Telegram, when `/telegram on` ran
                // meanwhile, presents it while the reservation still holds
                // and releases it after (`presentOwnTurnEndingInTelegram`),
                // so no turn starts from the chat before it received this
                // turn's outcome and summary.
                let reservation = promptReservation
                promptReservation = nil
                let telegramPresentsEnding = sessionHost.activeChannel(in: terminalSlotID) == .telegram
                if telegramPresentsEnding {
                    sessionHost.telegramChannel(in: terminalSlotID)?.primaryTurnEndingWillPresent()
                } else if let reservation {
                    sessionHost.releasePrompt(reservation)
                }
                await statusBar.setProcessing(false)
                await interactiveReader.setPanelProcessing(false)
                // The prompt consumed whatever was staged, so the indicator must
                // not keep advertising attachments that already left.
                await synchronizePanelPendingAttachmentCount()
                let didPresentEnding: Bool
                if telegramPresentsEnding {
                    didPresentEnding = await presentOwnTurnEndingInTelegram(
                        result, releasing: reservation
                    )
                } else {
                    await finishPromptResult(result)
                    didPresentEnding = true
                }
                var finalAnswer: String?
                // An answer Telegram presented is not read aloud here. One read
                // replaces a comment still being read: `speak` takes over
                // whatever is being read and the answer is not subject to the
                // "nothing else is being read" rule of comments. With no answer
                // to read (failed turn, nothing to say, voice paused) a
                // message set aside for the turn is announced right away.
                if didPresentEnding, case let .success(success) = result {
                    finalAnswer = success.finalAssistantContent
                }
                await voiceSession.turnDidEnd(finalAnswer: finalAnswer)
                await refreshSharedChatPanelSuggestions()
                await refreshStatusBarGitStatusSummaryAfterPromptIfNeeded()
                // Release the room only once the queue state is final, so the
                // Core re-offers a pending batch exactly when the terminal is
                // genuinely idle.
                await synchronizeSharedChatConsumerBusyState()
                scheduleQueuedPromptIfNeeded()
            case .startNextQueuedPrompt:
                isQueuedPromptStartScheduled = false
                // Scheduled before `/telegram on` ran: the queue waits for
                // `/telegram off`, whole.
                guard !isGenerating, !queuedPrompts.isEmpty,
                      sessionHost.activeChannel(in: terminalSlotID) == .primary else {
                    continue
                }
                let nextPrompt = queuedPrompts.dequeue()!
                await refreshQueuedPromptCount()
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
                // Turn starts arrive as a separate Core auto-trigger. The reader
                // buffer deduplicates by identity, so replays never update the dock
                // or its unread counter twice.
                let newMessages = sharedChatReadingBuffer.append(messages)
                guard !newMessages.isEmpty else { continue }
                await refreshSharedChatDock()
                await refreshSharedChatPanelSuggestions()
                // Voice mode announces the messages for the operator sent while
                // it listens, one at a time, after whatever is being read. A
                // replayed transcript is older than the observation and stays
                // silent.
                await voiceSession.handleSharedChatMessages(newMessages)
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
                // While Telegram drives the slot its channel observes the room
                // and claims the trigger; the dormant terminal leaves it alone.
                guard sessionHost.activeChannel(in: terminalSlotID) == .primary else {
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
                        origin: .local,
                        isUserVisible: false
                    )
                )
            case .sharedChatParticipantsChanged:
                // Room binding was verified before entering this switch.
                readableSharedChatMentionHandles = await sessionRunner.sharedChatMentionHandles(
                    rootSessionID: sharedChatRoomID
                )
                await refreshSharedChatPanelSuggestions()
            case let .voicePromptCompleted(result):
                await handleVoicePromptCompleted(result)
            case let .voiceUtterance(utterance):
                guard await voiceSession.handleUtterance(utterance) else {
                    break eventLoop
                }
            case let .voiceSpeakingChanged(isSpeaking):
                // Only the end of speech moves the dialogue on, and only when
                // nothing newer is being read.
                await voiceSession.speakingChanged(isSpeaking)
            case let .voiceCommentary(commentary):
                // A comment the root agent wrote before a tool call. It is read
                // only while the turn runs (a late one is dropped), when
                // nothing is being read (a new comment never queues behind or
                // replaces a reading) and the live-chat dialogue is idle (a
                // comment never answers, closes or delays a question). It
                // leaves the dialogue untouched: no transition, no deadline.
                await voiceSession.speakCommentary(commentary, duringTurn: isGenerating)
            case let .voiceDialogueTimedOut(token):
                // The question lapses in silence; its message stays unread.
                await voiceSession.answerDeadlineElapsed(token)
            }
        }

        // Every way out of the loop passes here (end of input, `/exit`,
        // `/setup`, a dictated exit, the queue finishing): an open `/subagent`
        // detail gives the terminal back before the teardown below.
        await closeSubAgentDetail(reason: .sessionEnded)

        // Teardown paths that bypass `finishPromptResult` (end-of-input during
        // generation, cancellation). Finish the queue BEFORE joining the
        // cancelled generation: its detached completion delivery can only
        // conclude once the queue is finished, since this loop no longer
        // consumes it. `finish()` is idempotent, so the teardown defer stays
        // safe.
        eventQueue.finish()
        if let generation = generationTask {
            generationTask = nil
            generation.cancel()
            _ = await generation.value
        }
        if let reservation = promptReservation {
            promptReservation = nil
            sessionHost.releasePrompt(reservation)
        }
        // This loop is ending for good: stop the task-graph observer (and its
        // in-flight debounce) without restarting it, so no observer-driven
        // render can run during or after the teardown below.
        await stopTaskGraphObserver()
        await stopVoiceMode()

        await stopPanelInput()
    }
}
