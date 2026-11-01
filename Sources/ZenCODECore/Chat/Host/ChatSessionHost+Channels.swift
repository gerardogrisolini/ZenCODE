//
//  ChatSessionHost+Channels.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 02/11/26.
//

import Foundation
import Synchronization
import ToolCore

/// The channel that drives a slot (``ChatSlotChannel``): the handover of a
/// slot to its Telegram channel and back, what a dormant channel may run,
/// the turns the Telegram channel runs through the host, and the ending of
/// a turn presented by whoever drives the slot when it ends.
///
/// `/telegram on` hands the slot to Telegram: the slot's Telegram channel is
/// created on first use and attached, the incarnation receives a reducer when
/// it has none (so the log of what happens from now on exists for the
/// catch-up), the last sequence the primary channel saw is recorded, the
/// chat receives the last entries of the transcript as context, and the
/// slot's presenter and host forward to Telegram from then on; a turn in
/// progress moves with them. `/telegram off` takes it back: the entries the
/// primary channel did not see are its catch-up, the presenter and the host
/// forward to the primary channel again, the requests still open are asked
/// there, and the reducer created for the handover is detached. The Telegram
/// link belongs to the slot: a new or loaded session keeps it.
extension ChatSessionHost {
    // MARK: - Handover

    /// The channel that drives `slotID` now; `.primary` for an unknown slot.
    public func activeChannel(in slotID: ChatSlotID) -> ChatSlotChannel {
        slots[slotID]?.activeChannel ?? .primary
    }

    /// The Telegram channel of `slotID`, once a `/telegram on` created it.
    public func telegramChannel(in slotID: ChatSlotID) -> TelegramChannel? {
        slots[slotID]?.telegramChannel
    }

    /// The working directory of `slotID`; `nil` for an unknown slot.
    func slotWorkingDirectory(_ slotID: ChatSlotID) -> URL? {
        slots[slotID]?.workingDirectory
    }

    /// The Telegram channel of `slotID`, created now when the slot has none,
    /// without attaching it: for a channel that binds the channel before the
    /// first `/telegram on` attaches it (ACP collects the notices of the
    /// attach into its reply), and for a test that drives the channel
    /// directly, as the slot's channel. `nil` for an unknown slot.
    func telegramChannelCreatingIfNeeded(
        in slotID: ChatSlotID,
        primaryChannelDescription: String = "TUI"
    ) -> TelegramChannel? {
        guard let slot = slots[slotID] else { return nil }
        if let channel = slot.telegramChannel {
            return channel
        }
        let channel = makeTelegramChannel(for: slot, primaryChannelDescription: primaryChannelDescription)
        slot.telegramChannel = channel
        return channel
    }

    /// Hands `slotID` to Telegram (`/telegram on`).
    ///
    /// Creates the slot's ``TelegramChannel`` on first use, with the
    /// primary channel named `primaryChannelDescription` in the texts sent
    /// to the chat, and attaches it (a repeated `/telegram on` restarts the
    /// link, as before). Then, when the slot runs a session: the incarnation
    /// gets a reducer if it has none, seeded with the controller's transcript
    /// (or the runtime history when the controller keeps no transcript), the
    /// last sequence of its log is recorded for the catch-up, the chat
    /// receives the last ``TelegramChannel/handoverContextEntryCount``
    /// transcript entries and the block streaming now as context, the slot
    /// switches to Telegram (its open requests are asked again in the chat),
    /// a turn in progress moves onto the channel, and the channel starts
    /// reading the chat.
    ///
    /// Throws what the attach throws (``TelegramChannelAttachError``), and
    /// `.unknownSlot` or `.shutDown` as ``ChatSessionHostError``, leaving the
    /// slot with the primary channel.
    public func activateTelegram(
        in slotID: ChatSlotID,
        primaryChannelDescription: String = "TUI"
    ) async throws {
        guard !isShutDown else { throw ChatSessionHostError.shutDown }
        guard let slot = slots[slotID] else { throw ChatSessionHostError.unknownSlot }
        let channel = slot.telegramChannel ?? makeTelegramChannel(
            for: slot, primaryChannelDescription: primaryChannelDescription
        )
        slot.telegramChannel = channel
        try await channel.attach()
        guard !isShutDown, slots[slotID] === slot, channel.isActive else { return }
        guard slot.activeChannel == .primary else {
            // A repeated `/telegram on`: the link restarted, the handover
            // stands.
            return
        }
        if var incarnation = slot.incarnation {
            let reducer = await ensureReducer(for: &incarnation, in: slot)
            slot.telegramHandoverLastSeenSequence = reducer.snapshot.log.last?.sequence
                ?? reducer.snapshot.firstRetainedSequence - 1
            slot.telegramHandoverEpoch = incarnation.epoch
            await channel.sendHandoverContext(
                transcript: reducer.snapshot.transcript,
                liveAssistantText: slot.slotPresenter.liveAssistantText
            )
        }
        slot.setActiveChannel(.telegram)
        await slot.slotPresenter.presentTurnMoveIfNeeded()
        channel.startDriving()
    }

