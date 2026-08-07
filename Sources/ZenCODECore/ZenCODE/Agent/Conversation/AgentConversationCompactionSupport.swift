//
//  AgentConversationCompactionSupport.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 27/05/26.
//

import Foundation
import ToolCore

public enum AgentConversationCompactionPolicy {
    /// Fraction of the budget that triggers a compaction.
    public static let triggerFraction = 0.95
    /// Fraction of the budget the compacted prompt aims to fill. The remaining
    /// headroom is what the next turns can grow into, so it must stay well
    /// below `triggerFraction` without throwing away most of the usable
    /// context. Model output and provider overhead are *not* part of this
    /// headroom: they are subtracted up front by
    /// `AgentConversationCompactionBudget.promptTokenBudget`.
    public static let targetFraction = 0.75
    /// Recent-window size that is always attempted before falling back to a
    /// smaller window. The adaptive search grows well beyond it when the target
    /// budget can afford more raw messages.
    public static let defaultRecentMessageCount = 12
    public static let minimumRecentMessageCount = 4
    public static let maximumSummaryCharacters = 24_000
    /// Historical reference size for summaries. It is not a floor: a small
    /// context window must be allowed to request a smaller summary.
    public static let minimumSummaryCharacters = 800
    /// Share of the target budget the conversation memory summary may use.
    public static let summaryBudgetFraction = 0.30
    /// Share of the summary budget reserved for memory inherited from a
    /// previous compaction, so re-compaction does not erase what was already
    /// synthesised. Budget the new facts cannot use is handed back to it.
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
    /// Largest share of the conversation the single context-limit retry may
    /// keep. The provider already rejected the request, so a prompt one token
    /// smaller would be rejected again: the retry has to remove a substantial
    /// part of the history to have a real chance of fitting.
    public static let contextLimitRetryRetentionFraction = 0.5
    /// A compaction must remove at least this many estimated tokens before it
    /// may replace the live conversation. This rules out destructive one-token
    /// rewrites of tiny histories.
    public static let minimumMaterialReductionTokens = 2
    /// Share of an already-in-budget prompt retained by an explicitly forced
    /// compaction. A manual force is still a lossy rewrite, so it must buy
    /// useful headroom instead of shaving one token from an otherwise healthy
    /// history. Keeping this relative to the input avoids an arbitrary raw
    /// token threshold for tiny and large conversations alike.
    public static let forcedCompactionRetentionFraction = 0.90
    /// Absolute estimated-token saving required when a manual force compacts a
    /// history that already fits the ordinary policy target. Percentage-only
    /// retention would permit a lossy rewrite of a tiny history for just a few
    /// tokens, even though it creates no useful headroom.
    public static let minimumForcedCompactionSavingsTokens = 8

    public static func triggerTokenCount(for maxTokens: Int) -> Int {
        Int(Double(maxTokens) * triggerFraction)
    }

    public static func targetTokenCount(for maxTokens: Int) -> Int {
        Int(Double(maxTokens) * targetFraction)
    }

    /// Target for a manually forced compaction whose input already fits the
    /// ordinary policy target. Eligibility separately requires this natural
    /// percentage target to create at least
    /// `minimumForcedCompactionSavingsTokens` of headroom.
    public static func forcedTargetTokenCount(for rawTokenCount: Int) -> Int {
        let raw = max(rawTokenCount, 0)
        return Int(
            (
                Double(raw)
                    * forcedCompactionRetentionFraction
            ).rounded(.down)
        )
    }

    /// Whether replacing a conversation with `candidateTokens` removes enough
    /// input to justify the lossy rewrite. This is intentionally independent of
    /// target fit: a provider-rejected request may have no fitting suffix, but
    /// its smallest safe candidate is still useful when it makes material
    /// progress.
    public static func materiallyReducesPrompt(
        originalTokens: Int,
        candidateTokens: Int
    ) -> Bool {
        let original = max(originalTokens, 0)
        let candidate = max(candidateTokens, 0)
        guard candidate < original else {
            return false
        }
        return original - candidate >= minimumMaterialReductionTokens
    }

    /// Character budget granted to the conversation memory summary for a given
    /// target token budget. The budget may be below the historical reference
    /// size when the target is small; inventing an 800-character floor can make
    /// an otherwise feasible prompt impossible.
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
        guard maxTokens > 0 else {
            return false
        }

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
        // This ratio comes from the provider's own serialized-wire estimate.
        // It can legitimately exceed an arbitrary small cap for UTF-8 text,
        // JSON escaping, ZWJ sequences, or combining marks. Never lower it:
        // doing so would claim a compacted request fits when its wire payload
        // does not. A lower-than-one measurement is still normalised because
        // the shared estimate is the minimum conservative unit.
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
        // A positive remaining window always leaves room for something: the
        // conversion may round down to zero for a pathological ratio, and
        // reporting "no budget" there would be a false unsatisfiable verdict.
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

public enum AgentConversationCompactionSupport {
    public static let memorySummaryHeader = "Conversation memory summary from earlier turns."

