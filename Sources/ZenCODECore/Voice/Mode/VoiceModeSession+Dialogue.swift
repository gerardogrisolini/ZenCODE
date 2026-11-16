//
//  VoiceModeSession+Dialogue.swift
//  ZenCODE
//
//  What voice mode reads aloud and hears: the answers and comments read
//  aloud, the events the host reports, and the spoken dialogue over the live
//  shared chat.
//

import Foundation
import Synchronization

extension VoiceModeSession {
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
        // A late report of a stopped controller changes nothing.
        if controller != nil {
            facts.isSpeaking = isSpeaking
            publishState()
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
    /// A bare yes or no that arrives while the answer that replaced its
    /// question is being read is dropped.
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
        case .strayAnswer:
            // Said to a question the answer being read has replaced: it is
            // never sent to the model, and a requeued message is announced
            // again once the answer is over.
            break
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
    func cancelDialogue() async {
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
    func cancelDeadline() {
        deadlineTask?.cancel()
        deadlineTask = nil
    }
}
