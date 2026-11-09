//
//  ZenWindowSession+SharedChat.swift
//  ZenApp
//
//  The shared chat of a window: the reader, the roster and the mentions,
//  the busy state declared for the room, and the answers to its
//  auto-triggers.
//

import Foundation
import ToolCore
import ZenCODECore

extension ZenWindowSession {
    // MARK: - Shared chat

    /// The reader's toggle: from a sub-agent tab it selects the conversation
    /// and opens the reader; on the conversation it opens a closed reader and
    /// closes an open one.
    public func toggleSharedChatReader() {
        guard !isClosed else { return }
        guard selectedTab == .chat else {
            selectTab(.chat)
            updateSharedChat { reader in
                if !reader.isReaderOpen {
                    reader.openReader()
                }
            }
            return
        }
        updateSharedChat { reader in
            if reader.isReaderOpen {
                reader.closeReader()
            } else {
                reader.openReader()
            }
        }
    }

    /// Moves the open reader's selection (``ZenSharedChatReader/navigate(_:)``).
    public func navigateSharedChat(_ action: ZenSharedChatReader.Navigation) {
        guard !isClosed else { return }
        updateSharedChat { $0.navigate(action) }
    }

    /// Reads the roster of the current session's room again, for
    /// ``mentionSuggestions`` and ``sharedChatParticipants``: the composer
    /// calls it when the operator starts completing a leading `@mention`, so
    /// the list never waits for a roster notification. A read still on its way
    /// is cancelled.
    public func refreshMentionSuggestions() {
        guard !isClosed else { return }
        rosterTask?.cancel()
        rosterTask = Task { [weak self] in
            await self?.refreshSharedChatRoster()
        }
    }

    /// Applies `change` to ``sharedChat``, assigned only when it changes, and
    /// keeps ``isSharedChatReaderOpen`` in step with it.
    func updateSharedChat(_ change: (inout ZenSharedChatReader) -> Void) {
        var reader = sharedChat
        change(&reader)
        if reader != sharedChat {
            sharedChat = reader
        }
        if reader.isReaderOpen != isSharedChatReaderOpen {
            isSharedChatReaderOpen = reader.isReaderOpen
        }
    }

    /// A claim of the window is on its way to the Core
    /// (``sharedChatClaimsInFlight``).
    private var isClaimingSharedChatTrigger: Bool {
        sharedChatClaimsInFlight > 0
    }

    /// A claim of the window takes its place on the chain: it counts as on
    /// its way (``sharedChatClaimsInFlight``) from now on, so every
    /// declaration made meanwhile says busy. It declares nothing itself; the
    /// caller enqueues the claim in the same step, before it suspends.
    private func beginSharedChatClaim() {
        sharedChatClaimsInFlight += 1
    }

    /// The window decided what to do with the result of a claim
    /// (``beginSharedChatClaim()``): the claim stops counting. It declares
    /// nothing itself: a give-back that follows enqueues its own declarations
    /// before an idle one could come first, and a line that took the claim
    /// over was declared busy when it started. A claim the window did not
    /// acquire declares the real state right after it ends, since a busy one
    /// may have been declared while the claim was on its way.
    private func endSharedChatClaim() {
        sharedChatClaimsInFlight -= 1
    }

    /// The busy state the window declares for the shared chat: a line runs
    /// or waits, or a claim of the window is on its way. A claim in flight
    /// counts, so a line that starts and ends meanwhile without a Core turn
    /// (a local command, a refused line) cannot declare the window idle
    /// behind the claim: an idle owner releases its claim and the batch with
    /// it. Only the declarations use it; whether a line runs is
    /// ``isLineRunningOrWaiting``.
    private var isSharedChatConsumerBusy: Bool {
        isLineRunningOrWaiting || isClaimingSharedChatTrigger
    }

    /// Declares the window's busy state on its observation, so the Core never
    /// offers a coordinator turn while a line of the window runs or waits, or
    /// while a claim of the window is on its way. Called whenever ``isBusy``,
    /// ``queuedLines``, ``adoptedTelegramPromptID``, or
    /// ``sharedChatClaimsInFlight`` change.
    func sharedChatConsumerStateDidChange() {
        guard !isClosed else { return }
        sharedChatObservation.declareConsumerBusy(isSharedChatConsumerBusy)
    }

