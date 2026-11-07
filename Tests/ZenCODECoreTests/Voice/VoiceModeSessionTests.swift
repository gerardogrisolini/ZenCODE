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
    private func runningSession(
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
        #expect(session.state == Self.on)
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
        let session = await makeSession(controller: controller, host: FakeVoiceModeHost())
        #expect(await session.turnInstruction() == nil)

        await session.handleCommand("/voice on")
        #expect(await session.turnInstruction() == VoiceModeSession.turnInstructionText)
        #expect(VoiceModeSession.turnInstructionText == TerminalChat.voiceTurnInstruction)

        await session.handleCommand("/voice pause")
        #expect(await session.turnInstruction() == nil)
        await session.handleCommand("/voice resume")
        #expect(await session.turnInstruction() == VoiceModeSession.turnInstructionText)

        // A controller that failed on its own sends nothing, and voice mode is off.
        await controller.fail()
        #expect(await session.turnInstruction() == nil)
        #expect(session.state == .off)
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
    func anythingElseIsSentByTheHostAsADictation() async {
        let host = FakeVoiceModeHost()
        let session = await runningSession(host: host)

        #expect(await session.handleUtterance("Che ore sono?"))
        #expect(await session.handleUtterance("/exit"))
        #expect(await session.handleUtterance("  "))
        #expect(host.submitted == [.line("Che ore sono?"), .plainPrompt("/exit")])

        // The host ends the channel for a line that exits.
        host.submitResult = false
        #expect(await session.handleUtterance("esci") == false)
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
        let session = await makeSession(controller: SessionFakeVoiceController(), host: FakeVoiceModeHost())
        var updates = session.stateUpdates().makeAsyncIterator()
        #expect(await updates.next() == .off)

        await session.handleCommand("/voice on")
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
}

/// A voice controller that listens until stopped, never speaks for real and
/// records every call.
private actor SessionFakeVoiceController: VoiceModeController {
    struct Spoken: Sendable, Equatable {
        let text: String
        let rendering: VoiceModeSpeechRendering
    }

    nonisolated let languageCode = "it"
    private(set) var isActive = true
    private(set) var isPaused = false
    private(set) var isSpeaking = false
    private(set) var spoken: [Spoken] = []
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var interruptCount = 0
    private(set) var awaitingShortAnswer: [Bool] = []
    private(set) var discarded: [UInt64] = []
    private nonisolated let installedCallbacks = Mutex<VoiceModeCallbacks?>(nil)

    /// The callbacks the session created this controller with.
    nonisolated var callbacks: VoiceModeCallbacks? {
        installedCallbacks.withLock { $0 }
    }

    nonisolated func install(_ callbacks: VoiceModeCallbacks) {
        installedCallbacks.withLock { $0 = callbacks }
    }

    /// Pretends a reading is in progress (`true`) or over (`false`).
    func setSpeaking(_ speaking: Bool) {
        isSpeaking = speaking
    }

    /// Pretends the controller failed on its own.
    func fail() {
        isActive = false
    }

    func start() async {
        startCount += 1
    }

    func stop() async {
        stopCount += 1
        isActive = false
    }

    func speak(_ text: String, rendering: VoiceModeSpeechRendering) async -> Bool {
        guard isActive, !isPaused, !text.isEmpty else {
            return false
        }
        spoken.append(Spoken(text: text, rendering: rendering))
        return true
    }

    func interruptPlayback() async {
        interruptCount += 1
    }

    func setPaused(_ paused: Bool) async -> Bool {
        guard paused != isPaused else {
            return false
        }
        isPaused = paused
        return true
    }

    func setAwaitingShortAnswer(_ awaiting: Bool) async {
        awaitingShortAnswer.append(awaiting)
    }

    func discardDictation(through id: UInt64) async {
        discarded.append(id)
    }
}

/// A channel that records what the session asks of it.
@ChatSessionActor
private final class FakeVoiceModeHost: VoiceModeSessionHost {
    enum Shown: Equatable {
        case system(String)
        case failure(String)
    }

    struct Sent: Equatable {
        let text: String
        let destination: AgentSharedChat.Destination
    }

    /// What arrived from the controller's context.
    struct ControllerLog: Sendable, Equatable {
        var previews: [String] = []
        var takes: [UInt64] = []
        var utterances: [String] = []
        var speaking: [Bool] = []
        var deadlines: [UUID] = []
    }

    var shown: [Shown] = []
    var startCount = 0
    var stopCount = 0
    var submitted: [VoiceModeDictatedInput] = []
    var submitResult = true
    var participants: [AgentSharedChat.Participant] = []
    var readIDs: Set<UUID> = []
    var markedRead: [UUID] = []
    var admitsInput = true
    var destinationIsActive = true
    var sendSucceeds = true
    var sent: [Sent] = []
    /// The typed draft a dictation is sent after; `nil` when an edit ended
    /// the dictation.
    nonisolated let draft: String?
    private nonisolated let log = Mutex(ControllerLog())

    init(draft: String? = "") {
        self.draft = draft
    }

    nonisolated var controllerLog: ControllerLog {
        log.withLock { $0 }
    }

    func voiceModeShowSystemMessage(_ text: String) async {
        shown.append(.system(text))
    }

    func voiceModeShowFailureMessage(_ text: String) async {
        shown.append(.failure(text))
    }

    func voiceModeDidStart() async {
        startCount += 1
    }

    func voiceModeDidStop() async {
        stopCount += 1
    }

    func voiceModeSubmitDictation(_ input: VoiceModeDictatedInput) async -> Bool {
        submitted.append(input)
        return submitResult
    }

    func voiceModeSharedChatParticipants() async -> [AgentSharedChat.Participant] {
        participants
    }

    func voiceModeIsSharedChatMessageUnread(_ id: UUID) async -> Bool {
        !readIDs.contains(id)
    }

    func voiceModeMarkSharedChatMessageRead(_ id: UUID) async {
        markedRead.append(id)
    }

    func voiceModeAdmitsInput() async -> Bool {
        admitsInput
    }

    func voiceModeIsActiveSharedChatDestination(_ destination: AgentSharedChat.Destination) async -> Bool {
        destinationIsActive
    }

    func voiceModeSendSharedChatMessage(_ text: String, to destination: AgentSharedChat.Destination) async -> Bool {
        sent.append(Sent(text: text, destination: destination))
        return sendSucceeds
    }

    nonisolated func voiceModeDictationChanged(id: UInt64, text: String) async {
        log.withLock { $0.previews.append("\(id):\(text)") }
    }

    nonisolated func voiceModeTakeDictation(id: UInt64, text: String) async -> String? {
        log.withLock { $0.takes.append(id) }
        return draft.map { VoiceModeSendKeyword.joined($0, text) }
    }

    nonisolated func voiceModeDeliverUtterance(_ text: String) async {
        log.withLock { $0.utterances.append(text) }
    }

    nonisolated func voiceModeDeliverSpeakingChanged(_ isSpeaking: Bool) async {
        log.withLock { $0.speaking.append(isSpeaking) }
    }

    nonisolated func voiceModeDeliverAnswerDeadline(_ token: UUID) async {
        log.withLock { $0.deadlines.append(token) }
    }
}
