//
//  ChatGPTSubscriptionGenerationClient+MetricsAndSession.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(os)
import os
#endif

extension ChatGPTSubscriptionGenerationClient {
    func resolvedContextWindowTokenLimit(forLLMID modelLLMID: String) -> Int? {
        configuration.configuredContextWindowLimit
            ?? CodexAgentModel.contextWindowTokenLimit(forLLMID: modelLLMID)
    }

    static func publishChatGPTSubscriptionMetrics(
        _ metrics: DirectAgentGenerationMetrics,
        estimatedContextTokens: Int?,
        completionTokens: Int?,
        generatedText: String,
        maxTokens: Int?,
        modelID: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        await onEvent(.metrics(chatGPTSubscriptionVisibleMetrics(metrics)))
        await onEvent(
            .contextWindow(
                DirectAgentContextWindowStatus(
                    usedTokens: chatGPTSubscriptionContextTokenCount(
                        metrics,
                        estimatedContextTokens: estimatedContextTokens,
                        completionTokens: completionTokens,
                        generatedText: generatedText
                    ),
                    maxTokens: maxTokens,
                    modelID: modelID,
                    isApproximate: true
                )
            )
        )
    }

    nonisolated static func chatGPTSubscriptionVisibleMetrics(
        _ metrics: DirectAgentGenerationMetrics
    ) -> DirectAgentGenerationMetrics {
        DirectAgentGenerationMetrics(
            promptTokenCount: metrics.promptTokenCount,
            cachedPromptTokenCount: metrics.cachedPromptTokenCount,
            promptTokensPerSecond: metrics.promptTokensPerSecond,
            completionTokenCount: metrics.completionTokenCount,
            completionTokensPerSecond: metrics.completionTokensPerSecond,
            responseDurationSeconds: metrics.responseDurationSeconds,
            contextTokenCount: metrics.contextTokenCount,
            clearsPromptMetrics: true,
            replacesPreviousMetrics: true
        )
    }

    static func chatGPTSubscriptionContextTokenCount(
        _ metrics: DirectAgentGenerationMetrics,
        estimatedContextTokens: Int?,
        completionTokens: Int?,
        generatedText: String
    ) -> Int? {
        if let contextTokenCount = metrics.contextTokenCount {
            return contextTokenCount
        }

        let generatedTokenCount = completionTokens
            ?? estimatedTokenCount(forText: generatedText)
        let estimatedTotalTokenCount = estimatedContextTokens.map {
            $0 + (generatedTokenCount ?? 0)
        }
        let reportedPromptTokenCount = metrics.promptTokenCount.map {
            $0 + (metrics.cachedPromptTokenCount ?? 0) + (generatedTokenCount ?? 0)
        }

        return [
            estimatedTotalTokenCount,
            reportedPromptTokenCount,
            estimatedContextTokens
        ]
        .compactMap { $0 }
        .max()
    }

    static func estimatedTokenCount(forText text: String) -> Int? {
        let byteCount = text.data(using: .utf8)?.count ?? text.utf8.count
        guard byteCount > 0 else {
            return nil
        }
        return max(Int((Double(byteCount) / 4.0).rounded(.up)), 1)
    }

    func promptCacheKey(for identity: SessionIdentity) -> String? {
        promptCacheKeysByIdentity[identity]
            ?? storedPromptCacheKeysByIdentity[identity.promptCachePersistenceKey]
    }

    @discardableResult
    func storePromptCacheKey(
        _ promptCacheKey: String,
        for identity: SessionIdentity
    ) -> String {
        promptCacheKeysByIdentity[identity] = promptCacheKey
        guard identity.connectionScopeID == nil else {
            return promptCacheKey
        }

        let persistenceKey = identity.promptCachePersistenceKey
        guard Self.isValidStoredPromptCacheValue(promptCacheKey) else {
            return promptCacheKey
        }
        let resolution = Self.resolveAndStorePromptCacheKey(
            promptCacheKey,
            for: persistenceKey
        )
        promptCacheKeysByIdentity[identity] = resolution.promptCacheKey
        storedPromptCacheKeysByIdentity = resolution.values
        return resolution.promptCacheKey
    }

    static func loadStoredPromptCacheKeys(
        userDefaults: UserDefaults = .standard
    ) -> [String: String] {
        promptCachePersistenceLock.withLock { _ in
            let loaded = readStoredPromptCacheKeys(userDefaults: userDefaults)
            let boundedValues = boundedStoredPromptCacheKeys(
                loaded.values,
                preserving: nil
            )
            if loaded.requiresRewrite || boundedValues.count != loaded.rawCount {
                userDefaults.set(
                    boundedValues,
                    forKey: promptCacheKeyStoreUserDefaultsKey
                )
            }
            return boundedValues
        }
    }

