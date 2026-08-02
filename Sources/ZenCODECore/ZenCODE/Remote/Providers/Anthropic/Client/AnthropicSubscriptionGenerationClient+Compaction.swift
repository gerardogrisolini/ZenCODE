//
//  AnthropicSubscriptionGenerationClient+Compaction.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

import Foundation

extension AnthropicSubscriptionGenerationClient {
    /// Compacts after the provider refused the request for context length.
    ///
    /// The reduction is substantial and subtracts the overhead observed on the
    /// rejected request, because a prompt one token smaller would simply be
    /// rejected again.
    func compactSessionForContextLimitRetry(
        _ session: inout AgentSession,
        modelLLMID: String
    ) -> AgentConversationCompactionResult? {
        let result = SubscriptionCompactionSupport.compactedMessagesForContextLimitRetry(
            session.messages,
            maxTokens: resolvedContextWindowTokenLimit(forLLMID: modelLLMID),
            maxOutputTokens: resolvedMaxOutputTokens(
                forLLMID: modelLLMID,
                thinkingSelection: session.thinkingSelection
            ),
            reserveTokenCount: Self.compactionReserveTokenCount,
            overhead: requestOverhead(forSessionID: session.id)
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
            force: force,
            // The tool catalogue and provider system blocks measured on the
            // last request of this session are part of the same window, along
            // with the rate the provider charges for its conversation.
            overhead: requestOverhead(forSessionID: session.id)
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
        invalidateRequestOverhead(sessionID: id)
        guard let snapshot = snapshotSession(id: id) else {
            return nil
        }
        return AgentRuntimeSessionCompactionResult(
            snapshot: snapshot,
            compactionResult: result
        )
    }

    func compactSessionForEstimatedContextIfNeeded(
        lease: SessionLease,
        estimate: SubscriptionCompactionSupport.RequestEstimate,
        modelLLMID: String,
        maxOutputTokens: Int
    ) -> SubscriptionCompactionSupport.PreflightOutcome {
        guard let session = currentSession(for: lease) else {
            return .notNeeded
        }
        let outcome = SubscriptionCompactionSupport.preflightCompaction(
            session.messages,
            estimate: estimate,
            maxTokens: resolvedContextWindowTokenLimit(forLLMID: modelLLMID),
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: Self.compactionReserveTokenCount
        )
        guard case let .compacted(result) = outcome else {
            return outcome
        }

        // Persisted into the actor-owned session immediately: the request that
        // is about to go out and every later round must see the same compacted
        // history, and the snapshot must match the wire payload.
        guard mutateSession(for: lease, { session in
            session.messages = RemoteGenerationClient.remoteMessages(
                compactionResult: result,
                preservingRecentFrom: session.messages
            )
        }) else {
            return .notNeeded
        }
        return outcome
    }

    /// Records what the last request of a session costs beyond its
    /// conversation (tool catalogue plus provider system blocks) together with
    /// the rate the provider charges for the conversation itself.
    ///
    /// The cache is only valid while the tool catalogue, the system prompt and
    /// the session options stay put, so every lifecycle mutation that can
    /// change them drops it: a stale, oversized reservation would otherwise
    /// keep compacting a conversation that already fits.
    func recordRequestOverhead(
        estimate: SubscriptionCompactionSupport.RequestEstimate,
        messages: [[String: Any]],
        for lease: SessionLease
    ) {
        recordRequestOverhead(
            estimate: estimate,
            runtimeConversationTokens: AgentConversationCompactionSupport.estimatedTokenCount(
                for: RemoteGenerationClient.agentRuntimeMessages(from: messages)
            ),
            for: lease
        )
    }

    /// Stores a request estimate that was measured while constructing a wire
    /// payload. Keeping the actor-facing overload Sendable avoids moving the
    /// JSON bridge dictionary across actor boundaries just to cache two numbers.
    func recordRequestOverhead(
        estimate: SubscriptionCompactionSupport.RequestEstimate,
        runtimeConversationTokens: Int,
        for lease: SessionLease
    ) {
        guard sessionGenerations[lease.id] == lease.generation else {
            return
        }
        sessionRequestOverhead[lease.id] = SubscriptionCompactionSupport.requestOverhead(
            estimate: estimate,
            runtimeConversationTokens: runtimeConversationTokens
        )
    }

    func requestOverhead(
        forSessionID id: String
    ) -> SubscriptionCompactionSupport.RequestOverhead {
        sessionRequestOverhead[id] ?? .none
    }

    /// Drops the cached request overhead for one session, or for all of them.
    func invalidateRequestOverhead(sessionID: String?) {
        guard let sessionID else {
            sessionRequestOverhead.removeAll()
            return
        }
        sessionRequestOverhead.removeValue(forKey: sessionID)
    }

    /// Claims the one unsatisfiable-budget diagnostic allowed for the current
    /// user turn. A context-limit retry rebuilds this same session and can hit
    /// the same preflight again; publishing twice adds noise without new
    /// actionable information.
    func claimUnsatisfiableBudgetDiagnostic(for lease: SessionLease) -> Bool {
        guard sessionGenerations[lease.id] == lease.generation,
              var session = sessions[lease.id],
              !session.didReportUnsatisfiableBudget else {
            return false
        }
        session.didReportUnsatisfiableBudget = true
        sessions[lease.id] = session
        return true
    }

    /// Splits an Anthropic request estimate into the part compaction cannot
    /// remove (tool catalogue plus the provider's own system blocks) and the
    /// part it can (user system prompt plus messages), using one estimator on
    /// both sides.
    static func requestEstimate(
        estimatedContextTokens: Int?,
        tools: [[String: Any]]
    ) -> SubscriptionCompactionSupport.RequestEstimate {
        SubscriptionCompactionSupport.RequestEstimate(
            totalTokens: estimatedContextTokens,
            staticOverheadTokens: AnthropicSubscriptionRequestBuilder.estimatedContextTokenCount(
                system: subscriptionSystemBlocks(userSystemPrompt: nil),
                messages: [],
                tools: tools
            )
        )
    }

    static let compactionReserveTokenCount = 0

    static func compactedMessagesIfNeeded(
        _ messages: [[String: Any]],
        maxTokens: Int?,
        maxOutputTokens: Int? = nil,
        force: Bool = false,
        overhead: SubscriptionCompactionSupport.RequestOverhead = .none
    ) -> AgentConversationCompactionResult {
        SubscriptionCompactionSupport.compactedMessagesIfNeeded(
            messages,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: compactionReserveTokenCount,
            force: force,
            overhead: overhead
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
            provider: "Anthropic Subscription",
            from: result
        )
    }

    static func contextLimitRetryUnavailableDiagnostic() -> String {
        SubscriptionCompactionSupport.contextLimitRetryUnavailableDiagnostic(
            provider: "Anthropic Subscription"
        )
    }

    static func unsatisfiableBudgetDiagnostic(
        contextWindowTokens: Int,
        maxOutputTokens: Int,
        overheadTokens: Int
    ) -> String {
        SubscriptionCompactionSupport.unsatisfiableBudgetDiagnostic(
            provider: "Anthropic Subscription",
            contextWindowTokens: contextWindowTokens,
            maxOutputTokens: maxOutputTokens,
            overheadTokens: overheadTokens
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
