//
//  TerminalVoiceTurnInstructionTests.swift
//  ZenCODECoreTests
//
//  The per-turn instruction voice mode adds to every prompt: present only while
//  voice mode listens (running and not paused), re-evaluated for each prompt.
//  Nothing here touches audio, a model, or the runtime.
//

import Foundation
import Testing
@testable import ZenCODECore

@ChatSessionActor
@Suite("Terminal voice turn instruction")
struct TerminalVoiceTurnInstructionTests {
    @Test
    func pausedVoiceModeSendsNoInstruction() async throws {
        let chat = try makeChat()
        let voice = ListeningVoiceController()
        chat.voiceController = voice

        _ = await voice.setPaused(true)
        #expect(await chat.voiceTurnInstruction() == nil)

        _ = await voice.setPaused(false)
        #expect(await chat.voiceTurnInstruction() == TerminalChat.voiceTurnInstruction)
    }

    @Test
    func failedOrStoppedControllerSendsNoInstruction() async throws {
        let chat = try makeChat()
        let voice = ListeningVoiceController()
        chat.voiceController = voice

        await voice.stop()
        // The controller stays installed (as after a failure) but is inactive.
        #expect(chat.voiceController != nil)
        #expect(await chat.voiceTurnInstruction() == nil)
    }

    private func makeChat() throws -> TerminalChat {
        TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "provider/model",
                explicitModelID: "provider/model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [],
                workingDirectory: FileManager.default.temporaryDirectory
            ),
            stdinIsTerminal: false
        )
    }
}

/// A voice controller that listens until paused or stopped. It never records or
/// speaks.
private actor ListeningVoiceController: VoiceModeController {
    nonisolated let languageCode = "it"
    private(set) var isActive = true
    private(set) var isPaused = false
    var isSpeaking: Bool { false }

    func start() async {}

    func stop() async {
        isActive = false
    }

    func speak(_ text: String, rendering: VoiceModeSpeechRendering) async -> Bool {
        false
    }

    func interruptPlayback() async {}

    func setPaused(_ paused: Bool) async -> Bool {
        guard paused != isPaused else {
            return false
        }
        isPaused = paused
        return true
    }

    func setAwaitingShortAnswer(_ awaiting: Bool) async {}

    func discardDictation(through id: UInt64) async {}
}
