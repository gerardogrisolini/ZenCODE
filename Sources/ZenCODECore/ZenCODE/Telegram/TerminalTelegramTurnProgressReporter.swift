//
//  TerminalTelegramTurnProgressReporter.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// The only turn-scoped payloads that may be mirrored to Telegram.
///
/// Keeping this surface closed prevents reasoning, streaming deltas, and tool
/// lifecycle details from reaching the remote chat.
enum TerminalTelegramTurnPayload: Sendable {
    case agentResponse(String)
    case subAgentResponse(String)
    case tasks(String)
    case authorization(String)
    case summary(String)

    var text: String {
        switch self {
        case let .agentResponse(text),
             let .subAgentResponse(text),
             let .tasks(text),
             let .authorization(text),
             let .summary(text):
            text
        }
    }
}

/// Single FIFO outbound channel for one Telegram-mirrored turn.
///
/// All remote turn output travels through this actor so root responses, task
/// updates, delegated responses, authorization requests, the final response,
/// and its change summary retain their production order. Bot control messages
/// intentionally bypass it.
///
/// Root responses are the only payload this actor buffers. Their deltas are
/// aggregated as they stream and published as a single message at the boundary
/// that proves the block complete (the next tool call). The buffer is text
/// only: reasoning, tool identity, arguments, and results never reach it.
actor TerminalTelegramTurnProgressReporter {
    /// Telegram rejects messages beyond ~4096 characters; stay below it.
    static let maximumMessageLength = 3_900

    private struct QueuedMessage {
        let text: String
        let deliveryContinuation: CheckedContinuation<Bool, Never>?
        let isProgressCard: Bool
    }

    let chatID: Int64
    /// Returns `true` when the message reached Telegram. Delivery status is part
    /// of the authorization contract: an undeliverable request must fail closed.
    let sendMessage: @Sendable (String, Int64) async -> Bool
    private let sendDraft: (@Sendable (String, Int64, Int) async throws -> Void)?
    private var draftStreamer: TerminalTelegramDraftStreamer?
    private let progressCards: TerminalTelegramProgressCardLedger?
    private let wireFence: TerminalTelegramWireFence
    private let waitForWireQuiescence: (@Sendable (TerminalTelegramWireFence) async -> Void)?

    private var queue: [QueuedMessage] = []
    /// Root response text aggregated since the last boundary.
    private var pendingAgentResponse = ""
    private var isDraining = false
    private var drainTask: Task<Void, Never>?
    private var isRetired = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        chatID: Int64,
        sendMessage: @escaping @Sendable (String, Int64) async -> Bool,
        sendDraft: (@Sendable (String, Int64, Int) async throws -> Void)? = nil,
        progressCards: TerminalTelegramProgressCardLedger? = nil,
        wireFence: TerminalTelegramWireFence,
        waitForWireQuiescence: (@Sendable (TerminalTelegramWireFence) async -> Void)? = nil
    ) {
        self.chatID = chatID
        self.sendMessage = sendMessage
        self.sendDraft = sendDraft
        self.progressCards = progressCards
        self.wireFence = wireFence
        self.waitForWireQuiescence = waitForWireQuiescence
        if let sendDraft {
            draftStreamer = TerminalTelegramDraftStreamer(chatID: chatID, sendDraft: sendDraft)
        }
    }

    /// Queues a permitted turn payload without waiting for delivery.
    func enqueue(_ payload: TerminalTelegramTurnPayload) {
        if case let .tasks(text) = payload, let progressCards {
            _ = progressCards
            enqueue(text, deliveryContinuation: nil, isProgressCard: true)
            return
        }
        enqueue(payload.text, deliveryContinuation: nil)
    }

    // MARK: - Root response buffer

    /// `true` when aggregated root response text is waiting for its boundary.
    var hasPendingAgentResponse: Bool {
        !pendingAgentResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Aggregates one visible root response delta.
    ///
    /// Nothing is queued here: a delta is not yet a response. The buffer is
    /// bounded by the per-message limit so a long block cannot grow unbounded.
    func appendAgentResponseDelta(_ delta: String) async {
        guard !delta.isEmpty else {
            return
        }
        let remainingCount = Self.maximumMessageLength - pendingAgentResponse.count
        guard remainingCount > 0 else {
            return
        }
        pendingAgentResponse.append(contentsOf: delta.prefix(remainingCount))
        if let draftStreamer { await draftStreamer.append(delta) }
    }

    /// Publishes the aggregated root response as one intermediate message.
    ///
    /// Called at the boundary that proves the block complete, so the remote
    /// chat receives the same response the terminal rendered before the tool.
    ///
    /// - Returns: `true` when a message was queued.
    @discardableResult
    func publishPendingAgentResponseAtBoundary() async -> Bool {
        let text = pendingAgentResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pendingAgentResponse.removeAll(keepingCapacity: true)
        await rotateDraftStreamer()
        guard !text.isEmpty else {
            return false
        }
        enqueue(.agentResponse(text))
        return true
    }

    /// Returns the aggregated trailing root response without queueing it.
    ///
    /// The finalization path reads it to mirror the turn's final response
    /// alone, instead of the accumulated turn text that already contains every
    /// intermediate response published at its own boundary.
    func pendingAgentResponseText() -> String {
        pendingAgentResponse.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops the aggregated root response without publishing it.
    ///
    /// Trailing content that no tool call followed belongs to the turn's final
    /// response, which is delivered once by the finalization path; discarding
    /// it here is what keeps that response from being sent twice.
    func discardPendingAgentResponse() async {
        pendingAgentResponse.removeAll(keepingCapacity: false)
        await rotateDraftStreamer()
    }

    func ownsStoppedDraft(chatID: Int64, draftID: Int) async -> Bool {
        await draftStreamer?.owns(chatID: chatID, draftID: draftID) == true
    }

    /// Internal observability for deterministic correlation tests.
    func draftStreamerIDForTesting() async -> Int? {
        draftStreamer?.draftID
    }

    /// Fences draft/card activity for finish, error, cancellation, rebind and
    /// teardown. Progress cards are deleted; persistent turn messages remain.
    func retire() async {
        guard !isRetired else { return }
        isRetired = true
        // Synchronous epoch invalidation happens before any suspension in retire,
        // so an already-extracted delayed send is fenced at service admission.
        wireFence.invalidate()
        pendingAgentResponse.removeAll()
        let abandoned = queue
        queue.removeAll()
        for message in abandoned {
            message.deliveryContinuation?.resume(returning: false)
        }
        let task = drainTask
        task?.cancel()
        await draftStreamer?.finish()
        draftStreamer = nil
        await progressCards?.retire(deleteMessage: true)
    }

    /// Replacement/invalidation barrier. Revocation happens synchronously in
    /// `retire()`; this join is deliberately separate so ordinary completion can
    /// retire without waiting on a stale producer, while a new turn cannot adopt
    /// ownership until the old reporter has no send in flight.
    func revokeAndWait() async {
        await retire()
        await waitForWireQuiescence?(wireFence)
    }

    /// Teardown barrier. Unlike turn-to-turn `retire()`, stop must not return
    /// while a reporter send admitted by the retired lifecycle is still alive.
    func shutdown() async {
        await revokeAndWait()
    }

    private func rotateDraftStreamer() async {
        let previous = draftStreamer
        if let previous { await previous.finish() }
        if let sendDraft {
            draftStreamer = TerminalTelegramDraftStreamer(chatID: chatID, sendDraft: sendDraft)
        } else {
            draftStreamer = nil
        }
    }

    /// Queues an authorization payload and waits for its delivery result.
    ///
    /// - Returns: `true` when Telegram accepted the message.
    @discardableResult
    func send(_ payload: TerminalTelegramTurnPayload) async -> Bool {
        guard !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return await withCheckedContinuation { continuation in
            enqueue(payload.text, deliveryContinuation: continuation)
        }
    }

    /// Waits until every queued payload has been delivered.
    func flush() async {
        guard isDraining || !queue.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    private func enqueue(
        _ message: String,
        deliveryContinuation: CheckedContinuation<Bool, Never>?,
        isProgressCard: Bool = false
    ) {
        guard !isRetired else {
            deliveryContinuation?.resume(returning: false)
            return
        }
        guard let text = message.nilIfBlank else {
            deliveryContinuation?.resume(returning: false)
            return
        }
        queue.append(
            QueuedMessage(
                text: String(text.prefix(Self.maximumMessageLength)),
                deliveryContinuation: deliveryContinuation,
                isProgressCard: isProgressCard
            )
        )
        startDrainingIfNeeded()
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else {
            return
        }
        isDraining = true
        drainTask = Task(name: "ZenCODE.Telegram.progress-drain") { [weak self] in
            await self?.drain()
        }
    }

    private func drain() async {
        while let message = nextMessage() {
            guard !Task.isCancelled, !isRetired else {
                message.deliveryContinuation?.resume(returning: false)
                continue
            }
            let delivered: Bool
            if message.isProgressCard, let progressCards {
                await progressCards.update(text: message.text)
                delivered = true
            } else {
                delivered = await sendMessage(message.text, chatID)
            }
            message.deliveryContinuation?.resume(returning: delivered)
        }
    }

    private func nextMessage() -> QueuedMessage? {
        guard !queue.isEmpty else {
            isDraining = false
            drainTask = nil
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
            return nil
        }
        return queue.removeFirst()
    }
}