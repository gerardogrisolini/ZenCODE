//
//  TerminalVoiceChatDialogueTests.swift
//  ZenCODECoreTests
//
//  The state machine of the spoken live-chat dialogue in voice mode.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Voice chat dialogue")
struct TerminalVoiceChatDialogueTests {
    private let roomID = "voice-room"

    private var operatorID: String {
        AgentSharedChat.operatorID(for: roomID)
    }

    private let coordinator = AgentSharedChat.Participant(
        id: "coordinator:voice-room",
        name: "Coordinator",
        kind: .coordinator
    )

    private let reviewer = AgentSharedChat.Participant(id: "agent-reviewer", name: "Reviewer", kind: .agent)
    private let builder = AgentSharedChat.Participant(id: "agent-builder", name: "Builder", kind: .agent)

    private func message(
        from sender: AgentSharedChat.Participant,
        to recipients: [String]? = nil,
        text: String = "Ho finito."
    ) -> AgentSharedChat.Message {
        AgentSharedChat.Message(
            roomID: roomID,
            sender: sender,
            recipientIDs: recipients ?? [operatorID],
            text: text
        )
    }

    private func operatorMessage() -> AgentSharedChat.Message {
        message(
            from: AgentSharedChat.Participant(id: operatorID, name: "operator", kind: .operator),
            to: [coordinator.id],
            text: "ciao"
        )
    }

    private func dialogueAsking(_ message: AgentSharedChat.Message) -> TerminalVoiceChatDialogue {
        var dialogue = TerminalVoiceChatDialogue()
        dialogue.enqueue([message])
        #expect(dialogue.beginAnnouncement(skipping: { _ in false })?.message == message)
        return dialogue
    }

    // MARK: - Queue

    @Test
    func onlyMessagesForTheOperatorFromAgentsOrTheCoordinatorAreAnnounceable() {
        #expect(TerminalVoiceChatDialogue.isAnnounceable(message(from: reviewer)))
        #expect(TerminalVoiceChatDialogue.isAnnounceable(message(from: coordinator)))
        #expect(TerminalVoiceChatDialogue.isAnnounceable(message(from: reviewer, to: [coordinator.id, operatorID])))
        #expect(!TerminalVoiceChatDialogue.isAnnounceable(message(from: reviewer, to: [coordinator.id])))
        #expect(!TerminalVoiceChatDialogue.isAnnounceable(message(from: coordinator, to: [reviewer.id])))
        #expect(!TerminalVoiceChatDialogue.isAnnounceable(operatorMessage()))
    }

    @Test
    func announcementsFollowArrivalOrderAndCountTheRest() {
        let first = message(from: reviewer)
        let second = message(from: coordinator)
        let third = message(from: builder)
        var dialogue = TerminalVoiceChatDialogue()
        dialogue.enqueue([first, operatorMessage(), message(from: reviewer, to: [coordinator.id]), second])
        dialogue.enqueue([second, third, first])
        #expect(dialogue.pending.map(\.id) == [first.id, second.id, third.id])

        let announced = dialogue.beginAnnouncement(skipping: { _ in false })
        #expect(announced?.message == first)
        #expect(announced?.remaining == 2)
        #expect(dialogue.phase == .askingToRead(first))
        // A new announcement waits until the dialogue is idle again.
        #expect(dialogue.beginAnnouncement(skipping: { _ in false }) == nil)
        // The current message is not queued twice by a replay.
        dialogue.enqueue([first])
        #expect(dialogue.pending.map(\.id) == [second.id, third.id])
    }

    @Test
    func messagesAlreadyReadInTheDockAreSkipped() {
        let read = message(from: reviewer)
        let unread = message(from: builder)
        var dialogue = TerminalVoiceChatDialogue()
        dialogue.enqueue([read, unread])
        let announced = dialogue.beginAnnouncement(skipping: { $0 == read.id })
        #expect(announced?.message == unread)
        #expect(announced?.remaining == 0)

        var empty = TerminalVoiceChatDialogue()
        empty.enqueue([read])
        #expect(empty.beginAnnouncement(skipping: { _ in true }) == nil)
        #expect(empty.phase == .idle)
    }

