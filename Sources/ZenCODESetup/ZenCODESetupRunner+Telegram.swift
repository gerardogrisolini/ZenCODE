//
//  ZenCODESetupRunner+Telegram.swift
//  ZenCODE
//

import Foundation
import ZenCODECore

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
            anthropicSubscriptionCredentials: manifest.anthropicSubscriptionCredentials
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
            token = try promptString(
                "Telegram bot token",
                defaultValue: nil,
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
        let pairingCode = newTelegramPairingCode()
        let pairingService = TerminalTelegramPairingService(botToken: botToken)
        let bot = try await pairingService.prepare()
        let botLabel = bot.username.map { "@\($0)" } ?? "your Telegram bot"

        AgentOutput.standardError.writeString(
            """
            Telegram pairing:
              Send this code to \(botLabel): \(pairingCode)
              You can send the code alone or /start \(pairingCode).
              Waiting for Telegram...

            """
        )

        let linkedChat = try await pairingService.waitForPairing(code: pairingCode)
        let title = linkedChat.chatTitle?.nilIfBlank ?? "chat \(linkedChat.chatID)"
        AgentOutput.standardError.writeString("Telegram linked: \(title)\n")
        return AgentTelegramSettingsManifest(
            enabled: true,
            botToken: botToken,
            linkedChatID: linkedChat.chatID,
            linkedChatTitle: linkedChat.chatTitle
        )
    }

    static func newTelegramPairingCode() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)).uppercased()
    }

}
