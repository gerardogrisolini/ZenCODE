//
//  VoiceModeSession.swift
//  ZenCODE
//
//  The coordinator of voice mode, the same in every channel: the `/voice`
//  command and the controller's lifetime, the per-turn instruction, the
//  answers and comments read aloud, and the spoken dialogue over the live
//  shared chat (`VoiceChatDialogue`). One session serves one microphone: the
//  terminal runs one for its chat, a host app one for all its windows,
//  pointed at the active one (`setHost`). What only a channel can do (its
//  draft, its reader, its rules for a typed line, its serialized context) is
//  behind `VoiceModeSessionHost`. Transient: nothing of it is persisted.
//

import Foundation
import Synchronization

/// Voice mode for a channel: dictation into ordinary prompts, final answers
/// and comments read aloud, and the live shared-chat messages for the
/// operator announced and answered by voice (see `Docs/voice.md`).
///
/// One session drives one controller, so an app runs one session for the
/// whole process (one microphone) and points it at the active window with
/// ``setHost(_:announcingMessagesSince:)``. Voice mode is independent of the
/// agent and of the session the host shows, and it is never persisted.
///
/// Every call runs on the chat actor. The host calls the event entry points
/// (``handleUtterance(_:)``, ``speakingChanged(_:)``,
/// ``answerDeadlineElapsed(_:)``, ``handleSharedChatMessages(_:)``,
/// ``speakCommentary(_:duringTurn:)``, ``turnDidEnd(finalAnswer:)``) one at a
/// time, from its serialized context, in the order the events happened. The
/// session never waits there for room in a queue: what the controller
/// reports reaches the host through its `nonisolated` requirements.
@ChatSessionActor
public final class VoiceModeSession {
    /// Builds the controller `/voice on` starts. The callbacks are the
    /// session's: a test controller calls them to pretend it heard
    /// something or started and stopped reading.
    public typealias ControllerFactory = @Sendable (VoiceModeCallbacks) -> VoiceModeControllerCreation

    /// Sent to the model with every prompt while voice mode listens (see
    /// ``turnInstruction()``). English on purpose: the language of the answer
    /// is already handled by the system prompt.
    static let turnInstructionText = "Voice mode is on: the user is listening and your final answer is read aloud. Answer in short sentences. While you work, briefly comment on what you are doing as you do it. Keep any format the request requires."
    static let offMessage = "ZenCODE: voice mode is off. Run /voice on to start it.\n"
    /// What a typed mention to an agent that is gone shows, in every channel.
    static let inactiveAgentMessage = "ZenCODE message: selected agent is no longer active.\n"

    /// What the session does now; every change is also delivered by
    /// ``stateUpdates()``.
    public private(set) var state = VoiceModeSessionState.off
    /// How long a spoken live-chat question waits for its answer before it
    /// lapses in silence: 60 seconds. A change applies from the next
    /// question.
    public var answerTimeout: Duration = .seconds(60)

    /// Messages sent before this instant are never announced: the
    /// transcript an observation replays when it starts.
    var announcementsSince: Date
    /// The spoken dialogue over the shared chat: announcements queued, the
    /// question being asked, the reply awaited. Transient like voice mode.
    private(set) var dialogue = VoiceChatDialogue()
    /// Sleeps until the answer to a spoken question is overdue.
    private var deadlineTask: Task<Void, Never>?
    private let makeController: ControllerFactory
    private nonisolated let relay = VoiceModeSessionRelay()
    private var stateStreams: [UUID: AsyncStream<VoiceModeSessionState>.Continuation] = [:]

    /// A session that runs this platform's controller: local dictation with
    /// the Apple speech frameworks on macOS, the downloaded sherpa-onnx
    /// programs on Linux. `/voice on` reads the voice language, the reading
    /// voice, and the options from the settings each time it creates one.
    public nonisolated convenience init() {
        self.init(makeController: { callbacks in
            VoiceModeSession.platformController(callbacks: callbacks)
        })
    }

    /// A session whose `/voice on` creates its controller with
    /// `makeController`, e.g. a test controller that records nothing and
    /// asks for no permission.
    public nonisolated init(makeController: @escaping ControllerFactory) {
        self.makeController = makeController
        self.announcementsSince = Date.now
    }

