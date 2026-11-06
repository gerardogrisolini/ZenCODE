//
//  VoiceModeSessionPublicAPITests.swift
//  ZenCODECoreTests
//
//  Voice mode as a host app sees it: everything here is reached through
//  `import ZenCODECore` without `@testable`, so a symbol an app needs to run
//  `VoiceModeSession` with a test controller and its own host that is not
//  public fails the build of this target (see Docs/embedding.md, Voice Mode).
//  Nothing here touches audio or asks for a permission.
//

import Foundation
import Synchronization
import Testing
import ZenCODECore

@ChatSessionActor
@Suite("Voice mode session, public API")
struct VoiceModeSessionPublicAPITests {
    @Test("An app runs voice mode with a test controller and its own window as host")
    func anAppRunsVoiceModeThroughThePublicAPI() async throws {
        let controller = PublicTestVoiceController()
        let session = VoiceModeSession { callbacks in
            controller.install(callbacks)
            return .ready(controller)
        }
        let window = PublicTestWindow()
        await session.setHost(window)
        var states = session.stateUpdates().makeAsyncIterator()
        #expect(await states.next() == .off)
        #expect(await session.turnInstruction() == nil)

        await session.handleCommand("/voice on")
        #expect(await states.next() == VoiceModeSessionState(isOn: true, isPaused: false, isSpeaking: false))
        #expect(window.started == 1)
        #expect(await session.turnInstruction() != nil)

        // The controller hears a dictation: the window's draft goes out
        // through its serialized context, and comes back as an utterance.
        let callbacks = try #require(controller.callbacks)
        await callbacks.utteranceRecognized(.dictation(id: 1, text: "che ore sono?"))
        let delivered = window.delivered
        #expect(delivered == ["che ore sono?"])
        for utterance in delivered {
            #expect(await session.handleUtterance(utterance))
        }
        #expect(window.submitted == [.line("che ore sono?")])

        // The answer of the turn is read aloud.
        await session.turnDidEnd(finalAnswer: "Sono le dieci.")
        #expect(await controller.spoken == ["Sono le dieci."])
        await session.speakingChanged(true)
        #expect(session.state.isSpeaking)
        await session.interruptPlayback()
        await session.speakingChanged(false)

        await session.handleCommand("/voice pause")
        #expect(window.shown.last == "Voice: paused; not listening or reading answers aloud. /voice resumes it.\n")
        #expect(session.state.isPaused)
        #expect(await session.turnInstruction() == nil)

        // The window that becomes active takes voice mode over.
        let other = PublicTestWindow()
        await session.setHost(other, announcingMessagesSince: .now)
        #expect(window.stopped == 1)
        #expect(other.started == 1)
        session.dictationEnded(through: 2)

        await session.handleCommand("/voice off")
        #expect(other.shown == ["Voice: off.\n"])
        #expect(session.state == .off)
        #expect(await controller.isActive == false)
    }
}

/// A controller that records what it is asked to read and nothing else.
private actor PublicTestVoiceController: VoiceModeController {
    nonisolated let languageCode = "en"
    private(set) var isActive = true
    private(set) var isPaused = false
    private(set) var isSpeaking = false
    private(set) var spoken: [String] = []
    private nonisolated let installedCallbacks = Mutex<VoiceModeCallbacks?>(nil)

    nonisolated var callbacks: VoiceModeCallbacks? {
        installedCallbacks.withLock { $0 }
    }

    nonisolated func install(_ callbacks: VoiceModeCallbacks) {
        installedCallbacks.withLock { $0 = callbacks }
    }

    func start() async {}

    func stop() async {
        isActive = false
    }

    func speak(_ text: String, rendering: VoiceModeSpeechRendering) async -> Bool {
        guard isActive, !isPaused, !text.isEmpty else { return false }
        spoken.append(text)
        return true
    }

    func interruptPlayback() async {}

    func setPaused(_ paused: Bool) async -> Bool {
        guard paused != isPaused else { return false }
        isPaused = paused
        return true
    }

    func setAwaitingShortAnswer(_ awaiting: Bool) async {}

    func discardDictation(through id: UInt64) async {}
}

/// A window as the host of the app's voice session: an empty draft, no
/// shared chat, and a serialized context the test drains by hand.
@ChatSessionActor
private final class PublicTestWindow: VoiceModeSessionHost {
    var shown: [String] = []
    var started = 0
    var stopped = 0
    var submitted: [VoiceModeDictatedInput] = []
    private nonisolated let deliveries = Mutex<[String]>([])

    nonisolated var delivered: [String] {
        deliveries.withLock { $0 }
    }

    func voiceModeShowSystemMessage(_ text: String) async {
        shown.append(text)
    }

    func voiceModeShowFailureMessage(_ text: String) async {
        shown.append(text)
    }

    func voiceModeDidStart() async {
        started += 1
    }

    func voiceModeDidStop() async {
        stopped += 1
    }

    func voiceModeSubmitDictation(_ input: VoiceModeDictatedInput) async -> Bool {
        submitted.append(input)
        return true
    }

    func voiceModeSharedChatParticipants() async -> [AgentSharedChat.Participant] {
        []
    }

    func voiceModeIsSharedChatMessageUnread(_ id: UUID) async -> Bool {
        true
    }

    func voiceModeMarkSharedChatMessageRead(_ id: UUID) async {}

    func voiceModeAdmitsInput() async -> Bool {
        true
    }

    func voiceModeIsActiveSharedChatDestination(_ destination: AgentSharedChat.Destination) async -> Bool {
        true
    }

    func voiceModeSendSharedChatMessage(_ text: String, to destination: AgentSharedChat.Destination) async -> Bool {
        true
    }

    nonisolated func voiceModeDictationChanged(id: UInt64, text: String) async {}

    nonisolated func voiceModeTakeDictation(id: UInt64, text: String) async -> String? {
        text
    }

    nonisolated func voiceModeDeliverUtterance(_ text: String) async {
        deliveries.withLock { $0.append(text) }
    }

    nonisolated func voiceModeDeliverSpeakingChanged(_ isSpeaking: Bool) async {}

    nonisolated func voiceModeDeliverAnswerDeadline(_ token: UUID) async {}
}
