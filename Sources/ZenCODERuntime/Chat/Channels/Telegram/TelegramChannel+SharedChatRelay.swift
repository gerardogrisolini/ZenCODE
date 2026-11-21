//
//  TelegramChannel+SharedChatRelay.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The live shared chat while Telegram drives the slot: the channel observes
/// the session's room itself, forwards the operator-directed messages to the
/// linked chat as cards, delivers Telegram replies to a card back to their
/// sender, publishes live `@mention` messages sent from Telegram as the
/// terminal publishes the operator's own, and runs the coordinator turns the
/// room asks for (the Core's auto-triggers) as hidden turns of the channel.
extension TelegramChannel {
    // MARK: - Relay

    /// Forwards operator-directed shared-chat messages to the linked chat
    /// and resolves Telegram replies back to their sender. Created on first
    /// use and owned for the channel's whole lifetime, so its ledger
    /// survives ``detach()`` → ``attach()``.
    var sharedChatRelay: TerminalTelegramSharedChatRelay {
        if let relay = sharedChatRelayStorage {
            return relay
        }
        let relay = TerminalTelegramSharedChatRelay(
            validateLease: { [weak self] lease in
                guard let self else { return false }
                return (try? await self.router.validate(lease)) != nil
            },
            send: { [weak self] text, chatID, lease in
                await self?.sendSharedChatCard(text, to: chatID, lease: lease) ?? nil
            }
        )
        sharedChatRelayStorage = relay
        return relay
    }

    // MARK: - Observation

    /// Observes the session's shared-chat room while the channel drives the
    /// slot: the room's messages reach the relay, and its auto-triggers run
    /// as hidden turns of the channel when the session is free. The
    /// observation follows the slot's incarnation: a new session rebinds it
    /// to the new room (see ``rebindSharedChatObservationIfNeeded()``).
    /// Starting it again while it runs does nothing. The channel's busy state
    /// is declared on the observation before its first event is handled, and
    /// the relay is bound to the room (when the link has a route that serves
    /// it, the shared one included) before the first event is forwarded, so
    /// what the room says from then on reaches the chat as soon as the channel
    /// drives the slot, without waiting for a message from Telegram.
    ///
    /// Only new messages are forwarded. The room's messages are read before
    /// the observation attaches, and marked as handled in the relay once it is
    /// bound and before the first event is handled: the observer's replay of
    /// the retained transcript, and every poll, read the room after that
    /// snapshot, so each message they offer is either in it (and skipped) or
    /// newer than it (and forwarded). The marks are written even when the
    /// relay was bound already (by a Telegram message read first), which is
    /// safe because nothing is forwarded for this observation before them.
    func startSharedChatObservation() {
        guard sharedChatObservationTask == nil else { return }
        let roomID = sessionID
        observedSharedChatRoomID = roomID
        sharedChatObservationTask = Task(name: "ZenCODE.Telegram.shared-chat-events") { [weak self] in
            guard let self else { return }
            let presentMessageIDs = await self.presentSharedChatMessageIDs(roomID: roomID)
            let observation = await sessionRunner.attachSharedChatObservation(rootSessionID: roomID)
            self.sharedChatObservation = observation
            await self.synchronizeSharedChatConsumerBusyState()
            if !Task.isCancelled {
                await self.bindSharedChatRelayForObservation(
                    roomID: roomID, presentMessageIDs: presentMessageIDs
                )
            }
            for await event in observation.events {
                guard !Task.isCancelled else { break }
                await self.handleSharedChatEvent(event, roomID: roomID, observation: observation)
            }
            await sessionRunner.detachSharedChatObservation(observation)
            if self.sharedChatObservation?.id == observation.id {
                self.sharedChatObservation = nil
            }
        }
    }

    /// Ends the observation of the room, releasing the observer's claim.
    func stopSharedChatObservation() async {
        guard let task = sharedChatObservationTask else { return }
        sharedChatObservationTask = nil
        task.cancel()
        await task.value
        if let observation = sharedChatObservation {
            sharedChatObservation = nil
            await sessionRunner.detachSharedChatObservation(observation)
        }
        observedSharedChatRoomID = nil
    }