    private static let memorySummaryInstruction =
        "Preserve the facts, decisions, files, code directions, and unresolved requests below as continuing context."
    private static let priorMemoryLabel = "Prior memory:"

    public static func compactedMessagesIfNeeded(
        _ messages: [AgentRuntimeMessage],
        maxTokens: Int?,
        force: Bool = false
    ) -> AgentConversationCompactionResult {
        compactedMessagesIfNeeded(
            messages,
            budget: AgentConversationCompactionBudget(contextWindowTokens: maxTokens),
            force: force
        )
    }

    /// Compacts against a budget that already accounts for reserved output and
    /// provider overhead. A result is only reported as compacted when the
    /// prompt materially shrank, which avoids destructive one-token rewrites
    /// and makes repeated provider preflights terminate.
    public static func compactedMessagesIfNeeded(
        _ messages: [AgentRuntimeMessage],
        budget: AgentConversationCompactionBudget,
        force: Bool = false
    ) -> AgentConversationCompactionResult {
        let rawTokenCount = estimatedTokenCount(for: messages)

        guard let promptTokenBudget = budget.promptTokenBudget,
              AgentConversationCompactionPolicy.shouldCompactHistory(
                  usedTokens: rawTokenCount,
                  maxTokens: promptTokenBudget,
                  messageCount: conversationMessageCount(in: messages),
                  force: force
              ) else {
            return unchangedResult(for: messages, budget: budget, rawTokenCount: rawTokenCount)
        }

        let policyTargetTokenCount = AgentConversationCompactionPolicy.targetTokenCount(
            for: promptTokenBudget
        )
        let isForcedWithinPolicyTarget = force && rawTokenCount <= policyTargetTokenCount
        let targetTokenCount = isForcedWithinPolicyTarget
            ? AgentConversationCompactionPolicy.forcedTargetTokenCount(
                for: rawTokenCount
            )
            : policyTargetTokenCount

        // An already-in-budget manual force is eligible only when its natural
        // percentage target creates useful absolute headroom. Do this before
        // searching for a suffix so a tiny history cannot undergo a lossy
        // rewrite merely because a smaller candidate happens to exist.
        if isForcedWithinPolicyTarget,
           rawTokenCount - targetTokenCount
            < AgentConversationCompactionPolicy.minimumForcedCompactionSavingsTokens {
            return unchangedResult(for: messages, budget: budget, rawTokenCount: rawTokenCount)
        }

        // Compaction must never grow the prompt. When an operator explicitly
        // forces a history that already fits policy, require both percentage
        // retention and an absolute saving rather than the former `raw - 1`
        // pseudo-target. In that case an above-target fallback would defeat
        // the requested reduction; a real policy overflow may still use a
        // material fallback when no provider-safe suffix can meet the ideal
        // target.
        return compactionResult(
            for: messages,
            budget: budget,
            rawTokenCount: rawTokenCount,
            targetTokenCount: targetTokenCount,
            allowsFallbackBeyondTarget: !isForcedWithinPolicyTarget
        )
    }

    /// Compacts for the single retry that follows a provider context-limit
    /// rejection.
    ///
    /// The provider has already refused this exact prompt, so the ordinary
    /// forced target would still be a lossy manual rewrite, while the retry
    /// needs to make substantially more room. It therefore aims at the smaller
    /// of the coordinated, overhead-aware budget target and a substantial
    /// fraction of what was just rejected. When the output reservation plus
    /// static overhead already fill the context window, no conversation can
    /// make the request fit. In that case this deliberately returns unchanged
    /// so the caller does not persist a lossy compaction for a retry that
    /// cannot possibly succeed.
    public static func compactedMessagesForContextLimitRetry(
        _ messages: [AgentRuntimeMessage],
        budget: AgentConversationCompactionBudget
    ) -> AgentConversationCompactionResult {
        let rawTokenCount = estimatedTokenCount(for: messages)
        guard !budget.reservationExceedsContextWindow,
              rawTokenCount > 0,
              conversationMessageCount(in: messages)
                > AgentConversationCompactionPolicy.minimumRecentMessageCount else {
            return unchangedResult(for: messages, budget: budget, rawTokenCount: rawTokenCount)
        }

        let substantialTarget = max(
            Int(
                Double(rawTokenCount)
                    * AgentConversationCompactionPolicy.contextLimitRetryRetentionFraction
            ),
            1
        )
        var targetTokenCount = substantialTarget
        if let promptTokenBudget = budget.promptTokenBudget {
            targetTokenCount = min(
                substantialTarget,
                AgentConversationCompactionPolicy.targetTokenCount(for: promptTokenBudget)
            )
        }

        return compactionResult(
            for: messages,
            budget: budget,
            rawTokenCount: rawTokenCount,
            targetTokenCount: max(targetTokenCount, 1),
            allowsFallbackBeyondTarget: true
        )
    }