    /// A released session ends the streams of its state.
    deinit {
        deadlineTask?.cancel()
        for continuation in stateStreams.values {
            continuation.finish()
        }
    }

    /// The controller of this platform, configured from the settings: the
    /// voice mode language, the macOS reading voice, and the options of
    /// `/setup` > Voice mode, read again for every controller, so a failed
    /// one is replaced with the current choices.
    nonisolated static func platformController(
        callbacks: VoiceModeCallbacks
    ) -> VoiceModeControllerCreation {
        let manifest = AgentSettingsManifestStore.load()
        let languageCode = VoiceLanguage.resolvedCode(manifest: manifest)
        return VoiceModePlatform.makeController(
            languageCode: languageCode,
            readingVoiceIdentifier: manifest?.voice?.macOSVoiceIdentifier,
            options: VoiceModeOptions(voice: manifest?.voice),
            callbacks: callbacks
        )
    }

    // MARK: Host

    /// The channel the session speaks for, held weakly.
    public var host: (any VoiceModeSessionHost)? {
        relay.host
    }

    /// Points the session at `host`, e.g. the window that became active,
    /// with the semantics of a new target: the reading stops, the live-chat
    /// question and every queued announcement are dropped, and only messages
    /// sent from `since` on are announced. While voice mode runs, the
    /// previous host is told ``VoiceModeSessionHost/voiceModeDidStop()`` and
    /// the new one ``VoiceModeSessionHost/voiceModeDidStart()``; end the
    /// dictation the previous host showed with ``dictationEnded(through:)``.
    /// Nothing happens when `host` is already the session's host.
    public func setHost(
        _ host: (any VoiceModeSessionHost)?,
        announcingMessagesSince since: Date = .now
    ) async {
        let previous = relay.host
        guard previous !== host else { return }
        // Whatever the previous host still reports reaches it until here.
        await interruptPlayback()
        if controller != nil {
            await previous?.voiceModeDidStop()
        }
        relay.host = host
        announcementsSince = since
        if controller != nil {
            await host?.voiceModeDidStart()
        }
    }

    /// The host now shows another session or room (a new or loaded session,
    /// an observation that restarted): the reading stops, the live-chat
    /// question and every queued announcement are dropped, and only messages
    /// sent from `since` on are announced. Take `since` before the new
    /// observation starts, so a message sent in between is still new.
    public func targetDidChange(announcingMessagesSince since: Date = .now) async {
        announcementsSince = since
        await interruptPlayback()
    }

    /// Installs the first host without the semantics of a new target, for a
    /// channel that creates its session with it.
    func attachHost(_ host: any VoiceModeSessionHost) {
        relay.host = host
    }

    // MARK: State

