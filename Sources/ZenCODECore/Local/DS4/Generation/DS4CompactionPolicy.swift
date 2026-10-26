//
//  DS4CompactionPolicy.swift
//  ZenCODE
//
//  When the in-process DS4 path compacts the conversation and how many tokens
//  a round may generate. Mirrors ds4-agent:
//  - `agent_worker_should_compact` (ds4_agent.c:9686-9697): compact when the
//    prompt fills `AGENT_COMPACT_SOFT_PERCENT` (85%) of the context, or when
//    the free room is at most max(min(8192, ctx/8), reserve + 128);
//  - `agent_compact_reserve_tokens` (9775-9785): the reserve is the tokens of
//    the compaction request (user message + assistant prefix without
//    thinking) + 64 + the summary budget (ctx/8 clamped to 256...4096);
//  - generation room (10416-10421): min(n_predict, ctx - prompt - reserve),
//    `n_predict` being 50000 by default.
//  ZenCODE's compaction is deterministic and never sends the compaction
//  request to the model; its token count is still used for the reserve so
//  the thresholds match ds4-agent exactly.
//

import Foundation

enum DS4CompactionPolicy {
    /// `AGENT_COMPACT_SOFT_PERCENT`
    static let softPercent = 85
    /// `AGENT_COMPACT_MIN_FREE_TOKENS`
    static let minimumFreeTokens = 8192
    /// `AGENT_COMPACT_SUMMARY_MAX_TOKENS`
    static let summaryMaximumTokens = 4096
    static let summaryMinimumTokens = 256
    /// Safety margin added to the reserve.
    static let reserveSafetyTokens = 64
    /// Margin added to the reserve in the free-room threshold.
    static let thresholdMarginTokens = 128
    /// ds4-agent `n_predict` default (ds4_agent.c:722).
    static let defaultMaxOutputTokens = 50_000
    /// Reason used by `agent_compact_reserve_tokens`.
    static let reserveReason = "context pressure before continuing the current task"

    /// `agent_compact_make_prompt` (ds4_agent.c:9737), verbatim.
    static func compactionPrompt(reason: String?) -> String {
        var text = "Internal ds4-agent context compaction request. This is not a user request.\n"
            + "Write a durable task-state summary of the conversation so far. Preserve only facts that matter for continuing the work:\n"
            + "- user goals, constraints, and preferences\n"
            + "- files inspected or edited\n"
            + "- commands run and important results\n"
            + "- decisions, rejected approaches, known bugs, and pending next steps\n"
            + "- reloadable bulky data with exact paths/ranges/commands when available\n\n"
            + "Do not invent facts. Do not include generic narration. Do not include raw file contents unless they were essential to a conclusion.\n"
            + "Do not solve unfinished tasks, calculate new results, or finish incomplete code in the summary. "
            + "Record the user's requirements and what actually happened, leaving unfinished work pending.\n"
            + "After the summary, stop. Do not continue the user task, do not call tools, and do not output thinking tags or DSML markup.\n"
            + "Output only the compact summary.\n"
        if let reason, !reason.isEmpty {
            text += "\nCompaction reason: " + reason + "\n"
        }
        return text
    }

    /// The operations whose token count enters the reserve.
    static var reserveTranscript: [DS4TranscriptOperation] {
        [
            .message(role: "user", content: compactionPrompt(reason: reserveReason)),
            .assistantPrefix(mode: DS4EngineABI.ThinkMode.none),
        ]
    }

    /// `agent_compact_summary_budget`: ctx/8 clamped to 256...4096.
    static func summaryBudget(contextSize: Int) -> Int {
        min(max(contextSize / 8, summaryMinimumTokens), summaryMaximumTokens)
    }

    /// `agent_compact_reserve_tokens`.
    static func reserveTokens(compactionPromptTokens: Int, contextSize: Int) -> Int {
        compactionPromptTokens + reserveSafetyTokens + summaryBudget(contextSize: contextSize)
    }

    /// `agent_worker_should_compact`.
    static func shouldCompact(usedTokens: Int, contextSize: Int, reserveTokens: Int) -> Bool {
        guard contextSize > 0, usedTokens > 0 else {
            return false
        }
        if usedTokens >= (contextSize * softPercent) / 100 {
            return true
        }
        let threshold = max(min(minimumFreeTokens, contextSize / 8), reserveTokens + thresholdMarginTokens)
        return contextSize - usedTokens <= threshold
    }

    /// Tokens a round may generate: min(maxOutputTokens ?? 50000,
    /// ctx - prompt - reserve). Not positive means the context has no
    /// generation room left.
    static func generationTokenLimit(
        maxOutputTokens: Int?,
        contextSize: Int,
        usedTokens: Int,
        reserveTokens: Int
    ) -> Int {
        min(maxOutputTokens ?? defaultMaxOutputTokens, contextSize - usedTokens - reserveTokens)
    }
}
