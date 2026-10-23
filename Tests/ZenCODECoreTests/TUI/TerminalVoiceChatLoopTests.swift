//
//  TerminalVoiceChatLoopTests.swift
//  ZenCODECoreTests
//
//  Drives the production panel FIFO with a fake voice controller: live
//  shared-chat messages for the operator are announced, read on a yes,
//  answered on a second yes, and "message to …" phrases send without a
//  generation. Nothing here touches audio or a model.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@TerminalChatActor
@Suite
struct TerminalVoiceChatLoopTests {
    private typealias Spoken = FakeVoiceController.Spoken

    /// A long message: well past the 600-character limit of spoken answers.
    private static let longText = String(
        repeating: "Ho rivisto il modulo e ogni test passa. ",
        count: 20
    ).trimmingCharacters(in: .whitespaces)

    @TerminalChatActor
    private final class Harness {
        let terminal: TerminalChat
        let queue = TerminalChatEventQueue()
        let voice = FakeVoiceController()
        let recorder = LoopRecorder()
        let generationGate = VoiceLoopTestGate()
        let coordinator: AgentSharedChat.Participant
        let reviewer = AgentSharedChat.Participant(id: "agent-reviewer", name: "Reviewer", kind: .agent)
        let builder = AgentSharedChat.Participant(id: "agent-builder", name: "Builder", kind: .agent)

        init(
            publicationsSucceed: Bool = true,
            holdGenerations: Bool = false,
            answerText: String = "Risposta."
        ) throws {
            terminal = TerminalChat(
                configuration: try AgentConfiguration(
                    hostedModelID: "remote-community/test",
                    availableAgents: AgentProfileStore.defaultProfiles(),
                    workingDirectory: URL(
                        fileURLWithPath: "/tmp/voice-chat-loop-\(UUID().uuidString)",
                        isDirectory: true
                    )
                ),
                stdinIsTerminal: false
            )
            coordinator = AgentSharedChat.Participant(
                id: "coordinator:\(terminal.sessionID)",
                name: "Coordinator",
                kind: .coordinator
            )
            terminal.interactiveRuntimeEventQueueForTesting = queue
            terminal.bypassInteractivePanelInputForTesting = true
            terminal.voiceController = voice
            let recorder = recorder
            terminal.onTelegramWorkEffectForTesting = { effect in
                guard case .sharedChatPublication = effect else { return false }
                recorder.recordPublication()
                return publicationsSucceed
            }
            let gate = generationGate
            terminal.onGenerateResponseForTesting = { attempt in
                recorder.recordPrompt(attempt.prompt)
                if holdGenerations {
                    await gate.enterAndWait()
                }
                return TerminalChatGenerationSuccess(
                    response: DirectAgentResponse(text: answerText, stopReason: "stop", modelID: "test"),
                    origin: attempt.origin,
                    fileChangeSummary: nil,
                    automaticallyCompletedPlan: nil,
                    finalAssistantContent: answerText
                )
            }
        }

        var operatorID: String {
            AgentSharedChat.operatorID(for: terminal.sessionID)
        }

        func message(
            from sender: AgentSharedChat.Participant,
            to recipients: [String]? = nil,
            text: String = "Ho finito."
        ) -> AgentSharedChat.Message {
            AgentSharedChat.Message(
                roomID: terminal.sessionID,
                sender: sender,
                recipientIDs: recipients ?? [operatorID],
                text: text
            )
        }

        func deliver(_ messages: [AgentSharedChat.Message]) {
            queue.send(.sharedChatMessages(roomID: terminal.sessionID, messages: messages))
        }

        /// The same message as the room would replay it: sent before the
        /// observation started.
        func replayed(_ message: AgentSharedChat.Message, secondsAgo: TimeInterval = 60) throws -> AgentSharedChat.Message {
            let encoder = JSONEncoder()
            var object = try #require(
                try JSONSerialization.jsonObject(with: encoder.encode(message)) as? [String: Any]
            )
            object["sentAt"] = Date.now.addingTimeInterval(-secondsAgo).timeIntervalSinceReferenceDate
            let data = try JSONSerialization.data(withJSONObject: object)
            return try JSONDecoder().decode(AgentSharedChat.Message.self, from: data)
        }