    private static func unchangedResult(
        for messages: [AgentRuntimeMessage],
        budget: AgentConversationCompactionBudget,
        rawTokenCount: Int
    ) -> AgentConversationCompactionResult {
        AgentConversationCompactionResult(
            messages: messages,
            wasCompacted: false,
            originalEstimatedTokenCount: rawTokenCount,
            estimatedTokenCount: rawTokenCount,
            maxTokens: budget.contextWindowTokens,
            compactedSystemPrompt: firstSystemPrompt(in: messages),
            keptRecentMessageCount: conversationMessageCount(in: messages)
        )
    }

    private static func compactionResult(
        for messages: [AgentRuntimeMessage],
        budget: AgentConversationCompactionBudget,
        rawTokenCount: Int,
        targetTokenCount: Int,
        allowsFallbackBeyondTarget: Bool
    ) -> AgentConversationCompactionResult {
        guard let candidate = bestCandidate(
            messages: messages,
            targetTokenCount: targetTokenCount,
            rawTokenCount: rawTokenCount,
            allowsFallbackBeyondTarget: allowsFallbackBeyondTarget
        ), AgentConversationCompactionPolicy.materiallyReducesPrompt(
            originalTokens: rawTokenCount,
            candidateTokens: candidate.estimatedTokenCount
        ) else {
            // Reporting success without material progress would let a
            // preflight retry a near-identical prompt while needlessly losing
            // history from tiny conversations.
            return unchangedResult(for: messages, budget: budget, rawTokenCount: rawTokenCount)
        }

        return AgentConversationCompactionResult(
            messages: candidate.messages,
            wasCompacted: true,
            originalEstimatedTokenCount: rawTokenCount,
            estimatedTokenCount: candidate.estimatedTokenCount,
            maxTokens: budget.contextWindowTokens,
            compactedSystemPrompt: candidate.compactedSystemPrompt,
            keptRecentMessageCount: candidate.keptRecentMessageCount
        )
    }

    public static func estimatedTokenCount(
        for messages: [AgentRuntimeMessage]
    ) -> Int {
        let characterCount = messages.reduce(into: 0) { count, message in
            count += estimatedCharacterCount(for: message)
        }
        guard characterCount > 0 else {
            return 0
        }
        return max(Int((Double(characterCount) / 4.0).rounded(.up)), 1)
    }

    /// Builds a memory summary that fits `maxCharacters` exactly.
    ///
    /// The limit is honoured as given. `minimumSummaryCharacters` is a
    /// historical reference value rather than a sizing floor, so both this
    /// public API and the compaction search may produce smaller summaries.
    public static func conversationMemorySummary(
        priorSummary: String?,
        olderMessages: [AgentRuntimeMessage],
        maxCharacters: Int
    ) -> String {
        conversationMemorySummary(
            priorSummary: priorSummary,
            entries: olderMessages.flatMap(summaryEntries(for:)),
            maxCharacters: maxCharacters
        )
    }

    /// Compacts `text` to `limit` characters. Beyond
    /// `tailPreservationCharacters` both the head and the tail are kept, so a
    /// fact stated at the end of a long message is not systematically lost.
    public static func compactSummaryText(_ text: String, limit: Int) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalized.isEmpty, limit > 0 else {
            return ""
        }

        guard normalized.count > limit else {
            return normalized
        }

        let marker = "..."
        // A marker cannot fit in one, two, or three characters. Returning the
        // prefix in that case is the only way to honour the public limit
        // exactly; the previous minimum cutoff appended all three dots and
        // returned four characters for these limits.
        guard limit > marker.count else {
            return String(normalized.prefix(limit))
        }
        guard limit > AgentConversationCompactionPolicy.tailPreservationCharacters else {
            let cutoff = limit - marker.count
            let cutoffIndex = normalized.index(normalized.startIndex, offsetBy: cutoff)
            let truncated = normalized[..<cutoffIndex]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(truncated)\(marker)"
        }

        let available = limit - marker.count - 2
        let headLimit = max(Int(Double(available) * 0.65), 1)
        let tailLimit = max(available - headLimit, 1)
        let headIndex = normalized.index(normalized.startIndex, offsetBy: headLimit)
        let tailIndex = normalized.index(normalized.endIndex, offsetBy: -tailLimit)
        let head = normalized[..<headIndex]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tail = normalized[tailIndex...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(head) \(marker) \(tail)"
    }

