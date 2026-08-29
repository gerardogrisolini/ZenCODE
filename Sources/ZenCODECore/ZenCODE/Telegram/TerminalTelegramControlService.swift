//
//  TerminalTelegramControlService.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation
import Synchronization
import ToolCore

private final class TerminalTelegramLifecycleGate: Sendable {
    private let active = Mutex(false)
    func setActive(_ value: Bool) { active.withLock { $0 = value } }
    var isActive: Bool { active.withLock { $0 } }
}
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
    /// Epoch emitted by the active service lifecycle and captured by every
    /// production wire fence. It changes on every successful start.
    public var wireLifecycleEpoch: UUID?

    public init(
        isConfigured: Bool,
        isActive: Bool,
        statusText: String,
        botUsername: String?,
        lastError: String?,
        lastMessagePreview: String?,
        wireLifecycleEpoch: UUID? = nil
    ) {
        self.isConfigured = isConfigured
        self.isActive = isActive
        self.statusText = statusText
        self.botUsername = botUsername
        self.lastError = lastError
        self.lastMessagePreview = lastMessagePreview
        self.wireLifecycleEpoch = wireLifecycleEpoch
    }

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
            lastMessagePreview: nil,
            wireLifecycleEpoch: nil
        )
    }
}

public struct TerminalTelegramIncomingMessage: Equatable, Sendable {
    public let chatID: Int64
    public let userID: Int64
    public let topicID: Int?
    public let chatKind: TerminalTelegramChatKind
    public let text: String?
    public let voice: TerminalTelegramVoiceAttachment?
    public let messageID: Int
    public let chatTitle: String?
    public let username: String?
    /// Identifier of the message this one replies to, when the user used
    /// Telegram's *Reply* action. It is the only durable link between a card the
    /// bot sent and the answer typed for it.
    public let replyToMessageID: Int?
    /// Non-nil only for a Telegram inline-keyboard callback. Keeping callbacks
    /// on the existing ingress stream preserves source compatibility.
    public let callbackQueryID: String?
    public let callbackData: String?
    /// Native Telegram draft generation stopped by the linked user. This event
    /// has no ordinary message/user identifier on the Bot API wire.
    public let stoppedMessageGenerationDraftID: Int?
    /// Selective media ingress: an admitted document or photo attachment.
    /// `nil` for every message that carries neither (or whose media was
    /// refused by the ingress gate).
    public let attachment: TerminalTelegramInboundAttachment?

