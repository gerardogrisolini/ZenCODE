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
    public let fileChanges: [OperationFileChange]

    public init(
        output: String,
        summary: String,
        modelOutput: String? = nil,
        status: Status = .completed,
        attachments: [AgentRuntimeAttachment] = [],
        fileChanges: [OperationFileChange] = []
    ) {
        self.output = output
        self.summary = summary
        self.modelOutput = modelOutput ?? output
        self.status = status
        self.attachments = attachments
        self.fileChanges = fileChanges
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

/// Prefill and generation speed reported by an in-process engine, live while a
/// round is running and with the exact engine values once it has ended.
///
/// Both speeds travel together: once the generation starts, the prefill speed
/// of the same round stays available next to the live generation speed.
public struct DirectAgentGenerationThroughput: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case prefill
        case generation
    }

    /// The phase the engine is in, or the last one the round reached.
    public let phase: Phase
    /// Tokens per second of the prompt evaluation; `nil` while it cannot be
    /// measured yet, or when the whole prompt came from the cache.
    public let prefillTokensPerSecond: Double?
    /// Tokens per second of the generation; `nil` until it can be measured.
    public let generationTokensPerSecond: Double?
    /// Live prefill progress, relative to the sync that is running: the prompt
    /// prefix reused from cache is excluded from both counts. `nil` outside
    /// the live prefill, including the final values of a round.
    public let processedTokens: Int?
    public let targetTokens: Int?

    public init(
        phase: Phase,
        prefillTokensPerSecond: Double? = nil,
        generationTokensPerSecond: Double? = nil,
        processedTokens: Int? = nil,
        targetTokens: Int? = nil
    ) {
        self.phase = phase
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.generationTokensPerSecond = generationTokensPerSecond
        self.processedTokens = processedTokens
        self.targetTokens = targetTokens
    }
}

public struct DirectAgentGenerationMetrics: Sendable {
    /// Prompt tokens evaluated during prefill. Excludes tokens known to have
    /// been reused from the prompt cache.
    public let promptTokenCount: Int?
    /// Prompt tokens reused from cache. `nil` when the backend does not report
    /// cache usage; an explicit cache miss is represented by zero.
    public let cachedPromptTokenCount: Int?
    /// Tokens generated by the latest model round.
    public let completionTokenCount: Int?
    public let responseDurationSeconds: Double?
    public let contextTokenCount: Int?
    public let clearsPromptMetrics: Bool
    /// When true, this event is a complete metrics snapshot and must not
    /// inherit unavailable values from an earlier model round.
    public let replacesPreviousMetrics: Bool
    /// Prefill and generation speed of the round in progress, or the exact
    /// values of the round that just ended. `nil` for providers that do not
    /// report it.
    public let throughput: DirectAgentGenerationThroughput?
    /// A throttled in-flight update carrying only `throughput`. It must not
    /// count as the first metrics event of a turn, and automation printing
    /// skips it.
    public let isLiveProgress: Bool

    public init(
        promptTokenCount: Int?,
        cachedPromptTokenCount: Int? = nil,
        completionTokenCount: Int?,
        responseDurationSeconds: Double? = nil,
        contextTokenCount: Int? = nil,
        clearsPromptMetrics: Bool = false,
        replacesPreviousMetrics: Bool = false,
        throughput: DirectAgentGenerationThroughput? = nil,
        isLiveProgress: Bool = false
    ) {
        self.promptTokenCount = promptTokenCount
        self.cachedPromptTokenCount = cachedPromptTokenCount
        self.completionTokenCount = completionTokenCount
        self.responseDurationSeconds = responseDurationSeconds
        self.contextTokenCount = contextTokenCount
        self.clearsPromptMetrics = clearsPromptMetrics
        self.replacesPreviousMetrics = replacesPreviousMetrics
        self.throughput = throughput
        self.isLiveProgress = isLiveProgress
    }

    /// Folds an incoming metrics event into the metrics observed so far during
    /// the same turn.
    ///
    /// This is the single definition of the merge semantics shared by every
    /// consumer (status bar and sub-agent overview), so both presentations
    /// agree on how partial provider updates accumulate:
    /// - a snapshot event (`replacesPreviousMetrics`) wins outright, and so
    ///   does the first event of a turn, when `current` is nil;
    /// - otherwise each unavailable field inherits the previous value, so a
    ///   completion-only update does not erase the prefill counters;
    /// - `clearsPromptMetrics` suppresses that inheritance for the prompt
    ///   fields only, letting a provider retract stale prefill values;
    /// - `throughput` follows the same inheritance, so a live update replaces
    ///   the speed while the counters of the previous round stay visible, and
    ///   a snapshot without it clears the speed.
    public static func merging(
        current: DirectAgentGenerationMetrics?,
        update: DirectAgentGenerationMetrics
    ) -> DirectAgentGenerationMetrics {
        guard let current, !update.replacesPreviousMetrics else {
            return update
        }
        return DirectAgentGenerationMetrics(
            promptTokenCount: update.clearsPromptMetrics
            ? update.promptTokenCount
            : update.promptTokenCount ?? current.promptTokenCount,
            cachedPromptTokenCount: update.clearsPromptMetrics
            ? update.cachedPromptTokenCount
            : update.cachedPromptTokenCount ?? current.cachedPromptTokenCount,
            completionTokenCount: update.completionTokenCount ?? current.completionTokenCount,
            responseDurationSeconds: update.responseDurationSeconds ?? current.responseDurationSeconds,
            contextTokenCount: update.contextTokenCount ?? current.contextTokenCount,
            clearsPromptMetrics: update.clearsPromptMetrics,
            replacesPreviousMetrics: update.replacesPreviousMetrics,
            throughput: update.throughput ?? current.throughput,
            isLiveProgress: update.isLiveProgress
        )
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
