//
//  AnthropicSubscriptionGenerationClient+Compaction.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension AnthropicSubscriptionGenerationClient {
    func compactSessionForContextLimitRetry(
        _ session: inout AgentSession,
        modelLLMID: String
    ) -> AgentConversationCompactionResult? {
        compactSession(&session, modelLLMID: modelLLMID, force: true)
    }

    func compactSessionIfNeeded(
        _ session: inout AgentSession,
        modelLLMID: String
    ) -> AgentConversationCompactionResult? {
        compactSession(&session, modelLLMID: modelLLMID, force: false)
    }

    func compactSession(
        _ session: inout AgentSession,
        modelLLMID: String,
        force: Bool
    ) -> AgentConversationCompactionResult? {
        let result = Self.compactedMessagesIfNeeded(
            session.messages,
            maxTokens: resolvedContextWindowTokenLimit(forLLMID: modelLLMID),
            maxOutputTokens: resolvedMaxOutputTokens(
                forLLMID: modelLLMID,
                thinkingSelection: session.thinkingSelection
            ),
            force: force
        )
        guard result.wasCompacted else {
            return nil
        }

        session.messages = RemoteGenerationClient.remoteMessages(
            compactionResult: result,
            preservingRecentFrom: session.messages
        )
        return result
    }

    public func compactSession(
        id: String,
        force: Bool
    ) async -> AgentRuntimeSessionCompactionResult? {
        guard var session = sessions[id] else {
            return nil
        }
        guard let result = compactSession(
            &session,
            modelLLMID: modelLLMID(),
            force: force
        ) else {
            return nil
        }
        sessions[id] = session
        guard let snapshot = snapshotSession(id: id) else {
            return nil
        }
        return AgentRuntimeSessionCompactionResult(
            snapshot: snapshot,
            compactionResult: result
        )
    }

    func compactSessionForEstimatedContextIfNeeded(
        _ session: inout AgentSession,
        estimatedContextTokens: Int?,
        modelLLMID: String,
        maxOutputTokens: Int
    ) -> AgentConversationCompactionResult? {
        guard let result = Self.compactedMessagesForEstimatedContextIfNeeded(
            session.messages,
            estimatedContextTokens: estimatedContextTokens,
            maxTokens: resolvedContextWindowTokenLimit(forLLMID: modelLLMID),
            maxOutputTokens: maxOutputTokens
        ) else {
            return nil
        }

        session.messages = RemoteGenerationClient.remoteMessages(
            compactionResult: result,
            preservingRecentFrom: session.messages
        )
        return result
    }

    static let compactionReserveTokenCount = 0

    static func compactedMessagesIfNeeded(
        _ messages: [[String: Any]],
        maxTokens: Int?,
        maxOutputTokens: Int? = nil,
        force: Bool = false
    ) -> AgentConversationCompactionResult {
        SubscriptionCompactionSupport.compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: compactionReserveTokenCount,
            force: force
        )
    }

    static func compactedMessagesForEstimatedContextIfNeeded(
        _ messages: [[String: Any]],
        estimatedContextTokens: Int?,
        maxTokens: Int?,
        maxOutputTokens: Int? = nil
    ) -> AgentConversationCompactionResult? {
        guard shouldCompactEstimatedContext(
            estimatedContextTokens: estimatedContextTokens,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            messageCount: conversationMessageCount(in: messages)
        ) else {
            return nil
        }

        let result = compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            force: true
        )
        return result.wasCompacted ? result : nil
    }

    static func compactionPolicyMaxTokens(
        for maxTokens: Int?,
        maxOutputTokens: Int? = nil
    ) -> Int? {
        SubscriptionCompactionSupport.compactionPolicyMaxTokens(
            for: maxTokens,
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: compactionReserveTokenCount
        )
    }

    static func shouldCompactEstimatedContext(
        estimatedContextTokens: Int?,
        maxTokens: Int?,
        maxOutputTokens: Int?,
        messageCount: Int
    ) -> Bool {
        guard let estimatedContextTokens,
              let compactionLimit = compactionPolicyMaxTokens(
                  for: maxTokens,
                  maxOutputTokens: maxOutputTokens
              ) else {
            return false
        }
        return AgentConversationCompactionPolicy.shouldCompactHistory(
            usedTokens: estimatedContextTokens,
            maxTokens: compactionLimit,
            messageCount: messageCount
        )
    }

    static func conversationMessageCount(in messages: [[String: Any]]) -> Int {
        SubscriptionCompactionSupport.conversationMessageCount(in: messages)
    }

    static func compactionDiagnostic(
        from result: AgentConversationCompactionResult
    ) -> String {
        SubscriptionCompactionSupport.compactionDiagnostic(from: result)
    }

    static func contextLimitRetryDiagnostic(
        from result: AgentConversationCompactionResult
    ) -> String {
        SubscriptionCompactionSupport.contextLimitRetryDiagnostic(
            provider: "Anthropic Subscription",
            from: result
        )
    }

    static func contextLimitRetryUnavailableDiagnostic() -> String {
        SubscriptionCompactionSupport.contextLimitRetryUnavailableDiagnostic(
            provider: "Anthropic Subscription"
        )
    }

    static func isContextLimitError(_ error: Error) -> Bool {
        if let error = error as? RemoteGenerationClientError,
           case let .remoteFailure(message) = error {
            return messageIndicatesContextLimit(message)
        }
        return messageIndicatesContextLimit(error.localizedDescription)
    }

    static func messageIndicatesContextLimit(_ message: String) -> Bool {
        SubscriptionCompactionSupport.messageIndicatesContextLimit(message)
    }
}
