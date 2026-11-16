//
//  TelegramChannel+Lifecycle.swift
//  ZenCODE
//
//  The lifecycle of a Telegram channel: attach, detach, and shutdown, the
//  notices it presents on the primary channel, and the control service's
//  poll-health notices.
//

import Foundation
import ToolCore

extension TelegramChannel {
    // MARK: - Attach

    /// Links the session to Telegram (`/telegram on`).
    ///
    /// Resolves the owner route persisted by setup, records the linked chat,
    /// and starts the control service, which restarts it when the channel
    /// is already attached, exactly as a repeated `/telegram on` does. The
    /// route is the session's topic, reused or created once the service
    /// started, or the route every session shares (see
    /// `TelegramChannel+Topics.swift`). The primary channel is told the link
    /// is active through ``noticeSink``; a created topic is then announced
    /// in General, and a topic that could not be created is reported after
    /// the activation text. On success the channel is registered in
    /// ``registry`` under its bot.
    ///
    /// Throws when the session cannot be linked; the primary channel presents
    /// the error's ``TelegramChannelAttachError/failureText``. When the
    /// service fails to start, the error is recorded as the control state's
    /// `lastError`, and the channel stays registered only if the service
    /// still reports an active link. Whether `/telegram` is available at all
    /// in the channel is the channel's decision, taken before it attaches. An
    /// attach that a later attach, a detach, or a shutdown overtook while it
    /// waited returns without effect: the later operation owns the state.
    public func attach() async throws(TelegramChannelAttachError) {
        lifecycleGeneration &+= 1
        let generation = lifecycleGeneration
        runningAttachCount += 1
        defer { finishRunningAttach() }
        guard let settings = AgentSettingsManifestStore.load()?.telegram,
              let linkedChatID = settings.linkedChatID else {
            throw TelegramChannelAttachError.notPaired
        }
        // Unsupported, ownerless or incoherent settings remain fail-closed
        // until setup creates a complete schema-2 owner route.
        guard let route = await egressRoute(
            settings: settings,
            linkedChatID: linkedChatID
        ) else {
            throw TelegramChannelAttachError.invalidConfiguration
        }
        guard generation == lifecycleGeneration else { return }
        self.linkedChatID = linkedChatID
        linkedChatTitle = settings.linkedChatTitle
        linkedUserID = route.lease.key.userID
        let hadRouteLease = activeRouteLease != nil
        activeRouteLease = route.lease
        sessionTopic = recordedSessionTopic(for: route)
        // A repeated `/telegram on` gives a channel that lost its route one.
        await activeRouteLeaseDidChange(hadLease: hadRouteLease)
        await installPollHealthHandlerIfNeeded()
        let startedState: TerminalTelegramControlState
        do {
            startedState = try await controlService.start()
        } catch {
            guard generation == lifecycleGeneration else { return }
            let description = TerminalTelegramControlError.operatorDescription(error)
            let currentState = await controlService.currentState()
            guard generation == lifecycleGeneration else { return }
            controlState = currentState
            controlState.lastError = description
            synchronizeRegistration()
            await synchronizeTurnReporting()
            // A start that failed before reaching the poller leaves the link
            // that was up still up, and still notified; only a link that is
            // down stops receiving poll-health notices.
            if !controlState.isActive {
                await removePollHealthHandler()
            }
            throw TelegramChannelAttachError.controlFailed(description: description)
        }
        guard generation == lifecycleGeneration else { return }
        controlState = startedState
        // Threaded mode is known, and the wire fenced, only from here on.
        let topicCreation = await createSessionTopicIfNeeded(for: route)
        guard generation == lifecycleGeneration else { return }
        if let topicCreation {
            adoptTopicCreation(topicCreation)
        }
        voiceTranscriptions.resume()
        synchronizeRegistration()
        await synchronizeTurnReporting()
        let chatTitle = linkedChatTitle?.nilIfBlank ?? "chat \(linkedChatID)"
        await presentNotice(
            """
            Telegram remote control is active.
            Linked chat: \(chatTitle)

            """,
            channel: .system
        )
        guard let topicCreation, generation == lifecycleGeneration else { return }
        await announceTopicCreation(topicCreation)
    }

    // MARK: - Detach and shutdown

    /// Unlinks the session (`/telegram off`).
    ///
    /// Stops the turn's Telegram side first, so nothing emitted while the
    /// service stops can reach the chat, then unbinds the shared-chat relay
    /// and stops the service. The relay's ledger is kept, so a later
    /// ``attach()`` resumes it. Every inbound temporary is deleted and every
    /// pending upload consent dropped. The channel leaves ``registry`` and
    /// the primary channel is told the link stopped. Detaching a channel that
    /// is not attached does the same and tells the same. What
    /// ``startDriving()`` started stops first; the queued prompts are
    /// dropped. In topic mode the session's topic route is closed and the
    /// inactive routes pruned once the service stopped
    /// (``closeSessionTopic()``); in legacy mode nothing is written.
    public func detach() async {
        lifecycleGeneration &+= 1
        // Disconnect the current turn before hopping to the service actor, so
        // events emitted while `stop()` is in flight cannot enqueue more output.
        controlState.isActive = false
        synchronizeRegistration()
        await stopDriving(shuttingDown: false)
        await voiceTranscriptions.cancelAllAndWait()
        await endTurnReporting()
        // Unbind before stopping the transport so no card is queued for a chat
        // that is about to be released. The ledger is retained on purpose; a
        // relay never created has nothing bound.
        await sharedChatRelayStorage?.deactivate()
        await removePollHealthHandler()
        controlState = await controlService.stop()
        await closeSessionTopic()
        activeRouteLease = nil
        linkedChatID = nil
        linkedChatTitle = nil
        linkedUserID = nil
        // Deterministic inbound-attachment teardown: every received temporary
        // is deleted and every pending upload consent is dropped.
        _ = await controlService.cleanupInboundAttachments()
        await presentNotice(Self.stoppedNoticeText, channel: .system)
    }

