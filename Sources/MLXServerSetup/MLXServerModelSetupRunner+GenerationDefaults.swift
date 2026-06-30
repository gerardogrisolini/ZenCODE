//
//  MLXServerModelSetupRunner+GenerationDefaults.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//
import Foundation
import HuggingFace
import MLXServerCore

extension MLXServerModelSetupRunner {
    static func configureGenerationDefaults(
        _ defaults: MLXServerModelGenerationDefaults,
        modelContextLimit: Int?
    ) throws -> MLXServerModelGenerationDefaults {
        let contextPrompt = [
            "Context window",
            "(model limit: \(contextLimitSummary(modelContextLimit)); recommended: \(recommendedContextWindow))"
        ].joined(separator: " ")
        let contextWindow = try promptInt(
            contextPrompt,
            defaultValue: defaults.contextWindow ?? defaultContextWindow(modelContextLimit: modelContextLimit),
            allowedRange: contextWindowAllowedRange(modelContextLimit: modelContextLimit)
        )
        let maxOutputTokens = try promptInt(
            "max_output_tokens",
            defaultValue: defaults.maxOutputTokens ?? 32_768,
            allowedRange: 1...Int.max
        )
        let temperature = try promptFloat(
            "Temperature",
            defaultValue: defaults.temperature ?? 0.6,
            allowedRange: 0...Float.greatestFiniteMagnitude
        )
        let topP = try promptFloat(
            "top_p",
            defaultValue: defaults.topP ?? 1.0,
            allowedRange: 0...1
        )
        let topK = try promptInt(
            "top_k",
            defaultValue: defaults.topK ?? 0,
            allowedRange: 0...Int.max
        )
        let repetitionPenalty = try promptFloat(
            "repetition_penalty",
            defaultValue: defaults.repetitionPenalty ?? 1.0,
            allowedRange: 0...Float.greatestFiniteMagnitude
        )
        let presencePenalty = try promptFloat(
            "presence_penalty",
            defaultValue: defaults.presencePenalty ?? 0,
            allowedRange: -2...2
        )
        let frequencyPenalty = try promptFloat(
            "frequency_penalty",
            defaultValue: defaults.frequencyPenalty ?? 0,
            allowedRange: -2...2
        )
        let prefillStepSize = try promptInt(
            "prefill_step_size",
            defaultValue: defaults.prefillStepSize ?? MLXServerModelGenerationDefaults.defaultPrefillStepSize,
            allowedRange: 1...Int.max
        )

        return MLXServerModelGenerationDefaults(
            contextWindow: contextWindow,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            topP: topP,
            topK: topK,
            repetitionPenalty: repetitionPenalty,
            presencePenalty: presencePenalty,
            frequencyPenalty: frequencyPenalty,
            prefillStepSize: prefillStepSize
        )
    }

    static func setupDefaults(
        from importedDefaults: MLXServerModelGenerationDefaults,
        modelContextLimit: Int?
    ) -> MLXServerModelGenerationDefaults {
        MLXServerModelGenerationDefaults(
            contextWindow: defaultContextWindow(modelContextLimit: modelContextLimit),
            maxOutputTokens: importedDefaults.maxOutputTokens,
            temperature: importedDefaults.temperature,
            topP: importedDefaults.topP,
            topK: importedDefaults.topK,
            repetitionPenalty: importedDefaults.repetitionPenalty,
            presencePenalty: importedDefaults.presencePenalty,
            frequencyPenalty: importedDefaults.frequencyPenalty,
            prefillStepSize: importedDefaults.prefillStepSize
                ?? MLXServerModelGenerationDefaults.defaultPrefillStepSize
        ).validated()
    }

    static func defaultContextWindow(modelContextLimit: Int?) -> Int {
        guard let modelContextLimit else {
            return recommendedContextWindow
        }
        return min(recommendedContextWindow, max(1, modelContextLimit))
    }

    static func contextLimitSummary(_ modelContextLimit: Int?) -> String {
        modelContextLimit.map(String.init) ?? "not detected"
    }

    static func contextWindowAllowedRange(modelContextLimit: Int?) -> ClosedRange<Int> {
        let upperBound = modelContextLimit.map { max(1, $0) } ?? Int.max
        return 1...upperBound
    }

    static func generationDefaults(
        _ preferred: MLXServerModelGenerationDefaults,
        fallingBackTo fallback: MLXServerModelGenerationDefaults
    ) -> MLXServerModelGenerationDefaults {
        MLXServerModelGenerationDefaults(
            contextWindow: preferred.contextWindow ?? fallback.contextWindow,
            maxOutputTokens: preferred.maxOutputTokens ?? fallback.maxOutputTokens,
            temperature: preferred.temperature ?? fallback.temperature,
            topP: preferred.topP ?? fallback.topP,
            topK: preferred.topK ?? fallback.topK,
            repetitionPenalty: preferred.repetitionPenalty ?? fallback.repetitionPenalty,
            presencePenalty: preferred.presencePenalty ?? fallback.presencePenalty,
            frequencyPenalty: preferred.frequencyPenalty ?? fallback.frequencyPenalty,
            prefillStepSize: preferred.prefillStepSize ?? fallback.prefillStepSize
        ).validated()
    }

    static func generationDefaultsSummary(
        _ defaults: MLXServerModelGenerationDefaults
    ) -> String {
        let values = [
            defaults.contextWindow.map { "context=\($0)" },
            defaults.maxOutputTokens.map { "max_output_tokens=\($0)" },
            defaults.temperature.map { "temperature=\(formatFloat($0))" },
            defaults.topP.map { "top_p=\(formatFloat($0))" },
            defaults.topK.map { "top_k=\($0)" },
            defaults.repetitionPenalty.map { "repetition_penalty=\(formatFloat($0))" },
            defaults.presencePenalty.map { "presence_penalty=\(formatFloat($0))" },
            defaults.frequencyPenalty.map { "frequency_penalty=\(formatFloat($0))" },
            defaults.prefillStepSize.map { "prefill_step_size=\($0)" }
        ].compactMap { $0 }

        return values.isEmpty ? "default runtime" : values.joined(separator: ", ")
    }

    static func thinkingSummary(
        _ thinking: MLXServerModelThinkingConfiguration
    ) -> String {
        let normalized = thinking.validated()
        guard normalized.supportsThinking else {
            return "off"
        }

        var parts = ["default=\(normalized.defaultSelection.rawValue)"]
        if normalized.supportsReasoningEffort {
            let levels = MLXServerModelThinkingConfiguration
                .normalizedEffortLevels(from: normalized.availableSelections)
                .map(\.rawValue)
                .joined(separator: ", ")
            parts.append("levels=\(levels)")
        } else {
            parts.append("mode=on/off")
        }
        if normalized.supportsPreserveThinking {
            parts.append("preserve=true")
        }
        return parts.joined(separator: ", ")
    }

}