    /// Trailing default keeps existing call sites source-compatible while the
    /// reply link is optional on the wire.
    public init(
        chatID: Int64,
        userID: Int64,
        topicID: Int? = nil,
        chatKind: TerminalTelegramChatKind = .privateChat,
        text: String?,
        voice: TerminalTelegramVoiceAttachment?,
        messageID: Int,
        chatTitle: String?,
        username: String?,
        replyToMessageID: Int? = nil,
        callbackQueryID: String? = nil,
        callbackData: String? = nil,
        stoppedMessageGenerationDraftID: Int? = nil,
        attachment: TerminalTelegramInboundAttachment? = nil
    ) {
        self.chatID = chatID
        self.userID = userID
        self.topicID = topicID
        self.chatKind = chatKind
        self.text = text
        self.voice = voice
        self.messageID = messageID
        self.chatTitle = chatTitle
        self.username = username
        self.replyToMessageID = replyToMessageID
        self.callbackQueryID = callbackQueryID
        self.callbackData = callbackData
        self.stoppedMessageGenerationDraftID = stoppedMessageGenerationDraftID
        self.attachment = attachment
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
    public let userID: Int64
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
    /// Grants issued by this pairing session; consumed atomically by payload.
    private let grantStore = TerminalTelegramPairingGrantStore()

    public init(botToken: String) {
        client = TerminalTelegramAPIClient(token: botToken)
    }

    public func prepare() async throws -> TerminalTelegramBotIdentity {
        _ = try? await client.deleteWebhook(dropPendingUpdates: true)
        let bot = try await client.getMe()
        return TerminalTelegramBotIdentity(username: bot.username)
    }

    /// Issues one single-use pairing grant and returns the payload to embed in
    /// the deep link (and to show for manual fallback). The terminal shows:
    ///   https://t.me/<bot>?start=<payload>
    /// and Telegram delivers `/start <payload>` back to the bot. The payload is
    /// also shown as a manual code, so a client that cannot open links still
    /// pairs by sending it as a plain message.
    public func issuePairingGrant() async -> String {
        await grantStore.issueGrant()
    }

    /// Convenience for setup: issue a grant and build the deep link for the
    /// paired bot username in one call.
    public func issuePairingDeepLink(botUsername: String?) async -> (
        payload: String, deepLink: String?
    ) {
        let payload = await grantStore.issueGrant()
        let link = botUsername.map {
            TerminalTelegramPairingGrantLink.deepLink(botUsername: $0, payload: payload)
        }
        return (payload, link)
    }

    /// Consumes a grant payload atomically. Returns `true` exactly once per
    /// issued, unexpired grant.
    public func consumePairingGrant(payload: String) async -> Bool {
        await grantStore.consume(payload: payload)
    }

    /// Chat-aware consume used by ingress: rejected group presentations never
    /// spend a grant that may still be completed from the intended private chat.
    public func consumePairingGrant(payload: String, chatType: String) async -> Bool {
        guard Self.allowsPairing(chatType: chatType) else { return false }
        return await grantStore.consume(payload: payload)
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
                lastUpdateID = max(lastUpdateID ?? update.updateID, update.updateID)
                guard let message = update.message,
                      let text = message.text?.nilIfBlank,
                      let user = message.from,
                      user.isBot != true else {
                    continue
                }

                // A deep-link `/start <payload>` carries a pairing grant: it is
                // consumed exactly once, atomically, before the link is
                // accepted. The same rule covers the manual fallback, where
                // the operator types the payload (or `/start <payload>`) as a
                // plain message.
                let candidate = Self.pairingCode(in: text)
                    ?? TerminalTelegramPairingGrantLink.payload(fromStartCommand: text)
                if let candidate {
                    guard Self.allowsPairing(chatType: message.chat.type) else {
                        _ = try? await client.sendMessage(
                            "For security, ZenCODE can only be linked from a private Telegram chat.",
                            to: message.chat.id
                        )
                        continue
                    }
                    guard await consumePairingGrant(
                        payload: candidate, chatType: message.chat.type
                    ) else {
                        continue
                    }
                    try await client.sendMessage(
                        "Telegram linked to ZenCODE.",
                        to: message.chat.id
                    )
                    return TerminalTelegramLinkedChat(
                        chatID: message.chat.id,
                        userID: user.id,
                        chatTitle: message.chat.displayTitle
                    )
                }

                guard Self.pairingCode(in: text) == expectedCode else {
                    _ = try? await client.sendMessage(
                        "ZenCODE setup is waiting for the pairing code shown in the terminal.",
                        to: message.chat.id
                    )
                    continue
                }

                guard Self.allowsPairing(chatType: message.chat.type) else {
                    _ = try? await client.sendMessage(
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
                    userID: user.id,
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
    /// Injectable transport factory so a test can drive the production polling,
    /// filtering and sending path through a fake HTTP transport. Production
    /// keeps the shared NIO engine.
    let transportFactory: @Sendable () -> any TelegramHTTPTransport
    /// Capacity of the bounded inbound mailbox. Kept public and source-compatible
    /// with 2.0.1.
    public static let incomingMessageBufferLimit = 64
    /// Bounded, lossless inbound queue: the actual RAM bound and the producer
    /// backpressure live here.
    nonisolated let incomingMailbox: TerminalTelegramMailbox<TerminalTelegramIncomingMessage>
    /// Source-compatible 2.0.1 façade over ``incomingMailbox``. The stream is
    /// demand-driven (`unfolding`), so it pulls exactly one element per consumer
    /// request and adds no buffer of its own.
    ///
    /// A **fresh** stream is vended per access on purpose. `AsyncStream(unfolding:)`
    /// is one-shot: the first `nil` — a superseded receiver during a consumer
    /// handoff, a cancelled forwarding task, or a restarted panel loop — marks it
    /// terminated forever, and every later iterator of that same stored value
    /// then completes immediately. Storing it in a `let` therefore silently and
    /// permanently killed Telegram ingress for the rest of the process while
    /// `/telegram on` still reported success. The mailbox itself stays the single
    /// shared, bounded, backpressured queue, so re-vending adds no buffering and
    /// cannot duplicate or drop an element.
    public nonisolated var incomingMessages: AsyncStream<TerminalTelegramIncomingMessage> {
        let mailbox = incomingMailbox
        return AsyncStream(unfolding: { await mailbox.nextElement() })
    }
    private var state: TerminalTelegramControlState
    private var pollingTask: Task<Void, Never>?
    private var commandMenuTask: Task<Void, Never>?
    private var dispatcherSubscription: TerminalTelegramBotDispatcher.Subscription?
    private var linkedChatID: Int64?
    private var botID: Int64?
    /// Message-send rate governor shared by every outbound path of this
    /// service instance. See ``TerminalTelegramRateGovernor``.
    private let rateGovernor = TerminalTelegramRateGovernor()
    private let dispatcher: TerminalTelegramBotDispatcher
    private let lifecycleGate: TerminalTelegramLifecycleGate
    /// Lifecycle-safe presence lease manager for `sendChatAction`.
    private lazy var presenceLeaseManager = TerminalTelegramPresenceLeaseManager(
        sendAction: { [weak self] scope in
            await self?.sendPresenceAction(scope)
        }
    )
    /// Outbound consent: one explicit single-use grant per uploaded artifact.
    private let artifactConsent = TerminalTelegramArtifactConsentBroker()
    /// Selective, bounded receiver for inbound documents/photos. Owns the
    /// 0600 temporaries and their deterministic cleanup.
    private let inboundAttachments = TerminalTelegramInboundAttachmentStore()

    public init() {
        self.init(
            transportFactory: { NIOTelegramHTTPTransport() },
            dispatcher: .shared
        )
    }

    init(
        transportFactory: @escaping @Sendable () -> any TelegramHTTPTransport,
        dispatcher: TerminalTelegramBotDispatcher = TerminalTelegramBotDispatcher()
    ) {
        self.transportFactory = transportFactory
        self.dispatcher = dispatcher
        let lifecycleGate = TerminalTelegramLifecycleGate()
        self.lifecycleGate = lifecycleGate
        let mailbox = TerminalTelegramMailbox<TerminalTelegramIncomingMessage>(
            capacity: Self.incomingMessageBufferLimit
        )
        incomingMailbox = mailbox
        state = TerminalTelegramControlState.inactive()
    }

    /// Monotonic token bumped by every `start()`/`stop()`. An in-flight
    /// `start()` captures the generation and, after each suspension point, may
    /// only mutate state or install the poller while it is still the current
    /// generation. This makes a `start()` that resumes after an interleaving
    /// `stop()` give up instead of resurrecting polling, and prevents two
    /// concurrent `start()` calls from orphaning a poller.
    private var pollingGeneration = 0
    /// Every admitted wire operation holds one slot. `stop()` advances the epoch
    /// and does not return until all slots from the retired epoch have unwound.
    private var inFlightWireEffects = 0
    private var wireQuiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    private var inFlightWireEffectsByFence: [ObjectIdentifier: Int] = [:]
    private var fenceQuiescenceWaiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]

    deinit {
        pollingTask?.cancel()
        // Terminate the stream so any `for await` consumer of `incomingMessages`
        // (e.g. the Telegram forwarding task) resumes and unwinds instead of
        // staying suspended after the service is deallocated.
        let mailbox = incomingMailbox
        Task { await mailbox.finish() }
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
        await stopPolling()

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

        guard let configuredChatID = settings.linkedChatID ?? settings.routes.first?.chatID else {
            throw TerminalTelegramControlError.missingConfiguration
        }
        linkedChatID = configuredChatID
        botID = bot.id

        state = TerminalTelegramControlState(
            isConfigured: true,
            isActive: true,
            statusText: bot.username.map { "Active as @\($0)" } ?? "Active",
            botUsername: bot.username,
            lastError: nil,
            lastMessagePreview: state.lastMessagePreview,
            wireLifecycleEpoch: UUID()
        )
        lifecycleGate.setActive(true)
        publishCommandMenu(client: client)
        let subscription = try await dispatcher.subscribe(
            botID: bot.id, client: client
        )
        do {
            try ensureCurrentGeneration(generation)
        } catch {
            await dispatcher.unsubscribe(subscription)
            throw error
        }
        dispatcherSubscription = subscription
        pollingTask = Task(name: "ZenCODE.Telegram.dispatch-consumer") { [weak self] in
            for await update in subscription.updates {
                guard !Task.isCancelled else { return }
                await self?.handle(update)
            }
        }
        return state
    }

    public func stop() async -> TerminalTelegramControlState {
        // Bump the generation so any in-flight `start()` that resumes afterwards
        // cannot reactivate polling or mutate state.
        pollingGeneration += 1
        lifecycleGate.setActive(false)
        await stopPolling()
        let menuTask = commandMenuTask
        commandMenuTask = nil
        menuTask?.cancel()
        await menuTask?.value
        await waitForWireQuiescence()
        linkedChatID = nil
        botID = nil
        // Cleanup is part of the stop barrier. Once this method returns, no
        // previous-generation lease, consent or inbound temporary survives.
        await presenceLeaseManager.releaseAll()
        await rateGovernor.reset()
        await artifactConsent.reset()
        await inboundAttachments.cleanup()
        let settings = AgentSettingsManifestStore.load()?.telegram
        state.isConfigured = settings?.isEnabled == true
        state.isActive = false
        state.wireLifecycleEpoch = nil
        state.statusText = state.isConfigured ? "Configured" : "Not configured"
        return state
    }

    /// Publishes the registry command menu to Telegram so the client shows the
    /// command list. Best-effort by design: a menu that fails to publish must
    /// not stop the link, and the failure lands in `lastError` diagnostics only.
    private func publishCommandMenu(client: TerminalTelegramAPIClient) {
        commandMenuTask?.cancel()
        let generation = pollingGeneration
        commandMenuTask = Task(name: "ZenCODE.Telegram.command-menu") { [weak self] in
            do {
                _ = try await client.setMyCommands(
                    TerminalTelegramCommandRegistry.botCommands
                )
                await self?.finishCommandMenu(generation: generation, error: nil)
            } catch {
                await self?.finishCommandMenu(generation: generation, error: error)
            }
        }
    }

    private func finishCommandMenu(generation: Int, error: Error?) {
        guard generation == pollingGeneration else { return }
        commandMenuTask = nil
        if let error {
            recordDiagnostics("Could not publish Telegram command menu: \(error.localizedDescription)")
        }
    }

    private func beginWireEffect(
        fence: TerminalTelegramWireFence,
        chatID: Int64,
        topicID: Int?
    ) async throws -> Int {
        guard state.isActive, !Task.isCancelled,
              fence.lifecycleEpoch == state.wireLifecycleEpoch else {
            throw CancellationError()
        }
        try await fence.validate(chatID: chatID, topicID: topicID)
        guard state.isActive, !Task.isCancelled else { throw CancellationError() }
        inFlightWireEffects += 1
        let fenceID = ObjectIdentifier(fence)
        inFlightWireEffectsByFence[fenceID, default: 0] += 1
        return pollingGeneration
    }

    private func endWireEffect(fence: TerminalTelegramWireFence) {
        inFlightWireEffects -= 1
        let fenceID = ObjectIdentifier(fence)
        let remaining = (inFlightWireEffectsByFence[fenceID] ?? 1) - 1
        if remaining == 0 {
            inFlightWireEffectsByFence.removeValue(forKey: fenceID)
            let fenceWaiters = fenceQuiescenceWaiters.removeValue(forKey: fenceID) ?? []
            for waiter in fenceWaiters { waiter.resume() }
        } else {
            inFlightWireEffectsByFence[fenceID] = remaining
        }
        guard inFlightWireEffects == 0 else { return }
        let waiters = wireQuiescenceWaiters
        wireQuiescenceWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func waitForWireQuiescence() async {
        while inFlightWireEffects > 0 {
            await withCheckedContinuation { wireQuiescenceWaiters.append($0) }
        }
    }

    private func ensureCurrentWireGeneration(_ generation: Int) throws {
        guard generation == pollingGeneration, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    func waitForWireQuiescence(fence: TerminalTelegramWireFence) async {
        let fenceID = ObjectIdentifier(fence)
        while inFlightWireEffectsByFence[fenceID, default: 0] > 0 {
            await withCheckedContinuation {
                fenceQuiescenceWaiters[fenceID, default: []].append($0)
            }
        }
    }

    private func validateWirePreflight(
        generation: Int,
        fence: TerminalTelegramWireFence,
        chatID: Int64,
        topicID: Int?
    ) async throws {
        try ensureCurrentWireGeneration(generation)
        try await fence.validate(chatID: chatID, topicID: topicID)
        try ensureCurrentWireGeneration(generation)
        guard state.isActive,
              fence.lifecycleEpoch == state.wireLifecycleEpoch else {
            throw CancellationError()
        }
    }

    private func wireClient(
        token: String,
        generation: Int,
        fence: TerminalTelegramWireFence,
        chatID: Int64,
        topicID: Int?
    ) -> TerminalTelegramAPIClient {
        TerminalTelegramAPIClient(
            token: token,
            transport: transportFactory(),
            preflight: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.validateWirePreflight(
                    generation: generation, fence: fence,
                    chatID: chatID, topicID: topicID
                )
            }
        )
    }

    private func recordDiagnostics(_ text: String) {
        state.lastError = text
    }

    public func sendMessage(
        _ text: String,
        to chatID: Int64,
        topicID: Int?,
        fence: TerminalTelegramWireFence
    ) async throws -> TerminalTelegramControlState {
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TerminalTelegramControlError.emptyMessage
        }

        let client = wireClient(
            token: token, generation: wireGeneration, fence: fence,
            chatID: chatID, topicID: topicID
        )
        do {
            try await client.sendMessage(trimmed, to: chatID, messageThreadID: topicID, parseMode: "Markdown", governor: rateGovernor)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TerminalTelegramControlError {
            // Telegram rejects messages whose Markdown markup is malformed.
            // Fall back to plain text so the message is still delivered.
            guard Self.isMarkdownParsingError(error) else {
                throw error
            }
            try ensureCurrentWireGeneration(wireGeneration)
            try await client.sendMessage(trimmed, to: chatID, messageThreadID: topicID, governor: rateGovernor)
        }
        try ensureCurrentWireGeneration(wireGeneration)
        state.lastError = nil
        return state
    }

    /// Sends a message as plain text and returns the Telegram receipt.
    ///
    /// Unlike ``sendMessage(_:to:)`` this never requests Markdown parsing: the
    /// payload carries live agent-authored names and text, which are untrusted
    /// content. Valid-but-unintended markup would silently change how the
    /// message reads, and there is no fallback that could restore it.
    /// Source-compatible plain-text receipt API for existing callers.
    public func sendPlainMessageWithReceipt(
        _ text: String,
        to chatID: Int64,
        topicID: Int?,
        fence: TerminalTelegramWireFence
    ) async throws -> Int {
        try await sendPlainMessageWithReceipt(
            text, to: chatID, topicID: topicID, replyMarkup: nil, fence: fence
        )
    }

    /// Persists a structured visible response, degrading to its deterministic
    /// plain-text projection only after a definite Rich Messages rejection.
    /// Transport failures are not retried as plain text because the rich send may
    /// already have succeeded and a fallback would duplicate the final answer.
    func sendRichMessageWithFallback(
        _ text: String,
        to chatID: Int64,
        topicID: Int?,
        replyMarkup: TerminalTelegramReplyMarkup? = nil,
        fence: TerminalTelegramWireFence
    ) async throws -> Int {
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let document = PresentationDocument(markdown: text)
        guard document.plainText.nilIfBlank != nil else {
            throw TerminalTelegramControlError.emptyMessage
        }
        let client = wireClient(
            token: token, generation: wireGeneration, fence: fence,
            chatID: chatID, topicID: topicID
        )
        do {
            let messageID = try await client.sendRichMessage(
                document, to: chatID, messageThreadID: topicID, replyMarkup: replyMarkup, governor: rateGovernor
            )
            try ensureCurrentWireGeneration(wireGeneration)
            state.lastError = nil
            return messageID
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as TerminalTelegramRichMessageError {
            _ = error
            try ensureCurrentWireGeneration(wireGeneration)
            let messageID = try await client.sendMessage(
                document.plainText, to: chatID, messageThreadID: topicID, replyMarkup: replyMarkup, governor: rateGovernor
            )
            try ensureCurrentWireGeneration(wireGeneration)
            state.lastError = nil
            return messageID
        } catch let error as TerminalTelegramControlError {
            guard Self.isRichMessageCompatibilityError(error) else { throw error }
            try ensureCurrentWireGeneration(wireGeneration)
            let messageID = try await client.sendMessage(
                document.plainText, to: chatID, messageThreadID: topicID, replyMarkup: replyMarkup, governor: rateGovernor
            )
            try ensureCurrentWireGeneration(wireGeneration)
            state.lastError = nil
            return messageID
        }
    }

    func sendPlainMessageWithReceipt(
        _ text: String,
        to chatID: Int64,
        topicID: Int?,
        replyMarkup: TerminalTelegramReplyMarkup?,
        fence: TerminalTelegramWireFence
    ) async throws -> Int {
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TerminalTelegramControlError.emptyMessage
        }
        let messageID = try await wireClient(
            token: token, generation: wireGeneration, fence: fence,
            chatID: chatID, topicID: topicID
        )
            .sendMessage(
                trimmed, to: chatID, messageThreadID: topicID,
                replyMarkup: replyMarkup, governor: rateGovernor
            )
        try ensureCurrentWireGeneration(wireGeneration)
        state.lastError = nil
        return messageID
    }

    func sendMessageDraft(
        _ text: String, to chatID: Int64, draftID: Int,
        fence: TerminalTelegramWireFence
    ) async throws {
        let topicID = fence.lease.effectiveMessageThreadID
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        try await wireClient(token: token, generation: wireGeneration, fence: fence, chatID: chatID, topicID: topicID)
            .sendMessageDraft(text, to: chatID, draftID: draftID, governor: rateGovernor)
        try ensureCurrentWireGeneration(wireGeneration)
    }

    /// Streams a structured draft and falls back to the legacy draft method on a
    /// definite API/client incompatibility. The caller's coalescer remains the
    /// sole owner of draft timing and cancellation.
    func sendRichMessageDraftWithFallback(
        _ text: String, to chatID: Int64, draftID: Int,
        fence: TerminalTelegramWireFence
    ) async throws {
        let topicID = fence.lease.effectiveMessageThreadID
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let document = PresentationDocument(markdown: text)
        let client = wireClient(token: token, generation: wireGeneration, fence: fence, chatID: chatID, topicID: topicID)
        do {
            try await client.sendRichMessageDraft(
                document, to: chatID, draftID: draftID, governor: rateGovernor
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch is TerminalTelegramRichMessageError {
            try ensureCurrentWireGeneration(wireGeneration)
            try await client.sendMessageDraft(
                document.plainText, to: chatID, draftID: draftID, governor: rateGovernor
            )
        } catch let error as TerminalTelegramControlError {
            guard Self.isRichMessageCompatibilityError(error) else { throw error }
            try ensureCurrentWireGeneration(wireGeneration)
            try await client.sendMessageDraft(
                document.plainText, to: chatID, draftID: draftID, governor: rateGovernor
            )
        }
        try ensureCurrentWireGeneration(wireGeneration)
    }

    func editMessageText(
        _ text: String, chatID: Int64, messageID: Int,
        fence: TerminalTelegramWireFence
    ) async throws {
        let topicID = fence.lease.effectiveMessageThreadID
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        try await wireClient(token: token, generation: wireGeneration, fence: fence, chatID: chatID, topicID: topicID)
            .editMessageText(text, chatID: chatID, messageID: messageID, governor: rateGovernor)
        try ensureCurrentWireGeneration(wireGeneration)
    }

    func editMessageReplyMarkup(
        _ markup: TerminalTelegramReplyMarkup?, chatID: Int64, messageID: Int,
        fence: TerminalTelegramWireFence
    ) async throws {
        let topicID = fence.lease.effectiveMessageThreadID
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        try await wireClient(token: token, generation: wireGeneration, fence: fence, chatID: chatID, topicID: topicID)
            .editMessageReplyMarkup(markup, chatID: chatID, messageID: messageID, governor: rateGovernor)
        try ensureCurrentWireGeneration(wireGeneration)
    }

    func deleteMessage(
        chatID: Int64, messageID: Int, fence: TerminalTelegramWireFence
    ) async throws {
        let topicID = fence.lease.effectiveMessageThreadID
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        try await wireClient(token: token, generation: wireGeneration, fence: fence, chatID: chatID, topicID: topicID)
            .deleteMessage(chatID: chatID, messageID: messageID, governor: rateGovernor)
        try ensureCurrentWireGeneration(wireGeneration)
    }

    public func answerCallbackQuery(
        _ callbackQueryID: String, chatID: Int64? = nil,
        fence: TerminalTelegramWireFence
    ) async {
        let resolvedChatID = chatID ?? fence.lease.key.chatID
        let topicID = fence.lease.effectiveMessageThreadID
        guard let wireGeneration = try? await beginWireEffect(
            fence: fence, chatID: resolvedChatID, topicID: topicID
        ) else { return }
        defer { endWireEffect(fence: fence) }
        guard let settings = try? telegramSettings(),
              let token = try? telegramToken(from: settings) else { return }
        _ = try? await wireClient(
            token: token, generation: wireGeneration, fence: fence,
            chatID: resolvedChatID, topicID: topicID
        ).answerCallbackQuery(callbackQueryID)
        _ = try? ensureCurrentWireGeneration(wireGeneration)
    }

    // MARK: - Secure artifacts

    /// Records an explicit, single-use consent offer for uploading `artifact`
    /// to `chatID`, and returns the offer id to embed in the confirmation
    /// keyboard. Returns `nil` when the broker is saturated for that chat.
    public func offerArtifactConsent(
        artifact: TerminalTelegramArtifact,
        chatID: Int64,
        userID: Int64,
        routeLease: TerminalTelegramRouteLease,
        cleanupAfterUse: Bool = false
    ) async throws -> String? {
        try await artifactConsent.offerConsent(
            artifact: artifact, chatID: chatID, userID: userID, routeLease: routeLease,
            cleanupAfterUse: cleanupAfterUse
        )
    }

    /// Consumes a single-use consent offer. Re-validates the artifact against
    /// `policy` and the on-disk fingerprint before uploading; any mismatch,
    /// expiry or replay refuses the upload (fail-closed) and the offer is
    /// spent either way.
    @discardableResult
    public func sendArtifactWithConsent(
        offerID: String,
        chatID: Int64,
        userID: Int64,
        routeLease: TerminalTelegramRouteLease,
        policy: TerminalTelegramArtifactPolicy,
        topicID: Int?,
        caption: String? = nil,
        fence: TerminalTelegramWireFence
    ) async throws -> Int? {
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let pendingArtifact = await artifactConsent.pendingOffer(
            offerID: offerID, chatID: chatID
        )?.artifact
        guard let offer = try await artifactConsent.consume(
            offerID: offerID,
            chatID: chatID,
            userID: userID,
            routeLease: routeLease,
            artifactFingerprint: pendingArtifact.flatMap {
                TerminalTelegramArtifactConsentBroker.fingerprint(of: $0)
            }
        ) else {
            return nil
        }
        defer {
            if offer.cleanupAfterUse {
                try? FileManager.default.removeItem(at: offer.artifact.fileURL)
            }
        }
        let validated = try policy.validated(offer.artifact)
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let receipt = try await wireClient(
            token: token, generation: wireGeneration, fence: fence,
            chatID: chatID, topicID: topicID
        )
            .sendDocument(
                validated, to: chatID, messageThreadID: topicID, caption: caption,
                expectedSHA256: offer.fingerprint.sha256,
                governor: rateGovernor
            )
        try ensureCurrentWireGeneration(wireGeneration)
        return receipt
    }

    /// Reads back the artifact of a still-pending offer, when present.
    public func pendingConsentArtifact(
        offerID: String, chatID: Int64
    ) async -> TerminalTelegramArtifact? {
        await artifactConsent.pendingOffer(
            offerID: offerID, chatID: chatID
        )?.artifact
    }

    private func offerArtifact(of offerID: String, chatID: Int64) async -> TerminalTelegramArtifact? {
        await artifactConsent.pendingOffer(offerID: offerID, chatID: chatID)?.artifact
    }

    /// Cancels a pending consent offer without uploading. Idempotent.
    public func cancelArtifactConsent(offerID: String, chatID: Int64) async {
        await artifactConsent.cancel(offerID: offerID, chatID: chatID)
    }

    /// Receives an admitted inbound attachment into the bounded store.
    public func receiveInboundAttachment(
        _ attachment: TerminalTelegramInboundAttachment,
        chatID: Int64,
        fence: TerminalTelegramWireFence
    ) async throws -> (url: URL, filename: String, mimeType: String) {
        let topicID = fence.lease.effectiveMessageThreadID
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let client = wireClient(token: token, generation: wireGeneration, fence: fence, chatID: chatID, topicID: topicID)
        let stored = try await inboundAttachments.receive(
            attachment, chatID: chatID, client: client,
            validateBeforeDownload: { [weak self] in
                guard let self else { throw CancellationError() }
                try await self.ensureCurrentWireGeneration(wireGeneration)
            }
        )
        try ensureCurrentWireGeneration(wireGeneration)
        return (stored.url, stored.filename, stored.mimeType)
    }

    /// Lists received-but-unconsumed attachments for a chat.
    public func inboundAttachmentFilenames(chatID: Int64) async -> [String] {
        await inboundAttachments.storedFilenames(chatID: chatID)
    }

    /// Deletes one inbound temporary. Idempotent.
    public func discardInboundAttachment(filename: String, chatID: Int64) async {
        await inboundAttachments.discard(filename: filename, chatID: chatID)
    }

    /// Deterministic cleanup of every inbound temporary for a chat.
    @discardableResult
    public func cleanupInboundAttachments(chatID: Int64? = nil) async -> Int {
        await inboundAttachments.cleanup(chatID: chatID)
    }

    // MARK: - Presence

    /// Takes a lifecycle-safe presence lease for `scope` and starts renewing
    /// the typing indicator. The lease is fenced by generation: releasing it,
    /// replacing it, or `stop()` kills the renewal loop at its next wake-up.
    public func acquirePresenceLease(
        scope: TerminalTelegramPresenceScope,
        fence: TerminalTelegramWireFence
    ) async -> TerminalTelegramPresenceLeaseManager.Lease? {
        guard state.isActive,
              scope.chatID == fence.lease.key.chatID,
              scope.topicID == fence.lease.effectiveMessageThreadID else {
            return nil
        }
        return await presenceLeaseManager.acquire(scope: scope, fence: fence)
    }

    private func sendPresenceAction(_ scope: TerminalTelegramPresenceScope) async {
        guard let fence = await presenceLeaseManager.currentFence(for: scope),
              let generation = try? await beginWireEffect(
                fence: fence, chatID: scope.chatID, topicID: scope.topicID
              ) else { return }
        defer { endWireEffect(fence: fence) }
        guard let settings = try? telegramSettings(),
              let token = try? telegramToken(from: settings) else { return }
        try? await wireClient(
            token: token, generation: generation, fence: fence,
            chatID: scope.chatID, topicID: scope.topicID
        ).sendChatAction(action: "typing", to: scope.chatID)
    }

    /// Releases a presence lease previously taken. Inert when the lease was
    /// already released or replaced.
    public func releasePresenceLease(
        _ lease: TerminalTelegramPresenceLeaseManager.Lease
    ) async {
        await presenceLeaseManager.release(lease)
    }

    public func downloadVoiceAudio(
        _ voice: TerminalTelegramVoiceAttachment,
        chatID: Int64? = nil,
        fence: TerminalTelegramWireFence
    ) async throws -> AgentVoiceAudioInput {
        let resolvedChatID = chatID ?? fence.lease.key.chatID
        let topicID = fence.lease.effectiveMessageThreadID
        let wireGeneration = try await beginWireEffect(
            fence: fence, chatID: resolvedChatID, topicID: topicID
        )
        defer { endWireEffect(fence: fence) }
        if let fileSize = voice.fileSize,
           fileSize > TerminalTelegramAPIClient.maximumAudioFileBytes {
            throw TerminalTelegramControlError.fileTooLarge(
                limit: TerminalTelegramAPIClient.maximumAudioFileBytes
            )
        }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let downloadedFile = try await wireClient(
            token: token, generation: wireGeneration, fence: fence,
            chatID: resolvedChatID, topicID: topicID
        )
            .downloadFile(
                fileID: voice.fileID,
                validateBeforeDownload: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.ensureCurrentWireGeneration(wireGeneration)
                }
            )
        try ensureCurrentWireGeneration(wireGeneration)
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
        do {
            try ensureCurrentWireGeneration(wireGeneration)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
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

    private func stopPolling() async {
        let task = pollingTask
        pollingTask = nil
        task?.cancel()
        await task?.value
        if let subscription = dispatcherSubscription {
            dispatcherSubscription = nil
            await dispatcher.unsubscribe(subscription)
        }
    }

    /// Throws `CancellationError` when this call was superseded by a newer
    /// `start()`/`stop()` (a generation bump) or the enclosing task was
    /// cancelled. Call after every suspension point before touching shared state.
    private func ensureCurrentGeneration(_ generation: Int) throws(CancellationError) {
        guard generation == pollingGeneration, !Task.isCancelled else {
            throw CancellationError()
        }
    }

    private func handle(_ update: TerminalTelegramUpdate) async {
        if let stopped = update.stoppedMessageGeneration,
           state.isActive {
            let admitted = await incomingMailbox.send(
                TerminalTelegramIncomingMessage(
                    chatID: stopped.chat.id,
                    userID: 0,
                    topicID: stopped.messageThreadID,
                    chatKind: TerminalTelegramChatKind(wireValue: stopped.chat.type),
                    text: nil,
                    voice: nil,
                    messageID: 0,
                    chatTitle: stopped.chat.displayTitle,
                    username: nil,
                    stoppedMessageGenerationDraftID: stopped.draftID
                )
            )
            guard admitted else {
                state.lastError = "Telegram ingress stopped before admitting a stop-generation event."
                return
            }
            return
        }
        if let callback = update.callbackQuery {
            await handle(callback)
            return
        }
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
        // Selective media ingress: at most one admitted document or photo per
        // message, decided by the allowlist gate before anything is yielded.
        let attachment = (message.inboundDocument ?? message.inboundPhoto)
            .flatMap(TerminalTelegramInboundAttachmentGate.admit(_:))
            .flatMap { try? $0.get() }
        guard text != nil || voice != nil || attachment != nil else {
            return
        }

        state.lastMessagePreview = text ?? voice.map { _ in "voice message" } ?? "attachment"
        let admitted = await incomingMailbox.send(
            TerminalTelegramIncomingMessage(
                chatID: message.chat.id,
                userID: user.id,
                topicID: message.messageThreadID,
                chatKind: TerminalTelegramChatKind(wireValue: message.chat.type),
                text: text,
                voice: voice,
                messageID: message.messageID,
                chatTitle: message.chat.displayTitle,
                username: user.username,
                replyToMessageID: message.replyToMessage?.messageID,
                attachment: attachment
            )
        )
        if !admitted {
            state.lastError = "Telegram ingress stopped before admitting a message."
        }
    }

    private func handle(_ callback: TerminalTelegramCallbackQuery) async {
        guard state.isActive,
              let message = callback.message,
              callback.from.isBot != true,
              let data = callback.data?.nilIfBlank else { return }
        let admitted = await incomingMailbox.send(TerminalTelegramIncomingMessage(
            chatID: message.chat.id, userID: callback.from.id,
            topicID: message.messageThreadID,
            chatKind: TerminalTelegramChatKind(wireValue: message.chat.type), text: nil, voice: nil,
            messageID: message.messageID, chatTitle: message.chat.displayTitle,
            username: callback.from.username, callbackQueryID: callback.id, callbackData: data
        ))
        if !admitted {
            state.lastError = "Telegram ingress stopped before admitting a callback."
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
        // Only 400s that mention entity parsing are markup failures; a 429 or
        // any other envelope must keep its own meaning.
        guard case let .apiFailure(status, _, description, _) = error,
              status == 400 else {
            return false
        }
        let body = description ?? ""
        let normalized = body.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return normalized.contains("can't parse entities")
            || normalized.contains("cannot parse entities")
            || normalized.contains("unsupported start tag")
    }

    /// A 400/404 Bot API response is a definite rejection, so no rich message
    /// was persisted and a legacy fallback is safe. Transport errors and 5xx
    /// responses are ambiguous and intentionally excluded.
    nonisolated static func isRichMessageCompatibilityError(
        _ error: TerminalTelegramControlError
    ) -> Bool {
        switch error {
        case let .apiFailure(status, _, _, _):
            return status == 400 || status == 404
        case let .httpError(status, _):
            return status == 400 || status == 404
        default:
            return false
        }
    }

}