    func startSharedChat() {
        sharedChatObservation.handlers = ZenSharedChatObservation.Handlers(
            consumerIsBusy: { [weak self] in
                self?.isSharedChatConsumerBusy ?? false
            },
            didAttach: { [weak self] _ in
                await self?.refreshSharedChatRoster()
            },
            handle: { [weak self] event, observation in
                await self?.handleSharedChatEvent(event, observation: observation)
            },
            mayRecover: { [weak self] roomID in
                await self?.mayRecoverSharedChat(roomID: roomID) ?? false
            }
        )
    }

    /// Observes the room of `incarnation`, its controller's session, while
    /// the slot runs it.
    func followSharedChat(of incarnation: ChatSessionIncarnation) async {
        guard !isClosed else { return }
        let roomID = await ZenSharedChatSteps.roomID(in: sessionHost, slotID: slotID, epoch: incarnation.epoch)
        guard let roomID, !isClosed, current.epoch == incarnation.epoch else { return }
        await sharedChatObservation.follow(roomID: roomID)
    }

    /// Leaves the room of the earlier session at once: its observation is
    /// retired, and the reader, the roster, and the handles start over.
    func resetSharedChat() {
        sharedChatObservation.retire()
        rosterGeneration &+= 1
        updateSharedChat { $0.reset() }
        applyRoster(participants: [], handleMap: [:])
    }

    /// A stream ended on its own: the observation is replaced only while the
    /// window is open and `roomID` is still its current session's room.
    private func mayRecoverSharedChat(roomID: String) async -> Bool {
        guard !isClosed else { return false }
        let currentRoomID = await ZenSharedChatSteps.currentRoomID(in: sessionHost, slotID: slotID)
        return !isClosed && currentRoomID == roomID
    }

    private func handleSharedChatEvent(
        _ event: AgentSharedChatCoordinatorEvent,
        observation: ZenSharedChatObservation.Observation
    ) async {
        switch event {
        case let .messages(messages):
            guard !isClosed, sharedChatObservation.isCurrent(observation) else { return }
            var appended: [AgentSharedChat.Message] = []
            updateSharedChat { appended = $0.append(messages) }
            // Voice mode, when it follows this window, announces the new
            // ones for the operator; the reader deduplicates, so a replay
            // is never new.
            if !appended.isEmpty {
                voiceHost.post(.sharedChatMessages(appended, host: voiceHost))
            }
        case .participantsChanged:
            guard !isClosed, sharedChatObservation.isCurrent(observation) else { return }
            await refreshSharedChatRoster()
        case let .autoTrigger(trigger):
            await answerSharedChatTrigger(trigger, observation: observation)
        }
    }

    /// Reads the participants and the readable handles of the observed room
    /// from one roster snapshot.
    private func refreshSharedChatRoster() async {
        guard !isClosed, let roomID = sharedChatObservation.roomID else { return }
        rosterGeneration &+= 1
        let generation = rosterGeneration
        let roster = await sessionHost.runner.sharedChatMentionRoster(rootSessionID: roomID)
        guard !isClosed, generation == rosterGeneration, sharedChatObservation.roomID == roomID else { return }
        applyRoster(participants: roster.participants, handleMap: roster.handleMap)
    }

