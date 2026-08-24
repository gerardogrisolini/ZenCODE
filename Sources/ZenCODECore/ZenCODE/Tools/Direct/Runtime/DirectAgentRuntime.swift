//
//  DirectAgentRuntime.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

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

/// Tool arguments are JSON-compatible. They are stored as `[String: JSONValue]`
/// (a genuinely `Sendable` representation) and materialized as `[String: Any]`
/// through `argumentsObject` for compatibility with the public tool runtime API.
/// The previous `[String: Any]` storage required `@unchecked Sendable` and could
/// not prove the absence of shared mutable references; storing `JSONValue` makes
/// the conformance sound without changing the public surface.
public enum DirectAgentToolCallError: LocalizedError, Sendable {
    case mismatchedArguments
    case invalidArgumentsJSON

    public var errorDescription: String? {
        switch self {
        case .mismatchedArguments:
            return "argumentsObject and argumentsJSON describe different tool arguments."
        case .invalidArgumentsJSON:
            return "argumentsJSON must encode a JSON object."
        }
    }
}

public struct DirectAgentToolCall: Sendable {
    public let id: String
    public let name: String
    private let arguments: [String: JSONValue]
    public let argumentsJSON: String
    /// Runtime-only descriptor metadata. Session/history persistence continues
    /// to store only id, name, and arguments.
    public let descriptorTitle: String?
    public let presentation: ToolPresentationDefinition?

    public init(
        id: String,
        name: String,
        argumentsObject: [String: Any],
        argumentsJSON: String,
        descriptorTitle: String? = nil,
        presentation: ToolPresentationDefinition? = nil
    ) {
        self.id = id
        self.name = name
        self.arguments = argumentsObject.mapValues { JSONValue(jsonObject: $0) }
        // The legacy non-throwing initializer remains source compatible, but
        // execution now always receives the exact representation inspected by
        // authorization gates.  Do not retain an untrusted parallel JSON blob.
        self.argumentsJSON = Self.canonicalArgumentsJSON(for: self.arguments)
        self.descriptorTitle = descriptorTitle
        self.presentation = presentation
    }

    /// Strict initializer for ingress points that require the supplied JSON to
    /// be rejected rather than canonicalized. It verifies semantic equality,
    /// not byte equality, so harmless JSON whitespace/key ordering differs are
    /// accepted.
    public init(
        validating id: String,
        name: String,
        argumentsObject: [String: Any],
        argumentsJSON: String,
        descriptorTitle: String? = nil,
        presentation: ToolPresentationDefinition? = nil
    ) throws {
        let arguments = argumentsObject.mapValues { JSONValue(jsonObject: $0) }
        guard let data = argumentsJSON.data(using: .utf8),
              let supplied = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw DirectAgentToolCallError.invalidArgumentsJSON
        }
        guard supplied == arguments else {
            throw DirectAgentToolCallError.mismatchedArguments
        }
        self.id = id
        self.name = name
        self.arguments = arguments
        self.argumentsJSON = Self.canonicalArgumentsJSON(for: arguments)
        self.descriptorTitle = descriptorTitle
        self.presentation = presentation
    }

    /// The tool arguments as a JSON-compatible `[String: Any]` dictionary,
    /// materialized on demand from the stored `JSONValue` payload.
    public var argumentsObject: [String: Any] {
        arguments.mapValues { $0.jsonObject }
    }

    private static func canonicalArgumentsJSON(for arguments: [String: JSONValue]) -> String {
        JSONValue.object(arguments).compactString(sortedKeys: true)
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
    public let modelOutput: String
    public let status: Status
    public let attachments: [AgentRuntimeAttachment]

    public init(
        output: String,
        summary: String,
        modelOutput: String? = nil,
        status: Status = .completed,
        attachments: [AgentRuntimeAttachment] = []
    ) {
        self.output = output
        self.summary = summary
        self.modelOutput = modelOutput ?? output
        self.status = status
        self.attachments = attachments
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
    /// Prompt tokens evaluated during prefill. Excludes tokens known to have
    /// been reused from the prompt cache.
    public let promptTokenCount: Int?
    /// Prompt tokens reused from cache. `nil` when the backend does not report
    /// cache usage; an explicit cache miss is represented by zero.
    public let cachedPromptTokenCount: Int?
    public let promptTokensPerSecond: Double?
    /// Tokens generated by the latest model round.
    public let completionTokenCount: Int?
    public let completionTokensPerSecond: Double?
    public let responseDurationSeconds: Double?
    public let contextTokenCount: Int?
    public let clearsPromptMetrics: Bool
    /// When true, this event is a complete metrics snapshot and must not
    /// inherit unavailable values from an earlier model round.
    public let replacesPreviousMetrics: Bool

    public init(
        promptTokenCount: Int?,
        cachedPromptTokenCount: Int? = nil,
        promptTokensPerSecond: Double?,
        completionTokenCount: Int?,
        completionTokensPerSecond: Double?,
        responseDurationSeconds: Double? = nil,
        contextTokenCount: Int? = nil,
        clearsPromptMetrics: Bool = false,
        replacesPreviousMetrics: Bool = false
    ) {
        self.promptTokenCount = promptTokenCount
        self.cachedPromptTokenCount = cachedPromptTokenCount
        self.promptTokensPerSecond = promptTokensPerSecond
        self.completionTokenCount = completionTokenCount
        self.completionTokensPerSecond = completionTokensPerSecond
        self.responseDurationSeconds = responseDurationSeconds
        self.contextTokenCount = contextTokenCount
        self.clearsPromptMetrics = clearsPromptMetrics
        self.replacesPreviousMetrics = replacesPreviousMetrics
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
    case metrics(DirectAgentGenerationMetrics)
    case contextWindow(DirectAgentContextWindowStatus)
    case subscriptionUsage(DirectAgentSubscriptionUsageStatus)
    case content(String)
    case toolCallStarted(DirectAgentToolCall)
    case toolCallCompleted(DirectAgentToolCall, DirectAgentToolResult)
    case sessionSnapshot(AgentRuntimeSessionSnapshot)
    case turnEnded(DirectAgentTurnOutcome)
}

/// A delegated agent's tool lifecycle event. Rendering surfaces receive the
/// original call and result instead of a lossy name/target projection, allowing
/// them to reuse the coordinator's canonical tool rows in their own layout.
public struct DirectSubAgentToolEvent: Sendable {
    public enum Lifecycle: Sendable {
        case started
        case completed(DirectAgentToolResult)
    }

    public let agentID: String
    public let agentName: String
    public let toolCall: DirectAgentToolCall
    public let lifecycle: Lifecycle

    public init(
        agentID: String,
        agentName: String,
        toolCall: DirectAgentToolCall,
        lifecycle: Lifecycle
    ) {
        self.agentID = agentID
        self.agentName = agentName
        self.toolCall = toolCall
        self.lifecycle = lifecycle
    }
}

public typealias DirectSubAgentToolEventHandler = @Sendable (DirectSubAgentToolEvent) async -> Void