    @Test
    func theQueueDropsTheOldestPastItsLimit() {
        var dialogue = TerminalVoiceChatDialogue()
        let messages = (0..<(TerminalVoiceChatDialogue.maximumPendingAnnouncements + 3)).map { index in
            message(from: reviewer, text: "message \(index)")
        }
        dialogue.enqueue(messages)
        #expect(dialogue.pending.count == TerminalVoiceChatDialogue.maximumPendingAnnouncements)
        #expect(dialogue.pending.first?.text == "message 3")
        #expect(dialogue.pending.last?.text == "message \(messages.count - 1)")
    }

    @Test
    func anUnspokenAnnouncementReturnsToTheHeadOfTheQueue() {
        let first = message(from: reviewer)
        let second = message(from: builder)
        var dialogue = TerminalVoiceChatDialogue()
        dialogue.enqueue([first, second])
        _ = dialogue.beginAnnouncement(skipping: { _ in false })
        dialogue.announcementNotSpoken()
        #expect(dialogue.phase == .idle)
        #expect(dialogue.pending.map(\.id) == [first.id, second.id])
    }

    // MARK: - Answers

    @Test
    func yesReadsTheMessageAndASecondYesAsksForTheReply() throws {
        let incoming = message(from: reviewer)
        var dialogue = dialogueAsking(incoming)
        #expect(dialogue.interpret("Sì.", participants: [reviewer]) == .read(incoming))
        #expect(dialogue.phase == .reading(incoming))

        let transition = dialogue.speechEnded()
        let token = try #require(dialogue.deadlineToken)
        #expect(transition == .armDeadline(token))
        #expect(dialogue.phase == .askingToReply(incoming))

        #expect(dialogue.interpret("yes", participants: [reviewer]) == .askReplyText(incoming))
        #expect(dialogue.phase == .awaitingReplyText(incoming))

        #expect(
            dialogue.interpret("  Bene, procedi. ", participants: [reviewer])
                == .send(destination: .direct([reviewer.id]), text: "Bene, procedi.", label: "Reviewer")
        )
        #expect(dialogue.phase == .idle)
    }

    @Test
    func aReplyToTheCoordinatorTargetsTheCoordinatorDestination() {
        let incoming = message(from: coordinator)
        var dialogue = dialogueAsking(incoming)
        _ = dialogue.interpret("ok", participants: [])
        _ = dialogue.speechEnded()
        _ = dialogue.interpret("ja", participants: [])
        #expect(
            dialogue.interpret("Fermati.", participants: [])
                == .send(destination: .coordinator, text: "Fermati.", label: "Coordinator")
        )
    }

    @Test
    func noDeclinesTheReadingOrTheReply() {
        let incoming = message(from: reviewer)
        var dialogue = dialogueAsking(incoming)
        #expect(dialogue.interpret("No", participants: []) == .declined)
        #expect(dialogue.phase == .idle)

        var replying = dialogueAsking(incoming)
        _ = replying.interpret("sì", participants: [])
        _ = replying.speechEnded()
        #expect(replying.interpret("non ora", participants: []) == .skip)
        #expect(replying.phase == .idle)
    }

    /// The reading ends with "Do you want to reply?": a yes or no heard while
    /// the message is still being read answers that question, instead of
    /// reading the message again from the start.
    @Test
    func anAnswerDuringTheReadingAnswersTheReplyQuestion() {
        let incoming = message(from: reviewer)
        var dialogue = dialogueAsking(incoming)
        _ = dialogue.interpret("sì", participants: [])
        #expect(dialogue.phase == .reading(incoming))
        #expect(dialogue.interpret("sì", participants: []) == .askReplyText(incoming))
        #expect(dialogue.phase == .awaitingReplyText(incoming))

        var declining = dialogueAsking(incoming)
        _ = declining.interpret("sì", participants: [])
        #expect(declining.interpret("no", participants: []) == .skip)
        #expect(declining.phase == .idle)
    }

    @Test
    func anythingElseClosesTheQuestionAndIsHandledAsFromIdle() {
        let incoming = message(from: reviewer)
        var dialogue = dialogueAsking(incoming)
        #expect(dialogue.interpret("Che ore sono?", participants: []) == .prompt)
        #expect(dialogue.phase == .idle)
        #expect(dialogue.pending.isEmpty)

        var sending = dialogueAsking(incoming)
        _ = sending.interpret("sì", participants: [])
        _ = sending.speechEnded()
        #expect(
            sending.interpret("messaggio al coordinatore: fermati", participants: [])
                == .send(destination: .coordinator, text: "fermati", label: "coordinator")
        )
        #expect(sending.phase == .idle)
    }

    @Test
    func sendPhrasesFromIdleResolveTheirRecipient() {
        var dialogue = TerminalVoiceChatDialogue()
        #expect(dialogue.interpret("Che ore sono?", participants: [reviewer]) == .prompt)
        #expect(
            dialogue.interpret("message to all: pause", participants: [reviewer])
                == .send(destination: .all, text: "pause", label: "all")
        )
        #expect(
            dialogue.interpret("messaggio a Reviewer: controlla", participants: [reviewer, builder])
                == .send(destination: .direct([reviewer.id]), text: "controlla", label: "Reviewer")
        )
        #expect(dialogue.interpret("messaggio a Anna: ciao", participants: [reviewer]) == .unknownAgent("Anna"))
        // Nothing usable after the preposition is an ordinary prompt.
        #expect(dialogue.interpret("messaggio a : ciao", participants: [reviewer]) == .prompt)
        #expect(dialogue.phase == .idle)
    }

    @Test
    func sendPhrasesWithoutTextAskForItAndTheNextUtteranceIsTheText() throws {
        var dialogue = TerminalVoiceChatDialogue()
        #expect(
            dialogue.interpret("messaggio a tutti", participants: [])
                == .askMessageText(destination: .all, label: "all")
        )
        #expect(dialogue.phase == .awaitingMessageText(destination: .all, label: "all"))
        let transition = dialogue.speechEnded()
        let token = try #require(dialogue.deadlineToken)
        #expect(transition == .armDeadline(token))
        #expect(
            dialogue.interpret("Pausa di dieci minuti.", participants: [])
                == .send(destination: .all, text: "Pausa di dieci minuti.", label: "all")
        )
        #expect(dialogue.phase == .idle)

        #expect(
            dialogue.interpret("messaggio a Builder", participants: [builder])
                == .askMessageText(destination: .direct([builder.id]), label: "Builder")
        )
        #expect(
            dialogue.interpret("no", participants: [builder])
                == .send(destination: .direct([builder.id]), text: "no", label: "Builder")
        )
    }

    // MARK: - Speech end, deadlines, preemption

    @Test
    func speechEndArmsADeadlineForEveryQuestionAndAnnouncesWhenIdle() {
        let incoming = message(from: reviewer)
        var idle = TerminalVoiceChatDialogue()
        #expect(idle.speechEnded() == .announceNext)
        #expect(idle.deadlineToken == nil)

        var asking = dialogueAsking(incoming)
        guard case let .armDeadline(first) = asking.speechEnded() else {
            Issue.record("A spoken announcement must wait for its answer.")
            return
        }
        #expect(asking.deadlineToken == first)
        #expect(asking.phase == .askingToRead(incoming))

        _ = asking.interpret("sì", participants: [])
        #expect(asking.deadlineToken == nil)
        guard case let .armDeadline(second) = asking.speechEnded() else {
            Issue.record("A finished reading must ask whether to reply.")
            return
        }
        #expect(second != first)
        #expect(asking.phase == .askingToReply(incoming))

        _ = asking.interpret("sì", participants: [])
        guard case .armDeadline = asking.speechEnded() else {
            Issue.record("The reply request must wait for the reply.")
            return
        }
        #expect(asking.phase == .awaitingReplyText(incoming))
    }

    @Test
    func onlyTheCurrentDeadlineLapsesTheQuestion() {
        let incoming = message(from: reviewer)
        var dialogue = dialogueAsking(incoming)
        guard case let .armDeadline(stale) = dialogue.speechEnded() else {
            Issue.record("Expected a deadline.")
            return
        }
        _ = dialogue.interpret("sì", participants: [])
        guard case let .armDeadline(current) = dialogue.speechEnded() else {
            Issue.record("Expected a deadline.")
            return
        }
        let staleLapsed = dialogue.deadlineElapsed(stale)
        #expect(!staleLapsed)
        #expect(dialogue.phase == .askingToReply(incoming))
        let currentLapsed = dialogue.deadlineElapsed(current)
        #expect(currentLapsed)
        #expect(dialogue.phase == .idle)
        #expect(dialogue.pending.isEmpty)
        let lapsedAgain = dialogue.deadlineElapsed(current)
        #expect(!lapsedAgain)
    }

    @Test
    func anAnswerBeingReadPreemptsTheDialogueAndRequeuesAnUnreadMessage() {
        let first = message(from: reviewer)
        let second = message(from: builder)
        var dialogue = TerminalVoiceChatDialogue()
        dialogue.enqueue([first, second])
        _ = dialogue.beginAnnouncement(skipping: { _ in false })
        _ = dialogue.speechEnded()
        dialogue.answerReadingStarted()
        #expect(dialogue.phase == .idle)
        #expect(dialogue.deadlineToken == nil)
        #expect(dialogue.pending.map(\.id) == [first.id, second.id])
        #expect(dialogue.speechEnded() == .announceNext)
        #expect(dialogue.beginAnnouncement(skipping: { _ in false })?.message == first)

        // A message already read is not announced again; its reply question
        // cannot be repeated silently.
        var reading = dialogueAsking(first)
        _ = reading.interpret("sì", participants: [])
        reading.answerReadingStarted()
        #expect(reading.phase == .idle)
        #expect(reading.pending.isEmpty)

        var askingToReply = dialogueAsking(first)
        _ = askingToReply.interpret("sì", participants: [])
        _ = askingToReply.speechEnded()
        askingToReply.answerReadingStarted()
        #expect(askingToReply.phase == .idle)
        #expect(askingToReply.pending.isEmpty)

        // A text already asked for is still awaited once the answer is over.
        var awaitingReply = dialogueAsking(first)
        _ = awaitingReply.interpret("sì", participants: [])
        _ = awaitingReply.speechEnded()
        _ = awaitingReply.interpret("sì", participants: [])
        _ = awaitingReply.speechEnded()
        awaitingReply.answerReadingStarted()
        #expect(awaitingReply.phase == .awaitingReplyText(first))
        #expect(awaitingReply.deadlineToken == nil)
        guard case .armDeadline = awaitingReply.speechEnded() else {
            Issue.record("The reply is still awaited after the answer.")
            return
        }
        #expect(
            awaitingReply.interpret("Procedi.", participants: [])
                == .send(destination: .direct([reviewer.id]), text: "Procedi.", label: "Reviewer")
        )

        var waitingForText = TerminalVoiceChatDialogue()
        _ = waitingForText.interpret("messaggio a tutti", participants: [])
        waitingForText.answerReadingStarted()
        #expect(waitingForText.phase == .awaitingMessageText(destination: .all, label: "all"))
        #expect(waitingForText.pending.isEmpty)
    }

    @Test
    func cancellingClearsTheQueueAndTheQuestion() {
        var dialogue = TerminalVoiceChatDialogue()
        dialogue.enqueue([message(from: reviewer), message(from: builder)])
        _ = dialogue.beginAnnouncement(skipping: { _ in false })
        _ = dialogue.speechEnded()
        dialogue.cancelAll()
        #expect(dialogue.phase == .idle)
        #expect(dialogue.pending.isEmpty)
        #expect(dialogue.deadlineToken == nil)
        #expect(dialogue.beginAnnouncement(skipping: { _ in false }) == nil)
    }
}
