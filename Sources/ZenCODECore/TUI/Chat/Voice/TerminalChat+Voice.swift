//
//  TerminalChat+Voice.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/09/26.
//
//  The terminal's voice mode: `VoiceModeSession` coordinates it as in every
//  channel, and `TerminalVoiceModeHost` is its host here (the terminal's
//  texts, the prompt draft of the interactive reader, the panel loop's FIFO).
//

import Foundation
import Synchronization

extension TerminalChat {
    static let voiceOffMessage = VoiceModeSession.offMessage
    static let voiceRequiresInteractiveTerminalMessage = "ZenCODE: /voice is available only in the interactive terminal.\n"
    /// Sent to the model with every prompt while voice mode listens (see
    /// ``voiceTurnInstruction()``).
    static let voiceTurnInstruction = VoiceModeSession.turnInstructionText

    /// The controller of the voice session; settable by tests, which install
    /// a controller without starting it.
    var voiceController: (any VoiceModeController)? {
        get { voiceSession.controller }
        set { voiceSession.controller = newValue }
    }

    /// Event queue of the running interactive panel loop; `nil` outside it,
    /// where voice mode cannot run.
    var voiceEventQueue: TerminalChatEventQueue? {
        get { voiceModeHost.eventQueue }
        set { voiceModeHost.eventQueue = newValue }
    }

    /// How long a spoken question waits for its answer. Mutable so tests can
    /// shorten it.
    var voiceDialogueAnswerTimeout: Duration {
        get { voiceSession.answerTimeout }
        set { voiceSession.answerTimeout = newValue }
    }

    /// `/voice [on|off|pause|resume]`. Voice mode is independent of the active
    /// agent, survives agent and session switches, and lasts only for this TUI
    /// session.
    func handleVoiceCommand(_ command: String) async {
        // Voice mode feeds the panel loop's FIFO: outside the loop
        // `/voice on` never reaches the microphone or speech recognition.
        if VoiceModeSession.commandAction(for: command) == .turnOn,
           voiceEventQueue == nil,
           await voiceSession.activeController() == nil {
            await writeFailureMessage(Self.voiceRequiresInteractiveTerminalMessage)
            return
        }
        await voiceSession.handleCommand(command)
    }

    /// The instruction that goes out with a prompt (see
    /// ``VoiceModeSession/turnInstruction()``). The runtime merges it into
    /// the outgoing copy of the user message only (see
    /// ``AgentTurnInstructionContext``): it never enters history or snapshots.
    func voiceTurnInstruction() async -> String? {
        await voiceSession.turnInstruction()
    }

    func stopVoiceMode() async {
        await voiceSession.stop()
    }

    /// Offers the runtime loop a comment the root agent wrote before a tool
    /// call, to be read aloud. The loop reads it only while the turn runs,
    /// nothing else is being read and no live-chat question is in progress
    /// (see ``VoiceModeSession/speakCommentary(_:duringTurn:)``); otherwise
    /// the comment is dropped and stays on screen only.
    ///
    /// Not `async` and non-blocking on purpose: generation must never wait on
    /// the terminal FIFO. `offer` is used instead of a backpressure send, so a
    /// full queue simply drops the comment, like any other comment that cannot
    /// be read right away. Does nothing without a voice controller or an
    /// interactive panel loop, or for a blank comment.
    func offerVoiceCommentary(_ text: String) {
        guard voiceController != nil,
              let voiceEventQueue,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        _ = voiceEventQueue.offer(.voiceCommentary(text))
    }

    /// Stops the answer being read aloud, e.g. after Esc (see
    /// ``VoiceModeSession/interruptPlayback()``).
    func interruptVoicePlayback() async {
        await voiceSession.interruptPlayback()
    }

    /// A dictated utterance that is not part of the live-chat dialogue is
    /// handled like a typed line, so it also answers a pending plan or
    /// workflow question and queues while a turn runs. Text that would read
    /// as a slash command is always sent as a plain prompt (see
    /// ``VoiceModeDictatedInput``).
    nonisolated static func dictatedPromptEvent(for utterance: String) -> TerminalChatRuntimeEvent {
        dictatedPromptEvent(for: VoiceModeDictatedInput(utterance: utterance))
    }

    nonisolated static func dictatedPromptEvent(for input: VoiceModeDictatedInput) -> TerminalChatRuntimeEvent {
        switch input {
        case let .plainPrompt(prompt):
            .voicePromptCompleted(
                TerminalVoicePromptResult(origin: .local, outcome: .success(prompt))
            )
        case let .line(line):
            .input(.submitted(line))
        }
    }
}

