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
    var state: TerminalTelegramControlState
    private var pollingTask: Task<Void, Never>?
    private var commandMenuTask: Task<Void, Never>?
    private var dispatcherSubscription: TerminalTelegramBotDispatcher.Subscription?
    private var linkedChatID: Int64?
    private var botID: Int64?
    /// Message-send rate governor shared by every outbound path of this
    /// service instance. See ``TerminalTelegramRateGovernor``.
    let rateGovernor = TerminalTelegramRateGovernor()
    private let dispatcher: TerminalTelegramBotDispatcher
    private let lifecycleGate: TerminalTelegramLifecycleGate
    /// Lifecycle-safe presence lease manager for `sendChatAction`.
    lazy var presenceLeaseManager = TerminalTelegramPresenceLeaseManager(
        sendAction: { [weak self] scope in
            await self?.sendPresenceAction(scope)
        }
    )
    /// Outbound consent: one explicit single-use grant per uploaded artifact.
    let artifactConsent = TerminalTelegramArtifactConsentBroker()
    /// Selective, bounded receiver for inbound documents/photos. Owns the
    /// 0600 temporaries and their deterministic cleanup.
    let inboundAttachments = TerminalTelegramInboundAttachmentStore()

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
    var pollingGeneration = 0
    /// Every admitted wire operation holds one slot. `stop()` advances the epoch
    /// and does not return until all slots from the retired epoch have unwound.
    var inFlightWireEffects = 0
    var wireQuiescenceWaiters: [CheckedContinuation<Void, Never>] = []
    var inFlightWireEffectsByFence: [ObjectIdentifier: Int] = [:]
    var fenceQuiescenceWaiters: [ObjectIdentifier: [CheckedContinuation<Void, Never>]] = [:]

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

        guard let configuredChatID = settings.linkedChatID else {
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

    private func recordDiagnostics(_ text: String) {
        state.lastError = text
    }

    func telegramSettings() throws(TerminalTelegramControlError) -> AgentTelegramSettingsManifest {
        guard let settings = AgentSettingsManifestStore.load()?.telegram,
              settings.isConfigured else {
            throw TerminalTelegramControlError.missingConfiguration
        }
        return settings
    }

    func telegramToken(
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

