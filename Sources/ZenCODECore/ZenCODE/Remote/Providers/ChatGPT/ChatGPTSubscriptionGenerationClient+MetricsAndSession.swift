//
//  ChatGPTSubscriptionGenerationClient+MetricsAndSession.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if os(macOS)
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

    func storeSessionID(_ sessionID: String, for identity: SessionIdentity) {
        sessionIDsByIdentity[identity] = sessionID
        Self.storeSessionIDs(sessionIDsByIdentity)
    }

    static func loadStoredSessionIDs() -> [SessionIdentity: String] {
        guard let rawValues =
            UserDefaults.standard.dictionary(forKey: sessionStoreUserDefaultsKey) as? [String: String]
        else {
            return [:]
        }

        return rawValues.reduce(into: [:]) { result, entry in
            guard let identity = SessionIdentity(storageKey: entry.key) else {
                return
            }
            result[identity] = entry.value
        }
    }

    static func storeSessionIDs(_ values: [SessionIdentity: String]) {
        let rawValues = Dictionary(
            uniqueKeysWithValues: values.map { identity, sessionID in
                (identity.storageKey, sessionID)
            }
        )
        UserDefaults.standard.set(rawValues, forKey: sessionStoreUserDefaultsKey)
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
        case .low, .medium, .high, .xhigh:
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
#endif
