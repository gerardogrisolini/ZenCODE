//
//  ServerGemma4Configuration.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

// MARK: - Shared KV state

/// Local copy of the vendored (package-scoped) `Gemma4SharedKVState`. KV-shared
/// layers reuse the keys/values computed by an earlier layer of the same
/// attention type.
enum ServerGemma4SharedKVState {
    case regular(keys: MLXArray, values: MLXArray)
    case quantized(
        keys: (MLXArray, MLXArray, MLXArray?),
        values: (MLXArray, MLXArray, MLXArray?),
        groupSize: Int,
        bits: Int,
        mode: QuantizationMode
    )

    var sequenceLength: Int {
        switch self {
        case .regular(let keys, _):
            keys.dim(2)
        case .quantized(let keys, _, _, _, _):
            keys.0.dim(-2)
        }
    }
}

// MARK: - Config helpers

private func serverGemma4BuildLayerTypes(
    hiddenLayers: Int, slidingWindowPattern: Int
) -> [String] {
    let pattern =
        Array(repeating: "sliding_attention", count: max(slidingWindowPattern - 1, 0))
        + ["full_attention"]
    guard !pattern.isEmpty else {
        return Array(repeating: "full_attention", count: hiddenLayers)
    }
    var result: [String] = []
    result.reserveCapacity(hiddenLayers)
    while result.count < hiddenLayers {
        result.append(contentsOf: pattern)
    }
    return Array(result.prefix(hiddenLayers))
}

private func serverGemma4DefaultTextRopeParameters() -> [String: [String: StringOrNumber]] {
    [
        "full_attention": [
            "partial_rotary_factor": .float(1.0),
            "rope_theta": .float(1_000_000.0),
            "rope_type": .string("proportional"),
        ],
        "sliding_attention": [
            "partial_rotary_factor": .float(1.0),
            "rope_theta": .float(10_000.0),
            "rope_type": .string("default"),
        ],
    ]
}

func serverGemma4AdjustAttentionMask(
    _ mask: MLXFast.ScaledDotProductAttentionMaskMode,
    keyLength: Int
) -> MLXFast.ScaledDotProductAttentionMaskMode {
    switch mask {
    case .array(let maskArray):
        let maskLength = maskArray.dim(-1)
        guard maskLength > keyLength else {
            return mask
        }
        let start = maskLength - keyLength
        return .array(maskArray[.ellipsis, start...])
    case .arrays, .causal, .none:
        return mask
    }
}

// MARK: - Configuration

