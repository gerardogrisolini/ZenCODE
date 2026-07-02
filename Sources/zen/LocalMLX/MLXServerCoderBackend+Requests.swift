#if ZENCODE_LOCAL_MLX
//
//  MLXServerCoderBackend+Requests.swift
//  ZenCODE
//

import Foundation
import ZenCODECore
@preconcurrency import MLXLMCommon
import MLXServerCore

extension MLXServerCoderBackend {
    func generationRequest(
        for session: SessionState,
        sessionID: String,
        tools: [ToolSpec]?
    ) -> MLXServerGenerationRequest {
        let thinkingSelection = resolvedThinkingSelection(for: session)
        var additionalContext = model.thinking.additionalContext(for: thinkingSelection)
        additionalContext["preserve_thinking"] = session.preserveThinking
            && model.thinking.supportsPreserveThinking
            && thinkingSelection.isEnabled

        return MLXServerGenerationRequest(
            model: model,
            messages: session.messages,
            parameters: generationParameters(),
            tools: tools,
            additionalContext: additionalContext,
                                    retainsReasoningInHistory: session.preserveThinking && thinkingSelection.isEnabled,
            // Prefer an explicit client-provided cache key. When absent, leave
            // the session key nil so the runtime derives a stable key from the
            // conversation opening (system prompt + first user message). This
            // lets stateless ACP clients that resend their transcript reuse the
            // KV cache across reconnections, even without a session_id. The TUI
            // always supplies a cache key, so it is unaffected.
            sessionID: session.cacheKey?.nilIfBlank
        )
    }

    func generationParameters() -> GenerateParameters {
        let overrides = configuration.generationParameterOverrides.normalized()
        var parameters = model.generationDefaults.generateParameters(
            maxTokens: configuration.maxOutputTokens ?? overrides.maxTokens,
            kvCacheSettings: kvCacheSettings
        )

        if let minP = overrides.minP {
            parameters.minP = Float(minP)
        }
        if let repetitionPenalty = overrides.repetitionPenalty {
            parameters.repetitionPenalty = Float(repetitionPenalty)
        }
        if let repetitionContextSize = overrides.repetitionContextSize {
            parameters.repetitionContextSize = repetitionContextSize
        }
        if let presenceContextSize = overrides.presenceContextSize {
            parameters.presenceContextSize = presenceContextSize
        }
        if let frequencyContextSize = overrides.frequencyContextSize {
            parameters.frequencyContextSize = frequencyContextSize
        }
        if let prefillStepSize = overrides.prefillStepSize {
            parameters.prefillStepSize = prefillStepSize
        }
        if let kvBits = overrides.kvBits {
            parameters.kvBits = kvBits
        }
        if let kvGroupSize = overrides.kvGroupSize {
            parameters.kvGroupSize = kvGroupSize
        }
        if let quantizedKVStart = overrides.quantizedKVStart {
            parameters.quantizedKVStart = quantizedKVStart
        }
        return parameters
    }

    func resolvedThinkingSelection(
        for session: SessionState
    ) -> MLXServerThinkingSelection {
        guard let thinkingSelection = session.thinkingSelection else {
            return model.thinking.defaultEnabledSelection()
        }
        return model.thinking.selection(for: thinkingSelection.rawValue)
    }

    func toolSpecs(
        allowedToolNames: Set<String>?,
        preferredWorkspaceRootURL: URL
    ) async -> [ToolSpec]? {
        let descriptors = await toolExecutor.descriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
        guard !descriptors.isEmpty else {
            return nil
        }

        return descriptors.compactMap { descriptor in
            guard let parameters = Self.sendableJSONObject(from: descriptor.inputSchema) else {
                return nil
            }
            return [
                "type": "function",
                "function": [
                    "name": descriptor.name,
                    "description": descriptor.description,
                    "parameters": parameters
                ] as [String: any Sendable]
            ] as ToolSpec
        }
    }
}
#endif
