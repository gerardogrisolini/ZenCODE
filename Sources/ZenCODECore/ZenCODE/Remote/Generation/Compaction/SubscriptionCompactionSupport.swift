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
import ToolCore

enum SubscriptionCompactionSupport {
    /// Coarse request estimate used only to decide whether compaction is needed.
    static func serializedPayloadTokenEstimate(_ payload: [String: Any]) -> Int? {
        guard !payload.isEmpty,
              let data = try? JSONValue(jsonObject: payload).jsonData(
                  outputFormatting: [.withoutEscapingSlashes]
              ),
              !data.isEmpty else {
            return nil
        }
        return max(Int((Double(data.count) / 4.0).rounded(.up)), 1)
    }

    /// Homogeneous split of a provider request estimate.
    ///
    /// `staticOverheadTokens` is produced by the *same* provider estimator run
    /// on a request whose conversation (system prompt included) has been
    /// removed, so it only contains the tool catalogue and the provider's own
    /// scaffolding and cannot grow with the conversation.
    ///
    /// Everything else — per-message JSON wrappers, escaped sequences,
    /// multi-byte UTF-8 — stays attached to the conversation, because it is
    /// removed together with the messages it belongs to. Subtracting the shared
    /// estimator from the provider estimate, as this used to do, folded all of
    /// that into "static overhead": a long, heavily escaped or non-ASCII
    /// history then looked like a request whose fixed cost alone overflowed the
    /// window, and the preflight declared an unsatisfiable budget that did not
    /// exist.
    struct RequestEstimate: Sendable, Equatable {
        /// Provider estimate for the request as it will be sent.
        let totalTokens: Int
        /// Provider estimate for the same request without any conversation.
        let staticOverheadTokens: Int

        init(totalTokens: Int?, staticOverheadTokens: Int?) {
            let total = max(totalTokens ?? 0, 0)
            self.totalTokens = total
            // The conversation-free request is a subset of the full one; a
            // larger value can only be a measurement artefact.
            self.staticOverheadTokens = min(max(staticOverheadTokens ?? 0, 0), total)
        }

        static let unmeasured = RequestEstimate(totalTokens: nil, staticOverheadTokens: nil)

        /// Provider tokens compaction can actually remove.
        var conversationTokens: Int {
            max(totalTokens - staticOverheadTokens, 0)
        }

        var isMeasured: Bool {
            totalTokens > 0
        }
    }

    /// What a provider request costs beyond the conversation, plus the rate at
    /// which the provider charges for the conversation itself. Both parts are
    /// derived from one estimator, so they can be cached per session and reused
    /// without mixing units.
    struct RequestOverhead: Sendable, Equatable {
        let staticOverheadTokens: Int
        let conversationInflationFactor: Double

        static let none = RequestOverhead(
            staticOverheadTokens: 0,
            conversationInflationFactor: 1.0
        )
    }

    /// Builds the end-to-end compaction budget for a subscription request.
    ///
    /// The conversation only owns what remains after the model's reserved
    /// output and the request overhead compaction cannot touch (tool catalogue,
    /// provider-injected system blocks). Feeding the raw context window to the
    /// shared policy would let the 75% target aim at tokens that are already
    /// spoken for, which is exactly what made preflight compaction repeat.
    static func compactionBudget(
        contextWindowTokens: Int?,
        maxOutputTokens: Int?,
        reserveTokenCount: Int,
        overheadTokens: Int = 0,
        conversationInflationFactor: Double = 1.0
    ) -> AgentConversationCompactionBudget {
        AgentConversationCompactionBudget(
            contextWindowTokens: contextWindowTokens,
            maxOutputTokens: max(maxOutputTokens ?? 0, reserveTokenCount),
            reservedOverheadTokens: overheadTokens,
            conversationInflationFactor: conversationInflationFactor
        )
    }

    static func compactionBudget(
        contextWindowTokens: Int?,
        maxOutputTokens: Int?,
        reserveTokenCount: Int,
        overhead: RequestOverhead
    ) -> AgentConversationCompactionBudget {
        compactionBudget(
            contextWindowTokens: contextWindowTokens,
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: reserveTokenCount,
            overheadTokens: overhead.staticOverheadTokens,
            conversationInflationFactor: overhead.conversationInflationFactor
        )
    }

