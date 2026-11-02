//
//  TelegramChannel+Turn.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The turns of a ``TelegramChannel``: the ones the chat starts, run through
/// the host, the prompts waiting for the session to be free, and the
/// Telegram side of the turn in progress (its route lease, the ordered
/// reporter that sends it to the linked chat, the typing presence, and the
/// task that stops it when its route is revoked).
///
/// The slot's presenter drives the turn's boundaries through the channel's
/// ``TelegramChannelPresenter``: ``beginTurn(adoptingStreamingBlock:liveThought:)`` when
/// a turn starts or moves onto the channel, the reasoning blocks, the root
/// response, and the tool calls while it runs, and ``finishTurn(ending:)``
/// with its ending.
extension TelegramChannel {
    // MARK: - Running turns

    /// Runs `prompt` as a turn of the session, on the route `lease` it came
    /// from, when the session is free; otherwise queues it (see
    /// ``admitPrompt(_:lease:mode:)``). `mode` says whether the text is a
    /// submitted line, answered by ``lineAction(for:lease:)`` when it runs,
    /// or a prompt that runs as it is (a transcribed voice note).
    ///
    /// The answer is what happened to the prompt by the time the call
    /// returns: started or queued, or dropped because the queue is full, in
    /// which case the chat is told with the terminal's text, where `kind`
    /// names what was not queued. A queued prompt keeps the channel busy for
    /// the shared chat (``synchronizeSharedChatConsumerBusyState()``).
    @discardableResult
    func admitPrompt(
        _ text: String,
        lease: TerminalTelegramRouteLease,
        mode: ChatQueuedPromptMode = .submittedLine,
        kind: String = "prompt"
    ) async -> Bool {
        let prompt = ChatQueuedPrompt(text: text, origin: lease, mode: mode)
        guard isSessionGenerating || activeTurnTask != nil || !promptQueue.isEmpty else {
            startTurnTask(for: prompt)
            return true
        }
        guard promptQueue.enqueue(prompt) else {
            await sendSystemMessageIfLinked(
                "ZenCODE is busy and the prompt queue is full. Your \(kind) was not queued; try again after a running prompt completes.",
                lease: lease
            )
            return false
        }
        await synchronizeSharedChatConsumerBusyState()
        return true
    }

    /// Starts the next queued prompt once the session is free and no turn of
    /// the channel runs. The task that runs it declares the channel busy for
    /// the shared chat as it starts.
    func startNextQueuedPromptIfNeeded() {
        guard activeTurnTask == nil, !isSessionGenerating,
              let next = promptQueue.dequeue() else { return }
        startTurnTask(for: next)
    }

    /// Runs `prompt` in a task of the channel: a submitted line is answered
    /// first (a remote command, a reply to a pending question, `/plan`
    /// `/goal` `/review`), and what remains runs as a turn through the host.
    /// The channel is busy for the shared chat from the start of the task,
    /// before the line runs, and the next queued prompt starts when it ends
    /// (``turnTaskDidEnd()``).
    private func startTurnTask(for prompt: ChatQueuedPrompt<TerminalTelegramRouteLease>) {
        activeTurnTask = Task(name: "ZenCODE.Telegram.channel-turn") { [weak self] in
            guard let self else { return }
            await self.synchronizeSharedChatConsumerBusyState()
            await self.runQueuedPrompt(prompt)
            await self.turnTaskDidEnd()
        }
    }

    /// Ends the task of the channel that just finished (``activeTurnTask``):
    /// the next queued prompt starts, and the shared chat is told whether the
    /// channel is still busy, so a batch it declined meanwhile is offered
    /// again once nothing of the channel waits.
    func turnTaskDidEnd() async {
        activeTurnTask = nil
        startNextQueuedPromptIfNeeded()
        await synchronizeSharedChatConsumerBusyState()
    }

    /// The primary channel is about to present in the chat the ending of a
    /// turn it ran, and keeps the session reserved for that turn until it
    /// released it (``sessionReservationDidEnd()``): see
    /// ``isPresentingPrimaryTurnEnding``.
    func primaryTurnEndingWillPresent() {
        isPresentingPrimaryTurnEnding = true
    }