/// The terminal as the host of its ``VoiceModeSession``: texts are written
/// like every command's, previews and sends go straight to the interactive
/// reader's draft, and the controller's events reach the panel loop through
/// its FIFO, whose single consumer hands them back to the session in order.
/// What only the running loop knows (the observed room, the shared-chat
/// reader, how a typed line runs) is installed in ``loop`` while it runs.
@ChatSessionActor
final class TerminalVoiceModeHost: VoiceModeSessionHost {
    /// The panel loop's side of the host.
    struct LoopBindings {
        /// The participants of the room the loop observes.
        let participants: () async -> [AgentSharedChat.Participant]
        let isUnread: (UUID) -> Bool
        /// Marks a message read aloud as read and repaints the dock.
        let markRead: (UUID) async -> Void
        /// Handles a dictated line like a typed one; `false` ends the loop.
        let submitLine: (String) async -> Bool
        let submitPrompt: (TerminalVoicePromptResult) async -> Void
    }

    weak var chat: TerminalChat?
    weak var session: VoiceModeSession?
    var loop: LoopBindings?
    nonisolated let reader: TerminalInteractiveLineReader
    private nonisolated let eventQueueStorage = Mutex<TerminalChatEventQueue?>(nil)

    init(reader: TerminalInteractiveLineReader) {
        self.reader = reader
    }

    /// The FIFO of the running panel loop; `nil` outside it.
    nonisolated var eventQueue: TerminalChatEventQueue? {
        get { eventQueueStorage.withLock { $0 } }
        set { eventQueueStorage.withLock { $0 = newValue } }
    }

    // MARK: Texts

    func voiceModeShowSystemMessage(_ text: String) async {
        await chat?.writeSystemMessage(text)
    }

    func voiceModeShowFailureMessage(_ text: String) async {
        await chat?.writeFailureMessage(text)
    }

    // MARK: Lifecycle

    func voiceModeDidStart() async {
        // An edit that turns the dictation shown in the draft into ordinary
        // text makes voice forget what it accumulated for it.
        reader.setVoiceDictationEndedHandler { [weak session = self.session] id in
            session?.dictationEnded(through: id)
        }
    }

    func voiceModeDidStop() async {
        reader.setVoiceDictationEndedHandler(nil)
        await reader.setPanelSpeaking(false)
    }

    // MARK: Dictation

    func voiceModeSubmitDictation(_ input: VoiceModeDictatedInput) async -> Bool {
        guard let loop else { return true }
        switch TerminalChat.dictatedPromptEvent(for: input) {
        case let .input(.submitted(line)):
            return await loop.submitLine(line)
        case let .voicePromptCompleted(result):
            await loop.submitPrompt(result)
        default:
            break
        }
        return true
    }

    // MARK: Shared chat

    func voiceModeSharedChatParticipants() async -> [AgentSharedChat.Participant] {
        await loop?.participants() ?? []
    }

    func voiceModeIsSharedChatMessageUnread(_ id: UUID) async -> Bool {
        loop?.isUnread(id) ?? true
    }

    func voiceModeMarkSharedChatMessageRead(_ id: UUID) async {
        await loop?.markRead(id)
    }

    func voiceModeAdmitsInput() async -> Bool {
        await chat?.admitTerminalInput() ?? false
    }

    func voiceModeIsActiveSharedChatDestination(
        _ destination: AgentSharedChat.Destination
    ) async -> Bool {
        await chat?.isCurrentSharedChatDirectDestination(destination) ?? false
    }

    func voiceModeSendSharedChatMessage(
        _ text: String,
        to destination: AgentSharedChat.Destination
    ) async -> Bool {
        await chat?.sendSharedChatMention(
            TerminalChat.SharedChatMentionRoute(destination: destination, text: text)
        ) ?? false
    }

    // MARK: From the controller's context

    nonisolated func voiceModeDictationChanged(id: UInt64, text: String) async {
        // Straight to the reader, not through the event queue: a preview
        // must reach the draft before the send that takes it, and it is
        // reported from inside `setPaused` and `stop`, which the runtime loop
        // itself awaits, so waiting for a full queue could block its only
        // consumer.
        reader.setVoiceDictation(id: id, text: text)
    }

    nonisolated func voiceModeTakeDictation(id: UInt64, text: String) async -> String? {
        reader.takeVoiceDictation(id: id, text: text)
    }

    nonisolated func voiceModeDeliverUtterance(_ text: String) async {
        guard let eventQueue else { return }
        _ = await eventQueue.sendWithBackpressure(.voiceUtterance(text))
    }

    nonisolated func voiceModeDeliverSpeakingChanged(_ isSpeaking: Bool) async {
        await reader.setPanelSpeaking(isSpeaking)
        guard let eventQueue else { return }
        // Reported from inside `speak`, `interruptPlayback`, `setPaused` and
        // `stop`, which the runtime loop itself awaits: waiting here for a
        // full queue would block its only consumer. Only a full queue is
        // retried, from a task of its own.
        if eventQueue.offer(.voiceSpeakingChanged(isSpeaking)) == .rejectedFull {
            Task(name: "ZenCODE.TUI.voice-speaking-changed") {
                _ = await eventQueue.sendWithBackpressure(.voiceSpeakingChanged(isSpeaking))
            }
        }
    }

    nonisolated func voiceModeDeliverAnswerDeadline(_ token: UUID) async {
        guard let eventQueue else { return }
        _ = await eventQueue.sendWithBackpressure(.voiceDialogueTimedOut(token))
    }
}
