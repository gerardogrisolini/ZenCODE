//
//  DirectAgentRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public struct DirectAgentResponse: Sendable {
    public let text: String
    public let stopReason: String
    public let modelID: String

    public init(
        text: String,
        stopReason: String,
        modelID: String
    ) {
        self.text = text
        self.stopReason = stopReason
        self.modelID = modelID
    }
}

/// Tool arguments are JSON-compatible but stored as `[String: Any]` for the public tool runtime API.
public struct DirectAgentToolCall: @unchecked Sendable {
    public let id: String
    public let name: String
    public let argumentsObject: [String: Any]
    public let argumentsJSON: String

    public init(
        id: String,
        name: String,
        argumentsObject: [String: Any],
        argumentsJSON: String
    ) {
        self.id = id
        self.name = name
        self.argumentsObject = argumentsObject
        self.argumentsJSON = argumentsJSON
    }
}

public struct DirectAgentToolResult: Sendable {
    public enum Status: String, Sendable, Equatable {
        case completed
        case failed
        case permissionDenied
    }

    public let output: String
    public let summary: String
    public let status: Status

    public init(
        output: String,
        summary: String,
        status: Status = .completed
    ) {
        self.output = output
        self.summary = summary
        self.status = status
    }

    public var isFailure: Bool {
        status != .completed
            || output.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasPrefix("Tool error:")
    }

    public var isPermissionDenied: Bool {
        status == .permissionDenied
    }
}

public struct DirectAgentGenerationMetrics: Sendable {
    public let promptTokenCount: Int?
    public let cachedPromptTokenCount: Int?
    public let promptTokensPerSecond: Double?
    public let completionTokenCount: Int?
    public let completionTokensPerSecond: Double?
    public let responseDurationSeconds: Double?
    public let contextTokenCount: Int?
    public let clearsPromptMetrics: Bool

    public init(
        promptTokenCount: Int?,
        cachedPromptTokenCount: Int? = nil,
        promptTokensPerSecond: Double?,
        completionTokenCount: Int?,
        completionTokensPerSecond: Double?,
        responseDurationSeconds: Double? = nil,
        contextTokenCount: Int? = nil,
        clearsPromptMetrics: Bool = false
    ) {
        self.promptTokenCount = promptTokenCount
        self.cachedPromptTokenCount = cachedPromptTokenCount
        self.promptTokensPerSecond = promptTokensPerSecond
        self.completionTokenCount = completionTokenCount
        self.completionTokensPerSecond = completionTokensPerSecond
        self.responseDurationSeconds = responseDurationSeconds
        self.contextTokenCount = contextTokenCount
        self.clearsPromptMetrics = clearsPromptMetrics
    }

    public var totalTokenCount: Int? {
        if let contextTokenCount {
            return contextTokenCount
        }

        switch (promptTokenCount, completionTokenCount) {
        case let (prompt?, completion?):
            return prompt + (cachedPromptTokenCount ?? 0) + completion
        case let (prompt?, nil):
            return prompt + (cachedPromptTokenCount ?? 0)
        case let (nil, completion?):
            return (cachedPromptTokenCount ?? 0) + completion
        default:
            return cachedPromptTokenCount
        }
    }
}

public struct DirectAgentContextWindowStatus: Sendable {
    public let usedTokens: Int?
    public let maxTokens: Int?
    public let modelID: String
    public let isApproximate: Bool

    public init(
        usedTokens: Int?,
        maxTokens: Int?,
        modelID: String,
        isApproximate: Bool
    ) {
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
        self.modelID = modelID
        self.isApproximate = isApproximate
    }
}

public struct DirectAgentSubscriptionUsageStatus: Sendable, Equatable {
    public let provider: String
    public let dailyUsedPercent: Double?
    public let weeklyUsedPercent: Double?
    public let dailyResetsInSeconds: Int?
    public let weeklyResetsInSeconds: Int?

    public init(
        provider: String,
        dailyUsedPercent: Double?,
        weeklyUsedPercent: Double?,
        dailyResetsInSeconds: Int? = nil,
        weeklyResetsInSeconds: Int? = nil
    ) {
        self.provider = provider
        self.dailyUsedPercent = dailyUsedPercent.map { min(max($0, 0), 100) }
        self.weeklyUsedPercent = weeklyUsedPercent.map { min(max($0, 0), 100) }
        self.dailyResetsInSeconds = dailyResetsInSeconds
        self.weeklyResetsInSeconds = weeklyResetsInSeconds
    }

    public var hasValues: Bool {
        dailyUsedPercent != nil || weeklyUsedPercent != nil
    }
}

public struct DirectAgentLoadedModelDetails: Sendable, Equatable {
    public let modelID: String
    public let runtime: String?
    public let generation: String?
    public let penalties: String?
    public let kvCache: String?

    public init(
        modelID: String,
        runtime: String? = nil,
        generation: String? = nil,
        penalties: String? = nil,
        kvCache: String? = nil
    ) {
        self.modelID = modelID
        self.runtime = runtime?.nilIfBlank
        self.generation = generation?.nilIfBlank
        self.penalties = penalties?.nilIfBlank
        self.kvCache = kvCache?.nilIfBlank
    }
}

public struct DirectAgentTurnOutcome: Sendable, Equatable {
    public enum Status: String, Sendable, Equatable {
        case completed
        case cancelled
        case failed
    }

    public let status: Status
    public let message: String?

    public init(status: Status, message: String? = nil) {
        self.status = status
        self.message = message?.nilIfBlank
    }

    public static let completed = DirectAgentTurnOutcome(status: .completed)
    public static let cancelled = DirectAgentTurnOutcome(status: .cancelled)

    public static func failed(message: String?) -> DirectAgentTurnOutcome {
        DirectAgentTurnOutcome(status: .failed, message: message)
    }
}

public enum DirectAgentEvent: Sendable {
    case status(String)
    case diagnostic(String)
    case thought(String)
    case modelLoaded(String)
    case modelLoadedDetails(DirectAgentLoadedModelDetails)
    case modelRuntime(String)
    case metrics(DirectAgentGenerationMetrics)
    case contextWindow(DirectAgentContextWindowStatus)
    case subscriptionUsage(DirectAgentSubscriptionUsageStatus)
    case content(String)
    case toolCallStarted(DirectAgentToolCall)
    case toolCallCompleted(DirectAgentToolCall, DirectAgentToolResult)
    case sessionSnapshot(AgentRuntimeSessionSnapshot)
    case turnEnded(DirectAgentTurnOutcome)
}

public struct AgentKVCachePersistencePolicy {
    public static func terminalDiskCacheKey(workingDirectoryPath: String) -> String {
        "terminal:\(workingDirectoryPath)"
    }
}