    /// Decomposes a provider estimate into a static reservation and a
    /// scale-free inflation factor over the shared estimator.
    static func requestOverhead(
        estimate: RequestEstimate,
        messages: [[String: Any]]
    ) -> RequestOverhead {
        requestOverhead(
            estimate: estimate,
            runtimeConversationTokens: AgentConversationCompactionSupport.estimatedTokenCount(
                for: RemoteGenerationClient.agentRuntimeMessages(from: messages)
            )
        )
    }

    static func requestOverhead(
        estimate: RequestEstimate,
        runtimeConversationTokens: Int
    ) -> RequestOverhead {
        guard estimate.isMeasured, runtimeConversationTokens > 0 else {
            return RequestOverhead(
                staticOverheadTokens: estimate.staticOverheadTokens,
                conversationInflationFactor: 1.0
            )
        }
        return RequestOverhead(
            staticOverheadTokens: estimate.staticOverheadTokens,
            // A ratio, not a difference: it stays constant when the same kind
            // of history grows, and the budget clamps it to a sane range.
            conversationInflationFactor: Double(estimate.conversationTokens)
                / Double(runtimeConversationTokens)
        )
    }

    /// Tokens the conversation may occupy once output and overhead are
    /// reserved. Retained under its historical name because the provider
    /// clients use it as the `maxTokens` fed to the shared policy.
    static func compactionPolicyMaxTokens(
        for maxTokens: Int?,
        maxOutputTokens: Int?,
        reserveTokenCount: Int,
        overheadTokens: Int = 0
    ) -> Int? {
        compactionBudget(
            contextWindowTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: reserveTokenCount,
            overheadTokens: overheadTokens
        ).promptTokenBudget
    }

