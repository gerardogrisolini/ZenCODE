//
//  ChatGPTSubscriptionGenerationClient+Compaction.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(os)
import os
#endif

extension ChatGPTSubscriptionGenerationClient {
    /// Compacts after the provider refused the request for context length.
    ///
    /// `estimate` describes the *full* conversation that is about to be
    /// compacted, not the continuation delta that happened to be on the wire:
    /// the retry always replays the whole history, so a delta-sized estimate
    /// would hide the tool catalogue and mis-size the reduction.
    func compactSessionForContextLimitRetry(
        _ session: inout AgentSession,
        maxTokens: Int?,
        maxOutputTokens: Int?,
        estimate: SubscriptionCompactionSupport.RequestEstimate
    ) -> AgentConversationCompactionResult? {
        let result = Self.compactedMessagesForContextLimitRetry(
            session.messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            overhead: SubscriptionCompactionSupport.requestOverhead(
                estimate: estimate,
                messages: session.messages
            )
        )
        guard result.wasCompacted else {
            return nil
        }

        session.messages = RemoteGenerationClient.remoteMessages(
            compactionResult: result,
            preservingRecentFrom: session.messages
        )
        resetContinuationAndTransport(session: &session)
        return result
    }

    func compactSessionIfNeeded(
        _ session: inout AgentSession,
        maxTokens: Int?,
        maxOutputTokens: Int?
    ) -> AgentConversationCompactionResult? {
        compactSession(
            &session,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            force: false
        )
    }

    func compactSession(
        _ session: inout AgentSession,
        maxTokens: Int?,
        maxOutputTokens: Int?,
        force: Bool
    ) -> AgentConversationCompactionResult? {
        let result = Self.compactedMessagesIfNeeded(
            session.messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            force: force
        )

        guard result.wasCompacted else {
            return nil
        }

        session.messages = RemoteGenerationClient.remoteMessages(
            compactionResult: result,
            preservingRecentFrom: session.messages
        )
        resetContinuationAndTransport(session: &session)
        return result
    }

    public func compactSession(
        id: String,
        force: Bool
    ) async -> AgentRuntimeSessionCompactionResult? {
        guard var session = sessions[id] else {
            return nil
        }
        let modelLLMID = modelLLMID()
        guard let result = compactSession(
            &session,
            maxTokens: resolvedContextWindowTokenLimit(forLLMID: modelLLMID),
            maxOutputTokens: configuration.maxOutputTokens,
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
        estimate: SubscriptionCompactionSupport.RequestEstimate,
        maxTokens: Int?,
        maxOutputTokens: Int?
    ) -> SubscriptionCompactionSupport.PreflightOutcome {
        let outcome = SubscriptionCompactionSupport.preflightCompaction(
            session.messages,
            estimate: estimate,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: Self.compactionReserveTokenCount
        )
        guard case let .compacted(result) = outcome else {
            return outcome
        }

        session.messages = RemoteGenerationClient.remoteMessages(
            compactionResult: result,
            preservingRecentFrom: session.messages
        )
        resetContinuationAndTransport(session: &session)
        return outcome
    }

    func resetContinuationAndTransport(session: inout AgentSession) {
        session.continuation = nil
        if let chatGPTSessionID = session.chatGPTSessionID {
            webSocketPool.closeSession(sessionID: chatGPTSessionID)
        }
        session.chatGPTSessionID = UUID().uuidString
    }

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
        estimate: SubscriptionCompactionSupport.RequestEstimate,
        maxTokens: Int?,
        maxOutputTokens: Int? = nil
    ) -> AgentConversationCompactionResult? {
        SubscriptionCompactionSupport.compactedMessagesForEstimatedContextIfNeeded(
            messages,
            estimate: estimate,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: compactionReserveTokenCount
        )
    }

    static func compactedMessagesForContextLimitRetry(
        _ messages: [[String: Any]],
        maxTokens: Int?,
        maxOutputTokens: Int? = nil,
        overhead: SubscriptionCompactionSupport.RequestOverhead = .none
    ) -> AgentConversationCompactionResult {
        SubscriptionCompactionSupport.compactedMessagesForContextLimitRetry(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: compactionReserveTokenCount,
            overhead: overhead
        )
    }

    /// Splits a ChatGPT request estimate into the part compaction cannot remove
    /// (tool catalogue) and the part it can (instructions plus conversation).
    ///
    /// Both halves come from the same builder, so no heterogeneous subtraction
    /// is involved and the static half cannot grow with the history.
    static func requestEstimate(
        instructions: String?,
        fullHistoryInput: [Any],
        toolPayloads: [[String: Any]]
    ) -> SubscriptionCompactionSupport.RequestEstimate {
        SubscriptionCompactionSupport.RequestEstimate(
            totalTokens: ChatGPTSubscriptionRequestBuilder.estimatedContextTokenCount(
                instructions: instructions,
                input: fullHistoryInput,
                toolPayloads: toolPayloads
            ),
            staticOverheadTokens: ChatGPTSubscriptionRequestBuilder.estimatedContextTokenCount(
                instructions: nil,
                input: [],
                toolPayloads: toolPayloads
            )
        )
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
            provider: "ChatGPT Subscription",
            from: result
        )
    }

    static func contextLimitRetryUnavailableDiagnostic() -> String {
        SubscriptionCompactionSupport.contextLimitRetryUnavailableDiagnostic(
            provider: "ChatGPT Subscription"
        )
    }

    static func unsatisfiableBudgetDiagnostic(
        contextWindowTokens: Int,
        maxOutputTokens: Int,
        overheadTokens: Int
    ) -> String {
        SubscriptionCompactionSupport.unsatisfiableBudgetDiagnostic(
            provider: "ChatGPT Subscription",
            contextWindowTokens: contextWindowTokens,
            maxOutputTokens: maxOutputTokens,
            overheadTokens: overheadTokens
        )
    }

    static func isContextLimitError(_ error: Error) -> Bool {
        if let error = error as? ChatGPTSubscriptionGenerationError {
            switch error {
            case let .http(_, output), let .responseFailed(output):
                return messageIndicatesContextLimit(output)
            default:
                return false
            }
        }
        return messageIndicatesContextLimit(error.localizedDescription)
    }

    static func messageIndicatesContextLimit(_ message: String) -> Bool {
        SubscriptionCompactionSupport.messageIndicatesContextLimit(message)
    }
}
