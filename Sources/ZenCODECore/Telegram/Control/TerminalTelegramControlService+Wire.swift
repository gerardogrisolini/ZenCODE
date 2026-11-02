//
//  TerminalTelegramControlService+Wire.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//
//  Wire-effect accounting and outbound Bot API surface of
//  ``TerminalTelegramControlService``. Extracted verbatim from
//  TerminalTelegramControlService.swift; every method keeps its actor
//  isolation, generation fence and rate governor behavior.
//

import Foundation
import ToolCore

extension TerminalTelegramControlService {
    func beginWireEffect(
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

    func endWireEffect(fence: TerminalTelegramWireFence) {
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

    func waitForWireQuiescence() async {
        while inFlightWireEffects > 0 {
            await withCheckedContinuation { wireQuiescenceWaiters.append($0) }
        }
    }

    func ensureCurrentWireGeneration(_ generation: Int) throws {
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

    func wireClient(
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
        clearSendDiagnostics()
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
            clearSendDiagnostics()
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
            clearSendDiagnostics()
            return messageID
        } catch let error as TerminalTelegramControlError {
            guard Self.isRichMessageCompatibilityError(error) else { throw error }
            try ensureCurrentWireGeneration(wireGeneration)
            let messageID = try await client.sendMessage(
                document.plainText, to: chatID, messageThreadID: topicID, replyMarkup: replyMarkup, governor: rateGovernor
            )
            try ensureCurrentWireGeneration(wireGeneration)
            clearSendDiagnostics()
            return messageID
        }
    }

    /// Sends one reasoning block as a rich message whose only block is a
    /// closed, expandable `details` (``TerminalTelegramTurnActivity/thoughtDocument(_:)``),
    /// degrading only after a definite Rich Messages rejection to plain text
    /// with the reasoning in italic by entity
    /// (``TerminalTelegramTurnActivity/thoughtFallback(_:)``). The reasoning
    /// is model output: it is never parsed as Markdown or HTML on either
    /// path. Like ``sendRichMessageWithFallback(_:to:topicID:replyMarkup:fence:)``,
    /// a transport failure is not retried, so an ambiguous send never
    /// becomes a duplicate.
    func sendThoughtMessageWithFallback(
        _ thought: String,
        to chatID: Int64,
        topicID: Int?,
        fence: TerminalTelegramWireFence
    ) async throws -> Int {
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        guard thought.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank != nil else {
            throw TerminalTelegramControlError.emptyMessage
        }
        let client = wireClient(
            token: token, generation: wireGeneration, fence: fence,
            chatID: chatID, topicID: topicID
        )
        let fallback = TerminalTelegramTurnActivity.thoughtFallback(thought)
        do {
            let messageID = try await client.sendRichMessage(
                TerminalTelegramTurnActivity.thoughtDocument(thought),
                to: chatID, messageThreadID: topicID, governor: rateGovernor
            )
            try ensureCurrentWireGeneration(wireGeneration)
            clearSendDiagnostics()
            return messageID
        } catch is CancellationError {
            throw CancellationError()
        } catch is TerminalTelegramRichMessageError {
            // Not rendered at all: nothing reached the wire.
        } catch let error as TerminalTelegramControlError {
            guard Self.isRichMessageCompatibilityError(error) else { throw error }
        }
        try ensureCurrentWireGeneration(wireGeneration)
        let messageID = try await client.sendMessage(
            fallback.text, to: chatID, messageThreadID: topicID,
            entities: fallback.entities.isEmpty ? nil : fallback.entities, governor: rateGovernor
        )
        try ensureCurrentWireGeneration(wireGeneration)
        clearSendDiagnostics()
        return messageID
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
        clearSendDiagnostics()
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
            .sendMessageDraft(
                text, to: chatID, messageThreadID: topicID, draftID: draftID, governor: rateGovernor
            )
        try ensureCurrentWireGeneration(wireGeneration)
    }

    /// Streams a structured draft and falls back to the legacy draft method on a
    /// definite API/client incompatibility. The caller's coalescer remains the
    /// sole owner of draft timing and cancellation.
    ///
    /// Both draft calls target the lease's topic (`message_thread_id` is omitted
    /// without one) and carry `canStop`. The default `true` keeps today's wire,
    /// `can_stop: true` with `keep_on_stop: true`; `false` hides the stop button
    /// and leaves `keep_on_stop` at its default.
    func sendRichMessageDraftWithFallback(
        _ text: String, to chatID: Int64, draftID: Int,
        canStop: Bool = true,
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
                document, to: chatID, messageThreadID: topicID, draftID: draftID,
                canStop: canStop, governor: rateGovernor
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch is TerminalTelegramRichMessageError {
            try ensureCurrentWireGeneration(wireGeneration)
            try await client.sendMessageDraft(
                document.plainText, to: chatID, messageThreadID: topicID, draftID: draftID,
                canStop: canStop, governor: rateGovernor
            )
        } catch let error as TerminalTelegramControlError {
            guard Self.isRichMessageCompatibilityError(error) else { throw error }
            try ensureCurrentWireGeneration(wireGeneration)
            try await client.sendMessageDraft(
                document.plainText, to: chatID, messageThreadID: topicID, draftID: draftID,
                canStop: canStop, governor: rateGovernor
            )
        }
        try ensureCurrentWireGeneration(wireGeneration)
    }

    /// Creates a topic in the private chat (Bot API 9.4) and returns its
    /// `message_thread_id`.
    ///
    /// `fence` is the lease of the route the request starts from (General or
    /// the legacy shared route), so it is validated with that lease's own
    /// thread, like ``editMessageText(_:chatID:messageID:fence:)``. This call
    /// binds nothing: the created topic gets a route of its own afterwards,
    /// from the topic-mode routing. The name is trimmed and cut on grapheme
    /// boundaries within 128 UTF-16 units; a blank name throws
    /// ``TerminalTelegramControlError/emptyMessage`` before the wire.
    func createTopic(
        name: String, chatID: Int64, fence: TerminalTelegramWireFence
    ) async throws -> Int {
        let topicID = fence.lease.effectiveMessageThreadID
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let bounded = TerminalTelegramAPIClient.boundedTopicName(name)
        guard !bounded.isEmpty else {
            throw TerminalTelegramControlError.emptyMessage
        }
        let topic = try await wireClient(
            token: token, generation: wireGeneration, fence: fence,
            chatID: chatID, topicID: topicID
        )
            .createForumTopic(chatID: chatID, name: bounded, governor: rateGovernor)
        try ensureCurrentWireGeneration(wireGeneration)
        return topic.messageThreadID
    }

    /// Renames the topic `topicID` (`editForumTopic`, name only). Like
    /// ``sendMessage(_:to:topicID:fence:)`` the fence is validated with the
    /// given `topicID`, so only the topic the lease owns can be renamed. The
    /// name is bounded as in ``createTopic(name:chatID:fence:)``.
    func renameTopic(
        name: String, chatID: Int64, topicID: Int, fence: TerminalTelegramWireFence
    ) async throws {
        let wireGeneration = try await beginWireEffect(fence: fence, chatID: chatID, topicID: topicID)
        defer { endWireEffect(fence: fence) }
        let settings = try telegramSettings()
        let token = try telegramToken(from: settings)
        let bounded = TerminalTelegramAPIClient.boundedTopicName(name)
        guard !bounded.isEmpty else {
            throw TerminalTelegramControlError.emptyMessage
        }
        try await wireClient(
            token: token, generation: wireGeneration, fence: fence,
            chatID: chatID, topicID: topicID
        )
            .editForumTopic(
                chatID: chatID, messageThreadID: topicID, name: bounded, governor: rateGovernor
            )
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
}