    /// Tears the link down when the slot closes: the turn's Telegram side,
    /// the shared-chat relay, which cannot be used again, and the control
    /// service. Nothing is presented. The channel leaves ``registry``. What
    /// ``startDriving()`` started stops, and with it every voice
    /// transcription for good. In topic mode the session's topic route is
    /// closed and the inactive routes pruned, as ``detach()`` does: the
    /// terminal always ends through here, and a route left active at every
    /// launch would never be pruned.
    public func shutdown() async {
        lifecycleGeneration &+= 1
        controlState.isActive = false
        synchronizeRegistration()
        await stopDriving(shuttingDown: true)
        await endTurnReporting()
        // Quiesce the relay before the transport it uses: its drain worker must
        // not outlive the service it sends through.
        await sharedChatRelayStorage?.shutdown()
        await removePollHealthHandler()
        _ = await controlService.stop()
        await closeSessionTopic()
    }

    /// Ends one ``attach()`` and, after the last one running, releases the
    /// poll-health notices that waited for it.
    private func finishRunningAttach() {
        runningAttachCount -= 1
        guard runningAttachCount == 0 else { return }
        let waiters = attachCompletionWaiters
        attachCompletionWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    /// Registers the channel under its bot while the link is active, and
    /// removes it otherwise.
    private func synchronizeRegistration() {
        if controlState.isActive, let botID = controlState.botID {
            registry.register(self, botID: botID)
        } else {
            registry.unregister(self)
        }
    }

    // MARK: - Notices to the primary channel

    /// Presents `text` on the primary channel through ``noticeSink``.
    func presentNotice(_ text: String, channel: ChatSessionNoticeChannel) async {
        await noticeSink?(text, channel)
    }

    // MARK: - Poll health

    /// Tells the primary channel, once per transition, that Telegram ingress
    /// is dead because of a persistent polling failure, and when it comes
    /// back. Without it the channel would keep saying the link is active
    /// while no message can arrive, and the error would be visible only
    /// through `/telegram`.
    func presentPollHealthNotice(_ notice: TerminalTelegramPollHealthNotice) async {
        guard controlState.isActive else { return }
        let generation = lifecycleGeneration
        let currentState = await controlService.currentState()
        // A lifecycle operation that started meanwhile owns the state.
        guard generation == lifecycleGeneration else { return }
        controlState = currentState
        switch notice {
        case let .failing(text):
            await presentNotice(
                """
                ZenCODE: Telegram is not receiving messages. \(text)
                ZenCODE keeps retrying every minute. Check the bot token with zen --setup, or stop the other process polling this bot. /telegram shows the latest error.

                """,
                channel: .failure
            )
        case .recovered:
            await presentNotice(
                "Telegram polling recovered; messages are being received again.\n",
                channel: .system
            )
        }
    }

    /// Presents `notice` once no ``attach()`` is running, unless the task
    /// that delivers the notices was cancelled meanwhile.
    private func presentPollHealthNoticeAfterAttach(
        _ notice: TerminalTelegramPollHealthNotice
    ) async {
        while runningAttachCount > 0 {
            await withCheckedContinuation { attachCompletionWaiters.append($0) }
        }
        guard !Task.isCancelled else { return }
        await presentPollHealthNotice(notice)
    }

    /// Installs the control service's poll-health handler, unless it is
    /// already installed. The handler runs on the service actor and must not
    /// block, so it only yields the notice to a stream that one task
    /// presents in order.
    private func installPollHealthHandlerIfNeeded() async {
        guard pollHealthTask == nil else { return }
        let (notices, continuation) = AsyncStream.makeStream(
            of: TerminalTelegramPollHealthNotice.self
        )
        pollHealthContinuation = continuation
        pollHealthTask = Task(name: "ZenCODE.Telegram.channel-poll-health") { [weak self] in
            for await notice in notices {
                await self?.presentPollHealthNoticeAfterAttach(notice)
            }
        }
        await controlService.setPollHealthHandler { notice in
            continuation.yield(notice)
        }
    }

    /// Removes the poll-health handler and stops the task that presents its
    /// notices. It does not wait for that task, which may be waiting for the
    /// attach that removes the handler; once cancelled it presents nothing.
    private func removePollHealthHandler() async {
        guard let task = pollHealthTask else { return }
        pollHealthTask = nil
        let continuation = pollHealthContinuation
        pollHealthContinuation = nil
        task.cancel()
        continuation?.finish()
        await controlService.setPollHealthHandler(nil)
    }
}
