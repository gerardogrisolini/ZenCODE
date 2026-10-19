//
//  AgentConversationCompactionSupport+Policy.swift
//  ZenCODE
//

import Foundation
import ToolCore

public enum AgentConversationCompactionPolicy {
    /// Fraction of the budget that triggers a compaction.
    public static let triggerFraction = 0.95
    /// Fraction of the budget the compacted prompt aims to fill; the headroom is
    /// what the next turns can grow into. Model output and provider overhead are
    /// subtracted up front by `AgentConversationCompactionBudget.promptTokenBudget`.
    public static let targetFraction = 0.50
    /// Recent-window size always attempted before falling back to a smaller one.
    public static let defaultRecentMessageCount = 12
    public static let minimumRecentMessageCount = 4
    public static let maximumSummaryCharacters = 24_000
    /// Historical reference size for summaries; not a floor.
    public static let minimumSummaryCharacters = 800
    /// Share of the target budget the conversation memory summary may use.
    public static let summaryBudgetFraction = 0.30
    /// Share of the summary budget reserved for memory inherited from a previous
    /// compaction. Budget the new facts cannot use is handed back to it.
    public static let priorMemoryBudgetFraction = 0.5
    public static let minimumPriorMemoryCharacters = 1_200
    /// Smallest useful budget for a single summarised message.
    public static let minimumSummaryEntryCharacters = 120
    /// Above this per-entry budget the summariser keeps both the head and the
    /// tail of a long message instead of only its prefix.
    public static let tailPreservationCharacters = 240
    /// How far back the recent window may expand to start on a user turn.
    public static let turnBoundaryLookbackLimit = 24
    /// How many times a provider preflight may compact before giving up and
    /// letting the request go out (or fail) as-is.
    public static let maximumPreflightCompactionAttempts = 3
    /// Largest share of the conversation the single context-limit retry may keep:
    /// the provider already rejected the request, so a marginal cut would fail again.
    public static let contextLimitRetryRetentionFraction = 0.5
    /// Minimum estimated-token saving before a compaction may replace the live
    /// conversation, ruling out destructive one-token rewrites.
    public static let minimumMaterialReductionTokens = 2
    /// Share of an already-in-budget prompt retained by a forced compaction, so a
    /// lossy manual rewrite buys useful headroom.
    public static let forcedCompactionRetentionFraction = 0.90
    /// Absolute saving required when a manual force compacts a history that already
    /// fits the policy target (percentage-only retention would allow tiny rewrites).
    public static let minimumForcedCompactionSavingsTokens = 8

    public static func triggerTokenCount(for maxTokens: Int) -> Int {
        Int(Double(maxTokens) * triggerFraction)
    }

    public static func targetTokenCount(for maxTokens: Int) -> Int {
        Int(Double(maxTokens) * targetFraction)
    }

    /// Target for a forced compaction whose input already fits the policy target;
    /// eligibility separately requires `minimumForcedCompactionSavingsTokens` of headroom.
    public static func forcedTargetTokenCount(for rawTokenCount: Int) -> Int {
        let raw = max(rawTokenCount, 0)
        return Int((Double(raw) * forcedCompactionRetentionFraction).rounded(.down))
    }

    /// Whether `candidateTokens` removes enough input to justify the lossy rewrite,
    /// independent of target fit.
    public static func materiallyReducesPrompt(
        originalTokens: Int,
        candidateTokens: Int
    ) -> Bool {
        let original = max(originalTokens, 0)
        let candidate = max(candidateTokens, 0)
        return candidate < original && original - candidate >= minimumMaterialReductionTokens
    }

    /// Character budget granted to the memory summary for a target token budget.
    /// It may be below the historical reference size: a floor could make a feasible prompt impossible.
    public static func summaryCharacterBudget(forTargetTokenCount targetTokenCount: Int) -> Int {
        let characters = Int(
            (Double(max(targetTokenCount, 0)) * 4.0 * summaryBudgetFraction).rounded(.down)
        )
        return min(max(characters, 0), maximumSummaryCharacters)
    }

    /// Character budget granted to memory inherited from a previous compaction.
    public static func priorMemoryCharacterBudget(
        forSummaryCharacters summaryCharacters: Int
    ) -> Int {
        max(
            minimumPriorMemoryCharacters,
            Int(Double(max(summaryCharacters, 0)) * priorMemoryBudgetFraction)
        )
    }

    public static func shouldCompactHistory(
        usedTokens: Int,
        maxTokens: Int,
        messageCount: Int,
        force: Bool = false
    ) -> Bool {
        guard maxTokens > 0 else { return false }
        return force
            || (
                messageCount > minimumRecentMessageCount
                    && usedTokens > triggerTokenCount(for: maxTokens)
            )
    }
}