    /// The state now, then each change, newest first: a slow reader skips
    /// the states it did not take yet. The stream ends when the session is
    /// released or the task reading it is cancelled.
    public func stateUpdates() -> AsyncStream<VoiceModeSessionState> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: VoiceModeSessionState.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.yield(state)
        let token = UUID()
        stateStreams[token] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { @ChatSessionActor in
                self.stateStreams[token] = nil
            }
        }
        return stream
    }

    private func publish(_ newState: VoiceModeSessionState) {
        guard newState != state else { return }
        state = newState
        for continuation in stateStreams.values {
            continuation.yield(newState)
        }
    }

    // MARK: Controller

    /// The controller voice mode runs, or `nil` while it is off. A controller
    /// that failed stays until it is replaced or stopped, and is inactive.
    /// Settable by the terminal's tests, which install a controller without
    /// starting it.
    var controller: (any VoiceModeController)? {
        get { relay.controller }
        set { relay.controller = newValue }
    }

    /// The running controller, or `nil` when voice mode is off or its
    /// controller failed. Voice mode is off once its controller failed on
    /// its own: only that is read from the controller, since the session
    /// itself pauses, resumes, starts and stops it, and `isActive` never
    /// comes back.
    func activeController() async -> (any VoiceModeController)? {
        guard let controller else { return nil }
        guard await controller.isActive else {
            // It failed on its own: voice mode is off.
            if self.controller === controller {
                publish(.off)
            }
            return nil
        }
        return controller
    }

    /// The controller while it listens: the live-chat dialogue announces,
    /// reads and asks only then.
    private func availableController() async -> (any VoiceModeController)? {
        guard let controller,
              await controller.isActive,
              await !controller.isPaused else {
            return nil
        }
        return controller
    }

    // MARK: Command

    /// The `/voice` subcommand of `line`.
    nonisolated static func commandAction(for line: String) -> VoiceModeCommandAction {
        VoiceModeCommandAction(argument: ChatCommandRegistry.arguments(from: line, commandPrefix: "/voice"))
    }

    /// Runs `line`, the whole `/voice [on|off|pause|resume]` command; bare
    /// `/voice` pauses a listening voice mode and resumes a paused one. The
    /// outcome is shown through the host, with the terminal's texts.
    public func handleCommand(_ line: String) async {
        switch Self.commandAction(for: line) {
        case .turnOn:
            await turnOn()
        case .turnOff:
            await turnOff()
        case .pause:
            await setPaused(true)
        case .resume:
            await setPaused(false)
        case .togglePause:
            guard let controller = await activeController() else {
                await showFailureMessage(Self.offMessage)
                return
            }
            await setPaused(!(await controller.isPaused))
        case .usage:
            await showSystemMessage(VoiceModeCommandAction.usageMessage)
        }
    }

    private func turnOn() async {
        if let controller = await activeController() {
            let state = await controller.isPaused ? " (paused). /voice resume resumes it" : ""
            await showSystemMessage("Voice: already on\(state).\n")
            return
        }
        // A failed controller is replaced, so the language, the reading
        // voice and the options are read again.
        await stop()
        let controller: any VoiceModeController
        switch makeController(makeCallbacks()) {
        case let .ready(ready):
            controller = ready
        case let .unavailable(message):
            await showFailureMessage(message)
            return
        }
        self.controller = controller
        publish(VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: false))
        await host?.voiceModeDidStart()
        // Starting may wait on the system permission prompts or on loading
        // the speech models; never hold the channel on it. The controller
        // reports when it listens.
        Task(name: "ZenCODE.voice-start") { [weak self] in
            await controller.start()
            // A start that failed turns voice mode off.
            _ = await self?.activeController()
        }
    }

    private func turnOff() async {
        guard await activeController() != nil else {
            await stop()
            await showSystemMessage("Voice: already off.\n")
            return
        }
        await stop()
        await showSystemMessage("Voice: off.\n")
    }

    private func setPaused(_ paused: Bool) async {
        guard let controller = await activeController() else {
            await showFailureMessage(Self.offMessage)
            return
        }
        if paused {
            await cancelDialogue()
        }
        let changed = await controller.setPaused(paused)
        if self.controller === controller {
            publish(VoiceModeSessionState(isOn: true, isPaused: paused, isSpeaking: state.isSpeaking))
        }
        switch (paused, changed) {
        case (true, true):
            await showSystemMessage("Voice: paused; not listening or reading answers aloud. /voice resumes it.\n")
        case (true, false):
            await showSystemMessage("Voice: already paused.\n")
        case (false, true):
            await showSystemMessage("Voice: resumed.\n")
        case (false, false):
            await showSystemMessage("Voice: already listening.\n")
        }
    }

    /// Stops voice mode, without a message: the live-chat dialogue is
    /// dropped, the controller stopped, and the host told
    /// ``VoiceModeSessionHost/voiceModeDidStop()``. `/voice on` starts it
    /// again.
    public func stop() async {
        await cancelDialogue()
        guard let controller else {
            return
        }
        self.controller = nil
        publish(.off)
        await controller.stop()
        await host?.voiceModeDidStop()
    }

    /// Forgets the controller and the answer deadline without awaiting
    /// anything, and returns the controller for the caller to stop: the
    /// synchronous fallback of a channel's teardown.
    func detachController() -> (any VoiceModeController)? {
        let controller = self.controller
        self.controller = nil
        cancelDeadline()
        if controller != nil {
            publish(.off)
        }
        return controller
    }

    /// The instruction that goes out with a prompt while voice mode listens
    /// (running and not paused), otherwise `nil`. Ask for it for every
    /// prompt, so `/voice pause`, `/voice resume` and `/voice off` take
    /// effect from the next one; it belongs to the outgoing request only
    /// (see `AgentTurnInstructionContext`), never to history or snapshots.
    public func turnInstruction() async -> String? {
        guard let controller = await activeController(),
              await !controller.isPaused else {
            return nil
        }
        return Self.turnInstructionText
    }

    // MARK: Reading aloud

    /// A turn ended. Its `finalAnswer`, when the channel presented one, is
    /// read aloud while voice mode runs and is not paused; it takes
    /// precedence over the live-chat dialogue and replaces a comment still
    /// being read. When nothing is read (no answer, a failed turn, nothing to
    /// say, voice mode paused), a message set aside during the turn is
    /// announced right away.
    public func turnDidEnd(finalAnswer: String?) async {
        var isReadingAnswer = false
        if let finalAnswer {
            isReadingAnswer = await speakResponse(finalAnswer)
        }
        if !isReadingAnswer {
            await startNextAnnouncement()
        }
    }

    /// Reads a completed answer aloud. An answer that starts takes
    /// precedence over the live-chat dialogue (see
    /// `VoiceChatDialogue.answerReadingStarted`) and replaces a comment still
    /// being read: it does not check whether something is being read. One
    /// that does not start leaves the dialogue as it is. Returns whether the
    /// reading started.
    func speakResponse(_ response: String) async -> Bool {
        guard let controller else {
            return false
        }
        let started = await controller.speak(response, rendering: .answer)
        if started {
            cancelDeadline()
            dialogue.answerReadingStarted()
            await syncAnswerState()
        }
        return started
    }

    /// A comment the main agent wrote before a tool call, read aloud like an
    /// answer only while its turn runs (`isTurnRunning`), nothing else is
    /// being read, and the live-chat dialogue is idle; otherwise it is
    /// dropped (it stays on screen only). It never changes the dialogue.
    public func speakCommentary(_ text: String, duringTurn isTurnRunning: Bool) async {
        guard isTurnRunning,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              dialogue.phase == .idle,
              let controller = await availableController(),
              await !controller.isSpeaking else {
            return
        }
        _ = await controller.speak(text, rendering: .answer)
    }

    /// Stops what is being read, e.g. after `Esc`. On Linux this also turns
    /// the microphone back on. The live-chat question and its queue are
    /// dropped: nothing is announced retroactively.
    public func interruptPlayback() async {
        await cancelDialogue()
        await controller?.interruptPlayback()
    }

    // MARK: Events from the host

    /// An edit turned the dictation shown in the draft, through `id`, into
    /// ordinary text, or the dictation's host is no longer the session's:
    /// voice forgets what it collected for it and starts a new dictation.
    /// Callable from any context; it returns at once.
    public nonisolated func dictationEnded(through id: UInt64) {
        guard let controller = relay.controller else { return }
        Task(name: "ZenCODE.voice-discard-dictation") {
            await controller.discardDictation(through: id)
        }
    }

    /// New messages of the room the host shows, each delivered once. Those
    /// for the operator from the coordinator or an agent, sent while voice
    /// mode listens, are announced one at a time after whatever is being
    /// read; a replayed transcript, older than the observation, stays
    /// silent.
    public func handleSharedChatMessages(_ messages: [AgentSharedChat.Message]) async {
        guard await availableController() != nil else { return }
        dialogue.enqueue(messages.filter { $0.sentAt >= announcementsSince })
        await startNextAnnouncement()
    }

    /// The controller reported that it started (`true`) or stopped
    /// (`false`) reading aloud. Only the end of a reading moves the dialogue
    /// on, and only when nothing newer is being read: a question starts
    /// waiting for its answer, a read message turns into "Do you want to
    /// reply?", an idle dialogue announces the next message.
    public func speakingChanged(_ isSpeaking: Bool) async {
        if state.isOn {
            publish(VoiceModeSessionState(isOn: true, isPaused: state.isPaused, isSpeaking: isSpeaking))
        }
        guard !isSpeaking,
              let controller,
              await !controller.isSpeaking else {
            return
        }
        switch dialogue.speechEnded() {
        case let .armDeadline(token):
            await syncAnswerState()
            armDeadline(token)
        case .announceNext:
            await startNextAnnouncement()
        case .none:
            break
        }
    }

    /// The answer to the question `token` is overdue: the question lapses in
    /// silence, its message stays unread, and the next one is announced. A
    /// late token of an older question is ignored.
    public func answerDeadlineElapsed(_ token: UUID) async {
        if dialogue.deadlineElapsed(token) {
            cancelDeadline()
            await syncAnswerState()
            await startNextAnnouncement()
        }
    }

    /// Carries out what the dialogue decides for a recognized utterance: the
    /// answer to a question, a "message to …" phrase sent without a turn, or
    /// a dictation the host sends (``VoiceModeSessionHost/voiceModeSubmitDictation(_:)``).
    /// Returns `false` when the channel ends because of it.
    public func handleUtterance(_ utterance: String) async -> Bool {
        // Nothing was heard: the question, if any, stays open.
        guard !utterance.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        cancelDeadline()
        let participants = await host?.voiceModeSharedChatParticipants() ?? []
        let action = dialogue.interpret(utterance, participants: participants)
        await syncAnswerState()
        switch action {
        case .prompt:
            guard let host else { return true }
            return await host.voiceModeSubmitDictation(VoiceModeDictatedInput(utterance: utterance))
        case let .read(message):
            let languageCode = await languageCode()
            let text = VoiceChatPhrases.readAloud(
                text: VoiceSpeechText.speakable(
                    fromMarkdown: SharedChatMentionParser.terminalSafeText(message.text),
                    languageCode: languageCode
                ),
                languageCode: languageCode
            )
            guard await speakDialogue(text) else {
                await cancelDialogue()
                return true
            }
            // Reading aloud consumes the message like opening it in the reader.
            await host?.voiceModeMarkSharedChatMessageRead(message.id)
        case .declined, .skip:
            await startNextAnnouncement()
        case .askReplyText:
            await speakDialogueOrCancel(VoiceChatPhrases.replyPrompt(languageCode: languageCode()))
        case .askMessageText:
            await speakDialogueOrCancel(VoiceChatPhrases.messagePrompt(languageCode: languageCode()))
        case let .send(destination, text, label):
            // A mention by voice is never a line that changes who drives the
            // channel: refused like a typed one when the channel says so.
            guard let host, await host.voiceModeAdmitsInput() else { return true }
            let languageCode = await languageCode()
            // Checked here as well so the spoken reason names the agent; the
            // channel shows the notice a typed mention would.
            guard await host.voiceModeIsActiveSharedChatDestination(destination) else {
                await host.voiceModeShowFailureMessage(Self.inactiveAgentMessage)
                _ = await speakDialogue(
                    VoiceChatPhrases.agentInactive(name: label, languageCode: languageCode)
                )
                return true
            }
            let sent = await host.voiceModeSendSharedChatMessage(text, to: destination)
            _ = await speakDialogue(
                sent
                    ? VoiceChatPhrases.sent(languageCode: languageCode)
                    : VoiceChatPhrases.sendFailed(languageCode: languageCode)
            )
        case let .unknownAgent(name):
            _ = await speakDialogue(
                VoiceChatPhrases.unknownAgent(name: name, languageCode: languageCode())
            )
        }
        return true
    }

    // MARK: Live-chat dialogue

    /// Announces the next queued message, unless voice mode is off or
    /// paused, something is still being read, or a question is pending.
    /// Messages read in the host's reader meanwhile are skipped.
    func startNextAnnouncement() async {
        guard let controller = await availableController(),
              await !controller.isSpeaking,
              dialogue.phase == .idle else {
            return
        }
        // The messages read meanwhile, up to the first unread one: the one
        // the dialogue takes next.
        var alreadyRead: Set<UUID> = []
        if let host {
            for message in dialogue.pending {
                guard await !host.voiceModeIsSharedChatMessageUnread(message.id) else { break }
                alreadyRead.insert(message.id)
            }
        }
        guard let announcement = dialogue.beginAnnouncement(
            skipping: { alreadyRead.contains($0) }
        ) else {
            return
        }
        await syncAnswerState()
        let message = announcement.message
        let text = VoiceChatPhrases.announcement(
            sender: AgentSharedChat.displayName(for: message.sender),
            isBroadcast: message.recipientIDs.count > 1,
            remaining: announcement.remaining,
            languageCode: controller.languageCode
        )
        if await !controller.speak(text, rendering: .plainText) {
            dialogue.announcementNotSpoken()
            await syncAnswerState()
        }
    }

    /// Reads a dialogue text whole; `false` when nothing was started.
    private func speakDialogue(_ text: String) async -> Bool {
        guard let controller = await availableController() else {
            return false
        }
        return await controller.speak(text, rendering: .plainText)
    }

    /// Reads a dialogue question or request; when nothing can be read the
    /// dialogue cannot go on and is dropped, so a later utterance is never
    /// taken for the answer to a question nobody heard.
    private func speakDialogueOrCancel(_ text: String) async {
        if await !speakDialogue(text) {
            await cancelDialogue()
        }
    }

    private func languageCode() async -> String? {
        await availableController()?.languageCode
    }

    /// Forgets the spoken live-chat question and every queued announcement.
    private func cancelDialogue() async {
        cancelDeadline()
        dialogue.cancelAll()
        await syncAnswerState()
    }

    /// Tells the controller whether the dialogue awaits a yes or no, so
    /// keyword send mode lets a bare answer through. Called after every
    /// dialogue transition.
    private func syncAnswerState() async {
        await controller?.setAwaitingShortAnswer(dialogue.isAwaitingAffirmation)
    }

    /// A spoken question lapses in silence when its answer is overdue: the
    /// host delivers the token in its serialized context.
    private func armDeadline(_ token: UUID) {
        cancelDeadline()
        let timeout = answerTimeout
        let relay = relay
        deadlineTask = Task(name: "ZenCODE.voice-dialogue-deadline") {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            await relay.host?.voiceModeDeliverAnswerDeadline(token)
        }
    }

    /// Stops waiting for the answer to a spoken question.
    private func cancelDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
    }

    // MARK: Callbacks

    /// The controller's callbacks: its texts are shown on the chat actor,
    /// everything else goes straight to the current host's `nonisolated`
    /// requirements, never through the chat actor.
    private func makeCallbacks() -> VoiceModeCallbacks {
        let relay = relay
        return VoiceModeCallbacks(
            systemMessage: { [weak self] text in
                await self?.showSystemMessage(text)
            },
            failureMessage: { [weak self] text in
                await self?.showFailureMessage(text)
                // A failure may have stopped the controller: voice mode is
                // then off.
                _ = await self?.activeController()
            },
            utteranceRecognized: { utterance in
                guard let host = relay.host else { return }
                await Self.deliver(utterance, to: host)
            },
            dictationChanged: { id, text in
                await relay.host?.voiceModeDictationChanged(id: id, text: text)
            },
            speakingChanged: { isSpeaking in
                await relay.host?.voiceModeDeliverSpeakingChanged(isSpeaking)
            }
        )
    }

    /// A recognized utterance as the host sends it: a dictation takes the
    /// whole visible draft (typed text, then the dictation), unless an edit
    /// already ended it; a bare answer goes alone. Nothing blank is sent.
    nonisolated static func deliver(_ utterance: VoiceModeUtterance, to host: any VoiceModeSessionHost) async {
        let text: String?
        switch utterance {
        case let .dictation(id, dictated):
            text = await host.voiceModeTakeDictation(id: id, text: dictated)
        case let .answer(answer):
            text = answer
        }
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        await host.voiceModeDeliverUtterance(text)
    }

    private func showSystemMessage(_ text: String) async {
        await host?.voiceModeShowSystemMessage(text)
    }

    private func showFailureMessage(_ text: String) async {
        await host?.voiceModeShowFailureMessage(text)
    }
}

/// The session's host and controller, readable from the controller's
/// callbacks and from ``VoiceModeSession/dictationEnded(through:)`` without
/// a hop to the chat actor, so a preview reaches the draft at once. The host
/// is held weakly.
final class VoiceModeSessionRelay: Sendable {
    private struct Current {
        weak var host: (any VoiceModeSessionHost)?
        var controller: (any VoiceModeController)?
    }

    private let current = Mutex(Current())

    var host: (any VoiceModeSessionHost)? {
        get { current.withLock { $0.host } }
        set { current.withLock { $0.host = newValue } }
    }

    var controller: (any VoiceModeController)? {
        get { current.withLock { $0.controller } }
        set { current.withLock { $0.controller = newValue } }
    }
}
