//
//  TerminalTelegramControlService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
import ToolCore
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
    /// Identifier of the message this one replies to, when the user used
    /// Telegram's *Reply* action. It is the only durable link between a card the
    /// bot sent and the answer typed for it.
    public let replyToMessageID: Int?

    /// Trailing default keeps existing call sites source-compatible while the
    /// reply link is optional on the wire.
    public init(
        chatID: Int64,
        userID: Int64,
        text: String?,
        voice: TerminalTelegramVoiceAttachment?,
        messageID: Int,
        chatTitle: String?,
        username: String?,
        replyToMessageID: Int? = nil
    ) {
        self.chatID = chatID
        self.userID = userID
        self.text = text
        self.voice = voice
        self.messageID = messageID
        self.chatTitle = chatTitle
        self.username = username
        self.replyToMessageID = replyToMessageID
    }
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
    /// Single-flight guard for `waitForPairing`. Without it two overlapping
    /// waits observe the same `lastUpdateID` and a late write from one can
    /// regress the offset seen by the other, reprocessing updates and racing to
    /// complete pairing.
    private var pairingInProgress = false

    public init(botToken: String) {
        client = TerminalTelegramAPIClient(token: botToken)
    }

    public func prepare() async throws -> TerminalTelegramBotIdentity {
        _ = try? await client.deleteWebhook(dropPendingUpdates: true)
        let bot = try await client.getMe()
        return TerminalTelegramBotIdentity(username: bot.username)
    }

    public func waitForPairing(code: String) async throws -> TerminalTelegramLinkedChat {
        // Single-flight: reject a second concurrent pairing wait. Two
        // overlapping waits would share `lastUpdateID` and a late write from one
        // could regress the offset seen by the other, reprocessing updates and
        // racing to complete pairing. `CancellationError` is reused so no new
        // public error case is introduced.
        guard !pairingInProgress else {
            throw CancellationError()
        }
        pairingInProgress = true
        defer { pairingInProgress = false }

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
                    try await client.sendMessage(
                        "ZenCODE setup is waiting for the pairing code shown in the terminal.",
                        to: message.chat.id
                    )
                    continue
                }

                guard Self.allowsPairing(chatType: message.chat.type) else {
                    try await client.sendMessage(
                        "For security, ZenCODE can only be linked from a private Telegram chat.",
                        to: message.chat.id
                    )
                    continue
                }

                try await client.sendMessage(
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

    public nonisolated static func allowsPairing(chatType: String) -> Bool {
        chatType.caseInsensitiveCompare("private") == .orderedSame
    }
}

