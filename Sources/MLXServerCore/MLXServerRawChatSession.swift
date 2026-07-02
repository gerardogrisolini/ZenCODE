//
//  MLXServerRawChatSession.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import CryptoKit
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import Tokenizers

/// `ModelContainer` and `[KVCache]` are external non-Sendable MLX types; the runtime actor serializes session access.
final class MLXServerRawChatSession: @unchecked Sendable {
    let container: ModelContainer
    var cache: [KVCache]?

    init(
        _ container: ModelContainer,
        cache: [KVCache]? = nil
    ) {
        self.container = container
        self.cache = cache
    }

    func streamDetails(
        request: MLXServerGenerationRequest,
        cachedPromptTokenCount: Int?,
        cachedPrefixMessageCount: Int
    ) async throws -> AsyncStream<Generation> {
        let plan = MLXServerRawChatSessionPlan(
            session: self,
            request: request,
            cachedPromptTokenCount: cachedPromptTokenCount,
            cachedPrefixMessageCount: cachedPrefixMessageCount
        )
        return try await container.perform(nonSendable: plan) { context, plan in
            let session = plan.session
            let tools = plan.request.tools
            let input = try await Self.input(
                for: plan,
                context: context
            )
            if session.cache == nil {
                session.cache = context.model.newCache(parameters: plan.request.parameters)
            }
            guard let cache = session.cache else {
                throw MLXServerRuntimeError.emptyPrompt
            }
            let tokenStream = try MLXLMCommon.generateTokens(
                input: input,
                cache: cache,
                parameters: plan.request.parameters,
                context: context
            )
            return Self.generationStream(
                from: tokenStream,
                tokenizer: context.tokenizer,
                toolCallFormat: context.configuration.toolCallFormat ?? .json,
                tools: tools
            )
        }
    }

    private static func input(
        for plan: MLXServerRawChatSessionPlan,
        context: ModelContext
    ) async throws -> LMInput {
        if plan.cachedPrefixMessageCount > 0 {
            return try await cachedContinuationInput(for: plan, context: context)
        }

        let rawMessages = plan.request.messages.map {
            $0.rawTemplateMessage(
                toolResultStyle: .style(for: plan.request.model)
            )
        }
        let renderedTokens = try context.tokenizer.applyChatTemplate(
            messages: rawMessages,
            tools: plan.request.tools,
            additionalContext: plan.request.additionalContext
        )
        guard !renderedTokens.isEmpty else {
            throw MLXServerRuntimeError.emptyPrompt
        }
        return LMInput(tokens: MLXArray(renderedTokens))
    }

    private static func cachedContinuationInput(
        for plan: MLXServerRawChatSessionPlan,
        context: ModelContext
    ) async throws -> LMInput {
        let suffixStartIndex = plan.cachedPrefixMessageCount
        guard suffixStartIndex < plan.request.messages.count else {
            throw MLXServerRuntimeError.emptyPrompt
        }
        guard plan.request.messages[suffixStartIndex].role == .tool else {
            let suffixMessages = suffixChatMessages(
                request: plan.request,
                cachedPrefixMessageCount: suffixStartIndex
            )
            guard !suffixMessages.isEmpty else {
                throw MLXServerRuntimeError.emptyPrompt
            }
            return try await context.processor.prepare(
                input: UserInput(
                    chat: suffixMessages,
                    processing: .init(resize: plan.request.mediaResize)
                )
            )
        }
        guard suffixStartIndex > 0,
              let tokenizer = context.tokenizer as? MLXServerChatTemplateTokenizing
        else {
            throw MLXServerRuntimeError.emptyPrompt
        }

        let templateSlice = cachedContinuationTemplateSlice(
            request: plan.request,
            cachedPrefixMessageCount: suffixStartIndex
        )
        let previousTokens = try tokenizer.applyChatTemplate(
            messages: templateSlice.cachedContextMessages,
            tools: nil,
            additionalContext: plan.request.additionalContext,
            addGenerationPrompt: false
        )
        let continuationTokens = try tokenizer.applyChatTemplate(
            messages: templateSlice.continuationContextMessages,
            tools: nil,
            additionalContext: plan.request.additionalContext,
            addGenerationPrompt: true
        )
        guard continuationTokens.count > previousTokens.count,
              continuationTokens.starts(with: previousTokens)
        else {
            throw MLXServerRuntimeError.emptyPrompt
        }

        let suffixTokens = Array(continuationTokens.dropFirst(previousTokens.count))
        guard !suffixTokens.isEmpty else {
            throw MLXServerRuntimeError.emptyPrompt
        }
        return LMInput(tokens: MLXArray(suffixTokens))
    }
}