    /// Takes `slotID` back from Telegram (`/telegram off`) and returns what
    /// the primary channel catches up with, or `nil` when Telegram did not
    /// drive the slot (the link, if any, is stopped all the same, as
    /// `/telegram off` always did).
    ///
    /// The catch-up is read before the switch: the entries with a sequence
    /// greater than the last one the primary channel saw, or the whole log
    /// when the slot runs another incarnation than the one handed over, with
    /// the block streaming now. Then the channel stops reading the chat, the
    /// slot switches back (its open requests are asked again on the primary
    /// channel, a turn in progress moves back), the link is stopped, and the
    /// reducer created for the handover is detached.
    public func deactivateTelegram(in slotID: ChatSlotID) async -> ChatTelegramCatchUp? {
        guard let slot = slots[slotID], let channel = slot.telegramChannel else { return nil }
        guard slot.activeChannel == .telegram else {
            await channel.detach()
            return nil
        }
        let catchUp = telegramCatchUp(of: slot)
        // The switch first: the requests open in the chat are cancelled there
        // and asked again on the primary channel before the channel stops
        // reading the chat and refuses what still waits.
        slot.setActiveChannel(.primary)
        await slot.slotPresenter.presentTurnMoveIfNeeded()
        await channel.stopDriving()
        await channel.detach()
        detachOnDemandReducer(of: slot)
        slot.telegramHandoverLastSeenSequence = nil
        slot.telegramHandoverEpoch = nil
        return catchUp
    }

    /// The `/telegram` status of `slotID`, after reading the control
    /// service's state; the inactive status when no channel exists yet.
    public func telegramStatusText(in slotID: ChatSlotID) async -> String {
        guard let channel = slots[slotID]?.telegramChannel else {
            return TelegramChannel.statusText(
                controlState: .inactive(), linkedChatTitle: nil, topicName: nil
            )
        }
        return await channel.statusText()
    }

    /// Whether the channel that reads `line` may run it on `slotID`: a
    /// dormant primary channel (Telegram drives the slot) runs only the lines
    /// of ``ChatSlotAdmission/isAllowedWhileDormant(_:)`` and answers
    /// ``ChatSlotAdmission/dormantRefusalText`` to every other one. Every
    /// channel asks before it runs a line, so the rule holds for all of them.
    public func admitLine(_ line: String, in slotID: ChatSlotID) -> ChatSlotAdmission {
        guard let slot = slots[slotID], slot.activeChannel == .telegram else { return .admitted }
        return ChatSlotAdmission.isAllowedWhileDormant(line)
            ? .admitted
            : .refused(ChatSlotAdmission.dormantRefusalText)
    }

    // MARK: - Turn endings