struct ServerGemma4TextConfiguration: Codable, Sendable {
    let modelType: String
    let hiddenSize: Int
    let hiddenLayers: Int
    let intermediateSize: Int
    let attentionHeads: Int
    let kvHeads: Int
    let globalKVHeads: Int?
    let headDim: Int
    let globalHeadDim: Int
    let vocabularySize: Int
    let vocabularySizePerLayerInput: Int
    let numKVSharedLayers: Int
    let hiddenSizePerLayerInput: Int
    let slidingWindow: Int
    let slidingWindowPattern: Int
    let maxPositionEmbeddings: Int
    let rmsNormEps: Float
    let ropeTraditional: Bool
    let finalLogitSoftcapping: Float?
    let useDoubleWideMLP: Bool
    let enableMoEBlock: Bool
    let numExperts: Int?
    let topKExperts: Int?
    let moeIntermediateSize: Int?
    let attentionKEqV: Bool
    let layerTypes: [String]
    let ropeParameters: [String: [String: StringOrNumber]]
    let tieWordEmbeddings: Bool

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case hiddenSize = "hidden_size"
        case hiddenLayers = "num_hidden_layers"
        case intermediateSize = "intermediate_size"
        case attentionHeads = "num_attention_heads"
        case kvHeads = "num_key_value_heads"
        case globalKVHeads = "num_global_key_value_heads"
        case headDim = "head_dim"
        case globalHeadDim = "global_head_dim"
        case vocabularySize = "vocab_size"
        case vocabularySizePerLayerInput = "vocab_size_per_layer_input"
        case numKVSharedLayers = "num_kv_shared_layers"
        case hiddenSizePerLayerInput = "hidden_size_per_layer_input"
        case slidingWindow = "sliding_window"
        case slidingWindowPattern = "sliding_window_pattern"
        case maxPositionEmbeddings = "max_position_embeddings"
        case rmsNormEps = "rms_norm_eps"
        case ropeTraditional = "rope_traditional"
        case finalLogitSoftcapping = "final_logit_softcapping"
        case useDoubleWideMLP = "use_double_wide_mlp"
        case enableMoEBlock = "enable_moe_block"
        case numExperts = "num_experts"
        case topKExperts = "top_k_experts"
        case moeIntermediateSize = "moe_intermediate_size"
        case attentionKEqV = "attention_k_eq_v"
        case layerTypes = "layer_types"
        case ropeParameters = "rope_parameters"
        case tieWordEmbeddings = "tie_word_embeddings"
    }

    init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelType =
            try c.decodeIfPresent(String.self, forKey: .modelType) ?? "gemma4_text"
        hiddenSize = try c.decodeIfPresent(Int.self, forKey: .hiddenSize) ?? 1536
        hiddenLayers = try c.decodeIfPresent(Int.self, forKey: .hiddenLayers) ?? 35
        intermediateSize =
            try c.decodeIfPresent(Int.self, forKey: .intermediateSize) ?? 6144
        attentionHeads = try c.decodeIfPresent(Int.self, forKey: .attentionHeads) ?? 8
        kvHeads = try c.decodeIfPresent(Int.self, forKey: .kvHeads) ?? 1
        globalKVHeads = try c.decodeIfPresent(Int.self, forKey: .globalKVHeads)
        headDim = try c.decodeIfPresent(Int.self, forKey: .headDim) ?? 256
        globalHeadDim = try c.decodeIfPresent(Int.self, forKey: .globalHeadDim) ?? 512
        vocabularySize =
            try c.decodeIfPresent(Int.self, forKey: .vocabularySize) ?? 262_144
        vocabularySizePerLayerInput =
            try c.decodeIfPresent(Int.self, forKey: .vocabularySizePerLayerInput)
            ?? vocabularySize
        numKVSharedLayers =
            try c.decodeIfPresent(Int.self, forKey: .numKVSharedLayers) ?? 20
        hiddenSizePerLayerInput =
            try c.decodeIfPresent(Int.self, forKey: .hiddenSizePerLayerInput) ?? 256
        slidingWindow = try c.decodeIfPresent(Int.self, forKey: .slidingWindow) ?? 512
        slidingWindowPattern =
            try c.decodeIfPresent(Int.self, forKey: .slidingWindowPattern) ?? 5
        maxPositionEmbeddings =
            try c.decodeIfPresent(Int.self, forKey: .maxPositionEmbeddings) ?? 131_072
        rmsNormEps = try c.decodeIfPresent(Float.self, forKey: .rmsNormEps) ?? 1e-6
        ropeTraditional =
            try c.decodeIfPresent(Bool.self, forKey: .ropeTraditional) ?? false
        finalLogitSoftcapping =
            try c.decodeIfPresent(Float.self, forKey: .finalLogitSoftcapping) ?? 30.0
        useDoubleWideMLP =
            try c.decodeIfPresent(Bool.self, forKey: .useDoubleWideMLP) ?? true
        enableMoEBlock =
            try c.decodeIfPresent(Bool.self, forKey: .enableMoEBlock) ?? false
        numExperts = try c.decodeIfPresent(Int.self, forKey: .numExperts)
        topKExperts = try c.decodeIfPresent(Int.self, forKey: .topKExperts)
        moeIntermediateSize = try c.decodeIfPresent(Int.self, forKey: .moeIntermediateSize)
        attentionKEqV = try c.decodeIfPresent(Bool.self, forKey: .attentionKEqV) ?? false
        ropeParameters =
            try c.decodeIfPresent(
                [String: [String: StringOrNumber]].self, forKey: .ropeParameters)
            ?? serverGemma4DefaultTextRopeParameters()
        layerTypes =
            try c.decodeIfPresent([String].self, forKey: .layerTypes)
            ?? serverGemma4BuildLayerTypes(
                hiddenLayers: hiddenLayers, slidingWindowPattern: slidingWindowPattern)
        tieWordEmbeddings =
            try c.decodeIfPresent(Bool.self, forKey: .tieWordEmbeddings) ?? true
    }
}

/// Configuration for the `"gemma4"` model_type. Handles the nested
/// `text_config` structure from multimodal HuggingFace configs, falling back to
/// a flat text-only config when `text_config` is absent.
struct ServerGemma4Configuration: Codable, Sendable {
    let textConfiguration: ServerGemma4TextConfiguration

    enum CodingKeys: String, CodingKey {
        case textConfiguration = "text_config"
    }

    init(from decoder: any Swift.Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let textConfiguration = try c.decodeIfPresent(
            ServerGemma4TextConfiguration.self, forKey: .textConfiguration)
        {
            self.textConfiguration = textConfiguration
        } else {
            self.textConfiguration = try ServerGemma4TextConfiguration(from: decoder)
        }
    }
}

