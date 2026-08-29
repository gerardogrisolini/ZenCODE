//
//  ZenCODESetupRunner+Telegram.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension ZenCODESetupRunner {
    static func configureTelegram(
        in manifest: AgentSettingsManifest
    ) async throws -> AgentSettingsManifest {
        let telegram = try await promptTelegramSettings(existingSettings: manifest.telegram)
        return AgentSettingsManifest(
            version: manifest.version,
            providers: manifest.providers,
            models: manifest.models,
            selectedModelID: manifest.selectedModelID,
            selectedThinkingSelection: manifest.selectedThinkingSelection,
            telegram: telegram,
            voice: manifest.voice,
            remoteAPIKeysByProviderID: manifest.remoteAPIKeysByProviderID,
            localExecAllowedCommands: manifest.localExecAllowedCommands,
            chatGPTSubscriptionCredentials: manifest.chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: manifest.anthropicSubscriptionCredentials,
            responseLanguage: manifest.responseLanguage,
            memoryEmbedding: manifest.memoryEmbedding
        )
    }

    static func promptTelegramSettings(
        existingSettings: AgentTelegramSettingsManifest?
    ) async throws -> AgentTelegramSettingsManifest? {
        let shouldEnableTelegram = try promptYesNo(
            "Enable Telegram remote control?",
            defaultValue: existingSettings?.isConfigured == true
        )
        guard shouldEnableTelegram else {
            return nil
        }

        let existingToken = existingSettings?.botToken?.nilIfBlank
        if existingSettings?.isEnabled == true {
            let shouldReplacePairing = try promptYesNo(
                "Replace stored Telegram bot token and pairing?",
                defaultValue: false
            )
            if !shouldReplacePairing {
                return existingSettings
            }
        }

        let token: String
        if let existingToken,
           try promptYesNo("Use stored Telegram bot token for pairing?", defaultValue: true) {
            token = existingToken
        } else {
            printTelegramBotTokenGuide()
            token = try promptSecret(
                "Telegram bot token",
                allowEmpty: false
            )
        }

        return try await pairTelegram(botToken: token)
    }

    static func printTelegramBotTokenGuide() {
        AgentOutput.standardError.writeString(
            """
            \nTelegram bot setup:
              1. Open Telegram and start a chat with @BotFather.
              2. Send /newbot and follow the prompts for bot name and username.
              3. Copy the bot token returned by BotFather and paste it below.
              4. Setup will then show a pairing code to send to your bot.
              Keep the token private; it gives access to your bot.

            """
        )
    }

    static func pairTelegram(
        botToken: String
    ) async throws -> AgentTelegramSettingsManifest {
        let pairingService = TerminalTelegramPairingService(botToken: botToken)
        let bot = try await pairingService.prepare()
        let botLabel = bot.username.map { "@\($0)" } ?? "your Telegram bot"

        // Deep-link grant: 128 bits of entropy, single use, 10-minute TTL.
        // Telegram delivers `/start <payload>` back to the bot, which consumes
        // the grant atomically. The payload doubles as the manual fallback
        // code for clients that cannot open links.
        let pairingDeadline = Date().addingTimeInterval(
            TerminalTelegramPairingGrant.timeToLive
        )
        let payload = await pairingService.issuePairingGrant()
        let deepLink = bot.username.map {
            TerminalTelegramPairingGrantLink.deepLink(botUsername: $0, payload: payload)
        }

        var instructions = """
        Telegram pairing:
          Open this link to link your private chat:
        """
        if let deepLink {
            instructions += "\n    \(deepLink)\n"
        } else {
            instructions += "\n    (bot username unavailable)\n"
        }
        instructions += """
          Or send this code to \(botLabel) manually:
            \(payload)
          The code works once and expires in 10 minutes.
          Waiting for Telegram...

        """
        AgentOutput.standardError.writeString(instructions)

        let linkedChat = try await pairingService.waitForPairing(
            code: payload, deadline: pairingDeadline
        )
        let title = linkedChat.chatTitle?.nilIfBlank ?? "chat \(linkedChat.chatID)"
        AgentOutput.standardError.writeString("Telegram linked: \(title)\n")
        return AgentTelegramSettingsManifest(
            enabled: true,
            botToken: botToken,
            linkedChatID: linkedChat.chatID,
            linkedChatTitle: linkedChat.chatTitle,
            ownerUserID: linkedChat.userID,
            routes: [
                AgentTelegramRouteManifest(roomID: "default")
            ]
        )
    }

    static func newTelegramPairingCode() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
    }

}
