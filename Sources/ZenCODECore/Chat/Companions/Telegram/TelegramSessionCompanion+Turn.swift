//
//  TelegramSessionCompanion+Turn.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The Telegram side of the turn in progress: its origin, the ordered
/// reporter that mirrors it to the linked chat, the typing presence, and the
/// task that stops it when its route is revoked.
///
/// The primary channel drives the turn's boundaries: it calls
/// ``TelegramSessionCompanion/beginTurn(origin:mirrorEpoch:)`` before the
/// turn runs and ``TelegramSessionCompanion/finishTurn(outcome:fileChangeSummary:)``
/// once its final response is presented. Between the two, the companion's
/// ``TelegramCompanionPresenter`` receives the turn's output from the
/// controller and buffers the root response, which is published at each tool
/// boundary, and the channel hands over the overview sections it renders with
/// ``TelegramSessionCompanion/enqueueOverview(_:epoch:taskGraphSignature:)``.
///
/// The mirror epoch fences those sections. A channel that queues them
/// asynchronously, like the terminal's render coordinator, tags each one with
/// the epoch it was queued under, advances its own epoch at every turn
/// boundary, and passes the new value to `beginTurn`, which makes it the
/// companion's ``TelegramSessionCompanion/currentMirrorEpoch``. The two epochs
/// are then the same value by construction, and the channel passes the tag of
/// a section unchanged to `enqueueOverview`: a section queued during a turn
/// that ended is discarded instead of being adopted by the next one. A
/// channel without such a queue omits the epoch, and the companion advances
/// its own.
extension TelegramSessionCompanion {
    /// How the turn ended, as the primary channel presented it.
    enum Outcome: Sendable, Equatable {
        /// The turn completed with this final response text. An empty text
        /// is mirrored as `Done.`, as the terminal presents it.
        case completed(String)
        /// The turn failed with this operator-facing message.
        case failed(String)
        /// The operator stopped the turn.
        case cancelled
    }

    // MARK: - Turn boundaries

    /// The origin a turn of `origin` is mirrored on. While the link is
    /// active, a turn of the primary channel uses the validated route lease of
    /// the link, as the terminal's `promptAttempt` promotes a local prompt,
    /// so the session keeps answering on Telegram after `/telegram on` without
    /// waiting for a Telegram message. Any other origin is returned as it is.
    func routedOrigin(for origin: TelegramTurnOrigin) -> TelegramTurnOrigin {
        guard origin == .primary,
              controlState.isActive,
              let lease = activeRouteLease else {
            return origin
        }
        return .telegram(lease)
    }

