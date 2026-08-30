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

/// Keeps exactly one live shared-chat observation attached for the blocking
/// input fallback.
///
/// A stream can finish because a backend was replaced while retaining the same
/// root session id. That fallback has no runtime event loop and parks inside
/// `readLine` for an unbounded time, so a lifecycle flag it only inspects after
/// the operator finally submits a line would leave the room unobserved in the
/// meantime. Recovery therefore lives on the producer path: the same task that
/// consumes the stream re-attaches when the stream ends without cancellation,
/// which makes repair immediate and independent of input.
///
/// Every dependency is injected, so the recovery, room-change, cancellation and
/// retry-pacing paths are exercised end to end instead of through a bookkeeping
/// set that production code would still have to poll.
actor TerminalSharedChatObservationSupervisor {
    struct Environment: Sendable {
        var attach: @Sendable (String) async -> AgentSharedChatCoordinator.Observation
        var detach: @Sendable (AgentSharedChatCoordinator.Observation) async -> Void
        var handleEvent: @Sendable (
            AgentSharedChatCoordinatorEvent,
            AgentSharedChatCoordinator.Observation
        ) async -> Void
        /// Cooperative pause applied only when a replacement stream ends
        /// without ever delivering an event. A backend that keeps closing the
        /// stream immediately then degrades to a bounded retry instead of a hot
        /// attach loop, while a healthy stream re-attaches without delay.
        var backoff: @Sendable (Int) async -> Void = { attempt in
            let milliseconds = min(2_000, 50 << min(max(0, attempt - 1), 5))
            try? await Task.sleep(for: .milliseconds(milliseconds))
        }
    }

    private let environment: Environment
    private var roomID: String
    private var current: (
        observation: AgentSharedChatCoordinator.Observation,
        task: Task<Void, Never>
    )?
    /// Retires an in-flight attach or a late stream completion whose binding
    /// was already replaced by a room change, a teardown, or a newer recovery.
    private var generation = 0
    private var emptyRestartCount = 0
    private var isStopped = false
    /// Automatic re-attachments performed after a non-cancelled end.
    private(set) var recoveryCount = 0

    init(roomID: String, environment: Environment) {
        self.roomID = roomID
        self.environment = environment
    }

    func start() async {
        guard !isStopped, current == nil else { return }
        await bind()
    }

    /// Observation currently attached, for callers that must address the live
    /// observer identity. `nil` only while a replacement is being attached.
    func currentObservation() -> AgentSharedChatCoordinator.Observation? {
        current?.observation
    }

    /// Follows a `/new` or `/resume` room swap. Same-room ends are already
    /// repaired by the producer path, so this stays a pure room-change hook.
    func follow(roomID newRoomID: String) async {
        guard !isStopped else { return }
        guard newRoomID != roomID || current == nil else { return }
        roomID = newRoomID
        emptyRestartCount = 0
        await teardownCurrent()
        await bind()
    }

    /// Local teardown. Cancellation is not a reason to attach a replacement, so
    /// this permanently retires the supervisor.
    func stop() async {
        guard !isStopped else { return }
        isStopped = true
        await teardownCurrent()
    }

    private func bind() async {
        guard !isStopped, current == nil else { return }
        generation += 1
        let generation = self.generation
        let roomID = self.roomID
        let environment = self.environment
        let observation = await environment.attach(roomID)
        guard !isStopped, generation == self.generation else {
            // A stop or a room change landed while attaching: release the
            // subscription instead of leaking it into a retired generation.
            await environment.detach(observation)
            return
        }
        current = (
            observation,
            Task(name: "ZenCODE.TUI.blocking-shared-chat-events") { [weak self] in
                var didHandleEvent = false
                for await event in observation.events {
                    if Task.isCancelled { break }
                    didHandleEvent = true
                    await environment.handleEvent(event, observation)
                }
                guard !Task.isCancelled else { return }
                await self?.observationDidEnd(
                    generation: generation,
                    didHandleEvent: didHandleEvent
                )
            }
        )
    }

    /// Producer-side repair for a stream that finished on its own.
    private func observationDidEnd(generation: Int, didHandleEvent: Bool) async {
        guard !isStopped, generation == self.generation, let ended = current else {
            return
        }
        // Release the finished subscription before attaching its replacement so
        // the Core never sees two observers for this one terminal.
        current = nil
        await environment.detach(ended.observation)
        guard !isStopped, generation == self.generation else { return }
        if didHandleEvent {
            emptyRestartCount = 0
        } else {
            emptyRestartCount += 1
            await environment.backoff(emptyRestartCount)
            guard !isStopped, generation == self.generation else { return }
        }
        recoveryCount += 1
        await bind()
    }

    private func teardownCurrent() async {
        // Retire the outgoing generation first: a completion racing this
        // teardown must not schedule a replacement behind our back.
        generation += 1
        guard let retired = current else { return }
        current = nil
        retired.task.cancel()
        await retired.task.value
        await environment.detach(retired.observation)
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

    /// Handles one shared-chat event for the blocking input fallback.
    ///
    /// Keeping this out of the stream pump leaves the supervisor responsible for
    /// stream lifecycle only, while room binding, trigger claiming and turn
    /// serialization stay here, unchanged.
    private func handleBlockingSharedChatEvent(
        _ event: AgentSharedChatCoordinatorEvent,
        observation: AgentSharedChatCoordinator.Observation,
        promptGate: TerminalBlockingPromptGate
    ) async {
        switch event {
        case let .messages(messages):
            // Shared-chat traffic is visible only in the reader panel. Never
            // append it to the main conversation transcript.
            //
            // `/telegram` is available in this fallback too, so cards must be
            // forwarded here as well. The binding itself is refreshed at the
            // room boundary below, not here: this only guards against a batch
            // of a room that is no longer the live one.
            guard observation.roomID == sessionID else { break }
            await forwardSharedChatMessagesToTelegram(
                messages,
                roomID: observation.roomID
            )
        case .participantsChanged:
            break
        case let .autoTrigger(trigger):
            guard trigger.roomID == sessionID,
                  trigger.roomID == observation.roomID else {
                await sessionRunner.declineSharedChatAutoTrigger(
                    id: trigger.id,
                    rootSessionID: trigger.roomID
                )
                return
            }
            let claim = await sessionRunner.resolveSharedChatAutoTrigger(
                id: trigger.id,
                observation: observation,
                resolution: .started
            )
            guard claim == .acquired else { return }

            guard await promptGate.acquire() else { return }
            // Session replacement can race while this trigger waits
            // behind an ordinary turn. The claimed batch is returned
            // by detach below rather than sent into the new session.
            guard trigger.roomID == sessionID else {
                await promptGate.release()
                return
            }
            await runPromptBlocking(
                promptAttempt(
                    prompt: trigger.prompt,
                    origin: takeTelegramSharedChatOrigin(for: trigger.messages) ?? .local,
                    isUserVisible: false
                )
            )
            await promptGate.release()
        }
    }

    func runBlockingInputLoop(initialInputLine: String?) async throws {
        var pendingInputLine = initialInputLine
        let promptGate = TerminalBlockingPromptGate()
        // This loop is parked inside `readLine` for an unbounded time, so the
        // observation lifecycle cannot depend on it: the supervisor re-attaches
        // from the producer path as soon as a stream ends without cancellation.
        let sharedChatObservations = TerminalSharedChatObservationSupervisor(
            roomID: sessionID,
            environment: TerminalSharedChatObservationSupervisor.Environment(
                attach: { [sessionRunner] roomID in
                    await sessionRunner.attachSharedChatObservation(
                        rootSessionID: roomID
                    )
                },
                detach: { [sessionRunner] observation in
                    await sessionRunner.detachSharedChatObservation(observation)
                },
                handleEvent: { [weak self] event, observation in
                    await self?.handleBlockingSharedChatEvent(
                        event,
                        observation: observation,
                        promptGate: promptGate
                    )
                }
            )
        )
        await sharedChatObservations.start()
        // Bind the relay to the initial room up front. Waiting for the first
        // `.messages` batch would leave a `/telegram on` session unbound in a
        // quiet room, so nothing addressed to the operator would be forwarded.
        await rebindTelegramSharedChatRelay(roomID: sessionID)

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

            if shouldContinue {
                // Fence and bind Telegram before attaching the next room's
                // observer. Its replay may arrive as soon as `follow` suspends;
                // binding afterward could drop that first batch or let a retired
                // room keep sending during the attach. Re-activating an
                // unchanged room is idempotent.
                await rebindTelegramSharedChatRelay(roomID: sessionID)
                // A stream that ended by itself was already repaired; this only
                // follows a `/new` or `/resume` room swap.
                await sharedChatObservations.follow(roomID: sessionID)
            }
        }

        await sharedChatObservations.stop()
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
                // `stop` or a backend replacement can finish an observation
                // without changing the session identifier. Surface that lifecycle
                // edge to the serialized loop; cancellation is local teardown,
                // not a reason to attach a replacement observer.
                guard !Task.isCancelled else { return }
                // Do this at the producer lifecycle boundary rather than after
                // a potentially slow slash-command replacement returns. The
                // status bar accepts the observation identity, so a late old
                // completion cannot erase the replacement dock.
                await statusBar.removeSharedChatReader(ownedBy: observation.id)
                _ = await eventQueue.sendWithBackpressure(
                    .sharedChatObservationEnded(
                        roomID: roomID,
                        observationID: observation.id
                    )
                )
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
            sharedChatObservation = await startSharedChatObservation(
                roomID: sharedChatRoomID
            )
            sharedChatReadingBuffer = TerminalSharedChatReadingBuffer()
            isSharedChatReaderOpen = false
            await statusBar.setSharedChatReader(
                entries: [],
                unreadCount: 0,
                isExpanded: false,
                observationID: sharedChatObservation.observation.id
            )
            interactiveReader.setSharedChatReaderOpen(false)
            readableSharedChatMentionHandles = await sessionRunner.sharedChatMentionHandles(
                rootSessionID: sharedChatRoomID
            )
            // A new room invalidates the Telegram receipt map: a reply to a card
            // from the retired room must not be routed into this one.
            await rebindTelegramSharedChatRelay(roomID: sharedChatRoomID)
            await synchronizeSharedChatConsumerBusyState()
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
                let result: TerminalChatGenerationResult
                do {
                    if let onGenerateResponseForTesting = self.onGenerateResponseForTesting {
                        result = .success(try await onGenerateResponseForTesting(attempt))
                    } else {
                        result = .success(try await self.generateResponse(attempt: attempt))
                    }
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
            await remoteTranscriptions.cancelAllAndWait(shuttingDown: true)
            await statusBar.stop()
            throw TerminalChatError.interactivePromptUnavailable
        }
        // An attached observation is the active-chat signal. Show its compact
        // indicator even before the first message arrives.
        await statusBar.setSharedChatReader(
            entries: [],
            unreadCount: 0,
            isExpanded: false,
            observationID: sharedChatObservation.observation.id
        )
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
                        await statusBar.setSharedChatReader(
                            entries: entries,
                            unreadCount: sharedChatReadingBuffer.unreadCount,
                            isExpanded: false,
                            observationID: sharedChatObservation.observation.id
                        )
                        isSharedChatReaderOpen = false
                        interactiveReader.setSharedChatReaderOpen(false)
                        continue
                    }
                    // Opening is a single status-bar transaction: it validates
                    // the viewport, commits expanded + selection and repaints
                    // without an intervening await, and reports whether a
                    // payload row was actually shown. Only then is opening
                    // committed as a reader action, so its selection/read
                    // state is applied after a visible payload is guaranteed.
                    let didExpand = await statusBar.expandSharedChatReader(
                        entries: entries,
                        unreadCount: sharedChatReadingBuffer.readerOpeningUnreadCount,
                        selection: .message(sharedChatReadingBuffer.readerOpeningMessageID),
                        observationID: sharedChatObservation.observation.id
                    )
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
                // The resize producer may have yielded while a refresh was
                // suspended. Reconcile on this FIFO after that refresh, so this
                // collapse is authoritative and cannot leave the status dock
                // expanded after its buffer/input peers have closed.
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
                await refreshSharedChatPanelSuggestions()
                await refreshStatusBarGitStatusSummaryAfterPromptIfNeeded()
                // Release the room only once the queue state is final, so the
                // Core re-offers a pending batch exactly when the terminal is
                // genuinely idle.
                await synchronizeSharedChatConsumerBusyState()
                scheduleQueuedPromptIfNeeded()
            case let .telegramRouteInvalidated(lease):
                guard activeTelegramTurnOrigin?.telegramLease == lease else { continue }
                generationTask?.cancel()
                generationTask = nil
                isGenerating = false
                await statusBar.setProcessing(false)
                await interactiveReader.setPanelProcessing(false)
                await endTelegramTurnProgressReporting()
                await telegramRouteRuntimeState.teardown(lease: lease)
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
                // The decision to start a turn belongs to the
                // Core coordinator and arrives as a separate auto-trigger.
                // Room binding was verified before entering this switch.
                // The terminal-local reader buffer owns identity deduplication;
                // replayed messages therefore update neither the dock nor its
                // unread counter twice.
                let newMessages = sharedChatReadingBuffer.append(messages)
                guard !newMessages.isEmpty else { continue }
                let entries = await sharedChatReaderEntries()
                // The status bar composes the compact header with live activity
                // and moves the scroll boundary in the same actor transaction.
                await statusBar.setSharedChatReader(
                    entries: entries,
                    unreadCount: sharedChatReadingBuffer.unreadCount,
                    isExpanded: isSharedChatReaderOpen,
                    observationID: sharedChatObservation.observation.id
                )
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

        // Loop teardown paths that bypass `finishPromptResult` (end-of-input
        // during generation, or cancellation of this loop's task) must still
        // retire the turn's Telegram reporting so no reporter outlives its
        // turn and no mirror is left in flight. Finish the queue BEFORE
        // joining the cancelled generation: the generation waits on a detached
        // completion delivery whose backpressure send can only conclude once
        // the queue is finished (or a slot frees up, which requires the
        // consumer this loop no longer runs). `finish()` is idempotent, so
        // the teardown defer below remains safe. Joining first also guarantees
        // a cancelled `generateResponse` suspended right before its
        // `beginTelegramTurnProgressReporting` call cannot open a reporting
        // session after the retirement below.
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

        await stopPanelInput()
    }
}