/// End-to-end token budget for one compaction decision.
///
/// Compaction can only shrink conversation messages, so the budget it works
/// against must subtract everything else sharing the same context window: the
/// output the model is allowed to generate, plus the static and tool overhead a
/// provider adds to every request. Passing the raw context window here (the
/// historical behaviour) keeps the previous semantics exactly.
public struct AgentConversationCompactionBudget: Sendable, Equatable {
    /// Full context window advertised by the model, used for reporting.
    public let contextWindowTokens: Int?
    /// Tokens reserved for the model's own output.
    public let maxOutputTokens: Int
    /// Tokens the request spends on things compaction cannot remove, such as
    /// the tool catalogue and provider-injected system blocks.
    ///
    /// This must be measured on a request whose conversation has been removed,
    /// never as the difference between two different estimators: JSON
    /// wrappers, escaping and UTF-8 expansion grow with the conversation and
    /// are therefore *not* overhead.
    public let reservedOverheadTokens: Int
    /// Provider tokens charged for one shared-estimator token of conversation.
    ///
    /// The shared estimator counts characters of role and content; the provider
    /// charges for the serialised request, which adds per-message JSON
    /// wrappers, escaped sequences and multi-byte UTF-8. That difference is
    /// proportional to the conversation, so it is carried here as a scale-free
    /// ratio instead of being reserved as static overhead.
    public let conversationInflationFactor: Double

    public init(
        contextWindowTokens: Int?,
        maxOutputTokens: Int? = nil,
        reservedOverheadTokens: Int = 0,
        conversationInflationFactor: Double = 1.0
    ) {
        self.contextWindowTokens = contextWindowTokens
        self.maxOutputTokens = max(maxOutputTokens ?? 0, 0)
        self.reservedOverheadTokens = max(reservedOverheadTokens, 0)
        let factor = conversationInflationFactor.isFinite
            ? conversationInflationFactor
            : 1.0
        // Comes from the provider's serialized-wire estimate: never cap it (that
        // would claim a request fits when its payload does not); below one is
        // normalised because the shared estimate is the minimum conservative unit.
        self.conversationInflationFactor = max(factor, 1.0)
    }

    /// Tokens the conversation messages may occupy, expressed in the same unit
    /// the shared estimator uses.
    ///
    /// `nil` means compaction has no reachable target: either the context
    /// window is unknown, or the reservation alone already fills it. No floor
    /// is applied to the *reservation*, because inventing a budget the request
    /// cannot actually use would let a "successful" compaction still produce
    /// `messages + output + overhead > contextWindow`. The remaining window is
    /// then converted from provider tokens into estimator tokens, so the policy
    /// compares like with like.
    public var promptTokenBudget: Int? {
        guard let contextWindowTokens, contextWindowTokens > 0 else {
            return nil
        }
        let available = contextWindowTokens - (maxOutputTokens + reservedOverheadTokens)
        guard available > 0 else {
            return nil
        }
        guard conversationInflationFactor > 1.0 else {
            return available
        }
        // A positive window always leaves room: never report a false "no budget" after rounding.
        return max(
            Int((Double(available) / conversationInflationFactor).rounded(.down)),
            1
        )
    }

    /// `true` when the reserved output and *static* overhead already consume
    /// the whole window. Compaction cannot fix such a request at all, so
    /// callers must stop explicitly instead of retrying an unreachable target.
    /// It deliberately ignores the conversation and its inflation factor: a
    /// long, escaped or non-ASCII history must never be what makes a request
    /// look impossible.
    public var reservationExceedsContextWindow: Bool {
        guard let contextWindowTokens, contextWindowTokens > 0 else {
            return false
        }
        return maxOutputTokens + reservedOverheadTokens >= contextWindowTokens
    }
}

public struct AgentConversationCompactionResult: Sendable {
    public let messages: [AgentRuntimeMessage]
    public let wasCompacted: Bool
    public let originalEstimatedTokenCount: Int
    public let estimatedTokenCount: Int
    public let maxTokens: Int?
    public let compactedSystemPrompt: String?
    public let keptRecentMessageCount: Int

    public init(
        messages: [AgentRuntimeMessage],
        wasCompacted: Bool,
        originalEstimatedTokenCount: Int,
        estimatedTokenCount: Int,
        maxTokens: Int?,
        compactedSystemPrompt: String?,
        keptRecentMessageCount: Int
    ) {
        self.messages = messages
        self.wasCompacted = wasCompacted
        self.originalEstimatedTokenCount = originalEstimatedTokenCount
        self.estimatedTokenCount = estimatedTokenCount
        self.maxTokens = maxTokens
        self.compactedSystemPrompt = compactedSystemPrompt
        self.keptRecentMessageCount = keptRecentMessageCount
    }
}