    public static func systemPromptWithoutCompactionSummary(
        _ systemPrompt: String
    ) -> String {
        guard let summaryRange = systemPrompt.range(of: memorySummaryHeader) else {
            return systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return String(systemPrompt[..<summaryRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Candidate {
        var messages: [AgentRuntimeMessage]
        var estimatedTokenCount: Int
        var compactedSystemPrompt: String
        var keptRecentMessageCount: Int
    }

    private struct SummaryEntry {
        var prefix: String
        var text: String
        var weight: Double
    }

    /// Pre-flattened summary entries with per-message prefix offsets, so every
    /// candidate evaluation can slice the older-message entries instead of
    /// rebuilding (and re-trimming) them.
    private struct SummaryEntrySource {
        let entries: [SummaryEntry]
        let prefixCounts: [Int]

        init(conversationMessages: [AgentRuntimeMessage]) {
            var entries: [SummaryEntry] = []
            var prefixCounts: [Int] = [0]
            entries.reserveCapacity(conversationMessages.count)
            prefixCounts.reserveCapacity(conversationMessages.count + 1)
            for message in conversationMessages {
                entries.append(contentsOf: AgentConversationCompactionSupport.summaryEntries(for: message))
                prefixCounts.append(entries.count)
            }
            self.entries = entries
            self.prefixCounts = prefixCounts
        }

        func entries(forOlderMessageCount count: Int) -> [SummaryEntry] {
            let clamped = min(max(count, 0), prefixCounts.count - 1)
            return Array(entries[0..<prefixCounts[clamped]])
        }
    }

    /// Searches the largest recent window (and the richest memory summary) that
    /// both fits the target budget and materially reduces the raw prompt.
    ///
    /// Rendering a summary is deliberately content-sensitive: sampling and
    /// truncating another older turn can make its rendered size either grow or
    /// shrink. Do not binary-search that predicate. We instead evaluate each
    /// provider-safe suffix directly from largest to smallest and accept only a
    /// measured fit. This makes the selection invariant simple: a successful
    /// result is never outside its target, even when the summary representation
    /// changes shape.
    private static func bestCandidate(
        messages: [AgentRuntimeMessage],
        targetTokenCount: Int,
        rawTokenCount: Int,
        allowsFallbackBeyondTarget: Bool
    ) -> Candidate? {
        let split = splitSystemPrompt(from: messages)
        let conversationMessages = split.conversationMessages
        guard conversationMessages.count > AgentConversationCompactionPolicy.minimumRecentMessageCount else {
            return nil
        }

        // At least one message must remain for the memory summary.
        let maximumRecentMessageCount = conversationMessages.count - 1
        let lowerBound = min(
            AgentConversationCompactionPolicy.minimumRecentMessageCount,
            maximumRecentMessageCount
        )
        let entrySource = SummaryEntrySource(conversationMessages: conversationMessages)
        var summaryCharacterLimit = AgentConversationCompactionPolicy.summaryCharacterBudget(
            forTargetTokenCount: targetTokenCount
        )
        let preferredSummaryCharacterLimit = summaryCharacterLimit
        var smallestCandidate: Candidate?

        func retainAsFallback(_ candidate: Candidate) {
            // A fallback is useful only when it can actually replace the live
            // prompt. Keep the same material-progress invariant as a fitting
            // candidate; otherwise a one-token rewrite could escape after all
            // target-fitting suffixes have been exhausted.
            guard AgentConversationCompactionPolicy.materiallyReducesPrompt(
                originalTokens: rawTokenCount,
                candidateTokens: candidate.estimatedTokenCount
            ) else {
                return
            }
            // The candidates are evaluated in semantic-preference order at the
            // requested summary budget, so an equal-sized result leaves the
            // earlier (richer) representation in place. Lower summary budgets
            // are explored only to find a target fit: they must not erase prior
            // memory merely to make an otherwise unusable fallback smaller.
            guard smallestCandidate == nil
                    || candidate.estimatedTokenCount < smallestCandidate!.estimatedTokenCount else {
                return
            }
            smallestCandidate = candidate
        }

        func makeCandidate(recentMessageCount: Int, summaryLimit: Int) -> Candidate? {
            guard recentMessageCount >= 1,
                  recentMessageCount <= maximumRecentMessageCount else {
                return nil
            }

            let splitIndex = conversationMessages.count - recentMessageCount
            guard splitIndex > 0 else {
                return nil
            }
            let recentMessages = Array(conversationMessages.suffix(recentMessageCount))
            let summary = conversationMemorySummary(
                priorSummary: split.priorSummary,
                entries: entrySource.entries(forOlderMessageCount: splitIndex),
                maxCharacters: summaryLimit
            )
            let systemPrompt = compactedSystemPrompt(
                systemPrompt: split.baseSystemPrompt,
                summary: summary
            )
            var candidateMessages: [AgentRuntimeMessage] = []
            if let systemPrompt = systemPrompt.nilIfBlank {
                candidateMessages.append(
                    AgentRuntimeMessage(role: .system, content: systemPrompt)
                )
            }
            if let dynamicContextMessage = split.dynamicContextMessage {
                candidateMessages.append(dynamicContextMessage)
            }
            candidateMessages.append(contentsOf: recentMessages)

            let candidate = Candidate(
                messages: candidateMessages,
                estimatedTokenCount: estimatedTokenCount(for: candidateMessages),
                compactedSystemPrompt: systemPrompt,
                keptRecentMessageCount: recentMessageCount
            )
            return candidate
        }

        /// Evaluates the provider-safe window sizes for `requestedCount`,
        /// preferring the turn-aligned one, and returns a directly measured
        /// candidate only when it fits the target *and* materially reduces the
        /// raw prompt. A near-identical fit must not terminate the search: a
        /// later suffix may both fit and make useful progress.
        func fittingCandidate(atLeast requestedCount: Int, summaryLimit: Int) -> Candidate? {
            for count in candidateRecentCounts(
                in: conversationMessages,
                requestedCount: requestedCount
            ) where count <= maximumRecentMessageCount {
                if let candidate = makeCandidate(
                    recentMessageCount: count,
                    summaryLimit: summaryLimit
                ) {
                    if allowsFallbackBeyondTarget,
                       summaryLimit == preferredSummaryCharacterLimit {
                        retainAsFallback(candidate)
                    }
                    guard candidate.estimatedTokenCount <= targetTokenCount,
                          AgentConversationCompactionPolicy.materiallyReducesPrompt(
                              originalTokens: rawTokenCount,
                              candidateTokens: candidate.estimatedTokenCount
                          ) else {
                        continue
                    }
                    return candidate
                }
            }
            return nil
        }

        while true {
            // Direct evaluation avoids treating the content-sensitive summary
            // renderer as a monotonic function. The first fit retains the
            // largest requested suffix for this summary budget.
            for requestedCount in stride(
                from: maximumRecentMessageCount,
                through: lowerBound,
                by: -1
            ) {
                if let candidate = fittingCandidate(
                    atLeast: requestedCount,
                    summaryLimit: summaryCharacterLimit
                ) {
                    return candidate
                }
            }

            // A feasible target may need less than the historical 800
            // characters. Keep decreasing the explicit summary budget until
            // even an empty summary cannot make a provider-safe suffix fit.
            // In the latter case retain the smallest directly measured safe
            // suffix at the requested summary fidelity as a fallback: provider
            // context-limit recovery benefits from a substantial reduction even
            // if the ideal target was unreachable, without discarding prior
            // memory solely because the target could not be reached.
            guard summaryCharacterLimit > 0 else {
                return allowsFallbackBeyondTarget ? smallestCandidate : nil
            }
            summaryCharacterLimit = summaryCharacterLimit > 1
                ? max((summaryCharacterLimit * 2) / 3, summaryCharacterLimit - 1)
                : 0
        }
    }

    private static func splitSystemPrompt(
        from messages: [AgentRuntimeMessage]
    ) -> (
        baseSystemPrompt: String?,
        priorSummary: String?,
        dynamicContextMessage: AgentRuntimeMessage?,
        conversationMessages: [AgentRuntimeMessage]
    ) {
        var remaining = messages[...]
        let baseSystemPrompt: String?
        let inheritedSummary: String?
        if let first = remaining.first, first.role == .system {
            baseSystemPrompt = systemPromptWithoutCompactionSummary(first.content).nilIfBlank
            inheritedSummary = priorSummary(from: first.content)
            remaining = remaining.dropFirst()
        } else {
            baseSystemPrompt = nil
            inheritedSummary = nil
        }
        let dynamicContextMessage = remaining.first.flatMap { message in
            AgentRuntimeDynamicContext.context(from: message) == nil ? nil : message
        }
        if dynamicContextMessage != nil {
            remaining = remaining.dropFirst()
        }
        return (baseSystemPrompt, inheritedSummary, dynamicContextMessage, Array(remaining))
    }

    private static func compactedSystemPrompt(
        systemPrompt: String?,
        summary: String
    ) -> String {
        [
            systemPrompt.map(systemPromptWithoutCompactionSummary),
            summary
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    private static func priorSummary(from systemPrompt: String) -> String? {
        guard let summaryRange = systemPrompt.range(of: memorySummaryHeader) else {
            return nil
        }
        return String(systemPrompt[summaryRange.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
    }

    private static func normalizedPriorSummary(_ summary: String?) -> String? {
        guard var summary = summary?.nilIfBlank else {
            return nil
        }
        if let headerRange = summary.range(of: memorySummaryHeader) {
            summary.removeSubrange(headerRange)
        }
        summary = summary
            .replacingOccurrences(of: memorySummaryInstruction, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.nilIfBlank
    }

    /// Removes every leading `Prior memory:` label from an inherited line.
    ///
    /// Historical summaries wrote the inherited memory inline as
    /// `Prior memory: <text>`; re-emitting such a line under a fresh label
    /// would nest the marker once per compaction. Both the inline legacy form
    /// and the current standalone-label form normalise to the bare fact.
    private static func strippingPriorMemoryLabels(_ line: String) -> String {
        var value = line.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasPrefix(priorMemoryLabel) {
            value = String(value.dropFirst(priorMemoryLabel.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value
    }

    /// Splits inherited memory back into its individual facts. Nested and
    /// inline "Prior memory:" labels are dropped so repeated compactions never
    /// stack them.
    private static func priorSummaryEntries(from priorSummary: String) -> [SummaryEntry] {
        priorSummary
            .split(separator: "\n")
            .map { strippingPriorMemoryLabels(String($0)) }
            .filter { line in
                guard !line.isEmpty else {
                    return false
                }
                return true
            }
            .map { SummaryEntry(prefix: "", text: $0, weight: 1.2) }
    }

    private static func summaryEntries(
        for message: AgentRuntimeMessage
    ) -> [SummaryEntry] {
        var entries: [SummaryEntry] = []
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            entries.append(
                SummaryEntry(
                    prefix: "\(roleLabel(message.role)): ",
                    text: content,
                    weight: summaryWeight(for: message.role)
                )
            )
        }
        let mediaSummary = mediaSummary(for: message)
        if !mediaSummary.isEmpty {
            entries.append(
                SummaryEntry(
                    prefix: "\(roleLabel(message.role)) media: ",
                    text: mediaSummary,
                    weight: 0.2
                )
            )
        }
        return entries
    }

    private static func naturalCharacterCost(of entries: [SummaryEntry]) -> Int {
        entries.reduce(into: 0) { $0 += $1.prefix.count + $1.text.count + 1 }
    }

    /// Renders the summary within `maxCharacters`.
    ///
    /// No floor is applied here: the public entry point and `bestCandidate`
    /// both honour the budget they were given, including values below the
    /// historical `minimumSummaryCharacters` reference.
    private static func conversationMemorySummary(
        priorSummary: String?,
        entries: [SummaryEntry],
        maxCharacters: Int
    ) -> String {
        let budget = max(maxCharacters, 0)
        guard budget > 0 else {
            return ""
        }

        // Keep the stable marker whenever it fits so a future compaction can
        // recover the prior summary. The long instruction is useful in normal
        // windows, but is optional when it would crowd out every fact.
        let fullHeader = """
        \(memorySummaryHeader)
        \(memorySummaryInstruction)
        """
        let header: String
        if fullHeader.count + 49 <= budget {
            header = fullHeader
        } else if memorySummaryHeader.count <= budget {
            header = memorySummaryHeader
        } else {
            header = compactSummaryText(memorySummaryHeader, limit: budget)
        }

        let priorEntries = normalizedPriorSummary(priorSummary)
            .map(priorSummaryEntries(from:)) ?? []
        let hasPrior = !priorEntries.isEmpty
        let hasNewFacts = !entries.isEmpty
        guard hasPrior || hasNewFacts else {
            return header
        }

        // A body follows the marker on its own line. Reserve one separator now
        // so every per-section allowance is exact rather than relying on a
        // final lossy truncation.
        let bodyBudget = max(budget - header.count - 1, 0)
        guard bodyBudget > 0 else {
            return header
        }

        let priorLabelCost = priorEntries.isEmpty ? 0 : priorMemoryLabel.count + 1
        let priorNaturalCost = priorEntries.isEmpty
            ? 0
            : naturalCharacterCost(of: priorEntries) + priorLabelCost
        let newNaturalCost = naturalCharacterCost(of: entries)

        func priorBlock(withBudget sectionBudget: Int) -> String {
            guard hasPrior, sectionBudget > priorLabelCost else {
                return ""
            }
            let facts = summaryLines(
                for: priorEntries,
                budget: sectionBudget - priorLabelCost,
                densePacking: true
            )
            guard !facts.isEmpty else {
                return ""
            }
            return "\(priorMemoryLabel)\n\(facts.joined(separator: "\n"))"
        }

        func newFactsBlock(withBudget sectionBudget: Int) -> String {
            summaryLines(for: entries, budget: sectionBudget)
                .joined(separator: "\n")
        }

        let body: String
        if hasPrior && hasNewFacts {
            // Reserve the separator between the two blocks, then start from a
            // fair split. Unlike the previous historical 1,200-character
            // minimum, this cannot give all of a small body to prior memory.
            let sectionsBudget = max(bodyBudget - 1, 0)
            var priorBudget = min(priorNaturalCost, sectionsBudget / 2)
            var newFactsBudget = sectionsBudget - priorBudget

            // Any allocation the new material cannot consume belongs to the
            // inherited memory, but only after its own non-zero share has been
            // reserved. This keeps old decisions while guaranteeing room for
            // newly summarised facts on compact windows.
            if newNaturalCost < newFactsBudget {
                priorBudget = min(
                    priorNaturalCost,
                    priorBudget + (newFactsBudget - newNaturalCost)
                )
                newFactsBudget = sectionsBudget - priorBudget
            }

            let prior = priorBlock(withBudget: priorBudget)
            let newFacts = newFactsBlock(withBudget: newFactsBudget)
            if !prior.isEmpty, !newFacts.isEmpty {
                body = "\(prior)\n\(newFacts)"
            } else if !prior.isEmpty {
                body = prior
            } else if !newFacts.isEmpty {
                body = newFacts
            } else {
                body = ""
            }
        } else if hasPrior {
            body = priorBlock(withBudget: bodyBudget)
        } else {
            body = newFactsBlock(withBudget: bodyBudget)
        }

        guard !body.isEmpty else {
            return header
        }
        // `summaryLines` honours each allowance. The prefix is retained as a
        // last-resort contract guard for future formatter changes.
        return String("\(header)\n\(body)".prefix(budget))
    }

    /// Distributes the summary budget across the whole history instead of
    /// keeping only its chronological prefix, so both the earliest decisions
    /// and the facts stated right before the raw window survive.
    private static func summaryLines(
        for entries: [SummaryEntry],
        budget: Int,
        densePacking: Bool = false
    ) -> [String] {
        guard !entries.isEmpty, budget > 0 else {
            return []
        }

        // Raw history remains intentionally lean, while already distilled
        // inherited facts can pack at their natural average density. There is
        // no elision sentence: it consumes a variable amount of the very
        // budget whose size must stay predictable.
        let perEntryBudget: Int
        if densePacking {
            perEntryBudget = max(naturalCharacterCost(of: entries) / entries.count, 1)
        } else {
            perEntryBudget = AgentConversationCompactionPolicy.minimumSummaryEntryCharacters
        }
        var maximumEntryCount = min(entries.count, max(budget / perEntryBudget, 1))

        func sampledEntries(count: Int) -> [SummaryEntry] {
            guard count < entries.count else {
                return entries
            }
            guard count > 1 else {
                return [entries[0]]
            }
            let step = Double(entries.count - 1) / Double(count - 1)
            var indices: [Int] = []
            for position in 0..<count {
                let index = min(Int((Double(position) * step).rounded()), entries.count - 1)
                if indices.last != index {
                    indices.append(index)
                }
            }
            return indices.map { entries[$0] }
        }

        var selected = sampledEntries(count: maximumEntryCount)
        while !selected.isEmpty {
            let structuralCost = selected.enumerated().reduce(into: 0) { cost, pair in
                cost += pair.element.prefix.count
                if pair.offset > 0 {
                    cost += 1 // newline between adjacent lines
                }
            }
            let textBudget = budget - structuralCost
            if textBudget >= selected.count {
                var limits = selected.map { min($0.text.count, 1) }
                var remainingBudget = textBudget - limits.reduce(0, +)
                var remainingWeight = selected.reduce(into: 0.0) { total, entry in
                    total += entry.weight
                }

                for index in selected.indices {
                    let entry = selected[index]
                    let capacity = max(entry.text.count - limits[index], 0)
                    let share = remainingWeight > 0
                        ? Int((Double(remainingBudget) * entry.weight / remainingWeight).rounded(.down))
                        : remainingBudget
                    let additional = min(capacity, max(share, 0))
                    limits[index] += additional
                    remainingBudget -= additional
                    remainingWeight = max(remainingWeight - entry.weight, 0)
                }

                // A capacity-limited early entry can leave budget behind. Give
                // it to later entries without changing the rendered shape.
                for index in selected.indices.reversed() where remainingBudget > 0 {
                    let capacity = max(selected[index].text.count - limits[index], 0)
                    let additional = min(capacity, remainingBudget)
                    limits[index] += additional
                    remainingBudget -= additional
                }

                return selected.enumerated().compactMap { index, entry in
                    let text = compactSummaryText(entry.text, limit: limits[index])
                    guard !text.isEmpty else {
                        return nil
                    }
                    return "\(entry.prefix)\(text)"
                }
            }

            guard maximumEntryCount > 1 else {
                return []
            }
            maximumEntryCount -= 1
            selected = sampledEntries(count: maximumEntryCount)
        }
        return []
    }

    /// Recent-window sizes worth evaluating for a requested size, from the most
    /// semantically complete to the minimum provider-safe one.
    private static func candidateRecentCounts(
        in messages: [AgentRuntimeMessage],
        requestedCount: Int
    ) -> [Int] {
        let toolSafeCount = toolSafeRecentMessageCount(
            in: messages,
            requestedCount: requestedCount
        )
        let turnAlignedCount = turnAlignedRecentMessageCount(
            in: messages,
            toolSafeCount: toolSafeCount
        )
        guard turnAlignedCount > toolSafeCount else {
            return [toolSafeCount]
        }
        return [turnAlignedCount, toolSafeCount]
    }

    /// Never starts the raw window with a tool result whose originating tool
    /// call was summarised away.
    private static func toolSafeRecentMessageCount(
        in messages: [AgentRuntimeMessage],
        requestedCount: Int
    ) -> Int {
        guard !messages.isEmpty else {
            return 0
        }

        var count = min(max(requestedCount, 0), messages.count)
        while count < messages.count {
            let startIndex = messages.count - count
            guard messages[startIndex].role == .tool else {
                break
            }
            count += 1
        }
        return count
    }

    /// Prefers a raw window that starts on the user turn opening the exchange,
    /// keeping assistant tool calls together with their results.
    private static func turnAlignedRecentMessageCount(
        in messages: [AgentRuntimeMessage],
        toolSafeCount: Int
    ) -> Int {
        guard toolSafeCount > 0, toolSafeCount < messages.count else {
            return toolSafeCount
        }

        var count = toolSafeCount
        var expansion = 0
        while count < messages.count,
              expansion <= AgentConversationCompactionPolicy.turnBoundaryLookbackLimit {
            if messages[messages.count - count].role == .user {
                return count
            }
            count += 1
            expansion += 1
        }
        return toolSafeCount
    }

    private static func conversationMessageCount(
        in messages: [AgentRuntimeMessage]
    ) -> Int {
        splitSystemPrompt(from: messages).conversationMessages.count
    }

    private static func firstSystemPrompt(
        in messages: [AgentRuntimeMessage]
    ) -> String? {
        guard messages.first?.role == .system else {
            return nil
        }
        return messages.first?.content
    }

    private static func estimatedCharacterCount(
        for message: AgentRuntimeMessage
    ) -> Int {
        var count = message.role.rawValue.count + 12
        count += message.content.count
        count += message.reasoningContent?.count ?? 0
        count += message.reasoningItemsJSON?.count ?? 0
        count += message.thinkingBlocksJSON?.count ?? 0
        count += message.toolCallID?.count ?? 0
        count += message.toolName?.count ?? 0
        count += message.toolCalls.reduce(into: 0) { toolCallCount, toolCall in
            toolCallCount += toolCall.id?.count ?? 0
            toolCallCount += toolCall.name.count
            toolCallCount += toolCall.argumentsJSON.count
        }
        count += message.attachments.reduce(into: 0) { attachmentCount, attachment in
            switch attachment.kind {
            case .image:
                attachmentCount += 512
            case .video:
                attachmentCount += 1_024
            }
            attachmentCount += attachment.originalFilename.count
        }
        return count
    }

    private static func roleLabel(_ role: AgentRuntimeMessage.Role) -> String {
        switch role {
        case .system:
            return "System"
        case .user:
            return "User request"
        case .assistant:
            return "Assistant reply"
        case .tool:
            return "Tool result"
        }
    }

    private static func mediaSummary(for message: AgentRuntimeMessage) -> String {
        let imageCount = message.attachments.filter { $0.kind == .image }.count
        let videoCount = message.attachments.filter { $0.kind == .video }.count
        var parts: [String] = []
        if imageCount > 0 {
            parts.append("\(imageCount) image(s)")
        }
        if videoCount > 0 {
            parts.append("\(videoCount) video(s)")
        }
        return parts.joined(separator: ", ")
    }

    private static func summaryWeight(for role: AgentRuntimeMessage.Role) -> Double {
        switch role {
        case .user:
            return 1.4
        case .assistant:
            return 1.1
        case .tool:
            return 0.8
        case .system:
            return 1.0
        }
    }
}
