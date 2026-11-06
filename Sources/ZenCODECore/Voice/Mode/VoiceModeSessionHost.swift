//
//  VoiceModeSessionHost.swift
//  ZenCODE
//
//  What a channel does for the voice mode coordinator (`VoiceModeSession`):
//  it shows the session's texts, owns the prompt draft and the shared-chat
//  reader, sends what was dictated by its own rules, and carries the
//  controller's events into its serialized context. The terminal and a host
//  app implement it; nothing here is persisted.
//

import Foundation

/// The channel a ``VoiceModeSession`` speaks for: the terminal, or the active
/// window of a host app. The session calls the isolated requirements on the
/// chat actor and awaits them, so each one returns quickly, like a
/// presenter call.
///
/// The `nonisolated` requirements are called from the voice controller's own
/// context, also while the channel awaits the controller (a preview and the
/// end of a reading are reported from inside `/voice pause` and
/// `/voice off`): they never wait on the channel's serialized context. The
/// three `voiceModeDeliver…` requirements put their event in that context, in
/// order (the terminal uses its event FIFO), and the channel then hands it
/// back to the session from there with
/// ``VoiceModeSession/handleUtterance(_:)``,
/// ``VoiceModeSession/speakingChanged(_:)``, or
/// ``VoiceModeSession/answerDeadlineElapsed(_:)``.
@ChatSessionActor
public protocol VoiceModeSessionHost: AnyObject, Sendable {
    // MARK: Texts

    /// Shows a notice of voice mode, e.g. `Voice: off.` or the controller's
    /// `Voice: listening …`. The text ends with a newline.
    func voiceModeShowSystemMessage(_ text: String) async
    /// Shows a failure of voice mode, e.g. that it is off or cannot run here.
    /// The text ends with a newline.
    func voiceModeShowFailureMessage(_ text: String) async

    // MARK: Lifecycle

    /// Voice mode started on this host, or this host became the session's
    /// host while it runs: dictation previews and sends reach it from now on,
    /// and it reports the end of an edited dictation with
    /// ``VoiceModeSession/dictationEnded(through:)``.
    func voiceModeDidStart() async
    /// Voice mode stopped, or this host stopped being the session's host
    /// while it ran: drop the dictation preview shown in the draft, keeping
    /// the typed text, and show that nothing is being read.
    func voiceModeDidStop() async

    // MARK: Dictation

    /// Sends a dictated utterance that is not part of the live-chat dialogue,
    /// by the channel's own rules: a ``VoiceModeDictatedInput/line(_:)`` as
    /// if typed (it answers a pending question, queues while a turn runs, an
    /// `@mention` sends a live message), a
    /// ``VoiceModeDictatedInput/plainPrompt(_:)`` as a prompt and never as a
    /// command. Admission (e.g. while Telegram drives the slot) and the
    /// prompt queue are the channel's. Returns `false` when the channel ends
    /// because of it, as the terminal does for a line that exits.
    func voiceModeSubmitDictation(_ input: VoiceModeDictatedInput) async -> Bool

    // MARK: Shared chat

    /// The participants of the room the channel shows, matched against the
    /// agent names of a "message to …" phrase.
    func voiceModeSharedChatParticipants() async -> [AgentSharedChat.Participant]
    /// Whether the message is still unread in the channel's shared-chat
    /// reader: a message read there meanwhile is not announced.
    func voiceModeIsSharedChatMessageUnread(_ id: UUID) async -> Bool
    /// The message was read aloud: mark it read in the reader, exactly like
    /// opening it there, and refresh the reader.
    func voiceModeMarkSharedChatMessageRead(_ id: UUID) async
    /// Whether the channel may act now on voice input that is not a dictated
    /// line, a live message by voice: the terminal refuses it while Telegram
    /// drives its slot. A refused input is answered by the channel.
    func voiceModeAdmitsInput() async -> Bool
    /// Whether `destination` still names an active recipient. When it does
    /// not, the session shows that the agent is no longer active and says so
    /// aloud.
    func voiceModeIsActiveSharedChatDestination(
        _ destination: AgentSharedChat.Destination
    ) async -> Bool
    /// Publishes a live message of the operator, as a typed mention would.
    /// Returns whether the room accepted it; the channel shows the reason of
    /// a failure.
    func voiceModeSendSharedChatMessage(
        _ text: String,
        to destination: AgentSharedChat.Destination
    ) async -> Bool

    // MARK: From the controller's context

    /// Shows `text` as the preview of dictation `id` at the end of the
    /// draft, after the typed text; an empty text removes it. Ignored once an
    /// edit ended `id`.
    nonisolated func voiceModeDictationChanged(id: UInt64, text: String) async
    /// Dictation `id` is sent with its final `text`: returns the whole draft
    /// to send (typed text, then `text`) and clears it, or `nil` when an
    /// edit already ended the dictation.
    nonisolated func voiceModeTakeDictation(id: UInt64, text: String) async -> String?
    /// A recognized utterance, never blank. Put it in the serialized context
    /// and hand it to ``VoiceModeSession/handleUtterance(_:)`` from there;
    /// it may wait for room, since it is never reported while the channel
    /// awaits the controller.
    nonisolated func voiceModeDeliverUtterance(_ text: String) async
    /// The controller started (`true`) or stopped (`false`) reading aloud:
    /// show it at once (the terminal's `Esc` stops a reading), then hand it
    /// to ``VoiceModeSession/speakingChanged(_:)`` from the serialized
    /// context. Reported from inside calls the channel awaits, so it must not
    /// wait for room there: the terminal offers the event and retries a full
    /// FIFO from a task of its own.
    nonisolated func voiceModeDeliverSpeakingChanged(_ isSpeaking: Bool) async
    /// A spoken live-chat question waited ``VoiceModeSession/answerTimeout``
    /// for its answer: hand `token` to
    /// ``VoiceModeSession/answerDeadlineElapsed(_:)`` from the serialized
    /// context. Called from a task of the session.
    nonisolated func voiceModeDeliverAnswerDeadline(_ token: UUID) async
}

/// How a dictated utterance outside the live-chat dialogue is sent.
public enum VoiceModeDictatedInput: Sendable, Equatable {
    /// Sent as if typed in the draft.
    case line(String)
    /// Text that would read as a slash command: sent as a plain prompt, so
    /// dictation never runs a command.
    case plainPrompt(String)

    /// Classifies `utterance`: text that starts with `/` is a plain prompt,
    /// anything else a line.
    public init(utterance: String) {
        if utterance.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("/") {
            self = .plainPrompt(utterance)
        } else {
            self = .line(utterance)
        }
    }
}

/// What a ``VoiceModeSession`` is doing, for a status bar and for `Esc`.
public struct VoiceModeSessionState: Sendable, Equatable {
    /// A controller runs: `/voice on` started it and it neither stopped nor
    /// failed.
    public var isOn: Bool
    /// Voice mode is on but neither listens nor reads aloud.
    public var isPaused: Bool
    /// Something is being read aloud, as the controller reported it through
    /// ``VoiceModeSession/speakingChanged(_:)``: `Esc` stops it.
    public var isSpeaking: Bool

    public static let off = VoiceModeSessionState(isOn: false, isPaused: false, isSpeaking: false)

    public init(isOn: Bool, isPaused: Bool, isSpeaking: Bool) {
        self.isOn = isOn
        self.isPaused = isPaused
        self.isSpeaking = isSpeaking
    }
}