    /// Presents `ending`, the end of a turn run on `slotID`, on the channel
    /// that drives the slot now: its presenter when it presents endings
    /// (``ChatSlotChannelPresenter``), else the handler of the descriptor
    /// (``ChatSlotDescriptor/presentTurnEnding``). The channel that ran the
    /// turn calls it instead of presenting the ending itself, because the
    /// turn may have moved to the other channel meanwhile.
    func presentTurnEnding(_ ending: ChatTurnEnding, in slotID: ChatSlotID) async {
        guard let slot = slots[slotID] else { return }
        if await slot.slotPresenter.presentTurnEnding(ending) {
            return
        }
        if slot.activeChannel == .primary, let handler = slot.presentTurnEndingHandler {
            await handler(ending)
        }
    }

    // MARK: - Telegram turns

    /// Runs one turn of the Telegram channel on the session `slotID` runs:
    /// reserves the prompt, composes the request as the primary channel
    /// composes its own turns
    /// (``ChatSessionChannelHooks/turnSessionConfiguration(for:controller:)``),
    /// runs it on the controller, inside the environment the primary channel
    /// gives its own turns
    /// (``ChatSessionChannelHooks/runTurnFromAnotherChannel(controller:_:)``),
    /// with the origin ``ChatTurnOrigin/telegram``
    /// and the consent of the incarnation's authorizer (which asks on the
    /// channel that drives the slot, so an *Always* given in the chat is
    /// recorded there), releases the prompt, and presents the ending on the
    /// channel that drives the slot then. A prompt the operator wrote
    /// (`isUserVisible`) locks the primary channel's response language first,
    /// as the terminal locks it on the first prompt it runs.
    ///
    /// Throws ``ChatSessionHostError`` when the prompt cannot be reserved and
    /// ``ChatTurnFailure`` when the turn fails or is cancelled.
    @discardableResult
    func runTelegramTurn(
        in slotID: ChatSlotID,
        prompt: String,
        attachments: [AgentRuntimeAttachment] = [],
        purpose: ChatTurnPurpose = .normal,
        isUserVisible: Bool = true
    ) async throws -> ChatTurnResult {
        let reservation = try reservePrompt(in: slotID)
        guard let slot = slots[slotID], let incarnation = reservedIncarnation(reservation) else {
            releasePrompt(reservation)
            throw ChatSessionHostError.noSession
        }
        slot.telegramTurnPromptID = reservation.promptID
        defer {
            if slot.telegramTurnPromptID == reservation.promptID {
                slot.telegramTurnPromptID = nil
            }
        }
        let controller = incarnation.controller
        let hooks = slot.channelHooks
        if isUserVisible {
            hooks?.responseLanguageShouldLock()
        }
        let sessionConfiguration: AgentCoreSessionConfiguration
        if let hooks {
            sessionConfiguration = await hooks.turnSessionConfiguration(for: purpose, controller: controller)
        } else {
            sessionConfiguration = await controller.turnSessionConfiguration(
                for: purpose, responseLanguageSection: nil
            )
        }
        guard holdsPrompt(reservation) else {
            throw ChatTurnFailure(underlying: CancellationError(), fileChangeSummary: nil)
        }
        let authorizer = controller.authorizer
        let request = ChatTurnRequest(
            prompt: prompt,
            attachments: attachments,
            purpose: purpose,
            sessionConfiguration: sessionConfiguration,
            authorizeTool: { request in await authorizer.authorize(request) },
            origin: .telegram
        )
        do {
            // The channel that owns the slot's session wraps the turn in its
            // own environment (ACP: the client's file system and the agent's
            // skills), as it does for the turns it starts itself.
            let result: ChatTurnResult
            if let hooks {
                result = try await hooks.runTurnFromAnotherChannel(controller: controller) {
                    // The environment may have suspended: a prompt cancelled
                    // meanwhile has lost its reservation and does not start.
                    guard holdsPrompt(reservation) else {
                        throw ChatTurnFailure(underlying: CancellationError(), fileChangeSummary: nil)
                    }
                    return try await controller.runTurn(request)
                }
            } else {
                result = try await controller.runTurn(request)
            }
            releasePrompt(reservation)
            await presentTurnEnding(ChatTurnEnding(result: result), in: slotID)
            return result
        } catch {
            releasePrompt(reservation)
            await presentTurnEnding(ChatTurnEnding(error: error), in: slotID)
            throw error
        }
    }

