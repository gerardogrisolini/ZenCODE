//
//  MLXConversationMetrics.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
import Foundation

public nonisolated struct ContextWindowStatus: Equatable, Hashable, Sendable {
    public var usedTokens: Int?
    public var maxTokens: Int?
    public var modelID: String?
    public var taskID: UUID?
    public var isApproximate: Bool

    public init(
        usedTokens: Int? = nil,
        maxTokens: Int? = nil,
        modelID: String? = nil,
        taskID: UUID? = nil,
        isApproximate: Bool = true
    ) {
        self.usedTokens = usedTokens
        self.maxTokens = maxTokens
        self.modelID = modelID
        self.taskID = taskID
        self.isApproximate = isApproximate
    }

    public static let empty = ContextWindowStatus()

    public var usageFraction: Double? {
        guard let usedTokens, let maxTokens, maxTokens > 0 else { return nil }
        return min(max(Double(usedTokens) / Double(maxTokens), 0), 1)
    }

    public var remainingTokens: Int? {
        guard let usedTokens, let maxTokens else { return nil }
        return max(maxTokens - usedTokens, 0)
    }

    public var hasVisibleData: Bool {
        usedTokens != nil || maxTokens != nil
    }

    public func tokenSummaryText(formatTokenCount: (Int) -> String) -> String {
        switch (usedTokens, maxTokens) {
        case let (usedTokens?, maxTokens?) where maxTokens > 0:
            return "\(formatTokenCount(usedTokens)) / \(formatTokenCount(maxTokens))"
        case let (usedTokens?, _):
            return "\(formatTokenCount(usedTokens)) / --"
        case let (_, maxTokens?) where maxTokens > 0:
            return "-- / \(formatTokenCount(maxTokens))"
        default:
            return "-- / --"
        }
    }
}

public nonisolated enum GenerationPhase: Equatable, Hashable, Sendable {
    case idle
    case prefill
    case generating
}

public nonisolated struct GenerationPerformanceSnapshot: Equatable, Hashable, Sendable {
    public var phase: GenerationPhase
    public var promptTokenCount: Int?
    public var cachedPromptTokenCount: Int?
    public var promptTokensPerSecond: Double?
    public var generationTokenCount: Int?
    public var reasoningTokenCount: Int?
    public var generationTokensPerSecond: Double?
    public var responseDurationSeconds: Double?

    public init(
        phase: GenerationPhase,
        promptTokenCount: Int? = nil,
        cachedPromptTokenCount: Int? = nil,
        promptTokensPerSecond: Double? = nil,
        generationTokenCount: Int? = nil,
        reasoningTokenCount: Int? = nil,
        generationTokensPerSecond: Double? = nil,
        responseDurationSeconds: Double? = nil
    ) {
        self.phase = phase
        self.promptTokenCount = promptTokenCount
        self.cachedPromptTokenCount = cachedPromptTokenCount
        self.promptTokensPerSecond = promptTokensPerSecond
        self.generationTokenCount = generationTokenCount
        self.reasoningTokenCount = reasoningTokenCount
        self.generationTokensPerSecond = generationTokensPerSecond
        self.responseDurationSeconds = responseDurationSeconds
    }
}

public nonisolated struct GenerationPerformance: Equatable, Hashable, Sendable {
    public var phase: GenerationPhase
    public var promptTokenCount: Int?
    public var cachedPromptTokenCount: Int?
    public var promptTokensPerSecond: Double?
    public var generationTokenCount: Int?
    public var reasoningTokenCount: Int?
    public var generationTokensPerSecond: Double?
    public var responseDurationSeconds: Double?

    public init(
        phase: GenerationPhase = .idle,
        promptTokenCount: Int? = nil,
        cachedPromptTokenCount: Int? = nil,
        promptTokensPerSecond: Double? = nil,
        generationTokenCount: Int? = nil,
        reasoningTokenCount: Int? = nil,
        generationTokensPerSecond: Double? = nil,
        responseDurationSeconds: Double? = nil
    ) {
        self.phase = phase
        self.promptTokenCount = promptTokenCount
        self.cachedPromptTokenCount = cachedPromptTokenCount
        self.promptTokensPerSecond = promptTokensPerSecond
        self.generationTokenCount = generationTokenCount
        self.reasoningTokenCount = reasoningTokenCount
        self.generationTokensPerSecond = generationTokensPerSecond
        self.responseDurationSeconds = responseDurationSeconds
    }

    public mutating func beginPrefill(promptTokenCount: Int?) {
        phase = .prefill
        self.promptTokenCount = promptTokenCount
        cachedPromptTokenCount = nil
        generationTokenCount = nil
        reasoningTokenCount = nil
        responseDurationSeconds = nil
    }

    public mutating func beginGenerating() {
        phase = .generating
    }

    public mutating func finishGeneration(
        promptTokenCount: Int?,
        cachedPromptTokenCount: Int? = nil,
        promptTokensPerSecond: Double?,
        generationTokenCount: Int?,
        reasoningTokenCount: Int? = nil,
        generationTokensPerSecond: Double?,
        responseDurationSeconds: Double? = nil
    ) {
        phase = .idle
        self.promptTokenCount = promptTokenCount
        self.cachedPromptTokenCount = cachedPromptTokenCount
        self.generationTokenCount = generationTokenCount
        self.reasoningTokenCount = reasoningTokenCount
        if let promptTokensPerSecond {
            self.promptTokensPerSecond = promptTokensPerSecond
        }
        if let generationTokensPerSecond {
            self.generationTokensPerSecond = generationTokensPerSecond
        }
        if let responseDurationSeconds {
            self.responseDurationSeconds = responseDurationSeconds
        }
    }

    public mutating func apply(snapshot: GenerationPerformanceSnapshot) {
        phase = snapshot.phase
        promptTokenCount = snapshot.promptTokenCount
        cachedPromptTokenCount = snapshot.cachedPromptTokenCount
        generationTokenCount = snapshot.generationTokenCount
        reasoningTokenCount = snapshot.reasoningTokenCount

        if let promptTokensPerSecond = snapshot.promptTokensPerSecond {
            self.promptTokensPerSecond = promptTokensPerSecond
        }

        if let generationTokensPerSecond = snapshot.generationTokensPerSecond {
            self.generationTokensPerSecond = generationTokensPerSecond
        }

        if let responseDurationSeconds = snapshot.responseDurationSeconds {
            self.responseDurationSeconds = responseDurationSeconds
        }
    }

    public mutating func resetPreservingThroughput() {
        phase = .idle
        promptTokenCount = nil
        cachedPromptTokenCount = nil
        generationTokenCount = nil
        reasoningTokenCount = nil
        responseDurationSeconds = nil
    }

    public static let empty = GenerationPerformance()
}