    /// Resumes what waited for the session once the primary channel released
    /// the reservation of a turn whose ending the channel presented while the
    /// reservation still held (see `TerminalChat+Telegram.swift`): closing
    /// that turn (``finishTurn(ending:)``) found the session still reserved
    /// and started nothing. As at the end of a task of the channel
    /// (``turnTaskDidEnd()``), the next queued prompt starts (a voice note
    /// transcribed meanwhile included), and the shared chat is told whether
    /// the channel is still busy, so a batch it declined meanwhile is offered
    /// again. A queued prompt still waits while another prompt holds the
    /// session or a task of the channel runs.
    func sessionReservationDidEnd() async {
        isPresentingPrimaryTurnEnding = false
        startNextQueuedPromptIfNeeded()
        await synchronizeSharedChatConsumerBusyState()
    }

    /// Stops the task of the channel whose turn holds no reservation of the
    /// session yet (a line still answered by ``lineAction(for:lease:)``, a
    /// coordinator turn not started yet) and waits for it: once the channel
    /// no longer drives the slot, what it read must not start a turn. A turn
    /// that holds the reservation goes on, and the channel that took the slot
    /// adopts it.
    func stopTurnTaskWithoutReservation() async {
        guard let task = activeTurnTask,
              host?.telegramTurnHoldsReservation(in: slotID) != true else { return }
        task.cancel()
        await task.value
    }

    private func runQueuedPrompt(_ prompt: ChatQueuedPrompt<TerminalTelegramRouteLease>) async {
        let lease = prompt.origin
        guard await validateLease(lease) else { return }
        switch prompt.mode {
        case .directPrompt:
            await runTurn(prompt: prompt.text, lease: lease)
        case .submittedLine:
            switch await lineAction(for: prompt.text, lease: lease) {
            case .handled:
                return
            case let .runPrompt(text):
                await runTurn(prompt: text, lease: lease)
            case let .startTurn(text, purpose, locksResponseLanguage):
                await runTurn(
                    prompt: text, lease: lease, purpose: purpose,
                    isUserVisible: locksResponseLanguage
                )
            }
        }
    }

    /// Runs one turn through the host, on the route `lease`. The host
    /// composes the request as the primary channel would, presents the
    /// ending on the channel that drives the slot when it ends (this one,
    /// unless `/telegram off` took the slot back meanwhile), and reports a
    /// prompt that cannot be reserved: the session is busy (the chat is told
    /// the busy text) or gone (nothing is said). A channel that no longer
    /// drives the slot (`/telegram off` took it back while the line was
    /// answered) starts nothing and says nothing.
    func runTurn(
        prompt: String,
        lease: TerminalTelegramRouteLease,
        purpose: ChatTurnPurpose = .normal,
        isUserVisible: Bool = true
    ) async {
        if let onRunTurnForTesting {
            await onRunTurnForTesting(prompt, lease, purpose)
            return
        }
        guard let host, drivesSlot else { return }
        nextTurnLease = lease
        defer { nextTurnLease = nil }
        do {
            try await host.runTelegramTurn(
                in: slotID,
                prompt: prompt,
                purpose: purpose,
                isUserVisible: isUserVisible
            )
        } catch let error as ChatSessionHostError {
            if error == .sessionBusy {
                await sendSystemMessageIfLinked(Self.busyMessageText, lease: lease)
            }
        } catch {
            // A failed or cancelled turn was presented as its ending; a turn
            // refused because the channel stopped driving the slot was not
            // reserved, and one the primary channel refused (an ACP session
            // closed meanwhile) was released before it ran: neither has
            // anything to present.
        }
    }

