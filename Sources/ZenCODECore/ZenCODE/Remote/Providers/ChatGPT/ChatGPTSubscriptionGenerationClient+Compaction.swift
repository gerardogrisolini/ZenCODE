//
//  ChatGPTSubscriptionGenerationClient+Compaction.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
#if os(macOS)
import Foundation
#if canImport(os)
import os
#endif

extension ChatGPTSubscriptionGenerationClient {
    func compactSessionForContextLimitRetry(
        _ session: inout AgentSession,
        maxTokens: Int?,
        maxOutputTokens: Int?,
        sessionIdentity: SessionIdentity
    ) -> AgentConversationCompactionResult? {
        compactSession(
            &session,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            sessionIdentity: sessionIdentity,
            force: true
        )
    }

    func compactSessionIfNeeded(
        _ session: inout AgentSession,
        maxTokens: Int?,
        maxOutputTokens: Int?,
        sessionIdentity: SessionIdentity
    ) -> AgentConversationCompactionResult? {
        compactSession(
            &session,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            sessionIdentity: sessionIdentity,
            force: false
        )
    }

    func compactSession(
        _ session: inout AgentSession,
        maxTokens: Int?,
        maxOutputTokens: Int?,
        sessionIdentity: SessionIdentity,
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
        resetContinuationAfterCompaction(
            session: &session,
            sessionIdentity: sessionIdentity
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
        let modelLLMID = modelLLMID()
        let requestConfiguration = RequestConfiguration(
            modelID: modelLLMID,
            workingDirectory: session.cwd,
            systemPrompt: session.systemPrompt ?? "",
            sessionKey: session.cacheKey?.nilIfBlank ?? session.id,
            history: [],
            allowedToolNames: session.allowedToolNames,
            thinkingSelection: session.thinkingSelection,
            appMode: configuration.appMode
        )
        guard let result = compactSession(
            &session,
            maxTokens: resolvedContextWindowTokenLimit(forLLMID: modelLLMID),
            maxOutputTokens: configuration.maxOutputTokens,
            sessionIdentity: SessionIdentity(configuration: requestConfiguration),
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

    func resetContinuationAfterCompaction(
        session: inout AgentSession,
        sessionIdentity: SessionIdentity
    ) {
        session.continuation = nil
        if let chatGPTSessionID = session.chatGPTSessionID {
            webSocketPool.closeSession(sessionID: chatGPTSessionID)
        }
        let replacementSessionID = UUID().uuidString
        session.chatGPTSessionID = replacementSessionID
        storeSessionID(replacementSessionID, for: sessionIdentity)
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
        false
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

#endif
