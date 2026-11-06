//
//  ZenAppVoice.swift
//  ZenApp
//
//  The app's voice mode: one `VoiceModeSession` for the whole app (one
//  microphone), owned by the runtime and pointed at the active window, and
//  the app's serialized voice context, where everything voice mode is handed
//  runs one at a time, in order. Each window is a `VoiceModeSessionHost`
//  (`ZenWindowVoiceHost`). Transient: nothing of it is persisted.
//

import Foundation
import Synchronization
import ZenCODECore

/// One request of the app's serialized voice context (``ZenAppVoice``).
enum ZenVoiceRequest: Sendable {
    // From the voice controller, through a window's host.

    /// A recognized utterance the host took from its draft or the dialogue
    /// awaits.
    case utterance(String, host: ZenWindowVoiceHost)
    /// The controller started or stopped reading aloud.
    case speakingChanged(Bool)
    /// A spoken live-chat question waited too long for its answer.
    case answerDeadline(UUID)

    // From a window.

    /// New messages of the room the window shows.
    case sharedChatMessages([AgentSharedChat.Message], host: ZenWindowVoiceHost)
    /// A turn of the window started: its own, a coordinator turn, or one
    /// adopted from Telegram.
    case turnStarted(host: ZenWindowVoiceHost)
    /// The text the main agent wrote before a tool call of the window's
    /// turn.
    case commentary(String, host: ZenWindowVoiceHost)
    /// The window's turn ended, with the answer to read (`nil` when it
    /// failed or was stopped).
    case turnEnded(finalAnswer: String?, host: ZenWindowVoiceHost)
    /// Esc in the window, while voice reads or a line runs.
    case interruptPlayback(host: ZenWindowVoiceHost)
    /// An edit of a window's draft ended the dictation it showed, through
    /// `id`: the controller's id, whichever window showed it.
    case dictationEnded(through: UInt64)
    /// The window shows another session: its room is observed from `since`.
    case targetDidChange(since: Date, host: ZenWindowVoiceHost)

    // From the runtime.

    /// The window became the active one; `nil` when no window is.
    case activate(ZenWindowVoiceHost?)
    /// The window closed; `fallback` is the most recent active window left.
    case windowClosed(ZenWindowVoiceHost, fallback: ZenWindowVoiceHost?)
    /// A `/voice` line the window runs: the window becomes the active one
    /// first.
    case command(String, host: ZenWindowVoiceHost)
    /// The runtime shuts down: voice mode stops and the context ends.
    case shutdown
    /// Nothing: done once every request before it was handled, for tests.
    case flush
}

/// What the app's voice context tells the main actor, in order.
enum ZenVoiceUpdate: Sendable {
    /// The controller started (`true`) or stopped reading aloud, as it
    /// reported it, before the session hears of it.
    case speaking(Bool)
    /// The window voice mode follows now; `nil` when none.
    case activeWindow(UUID?)
}

/// The way into the app's voice context: an unbounded stream with one
/// consumer, so a post never waits, from any context, and the requests are
/// handled in the order they were posted.
final class ZenVoiceRequestSink: Sendable {
    struct Envelope: Sendable {
        let request: ZenVoiceRequest
        /// Resumed once the request was handled, or dropped after the
        /// context ended.
        let done: CheckedContinuation<Void, Never>?
    }

    let requests: AsyncStream<Envelope>
    let updates: AsyncStream<ZenVoiceUpdate>
    private let requestContinuation: AsyncStream<Envelope>.Continuation
    private let updateContinuation: AsyncStream<ZenVoiceUpdate>.Continuation

    init() {
        (requests, requestContinuation) = AsyncStream.makeStream(of: Envelope.self)
        (updates, updateContinuation) = AsyncStream.makeStream(of: ZenVoiceUpdate.self)
    }

    /// Posts `request` without waiting; dropped once the context ended.
    func post(_ request: ZenVoiceRequest) {
        requestContinuation.yield(Envelope(request: request, done: nil))
    }

    /// Posts `request` and waits until it was handled; returns at once once
    /// the context ended.
    func perform(_ request: ZenVoiceRequest) async {
        await withCheckedContinuation { done in
            if case .terminated = requestContinuation.yield(Envelope(request: request, done: done)) {
                done.resume()
            }
        }
    }

    /// Tells the main actor something at once, without waiting.
    func update(_ update: ZenVoiceUpdate) {
        updateContinuation.yield(update)
    }

    /// Ends both streams; the requests already posted are still handled.
    func finish() {
        requestContinuation.finish()
        updateContinuation.finish()
    }
}