    /// Stops the turn the channel follows, as the stop button of a streamed
    /// draft asks, or the turn of the channel that reserved `promptID` (an
    /// editor's `session/cancel` already dropped that reservation): the
    /// channel's task, if any, is cancelled; the host fences the controller's
    /// turn and drops the reservation only while the prompt reserved on the
    /// session is still that turn's (`promptID`, else the one recorded when
    /// the turn began on the channel, ``activeTurnPromptID``); and the runner
    /// cancels the session's prompt only while no other prompt is reserved,
    /// so a prompt reserved after the turn's own was released keeps its
    /// reservation and its turn.
    func stopActiveTurn(promptID: UUID? = nil) async {
        guard let host else {
            activeTurnTask?.cancel()
            return
        }
        let sessionID = sessionID
        if let turnPromptID = promptID ?? activeTurnPromptID {
            host.cancelPrompt(turnPromptID, in: slotID)
        }
        activeTurnTask?.cancel()
        guard host.activePromptID(in: slotID) == nil else { return }
        await sessionRunner.cancelPrompt(sessionID: sessionID)
    }

    // MARK: - Turn boundaries

    /// Starts following the turn that starts now, or moved onto the channel
    /// now, on the route of the message that started it
    /// (``nextTurnLease``) or the link's route.
    ///
    /// While the previous turn is still finishing (``finishTurn(ending:)``
    /// is running: its outcome and summary being sent, the task-graph
    /// observer of an ACP slot quiesced or restarting), the turn waits for it
    /// before it touches anything: the turn's Telegram side is still the
    /// previous turn's, its closing touches only its own, and the chat
    /// receives its outcome and summary before anything of this turn. A turn
    /// moved onto the channel, which the channel runs no task for, is closed
    /// by the channel that ran it: the terminal keeps the session reserved
    /// until the closing ended (see `TerminalChat+Telegram.swift`), and the
    /// wait keeps the closing whole for a channel that releases it earlier.
    ///
    /// The reporter of the previous turn is revoked, the root-response and
    /// reasoning state and the task-graph dedup are reset, the turn gets a
    /// reporter and the typing presence, and a turn on a route lease is
    /// stopped when that route is revoked, rebound, or closed. A turn that
    /// moved onto the channel with a block already streaming
    /// (`adoptingStreamingBlock`) suppresses the rest of that block: the
    /// handover sent what streamed so far as context, and the chat must not
    /// receive the suffix alone; the reasoning streaming meanwhile, which may
    /// have begun before the move, is suppressed until the next event that
    /// closes it. Otherwise `liveThought`, the reasoning the moved turn
    /// streamed so far, which the handover does not send, starts the
    /// reasoning block, so the chat receives it whole once it closes.
    func beginTurn(adoptingStreamingBlock: Bool, liveThought: String = "") async {
        await waitForFinishingTurn()
        let lease = nextTurnLease ?? activeRouteLease
        let previousValidationTask = routeValidationTask
        routeValidationTask = nil
        previousValidationTask?.cancel()
        await previousValidationTask?.value
        await activeProgressReporter?.revokeAndWait()
        activeProgressReporter = nil
        activeTurnLease = lease
        activeTurnPromptID = host?.activePromptID(in: slotID)
        resetRootResponseBlock()
        resetThoughtBlock()
        if adoptingStreamingBlock {
            rootResponseBlockHasContent = true
            rootResponseBlockIsSuppressed = true
            thoughtBlockIsSuppressed = true
        } else {
            appendThoughtDelta(liveThought)
        }
        publishedTaskGraphOverviewSignature = nil
        await synchronizeTurnReporting()
        await beginTurnPresenceIfNeeded()
        if let lease, host != nil {
            routeValidationTask = makeRouteValidationTask(lease: lease)
        }
    }

    /// Waits until no turn is finishing (``finishingTurnCount``).
    private func waitForFinishingTurn() async {
        while finishingTurnCount > 0 {
            onBeginTurnWaitsForFinishingTurnForTesting?()
            await withCheckedContinuation { continuation in
                finishingTurnWaiters.append(continuation)
            }
        }
    }

