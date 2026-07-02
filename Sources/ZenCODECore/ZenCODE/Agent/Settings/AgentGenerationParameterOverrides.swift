//
//  AgentSettingsManifest.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
#if canImport(os)
import os
#endif

public struct AgentGenerationParameterOverrides: Codable, Equatable, Hashable, Sendable {
    public var maxTokens: Int?
    public var maxKVSize: Int?
    public var temperature: Double?
    public var topP: Double?
    public var topK: Int?
    public var minP: Double?
    public var repetitionPenalty: Double?
    public var repetitionContextSize: Int?
    public var presencePenalty: Double?
    public var presenceContextSize: Int?
    public var frequencyPenalty: Double?
    public var frequencyContextSize: Int?
    public var prefillStepSize: Int?
    public var kvBits: Int?
    public var kvGroupSize: Int?
    public var quantizedKVStart: Int?

    public init(
        maxTokens: Int? = nil,
        maxKVSize: Int? = nil,
        temperature: Double? = nil,
        topP: Double? = nil,
        topK: Int? = nil,
        minP: Double? = nil,
        repetitionPenalty: Double? = nil,
        repetitionContextSize: Int? = nil,
        presencePenalty: Double? = nil,
        presenceContextSize: Int? = nil,
        frequencyPenalty: Double? = nil,
        frequencyContextSize: Int? = nil,
        prefillStepSize: Int? = nil,
        kvBits: Int? = nil,
        kvGroupSize: Int? = nil,
        quantizedKVStart: Int? = nil
    ) {
        self.maxTokens = maxTokens
        self.maxKVSize = maxKVSize
        self.temperature = temperature
        self.topP = topP
        self.topK = topK
        self.minP = minP
        self.repetitionPenalty = repetitionPenalty
        self.repetitionContextSize = repetitionContextSize
        self.presencePenalty = presencePenalty
        self.presenceContextSize = presenceContextSize
        self.frequencyPenalty = frequencyPenalty
        self.frequencyContextSize = frequencyContextSize
        self.prefillStepSize = prefillStepSize
        self.kvBits = kvBits
        self.kvGroupSize = kvGroupSize
        self.quantizedKVStart = quantizedKVStart
    }

    public var isEmpty: Bool {
        maxTokens == nil
            && maxKVSize == nil
            && temperature == nil
            && topP == nil
            && topK == nil
            && minP == nil
            && repetitionPenalty == nil
            && repetitionContextSize == nil
            && presencePenalty == nil
            && presenceContextSize == nil
            && frequencyPenalty == nil
            && frequencyContextSize == nil
            && prefillStepSize == nil
            && kvBits == nil
            && kvGroupSize == nil
            && quantizedKVStart == nil
    }

    public var nilIfEmpty: AgentGenerationParameterOverrides? {
        isEmpty ? nil : self
    }

    public func normalized() -> Self {
        Self(
            maxTokens: maxTokens.map { min(max($0, 1), 1_048_576) },
            maxKVSize: maxKVSize.map { min(max($0, 1), 1_048_576) },
            temperature: temperature.map { min(max($0, 0), 2) },
            topP: topP.map { min(max($0, 0.01), 1) },
            topK: topK.map { min(max($0, 0), 10_000) },
            minP: minP.map { min(max($0, 0), 1) },
            repetitionPenalty: repetitionPenalty.map { min(max($0, 0), 3) },
            repetitionContextSize: repetitionContextSize.map { min(max($0, 0), 8192) },
            presencePenalty: presencePenalty.map { min(max($0, -2), 2) },
            presenceContextSize: presenceContextSize.map { min(max($0, 0), 8192) },
            frequencyPenalty: frequencyPenalty.map { min(max($0, -2), 2) },
            frequencyContextSize: frequencyContextSize.map { min(max($0, 0), 8192) },
            prefillStepSize: prefillStepSize.map { min(max($0, 1), 8192) },
            kvBits: kvBits.map { min(max($0, 2), 8) },
            kvGroupSize: kvGroupSize.map { min(max($0, 1), 256) },
            quantizedKVStart: quantizedKVStart.map { min(max($0, 0), 262_144) }
        )
    }
}