    /// Runs the shared compaction policy against remote-format messages,
    /// applying the provider's reserved-output and overhead budget.
    static func compactedMessagesIfNeeded(
        _ messages: [[String: Any]],
        maxTokens: Int?,
        maxOutputTokens: Int?,
        reserveTokenCount: Int,
        force: Bool,
        overhead: RequestOverhead = .none
    ) -> AgentConversationCompactionResult {
        AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            RemoteGenerationClient.agentRuntimeMessages(from: messages),
            budget: compactionBudget(
                contextWindowTokens: maxTokens,
                maxOutputTokens: maxOutputTokens,
                reserveTokenCount: reserveTokenCount,
                overhead: overhead
            ),
            force: force
        )
    }

    /// Compacts for the single retry that follows a provider context-limit
    /// rejection, applying a substantial and overhead-aware reduction.
    ///
    /// `overhead` is normally derived from the estimate computed for the
    /// request that was just rejected, so the retry aims at a conversation that
    /// actually fits next to the tool catalogue and the reserved output.
    static func compactedMessagesForContextLimitRetry(
        _ messages: [[String: Any]],
        maxTokens: Int?,
        maxOutputTokens: Int?,
        reserveTokenCount: Int,
        overhead: RequestOverhead = .none
    ) -> AgentConversationCompactionResult {
        AgentConversationCompactionSupport.compactedMessagesForContextLimitRetry(
            RemoteGenerationClient.agentRuntimeMessages(from: messages),
            budget: compactionBudget(
                contextWindowTokens: maxTokens,
                maxOutputTokens: maxOutputTokens,
                reserveTokenCount: reserveTokenCount,
                overhead: overhead
            )
        )
    }

    /// Compacts for a provider preflight.
    ///
    /// Three guards make the preflight terminate: an unsatisfiable budget
    /// (reserved output plus *static* overhead already fills the window) is
    /// rejected up front instead of being floored into an unreachable target,
    /// the pass only runs while the conversation is above the overhead-aware
    /// target (so the pass right after a successful compaction is a no-op), and
    /// success is never reported unless the prompt strictly shrank.
    /// Outcome of one preflight compaction pass.
    ///
    /// The unsatisfiable case is reported explicitly instead of being silently
    /// turned into "nothing to do": the request cannot be made to fit by
    /// compaction at all, so the provider must stop retrying and surface the
    /// reason once.
    enum PreflightOutcome {
        case notNeeded
        case unsatisfiableBudget(
            contextWindowTokens: Int,
            maxOutputTokens: Int,
            overheadTokens: Int
        )
        case compacted(AgentConversationCompactionResult)
    }

    static func compactedMessagesForEstimatedContextIfNeeded(
        _ messages: [[String: Any]],
        estimate: RequestEstimate,
        maxTokens: Int?,
        maxOutputTokens: Int?,
        reserveTokenCount: Int
    ) -> AgentConversationCompactionResult? {
        guard case let .compacted(result) = preflightCompaction(
            messages,
            estimate: estimate,
            maxTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: reserveTokenCount
        ) else {
            return nil
        }
        return result
    }

    static func preflightCompaction(
        _ messages: [[String: Any]],
        estimate: RequestEstimate,
        maxTokens: Int?,
        maxOutputTokens: Int?,
        reserveTokenCount: Int
    ) -> PreflightOutcome {
        let runtimeMessages = RemoteGenerationClient.agentRuntimeMessages(from: messages)
        let messageTokens = AgentConversationCompactionSupport.estimatedTokenCount(
            for: runtimeMessages
        )
        let budget = compactionBudget(
            contextWindowTokens: maxTokens,
            maxOutputTokens: maxOutputTokens,
            reserveTokenCount: reserveTokenCount,
            overhead: requestOverhead(
                estimate: estimate,
                runtimeConversationTokens: messageTokens
            )
        )

        // Unsatisfiability is a property of the reservation alone, so it is
        // decided before any trigger or message-count guard. Those guards
        // answer "not needed" for a request whose reserved output already fills
        // the window, or that holds four messages or fewer — exactly the cases
        // where no amount of compaction can help and the caller must be told
        // once instead of silently sending a request that cannot succeed.
        if budget.reservationExceedsContextWindow,
           let contextWindowTokens = budget.contextWindowTokens {
            return .unsatisfiableBudget(
                contextWindowTokens: contextWindowTokens,
                maxOutputTokens: budget.maxOutputTokens,
                overheadTokens: budget.reservedOverheadTokens
            )
        }

        guard estimate.isMeasured,
              let promptTokenBudget = budget.promptTokenBudget,
              // Both sides are shared-estimator tokens: the provider estimate
              // only contributes the static reservation and the inflation
              // factor already folded into `promptTokenBudget`.
              AgentConversationCompactionPolicy.shouldCompactHistory(
                  usedTokens: messageTokens,
                  maxTokens: promptTokenBudget,
                  messageCount: conversationMessageCount(in: messages)
              ) else {
            return .notNeeded
        }

        // Already at or below the coordinated target: compacting again would
        // shave a message at a time without ever resolving an overhead-driven
        // overflow, which is how the preflight used to spin.
        guard messageTokens
            > AgentConversationCompactionPolicy.targetTokenCount(for: promptTokenBudget) else {
            return .notNeeded
        }

        let result = AgentConversationCompactionSupport.compactedMessagesIfNeeded(
            runtimeMessages,
            budget: budget,
            force: true
        )
        guard result.wasCompacted,
              result.estimatedTokenCount < result.originalEstimatedTokenCount else {
            return .notNeeded
        }
        return .compacted(result)
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

    /// Emitted once when compaction cannot possibly help: the reserved output
    /// plus the *static* request overhead already fill the context window, so
    /// no conversation—however small—fits. The request is sent as-is and the
    /// provider error, if any, is surfaced instead of looping.
    static func unsatisfiableBudgetDiagnostic(
        provider: String,
        contextWindowTokens: Int,
        maxOutputTokens: Int,
        overheadTokens: Int
    ) -> String {
        "\(provider) request cannot fit the \(contextWindowTokens) token context window: reserved output (\(maxOutputTokens)) and request overhead (\(overheadTokens)) leave no room for the conversation. Skipping compaction."
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
