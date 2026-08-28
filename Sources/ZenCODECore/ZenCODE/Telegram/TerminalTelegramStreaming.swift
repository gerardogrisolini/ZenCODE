//
//  TerminalTelegramStreaming.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// Coalesces visible assistant text into Telegram's ephemeral native draft.
/// Only caller-supplied plain response text enters this actor; reasoning and
/// tool metadata have no API surface here.
actor TerminalTelegramDraftStreamer {
    static let defaultThrottle: Duration = .milliseconds(350)

    let chatID: Int64
    let draftID: Int
    private let throttle: Duration
    private let sendDraft: @Sendable (String, Int64, Int) async throws -> Void
    private var latestText = ""
    private var lastSentText = ""
    private var generation = 0
    private var deliveryTask: Task<Void, Never>?
    private var isFinished = false
    private var isSupported = true

    init(
        chatID: Int64,
        draftID: Int = Int.random(in: 1 ... Int(Int32.max)),
        throttle: Duration = TerminalTelegramDraftStreamer.defaultThrottle,
        sendDraft: @escaping @Sendable (String, Int64, Int) async throws -> Void
    ) {
        self.chatID = chatID
        self.draftID = draftID == 0 ? 1 : draftID
        self.throttle = throttle
        self.sendDraft = sendDraft
    }

    func append(_ delta: String) {
        guard !isFinished, isSupported, !delta.isEmpty else { return }
        latestText.append(delta)
        latestText = String(latestText.prefix(TerminalTelegramAPIClient.maximumMessageUTF16Length))
        scheduleIfNeeded()
    }

    func owns(chatID: Int64, draftID: Int) -> Bool {
        !isFinished && self.chatID == chatID && self.draftID == draftID
    }

    /// Stops all future wire activity. The persistent final response is sent by
    /// the reporter through `sendMessage`, independently of draft support.
    func finish() async {
        isFinished = true
        generation += 1
        let task = deliveryTask
        task?.cancel()
        deliveryTask = nil
        await task?.value
    }

    private func scheduleIfNeeded() {
        guard deliveryTask == nil else { return }
        let scheduledGeneration = generation
        deliveryTask = Task(name: "ZenCODE.Telegram.draft-throttle") { [weak self] in
            do {
                try await Task.sleep(for: self?.throttle ?? .zero)
                await self?.deliver(generation: scheduledGeneration)
            } catch {}
        }
    }

    private func deliver(generation scheduledGeneration: Int) async {
        deliveryTask = nil
        guard !isFinished, isSupported, generation == scheduledGeneration else { return }
        let text = latestText
        guard text != lastSentText else { return }
        do {
            try await sendDraft(text, chatID, draftID)
            guard !isFinished, generation == scheduledGeneration else { return }
            lastSentText = text
        } catch is CancellationError {
            return
        } catch {
            // Drafts are optional. Disable this stream after any failure; the
            // ordered final `sendMessage` remains the only persistence fallback,
            // avoiding retries after ambiguous outcomes and duplicate messages.
            isSupported = false
        }
        if latestText != lastSentText, isSupported, !isFinished {
            scheduleIfNeeded()
        }
    }
}

/// Owned editable Telegram progress card. This ledger is intentionally not the
/// shared-chat reply ledger: card receipts can never become reply targets.
actor TerminalTelegramProgressCardLedger {
    struct Ownership: Sendable, Equatable {
        let chatID: Int64
        let messageID: Int
        let generation: Int
    }

    private let chatID: Int64
    private let send: @Sendable (String, Int64) async throws -> Int
    private let editText: @Sendable (String, Int64, Int) async throws -> Void
    private let editMarkup: @Sendable (TerminalTelegramReplyMarkup?, Int64, Int) async throws -> Void
    private let delete: @Sendable (Int64, Int) async throws -> Void
    private var ownership: Ownership?
    private var generation = 0
    private var isRetired = false
    /// A failed create may have reached Telegram even though no receipt came
    /// back. Fence the ledger permanently rather than risking a duplicate card.
    private var deliveryUnknown = false

    init(
        chatID: Int64,
        send: @escaping @Sendable (String, Int64) async throws -> Int,
        editText: @escaping @Sendable (String, Int64, Int) async throws -> Void,
        editMarkup: @escaping @Sendable (TerminalTelegramReplyMarkup?, Int64, Int) async throws -> Void,
        delete: @escaping @Sendable (Int64, Int) async throws -> Void
    ) {
        self.chatID = chatID
        self.send = send
        self.editText = editText
        self.editMarkup = editMarkup
        self.delete = delete
    }

    func update(text: String, replyMarkup: TerminalTelegramReplyMarkup? = nil) async {
        guard !isRetired, !deliveryUnknown, let text = text.nilIfBlank else { return }
        let bounded = TerminalTelegramAPIClient.boundedMessageText(text)
        if let owned = ownership {
            do {
                try await editText(bounded, owned.chatID, owned.messageID)
                try await editMarkup(replyMarkup, owned.chatID, owned.messageID)
            } catch {
                // Never adopt or replace after an ambiguous edit outcome. The
                // existing ownership remains fenced and ordinary turn delivery
                // continues independently.
            }
            return
        }
        let capturedGeneration = generation
        do {
            let messageID = try await send(bounded, chatID)
            guard !isRetired, generation == capturedGeneration else {
                try? await delete(chatID, messageID)
                return
            }
            ownership = Ownership(chatID: chatID, messageID: messageID, generation: generation)
            if replyMarkup != nil {
                try? await editMarkup(replyMarkup, chatID, messageID)
            }
        } catch {
            deliveryUnknown = true
        }
    }

    func retire(deleteMessage: Bool) async {
        guard !isRetired else { return }
        isRetired = true
        generation += 1
        let owned = ownership
        ownership = nil
        guard let owned else { return }
        try? await editMarkup(nil, owned.chatID, owned.messageID)
        if deleteMessage {
            try? await delete(owned.chatID, owned.messageID)
        }
    }

    func currentOwnership() -> Ownership? { ownership }
}
