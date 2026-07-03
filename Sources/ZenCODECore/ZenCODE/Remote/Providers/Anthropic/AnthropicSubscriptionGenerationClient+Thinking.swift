//
//  AnthropicSubscriptionGenerationClient+Thinking.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

#if os(macOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
            promptTokenCount: nil,
            cachedPromptTokenCount: nil,
            promptTokensPerSecond: nil,
            completionTokenCount: metrics.completionTokenCount,
            completionTokensPerSecond: metrics.completionTokensPerSecond,
            responseDurationSeconds: metrics.responseDurationSeconds,
            contextTokenCount: metrics.contextTokenCount,
            clearsPromptMetrics: true
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
        guard let selection, selection.isEnabled else {
            body["thinking"] = ["type": "disabled"]
            return
        }

        if Self.usesAdaptiveThinking(modelID: modelID) {
            body["thinking"] = [
                "type": "adaptive",
                "display": "summarized"
            ]
            if let effort = Self.adaptiveThinkingEffort(
                for: selection,
                modelID: modelID
            ) {
                body["output_config"] = ["effort": effort]
            }
            return
        }

        let maxTokens = resolvedMaxOutputTokens(
            forLLMID: modelLLMID,
            thinkingSelection: selection
        )
        let budget = Self.adjustedThinkingBudget(
            Self.thinkingBudgetTokens(for: selection),
            maxTokens: maxTokens
        )
        guard budget > 0 else {
            return
        }
        body["thinking"] = [
            "type": "enabled",
            "budget_tokens": budget,
            "display": "summarized"
        ]
    }

    static func supportsThinking(modelID: String) -> Bool {
        AnthropicSubscriptionModel.option(forModelID: modelID).thinkingSupport != nil
    }

    static func usesAdaptiveThinking(modelID: String) -> Bool {
        switch modelID {
        case "claude-fable-5",
             "claude-opus-4-6",
             "claude-opus-4-7",
             "claude-opus-4-8",
             "claude-sonnet-4-6":
            return true
        default:
            return false
        }
    }

    static func adaptiveThinkingEffort(
        for selection: AgentThinkingSelection,
        modelID: String
    ) -> String? {
        switch selection {
        case .off, .enabled:
            return nil
        case .minimal, .low:
            return "low"
        case .medium:
            return "medium"
        case .high:
            return "high"
        case .xhigh:
            switch modelID {
            case "claude-fable-5", "claude-opus-4-7", "claude-opus-4-8":
                return "xhigh"
            case "claude-opus-4-6":
                return "max"
            default:
                return "high"
            }
        }
    }

    static func thinkingBudgetTokens(for selection: AgentThinkingSelection) -> Int {
        switch selection {
        case .off:
            return 0
        case .enabled, .minimal:
            return 1_024
        case .low:
            return 2_048
        case .medium:
            return 8_192
        case .high, .xhigh:
            return 16_384
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
            blocks[lastIndex]["cache_control"] = cacheControl()
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

    static func oauthBetaHeader(forModelID modelID: String) -> String {
        var headers = [
            claudeCodeBetaHeader,
            oauthBetaHeader,
            extendedCacheTTLHeader
        ]
        if !usesAdaptiveThinking(modelID: modelID) {
            headers.append(interleavedThinkingBetaHeader)
        }
        return headers.joined(separator: ",")
    }
}
#endif