        func say(_ utterance: String) {
            queue.send(.voiceUtterance(utterance))
        }

        func speechEnded() {
            queue.send(.voiceSpeakingChanged(false))
        }

        /// Everything spoken so far once at least `count` texts were spoken,
        /// or whatever was spoken by the timeout.
        func spoken(count: Int, timeout: Duration = .seconds(10)) async -> [Spoken] {
            let deadline = ContinuousClock.now + timeout
            while await voice.spoken.count < count, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return await voice.spoken
        }

        /// Lets the loop settle, then returns what was spoken: for asserting
        /// that nothing more was said.
        func spokenAfterSettling() async -> [Spoken] {
            try? await Task.sleep(for: .milliseconds(150))
            return await voice.spoken
        }

        var publications: Int {
            recorder.publications
        }

        var prompts: [String] {
            recorder.prompts
        }

        func promptsReached(_ expected: [String], timeout: Duration = .seconds(10)) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while recorder.prompts != expected, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            return recorder.prompts == expected
        }

        func run() async -> Task<Void, Error> {
            let terminal = terminal
            let loop = Task { try await terminal.runInteractivePanelLoop() }
            // Messages are announced only from the loop's start on: deliver
            // nothing before it runs.
            while terminal.voiceEventQueue !== queue {
                try? await Task.sleep(for: .milliseconds(5))
            }
            return loop
        }

        func finish(_ loop: Task<Void, Error>) async throws {
            queue.send(.input(.endOfInput))
            try await loop.value
        }
    }

    private static func plain(_ text: String) -> Spoken {
        Spoken(text: text, rendering: .plainText)
    }

    private static let answer = Spoken(text: "Risposta.", rendering: .answer)

    @Test
    func onlyNewMessagesForTheOperatorAreAnnounced() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        let forOperator = harness.message(from: harness.reviewer)
        harness.deliver([forOperator])
        #expect(await harness.spoken(count: 1) == [
            Self.plain("Nuovo messaggio da Reviewer. Vuoi che lo legga?")
        ])

        harness.speechEnded()
        harness.say("no")
        // Silent: traffic between the coordinator and an agent, and a replay.
        harness.deliver([harness.message(from: harness.coordinator, to: [harness.reviewer.id])])
        harness.deliver([forOperator])
        // The probe proves the FIFO announced nothing in between.
        harness.deliver([harness.message(from: harness.builder, to: [harness.coordinator.id, harness.operatorID])])
        #expect(await harness.spoken(count: 2) == [
            Self.plain("Nuovo messaggio da Reviewer. Vuoi che lo legga?"),
            Self.plain("Nuovo messaggio da Builder a tutti. Vuoi che lo legga?")
        ])
        #expect(harness.prompts.isEmpty)
        try await harness.finish(loop)
    }

    @Test
    func yesReadsTheWholeMessageAndASecondYesSendsTheReply() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        harness.deliver([harness.message(from: harness.coordinator, text: Self.longText)])
        #expect(await harness.spoken(count: 1).last == Self.plain("Nuovo messaggio da Coordinator. Vuoi che lo legga?"))

        harness.speechEnded()
        harness.say("Sì.")
        let reading = await harness.spoken(count: 2).last
        #expect(reading == Self.plain(Self.longText + " Vuoi rispondere?"))
        #expect((reading?.text.count ?? 0) > TerminalVoiceSpeechText.maximumSpokenCharacters)

        harness.speechEnded()
        harness.say("yes")
        #expect(await harness.spoken(count: 3).last == Self.plain("Dimmi la risposta."))

        harness.speechEnded()
        harness.say("Procedi pure.")
        #expect(await harness.spoken(count: 4).last == Self.plain("Inviato."))
        #expect(harness.publications == 1)
        #expect(harness.prompts.isEmpty)
        // The controller learnt when a yes or no was awaited: during the
        // announcement and the reading (which ends with the reply question),
        // not while the reply text was awaited.
        let awaiting = await harness.voice.awaitingShortAnswer
        #expect(awaiting.first == true)
        #expect(awaiting.contains(false))
        #expect(awaiting.last == false)
        try await harness.finish(loop)
    }

    @Test
    func noMovesOnToTheNextQueuedMessage() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        harness.deliver([harness.message(from: harness.reviewer), harness.message(from: harness.builder)])
        #expect(await harness.spoken(count: 1) == [
            Self.plain("Nuovo messaggio da Reviewer, un altro in attesa. Vuoi che lo legga?")
        ])

        harness.speechEnded()
        harness.say("no")
        #expect(await harness.spoken(count: 2).last == Self.plain("Nuovo messaggio da Builder. Vuoi che lo legga?"))

        harness.speechEnded()
        harness.say("sì")
        #expect(await harness.spoken(count: 3).last == Self.plain("Ho finito. Vuoi rispondere?"))
        harness.speechEnded()
        harness.say("no")
        // Nothing else is queued: the next thing spoken is a later probe.
        harness.deliver([harness.message(from: harness.reviewer, text: "Altro.")])
        #expect(await harness.spoken(count: 4).last == Self.plain("Nuovo messaggio da Reviewer. Vuoi che lo legga?"))
        #expect(harness.publications == 0)
        try await harness.finish(loop)
    }

    @Test
    func anythingElseClosesTheQuestionAndRunsAsAPrompt() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        harness.deliver([harness.message(from: harness.reviewer)])
        #expect(await harness.spoken(count: 1).count == 1)

        harness.speechEnded()
        harness.say("Che ore sono?")
        let prompted = await harness.promptsReached(["Che ore sono?"])
        #expect(prompted)
        // The answer is read as an answer; the closed question is not asked again.
        #expect(await harness.spoken(count: 2).last == Self.answer)
        harness.speechEnded()
        harness.deliver([harness.message(from: harness.builder)])
        #expect(await harness.spoken(count: 3).last == Self.plain("Nuovo messaggio da Builder. Vuoi che lo legga?"))
        #expect(harness.publications == 0)
        try await harness.finish(loop)
    }

    @Test
    func sendPhrasesPublishWithoutAGeneration() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        harness.say("messaggio al coordinatore: fermati")
        #expect(await harness.spoken(count: 1) == [Self.plain("Inviato.")])
        #expect(harness.publications == 1)

        harness.speechEnded()
        harness.say("messaggio a tutti")
        #expect(await harness.spoken(count: 2).last == Self.plain("Dimmi il messaggio."))
        harness.speechEnded()
        harness.say("Pausa di dieci minuti.")
        #expect(await harness.spoken(count: 3).last == Self.plain("Inviato."))
        #expect(harness.publications == 2)

        harness.speechEnded()
        harness.say("messaggio a Anna: ciao")
        #expect(await harness.spoken(count: 4).last == Self.plain("Nessun agente attivo si chiama Anna."))
        #expect(harness.publications == 2)
        #expect(harness.prompts.isEmpty)
        try await harness.finish(loop)
    }

    @Test
    func aFailedPublicationIsSaidAloud() async throws {
        let harness = try Harness(publicationsSucceed: false)
        let loop = await harness.run()
        // No coordinator is registered in this room, so the real publication fails.
        harness.say("message to the coordinator: stop")
        #expect(await harness.spoken(count: 1) == [Self.plain("Invio non riuscito.")])
        #expect(harness.prompts.isEmpty)
        try await harness.finish(loop)
    }

    @Test
    func anUnansweredQuestionLapsesAndTheNextMessageIsAnnounced() async throws {
        let harness = try Harness()
        harness.terminal.voiceDialogueAnswerTimeout = .milliseconds(200)
        let loop = await harness.run()
        harness.deliver([harness.message(from: harness.reviewer), harness.message(from: harness.builder)])
        #expect(await harness.spoken(count: 1).last == Self.plain("Nuovo messaggio da Reviewer, un altro in attesa. Vuoi che lo legga?"))

        harness.speechEnded()
        #expect(await harness.spoken(count: 2).last == Self.plain("Nuovo messaggio da Builder. Vuoi che lo legga?"))
        harness.speechEnded()
        // The last question lapses too; a later message is announced normally.
        try await Task.sleep(for: .milliseconds(400))
        harness.deliver([harness.message(from: harness.reviewer, text: "Altro.")])
        #expect(await harness.spoken(count: 3).last == Self.plain("Nuovo messaggio da Reviewer. Vuoi che lo legga?"))
        #expect(await harness.voice.spoken.count == 3)
        try await harness.finish(loop)
    }

    @Test
    func escapeDropsTheQueueAndTheQuestion() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        harness.deliver([harness.message(from: harness.reviewer), harness.message(from: harness.builder)])
        #expect(await harness.spoken(count: 1).count == 1)

        harness.queue.send(.input(.cancelRequested))
        harness.speechEnded()
        // Neither the question nor the queued message survives: a "yes" is a prompt now.
        harness.say("sì")
        let prompted = await harness.promptsReached(["sì"])
        #expect(prompted)
        #expect(await harness.spoken(count: 2).last == Self.answer)
        harness.speechEnded()
        harness.deliver([harness.message(from: harness.coordinator, text: "Probe.")])
        #expect(await harness.spoken(count: 3).last == Self.plain("Nuovo messaggio da Coordinator. Vuoi che lo legga?"))
        try await harness.finish(loop)
    }

    @Test
    func anAnswerBeingReadPreemptsTheQuestionWhichIsAskedAgainAfterwards() async throws {
        let harness = try Harness(holdGenerations: true)
        let loop = await harness.run()
        harness.queue.send(.input(.submitted("fai qualcosa")))
        await harness.generationGate.waitUntilEntered()

        harness.deliver([harness.message(from: harness.reviewer)])
        #expect(await harness.spoken(count: 1).last == Self.plain("Nuovo messaggio da Reviewer. Vuoi che lo legga?"))
        harness.speechEnded()

        // The answer completes while the question waits: it is read first.
        await harness.generationGate.release()
        #expect(await harness.spoken(count: 2).last == Self.answer)
        harness.speechEnded()
        #expect(await harness.spoken(count: 3).last == Self.plain("Nuovo messaggio da Reviewer. Vuoi che lo legga?"))

        harness.speechEnded()
        harness.say("sì")
        #expect(await harness.spoken(count: 4).last == Self.plain("Ho finito. Vuoi rispondere?"))
        try await harness.finish(loop)
    }

    /// A turn with nothing to read leaves the pending question in place.
    @Test
    func anAnswerThatIsNotReadLeavesTheQuestionPending() async throws {
        let harness = try Harness(answerText: "")
        let loop = await harness.run()
        harness.deliver([harness.message(from: harness.reviewer)])
        #expect(await harness.spoken(count: 1).count == 1)
        harness.speechEnded()

        harness.queue.send(.input(.submitted("fai qualcosa")))
        let prompted = await harness.promptsReached(["fai qualcosa"])
        #expect(prompted)
        // Nothing was read and the question was not asked again.
        #expect(await harness.spokenAfterSettling().count == 1)
        harness.say("sì")
        #expect(await harness.spoken(count: 2).last == Self.plain("Ho finito. Vuoi rispondere?"))
        try await harness.finish(loop)
    }

    /// Announcements follow whatever is being read; they never interrupt it.
    @Test
    func announcementsWaitForTheCurrentReadingToEnd() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        await harness.voice.setSpeaking(true)
        harness.deliver([harness.message(from: harness.reviewer)])
        #expect(await harness.spokenAfterSettling().isEmpty)

        // A stale end-of-speech while the controller still reads is ignored.
        harness.speechEnded()
        #expect(await harness.spokenAfterSettling().isEmpty)

        await harness.voice.setSpeaking(false)
        harness.speechEnded()
        #expect(await harness.spoken(count: 1) == [Self.plain("Nuovo messaggio da Reviewer. Vuoi che lo legga?")])
        try await harness.finish(loop)
    }

    /// A replayed transcript, older than the observation, is never announced;
    /// only messages sent while voice mode listens are.
    @Test
    func replayedMessagesAreNotAnnounced() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        let old = try harness.replayed(harness.message(from: harness.reviewer, text: "Vecchio."))
        harness.deliver([old])
        #expect(await harness.spokenAfterSettling().isEmpty)
        harness.deliver([harness.message(from: harness.builder, text: "Nuovo.")])
        #expect(await harness.spoken(count: 1) == [Self.plain("Nuovo messaggio da Builder. Vuoi che lo legga?")])
        try await harness.finish(loop)
    }

    /// `/voice pause` drops the question and the queue; resuming announces
    /// nothing retroactively, only what arrives afterwards.
    @Test
    func pausingVoiceModeDropsTheQuestionAndTheQueue() async throws {
        let harness = try Harness()
        let loop = await harness.run()
        harness.deliver([harness.message(from: harness.reviewer), harness.message(from: harness.builder)])
        #expect(await harness.spoken(count: 1).count == 1)
        harness.speechEnded()

        harness.queue.send(.input(.submitted("/voice pause")))
        harness.deliver([harness.message(from: harness.coordinator, text: "Durante la pausa.")])
        #expect(await harness.spokenAfterSettling().count == 1)
        #expect(await harness.voice.isPaused)

        harness.queue.send(.input(.submitted("/voice resume")))
        harness.speechEnded()
        #expect(await harness.spokenAfterSettling().count == 1)
        #expect(await harness.voice.isPaused == false)

        harness.deliver([harness.message(from: harness.coordinator, text: "Dopo la pausa.")])
        #expect(await harness.spoken(count: 2).last == Self.plain("Nuovo messaggio da Coordinator. Vuoi che lo legga?"))
        harness.speechEnded()
        harness.say("sì")
        #expect(await harness.spoken(count: 3).last == Self.plain("Dopo la pausa. Vuoi rispondere?"))
        #expect(harness.prompts.isEmpty)
        try await harness.finish(loop)
    }
}