    /// Moves the observation to the room of the session the slot runs now,
    /// when it changed (`/sessions new`, `/sessions load`), and rebinds the
    /// relay to it. Nothing happens while the channel does not drive the
    /// slot.
    func rebindSharedChatObservationIfNeeded() async {
        guard drivesSlot, sharedChatObservationTask != nil else { return }
        let roomID = sessionID
        guard observedSharedChatRoomID != roomID else { return }
        await stopSharedChatObservation()
        await rebindSharedChatRelay(roomID: roomID)
        startSharedChatObservation()
    }

    private func handleSharedChatEvent(
        _ event: AgentSharedChatCoordinatorEvent,
        roomID: String,
        observation: AgentSharedChatCoordinator.Observation
    ) async {
        switch event {
        case let .messages(messages):
            await forwardSharedChatMessages(messages, roomID: roomID)
        case .participantsChanged:
            break
        case let .autoTrigger(trigger):
            guard trigger.roomID == roomID, roomID == sessionID, drivesSlot else {
                await sessionRunner.declineSharedChatAutoTrigger(
                    id: trigger.id, rootSessionID: trigger.roomID
                )
                return
            }
            // The route is resolved first: without one the turn has nowhere
            // to answer, and the channel counts as busy until a route is back
            // (``synchronizeSharedChatConsumerBusyState()``).
            let hasLease = sharedChatLease(for: trigger.messages) != nil || activeRouteLease != nil
            guard !isSessionGenerating, activeTurnTask == nil, promptQueue.isEmpty, hasLease else {
                // Busy: the channel's own activity is declared before the
                // decline, so the requeued batch is not offered straight back
                // while a task or a queued prompt of the channel waits, or
                // while the channel has no route. The Core offers it again
                // once the channel declares itself idle at the end of its task
                // (``turnTaskDidEnd()``) or once a route is back, or once the
                // session's turn ends.
                await synchronizeSharedChatConsumerBusyState()
                await sessionRunner.declineSharedChatAutoTrigger(
                    id: trigger.id, rootSessionID: trigger.roomID
                )
                return
            }
            let claim = await sessionRunner.resolveSharedChatAutoTrigger(
                id: trigger.id, observation: observation, resolution: .started
            )
            guard claim == .acquired else { return }
            guard let lease = takeSharedChatLease(for: trigger.messages) ?? activeRouteLease else {
                // The route went away while the claim was resolved: the
                // channel declares itself busy, then gives its claim back,
                // which requeues the batch without offering it again until a
                // route is back.
                await synchronizeSharedChatConsumerBusyState()
                _ = await sessionRunner.resolveSharedChatAutoTrigger(
                    id: trigger.id, observation: observation, resolution: .declined
                )
                return
            }
            activeTurnTask = Task(name: "ZenCODE.Telegram.shared-chat-turn") { [weak self] in
                guard let self else { return }
                await self.synchronizeSharedChatConsumerBusyState()
                await self.runTurn(prompt: trigger.prompt, lease: lease, isUserVisible: false)
                await self.turnTaskDidEnd()
            }
        }
    }

    /// Declares the channel's own activity to the Core's auto-trigger, as the
    /// terminal does: a task of the channel (a line being answered, a turn, a
    /// coordinator turn) or a prompt in its queue keeps the channel's
    /// observation busy, so a shared-chat message waits for the channel to be
    /// free instead of racing its work; so does a link without a route
    /// (``activeRouteLease``, `nil` after the route was revoked, rebound, or
    /// closed), on which a coordinator turn could not answer, until a route is
    /// back (``activeRouteLeaseDidChange(hadLease:)``). Otherwise the
    /// observation is idle, and the Core offers again what waits. The
    /// declaration is scoped to the channel's observation: another consumer
    /// of the room can never clear it, and it ends with the observation
    /// (`/telegram off`). Called at every start and end of a task of the
    /// channel and of its queue, and when the route comes or goes; nothing
    /// happens while the channel observes no room.
    func synchronizeSharedChatConsumerBusyState() async {
        guard let observation = sharedChatObservation else { return }
        await sessionRunner.setSharedChatConsumerBusy(
            activeTurnTask != nil || !promptQueue.isEmpty || activeRouteLease == nil,
            observation: observation
        )
    }

