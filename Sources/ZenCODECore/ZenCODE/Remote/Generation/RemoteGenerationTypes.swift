//
//  RemoteGenerationTypes.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public struct RemoteStreamResult: Sendable {
    public let text: String
    public let reasoningText: String
    public let stopReason: String
    public let toolCalls: [DirectAgentToolCall]
    public let stats: RemoteGenerationStats
    /// Provider-specific assistant content blocks that must be replayed verbatim
    /// on later requests (for example Anthropic signed `thinking` blocks),
    /// serialized as a JSON array string to stay `Sendable`.
    public let assistantThinkingBlocksJSON: String?
    /// OpenAI Responses reasoning output items that carry encrypted content and
    /// must be replayed verbatim on later requests while `store` is disabled,
    /// serialized as a JSON array string to stay `Sendable`.
    public let reasoningItemsJSON: String?

    public init(
        text: String,
        reasoningText: String = "",
        stopReason: String,
        toolCalls: [DirectAgentToolCall],
        stats: RemoteGenerationStats,
        assistantThinkingBlocksJSON: String? = nil,
        reasoningItemsJSON: String? = nil
    ) {
        self.text = text
        self.reasoningText = reasoningText
        self.stopReason = stopReason
        self.toolCalls = toolCalls
        self.stats = stats
        self.assistantThinkingBlocksJSON = assistantThinkingBlocksJSON
        self.reasoningItemsJSON = reasoningItemsJSON
    }
}

public struct RemoteGenerationStats: Sendable {
    public let usage: RemoteGenerationUsage?
    public let requestStartedAt: Date
    public let firstDeltaAt: Date?
    public let finishedAt: Date
    public let generatedCharacterCount: Int

    public init(
        usage: RemoteGenerationUsage?,
        requestStartedAt: Date,
        firstDeltaAt: Date?,
        finishedAt: Date,
        generatedCharacterCount: Int
    ) {
        self.usage = usage
        self.requestStartedAt = requestStartedAt
        self.firstDeltaAt = firstDeltaAt
        self.finishedAt = finishedAt
        self.generatedCharacterCount = generatedCharacterCount
    }

    public var prefillElapsed: TimeInterval {
        guard let firstDeltaAt else {
            return 0
        }
        return max(firstDeltaAt.timeIntervalSince(requestStartedAt), 0)
    }

    public var generationElapsed: TimeInterval {
        let generationStartedAt = firstDeltaAt ?? requestStartedAt
        return max(finishedAt.timeIntervalSince(generationStartedAt), 0)
    }
}

public struct RemoteGenerationUsage: Sendable {
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let totalTokens: Int?
    public let contextTokens: Int?
    public let processedPromptTokens: Int?
    public let cachedPromptTokens: Int?
    public let promptTokensPerSecond: Double?
    public let completionTokensPerSecond: Double?
    public let responseDurationSeconds: Double?

    public init(
        promptTokens: Int?,
        completionTokens: Int?,
        totalTokens: Int?,
        contextTokens: Int? = nil,
        processedPromptTokens: Int? = nil,
        cachedPromptTokens: Int? = nil,
        promptTokensPerSecond: Double?,
        completionTokensPerSecond: Double?,
        responseDurationSeconds: Double? = nil
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.contextTokens = contextTokens
        self.processedPromptTokens = processedPromptTokens
        self.cachedPromptTokens = cachedPromptTokens
        self.promptTokensPerSecond = promptTokensPerSecond
        self.completionTokensPerSecond = completionTokensPerSecond
        self.responseDurationSeconds = responseDurationSeconds
    }
}

public enum ParsedRemoteStreamEvent {
    case content(String)
    case contentSnapshot(String)
    case reasoning(String)
    case toolCallDelta([[String: Any]])
    case responseToolCallItem([String: Any], outputIndex: Int?)
    case responseReasoningItem([String: Any])
    case responseToolCallArgumentsDelta([String: Any])
    case responseToolCallArgumentsDone([String: Any])
    case stop(String)
    case failure(String)
    case usage(RemoteGenerationUsage)
    case ignored
}

public enum RemoteGenerationClientError: LocalizedError {
    case invalidBaseURL(String)
    case missingAPIKey(String)
    case missingSession
    case httpStatus(Int)
    case remoteFailure(String)
    case invalidToolArguments
    case tooManyToolRounds(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidBaseURL(value):
            return "Invalid remote provider base URL: \(value)"
        case let .missingAPIKey(providerName):
            return "No API key is available for \(providerName)."
        case .missingSession:
            return "The remote agent session is missing."
        case let .httpStatus(statusCode):
            return "Remote provider returned HTTP \(statusCode)."
        case let .remoteFailure(message):
            return "Remote provider failed: \(message)"
        case .invalidToolArguments:
            return "Remote provider returned invalid tool call arguments."
        case let .tooManyToolRounds(limit):
            return "The remote model requested tools for \(limit) rounds without finishing."
        }
    }
}
