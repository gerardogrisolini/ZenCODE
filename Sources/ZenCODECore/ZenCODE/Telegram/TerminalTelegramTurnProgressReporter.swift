//
//  TerminalTelegramTurnProgressReporter.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// Single ordered outbound channel for one Telegram-mirrored turn.
///
/// Every turn-scoped message the remote chat receives — reasoning, the
/// narration that precedes a tool, the tool call itself, its failure, and the
/// permission dialogue raised while that tool is gated — is enqueued here and
/// drained by one serial task. Sending some of those messages directly while
/// others waited in a queue is what made the remote transcript arrive out of
/// order, so callers must not bypass this actor for turn output.
///
/// Buffering rules follow the semantics of the stream rather than its packet
/// boundaries: reasoning and narration accumulate as deltas and are published
/// at the boundary that proves them complete (the next tool call, the content
/// that follows the reasoning, or the end of the turn). Narration that is not
/// followed by a tool belongs to the final response and is dropped here,
/// because it is delivered once as the completion message.
actor TerminalTelegramTurnProgressReporter {
    /// Telegram rejects messages beyond ~4096 characters; stay below it.
    static let maximumMessageLength = 3_900
    /// Upper bound of one published reasoning block.
    static let maximumThoughtBlockLength = 900
    /// Upper bound of the reasoning published across a whole turn, so a verbose
    /// reasoning model cannot flood the remote chat.
    static let maximumThoughtLengthPerTurn = 4_000

    private struct QueuedMessage {
        let text: String
        let deliveryContinuation: CheckedContinuation<Bool, Never>?
    }

    let chatID: Int64
    /// Returns `true` when the message reached Telegram. Delivery status is part
    /// of the contract: a permission request that never arrived must fail closed
    /// instead of leaving the turn waiting for an answer nobody can give.
    let sendMessage: @Sendable (String, Int64) async -> Bool

    private var queue: [QueuedMessage] = []
    private var pendingAssistantContent = ""
    private var pendingThought = ""
    private var publishedThoughtCount = 0
    private var isDraining = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        chatID: Int64,
        sendMessage: @escaping @Sendable (String, Int64) async -> Bool
    ) {
        self.chatID = chatID
        self.sendMessage = sendMessage
    }

    // MARK: - Turn events

    /// Buffers a reasoning delta. The block is published when the reasoning is
    /// complete: when assistant content follows it, when a tool starts, or at
    /// the end of the turn.
    func reportThought(_ delta: String) {
        guard !delta.isEmpty,
              publishedThoughtCount < Self.maximumThoughtLengthPerTurn else {
            return
        }
        let remainingCount = Self.maximumThoughtBlockLength - pendingThought.count
        guard remainingCount > 0 else {
            return
        }
        pendingThought.append(contentsOf: delta.prefix(remainingCount))
    }

    func reportAssistantContent(_ delta: String) {
        guard !delta.isEmpty else {
            return
        }
        // Reasoning that produced this narration is complete now.
        publishPendingThought()
        guard pendingAssistantContent.count < Self.maximumMessageLength else {
            return
        }
        let remainingCount = Self.maximumMessageLength - pendingAssistantContent.count
        pendingAssistantContent.append(contentsOf: delta.prefix(remainingCount))
    }

    func reportToolCall(
        _ toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) {
        publishPendingThought()
        if let narration = pendingAssistantContent.nilIfBlank {
            enqueue(narration)
        }
        pendingAssistantContent.removeAll(keepingCapacity: true)

        enqueue(TerminalTelegramToolCallFormatter.format(
            toolCall,
            workingDirectory: workingDirectory
        ))
    }

    /// Publishes the outcome of a tool call that did not complete. Successful
    /// calls stay silent: their start message already described the work.
    func reportToolResult(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) {
        guard result.isFailure else {
            return
        }
        enqueue(TerminalTelegramToolCallFormatter.formatFailure(
            toolCall,
            result: result
        ))
    }

    /// Publishes an out-of-band turn message (permission request, decision,
    /// timeout) in the same order as the tool activity that produced it, and
    /// waits until it is actually delivered.
    ///
    /// - Returns: `true` when Telegram accepted the message.
    @discardableResult
    func send(_ message: String) async -> Bool {
        // Reasoning that preceded this message is complete.
        publishPendingThought()
        guard let text = message.nilIfBlank else {
            return false
        }
        return await withCheckedContinuation { continuation in
            queue.append(
                QueuedMessage(
                    text: String(text.prefix(Self.maximumMessageLength)),
                    deliveryContinuation: continuation
                )
            )
            startDrainingIfNeeded()
        }
    }

    /// Ends the turn: publishes any trailing reasoning, drops narration that
    /// belongs to the final response, and waits for the queue to drain so the
    /// completion message can never overtake queued progress.
    func flush() async {
        publishPendingThought()
        // Content not followed by a tool belongs to the final response, which is
        // delivered separately by sendTelegramCompletionIfLinked.
        pendingAssistantContent.removeAll(keepingCapacity: false)
        guard isDraining || !queue.isEmpty else {
            return
        }
        await withCheckedContinuation { continuation in
            idleWaiters.append(continuation)
        }
    }

    // MARK: - Queue

    private func publishPendingThought() {
        guard let text = pendingThought.nilIfBlank?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank else {
            pendingThought.removeAll(keepingCapacity: true)
            return
        }
        pendingThought.removeAll(keepingCapacity: true)
        publishedThoughtCount += text.count
        enqueue("🤔 Thinking\n\(text)")
    }

    private func enqueue(_ message: String) {
        guard let text = message.nilIfBlank else {
            return
        }
        queue.append(
            QueuedMessage(
                text: String(text.prefix(Self.maximumMessageLength)),
                deliveryContinuation: nil
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
