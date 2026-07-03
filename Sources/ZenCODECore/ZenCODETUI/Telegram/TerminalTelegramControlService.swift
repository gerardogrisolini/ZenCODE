//
//  TerminalTelegramControlService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct TerminalTelegramControlState: Equatable, Sendable {
    public var isConfigured: Bool
    public var isActive: Bool
    public var statusText: String
    public var botUsername: String?
    public var lastError: String?
    public var lastMessagePreview: String?

    public static func inactive(
        settings: AgentTelegramSettingsManifest? = AgentSettingsManifestStore.load()?.telegram
    ) -> Self {
        let isConfigured = settings?.isEnabled == true
        return Self(
            isConfigured: isConfigured,
            isActive: false,
            statusText: isConfigured ? "Configured" : "Not configured",
            botUsername: nil,
            lastError: nil,
            lastMessagePreview: nil
        )
    }
}

public struct TerminalTelegramIncomingMessage: Equatable, Sendable {
    public let chatID: Int64
    public let userID: Int64
    public let text: String?
    public let voice: TerminalTelegramVoiceAttachment?
    public let messageID: Int
    public let chatTitle: String?
    public let username: String?
}

public struct TerminalTelegramVoiceAttachment: Equatable, Sendable {
    public let fileID: String
    public let fileUniqueID: String?
    public let duration: Int?
    public let mimeType: String?
    public let fileSize: Int?
}

public struct TerminalTelegramBotIdentity: Equatable, Sendable {
    public let username: String?
}

public struct TerminalTelegramLinkedChat: Equatable, Sendable {
    public let chatID: Int64
    public let chatTitle: String?
}

public actor TerminalTelegramPairingService {
    private let client: TerminalTelegramAPIClient
    private var lastUpdateID: Int?

    public init(botToken: String) {
        client = TerminalTelegramAPIClient(token: botToken)
    }

    public func prepare() async throws -> TerminalTelegramBotIdentity {
        _ = try? await client.deleteWebhook(dropPendingUpdates: true)
        let bot = try await client.getMe()
        return TerminalTelegramBotIdentity(username: bot.username)
    }

    public func waitForPairing(code: String) async throws -> TerminalTelegramLinkedChat {
        let expectedCode = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        while !Task.isCancelled {
            let updates = try await client.getUpdates(
                offset: lastUpdateID.map { $0 + 1 },
                timeout: 30
            )
            for update in updates {
                lastUpdateID = update.updateID
                guard let message = update.message,
                      let text = message.text?.nilIfBlank,
                      let user = message.from,
                      user.isBot != true else {
                    continue
                }

                guard Self.pairingCode(in: text) == expectedCode else {
                    try? await client.sendMessage(
                        "ZenCODE setup is waiting for the pairing code shown in the terminal.",
                        to: message.chat.id
                    )
                    continue
                }

                try? await client.sendMessage(
                    "Telegram linked to ZenCODE.",
                    to: message.chat.id
                )
                return TerminalTelegramLinkedChat(
                    chatID: message.chat.id,
                    chatTitle: message.chat.displayTitle
                )
            }
        }
        throw CancellationError()
    }

    public nonisolated static func pairingCode(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let parts = trimmed.split(
            maxSplits: 1,
            omittingEmptySubsequences: true,
            whereSeparator: { $0.isWhitespace || $0.isNewline }
        )
        guard let firstPart = parts.first else {
            return nil
        }

        let command = String(firstPart).lowercased()
        if command == "/start" || command.hasPrefix("/start@") {
            guard parts.count == 2 else {
                return nil
            }
            return String(parts[1])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
        }

        return trimmed.uppercased()
    }
}