    /// Reconciles the turn in progress with the link as it is now.
    ///
    /// A reporter is kept while the linked chat is the same, so queued
    /// messages keep their order across a repeated `/telegram on`. Without a
    /// linked chat the reporter is revoked together with the root response
    /// text it aggregated; once the link is back a new, empty reporter starts.
    /// A response block that was already streaming across such a transition
    /// is suppressed, so the chat never receives a fragment whose beginning it
    /// could not see.
    func synchronizeTurnReporting() async {
        guard let lease = activeTurnLease,
              let chatID = outgoingChatID(for: lease) else {
            if activeProgressReporter != nil {
                suppressRootResponseBlockIfStreaming()
            }
            let retired = activeProgressReporter
            if let retired { await retired.revokeAndWait() }
            activeProgressReporter = nil
            return
        }
        guard activeProgressReporter?.chatID != chatID else {
            return
        }
        suppressRootResponseBlockIfStreaming()
        activeProgressReporter = makeTurnProgressReporter(for: lease)
    }

    /// Retires the turn's Telegram side with its ending: the outcome and the
    /// file-change summary are queued after the sections the turn already
    /// produced, the reporter is flushed and retired, and the turn's
    /// reporting ends. Without a reporter they are sent to the linked chat
    /// directly.
    ///
    /// The texts are the terminal's: `*ZenCODE completed*` and the final
    /// response cut to 3 600 characters (only the text since the last tool
    /// boundary once an intermediate response was published; `Done.` for an
    /// empty response), `Stopped.`, `ZenCODE failed: <message>`, and the
    /// summary of ``TurnFileChangeSummaryPresentation/text(_:includesCommandHint:)``.
    ///
    /// The session is free again: the next queued prompt starts, so a prompt
    /// queued during a turn the channel did not start (a turn that moved onto
    /// it, a turn of the app) does not wait for another turn of the channel.
    /// When the primary channel still holds the turn's reservation (the
    /// terminal releases it only after this), the prompt starts once it is
    /// released (``sessionReservationDidEnd()``).
    ///
    /// On an ACP session's slot the task-graph observer the channel runs is
    /// quiesced first, as the terminal does at its turn boundaries: the
    /// latest graph reaches this turn before its outcome, and the observer
    /// runs again only once the turn's reporting ended, before the next
    /// queued prompt starts, so nothing it debounced reaches the next turn
    /// (see `TelegramChannel+TaskGraph.swift`).
    ///
    /// From its first line to its last a turn that begins waits for it
    /// (``finishingTurnCount``), so it closes only the turn that ends.
    func finishTurn(ending: ChatTurnEnding) async {
        finishingTurnCount += 1
        let outcomePayload: TerminalTelegramTurnPayload
        switch ending.outcome {
        case let .completed(response):
            let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let completionText = trimmed.isEmpty ? "Done." : trimmed
            let sentText = await finalResponseText(fallback: completionText)
            outcomePayload = .agentResponse(
                "*ZenCODE completed*\n\n\(String(sentText.prefix(3_600)))"
            )
        case let .failed(message):
            outcomePayload = .agentResponse("ZenCODE failed: \(message)")
        case .cancelled:
            outcomePayload = .agentResponse("Stopped.")
        }
        let quiescedController = await quiesceTaskGraphObservationForTurnBoundary()
        await retireTurn(outcomePayload: outcomePayload, fileChangeSummary: ending.fileChangeSummary)
        if let quiescedController {
            await restartTaskGraphObservationAfterTurnBoundary(quiescedController)
        }
        finishingTurnCount -= 1
        if finishingTurnCount == 0 {
            let waiters = finishingTurnWaiters
            finishingTurnWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }
        startNextQueuedPromptIfNeeded()
    }

