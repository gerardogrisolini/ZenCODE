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

@TerminalChatActor
@Suite("Terminal voice turn instruction")
struct TerminalVoiceTurnInstructionTests {
    @Test
    func instructionTextIsTheAgreedWording() {
        #expect(
            TerminalChat.voiceTurnInstruction
                == "Voice mode is on: the user is listening and your final answer is read aloud. Answer in short sentences. While you work, briefly comment on what you are doing as you do it. Keep any format the request requires."
        )
    }

    @Test
    func noInstructionWhileVoiceModeIsOff() async throws {
        let chat = try makeChat()
        #expect(chat.voiceController == nil)
        #expect(await chat.voiceTurnInstruction() == nil)
    }

    @Test
    func listeningVoiceModeSendsTheInstruction() async throws {
        let chat = try makeChat()
        chat.voiceController = ListeningVoiceController()

        #expect(await chat.voiceTurnInstruction() == TerminalChat.voiceTurnInstruction)
    }

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

    @Test
    func voiceCommandsChangeTheInstructionFromTheNextPrompt() async throws {
        let chat = try makeChat()
        chat.voiceController = ListeningVoiceController()
        // Collect the command messages instead of writing to a terminal.
        chat.telegramImmediateCommandOutput = []
        defer { chat.telegramImmediateCommandOutput = nil }

        await chat.handleVoiceCommand("/voice pause")
        #expect(await chat.voiceTurnInstruction() == nil)

        await chat.handleVoiceCommand("/voice resume")
        #expect(await chat.voiceTurnInstruction() == TerminalChat.voiceTurnInstruction)

        await chat.handleVoiceCommand("/voice off")
        #expect(chat.voiceController == nil)
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
private actor ListeningVoiceController: TerminalVoiceController {
    nonisolated let languageCode = "it"
    private(set) var isActive = true
    private(set) var isPaused = false
    var isSpeaking: Bool { false }

    func start() async {}

    func stop() async {
        isActive = false
    }

    func speak(_ text: String, rendering: TerminalVoiceSpeechRendering) async -> Bool {
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
