//
//  AnthropicSubscriptionModel.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

import Foundation

public nonisolated enum AnthropicSubscriptionModel {
    public struct ModelOption: Identifiable, Hashable, Sendable {
        public let modelID: String
        public let title: String
        public let subtitle: String
        public let contextWindowTokenLimit: Int?
        public let maxOutputTokens: Int
        public let thinkingSupport: MLXModelThinkingSupport?

        public var id: String { modelID }
        public var llmID: String {
            AnthropicSubscriptionModel.selectionID(forModelID: modelID)
        }
    }

    public static let llmID = "claude"
    public static let defaultModelID = "claude-opus-4-8"
    public static var defaultLLMID: String {
        selectionID(forModelID: defaultModelID)
    }
    public static let modelID = defaultModelID
    public static let displayTitle = "Claude Subscription"
    public static let displaySubtitle = "Claude Pro/Max"
    public static let defaultContextWindowTokenLimit = 200_000
    public static let largeContextWindowTokenLimit = 1_000_000
    public static let defaultMaxOutputTokens = 64_000
    public static let largeMaxOutputTokens = 128_000
    public static let thinkingSupport = MLXModelThinkingSupport.effort(
        levels: [.low, .medium, .high, .xhigh]
    )

    public static let availableModels: [ModelOption] = [
        modelOption(
            modelID: "claude-fable-5",
            title: "Claude Fable 5",
            subtitle: "Adaptive reasoning",
            contextWindowTokenLimit: largeContextWindowTokenLimit,
            maxOutputTokens: largeMaxOutputTokens
        ),
        modelOption(
            modelID: "claude-opus-4-8",
            title: "Claude Opus 4.8",
            subtitle: "Frontier reasoning",
            contextWindowTokenLimit: largeContextWindowTokenLimit,
            maxOutputTokens: largeMaxOutputTokens
        ),
        modelOption(
            modelID: "claude-opus-4-7",
            title: "Claude Opus 4.7",
            subtitle: "Frontier reasoning",
            contextWindowTokenLimit: largeContextWindowTokenLimit,
            maxOutputTokens: largeMaxOutputTokens
        ),
        modelOption(
            modelID: "claude-opus-4-6",
            title: "Claude Opus 4.6",
            subtitle: "Frontier reasoning",
            contextWindowTokenLimit: largeContextWindowTokenLimit,
            maxOutputTokens: largeMaxOutputTokens
        ),
        modelOption(
            modelID: "claude-sonnet-5-0",
            title: "Claude Sonnet 5.0",
            subtitle: "Latest everyday coding",
            contextWindowTokenLimit: largeContextWindowTokenLimit,
            maxOutputTokens: largeMaxOutputTokens
        ),
        modelOption(
            modelID: "claude-sonnet-4-6",
            title: "Claude Sonnet 4.6",
            subtitle: "Everyday coding",
            contextWindowTokenLimit: largeContextWindowTokenLimit,
            maxOutputTokens: defaultMaxOutputTokens
        ),
        modelOption(
            modelID: "claude-haiku-4-5",
            title: "Claude Haiku 4.5 (latest)",
            subtitle: "Fast small model",
            contextWindowTokenLimit: defaultContextWindowTokenLimit,
            maxOutputTokens: defaultMaxOutputTokens
        )
    ]

    private static func modelOption(
        modelID: String,
        title: String,
        subtitle: String,
        contextWindowTokenLimit: Int?,
        maxOutputTokens: Int,
        supportsThinking: Bool = true
    ) -> ModelOption {
        ModelOption(
            modelID: modelID,
            title: title,
            subtitle: subtitle,
            contextWindowTokenLimit: contextWindowTokenLimit,
            maxOutputTokens: maxOutputTokens,
            thinkingSupport: supportsThinking ? thinkingSupport : nil
        )
    }

    public static func isAnthropicSubscriptionLLMID(_ value: String?) -> Bool {
        guard let normalizedValue = value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              !normalizedValue.isEmpty else {
            return false
        }

        return isSubscriptionPrefix(normalizedValue, prefix: llmID)
    }

    public static func canonicalLLMID(_ value: String?) -> String {
        guard isAnthropicSubscriptionLLMID(value) else {
            return ""
        }
        return selectionID(forModelID: modelID(fromLLMID: value))
    }

    public static func selectionID(forModelID modelID: String) -> String {
        "\(llmID):\(normalizedModelID(modelID))"
    }

    public static func modelID(fromLLMID value: String?) -> String {
        guard let value else {
            return defaultModelID
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return defaultModelID
        }

        let lowercasedValue = trimmedValue.lowercased()
        if lowercasedValue == llmID {
            return defaultModelID
        }
        for separator in [":", "/"] where lowercasedValue.hasPrefix(llmID + separator) {
            let rawModelID = String(trimmedValue.dropFirst(llmID.count + separator.count))
            return normalizedModelID(rawModelID)
        }
        return normalizedModelID(trimmedValue)
    }

    public static func option(forLLMID value: String?) -> ModelOption {
        option(forModelID: modelID(fromLLMID: value))
    }

    public static func option(forModelID modelID: String) -> ModelOption {
        let normalizedModelID = normalizedModelID(modelID)
        if let option = availableModels.first(where: { $0.modelID == normalizedModelID }) {
            return option
        }
        return ModelOption(
            modelID: normalizedModelID,
            title: normalizedModelID,
            subtitle: displaySubtitle,
            contextWindowTokenLimit: nil,
            maxOutputTokens: defaultMaxOutputTokens,
            thinkingSupport: thinkingSupport
        )
    }

    public static func selectionTitle(forLLMID value: String?) -> String {
        "\(displayTitle) · \(option(forLLMID: value).title)"
    }

    public static func contextWindowTokenLimit(forLLMID value: String?) -> Int? {
        option(forLLMID: value).contextWindowTokenLimit
    }

    public static func maxOutputTokens(forLLMID value: String?) -> Int {
        option(forLLMID: value).maxOutputTokens
    }

    public static var isAvailable: Bool {
        isAuthenticated
    }

    public static var isAuthenticated: Bool {
#if os(macOS)
        (try? AnthropicSubscriptionAuthService.loadCredentials()) != nil
#else
        false
#endif
    }

    public static var isReady: Bool {
        isAuthenticated
    }

    private static func normalizedModelID(_ value: String) -> String {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? defaultModelID : trimmedValue
    }

    private static func isSubscriptionPrefix(_ value: String, prefix: String) -> Bool {
        value == prefix
            || value.hasPrefix(prefix + ":")
            || value.hasPrefix(prefix + "/")
    }
}