    /// Whether the prompt reserved on `slotID` now is a turn of the slot's
    /// Telegram channel, run while the channel drives the slot: for a channel
    /// that must say why the session is busy (an ACP editor whose prompt was
    /// refused). `false` for an unknown slot, an idle session, or a prompt
    /// of another channel.
    func reservedPromptIsTelegramTurn(in slotID: ChatSlotID) -> Bool {
        guard let slot = slots[slotID], slot.activeChannel == .telegram,
              let promptID = slot.telegramTurnPromptID else { return false }
        return slot.incarnation?.activePromptID == promptID
    }

    /// Stops the turn of the Telegram channel of `slotID` that reserved
    /// `promptID`, once ``cancelPrompt(in:armingWorkflowRecovery:)`` dropped
    /// that reservation: the channel cancels its task and the runner's prompt
    /// (``TelegramChannel/stopActiveTurn()``), so the turn ends as a cancelled
    /// one and the chat is told it stopped. Nothing happens when the prompt
    /// was not the channel's.
    func stopTelegramTurnIfReserved(_ promptID: UUID, in slotID: ChatSlotID) async {
        guard let slot = slots[slotID], slot.telegramTurnPromptID == promptID,
              let channel = slot.telegramChannel else { return }
        await channel.stopActiveTurn()
    }

    // MARK: - Reducer on demand

    /// The reducer of `incarnation`, created for the handover when the slot
    /// publishes none: seeded with the controller's transcript, or with the
    /// runtime history when the controller keeps no transcript, and with the
    /// turn in progress (its prompt and the block streaming so far), then
    /// added to the controller as an observer, so it sees the rest of that
    /// turn.
    private func ensureReducer(
        for incarnation: inout ChatSessionIncarnation,
        in slot: ChatSlot
    ) async -> ChatSessionStateReducer {
        if let reducer = incarnation.reducer {
            return reducer
        }
        let controller = incarnation.controller
        let reducer = makeReducer(for: slot, sessionID: incarnation.sessionID, epoch: incarnation.epoch)
        await reducer.presentSessionStateChanged(controller.sessionState)
        let transcript: [AgentRuntimeMessage]
        if controller.retainsTranscript {
            transcript = controller.transcript
        } else {
            transcript = await controller.runtime.snapshotSession(id: incarnation.sessionID)?.history ?? []
        }
        await reducer.presentRestoredLog(ChatTurnEntry.kinds(fromTranscript: transcript))
        if let turn = slot.slotPresenter.movedTurn {
            await reducer.turnWillStart(turn.request)
            await reducer.presentThought(turn.liveThought)
            await reducer.presentAssistantContent(turn.liveAssistantText)
        }
        controller.addObserver(reducer)
        incarnation.reducer = reducer
        if slot.incarnation?.epoch == incarnation.epoch {
            slot.incarnation?.reducer = reducer
        }
        slot.reducerIsOnDemand = true
        return reducer
    }

    /// Detaches the reducer created for the handover, once the catch-up is
    /// read; a reducer the slot publishes stays.
    private func detachOnDemandReducer(of slot: ChatSlot) {
        guard slot.reducerIsOnDemand, var incarnation = slot.incarnation else {
            slot.reducerIsOnDemand = false
            return
        }
        if let reducer = incarnation.reducer {
            incarnation.controller.removeObserver(reducer)
        }
        incarnation.reducer = nil
        slot.incarnation = incarnation
        slot.reducerIsOnDemand = false
    }

