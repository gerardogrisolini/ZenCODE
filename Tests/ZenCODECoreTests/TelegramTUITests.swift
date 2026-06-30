//
//  TelegramTUITests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//
import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TelegramTUITests {
    @Test
    func telegramSettingsRequireEnabledToken() {
        let tokenOnlySettings = AgentTelegramSettingsManifest(
            enabled: true,
            botToken: " 123456:ABCDEF "
        )
        let pairedSettings = AgentTelegramSettingsManifest(
            enabled: true,
            botToken: " 123456:ABCDEF ",
            linkedChatID: 42,
            linkedChatTitle: "Gerardo"
        )
        let missingTokenSettings = AgentTelegramSettingsManifest(
            enabled: true,
            botToken: " "
        )
        let disabledSettings = AgentTelegramSettingsManifest(
            enabled: false,
            botToken: "123456:ABCDEF"
        )

        #expect(tokenOnlySettings.isConfigured)
        #expect(!tokenOnlySettings.isEnabled)
        #expect(tokenOnlySettings.botToken == "123456:ABCDEF")
        #expect(pairedSettings.isConfigured)
        #expect(pairedSettings.isEnabled)
        #expect(pairedSettings.linkedChatID == 42)
        #expect(pairedSettings.linkedChatTitle == "Gerardo")
        #expect(!missingTokenSettings.isEnabled)
        #expect(missingTokenSettings.botToken == nil)
        #expect(!disabledSettings.isEnabled)
        #expect(disabledSettings.botToken == nil)
    }

    @Test
    func settingsManifestRoundTripsEnabledTelegramConfiguration() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            telegram: AgentTelegramSettingsManifest(
                enabled: true,
                botToken: "123456:ABCDEF",
                linkedChatID: 42,
                linkedChatTitle: "Gerardo"
            )
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(decoded.telegram?.isEnabled == true)
        #expect(decoded.telegram?.botToken == "123456:ABCDEF")
        #expect(decoded.telegram?.linkedChatID == 42)
        #expect(decoded.telegram?.linkedChatTitle == "Gerardo")
        #expect(json.contains(#""telegram""#))
        #expect(json.contains(#""botToken":"123456:ABCDEF""#))
        #expect(json.contains(#""linkedChatID":42"#))
    }

    @Test
    func settingsManifestPreservesTokenOnlyTelegramConfigurationWithoutEnablingCommand() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            telegram: AgentTelegramSettingsManifest(
                enabled: true,
                botToken: "123456:ABCDEF"
            )
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)

        #expect(decoded.telegram?.isConfigured == true)
        #expect(decoded.telegram?.isEnabled == false)
        #expect(decoded.telegram?.botToken == "123456:ABCDEF")
        #expect(decoded.telegram?.linkedChatID == nil)
    }

    @Test
    func settingsManifestOmitsDisabledTelegramConfiguration() throws {
        let manifest = AgentSettingsManifest(
            models: [],
            telegram: AgentTelegramSettingsManifest(
                enabled: false,
                botToken: "123456:ABCDEF"
            )
        )

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(decoded.telegram == nil)
        #expect(!json.contains(#""telegram""#))
    }

    @Test
    func telegramCommandIsVisibleOnlyWhenConfigured() {
        let disabledCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: false
        ).map(\.command)
        let enabledCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: true,
            voiceEnabled: false
        ).map(\.command)

        #expect(!disabledCommands.contains("/telegram"))
        #expect(enabledCommands.contains("/telegram"))
    }

    @Test
    func builderCommandVisibilityRemainsIndependentFromTelegram() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: true,
            telegramEnabled: false,
            voiceEnabled: false
        ).map(\.command)

        #expect(commands.contains("/feature"))
        #expect(!commands.contains("/telegram"))
    }

    @Test
    func telegramCommandTokenRendersAsUnknownWhenHidden() {
        #expect(
            TerminalChat.unknownCommandMessage(for: "/telegram on")
                == "ZenCODE: unknown command '/telegram'.\n"
        )
    }

    @Test
    func voiceCommandIsVisibleOnlyWhenConfigured() {
        let disabledCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: false
        ).map(\.command)
        let enabledCommands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: true
        ).map(\.command)

        #expect(!disabledCommands.contains("/voice"))
        #expect(enabledCommands.contains("/voice"))
        #expect(!disabledCommands.contains("/speak"))
        #expect(enabledCommands.contains("/speak"))
    }

    @Test
    func speakCommandRequiresVoiceSynthesisSupport() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false,
            voiceEnabled: true,
            voiceSynthesisEnabled: false
        ).map(\.command)

        #expect(commands.contains("/voice"))
        #expect(!commands.contains("/speak"))
    }

    @Test
    func voiceSynthesisSupportIsMacOSOnly() {
        #if os(macOS)
        #expect(AgentVoiceSynthesisService.isSupported)
        #else
        #expect(!AgentVoiceSynthesisService.isSupported)
        #endif
    }

    @Test
    func voiceCommandTokenRendersAsUnknownWhenHidden() {
        #expect(
            TerminalChat.unknownCommandMessage(for: "/voice")
                == "ZenCODE: unknown command '/voice'.\n"
        )
        #expect(
            TerminalChat.unknownCommandMessage(for: "/speak")
                == "ZenCODE: unknown command '/speak'.\n"
        )
    }

    @Test
    func submittedLineRoleSeparatesPromptsFromSlashCommands() {
        #expect(TerminalChat.submittedLineRole(for: "ciao") == .prompt)
        #expect(TerminalChat.submittedLineRole(for: "   ") == .empty)
        #expect(TerminalChat.submittedLineRole(for: "/speak") == .slashCommand(token: "/speak"))
        #expect(TerminalChat.submittedLineRole(for: "/help extra") == .slashCommand(token: "/help"))
        #expect(TerminalChat.submittedLineRole(for: "/start 233B0EC4") == .slashCommand(token: "/start"))
    }

    @Test
    func slashCommandsDoNotUsePromptPanelRules() {
        #expect(!TerminalChat.shouldSuspendPanelInput(for: "ciao"))
        #expect(TerminalChat.shouldSuspendPanelInput(for: "/help"))
        #expect(TerminalChat.shouldSuspendPanelInput(for: "/unknown"))
        #expect(!TerminalChat.shouldSuspendPanelInput(for: "/speak"))
        #expect(TerminalChat.isKnownSlashCommand("/think"))
        #expect(TerminalChat.isKnownSlashCommand("/session save"))
        #expect(!TerminalChat.isKnownSlashCommand("/start 233B0EC4"))
    }

    @Test
    func spokenTextFormatterRemovesCodeBlocksAndShortensLongReplies() {
        let prepared = AgentVoiceSpokenTextFormatter.prepare(
            """
            Ecco il punto principale.

            ```swift
            print("non leggere questo")
            ```

            Questa parte resta parlabile e contiene un link [utile](https://example.com).
            """,
            characterLimit: 160
        )

        #expect(!prepared.text.contains("print"))
        #expect(!prepared.text.contains("example.com"))
        #expect(prepared.text.contains("Ecco il punto principale."))
        #expect(prepared.text.contains("utile"))
    }

    @Test
    func spokenTextFormatterTruncatesAtSpeechBoundary() {
        let longReply = Array(
            repeating: "Questa frase e' pensata per essere abbastanza lunga.",
            count: 40
        ).joined(separator: " ")
        let prepared = AgentVoiceSpokenTextFormatter.prepare(longReply, characterLimit: 220)

        #expect(prepared.isShortened)
        #expect(prepared.text.count <= 220)
        #expect(prepared.text.last == "." || prepared.text.hasSuffix("..."))
    }

    @Test
    func telegramVoiceOriginKeepsChatIDAndMarksVoiceReply() {
        let textOrigin = TerminalPromptOrigin.telegram(chatID: 42)
        let voiceOrigin = TerminalPromptOrigin.telegramVoice(chatID: 42)

        #expect(textOrigin.telegramChatID == 42)
        #expect(voiceOrigin.telegramChatID == 42)
        #expect(!textOrigin.isTelegramVoice)
        #expect(voiceOrigin.isTelegramVoice)
    }

    @Test
    func telegramCommandActionAcceptsOnlyOnOffAndBareStatus() {
        #expect(TerminalTelegramCommandAction(argument: "") == .status)
        #expect(TerminalTelegramCommandAction(argument: " on ") == .turnOn)
        #expect(TerminalTelegramCommandAction(argument: "off") == .turnOff)
        #expect(TerminalTelegramCommandAction(argument: "status") == .usage)
        #expect(TerminalTelegramCommandAction(argument: "start") == .usage)
        #expect(TerminalTelegramCommandAction(argument: "stop") == .usage)
    }

    @Test
    func telegramStartPayloadIsRemoteCommandNotPrompt() {
        #expect(TerminalTelegramRemoteCommand(text: "/start") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/start 233B0EC4") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/start@zencode_bot 233B0EC4") == .start)
        #expect(TerminalTelegramRemoteCommand(text: "/help") == .help)
        #expect(TerminalTelegramRemoteCommand(text: "ciao") == nil)
    }

    @Test
    func telegramProgressReporterRequiresActiveTelegramSession() throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "mlx-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        )
        let terminal = TerminalChat(configuration: configuration, stdinIsTerminal: false)
        terminal.telegramLinkedChatID = 42

        terminal.telegramControlState = TerminalTelegramControlState(
            isConfigured: true,
            isActive: false,
            statusText: "Configured",
            botUsername: nil,
            lastError: nil,
            lastMessagePreview: nil
        )
        #expect(terminal.makeTelegramTurnProgressReporter(for: .telegram(chatID: 42)) == nil)

        terminal.telegramControlState.isActive = true
        // Local prompts forward to the linked chat once Telegram is active.
        #expect(terminal.makeTelegramTurnProgressReporter(for: .local) != nil)
        #expect(terminal.makeTelegramTurnProgressReporter(for: .telegram(chatID: 43)) == nil)
        #expect(terminal.makeTelegramTurnProgressReporter(for: .telegram(chatID: 42)) != nil)

        // Without a linked chat there is no destination, even for local prompts.
        terminal.telegramLinkedChatID = nil
        #expect(terminal.makeTelegramTurnProgressReporter(for: .local) == nil)
    }

    @Test
    func telegramPairingCodeAcceptsPlainCodeAndStartPayload() {
        #expect(TerminalTelegramPairingService.pairingCode(in: " abcd1234 ") == "ABCD1234")
        #expect(TerminalTelegramPairingService.pairingCode(in: "/start abcd1234") == "ABCD1234")
        #expect(
            TerminalTelegramPairingService.pairingCode(in: "/start@zencode_bot abcd1234")
                == "ABCD1234"
        )
        #expect(TerminalTelegramPairingService.pairingCode(in: "\n/start AbCd1234\n") == "ABCD1234")
        #expect(TerminalTelegramPairingService.pairingCode(in: "/start") == nil)
    }

        @Test
    func telegramPermissionCommandsParseRemoteApprovalReplies() {
        #expect(
            TerminalTelegramPermissionBroker.permissionCommand(from: "/allow ABC123")
                == TerminalTelegramPermissionCommand(decision: .allowOnce, requestID: "ABC123")
        )
        #expect(
            TerminalTelegramPermissionBroker.permissionCommand(from: "/always@zencode_bot f00")
                == TerminalTelegramPermissionCommand(decision: .allowAlways, requestID: "F00")
        )
        #expect(
            TerminalTelegramPermissionBroker.permissionCommand(from: "/deny ABC123")
                == TerminalTelegramPermissionCommand(decision: .deny, requestID: "ABC123")
        )
        #expect(TerminalTelegramPermissionBroker.permissionCommand(from: "sì abc-123") == nil)
        #expect(TerminalTelegramPermissionBroker.permissionCommand(from: "annulla") == nil)
        #expect(TerminalTelegramPermissionBroker.permissionCommand(from: "run the tests") == nil)
    }

    @Test
    func telegramPermissionBrokerWaitsForRemoteReply() async throws {
        let broker = TerminalTelegramPermissionBroker()
        let collector = TelegramTestMessageCollector()
        let command = "mlx-telegram-permission-test-\(UUID().uuidString)"
        let request = Self.localExecAuthorizationRequest(command: "\(command) --flag")

        let authorization = Task {
            await broker.authorize(
                request,
                chatID: 42,
                timeoutNanoseconds: 5_000_000_000
            ) { message in
                await collector.append(message)
            }
        }

        let message = await collector.firstMessage()
        #expect(message.contains("Permission required"))
        #expect(message.contains(command))
        let requestID = try #require(Self.telegramPermissionRequestID(in: message))

        let reminder = await broker.handleMessage("queue another prompt", chatID: 42)
        #expect(reminder.isHandled)
        if case let .handled(reply) = reminder {
            #expect(reply?.contains("Permission request pending") == true)
        }

        let reply = await broker.handleMessage("/allow \(requestID)", chatID: 42)
        #expect(reply.isHandled)
        if case let .handled(replyText) = reply {
            #expect(replyText?.contains("allowed once") == true)
        }
        #expect(await authorization.value)
    }

    @Test
    func telegramPermissionBrokerHandlesStrayPermissionRepliesWithoutPrompting() async {
        let broker = TerminalTelegramPermissionBroker()
        let permissionReply = await broker.handleMessage("/allow ABC123", chatID: 42)
        let regularPrompt = await broker.handleMessage("please continue", chatID: 42)

        #expect(permissionReply.isHandled)
        if case let .handled(reply) = permissionReply {
            #expect(reply == "No permission request is pending.")
        }
        #expect(regularPrompt == .notHandled)
    }

    private static func localExecAuthorizationRequest(command: String) -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            sessionID: "terminal-test",
            toolCallID: "tool-call-test",
            toolName: "local.exec",
            title: "Run \(command)",
            kind: "execute",
            command: command,
            workingDirectory: "/tmp/project"
        )
    }

    private static func telegramPermissionRequestID(in message: String) -> String? {
        message
            .split(separator: "\n")
            .first { line in
                line.trimmingCharacters(in: .whitespacesAndNewlines)
                    .hasPrefix("Request ID:")
            }
            .map {
                $0.replacingOccurrences(of: "Request ID:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }
}

private actor TelegramTestMessageCollector {
    private var messages: [String] = []
    private var waiters: [CheckedContinuation<String, Never>] = []

    func append(_ message: String) {
        messages.append(message)
        let pendingWaiters = waiters
        waiters.removeAll()
        for waiter in pendingWaiters {
            waiter.resume(returning: message)
        }
    }

    func firstMessage() async -> String {
        if let message = messages.first {
            return message
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }
}