    private func applyRoster(participants: [AgentSharedChat.Participant], handleMap: [String: String]) {
        let byID = Dictionary(participants.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        if sharedChatParticipants != byID {
            sharedChatParticipants = byID
        }
        mentionHandles = handleMap
        let suggestions = SharedChatMentionParser.suggestions(for: participants, handleMap: handleMap)
        if mentionSuggestions != suggestions {
            mentionSuggestions = suggestions
        }
    }

    /// Answers an auto-trigger of the Core, the one coordinator turn it
    /// allows at a time for the room's messages to the coordinator. A
    /// trigger of a room the window does not observe now, or reaching a
    /// closed window, goes back to the room ownerless; so does one reaching
    /// a busy window, after the window declared itself busy, so it is not
    /// offered straight back. Otherwise the window claims it and, only when
    /// it acquired it, runs its prompt as a line of the executor
    /// (``runSharedChatTurn(_:roomID:observation:stop:)``). The claim, every
    /// give-back of it, and the decline of a busy window run on the chain of
    /// the busy declarations (``ZenSharedChatObservation/serialized(_:)``).
    /// While the claim is on its way, the window declares itself busy
    /// (``sharedChatClaimsInFlight``), so no idle declaration made meanwhile
    /// can land behind the claim and release it; once the window decided
    /// what to do with the result, its real state is declared again. While
    /// Telegram drives the slot the window neither claims nor declines a
    /// trigger of its room: the slot's Telegram channel observes the room and
    /// claims it, as in the terminal.
    private func answerSharedChatTrigger(
        _ trigger: AgentSharedChatAutoTrigger,
        observation: ZenSharedChatObservation.Observation
    ) async {
        await sharedChatTriggerWillResolve?()
        let runner = sessionHost.runner
        let triggerID = trigger.id
        let triggerRoomID = trigger.roomID
        guard let roomID = await sharedChatRoom(of: trigger, observation: observation) else {
            await runner.declineSharedChatAutoTrigger(id: triggerID, rootSessionID: triggerRoomID)
            return
        }
        guard !isDrivenFromTelegram else { return }
        guard !isLineRunningOrWaiting else {
            // Ownerless on purpose: this may be a re-offered duplicate of a
            // trigger the window claimed, whose turn must not be released.
            // On the chain, it lands after the busy declaration.
            sharedChatObservation.declareConsumerBusy(true)
            await sharedChatObservation.serialized {
                await runner.declineSharedChatAutoTrigger(id: triggerID, rootSessionID: triggerRoomID)
            }
            return
        }
        // Counted before the claim takes its place on the chain, in the same
        // step: every declaration made from now on, the idle one of a line
        // that starts and ends while the claim is on its way included, says
        // busy. On the chain, the claim lands after every declaration made
        // before it, so an idle one on its way cannot land after it and
        // release it.
        beginSharedChatClaim()
        let claim = await resolveSharedChatTrigger(trigger, observation: observation, resolution: .started)
        guard claim == .acquired else {
            // Nothing to hold: the real state, since a busy one may have been
            // declared while the claim was on its way.
            endSharedChatClaim()
            sharedChatConsumerStateDidChange()
            return
        }
        guard !isClosed, sharedChatObservation.isCurrent(observation), !isLineRunningOrWaiting else {
            // A line started, or the window closed or left the room, while
            // the claim was taken: the window gives it back. The claim stops
            // counting right before the give-back, which enqueues, before it
            // first suspends, its busy declaration (while the observation is
            // the current one) and the give-back itself: nothing runs in
            // between, so no idle declaration can come before them. The
            // give-back then declares the real state while the observation
            // is still the current one.
            endSharedChatClaim()
            await giveBackSharedChatClaim(trigger, observation: observation)
            if !sharedChatObservation.isCurrent(observation) {
                // The give-back declared nothing on this retired observation,
                // while its replacement may have been declared busy for the
                // claim: the real state on it.
                sharedChatConsumerStateDidChange()
            }
            return
        }
        startExclusive { [weak self] stop in
            await self?.runSharedChatTurn(trigger, roomID: roomID, observation: observation, stop: stop)
        }
        // The line is busy and declared so: the claim is its turn's from now
        // on, and the line's end declares the real state.
        endSharedChatClaim()
    }

    /// The room `trigger` is for, when it is the one the window observes now
    /// with `observation` and the room of the session the slot runs; `nil`
    /// otherwise, or once the window closed.
    private func sharedChatRoom(
        of trigger: AgentSharedChatAutoTrigger,
        observation: ZenSharedChatObservation.Observation
    ) async -> String? {
        guard !isClosed,
              sharedChatObservation.isCurrent(observation),
              trigger.roomID == observation.roomID,
              let roomID = sharedChatObservation.roomID else {
            return nil
        }
        let currentRoomID = await ZenSharedChatSteps.currentRoomID(in: sessionHost, slotID: slotID)
        guard !isClosed, sharedChatObservation.isCurrent(observation), currentRoomID == roomID else { return nil }
        return roomID
    }

    /// The line of a coordinator turn the window acquired: `trigger.prompt`
    /// runs verbatim, through the turn path and nothing else (no command, no
    /// pending reply), as a prompt the operator did not type, so its turn
    /// shows and its prompt does not. Stop ends it like any turn. A turn that
    /// does not start (refused, stopped or cancelled before it started, no
    /// controller for the room) gives the claim back, so its messages are
    /// offered again once the window is idle.
    private func runSharedChatTurn(
        _ trigger: AgentSharedChatAutoTrigger,
        roomID: String,
        observation: ZenSharedChatObservation.Observation,
        stop: ZenLineStop
    ) async {
        var didStart = false
        if !isClosed,
           let controller = await ZenSharedChatSteps.controller(in: sessionHost, slotID: slotID, roomID: roomID),
           !isClosed {
            let outcome = await runTurn(
                prompt: trigger.prompt,
                purpose: .normal,
                typedByOperator: false,
                stop: stop,
                controller: controller
            )
            switch outcome {
            case .finished, .failed:
                didStart = true
            case .refused, .cancelledBeforeStart:
                didStart = false
            }
        }
        if !didStart {
            // The line still runs: the batch waits for its end.
            await giveBackSharedChatClaim(trigger, observation: observation)
        }
        guard !isClosed else { return }
        if statusFactsAreStale {
            await refreshStatus()
        }
        refreshGitStatus()
    }

    /// Gives back the claim `observation` acquired for `trigger`, as one
    /// sequence on the chain of the busy declarations, so the owner never
    /// declares itself idle between the claim and the give-back (an idle
    /// owner releases its claim and the batch with it): busy first, while the
    /// observation is the current one; then the give-back, which returns the
    /// batch to the room; then, while the observation is still the current
    /// one and the window open, its real busy state, so the batch is offered
    /// again once the window is idle. A declaration made meanwhile, such as
    /// the idle one of a line that ends, lands after the give-back. The busy
    /// declaration and the give-back take their places on the chain before
    /// this first suspends; ``answerSharedChatTrigger(_:observation:)``
    /// relies on it.
    private func giveBackSharedChatClaim(
        _ trigger: AgentSharedChatAutoTrigger,
        observation: ZenSharedChatObservation.Observation
    ) async {
        if sharedChatObservation.isCurrent(observation) {
            sharedChatObservation.declareConsumerBusy(true)
        }
        _ = await resolveSharedChatTrigger(trigger, observation: observation, resolution: .declined)
        if !isClosed, sharedChatObservation.isCurrent(observation) {
            sharedChatObservation.declareConsumerBusy(isSharedChatConsumerBusy)
        }
    }

    /// Answers `trigger` as the owner `observation` (its claim or its
    /// give-back) on the chain of the busy declarations
    /// (``ZenSharedChatObservation/serialized(_:)``).
    private func resolveSharedChatTrigger(
        _ trigger: AgentSharedChatAutoTrigger,
        observation: ZenSharedChatObservation.Observation,
        resolution: AgentSharedChatAutoTriggerResolution
    ) async -> AgentSharedChatAutoTriggerClaimResult {
        let runner = sessionHost.runner
        let willResolve = sharedChatClaimWillResolve
        let triggerID = trigger.id
        return await sharedChatObservation.serialized {
            await willResolve?(resolution)
            return await runner.resolveSharedChatAutoTrigger(
                id: triggerID,
                observation: observation,
                resolution: resolution
            )
        }
    }

    /// Sends a live mention the operator submitted, beside whatever runs. On
    /// a failure the window shows why and, when the draft is empty by then,
    /// puts `line` back in it.
    func sendMention(_ mention: SharedChatMentionParser.Route, line: String) {
        let token = UUID()
        mentionTasks[token] = Task { [weak self] in
            guard let self else { return }
            let failure = await self.deliver(mention.text, to: mention.destination)
            self.mentionTasks[token] = nil
            guard let failure, !self.isClosed else { return }
            self.appendLocalNow(.local(text: failure, isFailure: true))
            if self.draft.isEmpty {
                self.draft = line
            }
        }
    }

    /// Publishes `text` to `destination` in the room of the session the slot
    /// runs now, as the operator; the failure text when it was not
    /// published.
    func deliver(_ text: String, to destination: AgentSharedChat.Destination) async -> String? {
        let runner = sessionHost.runner
        guard let roomID = await ZenSharedChatSteps.currentRoomID(in: sessionHost, slotID: slotID) else {
            return Self.mentionFailureMessage(for: AgentSharedChat.Error.unavailable)
        }
        guard await Self.isActiveDestination(destination, in: roomID, runner: runner) else {
            await refreshSharedChatRoster()
            return Self.mentionInactiveAgentMessage
        }
        do {
            _ = try await runner.sendSharedChatMessage(
                text: text,
                destination: destination,
                rootSessionID: roomID,
                messageID: UUID()
            )
        } catch {
            return Self.mentionFailureMessage(for: error)
        }
        await refreshSharedChatRoster()
        return nil
    }

    /// Whether `destination` still names an active recipient of `roomID`:
    /// the room also takes a display name as a direct identifier, but a
    /// mention must name one active agent by its id; the coordinator and the
    /// broadcast always do.
    static func isActiveDestination(
        _ destination: AgentSharedChat.Destination,
        in roomID: String,
        runner: AgentCoreSessionRunner
    ) async -> Bool {
        guard case let .direct(identifiers) = destination,
              identifiers.count == 1,
              let identifier = identifiers.first else {
            return true
        }
        let participants = await runner.sharedChatParticipants(rootSessionID: roomID)
        return participants.contains { $0.kind == .agent && $0.isActive && $0.id == identifier }
    }
}