    /// What the primary channel catches up with when it takes `slot` back.
    private func telegramCatchUp(of slot: ChatSlot) -> ChatTelegramCatchUp? {
        guard let incarnation = slot.incarnation, let reducer = incarnation.reducer else { return nil }
        let snapshot = reducer.snapshot
        let incarnationChanged = slot.telegramHandoverEpoch != incarnation.epoch
        let lastSeen = incarnationChanged ? nil : slot.telegramHandoverLastSeenSequence
        let entries: [ChatTurnEntry]
        let omittedOlderEntries: Bool
        if let lastSeen {
            entries = snapshot.log.filter { $0.sequence > lastSeen }
            omittedOlderEntries = snapshot.firstRetainedSequence > lastSeen + 1
        } else {
            entries = snapshot.log
            omittedOlderEntries = incarnationChanged
                ? snapshot.firstRetainedSequence > (snapshot.log.first?.sequence ?? snapshot.firstRetainedSequence)
                : false
        }
        return ChatTelegramCatchUp(
            sessionID: incarnation.sessionID,
            entries: entries,
            liveAssistantText: snapshot.turn.liveAssistantText,
            incarnationChanged: incarnationChanged,
            omittedOlderEntries: omittedOlderEntries
        )
    }

    // MARK: - Channel construction

    /// The Telegram channel of `slot`, on the router and dispatcher this host
    /// shares among its slots, with a control service of its own.
    private func makeTelegramChannel(
        for slot: ChatSlot,
        primaryChannelDescription: String
    ) -> TelegramChannel {
        let transportFactory = telegramTransportFactory ?? { NIOTelegramHTTPTransport() }
        return TelegramChannel(
            host: self,
            slotID: slot.id,
            sessionRunner: runner,
            router: telegramRouter(),
            controlService: TerminalTelegramControlService(
                transportFactory: transportFactory,
                dispatcher: telegramDispatcher()
            ),
            primaryChannelDescription: primaryChannelDescription
        )
    }

    // MARK: - Consent routing

    /// Routes the consent requests `authorizer` receives to the slot that
    /// runs the request's session (see
    /// ``ChatToolConsentAuthorizer/setConsentHostResolver(_:)``).
    func installConsentHostResolver(on authorizer: ChatToolConsentAuthorizer) {
        let routes = consentHostRoutes
        authorizer.setConsentHostResolver { request in
            guard let sessionID = request.delegatedIdentity?.rootSessionID ?? request.sessionID else {
                return nil
            }
            return routes.host(for: sessionID)
        }
    }

    /// Records that the session `slot` runs now asks its consent on the
    /// slot's host.
    func registerConsentHost(of slot: ChatSlot) {
        guard let sessionID = slot.incarnation?.sessionID else { return }
        consentHostRoutes.set(slot.slotInteractionHost, for: sessionID)
    }

    /// Forgets the routing of `sessionID`, unless another slot runs it now.
    func unregisterConsentHost(of slot: ChatSlot, sessionID: String) {
        consentHostRoutes.remove(slot.slotInteractionHost, for: sessionID)
    }
}

/// The slot host that answers the consent requests of each session a host
/// runs, by session id: read by the consent authorizers outside
/// ``ChatSessionActor``, so it is kept under a lock.
final class ChatConsentHostRoutes: Sendable {
    private let hosts = Mutex<[String: ChatSlotInteractionHost]>([:])

    func host(for sessionID: String) -> ChatSlotInteractionHost? {
        hosts.withLock { $0[sessionID] }
    }

    func set(_ host: ChatSlotInteractionHost, for sessionID: String) {
        hosts.withLock { $0[sessionID] = host }
    }

    /// Removes the route of `sessionID` when it still points at `host`.
    func remove(_ host: ChatSlotInteractionHost, for sessionID: String) {
        hosts.withLock { hosts in
            guard hosts[sessionID] === host else { return }
            hosts[sessionID] = nil
        }
    }
}

extension ChatSessionHost {
    /// Installs the transport of the Telegram channels this host creates
    /// from now on (see ``telegramTransportFactory``); for tests.
    func setTelegramTransportFactoryForTesting(
        _ factory: (@Sendable () -> any TelegramHTTPTransport)?
    ) {
        telegramTransportFactory = factory
    }
}