public actor TerminalTelegramControlService {
    public static let incomingMessageBufferLimit = 64
    /// Injectable transport factory so a test can drive the production polling,
    /// filtering and sending path through a fake HTTP transport. Production
    /// keeps the shared NIO engine.
    let transportFactory: @Sendable () -> any TelegramHTTPTransport
    public nonisolated let incomingMessages: AsyncStream<TerminalTelegramIncomingMessage>

    private let incomingContinuation: AsyncStream<TerminalTelegramIncomingMessage>.Continuation
    private var state: TerminalTelegramControlState
    private var pollingTask: Task<Void, Never>?
    private var lastUpdateID: Int?
    private var linkedChatID: Int64?
    private var botID: Int64?
    /// Monotonic token bumped by every `start()`/`stop()`. An in-flight
    /// `start()` captures the generation and, after each suspension point, may
    /// only mutate state or install the poller while it is still the current
    /// generation. This makes a `start()` that resumes after an interleaving
    /// `stop()` give up instead of resurrecting polling, and prevents two
    /// concurrent `start()` calls from orphaning a poller.
    private var pollingGeneration = 0

    public init() {
        self.init(transportFactory: { NIOTelegramHTTPTransport() })
    }

    init(transportFactory: @escaping @Sendable () -> any TelegramHTTPTransport) {
        self.transportFactory = transportFactory
        var continuation: AsyncStream<TerminalTelegramIncomingMessage>.Continuation!
        incomingMessages = AsyncStream(bufferingPolicy: .bufferingNewest(Self.incomingMessageBufferLimit)) {
            streamContinuation in
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
        let client = TerminalTelegramAPIClient(
            token: token,
            transport: transportFactory()
        )

        // Bump the generation to invalidate any previous start()/stop(): an
        // in-flight `start()` still suspended below will see the new generation
        // and give up. Capture it so we can detect, after every await, whether
        // we are still the authoritative call.
        pollingGeneration += 1
        let generation = pollingGeneration
        // Cancel the previous poller so a failure below cannot leave it running.
        // The generation guard (not this cancel) is what guarantees a superseded
        // start() never installs a poller.
        stopPolling()

        let bot: TerminalTelegramUser
        do {
            _ = try? await client.deleteWebhook(dropPendingUpdates: false)
            // Resumed after a suspension: bail out if superseded or cancelled.
            try ensureCurrentGeneration(generation)
            bot = try await client.getMe()
            try ensureCurrentGeneration(generation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // Only the still-current generation reports the failure to state.
            if generation == pollingGeneration {
                state.isActive = false
                state.lastError = error.localizedDescription
            }
            throw error
        }

        // After both awaits: only the current generation publishes active state
        // and installs the poller. A stop()/start() that interleaved during the
        // awaits bumped the generation, so this superseded call gives up instead
        // of resurrecting polling.
        try ensureCurrentGeneration(generation)

        guard let configuredChatID = settings.linkedChatID else {
            throw TerminalTelegramControlError.missingConfiguration
        }
        linkedChatID = configuredChatID
        botID = bot.id
        lastUpdateID = try TerminalTelegramUpdateOffsetStore.loadRequired(botID: bot.id)

        state = TerminalTelegramControlState(
            isConfigured: true,
            isActive: true,
            statusText: bot.username.map { "Active as @\($0)" } ?? "Active",
            botUsername: bot.username,
            lastError: nil,
            lastMessagePreview: state.lastMessagePreview
        )
        pollingTask = Task(name: "ZenCODE.Telegram.polling") { [weak self] in
            // The loop lives here (not inside an actor method) so `self?` is
            // retained only for the duration of a single `pollOnce` call.
            // Between iterations the weak reference can go nil when the actor is
            // released, making `deinit` reachable and letting the stream finish.
            while !Task.isCancelled {
                guard await self?.pollOnce(client: client, generation: generation) == true else {
                    return
                }
            }
        }
        return state
    }

    public func stop() -> TerminalTelegramControlState {
        // Bump the generation so any in-flight `start()` that resumes afterwards
        // cannot reactivate polling or mutate state.
        pollingGeneration += 1
        stopPolling()
        linkedChatID = nil
        botID = nil
        lastUpdateID = nil
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

        let client = TerminalTelegramAPIClient(
            token: token,
            transport: transportFactory()
        )
        do {
            try await client.sendMessage(trimmed, to: chatID, parseMode: "Markdown")
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TerminalTelegramControlError {
            // Telegram rejects messages whose Markdown markup is malformed.
            // Fall back to plain text so the message is still delivered.
            guard Self.isMarkdownParsingError(error) else {
                throw error
            }
            try await client.sendMessage(trimmed, to: chatID)
        }
        state.lastError = nil
        return state
    }

    /// Sends a message as plain text and returns the Telegram receipt.
    ///
    /// Unlike ``sendMessage(_:to:)`` this never requests Markdown parsing: the
    /// payload carries live agent-authored names and text, which are untrusted
    /// content. Valid-but-unintended markup would silently change how the
    /// message reads, and there is no fallback that could restore it.
    public func sendPlainMessageWithReceipt(
        _ text: String,
        to chatID: Int64
    ) async throws -> Int {
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TerminalTelegramControlError.emptyMessage
        }
        let messageID = try await TerminalTelegramAPIClient(
            token: token,
            transport: transportFactory()
        )
            .sendMessage(trimmed, to: chatID)
        state.lastError = nil
        return messageID
    }

    public func downloadVoiceAudio(
        _ voice: TerminalTelegramVoiceAttachment
    ) async throws -> AgentVoiceAudioInput {
        if let fileSize = voice.fileSize,
           fileSize > TerminalTelegramAPIClient.maximumAudioFileBytes {
            throw TerminalTelegramControlError.fileTooLarge(
                limit: TerminalTelegramAPIClient.maximumAudioFileBytes
            )
        }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let downloadedFile = try await TerminalTelegramAPIClient(
            token: token,
            transport: transportFactory()
        )
            .downloadFile(fileID: voice.fileID)
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODE-telegram-voice-\(UUID().uuidString)")
            .appendingPathExtension(Self.fileExtension(for: downloadedFile.filename))
        guard FileManager.default.createFile(
            atPath: temporaryURL.path,
            contents: downloadedFile.data,
            attributes: [.posixPermissions: NSNumber(value: 0o600)]
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return AgentVoiceAudioInput(
            fileURL: temporaryURL,
            filename: downloadedFile.filename,
            contentType: voice.mimeType ?? Self.contentType(for: downloadedFile.filename),
            removeAfterUse: true
        )
    }

    private func telegramSettings() throws(TerminalTelegramControlError) -> AgentTelegramSettingsManifest {
        guard let settings = AgentSettingsManifestStore.load()?.telegram,
              settings.isConfigured else {
            throw TerminalTelegramControlError.missingConfiguration
        }
        return settings
    }

    private func telegramToken(
        from settings: AgentTelegramSettingsManifest
    ) throws(TerminalTelegramControlError) -> String {
        guard let token = settings.botToken?.nilIfBlank else {
            throw TerminalTelegramControlError.missingConfiguration
        }
        return token
    }

    private func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    /// Throws `CancellationError` when this call was superseded by a newer
    /// `start()`/`stop()` (a generation bump) or the enclosing task was
    /// cancelled. Call after every suspension point before touching shared state.
    private func ensureCurrentGeneration(_ generation: Int) throws(CancellationError) {
        guard generation == pollingGeneration, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    /// One polling iteration. Returns `true` to keep polling, `false` to stop.
    /// Splitting the old infinite `poll()` loop into single-iteration calls lets
    /// the `weak self` in the polling `Task` go nil between iterations, so the
    /// actor can be deallocated and `deinit` can finish the stream.
    private func pollOnce(
        client: TerminalTelegramAPIClient,
        generation: Int
    ) async -> Bool {
        do {
            let updates = try await client.getUpdates(
                offset: lastUpdateID.map { $0 + 1 },
                timeout: 30
            )
            // Resumed after the long-poll await: stop if superseded or
            // cancelled. Only the current generation may advance `lastUpdateID`,
            // which also prevents a late write from regressing the offset.
            guard generation == pollingGeneration, !Task.isCancelled else {
                return false
            }
            for update in updates {
                guard let botID else {
                    return false
                }
                do {
                    try TerminalTelegramUpdateOffsetStore.save(
                        updateID: update.updateID,
                        botID: botID
                    )
                } catch {
                    state.lastError = "Could not persist Telegram update offset: \(error.localizedDescription)"
                    return false
                }
                lastUpdateID = update.updateID
                handle(update)
            }
            state.lastError = nil
            return true
        } catch is CancellationError {
            return false
        } catch {
            guard generation == pollingGeneration, !Task.isCancelled else {
                return false
            }
            state.lastError = error.localizedDescription
            try? await Task.sleep(for: .seconds(3))
            // Re-check after the backoff so a stop()/start() that interleaved
            // during the sleep does not keep this superseded poller alive.
            return generation == pollingGeneration && !Task.isCancelled
        }
    }

    private func handle(_ update: TerminalTelegramUpdate) {
        guard state.isActive,
              let message = update.message,
              message.chat.id == linkedChatID,
              TerminalTelegramPairingService.allowsPairing(chatType: message.chat.type),
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
        let yieldResult = incomingContinuation.yield(
            TerminalTelegramIncomingMessage(
                chatID: message.chat.id,
                userID: user.id,
                text: text,
                voice: voice,
                messageID: message.messageID,
                chatTitle: message.chat.displayTitle,
                username: user.username,
                replyToMessageID: message.replyToMessage?.messageID
            )
        )
        if case .dropped = yieldResult {
            state.lastError = "Telegram ingress overloaded; the oldest buffered message was dropped."
        }
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

    private nonisolated static func isMarkdownParsingError(
        _ error: TerminalTelegramControlError
    ) -> Bool {
        guard case let .httpError(statusCode, body) = error,
              statusCode == 400,
              let body else {
            return false
        }
        let description = body.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return description.contains("can't parse entities")
            || description.contains("cannot parse entities")
            || description.contains("unsupported start tag")
    }

}

