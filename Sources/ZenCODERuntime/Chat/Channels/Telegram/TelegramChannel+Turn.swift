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
    package func primaryTurnEndingWillPresent() {
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
    package func sessionReservationDidEnd() async {
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
    package func stopActiveTurn(promptID: UUID? = nil) async {
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
    /// observer of an ACP or `zen --telegram` slot quiesced or restarting),
    /// the turn waits for it before it touches anything: the turn's Telegram
    /// side is still the previous turn's, its closing touches only its own,
    /// and the chat receives its outcome and summary before anything of this
    /// turn. A turn moved onto the channel, which the channel runs no task
    /// for, is closed by the channel that ran it: the terminal keeps the
    /// session reserved until the closing ended (see
    /// `TerminalChat+Telegram.swift`), and the wait keeps the closing whole
    /// for a channel that releases it earlier.
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
            turnBlocks.adoptStreamingBlocks()
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
    /// The texts are the terminal's: `*ZenCODE completed*` and the whole
    /// final response (only the text since the last tool boundary once an
    /// intermediate response was published; `Done.` for an empty response),
    /// which the reporter sends in as many messages as it needs, `Stopped.`,
    /// `ZenCODE failed: <message>`, and the summary of
    /// ``TurnFileChangeSummaryPresentation/text(_:includesCommandHint:)``.
    ///
    /// The session is free again: the next queued prompt starts, so a prompt
    /// queued during a turn the channel did not start (a turn that moved onto
    /// it, a turn of the app) does not wait for another turn of the channel.
    /// When the primary channel still holds the turn's reservation (the
    /// terminal releases it only after this), the prompt starts once it is
    /// released (``sessionReservationDidEnd()``).
    ///
    /// On an ACP session's slot, and on the slot of a session started by
    /// `zen --telegram`, the task-graph observer the channel runs is
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
            outcomePayload = .agentResponse("*ZenCODE completed*\n\n\(sentText)")
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
    /// pending command replies are torn down, and, when `lease` is the link's
    /// active route, it is forgotten and the shared-chat relay unbound.
    /// Calling it again changes nothing.
    func routeWasInvalidated(_ lease: TerminalTelegramRouteLease) async {
        if activeTurnLease == lease {
            await stopActiveTurn()
        }
        await endTurnReporting()
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

    // MARK: - Presence

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
