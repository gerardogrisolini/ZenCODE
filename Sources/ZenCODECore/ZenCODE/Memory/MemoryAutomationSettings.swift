//
//  MemoryAutomationSettings.swift
//  ZenCODE
//
//  Environment settings for automatic memory recall.
//

import Foundation
import ToolCore

/// Environment-driven configuration for the automatic recall pipeline.
///
/// Recall runs over the workspace graph inline before each turn. With no
/// embedding endpoint configured it is pure lexical BM25 plus graph expansion,
/// which is local and sub-millisecond. When an endpoint is configured, semantic
/// similarity adds a bounded HTTP call to that endpoint — but never a second LLM
/// call: the formatted block is folded into the main turn's outgoing request,
/// so its timeout and character budget protect turn latency and prompt size
/// independently of the configured provider.
enum MemoryAutomationSettings {
    /// Enables automatic recall. Absent ⇒ true.
    static let environmentAutoRecallKey = "ZENCODE_MEMORY_AUTO_RECALL"
    /// Upper bound, in milliseconds, on how long a turn may wait for recall.
    static let environmentRecallTimeoutKey = "ZENCODE_MEMORY_RECALL_TIMEOUT_MS"
    /// Upper bound, in characters, on the recalled payload of the injected
    /// block.
    static let environmentRecallBudgetKey = "ZENCODE_MEMORY_RECALL_MAX_CHARACTERS"

    /// Without an endpoint, retrieval is offline BM25 over an in-memory graph,
    /// which is normally sub-millisecond. With an endpoint, a bounded HTTP call
    /// to the embedding service is added. The budget absorbs scheduling jitter
    /// while ensuring a cold graph open never delays the main turn indefinitely.
    static let defaultRecallTimeoutMilliseconds = 150
    /// Hard bounds so a mistyped value cannot defeat the latency guarantee.
    static let minimumRecallTimeoutMilliseconds = 10
    static let maximumRecallTimeoutMilliseconds = 5_000

    /// Budgets are expressed in characters because that unit is exact,
    /// provider-independent and stable across runs. The estimate is reporting
    /// only; it never drives truncation.
    static let charactersPerApproximateToken = 4

    /// Bounds the recalled payload merged into the outgoing user message.
    /// Retrieval is selection-limited but graph-dependent, so without a budget
    /// a large workspace could push an arbitrarily long block into a request.
    static let defaultRecallBudgetCharacters = 4_000
    static let minimumRecallBudgetCharacters = 200
    static let maximumRecallBudgetCharacters = 32_000

    /// Automatic recall is enabled unless explicitly switched off.
    static var isAutoRecallEnabled: Bool {
        boolean(forKey: environmentAutoRecallKey, default: true)
    }

    static var recallTimeout: Duration {
        .milliseconds(recallTimeoutMilliseconds)
    }

    static var recallTimeoutMilliseconds: Int {
        guard let raw = environment[environmentRecallTimeoutKey]?.nilIfBlank,
              let parsed = Int(raw) else {
            return defaultRecallTimeoutMilliseconds
        }
        return min(
            max(parsed, minimumRecallTimeoutMilliseconds),
            maximumRecallTimeoutMilliseconds
        )
    }

    static var recallBudgetCharacters: Int {
        clampedInteger(
            forKey: environmentRecallBudgetKey,
            default: defaultRecallBudgetCharacters,
            minimum: minimumRecallBudgetCharacters,
            maximum: maximumRecallBudgetCharacters
        )
    }

    /// Conventional 4-characters-per-token estimate. Reporting only: no
    /// truncation decision is ever taken from this value.
    static func approximateTokens(forCharacters characters: Int) -> Int {
        max(characters, 0) / charactersPerApproximateToken
    }

    /// Reads a bounded integer, falling back to the default on anything absent
    /// or unparseable so a mistyped value cannot defeat a budget.
    private static func clampedInteger(
        forKey key: String,
        default defaultValue: Int,
        minimum: Int,
        maximum: Int
    ) -> Int {
        guard let raw = environment[key]?.nilIfBlank,
              let parsed = Int(raw) else {
            return defaultValue
        }
        return min(max(parsed, minimum), maximum)
    }

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    /// Accepts the usual shell spellings. An unrecognized value falls back to
    /// the default rather than guessing.
    private static func boolean(forKey key: String, default defaultValue: Bool) -> Bool {
        guard let raw = environment[key]?.nilIfBlank?.lowercased() else {
            return defaultValue
        }
        switch raw {
        case "1", "true", "yes", "y", "on", "enabled":
            return true
        case "0", "false", "no", "n", "off", "disabled":
            return false
        default:
            return defaultValue
        }
    }
}