    /// Tells the shared chat whether the channel is busy once the link's
    /// route came (`hadLease` is `false`) or went (`true`): a channel without
    /// a route counts as busy. Nothing happens when it did not change.
    func activeRouteLeaseDidChange(hadLease: Bool) async {
        guard hadLease != (activeRouteLease != nil) else { return }
        await synchronizeSharedChatConsumerBusyState()
    }

    // MARK: - Live-message relay

    /// Reports whether `text` is already claimed by a higher-precedence route, in
    /// which case quoting a card must not change its meaning.
    ///
    /// The decision uses the real parsers: ``CoordinatorCommandParser`` for
    /// slash commands (every remote command's canonical form is a slash line)
    /// and the actual ``SharedChatMentionParser/parse(from:readableHandles:)``
    /// outcome for mentions — including `missingText`, which is a recognised
    /// mention whose diagnostic must not be replaced by a reply. Plain-word
    /// command aliases ("status", "diff", ...) do not take precedence: quoting
    /// a card and answering "diff" is an answer to its sender, as in the
    /// terminal. A leading `@` that resolves to nothing is not a mention, so
    /// it does not suppress the reply route.
    func replyRoutingHasPrecedence(over text: String) async -> Bool {
        if CoordinatorCommandParser.isSlashCommand(text) {
            return true
        }
        switch SharedChatMentionParser.parse(
            from: text,
            readableHandles: await sessionRunner.sharedChatMentionHandles(
                rootSessionID: sessionID
            )
        ) {
        case .route, .missingText:
            return true
        case .none:
            return false
        }
    }

    /// Offers one shared-chat observer batch to the Telegram relay, which
    /// owns its own delivery ledger.
    func forwardSharedChatMessages(
        _ messages: [AgentSharedChat.Message],
        roomID: String
    ) async {
        guard controlState.isActive,
              activeRouteLease != nil || linkedChatID != nil else {
            return
        }
        let roster = await sessionRunner.sharedChatMentionRoster(rootSessionID: roomID)
        await sharedChatRelay.forward(
            messages,
            roomID: roomID,
            participants: roster.participants
        )
    }

    /// Follows a room swap (`/sessions new`, `/sessions load`). A new room
    /// invalidates the ledger and the receipt map: identifiers of a retired
    /// room must never route a reply into the live one. Cards invite a reply
    /// only while ``readsIngress`` is `true`. What the new room already holds
    /// is not forwarded (see ``activateSharedChatRelay(roomID:lease:presentMessageIDs:)``).
    func rebindSharedChatRelay(roomID: String) async {
        guard let lease = await sharedChatRelayLease(roomID: roomID) else {
            // A room swap or invalidated lease retires every command receipt
            // associated with this session before a new route can be bound.
            commandReplyBindings.removeAll()
            await sharedChatRelay.deactivate()
            return
        }
        await activateSharedChatRelay(roomID: roomID, lease: lease)
    }

    /// The link's route for the relay of `roomID`: `nil` unless the link is
    /// active and its route is valid and serves the room (the room's own
    /// route, or the one every session shares, `default`).
    private func sharedChatRelayLease(roomID: String) async -> TerminalTelegramRouteLease? {
        guard controlState.isActive,
              let lease = activeRouteLease,
              lease.key.admits(roomID: roomID),
              (try? await router.validate(lease)) != nil else {
            return nil
        }
        return lease
    }

    /// Binds the relay of a starting observation to `roomID` on the link's
    /// route, touching nothing when there is none, and marks
    /// `presentMessageIDs`, read before the observation attached, as handled
    /// (see ``startSharedChatObservation()``).
    private func bindSharedChatRelayForObservation(
        roomID: String,
        presentMessageIDs: [UUID]
    ) async {
        guard let lease = await sharedChatRelayLease(roomID: roomID),
              let activation = await activateSharedChatRelay(
                  roomID: roomID, lease: lease, presentMessageIDs: presentMessageIDs
              ),
              !activation.startedForwarding else {
            // Unbound, or the activation wrote the marks itself.
            return
        }
        await sharedChatRelay.markPresent(
            presentMessageIDs, roomID: roomID, generation: activation.generation
        )
    }

