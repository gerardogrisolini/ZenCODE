//
//  TerminalChat+InputLoop.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

/// Serializes ordinary and shared-chat-generated turns in the blocking input
/// fallback. Unlike the interactive panel, that loop has no event queue whose
/// `isGenerating` state can provide the same exclusion.
private actor TerminalBlockingPromptGate {
    private var isHeld = false
    private var waiters: [(
        id: UUID,
        continuation: CheckedContinuation<Bool, Never>
    )] = []

    func acquire() async -> Bool {
        guard !Task.isCancelled else { return false }
        guard isHeld else {
            isHeld = true
            return true
        }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((waiterID, continuation))
            }
        } onCancel: {
            Task(name: "ZenCODE.TUI.blocking-prompt-gate-cancel") {
                await self.cancelWaiter(waiterID)
            }
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().continuation.resume(returning: true)
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}

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
            await renderCoordinator.beginExternalTerminalPrompt()
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

    static func readConsentKeyOffActor(
        reader: TerminalInteractiveLineReader,
        prompt: String
    ) async -> String? {
        await TerminalBlockingRead.run { token in
            reader.readSingleKey(
                prompt: prompt,
                shouldCancel: token.isCancelled
            )
        }
    }

    /// Reads one interactive line off the cooperative executor.
    ///
    /// `TerminalInteractiveLineReader.readLine(prompt:)` puts the terminal in raw
    /// mode and blocks the calling thread until the operator submits a line, so
    /// it must never run on `TerminalChatActor`: doing so would stall rendering,
    /// the status bar, and every background refresh task for the whole wait.
    /// The read is cancellation-aware, so a cancelled turn does not leave the
    /// terminal owned by a read nobody awaits.
    static func readLineOffActor(
        reader: TerminalInteractiveLineReader,
        prompt: String
    ) async -> String? {
        await TerminalBlockingRead.run { token in
            reader.readLine(prompt: prompt, shouldCancel: token.isCancelled)
        }
    }

    /// Reads a single piped line off the cooperative executor.
    ///
    /// Used for the very first non-interactive line, before the input loop
    /// takes over: `StdioLineReader.readLine()` blocks on stdin, so it must not
    /// run on `TerminalChatActor`. No paste drain happens here because the line
    /// is handed to the loop as its pending input. The bridge token is passed
    /// down so the poll loop unwinds on cancellation: the bridge now waits for
    /// this body to return before resuming its caller, so a read that ignored
    /// the token would hold the teardown until a line arrived.
    static func readStdinLineOffActor(
        reader: StdioLineReader
    ) async -> String? {
        await TerminalBlockingRead.run { token in
            reader.readLine(shouldCancel: token.isCancelled)
        }
    }

    /// Reads one piped line plus any buffered paste continuation off the
    /// cooperative executor. Both `readLine()` and `drainBufferedLines(_:)`
    /// block on stdin, so they run together off the cooperative pool to keep the
    /// paste-drain window contiguous with its originating line.
    ///
    /// The token is threaded through *both* halves. The drain keeps consuming
    /// while data keeps arriving, so against a continuous producer it has no
    /// natural end: only cancellation ends it, and the bridge stays suspended
    /// until this body returns.
    static func readPipedLineOffActor(
        reader: StdioLineReader,
        initialLine: String?,
        waitMilliseconds: Int32
    ) async -> String? {
        await TerminalBlockingRead.run { token in
            guard let line = initialLine
                ?? reader.readLine(shouldCancel: token.isCancelled) else {
                return nil
            }
            guard !token.isCancelled() else {
                return nil
            }
            let pastedLines = reader.drainBufferedLines(
                waitMilliseconds: waitMilliseconds,
                shouldCancel: token.isCancelled
            )
            return ([line] + pastedLines).joined(separator: "\n")
        }
    }

    func runBlockingInputLoop(initialInputLine: String?) async throws {
        var pendingInputLine = initialInputLine
        let promptGate = TerminalBlockingPromptGate()

        func startSharedChatObservation(
            roomID: String
        ) async -> (
            observation: AgentSharedChatCoordinator.Observation,
            task: Task<Void, Never>
        ) {
            let observation = await sessionRunner.attachSharedChatObservation(
                rootSessionID: roomID
            )
            let task = Task(name: "ZenCODE.TUI.blocking-shared-chat-events") { [weak self] in
                for await event in observation.events {
                    guard let self else { return }
                    switch event {
                    case let .messages(messages):
                        // Operator messages were rendered synchronously by
                        // `sendSharedChatMention`; render only incoming traffic.
                        await self.renderSharedChatMessages(
                            messages.filter { $0.sender.kind != .operator }
                        )
                    case .participantsChanged:
                        break
                    case let .autoTrigger(trigger):
                        guard trigger.roomID == self.sessionID,
                              trigger.roomID == observation.roomID else {
                            await self.sessionRunner.declineSharedChatAutoTrigger(
                                id: trigger.id,
                                rootSessionID: trigger.roomID
                            )
                            continue
                        }
                        let claim = await self.sessionRunner.resolveSharedChatAutoTrigger(
                            id: trigger.id,
                            observation: observation,
                            resolution: .started
                        )
                        guard claim == .acquired else { continue }

                        guard await promptGate.acquire() else { return }
                        // Session replacement can race while this trigger waits
                        // behind an ordinary turn. The claimed batch is returned
                        // by detach below rather than sent into the new session.
                        guard trigger.roomID == self.sessionID else {
                            await promptGate.release()
                            continue
                        }
                        await self.runPromptBlocking(
                            self.promptAttempt(
                                prompt: trigger.prompt,
                                origin: .local,
                                isUserVisible: false
                            )
                        )
                        await promptGate.release()
                    }
                }
            }
            return (observation, task)
        }

        var observedRoomID = sessionID
        var sharedChatObservation = await startSharedChatObservation(roomID: observedRoomID)
        var shouldContinue = true
        while shouldContinue {
            let promptInput: String
            if stdinIsTerminal {
                guard let line = await Self.readLineOffActor(
                    reader: interactiveReader,
                    prompt: "> "
                ) else {
                    break
                }
                promptInput = line
            } else {
                guard let line = await Self.readPipedLineOffActor(
                    reader: reader,
                    initialLine: pendingInputLine,
                    waitMilliseconds: 80
                ) else {
                    break
                }
                pendingInputLine = nil
                promptInput = line
            }

            switch await submittedLineAction(promptInput) {
            case .continueChat:
                break
            case .exitChat:
                shouldContinue = false
            case .requestSetup:
                requestedRuntimeSetup = true
                shouldContinue = false
            case let .runPrompt(prompt):
                guard await promptGate.acquire() else {
                    shouldContinue = false
                    break
                }
                await runPromptBlocking(promptAttempt(prompt: prompt))
                await promptGate.release()
            case let .runHiddenPrompt(prompt, purpose):
                guard await promptGate.acquire() else {
                    shouldContinue = false
                    break
                }
                await runPromptBlocking(
                    promptAttempt(prompt: prompt, isUserVisible: false, purpose: purpose)
                )
                await promptGate.release()
            case let .prefillPrompt(prompt):
                await writeSystemMessage("Draft prompt:\n\(prompt)\n")
            }

            if shouldContinue, observedRoomID != sessionID {
                sharedChatObservation.task.cancel()
                await sharedChatObservation.task.value
                await sessionRunner.detachSharedChatObservation(
                    sharedChatObservation.observation
                )
                observedRoomID = sessionID
                sharedChatObservation = await startSharedChatObservation(roomID: observedRoomID)
            }
        }

        sharedChatObservation.task.cancel()
        await sharedChatObservation.task.value
        await sessionRunner.detachSharedChatObservation(sharedChatObservation.observation)
    }

    func runInteractivePanelLoop() async throws {
        let eventQueue = TerminalChatEventQueue()
        var queuedPrompts = TerminalQueuedPromptBuffer()
        var generationTask: Task<Void, Never>?
        let remoteTranscriptions = TerminalVoiceTranscriptionRegistry()
        let telegramForwardingTask = startTelegramForwardingTask(eventQueue: eventQueue)
        // Mailbox monitoring, drain batching and the idle/busy decision belong
        // to the Core coordinator. This task only forwards its live events into
        // the terminal queue: the TUI renders and answers, but never owns the
        // auto-trigger semantics, so non-TUI consumers behave identically.
        func startSharedChatObservation(
            roomID: String
        ) async -> (
            observation: AgentSharedChatCoordinator.Observation,
            task: Task<Void, Never>
        ) {
            let observation = await sessionRunner.attachSharedChatObservation(rootSessionID: roomID)
            let task = Task(name: "ZenCODE.TUI.shared-chat-events") {
                for await event in observation.events {
                    switch event {
                    case let .messages(messages):
                        // Shared-chat messages are never evicted from the
                        // bounded runtime queue: the box must reach this
                        // observer within the transcript bound, so the forwarder
                        // applies backpressure instead of dropping. The TUI
                        // deduplicates by message id, so a replayed transcript
                        // cannot double-render.
                        _ = await eventQueue.sendWithBackpressure(
                            .sharedChatMessages(roomID: roomID, messages: messages)
                        )
                    case .participantsChanged:
                        eventQueue.send(.sharedChatParticipantsChanged(roomID: roomID))
                    case let .autoTrigger(trigger):
                        // A trigger has Core-owned recovery semantics. Do not
                        // retain it in a local overflow side-channel: if the
                        // bounded TUI FIFO is full, decline it immediately and
                        // let the coordinator requeue the batch for a later turn.
                        if eventQueue.offer(.sharedChatAutoTrigger(trigger)) == .rejectedFull {
                            await sessionRunner.declineSharedChatAutoTrigger(
                                id: trigger.id,
                                rootSessionID: trigger.roomID
                            )
                        }
                    }
                }
            }
            return (observation, task)
        }

        // The room follows the live session id: `/new` and `/resume` swap it and
        // delegated agents then register in the new room, so the observation is
        // rebound instead of silently watching a retired one.
        var sharedChatRoomID = sessionID
        var sharedChatObservation = await startSharedChatObservation(
            roomID: sharedChatRoomID
        )
        var isGenerating = false
        var isQueuedPromptStartScheduled = false
        // Rendering history belongs to this terminal observer only. A message
        // replayed to a second observer must remain visible there, while one
        // observer never renders the same Message.id twice. The history is
        // bounded like the room transcript it mirrors.
        var renderedSharedChatMessageIDs = TerminalChat.SharedChatRenderedMessageIDs()
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

        defer {
            // Stop producers before terminating the queue so no task keeps
            // running (or keeps this chat alive) after the loop exits, and any
            // event racing the teardown is dropped instead of buffered forever.
            generationTask?.cancel()
            telegramForwardingTask.cancel()
            sharedChatObservation.task.cancel()
            remoteTranscriptions.cancelAll()
            eventQueue.finish()
            // This loop owns exactly one subscriber. Session teardown performs
            // room-wide stop; detaching here must never end another TUI/ACP
            // observer that is still handling live messages.
            let observation = sharedChatObservation.observation
            Task(name: "ZenCODE.TUI.shared-chat-detach") { [sessionRunner] in
                await sessionRunner.detachSharedChatObservation(observation)
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
        func rebindSharedChatObservationIfNeeded() async {
            guard sharedChatRoomID != sessionID else { return }
            let retiredObservation = sharedChatObservation
            retiredObservation.task.cancel()
            await sessionRunner.detachSharedChatObservation(retiredObservation.observation)
            sharedChatRoomID = sessionID
            sharedChatObservation = await startSharedChatObservation(
                roomID: sharedChatRoomID
            )
            renderedSharedChatMessageIDs.removeAll()
            sharedChatReadingBuffer = TerminalSharedChatReadingBuffer()
            isSharedChatReaderOpen = false
            await statusBar.setSharedChatReader(entries: [], unreadCount: 0, isExpanded: false)
            interactiveReader.setSharedChatReaderOpen(false)
            readableSharedChatMentionHandles = await sessionRunner.sharedChatMentionHandles(
                rootSessionID: sharedChatRoomID
            )
            await synchronizeSharedChatConsumerBusyState()
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
            guard didStart else {
                return false
            }
            await interactiveReader.setPanelProcessing(isGenerating)
            await interactiveReader.setQueuedPromptCount(queuedPrompts.count)
            await synchronizePanelPendingAttachmentCount()
            return true
        }

        func stopPanelInput(clearPanel: Bool = true) async {
            await interactiveReader.stopPanelInput(clearPanel: clearPanel)
        }

        func startGeneration(attempt: TerminalPromptAttempt) async {
            isGenerating = true
            didReceiveMetricsForCurrentPrompt = false
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
                let result: TerminalChatGenerationResult
                do {
                    result = .success(try await self.generateResponse(attempt: attempt))
                } catch is CancellationError {
                    result = .failure(
                        TerminalChatGenerationFailure(
                            message: "",
                            isCancellation: true,
                            origin: attempt.origin,
                            fileChangeSummary: nil
                        )
                    )
                } catch {
                    let failure = TerminalChatGenerationFailure(
                        error: error,
                        origin: attempt.origin
                    )
                    result = .failure(
                        failure
                    )
                }
                // A user cancellation still has to reach the event loop as a
                // cancellation result. Delivery runs in one detached, bounded
                // lifecycle task: cancelling this generation task must not turn
                // a full queue into a silently lost completion and leave the
                // terminal permanently marked as generating. Queue teardown
                // makes the detached delivery return promptly.
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
            await statusBar.stop()
            throw TerminalChatError.interactivePromptUnavailable
        }
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

            switch action {
            case .continueChat:
                if shouldSuspendPanel {
                    _ = await startPanelInput()
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
                    _ = await startPanelInput()
                }
                let attempt = promptAttempt(prompt: prompt, origin: origin)
                if origin == .local {
                    await writeSubmittedPrompt(prompt)
                } else {
                    await writeTelegramSubmittedPrompt(prompt)
                }
                await startGeneration(attempt: attempt)
                return true
            case let .runHiddenPrompt(prompt, purpose):
                if shouldSuspendPanel {
                    _ = await startPanelInput()
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
                    _ = await startPanelInput()
                }
                await interactiveReader.setPanelText(prompt)
                return true
            }
        }

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
                        if let messageID = await sendSharedChatMention(route) {
                            // The outbound card was rendered synchronously.
                            // If the coordinator receives this same message,
                            // its later event is suppressed only in this TUI.
                            renderedSharedChatMessageIDs.insert(messageID)
                        }
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
                case .toggleToolDetailsRequested:
                    await self.toggleToolDetailsOutput()
                    await interactiveReader.refreshPanel()
                case .toggleAccessModeRequested:
                    let accessMode = await sessionRunner.toggleLocalExecAccessMode()
                    await statusBar.update(localExecAccessMode: accessMode)
                    await writeAccessModeChangeMessage(accessMode)
                    await interactiveReader.refreshPanel()
                case .toggleSharedChatReaderRequested:
                    let participants = await sessionRunner.sharedChatParticipants(rootSessionID: sharedChatRoomID)
                    let participantMap = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })
                    let entries = sharedChatReadingBuffer.messages.map {
                        TerminalSharedChatReaderEntry(message: $0, participantMap: participantMap)
                    }
                    let isOpening = !isSharedChatReaderOpen
                    if isOpening {
                        sharedChatReadingBuffer.openReader()
                    } else {
                        sharedChatReadingBuffer.closeReader()
                    }
                    // The dock is rendered by the status bar in the panel's
                    // reserved rows; generation and the normal input loop keep running.
                    await statusBar.setSharedChatReader(entries: entries, unreadCount: sharedChatReadingBuffer.unreadCount, isExpanded: isOpening)
                    isSharedChatReaderOpen = isOpening
                    interactiveReader.setSharedChatReaderOpen(isOpening)
                case let .sharedChatReaderNavigation(action):
                    guard isSharedChatReaderOpen else { continue }
                    let unreadCountBeforeNavigation = sharedChatReadingBuffer.unreadCount
                    sharedChatReadingBuffer.navigate(action)
                    await statusBar.navigateSharedChatReader(action)
                    // The status bar owns the visual selection, while the
                    // terminal-local buffer owns the read marker. Refresh only
                    // when reaching the newest message changed that marker;
                    // `navigateSharedChatReader` has already applied the
                    // selection so `replace` preserves it by message ID.
                    if sharedChatReadingBuffer.unreadCount != unreadCountBeforeNavigation {
                        let participants = await sessionRunner.sharedChatParticipants(rootSessionID: sharedChatRoomID)
                        let participantMap = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })
                        let entries = sharedChatReadingBuffer.messages.map {
                            TerminalSharedChatReaderEntry(message: $0, participantMap: participantMap)
                        }
                        await statusBar.setSharedChatReader(
                            entries: entries,
                            unreadCount: sharedChatReadingBuffer.unreadCount,
                            isExpanded: true
                        )
                    }
                case .endOfInput:
                    generationTask?.cancel()
                    break eventLoop
                }
            case let .generationCompleted(result):
                generationTask = nil
                isGenerating = false
                await statusBar.setProcessing(false)
                await interactiveReader.setPanelProcessing(false)
                // The prompt consumed whatever was staged, so the indicator must
                // not keep advertising attachments that already left.
                await synchronizePanelPendingAttachmentCount()
                await finishPromptResult(result)
                await refreshSharedChatPanelSuggestions()
                await refreshStatusBarGitStatusSummaryAfterPromptIfNeeded()
                // Release the room only once the queue state is final, so the
                // Core re-offers a pending batch exactly when the terminal is
                // genuinely idle.
                await synchronizeSharedChatConsumerBusyState()
                scheduleQueuedPromptIfNeeded()
            case .startNextQueuedPrompt:
                isQueuedPromptStartScheduled = false
                guard !isGenerating, !queuedPrompts.isEmpty else {
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
                // Rendering only: the decision to start a turn belongs to the
                // Core coordinator and arrives as a separate auto-trigger.
                // Room binding was verified before entering this switch.
                // Keep the transcript reader independent from card rendering:
                // outbound operator IDs are pre-recorded below to suppress a
                // duplicate card, but their eventual transcript entry must
                // still appear as unread in the reader.
                let newlyBufferedMessages = sharedChatReadingBuffer.append(messages)
                let newlyReceivedMessages = Self.newlyReceivedSharedChatMessages(
                    messages,
                    renderedMessageIDs: &renderedSharedChatMessageIDs
                )
                await renderSharedChatCompactMessages(
                    newlyReceivedMessages,
                    unreadCount: sharedChatReadingBuffer.unreadCount
                )
                if isSharedChatReaderOpen, !newlyBufferedMessages.isEmpty {
                    let participants = await sessionRunner.sharedChatParticipants(rootSessionID: sharedChatRoomID)
                    let participantMap = Dictionary(uniqueKeysWithValues: participants.map { ($0.id, $0) })
                    let entries = sharedChatReadingBuffer.messages.map { TerminalSharedChatReaderEntry(message: $0, participantMap: participantMap) }
                    await statusBar.setSharedChatReader(entries: entries, unreadCount: sharedChatReadingBuffer.unreadCount, isExpanded: true)
                }
                await refreshSharedChatPanelSuggestions()
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
            case let .telegramMessage(message):
                await handleTelegramMessage(
                    message,
                    queuedPrompts: &queuedPrompts,
                    eventQueue: eventQueue,
                    transcriptions: remoteTranscriptions
                )
                await refreshQueuedPromptCount()
                scheduleQueuedPromptIfNeeded()
            case let .voicePromptCompleted(result):
                switch result.outcome {
                case let .success(prompt):
                    if isGenerating || !queuedPrompts.isEmpty {
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

        await stopPanelInput()
    }
}