public actor TerminalTelegramControlService {
    public nonisolated let incomingMessages: AsyncStream<TerminalTelegramIncomingMessage>

    private let incomingContinuation: AsyncStream<TerminalTelegramIncomingMessage>.Continuation
    private var state: TerminalTelegramControlState
    private var pollingTask: Task<Void, Never>?
    private var lastUpdateID: Int?

    public init() {
        var continuation: AsyncStream<TerminalTelegramIncomingMessage>.Continuation!
        incomingMessages = AsyncStream { streamContinuation in
            continuation = streamContinuation
        }
        incomingContinuation = continuation
        state = TerminalTelegramControlState.inactive()
    }

    deinit {
        pollingTask?.cancel()
        // Terminate the stream so any `for await` consumer of `incomingMessages`
        // (e.g. the Telegram forwarding task) resumes and unwinds instead of
        // staying suspended after the service is deallocated.
        incomingContinuation.finish()
    }

    public func currentState() -> TerminalTelegramControlState {
        state
    }

    public func start() async throws -> TerminalTelegramControlState {
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let client = TerminalTelegramAPIClient(token: token)

        // Stop any previous polling before starting a new session so a failure
        // below cannot leave a stale poller running.
        stopPolling()

        let bot: TerminalTelegramUser
        do {
            _ = try? await client.deleteWebhook(dropPendingUpdates: false)
            bot = try await client.getMe()
        } catch {
            state.isActive = false
            state.lastError = error.localizedDescription
            throw error
        }

        state = TerminalTelegramControlState(
            isConfigured: true,
            isActive: true,
            statusText: bot.username.map { "Active as @\($0)" } ?? "Active",
            botUsername: bot.username,
            lastError: nil,
            lastMessagePreview: state.lastMessagePreview
        )
        pollingTask = Task { [weak self] in
            await self?.poll(token: token)
        }
        return state
    }

    public func stop() -> TerminalTelegramControlState {
        stopPolling()
        let settings = AgentSettingsManifestStore.load()?.telegram
        state.isConfigured = settings?.isEnabled == true
        state.isActive = false
        state.statusText = state.isConfigured ? "Configured" : "Not configured"
        return state
    }

    public func sendMessage(
        _ text: String,
        to chatID: Int64
    ) async throws -> TerminalTelegramControlState {
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TerminalTelegramControlError.emptyMessage
        }

        let client = TerminalTelegramAPIClient(token: token)
        do {
            try await client.sendMessage(trimmed, to: chatID, parseMode: "Markdown")
        } catch {
            // Telegram rejects messages whose Markdown markup is malformed.
            // Fall back to plain text so the message is still delivered.
            try await client.sendMessage(trimmed, to: chatID)
        }
        state.lastError = nil
        return state
    }

    public func sendAudio(
        _ audio: AgentVoiceSynthesisOutput,
        to chatID: Int64
    ) async throws -> TerminalTelegramControlState {
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        guard FileManager.default.fileExists(atPath: audio.fileURL.path) else {
            throw TerminalTelegramControlError.missingAudioFile(audio.fileURL.path)
        }

        try await TerminalTelegramAPIClient(token: token)
            .sendAudio(audio, to: chatID)
        state.lastError = nil
        return state
    }

    public func downloadVoiceAudio(
        _ voice: TerminalTelegramVoiceAttachment
    ) async throws -> AgentVoiceAudioInput {
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let downloadedFile = try await TerminalTelegramAPIClient(token: token)
            .downloadFile(fileID: voice.fileID)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-telegram-voice-\(UUID().uuidString)")
            .appendingPathExtension(Self.fileExtension(for: downloadedFile.filename))
        try downloadedFile.data.write(to: temporaryURL, options: .atomic)
        return AgentVoiceAudioInput(
            fileURL: temporaryURL,
            filename: downloadedFile.filename,
            contentType: voice.mimeType ?? Self.contentType(for: downloadedFile.filename),
            removeAfterUse: true
        )
    }

    private func telegramSettings() throws -> AgentTelegramSettingsManifest {
        guard let settings = AgentSettingsManifestStore.load()?.telegram,
              settings.isConfigured else {
            throw TerminalTelegramControlError.missingConfiguration
        }
        return settings
    }

    private func telegramToken(from settings: AgentTelegramSettingsManifest) throws -> String {
        guard let token = settings.botToken?.nilIfBlank else {
            throw TerminalTelegramControlError.missingConfiguration
        }
        return token
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func poll(token: String) async {
        let client = TerminalTelegramAPIClient(token: token)
        while !Task.isCancelled {
            do {
                let updates = try await client.getUpdates(
                    offset: lastUpdateID.map { $0 + 1 },
                    timeout: 30
                )
                for update in updates {
                    lastUpdateID = update.updateID
                    handle(update)
                }
                state.lastError = nil
            } catch is CancellationError {
                return
            } catch {
                state.lastError = error.localizedDescription
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func handle(_ update: TerminalTelegramUpdate) {
        guard state.isActive,
              let message = update.message,
              let user = message.from,
              user.isBot != true else {
            return
        }

        let text = message.text?.nilIfBlank
        let voice = message.voice.map {
            TerminalTelegramVoiceAttachment(
                fileID: $0.fileID,
                fileUniqueID: $0.fileUniqueID,
                duration: $0.duration,
                mimeType: $0.mimeType,
                fileSize: $0.fileSize
            )
        }
        guard text != nil || voice != nil else {
            return
        }

        state.lastMessagePreview = text ?? "voice message"
        incomingContinuation.yield(
            TerminalTelegramIncomingMessage(
                chatID: message.chat.id,
                userID: user.id,
                text: text,
                voice: voice,
                messageID: message.messageID,
                chatTitle: message.chat.displayTitle,
                username: user.username
            )
        )
    }

    private nonisolated static func contentType(for filename: String) -> String? {
        switch URL(fileURLWithPath: filename).pathExtension.lowercased() {
        case "oga", "ogg":
            return "audio/ogg"
        case "m4a":
            return "audio/mp4"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        default:
            return nil
        }
    }

    private nonisolated static func fileExtension(for filename: String) -> String {
        URL(fileURLWithPath: filename).pathExtension.nilIfBlank ?? "oga"
    }

}