    /// Retires the turn's Telegram side after its final response, sending
    /// `outcomePayload` as the turn's outcome and the file-change summary;
    /// without a payload only the summary, if any, is sent. A reasoning block
    /// still open is closed by the end of the turn and queued before them.
    func retireTurn(
        outcomePayload: TerminalTelegramTurnPayload?,
        fileChangeSummary: TurnFileChangeSummary?
    ) async {
        await closeThoughtBlock()
        let summaryPayload: TerminalTelegramTurnPayload?
        if let fileChangeSummary, !fileChangeSummary.entries.isEmpty {
            let summary = TurnFileChangeSummaryPresentation
                .text(fileChangeSummary, includesCommandHint: true)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            summaryPayload = summary.isEmpty ? nil : .summary(summary)
        } else {
            summaryPayload = nil
        }

        if let reporter = activeProgressReporter {
            // Trailing content never closed by a tool call is the final
            // response: dropping it here keeps the outcome from being sent
            // twice.
            await reporter.discardPendingAgentResponse()
            if let outcomePayload {
                await reporter.enqueue(outcomePayload)
            }
            if let summaryPayload {
                await reporter.enqueue(summaryPayload)
            }
            await reporter.flush()
            await reporter.retire()
        } else if let lease = activeTurnLease {
            if let outcomePayload {
                await sendTurnMessageIfLinked(outcomePayload, lease: lease)
            }
            if let summaryPayload {
                await sendTurnMessageIfLinked(summaryPayload, lease: lease)
            }
        }
        await endTurnReporting()
    }

    /// Ends the turn's reporting without sending anything more: stops the
    /// sub-agent refresh the presenter started and the route validation,
    /// revokes the reporter, releases the typing presence, and forgets the
    /// turn's route, root-response, and reasoning state.
    func endTurnReporting() async {
        await presenter.stopOwnedSubAgentOverviewRefresh()
        let validationTask = routeValidationTask
        routeValidationTask = nil
        validationTask?.cancel()
        await validationTask?.value
        let retiredReporter = activeProgressReporter
        if let retiredReporter { await retiredReporter.revokeAndWait() }
        if let presence = activePresenceLease {
            await controlService.releasePresenceLease(presence)
        }
        activePresenceLease = nil
        activeProgressReporter = nil
        activeTurnLease = nil
        activeTurnPromptID = nil
        resetRootResponseBlock()
        resetThoughtBlock()
    }

    // MARK: - Route invalidation

    /// A route revoked, rebound, or closed while the turn that came from it
    /// was generating: the turn is stopped, its reporting ends, the route's
    /// runtime state and its pending command replies are torn down, and,
    /// when `lease` is the link's active route, it is forgotten and the
    /// shared-chat relay unbound. Calling it again changes nothing.
    func routeWasInvalidated(_ lease: TerminalTelegramRouteLease) async {
        if activeTurnLease == lease {
            await stopActiveTurn()
        }
        await endTurnReporting()
        await routeRuntimeState.teardown(lease: lease)
        commandReplyBindings = commandReplyBindings.filter {
            $0.value.lease != lease
        }
        if activeRouteLease == lease {
            activeRouteLease = nil
            await sharedChatRelayStorage?.deactivate()
            await activeRouteLeaseDidChange(hadLease: true)
        }
    }

