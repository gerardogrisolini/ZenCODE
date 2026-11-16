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
    var dialogue = VoiceChatDialogue()
    /// Sleeps until the answer to a spoken question is overdue.
    var deadlineTask: Task<Void, Never>?
    private let makeController: ControllerFactory
    nonisolated let relay = VoiceModeSessionRelay()
    private var stateStreams: [UUID: AsyncStream<VoiceModeSessionState>.Continuation] = [:]
    /// What the session knows of its current controller; ``state`` is
    /// computed from it (see `publishState()`).
    var facts = ControllerFacts()
    /// Advanced for every controller `/voice on` creates; its callbacks
    /// carry it, so what a replaced controller still reports is ignored.
    private var controllerGeneration: UInt64 = 0
    /// The start of the last controller `/voice on` created, awaited by the
    /// tests.
    private(set) var controllerStart: Task<Void, Never>?

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
    /// `zen --setup` > Voice mode, read again for every controller, so a failed
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

    /// What the session knows of its current controller, reset whenever the
    /// controller changes. A controller installed without `/voice on` (the
    /// terminal's tests) is taken to listen.
    struct ControllerFacts {
        var isPaused = false
        var isSpeaking = false
        /// `start()` has not returned yet.
        var isStartPending: Bool {
            didSet { noteListening() }
        }
        /// What the controller last reported through
        /// ``VoiceModeCallbacks/listeningChanged``; `nil` before it did.
        var listeningReport: Bool? {
            didSet { noteListening() }
        }
        /// The controller heard the microphone at least once: its start
        /// returned without a last report that it does not, or it reported
        /// that it does. It stays so while the recognizer loads again.
        private(set) var hasListened: Bool

        init(isStartPending: Bool = false, hasListened: Bool = true) {
            self.isStartPending = isStartPending
            self.listeningReport = nil
            self.hasListened = hasListened
        }

        /// The controller does not hear the microphone: its start did not
        /// return yet, or it last reported that it does not.
        var isStarting: Bool {
            isStartPending || listeningReport == false
        }

        private mutating func noteListening() {
            if listeningReport == true || (!isStartPending && listeningReport != false) {
                hasListened = true
            }
        }
    }

    /// The one place the state changes: computed from the controller and
    /// `facts`, so `isStarting` always agrees with the pause and the
    /// reading. Every change reaches ``stateUpdates()``.
    func publishState() {
        let newState: VoiceModeSessionState
        if controller != nil {
            newState = VoiceModeSessionState(
                isOn: true,
                isPaused: facts.isPaused,
                isSpeaking: facts.isSpeaking,
                isStarting: !facts.isPaused && !facts.isSpeaking && facts.isStarting
            )
        } else {
            newState = .off
        }
        guard newState != state else { return }
        state = newState
        for continuation in stateStreams.values {
            continuation.yield(newState)
        }
    }

    // MARK: Controller

    /// The controller voice mode runs, or `nil` while it is off. A controller
    /// that failed stays until the session notices it (see
    /// `activeController()`), which forgets it. Settable by the terminal's
    /// tests, which install a controller without starting it; such a
    /// controller is taken to listen.
    var controller: (any VoiceModeController)? {
        get { relay.controller }
        set { relay.controller = newValue }
    }

    /// The running controller, or `nil` when voice mode is off or its
    /// controller failed. Voice mode is off once its controller failed on
    /// its own: only that is read from the controller, since the session
    /// itself pauses, resumes, starts and stops it, and `isActive` never
    /// comes back. A failed controller is forgotten (see
    /// `controllerDidFail(_:)`).
    func activeController() async -> (any VoiceModeController)? {
        guard let controller else { return nil }
        guard await controller.isActive else {
            await controllerDidFail(controller)
            return nil
        }
        return controller
    }

    /// `failed` stopped on its own: voice mode is off, as after
    /// ``stop()``, but the controller is not stopped again, since a failed
    /// one already released what it held. Callers race here (the start, the
    /// failure callback, the commands): only the first one that finds
    /// `failed` still current tears down, and it forgets the controller
    /// before its first suspension, so the host hears
    /// ``VoiceModeSessionHost/voiceModeDidStop()`` once for it.
    private func controllerDidFail(_ failed: any VoiceModeController) async {
        guard controller === failed else { return }
        controller = nil
        facts = ControllerFacts()
        await cancelDialogue()
        publishState()
        await host?.voiceModeDidStop()
    }

    /// The `start()` of controller `generation` returned. A start that
    /// failed turns voice mode off; one that listens ends `isStarting`,
    /// unless the controller last reported that it does not hear the
    /// microphone yet.
    private func controllerDidStart(generation: UInt64) async {
        guard await activeController() != nil,
              generation == controllerGeneration,
              controller != nil else {
            return
        }
        facts.isStartPending = false
        publishState()
    }

    /// Controller `generation` reported whether it hears the microphone; a
    /// report of a replaced or stopped controller changes nothing.
    private func listeningChanged(_ isListening: Bool, generation: UInt64) {
        guard generation == controllerGeneration, controller != nil else {
            return
        }
        facts.listeningReport = isListening
        publishState()
    }

    /// The controller while it listens: the live-chat dialogue announces,
    /// reads and asks only then.
    func availableController() async -> (any VoiceModeController)? {
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
        controllerGeneration &+= 1
        let generation = controllerGeneration
        let controller: any VoiceModeController
        switch makeController(makeCallbacks(generation: generation)) {
        case let .ready(ready):
            controller = ready
        case let .unavailable(message):
            await showFailureMessage(message)
            return
        }
        self.controller = controller
        // On, and starting until `start()` returns.
        facts = ControllerFacts(isStartPending: true, hasListened: false)
        publishState()
        await host?.voiceModeDidStart()
        // Starting may wait on the system permission prompts or on loading
        // the speech models; never hold the channel on it. The controller
        // reports when it listens.
        controllerStart = Task(name: "ZenCODE.voice-start") { [weak self] in
            await controller.start()
            await self?.controllerDidStart(generation: generation)
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
            facts.isPaused = paused
            publishState()
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
        facts = ControllerFacts()
        publishState()
        await controller.stop()
        await host?.voiceModeDidStop()
    }

    /// Forgets the controller and the answer deadline without awaiting
    /// anything, and returns the controller for the caller to stop: the
    /// synchronous fallback of a channel's teardown.
    func detachController() -> (any VoiceModeController)? {
        let controller = self.controller
        self.controller = nil
        facts = ControllerFacts()
        cancelDeadline()
        publishState()
        return controller
    }

    /// The instruction that goes out with a prompt while voice mode listens
    /// (running and not paused), otherwise `nil`. A controller that is
    /// starting hears nothing yet: there is none until it listened a first
    /// time, then also while it loads its recognizer again. Ask for it for
    /// every prompt, so `/voice pause`, `/voice resume` and `/voice off` take
    /// effect from the next one; it belongs to the outgoing request only
    /// (see `AgentTurnInstructionContext`), never to history or snapshots.
    public func turnInstruction() async -> String? {
        guard let controller = await activeController(),
              await !controller.isPaused,
              self.controller === controller,
              facts.hasListened else {
            return nil
        }
        return Self.turnInstructionText
    }

    // MARK: Callbacks

    /// The callbacks of controller `generation`: its texts and whether it
    /// listens are handled on the chat actor, everything else goes straight
    /// to the current host's `nonisolated` requirements, never through the
    /// chat actor.
    private func makeCallbacks(generation: UInt64) -> VoiceModeCallbacks {
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
            },
            listeningChanged: { [weak self] isListening in
                await self?.listeningChanged(isListening, generation: generation)
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
