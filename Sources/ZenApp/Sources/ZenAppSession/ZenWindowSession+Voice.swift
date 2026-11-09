//
//  ZenWindowSession+Voice.swift
//  ZenApp
//
//  A window as the host of the app's voice mode: Esc, the dictation in the
//  draft, the dictated lines and prompts, and the room as voice reads it.
//

import Foundation
import ToolCore
import ZenCODECore

extension ZenWindowSession {
    // MARK: - Voice mode

    /// Esc of the window in the conversation, as the terminal's: it stops
    /// the line that runs, as ``stop()`` does, and, while voice mode follows
    /// this window, a reading aloud (an answer, a comment, a live-chat
    /// announcement) when voice reads or a line runs, dropping the live-chat
    /// question and the queued announcements. It never touches ``draft``.
    /// A consent sheet keeps its own Esc, which denies.
    public func handleEscape() {
        guard !isClosed else { return }
        let lineRuns = isLineRunning
        stop()
        if lineRuns || voiceState.isSpeaking {
            voiceHost.post(.interruptPlayback(host: voiceHost))
        }
    }

    /// A change of ``draft`` that the dictation did not make is an edit: the
    /// dictation shown becomes ordinary text and voice forgets what it
    /// collected for it, through the app's voice context, in the order of
    /// the switches of the active window (``ZenAppVoice/dictationFloor``).
    /// Moving the cursor changes nothing here.
    func draftDidChange(from oldValue: String) {
        guard !isApplyingVoiceDictation, draft != oldValue, let id = voiceDictation.end() else { return }
        voiceHost.post(.dictationEnded(through: id))
    }

    /// Applies `change` to ``draft`` and ``voiceDictation`` as the
    /// dictation's own change, not an edit, and records it for the cursor.
    private func applyVoiceDictation(
        _ change: (inout ZenVoiceDictationDraft, inout String) -> ZenVoiceDictationDraft.Change?
    ) {
        var dictation = voiceDictation
        var text = draft
        let applied = change(&dictation, &text)
        if dictation != voiceDictation {
            voiceDictation = dictation
        }
        guard let applied else { return }
        isApplyingVoiceDictation = true
        draft = text
        isApplyingVoiceDictation = false
        voiceDictationUpdate = ZenVoiceDictationUpdate(
            revision: (voiceDictationUpdate?.revision ?? 0) + 1,
            change: applied
        )
    }

    /// Voice mode started, or moved to this window: a fresh dictation,
    /// ignoring the ones up to `floor`, which a switch ended in the previous
    /// window and whose previews may still be on their way. (The window
    /// shows no dictation by then: a stop removed it, a switch ended it.)
    func voiceModeDidStart(ignoringDictationsThrough floor: UInt64) {
        guard !isClosed else { return }
        let fresh = ZenVoiceDictationDraft(endedThrough: floor)
        if voiceDictation != fresh {
            voiceDictation = fresh
        }
    }

    /// Voice mode stopped, or moved to another window: the preview leaves
    /// the draft, the typed text stays.
    func voiceModeDidStop() {
        guard !isClosed else { return }
        applyVoiceDictation { dictation, draft in
            dictation.remove(from: &draft) ? .removed : nil
        }
    }

    /// Shows `text` as the preview of dictation `id` (an empty text removes
    /// it).
    func showVoiceDictation(id: UInt64, text: String) {
        guard !isClosed else { return }
        applyVoiceDictation { dictation, draft in
            dictation.show(id: id, text: text, in: &draft)
        }
    }

    /// Voice sends dictation `id`: the whole draft, typed text then `text`,
    /// and the draft is cleared; `nil` once an edit or a switch ended the
    /// dictation. The prompt history does not record it.
    func takeVoiceDictation(id: UInt64, text: String) -> String? {
        guard !isClosed else { return nil }
        var taken: String?
        applyVoiceDictation { dictation, draft in
            let before = draft
            taken = dictation.take(id: id, text: text, from: &draft)
            return taken != nil && draft != before ? .taken : nil
        }
        return taken
    }

    /// Voice mode moves to another window: the dictation shown stays in the
    /// draft as ordinary text, as after an edit. Its id, for voice to forget
    /// it; `nil` when none was shown.
    func endVoiceDictationForSwitch() -> UInt64? {
        voiceDictation.end()
    }

    /// `text`, an utterance taken from this draft that voice mode could not
    /// send here any more (it moved to another window meanwhile), goes back
    /// to the draft as ordinary text, before what was typed since.
    func restoreVoiceUtterance(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isClosed, !text.isEmpty else { return }
        if draft.isEmpty {
            draft = text
        } else {
            draft = text + (draft.first?.isWhitespace == true ? "" : " ") + draft
        }
    }

    /// A text of voice mode, as a message row: a failure row for its
    /// failures.
    func showVoiceMessage(_ text: String, isFailure: Bool) async {
        await appendLocal(.local(text: Self.withoutTrailingNewlines(text), isFailure: isFailure))
    }