    private static func readStoredPromptCacheKeys(
        userDefaults: UserDefaults
    ) -> (values: [String: String], rawCount: Int, requiresRewrite: Bool) {
        guard let rawValues = userDefaults.dictionary(
            forKey: promptCacheKeyStoreUserDefaultsKey
        ) else {
            return ([:], 0, false)
        }

        var requiresRewrite = false
        var currentValues: [String: String] = [:]
        var legacyValues: [String: String] = [:]
        for entry in rawValues {
            guard let value = entry.value as? String,
                  isValidStoredPromptCacheValue(value) else {
                requiresRewrite = true
                continue
            }

            if SessionIdentity.isPromptCachePersistenceKey(entry.key) {
                currentValues[entry.key] = value
                continue
            }

            requiresRewrite = true
            guard let identity = SessionIdentity(storageKey: entry.key),
                  identity.connectionScopeID == nil else {
                continue
            }
            legacyValues[identity.promptCachePersistenceKey] = value
        }

        // Prefer an already-migrated value when both formats represent the same
        // identity; a stale legacy entry must not replace the v2 value.
        for entry in legacyValues where currentValues[entry.key] == nil {
            currentValues[entry.key] = entry.value
        }
        if currentValues.count != rawValues.count {
            requiresRewrite = true
        }
        return (currentValues, rawValues.count, requiresRewrite)
    }

    static func boundedStoredPromptCacheKeys(
        _ values: [String: String],
        preserving requiredKey: String?
    ) -> [String: String] {
        let validValues = values.filter { entry in
            SessionIdentity.isPromptCachePersistenceKey(entry.key)
                && isValidStoredPromptCacheValue(entry.value)
        }
        guard validValues.count > maximumStoredPromptCacheKeyCount else {
            return validValues
        }

        var retainedKeys = Array(
            validValues.keys.sorted().suffix(maximumStoredPromptCacheKeyCount)
        )
        if let requiredKey,
           validValues[requiredKey] != nil,
           !retainedKeys.contains(requiredKey) {
            retainedKeys.removeFirst()
            retainedKeys.append(requiredKey)
        }
        return Dictionary(
            uniqueKeysWithValues: retainedKeys.compactMap { key in
                validValues[key].map { (key, $0) }
            }
        )
    }

    static func isValidStoredPromptCacheValue(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumStoredPromptCacheValueByteCount
    }

    static func resolveAndStorePromptCacheKey(
        _ promptCacheKey: String,
        for persistenceKey: String,
        userDefaults: UserDefaults = .standard
    ) -> (promptCacheKey: String, values: [String: String]) {
        promptCachePersistenceLock.withLock { _ in
            var values = readStoredPromptCacheKeys(userDefaults: userDefaults).values
            let resolvedPromptCacheKey = values[persistenceKey] ?? promptCacheKey
            values[persistenceKey] = resolvedPromptCacheKey
            let boundedValues = boundedStoredPromptCacheKeys(
                values,
                preserving: persistenceKey
            )
            userDefaults.set(
                boundedValues,
                forKey: promptCacheKeyStoreUserDefaultsKey
            )
            return (resolvedPromptCacheKey, boundedValues)
        }
    }

    func modelLLMID() -> String {
        CodexAgentModel.selectionID(
            forModelID: CodexAgentModel.modelID(fromLLMID: configuration.modelID)
        )
    }

    static func chatGPTReasoningEffort(
        for selection: AgentThinkingSelection
    ) -> String? {
        switch selection {
        case .off:
            return nil
        case .enabled:
            return AgentThinkingSelection.medium.rawValue
        case .minimal:
            return AgentThinkingSelection.low.rawValue
        case .low, .medium, .high, .xhigh, .max, .ultra:
            return selection.rawValue
        }
    }

    static func isContinuationReplayRejected(_ error: Error) -> Bool {
        let message = (error as? LocalizedError)?.errorDescription
            ?? error.localizedDescription
        let normalizedMessage = message.lowercased()
        let mentionsContinuation = normalizedMessage.contains("previous_response")
            || normalizedMessage.contains("previous response")
            || normalizedMessage.contains("response id")
            || normalizedMessage.contains("response_id")
        let rejectsContinuation = normalizedMessage.contains("not found")
            || normalizedMessage.contains("invalid")
            || normalizedMessage.contains("expired")
            || normalizedMessage.contains("unknown")

        return mentionsContinuation && rejectsContinuation
    }
}
