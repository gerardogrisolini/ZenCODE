//
//  VoiceModeSessionTests.swift
//  ZenCODECoreTests
//
//  The voice mode coordinator with a fake controller and a fake host: the
//  `/voice` texts, the per-turn instruction, answers and comments read
//  aloud, the live-chat dialogue, a change of host with the semantics of
//  the terminal's rebind, the end of an edited dictation, the controller's
//  callbacks routed to the host, and the observable state. Nothing here
//  touches audio or asks for a permission.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@ChatSessionActor
@Suite("Voice mode session")
struct VoiceModeSessionTests {
    private typealias Spoken = SessionFakeVoiceController.Spoken
    private typealias Shown = FakeVoiceModeHost.Shown

    private static let roomID = "voice-session-room"
    private static let coordinator = AgentSharedChat.Participant(
        id: "coordinator:\(roomID)", name: "Coordinator", kind: .coordinator
    )
    private static let reviewer = AgentSharedChat.Participant(id: "agent-reviewer", name: "Reviewer", kind: .agent)
    private static let builder = AgentSharedChat.Participant(id: "agent-builder", name: "Builder", kind: .agent)
    private static let on = VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: false)
    private static let paused = VoiceModeSessionState(isOn: true, isPaused: true, isSpeaking: false)
    private static let speaking = VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: true)
    private static let starting = VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: false, isStarting: true)

    private static func plain(_ text: String) -> Spoken {
        Spoken(text: text, rendering: .plainText)
    }

    private static func answer(_ text: String) -> Spoken {
        Spoken(text: text, rendering: .answer)
    }

    private static func message(
        from sender: AgentSharedChat.Participant,
        text: String = "Ho finito."
    ) -> AgentSharedChat.Message {
        AgentSharedChat.Message(
            roomID: roomID,
            sender: sender,
            recipientIDs: [AgentSharedChat.operatorID(for: roomID)],
            text: text
        )
    }

    /// A session whose `/voice on` runs `controller`, pointed at `host`.
    private func makeSession(
        controller: SessionFakeVoiceController,
        host: FakeVoiceModeHost
    ) async -> VoiceModeSession {
        let session = VoiceModeSession { callbacks in
            controller.install(callbacks)
            return .ready(controller)
        }
        await session.setHost(host, announcingMessagesSince: .distantPast)
        return session
    }

    /// A session with voice mode on, its host's messages cleared.
    func runningSession(
        controller: SessionFakeVoiceController = SessionFakeVoiceController(),
        host: FakeVoiceModeHost = FakeVoiceModeHost()
    ) async -> VoiceModeSession {
        let session = await makeSession(controller: controller, host: host)
        await session.handleCommand("/voice on")
        host.shown = []
        return session
    }

    private func eventually(
        timeout: Duration = .seconds(5),
        _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while await !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    // MARK: Commands

    @Test
    func commandsDriveTheControllerWithTheTerminalTexts() async {
        let controller = SessionFakeVoiceController()
        let host = FakeVoiceModeHost()
        let session = await makeSession(controller: controller, host: host)

        // The controller says when it listens: the session adds nothing.
        await session.handleCommand("/voice on")
        #expect(host.shown.isEmpty)
        #expect(host.startCount == 1)
        #expect(await eventually { session.state == Self.on })
        #expect(await eventually { await controller.startCount == 1 })

        let expectations: [(String, Shown)] = [
            ("/voice on", .system("Voice: already on.\n")),
            ("/voice pause", .system("Voice: paused; not listening or reading answers aloud. /voice resumes it.\n")),
            ("/voice on", .system("Voice: already on (paused). /voice resume resumes it.\n")),
            ("/voice pause", .system("Voice: already paused.\n")),
            ("/voice", .system("Voice: resumed.\n")),
            ("/voice resume", .system("Voice: already listening.\n")),
            ("/voice", .system("Voice: paused; not listening or reading answers aloud. /voice resumes it.\n")),
            ("/voice resume", .system("Voice: resumed.\n")),
            ("/voice off", .system("Voice: off.\n")),
            ("/voice off", .system("Voice: already off.\n")),
        ]
        for (command, shown) in expectations {
            host.shown = []
            await session.handleCommand(command)
            #expect(host.shown == [shown], "\(command)")
        }
        #expect(await controller.stopCount == 1)
        #expect(host.stopCount == 1)
        #expect(session.state == .off)
    }

    @Test
    func turnInstructionIsSentOnlyWhileVoiceModeListens() async {
        let controller = SessionFakeVoiceController()
        let host = FakeVoiceModeHost()
        let session = await makeSession(controller: controller, host: host)
        #expect(await session.turnInstruction() == nil)

        await session.handleCommand("/voice on")
        // Once the start returned.
        #expect(await eventually { session.state == Self.on })
        #expect(await session.turnInstruction() == VoiceModeSession.turnInstructionText)

        await session.handleCommand("/voice pause")
        #expect(await session.turnInstruction() == nil)
        await session.handleCommand("/voice resume")
        #expect(await session.turnInstruction() == VoiceModeSession.turnInstructionText)

        // A controller that failed on its own sends nothing, and voice mode is off.
        await controller.fail()
        #expect(await session.turnInstruction() == nil)
        #expect(session.state == .off)
        #expect(host.stopCount == 1)
    }

    @Test
    func noInstructionGoesOutBeforeTheControllerListenedOnce() async {
        let controller = SessionFakeVoiceController()
        await controller.holdStart()
        let session = await makeSession(controller: controller, host: FakeVoiceModeHost())

        // On, starting, and nothing heard: no instruction.
        await session.handleCommand("/voice on")
        #expect(session.state == Self.starting)
        #expect(await eventually { await controller.startCount == 1 })
        #expect(await session.turnInstruction() == nil)

        await controller.releaseStart()
        #expect(await eventually { session.state == Self.on })
        #expect(await session.turnInstruction() == VoiceModeSession.turnInstructionText)
    }

    // MARK: Reading aloud

    @Test
    func theFinalAnswerIsReadAndATurnWithNothingToReadAnnouncesTheNextMessage() async {
        let controller = SessionFakeVoiceController()
        let session = await runningSession(controller: controller)

        await session.turnDidEnd(finalAnswer: "Risposta.")
        #expect(await controller.spoken == [Self.answer("Risposta.")])

        // A message that arrives while something is read waits for the end
        // of the turn.
        await controller.setSpeaking(true)
        await session.handleSharedChatMessages([Self.message(from: Self.reviewer)])
        #expect(await controller.spoken.count == 1)
        await controller.setSpeaking(false)

        // Nothing to say: the message set aside is announced right away.
        await session.turnDidEnd(finalAnswer: "")
        #expect(await controller.spoken.last == Self.plain("Nuovo messaggio da Reviewer. Vuoi che lo legga?"))
    }

    @Test
    func commentsAreReadOnlyDuringATurnWhenNothingElseIsReadOrAsked() async {
        let controller = SessionFakeVoiceController()
        let session = await runningSession(controller: controller)

        await session.speakCommentary("Fuori dal turno.", duringTurn: false)
        await session.speakCommentary(" \n ", duringTurn: true)
        #expect(await controller.spoken.isEmpty)

        await session.speakCommentary("Ora leggo il file.", duringTurn: true)
        #expect(await controller.spoken == [Self.answer("Ora leggo il file.")])

        // Something is being read: dropped, never read later.
        await controller.setSpeaking(true)
        await session.speakCommentary("Durante la lettura.", duringTurn: true)
        await controller.setSpeaking(false)
        await session.speakingChanged(false)
        #expect(await controller.spoken.count == 1)

        // A live-chat question is pending: dropped, the dialogue untouched.
        await session.handleSharedChatMessages([Self.message(from: Self.reviewer)])
        await session.speakingChanged(false)
        await session.speakCommentary("Durante la domanda.", duringTurn: true)
        #expect(await controller.spoken.count == 2)
        #expect(await session.handleUtterance("sì"))
        #expect(await controller.spoken.last == Self.plain("Ho finito. Vuoi rispondere?"))

        // Paused: nothing is read.
        await session.handleCommand("/voice pause")
        await session.speakCommentary("In pausa.", duringTurn: true)
        #expect(await controller.spoken.count == 3)
    }

    // MARK: Live-chat dialogue

    @Test
    func aMessageIsAnnouncedReadAndAnsweredByVoice() async {
        let controller = SessionFakeVoiceController()
        let host = FakeVoiceModeHost()
        host.participants = [Self.coordinator, Self.reviewer]
        let session = await runningSession(controller: controller, host: host)
        let message = Self.message(from: Self.reviewer)

        await session.handleSharedChatMessages([message])
        #expect(await controller.spoken == [Self.plain("Nuovo messaggio da Reviewer. Vuoi che lo legga?")])
        await session.speakingChanged(false)

        #expect(await session.handleUtterance("sì"))
        #expect(await controller.spoken.last == Self.plain("Ho finito. Vuoi rispondere?"))
        #expect(host.markedRead == [message.id])
        await session.speakingChanged(false)

        #expect(await session.handleUtterance("sì"))
        #expect(await controller.spoken.last == Self.plain("Dimmi la risposta."))
        await session.speakingChanged(false)

        #expect(await session.handleUtterance("Procedi pure."))
        #expect(await controller.spoken.last == Self.plain("Inviato."))
        #expect(host.sent == [.init(text: "Procedi pure.", destination: .direct([Self.reviewer.id]))])
        #expect(host.submitted.isEmpty)
        // A yes or no was awaited while asking and reading, not while the
        // reply text was.
        #expect(await controller.awaitingShortAnswer == [true, true, true, true, false, false, false])
    }

    @Test
    func anUnansweredQuestionLapsesThroughTheHostsContext() async {
        let controller = SessionFakeVoiceController()
        let host = FakeVoiceModeHost()
        let session = await runningSession(controller: controller, host: host)
        session.answerTimeout = .milliseconds(50)
        await session.handleSharedChatMessages([Self.message(from: Self.reviewer), Self.message(from: Self.builder)])
        await session.speakingChanged(false)

        // The session never closes the question by itself: the host hands
        // the token back from its serialized context.
        #expect(await eventually { host.controllerLog.deadlines.count == 1 })
        #expect(await controller.spoken.count == 1)
        let token = host.controllerLog.deadlines[0]
        await session.answerDeadlineElapsed(token)
        #expect(await controller.spoken.last == Self.plain("Nuovo messaggio da Builder. Vuoi che lo legga?"))

        // A late token of the lapsed question changes nothing.
        await session.answerDeadlineElapsed(token)
        #expect(await controller.spoken.count == 2)
    }

    @Test
    func aYesSaidToAQuestionAnAnswerReplacedIsNeverSentAsAPrompt() async {
        let controller = SessionFakeVoiceController()
        let host = FakeVoiceModeHost()
        let session = await runningSession(controller: controller, host: host)
        let message = Self.message(from: Self.reviewer)

        await session.handleSharedChatMessages([message])
        await session.speakingChanged(false)
        // The turn ends before the yes is handled: its answer is read first.
        await session.turnDidEnd(finalAnswer: "Vuoi che proceda?")
        await controller.setSpeaking(true)
        #expect(await session.handleUtterance("sì"))
        #expect(host.submitted.isEmpty)
        #expect(await controller.spoken == [
            Self.plain("Nuovo messaggio da Reviewer. Vuoi che lo legga?"),
            Self.answer("Vuoi che proceda?")
        ])

        // The answer is over: the question is asked again, and a yes answers
        // it.
        await controller.setSpeaking(false)
        await session.speakingChanged(false)
        #expect(await controller.spoken.last == Self.plain("Nuovo messaggio da Reviewer. Vuoi che lo legga?"))
        #expect(await session.handleUtterance("sì"))
        #expect(await controller.spoken.last == Self.plain("Ho finito. Vuoi rispondere?"))
        #expect(host.markedRead == [message.id])

        // The reply question goes with an answer read meanwhile: a yes that
        // arrives while it is read is dropped, one said after it replies to
        // the answer.
        await session.turnDidEnd(finalAnswer: "Fatto.")
        #expect(await session.handleUtterance("sì"))
        #expect(host.submitted.isEmpty)
        await session.speakingChanged(false)
        #expect(await session.handleUtterance("sì"))
        #expect(host.submitted == [.line("sì")])
    }

    @Test
    func sendPhrasesFollowWhatTheHostAnswers() async {
        let controller = SessionFakeVoiceController()
        let host = FakeVoiceModeHost()
        host.participants = [Self.coordinator, Self.reviewer]
        let session = await runningSession(controller: controller, host: host)

        // Refused by the channel: nothing is said or sent.
        host.admitsInput = false
        #expect(await session.handleUtterance("messaggio al coordinatore: fermati"))
        #expect(await controller.spoken.isEmpty)
        #expect(host.sent.isEmpty)
        host.admitsInput = true

        #expect(await session.handleUtterance("messaggio al coordinatore: fermati"))
        #expect(host.sent == [.init(text: "fermati", destination: .coordinator)])
        #expect(await controller.spoken.last == Self.plain("Inviato."))

        host.sendSucceeds = false
        #expect(await session.handleUtterance("messaggio a tutti: pausa"))
        #expect(await controller.spoken.last == Self.plain("Invio non riuscito."))

        host.destinationIsActive = false
        #expect(await session.handleUtterance("messaggio a Reviewer: controlla il diff"))
        #expect(host.shown == [.failure("ZenCODE message: selected agent is no longer active.\n")])
        #expect(await controller.spoken.last == Self.plain("Reviewer non è più attivo."))

        #expect(await session.handleUtterance("messaggio a Anna: ciao"))
        #expect(await controller.spoken.last == Self.plain("Nessun agente attivo si chiama Anna."))
        #expect(host.sent.count == 2)
        #expect(host.submitted.isEmpty)
    }

    @Test
    func escapeStopsTheReadingAndDropsTheQuestionAndTheQueue() async {
        let controller = SessionFakeVoiceController()
        let host = FakeVoiceModeHost()
        let session = await runningSession(controller: controller, host: host)
        await session.handleSharedChatMessages([Self.message(from: Self.reviewer), Self.message(from: Self.builder)])

        await session.interruptPlayback()
        #expect(await controller.interruptCount == 1)
        await session.speakingChanged(false)
        // Neither the question nor the queued message survives.
        #expect(await controller.spoken.count == 1)
        #expect(await session.handleUtterance("sì"))
        #expect(host.submitted == [.line("sì")])
        #expect(await controller.awaitingShortAnswer.last == false)
    }

    // MARK: Host

    @Test
    func aNewHostHasTheSemanticsOfTheTerminalsRebind() async {
        let controller = SessionFakeVoiceController()
        let first = FakeVoiceModeHost()
        let second = FakeVoiceModeHost()
        let session = await runningSession(controller: controller, host: first)
        await session.handleSharedChatMessages([Self.message(from: Self.reviewer), Self.message(from: Self.builder)])
        #expect(await controller.spoken.count == 1)

        // Messages sent before `since` are never announced to the new host.
        await session.setHost(second, announcingMessagesSince: Date.now.addingTimeInterval(60))
        #expect(session.host === second)
        #expect(await controller.interruptCount == 1)
        #expect(first.stopCount == 1)
        #expect(second.startCount == 1)
        #expect(await controller.awaitingShortAnswer.last == false)

        // The question and the queue were dropped: a yes is the new host's dictation.
        await session.speakingChanged(false)
        #expect(await session.handleUtterance("sì"))
        #expect(second.submitted == [.line("sì")])
        #expect(first.submitted.isEmpty)
        await session.handleSharedChatMessages([Self.message(from: Self.coordinator)])
        #expect(await controller.spoken.count == 1)

        // What the controller reports reaches the current host only.
        await controller.callbacks?.dictationChanged(1, "ci")
        #expect(second.controllerLog.previews == ["1:ci"])
        #expect(first.controllerLog.previews.isEmpty)

        // The same host is no change.
        await session.setHost(second)
        #expect(await controller.interruptCount == 1)

        // Another session or room in the same host: the same semantics.
        await session.targetDidChange(announcingMessagesSince: .distantPast)
        #expect(await controller.interruptCount == 2)
        await session.handleSharedChatMessages([Self.message(from: Self.builder, text: "Nuovo.")])
        #expect(await controller.spoken.last == Self.plain("Nuovo messaggio da Builder. Vuoi che lo legga?"))
    }

    @Test
    func theControllersCallbacksReachTheHost() async throws {
        let controller = SessionFakeVoiceController()
        let host = FakeVoiceModeHost(draft: "@reviewer")
        let session = await runningSession(controller: controller, host: host)
        let callbacks = try #require(controller.callbacks)

        // A dictation takes the whole draft; a bare answer goes alone.
        await callbacks.dictationChanged(1, "contro")
        await callbacks.utteranceRecognized(.dictation(id: 1, text: "controlla il diff"))
        await callbacks.utteranceRecognized(.answer("sì"))
        await callbacks.speakingChanged(true)
        let log = host.controllerLog
        #expect(log.previews == ["1:contro"])
        #expect(log.takes == [1])
        #expect(log.utterances == ["@reviewer controlla il diff", "sì"])
        #expect(log.speaking == [true])

        // Texts are shown; a failure that stopped the controller turns voice mode off.
        await callbacks.systemMessage("Voice: listening.\n")
        await controller.fail()
        await callbacks.failureMessage("Voice: the microphone stopped.\n")
        #expect(host.shown == [.system("Voice: listening.\n"), .failure("Voice: the microphone stopped.\n")])
        #expect(session.state == .off)
    }

    // MARK: State

    @Test
    func stateUpdatesFollowVoiceMode() async {
        let controller = SessionFakeVoiceController()
        await controller.holdStart()
        let session = await makeSession(controller: controller, host: FakeVoiceModeHost())
        var updates = session.stateUpdates().makeAsyncIterator()
        #expect(await updates.next() == .off)

        await session.handleCommand("/voice on")
        #expect(await updates.next() == Self.starting)
        await controller.releaseStart()
        #expect(await updates.next() == Self.on)
        await session.handleCommand("/voice pause")
        #expect(await updates.next() == Self.paused)
        await session.handleCommand("/voice resume")
        #expect(await updates.next() == Self.on)
        await session.speakingChanged(true)
        #expect(await updates.next() == Self.speaking)
        #expect(session.state == Self.speaking)
        await session.speakingChanged(false)
        #expect(await updates.next() == Self.on)
        await session.handleCommand("/voice off")
        #expect(await updates.next() == .off)
        // A late report of the stopped controller changes nothing.
        await session.speakingChanged(true)
        #expect(session.state == .off)
    }

    @Test
    func startingIsPublishedOnlyWhileNeitherPausedNorReading() async {
        let controller = SessionFakeVoiceController()
        await controller.holdStart()
        let session = await makeSession(controller: controller, host: FakeVoiceModeHost())

        await session.handleCommand("/voice on")
        #expect(session.state == Self.starting)
        #expect(await eventually { await controller.startCount == 1 })

        // The pause and the reading hide the start, which goes on below.
        await session.handleCommand("/voice pause")
        #expect(session.state == Self.paused)
        await session.handleCommand("/voice resume")
        #expect(session.state == Self.starting)
        await session.speakingChanged(true)
        #expect(session.state == Self.speaking)
        await session.speakingChanged(false)
        #expect(session.state == Self.starting)

        // The start returned: voice mode listens.
        await controller.releaseStart()
        #expect(await eventually { session.state == Self.on })
    }

    @Test
    func theControllerSaysWhenItHearsTheMicrophone() async throws {
        let controller = SessionFakeVoiceController()
        await controller.holdStart()
        let session = await makeSession(controller: controller, host: FakeVoiceModeHost())
        await session.handleCommand("/voice on")
        let callbacks = try #require(controller.callbacks)

        // Its start returns while it still loads the recognizer: starting,
        // and no instruction.
        await callbacks.listeningChanged(false)
        await controller.releaseStart()
        await session.controllerStart?.value
        #expect(session.state == Self.starting)
        #expect(await session.turnInstruction() == nil)

        // It hears the microphone.
        await callbacks.listeningChanged(true)
        #expect(session.state == Self.on)
        #expect(await session.turnInstruction() == VoiceModeSession.turnInstructionText)

        // It loads the recognizer again after a reading: starting, but the
        // instruction stays, since it listened once.
        await callbacks.listeningChanged(false)
        #expect(session.state == Self.starting)
        #expect(await session.turnInstruction() == VoiceModeSession.turnInstructionText)
        await callbacks.listeningChanged(true)
        #expect(session.state == Self.on)
    }

    @Test
    func aControllerThatFailsTurnsVoiceModeOffOnce() async throws {
        let controller = SessionFakeVoiceController()
        let host = FakeVoiceModeHost()
        let session = await runningSession(controller: controller, host: host)
        #expect(await eventually { session.state == Self.on })
        await session.handleSharedChatMessages([Self.message(from: Self.reviewer), Self.message(from: Self.builder)])
        await session.speakingChanged(false)
        #expect(session.dialogue.phase != .idle)
        let callbacks = try #require(controller.callbacks)
        let awaitingReports = await controller.awaitingShortAnswer.count

        // Everything that notices the failure at once: the host hears the
        // stop once, the dialogue is dropped, voice mode is off.
        await controller.fail()
        async let failure: Void = callbacks.failureMessage("Voice: the microphone stopped.\n")
        async let instruction = session.turnInstruction()
        async let command: Void = session.handleCommand("/voice pause")
        await failure
        #expect(await instruction == nil)
        await command
        #expect(host.stopCount == 1)
        #expect(session.state == .off)
        #expect(session.controller == nil)
        #expect(session.dialogue.phase == .idle)
        #expect(session.dialogue.pending.isEmpty)
        // The failed controller is neither stopped nor told anything else.
        #expect(await controller.stopCount == 0)
        #expect(await controller.awaitingShortAnswer.count == awaitingReports)

        // Nothing more happens later.
        #expect(await session.turnInstruction() == nil)
        await session.handleCommand("/voice off")
        #expect(host.stopCount == 1)
    }

    @Test
    func whatAReplacedControllerReportsIsIgnored() async throws {
        let first = SessionFakeVoiceController()
        let second = SessionFakeVoiceController()
        let host = FakeVoiceModeHost()
        let session = VoiceModeSession { callbacks in
            let next = first.callbacks == nil ? first : second
            next.install(callbacks)
            return .ready(next)
        }
        await session.setHost(host, announcingMessagesSince: .distantPast)
        await session.handleCommand("/voice on")
        #expect(await eventually { session.state == Self.on })
        let stale = try #require(first.callbacks)
        await session.handleCommand("/voice off")
        await second.holdStart()
        await session.handleCommand("/voice on")
        #expect(second.callbacks != nil)
        #expect(session.state == Self.starting)

        // The first controller's reports reach neither the state nor the
        // instruction of the second.
        await stale.listeningChanged(true)
        #expect(session.state == Self.starting)
        #expect(await session.turnInstruction() == nil)
        await second.releaseStart()
        #expect(await eventually { session.state == Self.on })
        await stale.listeningChanged(false)
        #expect(session.state == Self.on)
        #expect(await session.turnInstruction() == VoiceModeSession.turnInstructionText)
        await stale.failureMessage("Voice: the microphone stopped.\n")
        #expect(session.state == Self.on)
        #expect(host.stopCount == 1)
    }
}
