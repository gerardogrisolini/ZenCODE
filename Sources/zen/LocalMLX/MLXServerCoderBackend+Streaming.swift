#if ZENCODE_LOCAL_MLX
//
//  MLXServerCoderBackend+Streaming.swift
//  ZenCODE
//

import Foundation
import ZenCODECore
@preconcurrency import MLXLMCommon
import MLXServerCore

extension MLXServerCoderBackend {
    func runGenerationTurn(
        request: MLXServerGenerationRequest,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> GenerationTurn {
        let stream = try await runtime.generateChatSession(request: request)
        var splitter = MLXServerCoderTranscriptSplitter(
            startsInThinking: request.startsInThinking
        )
        var toolCalls: [ToolCall] = []
        var completionInfo: GenerateCompletionInfo?

        for try await event in stream {
            switch event {
            case .chunk(let chunk):
                for part in splitter.consume(chunk) {
                    await emitTranscriptPart(part, onEvent: onEvent)
                }
            case .toolCall(let toolCall):
                toolCalls.append(toolCall)
            case .info(let info):
                completionInfo = info
            }
        }

        for part in splitter.finish() {
            await emitTranscriptPart(part, onEvent: onEvent)
        }

        return GenerationTurn(
            visibleText: splitter.visibleText,
            historyVisibleText: splitter.historyVisibleText,
            reasoningText: splitter.reasoningText,
            toolCalls: toolCalls,
            completionInfo: completionInfo
        )
    }

    func appendAssistantTurn(
        _ turn: GenerationTurn,
        directToolCalls: [DirectAgentToolCall],
        to session: inout SessionState
    ) {
        if !turn.reasoningText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           session.preserveThinking {
            session.messages.append(
                .assistant(
                    MLXServerReasoningTranscript.reasoningSummary(turn.reasoningText)
                )
            )
        }
        let historyReasoningText = session.preserveThinking ? turn.reasoningText : nil
        let hasHistoryReasoningText = historyReasoningText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty == false
        let structuredToolCalls = zip(turn.toolCalls, directToolCalls).map { toolCall, directToolCall in
            MLXServerChatToolCall(id: directToolCall.id, toolCall: toolCall)
        }
        if !turn.historyVisibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !structuredToolCalls.isEmpty {
            session.messages.append(
                .assistant(
                    turn.historyVisibleText,
                    reasoningContent: historyReasoningText,
                    toolCalls: structuredToolCalls
                )
            )
        }
        if turn.historyVisibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !hasHistoryReasoningText,
           turn.toolCalls.isEmpty {
            session.messages.append(.assistant(""))
        }
    }

    func emitMetrics(
        _ info: GenerateCompletionInfo,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        let cacheEvent = await runtime.consumeLastChatCacheEvent()
        if configuration.verboseLogging, let cacheEvent {
            await onEvent(.diagnostic(Self.cacheDiagnostic(from: cacheEvent)))
        }
        let cachedPromptTokenCount = cacheEvent?.cachedPromptTokenCount
        let contextTokenCount = (cachedPromptTokenCount ?? 0)
            + info.promptTokenCount
            + info.generationTokenCount
        await onEvent(
            .metrics(
                DirectAgentGenerationMetrics(
                    promptTokenCount: info.promptTokenCount,
                    cachedPromptTokenCount: cachedPromptTokenCount,
                    promptTokensPerSecond: info.promptTokensPerSecond,
                    completionTokenCount: info.generationTokenCount,
                    completionTokensPerSecond: info.tokensPerSecond,
                    responseDurationSeconds: info.promptTime + info.generateTime,
                    contextTokenCount: contextTokenCount
                )
            )
        )
        await onEvent(
            .contextWindow(
                DirectAgentContextWindowStatus(
                    usedTokens: contextTokenCount,
                    maxTokens: configuration.configuredContextWindowLimit
                        ?? model.generationDefaults.contextWindow,
                    modelID: model.id,
                    isApproximate: false
                )
            )
        )
    }

    func emitTranscriptPart(
        _ part: MLXServerCoderTranscriptSplitter.Part,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async {
        switch part {
        case .content(let text):
            guard !text.isEmpty else {
                return
            }
            await onEvent(.content(text))
        case .thought(let text):
            guard !text.isEmpty else {
                return
            }
            await onEvent(.thought(text))
        }
    }
}
#endif
