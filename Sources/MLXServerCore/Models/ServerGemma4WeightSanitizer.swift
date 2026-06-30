//
//  ServerGemma4WeightSanitizer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN

// MARK: - Weight sanitizer

enum ServerGemma4WeightSanitizer {
    /// Normalizes HuggingFace weight keys to the module hierarchy and splits the
    /// fused MoE `experts.gate_up_proj` into the `SwitchGLU` gate/up weights.
    ///
    /// - Parameter languageModelPrefixed: `true` for the `gemma4` wrapper, where
    ///   weights are nested under `language_model.model.…`; `false` for the
    ///   `gemma4_text` model, where they sit under `model.…`.
    static func sanitize(
        weights: [String: MLXArray],
        tieWordEmbeddings: Bool,
        languageModelPrefixed: Bool
    ) -> [String: MLXArray] {
        var sanitized: [String: MLXArray] = [:]
        sanitized.reserveCapacity(weights.count + 1)

        for (key, value) in weights {
            if key.contains("rotary_emb")
                || key.contains("input_max")
                || key.contains("input_min")
                || key.contains("output_max")
                || key.contains("output_min")
            {
                continue
            }

            // Skip vision/audio multimodal weights.
            let strippedForVisionCheck =
                key.hasPrefix("model.") ? String(key.dropFirst("model.".count)) : key
            if strippedForVisionCheck.hasPrefix("vision_tower")
                || strippedForVisionCheck.hasPrefix("multi_modal_projector")
                || strippedForVisionCheck.hasPrefix("audio_tower")
                || strippedForVisionCheck.hasPrefix("embed_audio")
                || strippedForVisionCheck.hasPrefix("embed_vision")
            {
                continue
            }

            var newKey = key

            if languageModelPrefixed {
                if newKey.hasPrefix("model.") {
                    newKey.removeFirst("model.".count)
                }
                if newKey.hasPrefix("language_model."),
                    !newKey.hasPrefix("language_model.model."),
                    !newKey.hasPrefix("language_model.lm_head.")
                {
                    let rest = String(newKey.dropFirst("language_model.".count))
                    newKey = "language_model.model.\(rest)"
                }
            }

            if newKey.hasSuffix(".experts.down_proj") {
                newKey = newKey.replacingOccurrences(
                    of: ".experts.down_proj",
                    with: ".experts.switch_glu.down_proj.weight"
                )
            }

            if newKey.hasSuffix(".experts.gate_up_proj") {
                let mid = value.dim(-2) / 2
                sanitized[
                    newKey.replacingOccurrences(
                        of: ".experts.gate_up_proj",
                        with: ".experts.switch_glu.gate_proj.weight"
                    )
                ] = value[.ellipsis, ..<mid, 0...]
                sanitized[
                    newKey.replacingOccurrences(
                        of: ".experts.gate_up_proj",
                        with: ".experts.switch_glu.up_proj.weight"
                    )
                ] = value[.ellipsis, mid..., 0...]
                continue
            }

            sanitized[newKey] = value
        }

        if languageModelPrefixed {
            if tieWordEmbeddings {
                sanitized = sanitized.filter { key, _ in
                    !key.hasPrefix("language_model.lm_head.")
                }
            } else if sanitized["language_model.lm_head.weight"] == nil,
                let embedWeight = sanitized["language_model.model.embed_tokens.weight"]
            {
                sanitized["language_model.lm_head.weight"] = embedWeight
            }
        } else {
            if tieWordEmbeddings {
                sanitized = sanitized.filter { key, _ in !key.hasPrefix("lm_head.") }
            } else if sanitized["lm_head.weight"] == nil,
                let embedWeight = sanitized["model.embed_tokens.weight"]
            {
                sanitized["lm_head.weight"] = embedWeight
            }
        }

        return sanitized
    }
}

// MARK: - LoRA conformance

extension ServerGemma4TextModel: LoRAModel {}
extension ServerGemma4Model: LoRAModel {}
