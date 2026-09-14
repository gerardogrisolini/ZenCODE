//
//  AnthropicSubscriptionGenerationClient+Thinking.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

import Foundation
import ToolCore

extension AnthropicSubscriptionGenerationClient {
    func modelLLMID() -> String {
        configuration.modelID?.nilIfBlank ?? provider.modelID
    }

    func resolvedContextWindowTokenLimit() -> Int? {
        configuration.configuredContextWindowLimit
    }

    nonisolated static func anthropicSubscriptionVisibleMetrics(
        _ metrics: DirectAgentGenerationMetrics
    ) -> DirectAgentGenerationMetrics {
        DirectAgentGenerationMetrics(
            promptTokenCount: metrics.promptTokenCount,
            cachedPromptTokenCount: metrics.cachedPromptTokenCount,
            completionTokenCount: metrics.completionTokenCount,
            responseDurationSeconds: metrics.responseDurationSeconds,
            contextTokenCount: metrics.contextTokenCount,
            clearsPromptMetrics: true,
            replacesPreviousMetrics: true
        )
    }

    nonisolated static func publishAnthropicSubscriptionMetrics(
        _ metrics: DirectAgentGenerationMetrics,
        maxTokens: Int?,
        modelID: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        let visibleMetrics = anthropicSubscriptionVisibleMetrics(metrics)
        await onEvent(.metrics(visibleMetrics))
        guard let contextTokenCount = metrics.contextTokenCount else {
            return
        }
        await onEvent(
            .contextWindow(
                DirectAgentContextWindowStatus(
                    usedTokens: contextTokenCount,
                    maxTokens: maxTokens,
                    modelID: modelID,
                    isApproximate: true
                )
            )
        )
    }

    func resolvedMaxOutputTokens() -> Int {
        let catalogLimit = configuration.generationParameterOverrides.maxTokens.flatMap { $0 > 0 ? $0 : nil }
        let requestedLimit = configuration.maxOutputTokens.flatMap { $0 > 0 ? $0 : nil }
        if let catalogLimit, let requestedLimit { return min(catalogLimit, requestedLimit) }
        return catalogLimit ?? requestedLimit ?? 4_096
    }

    func applyThinkingSelection(
        _ selection: AgentThinkingSelection?,
        to body: inout [String: Any]
    ) {
        guard let catalogThinkingMode else { return }
        let payload = Self.catalogThinkingPayload(
            mode: catalogThinkingMode,
            selection: selection,
            options: thinkingOptions ?? [],
            maxTokens: resolvedMaxOutputTokens()
        )
        if let thinking = payload.thinking { body["thinking"] = thinking }
        if let outputConfig = payload.outputConfig { body["output_config"] = outputConfig }
    }

    /// Uses the supplied wire mode and explicitly configured thinking options.
    /// Unknown modes and missing selections do not activate model defaults.
    static func catalogThinkingPayload(
        mode: String, selection: AgentThinkingSelection?, options: [AgentThinkingSelection], maxTokens: Int
    ) -> (thinking: [String: Any]?, outputConfig: [String: Any]?) {
        guard mode == "adaptive" || mode == "enabled",
              let selection, options.contains(selection) else { return (nil, nil) }
        guard selection.isEnabled else { return (["type": "disabled"], nil) }
        if mode == "adaptive" {
            return (["type": "adaptive"], ["effort": selection.rawValue])
        }
        let budget = adjustedThinkingBudget(thinkingBudgetTokens(for: selection), maxTokens: maxTokens)
        guard budget >= minimumThinkingBudgetTokens else { return (nil, nil) }
        return (["type": "enabled", "budget_tokens": budget], nil)
    }

    /// Anthropic rejects a `budget_tokens` value below this floor.
    static let minimumThinkingBudgetTokens = 1_024

    /// Manual thinking budgets for models that still use
    /// `thinking: {type: "enabled", budget_tokens: N}`.
    ///
    /// The ladder stays between Anthropic's documented 1,024 token minimum and
    /// the 32,000 token ceiling above which long thinking requests are expected
    /// to run as batch work instead of streaming.
    static func thinkingBudgetTokens(for selection: AgentThinkingSelection) -> Int {
        switch selection {
        case .off:
            return 0
        case .minimal:
            return minimumThinkingBudgetTokens
        case .enabled:
            // Thinking on without an explicit level: balanced depth.
            return 8_192
        case .low:
            return 4_096
        case .medium:
            return 8_192
        case .high:
            return 16_384
        case .xhigh:
            return 24_576
        case .max, .ultra:
            return 32_000
        }
    }

    static func adjustedThinkingBudget(_ budget: Int, maxTokens: Int) -> Int {
        guard maxTokens <= budget else {
            return budget
        }
        return max(0, maxTokens - minimumOutputTokensForThinking)
    }

    static func subscriptionSystemBlocks(userSystemPrompt: String?) -> [[String: Any]] {
        var blocks = [
            subscriptionSystemTextBlock(
                "You are Claude Code, Anthropic's official CLI for Claude."
            )
        ]
        if let userSystemPrompt = userSystemPrompt?.nilIfBlank {
            blocks.append(subscriptionSystemTextBlock(userSystemPrompt))
        }
        // A single cache breakpoint on the last system block covers the whole
        // static prefix (tools + system). Marking every block wastes
        // breakpoints from Anthropic's per-request budget of 4.
        if let lastIndex = blocks.indices.last {
            blocks[lastIndex]["cache_control"] = systemCacheControl()
        }
        return blocks
    }

    static func subscriptionSystemTextBlock(_ text: String) -> [String: Any] {
        [
            "type": "text",
            "text": text
        ]
    }


    static func cacheControl() -> [String: Any] {
        ["type": "ephemeral", "ttl": "1h"]
    }

    static func systemCacheControl() -> [String: Any] {
        var value = cacheControl()
        value["scope"] = "global"
        return value
    }

    static func oauthBetaHeader(contextWindowTokenLimit: Int?, thinkingMode: String?) -> String {
        var headers = [
            claudeCodeBetaHeader,
            oauthBetaHeader,
            contextManagementBetaHeader,
            promptCachingScopeBetaHeader,
            extendedCacheTTLHeader
        ]
        if let contextWindowTokenLimit, contextWindowTokenLimit > 200_000 {
            headers.append(longContextBetaHeader)
        }
        if thinkingMode == "adaptive" {
            headers.append(effortBetaHeader)
        } else if thinkingMode == "enabled" {
            headers.append(interleavedThinkingBetaHeader)
        }
        return headers.joined(separator: ",")
    }
}