    /// Sends a dictated utterance by the voice rules: a line as if typed,
    /// without touching the draft or the history (a leading `@mention`
    /// sends a live message, a reply answers a pending `/plan` or `/goal`
    /// question, a prompt queues while a line runs, and a full queue refuses
    /// it with the typed text); text that would read as a command as a plain
    /// prompt, never as a command. While Telegram drives the slot both are
    /// refused with the dormant text.
    func submitVoiceDictation(_ input: VoiceModeDictatedInput) {
        guard !isClosed, !refusedWhileDormant() else { return }
        switch input {
        case let .line(text):
            let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { return }
            switch SharedChatMentionParser.parse(from: line, readableHandles: mentionHandles) {
            case let .route(mention):
                sendMention(mention, line: line)
            case .missingText:
                appendLocalNow(.local(text: Self.mentionMissingTextMessage, isFailure: true))
            case .none:
                route(line)
            }
        case let .plainPrompt(text):
            submitVoicePrompt(text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// A dictated plain prompt: it runs now, or waits in the queue while a
    /// line runs or lines wait; a full queue refuses it with the terminal's
    /// voice text.
    private func submitVoicePrompt(_ prompt: String) {
        guard !prompt.isEmpty else { return }
        guard isLineRunningOrWaiting else {
            startPlainPrompt(prompt)
            return
        }
        guard queuedLines.count < Self.queueCapacity else {
            appendLocalNow(.local(text: Self.voiceQueueFullMessage, isFailure: true))
            return
        }
        queuedLines.append(ZenQueuedLine(text: prompt, isPlainPrompt: true))
        drainQueueIfIdle()
        sharedChatConsumerStateDidChange()
    }

    func startPlainPrompt(_ prompt: String) {
        startExclusive { [weak self] stop in
            await self?.executePlainPrompt(prompt, stop: stop)
        }
    }

    /// The line of a plain prompt: a turn the operator typed, through the
    /// turn path alone (no command, no pending reply), as the terminal runs
    /// a dictated text that reads as a command. Refused while Telegram drives
    /// the slot: the host's admission would let a `/exit` or `/telegram off`
    /// through, so it is not asked.
    private func executePlainPrompt(_ prompt: String, stop: ZenLineStop) async {
        guard !isClosed else { return }
        guard !isDrivenFromTelegram, await !ZenWindowSteps.isDrivenFromTelegram(in: sessionHost, slotID: slotID) else {
            await appendLocal(.local(text: Self.dormantRefusalText, isFailure: true))
            return
        }
        guard let incarnation = await sessionHost.incarnation(in: slotID) else {
            await appendLocal(.local(text: Self.text(for: ChatSessionHostError.noSession), isFailure: true))
            return
        }
        guard !isClosed else { return }
        await runTurn(
            prompt: prompt,
            purpose: .normal,
            typedByOperator: true,
            stop: stop,
            controller: incarnation.controller
        )
        guard !isClosed else { return }
        if statusFactsAreStale {
            await refreshStatus()
        }
        refreshGitStatus()
    }

    /// The participants of the room the window observes, read now.
    func voiceSharedChatParticipants() async -> [AgentSharedChat.Participant] {
        guard !isClosed, let roomID = sharedChatObservation.roomID else { return [] }
        return await sessionHost.runner.sharedChatParticipants(rootSessionID: roomID)
    }

    /// Whether the message `id` is still unread in the reader.
    func isSharedChatMessageUnread(_ id: UUID) -> Bool {
        sharedChat.isUnread(id)
    }

    /// Voice mode read the message `id` aloud: it is read in the reader too,
    /// as if opened there.
    func markSharedChatMessageRead(_ id: UUID) {
        guard !isClosed else { return }
        updateSharedChat { $0.markRead(id) }
    }

    /// Whether voice input that is not a dictated line (a live message by
    /// voice) may act now: not while Telegram drives the slot, which is
    /// answered with the dormant text.
    func admitsVoiceInput() -> Bool {
        !isClosed && !refusedWhileDormant()
    }

    /// Whether `destination` still names an active recipient of the room of
    /// the session the slot runs now.
    func isActiveSharedChatDestination(_ destination: AgentSharedChat.Destination) async -> Bool {
        guard !isClosed, let roomID = await ZenSharedChatSteps.currentRoomID(in: sessionHost, slotID: slotID) else {
            return false
        }
        return await Self.isActiveDestination(destination, in: roomID, runner: sessionHost.runner)
    }

    /// A live message by voice, published as a typed mention is; the window
    /// shows why when the room did not take it. Returns whether it did.
    func sendVoiceSharedChatMessage(_ text: String, to destination: AgentSharedChat.Destination) async -> Bool {
        guard !isClosed else { return false }
        guard let failure = await deliver(text, to: destination) else { return true }
        appendLocalNow(.local(text: failure, isFailure: true))
        return false
    }
}