/// A voice controller that listens forever, never speaks for real and records
/// every text handed to it.
private actor FakeVoiceController: TerminalVoiceController {
    struct Spoken: Sendable, Equatable {
        let text: String
        let rendering: TerminalVoiceSpeechRendering
    }

    nonisolated let languageCode = "it"
    private(set) var isPaused = false
    private(set) var isSpeaking = false
    private(set) var spoken: [Spoken] = []
    private var isStopped = false

    var isActive: Bool {
        !isStopped
    }

    /// Pretends a reading is in progress (`true`) or over (`false`).
    func setSpeaking(_ speaking: Bool) {
        isSpeaking = speaking
    }

    func start() async {}

    func stop() async {
        isStopped = true
    }

    func speak(_ text: String, rendering: TerminalVoiceSpeechRendering) async -> Bool {
        guard !isStopped, !isPaused, !text.isEmpty else {
            return false
        }
        spoken.append(Spoken(text: text, rendering: rendering))
        return true
    }

    func interruptPlayback() async {}

    func setPaused(_ paused: Bool) async -> Bool {
        guard paused != isPaused else {
            return false
        }
        isPaused = paused
        return true
    }

    /// Every value the loop reported, in order.
    private(set) var awaitingShortAnswer: [Bool] = []

    func setAwaitingShortAnswer(_ awaiting: Bool) {
        awaitingShortAnswer.append(awaiting)
    }
}

/// Publications and prompts observed while the loop runs.
private final class LoopRecorder: Sendable {
    private let state = Mutex((publications: 0, prompts: [String]()))

    func recordPublication() {
        state.withLock { $0.publications += 1 }
    }

    func recordPrompt(_ prompt: String) {
        state.withLock { $0.prompts.append(prompt) }
    }

    var publications: Int {
        state.withLock { $0.publications }
    }

    var prompts: [String] {
        state.withLock { $0.prompts }
    }
}

private actor VoiceLoopTestGate {
    private var entered = false
    private var released = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func enterAndWait() async {
        entered = true
        entryWaiters.forEach { $0.resume() }
        entryWaiters.removeAll()
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilEntered() async {
        guard !entered else { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiters.forEach { $0.resume() }
        releaseWaiters.removeAll()
    }
}