/// The app's voice mode, one per runtime: one ``VoiceModeSession`` (one
/// microphone) for every window, pointed at the active one, and the
/// serialized context where everything handed to the session runs, one
/// request at a time, in the order the requests were posted
/// (``ZenVoiceRequestSink``): the controller's deliveries from every window,
/// the windows' turns, comments, room messages, Esc, and the edits that end a
/// dictation, the switches of the active window, and the `/voice` lines.
///
/// Everything follows the active window: dictation, the answers and comments
/// read aloud, the live-chat announcements, and the per-turn instruction
/// (``ZenWindowVoiceHost/turnInstruction()``). What another window reports is
/// dropped, except a recognized utterance it already took from its draft,
/// which goes back there as ordinary text.
@ChatSessionActor
final class ZenAppVoice {
    let session: VoiceModeSession
    nonisolated let sink = ZenVoiceRequestSink()
    /// Awaited before each request is handled, for tests.
    var requestWillHandle: (@Sendable (ZenVoiceRequest) async -> Void)?
    /// The highest dictation an edit or a switch of the active window ended:
    /// the window that takes voice mode over ignores it and every older
    /// one, since their previews may still be on their way
    /// (``ZenWindowVoiceHost/voiceModeDidStart()``). Raised before voice
    /// forgets the dictation, so a switch asked after the edit already
    /// sees it. Back to 0 when a `/voice` line runs while voice mode is off,
    /// since the controller it may start numbers its dictations from 1
    /// again; a `/voice on` that finds voice mode on keeps it.
    private(set) var dictationFloor: UInt64 = 0
    private var isShutDown = false
    private var consumer: Task<Void, Never>?

    init(session: VoiceModeSession) {
        self.session = session
        let requests = sink.requests
        consumer = Task { [weak self] in
            for await envelope in requests {
                if let self {
                    await self.handle(envelope.request)
                }
                envelope.done?.resume()
            }
        }
    }

    /// The window voice mode follows now, or `nil`.
    var activeHost: ZenWindowVoiceHost? {
        session.host as? ZenWindowVoiceHost
    }

    private func isActive(_ host: ZenWindowVoiceHost) -> Bool {
        session.host === host
    }

    private func handle(_ request: ZenVoiceRequest) async {
        await requestWillHandle?(request)
        guard !isShutDown else { return }
        switch request {
        case let .utterance(text, host):
            if isActive(host) {
                // A window never ends because of an utterance.
                _ = await session.handleUtterance(text)
            } else {
                // Taken from the draft of a window that is no longer the
                // active one: the words go back there as ordinary text,
                // unsent, like a dictation the switch ended.
                await host.restoreUtterance(text)
            }
        case let .speakingChanged(isSpeaking):
            // The controller's, whichever window reported it.
            await session.speakingChanged(isSpeaking)
        case let .answerDeadline(token):
            await session.answerDeadlineElapsed(token)
        case let .sharedChatMessages(messages, host):
            guard isActive(host) else { return }
            await session.handleSharedChatMessages(messages)
        case let .turnStarted(host):
            host.runningTurns += 1
        case let .commentary(text, host):
            guard isActive(host) else { return }
            await session.speakCommentary(text, duringTurn: host.isTurnRunning)
        case let .turnEnded(finalAnswer, host):
            host.runningTurns = max(0, host.runningTurns - 1)
            guard isActive(host) else { return }
            await session.turnDidEnd(finalAnswer: finalAnswer)
        case let .interruptPlayback(host):
            guard isActive(host) else { return }
            await session.interruptPlayback()
        case let .dictationEnded(id):
            endDictation(through: id)
        case let .targetDidChange(since, host):
            guard isActive(host) else { return }
            await session.targetDidChange(announcingMessagesSince: since)
        case let .activate(host):
            await activate(host)
        case let .windowClosed(host, fallback):
            guard isActive(host) else { return }
            await activate(fallback)
        case let .command(line, host):
            await activate(host)
            if !session.state.isOn {
                // No controller runs: the one the line may start numbers
                // its dictations from 1.
                dictationFloor = 0
            }
            await session.handleCommand(line)
        case .shutdown:
            isShutDown = true
            await session.stop()
            await session.setHost(nil)
            sink.update(.activeWindow(nil))
            sink.finish()
        case .flush:
            break
        }
    }

    /// Points voice mode at `host`. The dictation the previous window shows
    /// is first turned into ordinary text of its draft, and voice forgets
    /// it; only then does the session move, with the semantics of a new
    /// target (the reading stops, the live-chat question and the queued
    /// announcements are dropped), so the previous window has no preview
    /// left to remove.
    private func activate(_ host: ZenWindowVoiceHost?) async {
        let previous = activeHost
        guard previous !== host else { return }
        if let previous, let id = await previous.endDictationForSwitch() {
            endDictation(through: id)
        }
        await session.setHost(host)
        sink.update(.activeWindow(host?.windowID))
    }

    /// A window ended the dictation it showed, through `id`: no window takes
    /// its previews any more, then voice forgets it.
    private func endDictation(through id: UInt64) {
        dictationFloor = max(dictationFloor, id)
        session.dictationEnded(through: id)
    }
}

