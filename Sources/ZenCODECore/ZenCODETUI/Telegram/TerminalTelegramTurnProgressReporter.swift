//
//  TerminalTelegramTurnProgressReporter.swift
//  ZenCODE
//

import Foundation
import ToolCore

actor TerminalTelegramTurnProgressReporter {
    let chatID: Int64
    let sendMessage: @Sendable (String, Int64) async -> Void
    var queue: [String] = []
    var pendingAssistantContent = ""
    var isDraining = false
    var idleWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        chatID: Int64,
        sendMessage: @escaping @Sendable (String, Int64) async -> Void
    ) {
        self.chatID = chatID
        self.sendMessage = sendMessage
    }

    func reportAssistantContent(_ delta: String) {
        guard !delta.isEmpty, pendingAssistantContent.count < 3_900 else {
            return
        }
        let remainingCount = 3_900 - pendingAssistantContent.count
        pendingAssistantContent.append(contentsOf: delta.prefix(remainingCount))
    }

    func reportToolCall(
        _ toolCall: DirectAgentToolCall,
        workingDirectory: URL
    ) {
        if let narration = pendingAssistantContent.nilIfBlank {
            enqueue(narration)
        }
        pendingAssistantContent.removeAll(keepingCapacity: true)

        enqueue(TerminalTelegramToolCallFormatter.format(
            toolCall,
            workingDirectory: workingDirectory
        ))
    }

    private func enqueue(_ message: String) {
        guard let text = message.nilIfBlank else {
            return
        }
        queue.append(String(text.prefix(3_900)))
        startDrainingIfNeeded()
    }

    func flush() async {
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

    func startDrainingIfNeeded() {
        guard !isDraining else {
            return
        }
        isDraining = true
        Task(name: "ZenCODE.Telegram.progress-drain") {
            await drain()
        }
    }

    func drain() async {
        while let message = nextMessage() {
            await sendMessage(message, chatID)
        }
    }

    func nextMessage() -> String? {
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
