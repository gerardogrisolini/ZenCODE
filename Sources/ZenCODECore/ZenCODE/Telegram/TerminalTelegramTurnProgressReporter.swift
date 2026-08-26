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
    }

    let chatID: Int64
    /// Returns `true` when the message reached Telegram. Delivery status is part
    /// of the authorization contract: an undeliverable request must fail closed.
    let sendMessage: @Sendable (String, Int64) async -> Bool

    private var queue: [QueuedMessage] = []
    /// Root response text aggregated since the last boundary.
    private var pendingAgentResponse = ""
    private var isDraining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        chatID: Int64,
        sendMessage: @escaping @Sendable (String, Int64) async -> Bool
    ) {
        self.chatID = chatID
        self.sendMessage = sendMessage
    }

    /// Queues a permitted turn payload without waiting for delivery.
    func enqueue(_ payload: TerminalTelegramTurnPayload) {
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
    func appendAgentResponseDelta(_ delta: String) {
        guard !delta.isEmpty else {
            return
        }
        let remainingCount = Self.maximumMessageLength - pendingAgentResponse.count
        guard remainingCount > 0 else {
            return
        }
        pendingAgentResponse.append(contentsOf: delta.prefix(remainingCount))
    }

    /// Publishes the aggregated root response as one intermediate message.
    ///
    /// Called at the boundary that proves the block complete, so the remote
    /// chat receives the same response the terminal rendered before the tool.
    ///
    /// - Returns: `true` when a message was queued.
    @discardableResult
    func publishPendingAgentResponseAtBoundary() -> Bool {
        let text = pendingAgentResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
        pendingAgentResponse.removeAll(keepingCapacity: true)
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
    func discardPendingAgentResponse() {
        pendingAgentResponse.removeAll(keepingCapacity: false)
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
        deliveryContinuation: CheckedContinuation<Bool, Never>?
    ) {
        guard let text = message.nilIfBlank else {
            deliveryContinuation?.resume(returning: false)
            return
        }
        queue.append(
            QueuedMessage(
                text: String(text.prefix(Self.maximumMessageLength)),
                deliveryContinuation: deliveryContinuation
            )
        )
        startDrainingIfNeeded()
    }

    private func startDrainingIfNeeded() {
        guard !isDraining else {
            return
        }
        isDraining = true
        Task(name: "ZenCODE.Telegram.progress-drain") {
            await drain()
        }
    }

    private func drain() async {
        while let message = nextMessage() {
            let delivered = await sendMessage(message.text, chatID)
            message.deliveryContinuation?.resume(returning: delivered)
        }
    }

    private func nextMessage() -> QueuedMessage? {
        guard !queue.isEmpty else {
            isDraining = false
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

enum TerminalTelegramCommandAction: Equatable {
    case status
    case turnOn
    case turnOff
    case usage

    init(argument: String) {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "":
            self = .status
        case "on":
            self = .turnOn
        case "off":
            self = .turnOff
        default:
            self = .usage
        }
    }
}

enum TerminalTelegramRemoteCommand: Equatable {
    case start
    case help
    case status
    case changes
    case undo

    init?(text: String) {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let command = normalized
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? normalized
        switch normalized {
        case "/help", "help":
            self = .help
        case "/status", "status", "stato":
            self = .status
        case "/changes", "changes", "modifiche":
            self = .changes
        case "/undo", "undo", "undo changes", "annulla", "annulla modifiche":
            self = .undo
        default:
            if command == "/start" || command.hasPrefix("/start@") {
                self = .start
                return
            }
            return nil
        }
    }
}