/// A window as the host of the app's voice session. The window holds it
/// (the session holds it weakly) and it holds the window weakly. Its texts
/// become message rows, dictation goes to and from the window's draft
/// (``ZenWindowSession/draft``), and the controller's deliveries go into the
/// app's voice context (``ZenAppVoice``), never waiting.
@ChatSessionActor
final class ZenWindowVoiceHost: VoiceModeSessionHost {
    nonisolated let windowID: UUID
    nonisolated let window = ZenWeakWindow()
    nonisolated let sink: ZenVoiceRequestSink
    private weak var voice: ZenAppVoice?
    /// The turns of the window that run, as the voice context last heard
    /// (``ZenVoiceRequest/turnStarted(host:)``): a comment is read only
    /// while one does.
    var runningTurns = 0

    var isTurnRunning: Bool {
        runningTurns > 0
    }

    nonisolated init(windowID: UUID, voice: ZenAppVoice) {
        self.windowID = windowID
        self.sink = voice.sink
        self.voice = voice
    }

    /// Posts `request` into the app's voice context, without waiting.
    nonisolated func post(_ request: ZenVoiceRequest) {
        sink.post(request)
    }

    /// The instruction that goes out with a prompt of the window: voice
    /// mode's while it listens and the window is the active one, else `nil`.
    /// Asked for every request.
    func turnInstruction() async -> String? {
        guard let voice, voice.session.host === self else { return nil }
        return await voice.session.turnInstruction()
    }

    /// Turns the dictation the window shows into ordinary text; its id.
    func endDictationForSwitch() async -> UInt64? {
        await window.value?.endVoiceDictationForSwitch()
    }

    /// Puts `text`, an utterance taken from the window's draft, back there.
    func restoreUtterance(_ text: String) async {
        await window.value?.restoreVoiceUtterance(text)
    }

    // MARK: Texts

    func voiceModeShowSystemMessage(_ text: String) async {
        await window.value?.showVoiceMessage(text, isFailure: false)
    }

    func voiceModeShowFailureMessage(_ text: String) async {
        await window.value?.showVoiceMessage(text, isFailure: true)
    }

    // MARK: Lifecycle

    func voiceModeDidStart() async {
        await window.value?.voiceModeDidStart(ignoringDictationsThrough: voice?.dictationFloor ?? 0)
    }

    func voiceModeDidStop() async {
        // Nothing is read for this window any more.
        sink.update(.speaking(false))
        await window.value?.voiceModeDidStop()
    }

    // MARK: Dictation

    func voiceModeSubmitDictation(_ input: VoiceModeDictatedInput) async -> Bool {
        await window.value?.submitVoiceDictation(input)
        // A dictation never closes the window.
        return true
    }

    // MARK: Shared chat

    func voiceModeSharedChatParticipants() async -> [AgentSharedChat.Participant] {
        await window.value?.voiceSharedChatParticipants() ?? []
    }

    func voiceModeIsSharedChatMessageUnread(_ id: UUID) async -> Bool {
        await window.value?.isSharedChatMessageUnread(id) ?? true
    }

    func voiceModeMarkSharedChatMessageRead(_ id: UUID) async {
        await window.value?.markSharedChatMessageRead(id)
    }

    func voiceModeAdmitsInput() async -> Bool {
        await window.value?.admitsVoiceInput() ?? false
    }

    func voiceModeIsActiveSharedChatDestination(_ destination: AgentSharedChat.Destination) async -> Bool {
        await window.value?.isActiveSharedChatDestination(destination) ?? false
    }

    func voiceModeSendSharedChatMessage(_ text: String, to destination: AgentSharedChat.Destination) async -> Bool {
        await window.value?.sendVoiceSharedChatMessage(text, to: destination) ?? false
    }

    // MARK: From the controller's context

    nonisolated func voiceModeDictationChanged(id: UInt64, text: String) async {
        // Straight to the draft, not through the voice context: a preview
        // must reach the draft before the send that takes it, and it is
        // reported from inside `/voice pause` and `/voice off`, which the
        // context itself awaits.
        await window.value?.showVoiceDictation(id: id, text: text)
    }

    nonisolated func voiceModeTakeDictation(id: UInt64, text: String) async -> String? {
        await window.value?.takeVoiceDictation(id: id, text: text)
    }

    nonisolated func voiceModeDeliverUtterance(_ text: String) async {
        sink.post(.utterance(text, host: self))
    }

    nonisolated func voiceModeDeliverSpeakingChanged(_ isSpeaking: Bool) async {
        // Shown at once (Esc stops a reading), then handed to the session in
        // order; neither waits.
        sink.update(.speaking(isSpeaking))
        sink.post(.speakingChanged(isSpeaking))
    }

    nonisolated func voiceModeDeliverAnswerDeadline(_ token: UUID) async {
        sink.post(.answerDeadline(token))
    }
}

/// A weak reference to a window, readable from any context.
final class ZenWeakWindow: Sendable {
    private struct Reference {
        weak var window: ZenWindowSession?
    }

    private let reference = Mutex(Reference())

    var value: ZenWindowSession? {
        reference.withLock { $0.window }
    }

    func set(_ window: ZenWindowSession?) {
        reference.withLock { $0.window = window }
    }
}