    /// Polls the router while the turn on `lease` runs, and reports the
    /// first failed validation. The task holds the channel weakly and ends
    /// once the channel is gone.
    private func makeRouteValidationTask(lease: TerminalTelegramRouteLease) -> Task<Void, Never> {
        let router = router
        return Task(name: "ZenCODE.Telegram.route-validation") { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                guard self != nil else { return }
                guard (try? await router.validate(lease)) != nil else {
                    await self?.reportInvalidatedRoute(lease)
                    return
                }
            }
        }
    }

    /// Handles an invalidated `lease`, unless the turn's validation was
    /// stopped meanwhile. The finishing task is forgotten first, so the
    /// handling can end the turn's reporting without waiting for the task
    /// that is calling it.
    private func reportInvalidatedRoute(_ lease: TerminalTelegramRouteLease) async {
        // Every path that replaces or stops the validation task cancels it
        // synchronously, so a task that is not cancelled is still the
        // current one.
        guard !Task.isCancelled else { return }
        routeValidationTask = nil
        guard activeTurnLease == lease else { return }
        await routeWasInvalidated(lease)
    }

    // MARK: - Root response

    /// Aggregates one visible root-response delta for the linked chat.
    ///
    /// The reporter buffers the deltas and publishes them as one message at
    /// the next tool boundary; nothing is sent while the response streams.
    func appendRootResponseDelta(_ delta: String) async {
        guard !delta.isEmpty else {
            return
        }
        rootResponseBlockHasContent = true
        guard !rootResponseBlockIsSuppressed,
              let reporter = activeProgressReporter else {
            return
        }
        await reporter.appendAgentResponseDelta(delta)
    }

    /// Publishes the aggregated root response at a tool-call boundary, or
    /// at a reasoning block that assistant content closes
    /// (``closeThoughtBlockBeforeAssistantContent()``).
    ///
    /// The boundary proves the response complete: the model stopped writing
    /// and started a tool, or reasoned before it wrote again. A suppressed
    /// block ends here unsent; the next one is sent again.
    func publishRootResponseAtToolBoundary() async {
        let wasSuppressed = rootResponseBlockIsSuppressed
        rootResponseBlockHasContent = false
        rootResponseBlockIsSuppressed = false
        guard let reporter = activeProgressReporter else {
            return
        }
        guard !wasSuppressed else {
            await reporter.discardPendingAgentResponse()
            return
        }
        guard await reporter.hasPendingAgentResponse else {
            return
        }
        if await reporter.publishPendingAgentResponseAtBoundary() {
            didPublishIntermediateRootResponse = true
        }
    }

    /// The text to send as the turn's final response.
    ///
    /// A turn's response text accumulates every assistant block it produced,
    /// the intermediate responses already published at their tool boundaries
    /// included. Once one was published, the trailing block aggregated since
    /// the last boundary, the final response itself, is sent instead.
    func finalResponseText(fallback: String) async -> String {
        guard didPublishIntermediateRootResponse,
              let reporter = activeProgressReporter else {
            return fallback
        }
        let trailing = await reporter.pendingAgentResponseText()
        return trailing.isEmpty ? fallback : trailing
    }

    /// Marks the streaming root response as unsendable, when one is in
    /// flight: a reporter is retired or replaced in the middle of it.
    func suppressRootResponseBlockIfStreaming() {
        guard rootResponseBlockHasContent else {
            return
        }
        rootResponseBlockIsSuppressed = true
    }

    /// Resets the root-response state at a turn boundary.
    func resetRootResponseBlock() {
        rootResponseBlockHasContent = false
        rootResponseBlockIsSuppressed = false
        didPublishIntermediateRootResponse = false
    }

    // MARK: - Reasoning

    /// Aggregates one reasoning delta of the block streaming now, unless the
    /// block is suppressed. Nothing is queued here: the block is sent whole
    /// once the event that closes it arrives (``closeThoughtBlock()``). The
    /// buffer is bounded just above the message limit, so a long block cannot
    /// grow unbounded and its cut is still seen.
    func appendThoughtDelta(_ delta: String) {
        guard !delta.isEmpty, !thoughtBlockIsSuppressed else { return }
        let remainingCount = TerminalTelegramTurnProgressReporter.maximumMessageLength + 1
            - pendingThought.count
        guard remainingCount > 0 else { return }
        pendingThought.append(contentsOf: delta.prefix(remainingCount))
    }

    /// Closes the reasoning block streaming now: assistant content, a tool
    /// call, an automatic `/goal` continuation, or the end of the turn
    /// followed it. The block is queued as one thinking message, before what
    /// closed it, when a reporter sends the turn and the block is not blank;
    /// a suppressed block ends here and the next one is sent again.
    func closeThoughtBlock() async {
        let thought = pendingThought
        resetThoughtBlock()
        guard thought.nilIfBlank != nil, let reporter = activeProgressReporter else { return }
        await reporter.enqueue(.thought(thought))
    }

    /// Closes the reasoning block that assistant content follows. A block
    /// that is sent (not blank, with a reporter) is a boundary of the root
    /// response written before it: that response is published first, as an
    /// intermediate one (``publishRootResponseAtToolBoundary()``), so the
    /// chat receives it, then the thought, then the content that follows,
    /// in the order they were written. A tool call and an automatic `/goal`
    /// continuation already publish the response before they close the
    /// block; the end of the turn closes it without a boundary, and the
    /// response before it stays the final response.
    func closeThoughtBlockBeforeAssistantContent() async {
        if pendingThought.nilIfBlank != nil, activeProgressReporter != nil {
            await publishRootResponseAtToolBoundary()
        }
        await closeThoughtBlock()
    }

    /// Forgets the reasoning block at a turn boundary.
    func resetThoughtBlock() {
        pendingThought = ""
        thoughtBlockIsSuppressed = false
    }

    // MARK: - Tool activity

    /// Shows a root tool call that started in the turn's activity message:
    /// its title (``ToolCallPresentation/toolTitle(for:)``), never its
    /// arguments. A call the terminal does not show in its tool blocks
    /// (``TerminalChat/shouldSuppressToolRendering(for:)``) is not shown
    /// either; nothing is shown without a reporter.
    func presentToolCallActivityStarted(_ toolCall: DirectAgentToolCall) async {
        guard !TerminalChat.shouldSuppressToolRendering(for: toolCall.name),
              let reporter = activeProgressReporter else { return }
        await reporter.toolCallDidStart(
            id: toolCall.id, title: ToolCallPresentation.toolTitle(for: toolCall)
        )
    }

    /// Writes the outcome of a root tool call in its activity row: ✅, or ❌
    /// when it failed as the terminal judges it
    /// (``TerminalChat/toolResultIsFailure(for:result:)``). Its result is
    /// never sent.
    func presentToolCallActivityCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) async {
        guard !TerminalChat.shouldSuppressToolRendering(for: toolCall.name),
              let reporter = activeProgressReporter else { return }
        await reporter.toolCallDidComplete(
            id: toolCall.id,
            failed: TerminalChat.toolResultIsFailure(for: toolCall, result: result)
        )
    }

    // MARK: - Overviews

    /// Queues an overview section the controller published for the turn in
    /// progress: a task graph (`.tasks`), a sub-agent response
    /// (`.subAgentResponse`), or the sub-agent status (`.subAgentStatus`).
    ///
    /// The section is dropped when no reporter sends the turn: outside a
    /// turn there is no remote audience. A task graph whose
    /// `taskGraphSignature` was already sent during the turn is dropped too,
    /// so republished identical content does not repeat in the chat.
    /// Sections go through the reporter's queue, so they cannot overtake the
    /// tool activity that produced them.
    func enqueueOverview(
        _ payload: TerminalTelegramTurnPayload,
        taskGraphSignature: String? = nil
    ) async {
        guard activeProgressReporter != nil else {
            return
        }
        if let taskGraphSignature {
            guard publishedTaskGraphOverviewSignature != taskGraphSignature else {
                return
            }
            publishedTaskGraphOverviewSignature = taskGraphSignature
        }
        await activeProgressReporter?.enqueue(payload)
    }

    // MARK: - Reporter and presence

    /// The ordered reporter of a turn on `lease`, or `nil` when the turn does
    /// not reach the linked chat or the link has no wire lifecycle. Every
    /// send and every edit, the progress card's, the activity and status
    /// messages', and the thinking messages' included, is fenced by the route
    /// lease and the lifecycle epoch, and validated again before it leaves.
    func makeTurnProgressReporter(
        for lease: TerminalTelegramRouteLease
    ) -> TerminalTelegramTurnProgressReporter? {
        guard let chatID = outgoingChatID(for: lease),
              let lifecycleEpoch = controlState.wireLifecycleEpoch else {
            return nil
        }

        let service = controlService
        let wireFence = TerminalTelegramWireFence(
            lease: lease,
            lifecycleEpoch: lifecycleEpoch,
            validateLease: { [router] lease in
                try await router.validate(lease)
            }
        )
        let topicID = lease.effectiveMessageThreadID
        let cards = TerminalTelegramProgressCardLedger(
            chatID: chatID,
            send: { [weak self] text, chatID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                return try await service.sendPlainMessageWithReceipt(
                    text, to: chatID, topicID: topicID, fence: wireFence
                )
            },
            editText: { [weak self] text, chatID, messageID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                try await service.editMessageText(
                    text, chatID: chatID, messageID: messageID, fence: wireFence
                )
            },
            editMarkup: { [weak self] markup, chatID, messageID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                try await service.editMessageReplyMarkup(
                    markup, chatID: chatID, messageID: messageID, fence: wireFence
                )
            },
            delete: { [weak self] chatID, messageID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                try await service.deleteMessage(
                    chatID: chatID, messageID: messageID, fence: wireFence
                )
            }
        )
        let activity = TerminalTelegramTurnActivityWire(
            sendPlainMessage: { [weak self] text, chatID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                return try await service.sendPlainMessageWithReceipt(
                    text, to: chatID, topicID: topicID, fence: wireFence
                )
            },
            editPlainMessage: { [weak self] text, chatID, messageID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                try await service.editMessageText(
                    text, chatID: chatID, messageID: messageID, fence: wireFence
                )
            },
            sendThought: { [weak self] thought, chatID in
                guard let self, await self.validateLease(lease) else { return false }
                return await self.sendThoughtMessage(
                    thought, to: chatID, topicID: topicID, fence: wireFence
                )
            }
        )
        return TerminalTelegramTurnProgressReporter(
            chatID: chatID,
            sendMessage: { [weak self] message, chatID in
                guard let self, await self.validateLease(lease) else { return false }
                return await self.sendProgressMessage(
                    message, to: chatID, topicID: topicID, fence: wireFence
                )
            },
            sendDraft: { [weak self] text, chatID, draftID in
                guard let self, await self.validateLease(lease) else {
                    throw CancellationError()
                }
                try await service.sendRichMessageDraftWithFallback(
                    text, to: chatID, draftID: draftID, canStop: true, fence: wireFence
                )
            },
            progressCards: cards,
            activityWire: activity,
            wireFence: wireFence,
            waitForWireQuiescence: { fence in
                await service.waitForWireQuiescence(fence: fence)
            }
        )
    }

    /// Sends one reporter message as a rich message, reporting whether it
    /// was delivered. Failures are silent: the reporter owns the outcome.
    @discardableResult
    private func sendProgressMessage(
        _ message: String, to chatID: Int64, topicID: Int? = nil,
        fence: TerminalTelegramWireFence
    ) async -> Bool {
        guard controlState.isActive else {
            return false
        }
        do {
            _ = try await controlService.sendRichMessageWithFallback(
                message, to: chatID, topicID: topicID, fence: fence
            )
            return true
        } catch {
            return false
        }
    }

    /// Sends one reasoning block as a thinking message, reporting whether it
    /// was delivered. Failures are silent, as for the other reporter
    /// messages.
    private func sendThoughtMessage(
        _ thought: String, to chatID: Int64, topicID: Int?,
        fence: TerminalTelegramWireFence
    ) async -> Bool {
        guard controlState.isActive else {
            return false
        }
        do {
            _ = try await controlService.sendThoughtMessageWithFallback(
                thought, to: chatID, topicID: topicID, fence: fence
            )
            return true
        } catch {
            return false
        }
    }

    /// Takes the lifecycle-safe typing lease for the turn. Presence is
    /// best-effort: a chat action that fails says nothing about the link or
    /// the turn, so failures are silent. The lease is released by
    /// ``endTurnReporting()`` and fenced by generation, so a renewal that
    /// wakes after teardown exits without touching the wire.
    private func beginTurnPresenceIfNeeded() async {
        guard let lease = activeTurnLease,
              await validateLease(lease),
              let chatID = outgoingChatID(for: lease),
              let fence = wireFence(for: lease) else {
            return
        }
        activePresenceLease = await controlService.acquirePresenceLease(
            scope: .turn(
                chatID: chatID,
                topicID: lease.effectiveMessageThreadID
            ),
            fence: fence
        )
    }
}
