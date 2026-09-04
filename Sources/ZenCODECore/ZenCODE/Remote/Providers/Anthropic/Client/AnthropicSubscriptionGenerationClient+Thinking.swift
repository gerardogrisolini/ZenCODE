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

    func resolvedContextWindowTokenLimit(forLLMID modelLLMID: String?) -> Int? {
        configuration.configuredContextWindowLimit
            ?? AnthropicSubscriptionModel.contextWindowTokenLimit(forLLMID: modelLLMID)
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

    func resolvedMaxOutputTokens(
        forLLMID modelLLMID: String?,
        thinkingSelection: AgentThinkingSelection? = nil
    ) -> Int {
        let modelID = AnthropicSubscriptionModel.modelID(fromLLMID: modelLLMID)
        let modelLimit = AnthropicSubscriptionModel.maxOutputTokens(forLLMID: modelLLMID)
        guard let configuredLimit = configuration.maxOutputTokens, configuredLimit > 0 else {
            return modelLimit
        }
        guard let thinkingSelection,
              thinkingSelection.isEnabled,
              Self.supportsThinking(modelID: modelID),
              !Self.usesAdaptiveThinking(modelID: modelID) else {
            return min(configuredLimit, modelLimit)
        }
        return min(
            configuredLimit + Self.thinkingBudgetTokens(for: thinkingSelection),
            modelLimit
        )
    }

    func applyThinkingSelection(
        _ selection: AgentThinkingSelection?,
        to body: inout [String: Any],
        modelLLMID: String
    ) {
        let modelID = AnthropicSubscriptionModel.modelID(fromLLMID: modelLLMID)
        guard Self.supportsThinking(modelID: modelID) else {
            return
        }
        let maxTokens = resolvedMaxOutputTokens(
            forLLMID: modelLLMID,
            thinkingSelection: selection
        )
        let payload = Self.thinkingPayload(
            for: selection,
            modelID: modelID,
            maxTokens: maxTokens
        )
        if let thinking = payload.thinking {
            body["thinking"] = thinking
        }
        if let outputConfig = payload.outputConfig {
            body["output_config"] = outputConfig
        }
    }

    static func thinkingPayload(
        for selection: AgentThinkingSelection?,
        modelID: String,
        maxTokens: Int
    ) -> (thinking: [String: Any]?, outputConfig: [String: Any]?) {
        guard supportsThinking(modelID: modelID) else {
            return (nil, nil)
        }
        guard let selection, selection.isEnabled else {
            if usesAdaptiveThinking(modelID: modelID) {
                if selection == .off {
                    // Explicitly disabled: send disabled to turn off adaptive thinking.
                    return (["type": "disabled"], nil)
                }
                // No preference: activate adaptive thinking at the default
                // effort. The Claude Code subscription endpoint requires
                // explicit output_config.effort to enable thinking; omitting
                // it leaves the model without thinking.
                return (nil, ["effort": "high"])
            }
            return (["type": "disabled"], nil)
        }

        let outputConfig: [String: Any]?
        if usesAdaptiveThinking(modelID: modelID),
           let effort = adaptiveThinkingEffort(
               for: selection,
               modelID: modelID
           ) {
            outputConfig = ["effort": effort]
        } else {
            outputConfig = nil
        }
        if usesAdaptiveThinking(modelID: modelID) {
            var thinking: [String: Any] = ["type": "adaptive"]
            if usesSummarizedThinkingDisplay(modelID: modelID) {
                thinking["display"] = "summarized"
            }
            return (
                thinking,
                outputConfig
            )
        }

        let budget = adjustedThinkingBudget(
            thinkingBudgetTokens(for: selection),
            maxTokens: maxTokens
        )
        guard budget >= minimumThinkingBudgetTokens else {
            return (nil, nil)
        }
        return (
            [
                "type": "enabled",
                "budget_tokens": budget
            ],
            outputConfig
        )
    }

    /// Adaptive models default to omitting visible thinking text. ZenCODE
    /// renders streamed thinking, so every enabled adaptive request opts into
    /// summarized display and receives `thinking_delta` events from Anthropic.
    static func usesSummarizedThinkingDisplay(modelID: String) -> Bool {
        adaptiveThinkingModelIDs.contains(modelID)
    }

    static func supportsThinking(modelID: String) -> Bool {
        AnthropicSubscriptionModel.option(forModelID: modelID).thinkingSupport != nil
    }

    /// Models of the Claude 5 generation that replace manual `budget_tokens`
    /// with `thinking: {type: "adaptive"}` plus `output_config.effort`.
    /// They are also the models that accept the gated `xhigh` and `max`
    /// effort levels.
    static let adaptiveThinkingModelIDs: Set<String> = [
        "claude-fable-5",
        "claude-opus-5",
        "claude-sonnet-5"
    ]

    /// Anthropic rejects a `budget_tokens` value below this floor.
    static let minimumThinkingBudgetTokens = 1_024

    static func usesAdaptiveThinking(modelID: String) -> Bool {
        adaptiveThinkingModelIDs.contains(modelID)
    }

    /// `xhigh` and `max` are model gated. Every adaptive model in the catalog
    /// supports both, while any other model falls back to `high`, which is the
    /// API default.
    static func supportsExtendedEffortLevels(modelID: String) -> Bool {
        adaptiveThinkingModelIDs.contains(modelID)
    }

    static func adaptiveThinkingEffort(
        for selection: AgentThinkingSelection,
        modelID: String
    ) -> String? {
        switch selection {
        case .off, .enabled:
            // Omitting `effort` selects the API default, which is `high`, and
            // keeps the prompt cache stable.
            return nil
        case .minimal, .low:
            // Anthropic has no `minimal` effort level.
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        case .xhigh:
            return supportsExtendedEffortLevels(modelID: modelID) ? "xhigh" : "high"
        case .max, .ultra:
            return supportsExtendedEffortLevels(modelID: modelID) ? "max" : "high"
        }
    }

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

    static func oauthBetaHeader(forModelID modelID: String) -> String {
        var headers = [
            claudeCodeBetaHeader,
            oauthBetaHeader,
            contextManagementBetaHeader,
            promptCachingScopeBetaHeader,
            extendedCacheTTLHeader
        ]
        if AnthropicSubscriptionModel
            .option(forModelID: modelID)
            .contextWindowTokenLimit == AnthropicSubscriptionModel.largeContextWindowTokenLimit {
            headers.append(longContextBetaHeader)
        }
        if usesAdaptiveThinking(modelID: modelID) {
            headers.append(effortBetaHeader)
        }
        if !usesAdaptiveThinking(modelID: modelID) {
            headers.append(interleavedThinkingBetaHeader)
        }
        return headers.joined(separator: ",")
    }
}