    /// Binds the relay to `roomID` on `lease`: every binding the channel makes
    /// goes through here (observation start, room swap, a message from
    /// Telegram), so the relay forwards only what a room says after it
    /// started forwarding it.
    ///
    /// When the relay does not forward the room to the lease's chat yet, the
    /// room's present messages (`presentMessageIDs`, or read here when `nil`)
    /// are marked by the activation itself, atomically with the binding,
    /// because an observation may already be offering batches concurrently. A
    /// new lease of the pair the relay already forwards (a route refresh)
    /// reads and marks nothing, so a new message a running observation has
    /// still to offer arrives. Returns the activation, `nil` when the relay
    /// refused the lease.
    @discardableResult
    func activateSharedChatRelay(
        roomID: String,
        lease: TerminalTelegramRouteLease,
        presentMessageIDs knownPresentMessageIDs: [UUID]? = nil
    ) async -> TerminalTelegramSharedChatRelay.Activation? {
        let relay = sharedChatRelay
        let chatID = lease.key.chatID
        let repliesEnabled = readsIngress
        var presentMessageIDs = knownPresentMessageIDs
        if presentMessageIDs == nil {
            let alreadyForwarding = await relay.forwards(roomID: roomID, chatID: chatID)
            if !alreadyForwarding {
                presentMessageIDs = await presentSharedChatMessageIDs(roomID: roomID)
            }
        }
        let activation = await relay.activate(
            roomID: roomID,
            chatID: chatID,
            lease: lease,
            repliesEnabled: repliesEnabled,
            presentMessageIDs: presentMessageIDs ?? []
        )
        if let activation, activation.startedForwarding, presentMessageIDs == nil {
            // The relay was unbound between the check and the activation, so
            // nothing was read: the room's messages are read and marked now.
            let lateMessageIDs = await presentSharedChatMessageIDs(roomID: roomID)
            await relay.markPresent(
                lateMessageIDs, roomID: roomID, generation: activation.generation
            )
        }
        return activation
    }

    /// The identities of the messages `roomID` holds now, read from the very
    /// source the coordinator replays to a new observer (`allRoomMessages`,
    /// the room's bounded transcript, with the same room-id normalization).
    ///
    /// Every message the bus accepts enters that transcript, the ones drained
    /// into the coordinator's `pending` queue included, so the snapshot also
    /// covers the `pending` messages an observer is sent when it attaches,
    /// with one accepted exception (residual risk): a message still pending
    /// after `AgentSharedChat.maximumRetainedMessagesPerRoom` newer messages
    /// of the room has already left the transcript, so that attach-time
    /// replay can still forward it once. The coordinator offers no public read
    /// of its pending queue.
    private func presentSharedChatMessageIDs(roomID: String) async -> [UUID] {
        await sessionRunner.sharedChatTranscriptMessages(rootSessionID: roomID).map(\.id)
    }

    /// Delivers one relay card as plain text and returns its Telegram receipt.
    ///
    /// A failure is recorded on the control state but never presented on the
    /// primary channel: cards are asynchronous notifications, and a transient
    /// Telegram error must not inject noise into the operator's transcript.
    func sendSharedChatCard(
        _ text: String, to chatID: Int64,
        lease: TerminalTelegramRouteLease
    ) async -> Int? {
        guard controlState.isActive,
              let lifecycleEpoch = controlState.wireLifecycleEpoch else {
            return nil
        }
        guard lease.key.chatID == chatID,
              (try? await router.validate(lease)) != nil else { return nil }
        let fence = TerminalTelegramWireFence(
            lease: lease,
            lifecycleEpoch: lifecycleEpoch,
            validateLease: { [router] lease in
                try await router.validate(lease)
            }
        )
        do {
            return try await controlService.sendPlainMessageWithReceipt(
                text,
                to: chatID,
                topicID: lease.effectiveMessageThreadID,
                fence: fence
            )
        } catch {
            controlState.lastError = TerminalTelegramControlError.operatorDescription(error)
            return nil
        }
    }
}
