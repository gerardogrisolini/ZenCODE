//
//  TerminalVoiceModeTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@TerminalChatActor
@Suite("Terminal voice mode")
struct TerminalVoiceModeTests {
    @Test
    func voiceCommandIsKnownAndUsableDuringGeneration() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        ).map(\.command)
        #expect(commands.contains("/voice"))
        #expect(TerminalChat.isKnownSlashCommand("/voice"))
        #expect(TerminalChat.isKnownSlashCommand("/voice on"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/voice"))
    }

    @Test
    func voiceCompletionsListEverySubcommand() {
        let arguments = TerminalPromptCompletionCatalog.argumentSuggestions(for: "/voice")
        #expect(arguments.map(\.command) == ["on", "off", "pause", "resume"])
        #expect(arguments.allSatisfy { !$0.requiresArgument })
    }

    @Test
    func voiceCommandsWithoutARunningVoiceModeExplainHowToStartIt() async throws {
        let chat = TerminalChat(configuration: try configuration(), stdinIsTerminal: true)
        // Outside the interactive panel loop no event queue is registered, so
        // `/voice on` never reaches the microphone or speech recognition.
        #expect(chat.voiceEventQueue == nil)

        for command in ["/voice", "/voice pause", "/voice resume"] {
            #expect(await output(of: command, in: chat) == TerminalChat.voiceOffMessage)
        }
        #expect(await output(of: "/voice off", in: chat) == "Voice: already off.\n")
        #expect(
            await output(of: "/voice on", in: chat)
                == TerminalChat.voiceRequiresInteractiveTerminalMessage
        )
        #expect(await output(of: "/voice loud", in: chat) == TerminalVoiceCommandAction.usageMessage)
        #expect(chat.voiceController == nil)
    }

    @Test
    func echoCancellationWarningNamesTheCurrentOutput() {
        #expect(
            TerminalDictationVoiceController.echoCancellationUnavailableMessage(outputDeviceName: "AirPlay")
                == "Voice: echo cancellation is unavailable with the current audio output (AirPlay); switch to a local output or use headphones so you can talk over the assistant without it hearing itself.\n"
        )
        #expect(
            TerminalDictationVoiceController.echoCancellationUnavailableMessage(outputDeviceName: nil)
                == "Voice: echo cancellation is unavailable with the current audio output; switch to a local output or use headphones so you can talk over the assistant without it hearing itself.\n"
        )
    }

    @Test
    func listeningMessageNamesTheVoiceCommands() {
        #expect(
            TerminalDictationVoiceController.listeningMessage(localeIdentifier: "it_IT")
                == "Voice: listening (dictation, it_IT, on-device). Speak or type; answers are read aloud. /voice pauses or resumes, /voice off stops.\n"
        )
    }

    @Test
    func downloadingMessageNamesTheLanguage() {
        #expect(
            TerminalDictationVoiceController.downloadingMessage(localeIdentifier: "it_IT")
                == "Voice: downloading the speech recognition model for it_IT; macOS does this only the first time.\n"
        )
    }

    private func output(of command: String, in chat: TerminalChat) async -> String {
        chat.telegramImmediateCommandOutput = []
        await chat.handleVoiceCommand(command)
        defer { chat.telegramImmediateCommandOutput = nil }
        return chat.telegramImmediateCommandOutput?.joined() ?? ""
    }

    private func configuration() throws -> AgentConfiguration {
        try AgentConfiguration(
            hostedModelID: "provider/model",
            explicitModelID: "provider/model",
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [],
            workingDirectory: FileManager.default.temporaryDirectory
        )
    }
}