    /// Starts following a turn of `origin`, even while Telegram is detached.
    ///
    /// The turn's origin (see ``routedOrigin(for:)``) is kept for the whole
    /// turn, so an ``attach()`` in the middle of it moves it onto the route
    /// and mirrors the rest. The reporter of the previous turn is revoked,
    /// the root-response state and the task-graph dedup are reset, and the
    /// mirror epoch becomes `mirrorEpoch`, or advances by one without it (see
    /// the extension's documentation). A turn that reaches the linked chat
    /// gets a reporter and the typing presence; a turn on a route lease is
    /// stopped when that route is revoked, rebound, or closed (the companion
    /// calls ``TelegramCompanionChannel/telegramRouteWasInvalidated(_:)``).
    ///
    /// A `nil` origin is a turn the companion follows without an origin, as
    /// the terminal follows a turn whose origin carries no validated lease
    /// (see ``TelegramTurnOrigin``): the previous turn's reporter is still
    /// revoked, the root-response state, the task-graph dedup, and the
    /// mirror epoch still start over, but the turn reaches no chat, so it
    /// gets no reporter, no typing presence, and no route validation, and an
    /// ``attach()`` in the middle of it does not adopt it.
    func beginTurn(origin: TelegramTurnOrigin?, mirrorEpoch: Int? = nil) async {
        let origin = origin.map(routedOrigin(for:))
        let previousValidationTask = routeValidationTask
        routeValidationTask = nil
        previousValidationTask?.cancel()
        await previousValidationTask?.value
        await activeProgressReporter?.revokeAndWait()
        activeProgressReporter = nil
        activeTurnOrigin = origin
        resetRootResponseBlock()
        mirroredTaskGraphOverviewSignature = nil
        // Fence off any undelivered overview of the previous turn before the
        // new turn's reporter exists: stale-epoch deliveries are discarded
        // instead of being adopted by the new reporter.
        currentMirrorEpoch = mirrorEpoch ?? (currentMirrorEpoch &+ 1)
        await synchronizeTurnReporting()
        await beginTurnPresenceIfNeeded()
        if let lease = origin?.lease, channel != nil {
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
    /// could not see, nor a replay of text produced while it was detached.
    func synchronizeTurnReporting() async {
        guard let origin = activeTurnOrigin,
              let chatID = outgoingChatID(for: origin) else {
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
        activeProgressReporter = makeTurnProgressReporter(for: origin)
    }

    /// Retires the turn's Telegram side after its final response.
    ///
    /// Waits for the overview sections the channel already queued
    /// (``TelegramCompanionChannel/overviewMirrorBarrier()``), drops the
    /// trailing root response that no tool call closed (it is the final
    /// response, mirrored once here as `outcome`), queues the outcome and the
    /// file-change summary, flushes the reporter so they are delivered, and
    /// ends the turn's reporting. Without a reporter the outcome and the
    /// summary are sent to the linked chat directly. Without an outcome, as
    /// when the channel tears its loop down while a turn runs, only the
    /// summary, if any, is sent.
    ///
    /// The texts are the terminal's: `*ZenCODE completed*` and the final
    /// response cut to 3 600 characters (only the text since the last tool
    /// boundary once an intermediate response was published), `Stopped.`,
    /// `ZenCODE failed: <message>`, and the summary of
    /// ``TurnFileChangeSummaryPresentation/text(_:includesCommandHint:)``.
    func finishTurn(
        outcome: Outcome? = nil,
        fileChangeSummary: TurnFileChangeSummary? = nil
    ) async {
        let outcomePayload: TerminalTelegramTurnPayload?
        switch outcome {
        case let .completed(text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let completionText = trimmed.isEmpty ? "Done." : trimmed
            let mirroredText = await mirroredFinalResponseText(fallback: completionText)
            outcomePayload = .agentResponse(
                "*ZenCODE completed*\n\n\(String(mirroredText.prefix(3_600)))"
            )
        case let .failed(message):
            outcomePayload = .agentResponse("ZenCODE failed: \(message)")
        case .cancelled:
            outcomePayload = .agentResponse("Stopped.")
        case nil:
            outcomePayload = nil
        }
        await retireTurn(outcomePayload: outcomePayload, fileChangeSummary: fileChangeSummary)
    }

    /// Retires the turn's Telegram side after its final response, mirroring
    /// `outcomePayload` as the turn's outcome: what
    /// ``finishTurn(outcome:fileChangeSummary:)`` does once it has built the
    /// outcome's payload, for a channel that already holds the payload. The
    /// barrier, the file-change summary, the reporter's flush, the direct
    /// delivery without a reporter, and the end of the turn's reporting are
    /// the same; without a payload only the summary, if any, is sent.
    func retireTurn(
        outcomePayload: TerminalTelegramTurnPayload?,
        fileChangeSummary: TurnFileChangeSummary?
    ) async {
        await channel?.overviewMirrorBarrier()
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
            // response: dropping it here keeps the outcome from being
            // mirrored twice.
            await reporter.discardPendingAgentResponse()
            if let outcomePayload {
                await reporter.enqueue(outcomePayload)
            }
            if let summaryPayload {
                await reporter.enqueue(summaryPayload)
            }
            await reporter.flush()
            await reporter.retire()
        } else if let origin = activeTurnOrigin {
            if let outcomePayload {
                await sendTurnMessageIfLinked(outcomePayload, origin: origin)
            }
            if let summaryPayload {
                await sendTurnMessageIfLinked(summaryPayload, origin: origin)
            }
        }
        await endTurnReporting()
    }

    /// Ends the turn's reporting without mirroring anything more: stops the
    /// route validation, revokes the reporter, releases the typing presence,
    /// and forgets the turn's origin and root-response state.
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
        activeTurnOrigin = nil
        resetRootResponseBlock()
    }

    // MARK: - Route invalidation

    /// The companion's part of a route revoked, rebound, or closed while the
    /// turn that came from it was generating.
    ///
    /// The companion reports the invalidation with
    /// ``TelegramCompanionChannel/telegramRouteWasInvalidated(_:)``. The
    /// channel ignores it unless the turn in progress is still the one on
    /// `lease` (`activeTurnOrigin?.lease == lease`), as the terminal does;
    /// otherwise it stops that turn and then calls this method, which ends the
    /// turn's reporting, tears down the route's runtime state and its pending
    /// command replies, and, when `lease` is the link's active route, forgets
    /// it and unbinds the shared-chat relay. Calling it again changes nothing.
    func routeWasInvalidated(_ lease: TerminalTelegramRouteLease) async {
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
    /// first failed validation to the channel. The task holds the companion
    /// weakly and ends once the companion is gone.
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

    /// Tells the channel that `lease` is no longer valid, unless the turn's
    /// validation was stopped meanwhile. The finishing task is forgotten
    /// first, so the channel can end the turn's reporting from within the
    /// call without waiting for the task that is calling it.
    private func reportInvalidatedRoute(_ lease: TerminalTelegramRouteLease) async {
        // Every path that replaces or stops the validation task cancels it
        // synchronously, so a task that is not cancelled is still the
        // current one.
        guard !Task.isCancelled else { return }
        routeValidationTask = nil
        await channel?.telegramRouteWasInvalidated(lease)
    }

    // MARK: - Root response mirroring

    /// Aggregates one visible root-response delta for the linked chat.
    ///
    /// The reporter buffers the deltas and publishes them as one message at
    /// the next tool boundary; nothing is sent while the response streams.
    /// The block's state is tracked even without a reporter, so a response
    /// that streams across a detach and an attach is recognized.
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
    /// and started a tool. The channel's overview barrier runs first, so the
    /// sub-agent and task sections it already rendered enter the ordered
    /// channel ahead of this response instead of being overtaken by it.
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
        await channel?.overviewMirrorBarrier()
        guard let current = activeProgressReporter,
              current === reporter else {
            // Telegram was detached while the barrier waited: the buffered
            // text belongs to a reporter that no longer exists.
            return
        }
        if await current.publishPendingAgentResponseAtBoundary() {
            didPublishIntermediateRootResponse = true
        }
    }

    /// The text to mirror as the turn's final response.
    ///
    /// A turn's response text accumulates every assistant block it produced,
    /// the intermediate responses already published at their tool boundaries
    /// included. Once one was published, the trailing block aggregated since
    /// the last boundary, the final response itself, is mirrored instead.
    func mirroredFinalResponseText(fallback: String) async -> String {
        guard didPublishIntermediateRootResponse,
              let reporter = activeProgressReporter else {
            return fallback
        }
        let trailing = await reporter.pendingAgentResponseText()
        return trailing.isEmpty ? fallback : trailing
    }

    /// Marks the streaming root response as unmirrorable, when one is in
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

    /// Queues an overview section the primary channel rendered for the turn
    /// in progress: a task graph (`.tasks`) or a sub-agent response
    /// (`.subAgentResponse`), built by the channel as the terminal builds it.
    ///
    /// The section is dropped when `epoch` is not the turn's
    /// ``currentMirrorEpoch`` (it was queued during a turn that ended) or
    /// when no reporter mirrors the turn: outside a mirrored turn there is no
    /// remote audience. A task graph whose `taskGraphSignature` was already
    /// mirrored during the turn is dropped too, so republished identical
    /// content does not repeat in the chat. Sections go through the
    /// reporter's queue, so they cannot overtake the tool activity that
    /// produced them.
    func enqueueOverview(
        _ payload: TerminalTelegramTurnPayload,
        epoch: Int,
        taskGraphSignature: String? = nil
    ) async {
        guard epoch == currentMirrorEpoch,
              activeProgressReporter != nil else {
            return
        }
        if let taskGraphSignature {
            guard mirroredTaskGraphOverviewSignature != taskGraphSignature else {
                return
            }
            mirroredTaskGraphOverviewSignature = taskGraphSignature
        }
        await activeProgressReporter?.enqueue(payload)
    }

    // MARK: - Reporter and presence

    /// The ordered reporter of a turn of `origin`, or `nil` when the turn
    /// does not reach the linked chat or the link has no wire lifecycle.
    ///
    /// Every send is fenced by the route lease and the lifecycle epoch, and
    /// validated again before it leaves. Under ``Policy/mirrorOnly`` the
    /// streamed drafts carry no stop button (`canStop: false`): the operator
    /// cannot stop a turn from Telegram.
    func makeTurnProgressReporter(
        for origin: TelegramTurnOrigin
    ) -> TerminalTelegramTurnProgressReporter? {
        guard let lease = origin.lease,
              let chatID = outgoingChatID(for: origin),
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
        let canStop = configuration.policy != .mirrorOnly
        let cards = TerminalTelegramProgressCardLedger(
            chatID: chatID,
            send: { [weak self] text, chatID in
                guard let self, await self.validateOrigin(origin) else {
                    throw CancellationError()
                }
                return try await service.sendPlainMessageWithReceipt(
                    text, to: chatID, topicID: topicID, fence: wireFence
                )
            },
            editText: { [weak self] text, chatID, messageID in
                guard let self, await self.validateOrigin(origin) else {
                    throw CancellationError()
                }
                try await service.editMessageText(
                    text, chatID: chatID, messageID: messageID, fence: wireFence
                )
            },
            editMarkup: { [weak self] markup, chatID, messageID in
                guard let self, await self.validateOrigin(origin) else {
                    throw CancellationError()
                }
                try await service.editMessageReplyMarkup(
                    markup, chatID: chatID, messageID: messageID, fence: wireFence
                )
            },
            delete: { [weak self] chatID, messageID in
                guard let self, await self.validateOrigin(origin) else {
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
                guard let self, await self.validateOrigin(origin) else { return false }
                return await self.sendProgressMessage(
                    message, to: chatID, topicID: topicID, fence: wireFence
                )
            },
            sendDraft: { [weak self] text, chatID, draftID in
                guard let self, await self.validateOrigin(origin) else {
                    throw CancellationError()
                }
                try await service.sendRichMessageDraftWithFallback(
                    text, to: chatID, draftID: draftID, canStop: canStop, fence: wireFence
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

    /// Takes the lifecycle-safe typing lease for a mirrored turn. Presence
    /// is best-effort: a chat action that fails says nothing about the link
    /// or the turn, so failures are silent. The lease is released by
    /// ``endTurnReporting()`` and fenced by generation, so a renewal that
    /// wakes after teardown exits without touching the wire.
    private func beginTurnPresenceIfNeeded() async {
        guard let origin = activeTurnOrigin,
              await validateOrigin(origin),
              let chatID = outgoingChatID(for: origin),
              let fence = wireFence(for: origin) else {
            return
        }
        activePresenceLease = await controlService.acquirePresenceLease(
            scope: .turn(
                chatID: chatID,
                topicID: origin.lease?.effectiveMessageThreadID
            ),
            fence: fence
        )
    }
}
