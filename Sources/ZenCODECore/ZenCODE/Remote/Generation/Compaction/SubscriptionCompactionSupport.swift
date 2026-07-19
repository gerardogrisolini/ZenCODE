//
//  SubscriptionCompactionSupport.swift
//  ZenCODE
//
//  Shared compaction helpers for subscription-based remote generation
//  clients (ChatGPT, Anthropic). Keeps the token-budget math, message
//  counting, context-limit detection, and diagnostics in a single place so
//  the per-provider clients only differ where their behaviour genuinely
//  diverges.
//

import Foundation

enum SubscriptionCompactionSupport {
    /// Converts a raw context-window limit into the policy budget used by the
    /// shared compaction support, reserving room for the model's output.
    static func compactionPolicyMaxTokens(
        for maxTokens: Int?,
        maxOutputTokens: Int?,
        reserveTokenCount: Int
    ) -> Int? {
        guard let maxTokens, maxTokens > 0 else {
            return nil
        }
        let outputReserve = max(maxOutputTokens ?? 0, reserveTokenCount)
        let usableTokens = max(1, maxTokens - outputReserve)
        let adjustedMaxTokens = Double(usableTokens)
            / AgentConversationCompactionPolicy.triggerFraction
        return max(1, Int(adjustedMaxTokens.rounded(.up)))
    }

    /// Runs the shared compaction policy against remote-format messages,
    /// applying the provider's reserved-output budget.
    static func compactedMessagesIfNeeded(
        _ messages: [[String: Any]],
        maxTokens: Int?,
        maxOutputTokens: Int?,
        reserveTokenCount: Int,
        force: Bool
    ) -> AgentConversationCompactionResult {
        let compactionLimit = compactionPolicyMaxTokens(
            for: maxTokens,
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: reserveTokenCount
        )
        return AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            RemoteGenerationClient.agentRuntimeMessages(from: messages),
            maxTokens: compactionLimit,
            force: force
        )
    }

    static func conversationMessageCount(in messages: [[String: Any]]) -> Int {
        if let firstRole = messages.first?["role"] as? String,
           firstRole.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "system" {
            return max(messages.count - 1, 0)
        }
        return messages.count
    }

    static func compactionDiagnostic(
        from result: AgentConversationCompactionResult
    ) -> String {
        "Compacted conversation history from \(result.originalEstimatedTokenCount) to \(result.estimatedTokenCount) estimated tokens."
    }

    static func contextLimitRetryDiagnostic(
        provider: String,
        from result: AgentConversationCompactionResult
    ) -> String {
        "\(provider) context limit reached. Retrying once with compacted conversation history from \(result.originalEstimatedTokenCount) to \(result.estimatedTokenCount) estimated tokens."
    }

    static func contextLimitRetryUnavailableDiagnostic(provider: String) -> String {
        "\(provider) context limit reached, but conversation history could not be compacted for retry."
    }

    static func messageIndicatesContextLimit(_ message: String) -> Bool {
        let normalizedMessage = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedMessage.isEmpty else {
            return false
        }

        let compactMessage = normalizedMessage
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if compactMessage.contains("context_length_exceeded")
            || compactMessage.contains("context_window_exceeded")
            || compactMessage.contains("context_limit_exceeded")
            || compactMessage.contains("input_too_long")
            || compactMessage.contains("prompt_too_long")
            || compactMessage.contains("too_many_tokens") {
            return true
        }

        return normalizedMessage.contains("context length")
            || normalizedMessage.contains("context window")
            || normalizedMessage.contains("context limit")
            || normalizedMessage.contains("maximum context")
            || normalizedMessage.contains("max context")
            || normalizedMessage.contains("too many tokens")
            || normalizedMessage.contains("input is too long")
            || normalizedMessage.contains("prompt is too long")
            || normalizedMessage.contains("token limit")
            || normalizedMessage.contains("tokens exceed")
            || normalizedMessage.contains("exceeds the maximum")
            || normalizedMessage.contains("exceeded maximum")
    }
}
