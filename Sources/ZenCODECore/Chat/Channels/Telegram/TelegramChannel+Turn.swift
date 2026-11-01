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
/// ``TelegramChannelPresenter``: ``beginTurn(adoptingStreamingBlock:)`` when
/// a turn starts or moves onto the channel, the root response and the tool
/// boundaries while it runs, and ``finishTurn(ending:)`` with its ending.
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
    /// names what was not queued.
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
        return true
    }

    /// Starts the next queued prompt once the session is free and no turn of
    /// the channel runs.
    func startNextQueuedPromptIfNeeded() {
        guard activeTurnTask == nil, !isSessionGenerating,
              let next = promptQueue.dequeue() else { return }
        startTurnTask(for: next)
    }

    /// Runs `prompt` in a task of the channel: a submitted line is answered
    /// first (a remote command, a reply to a pending question, `/plan`
    /// `/goal` `/review`), and what remains runs as a turn through the host.
    /// The next queued prompt starts when it ends.
    private func startTurnTask(for prompt: ChatQueuedPrompt<TerminalTelegramRouteLease>) {
        activeTurnTask = Task(name: "ZenCODE.Telegram.channel-turn") { [weak self] in
            guard let self else { return }
            await self.runQueuedPrompt(prompt)
            self.activeTurnTask = nil
            self.startNextQueuedPromptIfNeeded()
        }
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
    /// the busy text) or gone (nothing is said).
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
        guard let host else { return }
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
            // A failed or cancelled turn was presented as its ending.
        }
    }

    /// Stops the turn in progress, as the stop button of a streamed draft
    /// asks: the host fences the controller's turn, the runner cancels the
    /// prompt, and the channel's task, if the turn is its own, is cancelled.
    func stopActiveTurn() async {
        guard let host else { return }
        let sessionID = sessionID
        host.cancelPrompt(in: slotID)
        activeTurnTask?.cancel()
        await sessionRunner.cancelPrompt(sessionID: sessionID)
    }

    // MARK: - Turn boundaries

    /// Starts following the turn that starts now, or moved onto the channel
    /// now, on the route of the message that started it
    /// (``nextTurnLease``) or the link's route.
    ///
    /// The reporter of the previous turn is revoked, the root-response state
    /// and the task-graph dedup are reset, the turn gets a reporter and the
    /// typing presence, and a turn on a route lease is stopped when that
    /// route is revoked, rebound, or closed. A turn that moved onto the
    /// channel with a block already streaming (`adoptingStreamingBlock`)
    /// suppresses the rest of that block: the handover sent what streamed so
    /// far as context, and the chat must not receive the suffix alone.
    func beginTurn(adoptingStreamingBlock: Bool) async {
        let lease = nextTurnLease ?? activeRouteLease
        let previousValidationTask = routeValidationTask
        routeValidationTask = nil
        previousValidationTask?.cancel()
        await previousValidationTask?.value
        await activeProgressReporter?.revokeAndWait()
        activeProgressReporter = nil
        activeTurnLease = lease
        resetRootResponseBlock()
        if adoptingStreamingBlock {
            rootResponseBlockHasContent = true
            rootResponseBlockIsSuppressed = true
        }
        publishedTaskGraphOverviewSignature = nil
        await synchronizeTurnReporting()
        await beginTurnPresenceIfNeeded()
        if let lease, host != nil {
            routeValidationTask = makeRouteValidationTask(lease: lease)
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
    func finishTurn(ending: ChatTurnEnding) async {
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
        await retireTurn(outcomePayload: outcomePayload, fileChangeSummary: ending.fileChangeSummary)
    }

    /// Retires the turn's Telegram side after its final response, sending
    /// `outcomePayload` as the turn's outcome and the file-change summary;
    /// without a payload only the summary, if any, is sent.
    func retireTurn(
        outcomePayload: TerminalTelegramTurnPayload?,
        fileChangeSummary: TurnFileChangeSummary?
    ) async {
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
    /// route validation, revokes the reporter, releases the typing presence,
    /// and forgets the turn's route and root-response state.
    func endTurnReporting() async {
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
        resetRootResponseBlock()
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

    /// Publishes the aggregated root response at a tool-call boundary.
    ///
    /// The boundary proves the response complete: the model stopped writing
    /// and started a tool.
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

    // MARK: - Overviews

    /// Queues an overview section the controller published for the turn in
    /// progress: a task graph (`.tasks`) or a sub-agent response
    /// (`.subAgentResponse`).
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
    /// send is fenced by the route lease and the lifecycle epoch, and
    /// validated again before it leaves.
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
