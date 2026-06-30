//
//  MLXServerModelSetupRunner+ConfigProbes.swift
//  ZenCODE
//

import Foundation
import HuggingFace
import MLXServerCore

struct ModelRuntimeKindProbe: Decodable {
    var modelType: String?
    var architectures: [String]?
    var textConfig: Nested?

    enum CodingKeys: String, CodingKey {
        case modelType = "model_type"
        case architectures
        case textConfig = "text_config"
    }

    var preferredTextRuntimeKind: MLXServerModelRuntimeKind? {
        for modelType in normalizedModelTypes {
            if Self.llmTextRuntimeModelTypes.contains(modelType) {
                return .llm
            }
        }

        for modelType in normalizedModelTypes {
            if Self.vlmOnlyModelTypes.contains(modelType) {
                return .vlm
            }
        }

        let architectureText = (architectures ?? [])
            .joined(separator: " ")
            .lowercased()
        if architectureText.contains("vision")
            || architectureText.contains("vlm")
            || architectureText.contains("llava") {
            return .vlm
        }

        return nil
    }

    private var normalizedModelTypes: [String] {
        [modelType, textConfig?.modelType]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }

    private static let llmTextRuntimeModelTypes: Set<String> = [
        "qwen3_5",
        "qwen3_5_moe",
        "gemma3",
        "gemma3n",
        "gemma4"
    ]

    private static let vlmOnlyModelTypes: Set<String> = [
        "fastvlm",
        "glm_ocr",
        "idefics3",
        "lfm2-vl",
        "lfm2_vl",
        "llava_qwen2",
        "mistral3",
        "paligemma",
        "pixtral",
        "qwen2_5_vl",
        "qwen2_vl",
        "qwen3_vl",
        "smolvlm"
    ]

    struct Nested: Decodable {
        var modelType: String?

        enum CodingKeys: String, CodingKey {
            case modelType = "model_type"
        }
    }
}

struct GenerationConfigProbe: Decodable {
    var maxNewTokens: Int?
    var maxOutputTokens: Int?
    var temperature: Float?
    var topP: Float?
    var topK: Int?
    var repetitionPenalty: Float?
    var presencePenalty: Float?
    var frequencyPenalty: Float?

    enum CodingKeys: String, CodingKey {
        case maxNewTokens = "max_new_tokens"
        case maxOutputTokens = "max_output_tokens"
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case repetitionPenalty = "repetition_penalty"
        case presencePenalty = "presence_penalty"
        case frequencyPenalty = "frequency_penalty"
    }

    var maxOutputTokensValue: Int? {
        maxOutputTokens ?? maxNewTokens
    }
}

struct ModelConfigProbe: Decodable {
    var maxPositionEmbeddings: Int?
    var maxContextLength: Int?
    var contextLength: Int?
    var modelMaxLength: Int?
    var maxSequenceLength: Int?
    var maxSequenceLen: Int?
    var textConfig: Nested?

    enum CodingKeys: String, CodingKey {
        case maxPositionEmbeddings = "max_position_embeddings"
        case maxContextLength = "max_context_length"
        case contextLength = "context_length"
        case modelMaxLength = "model_max_length"
        case maxSequenceLength = "max_sequence_length"
        case maxSequenceLen = "max_sequence_len"
        case textConfig = "text_config"
    }

    var contextWindow: Int? {
        [
            maxContextLength,
            contextLength,
            modelMaxLength,
            maxSequenceLength,
            maxSequenceLen,
            maxPositionEmbeddings,
            textConfig?.contextWindow
        ]
        .compactMap { $0 }
        .max()
    }

    struct Nested: Decodable {
        var maxPositionEmbeddings: Int?
        var maxContextLength: Int?
        var contextLength: Int?
        var modelMaxLength: Int?

        enum CodingKeys: String, CodingKey {
            case maxPositionEmbeddings = "max_position_embeddings"
            case maxContextLength = "max_context_length"
            case contextLength = "context_length"
            case modelMaxLength = "model_max_length"
        }

        var contextWindow: Int? {
            [
                maxContextLength,
                contextLength,
                modelMaxLength,
                maxPositionEmbeddings
            ]
            .compactMap { $0 }
            .max()
        }
    }
}

