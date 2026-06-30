//
//  CachedContinuationTemplateSlice.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
import CryptoKit
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import Tokenizers

extension MLXServerRawChatSession {
    struct CachedContinuationTemplateSlice {
        var cachedContextMessages: [[String: any Sendable]]
        var continuationContextMessages: [[String: any Sendable]]
    }

    static func cachedContinuationTemplateSlice(
        request: MLXServerGenerationRequest,
        cachedPrefixMessageCount: Int
    ) -> CachedContinuationTemplateSlice {
        let contextStartIndex = cachedContinuationContextStartIndex(
            request: request,
            cachedPrefixMessageCount: cachedPrefixMessageCount
        )
        let style = MLXServerToolResultTemplateStyle.style(for: request.model)
        let cachedContextMessages = request.messages[contextStartIndex..<cachedPrefixMessageCount]
            .map { $0.rawTemplateMessage(toolResultStyle: style) }
        let continuationContextMessages = request.messages
            .dropFirst(contextStartIndex)
            .map { $0.rawTemplateMessage(toolResultStyle: style) }
        return CachedContinuationTemplateSlice(
            cachedContextMessages: cachedContextMessages,
            continuationContextMessages: continuationContextMessages
        )
    }

    private static func cachedContinuationContextStartIndex(
        request: MLXServerGenerationRequest,
        cachedPrefixMessageCount: Int
    ) -> Int {
        let prefix = request.messages.prefix(cachedPrefixMessageCount)
        return prefix.lastIndex { $0.role == .user } ?? (cachedPrefixMessageCount - 1)
    }

    static func suffixChatMessages(
        request: MLXServerGenerationRequest,
        cachedPrefixMessageCount: Int
    ) -> [Chat.Message] {
        guard cachedPrefixMessageCount > 0 else {
            return request.messages.map(\.mlxChatMessage)
        }
        return request.messages
            .dropFirst(cachedPrefixMessageCount)
            .map(\.mlxChatMessage)
    }

    static func generationStream(
        from tokenStream: AsyncStream<TokenGeneration>,
        tokenizer: any MLXLMCommon.Tokenizer,
        toolCallFormat: ToolCallFormat,
        tools: [[String: any Sendable]]?
    ) -> AsyncStream<Generation> {
        AsyncStream { continuation in
            let task = Task {
                var detokenizer = NaiveStreamingDetokenizer(tokenizer: tokenizer)
                var toolCallProcessor = MLXServerToolCallStreamProcessor(
                    format: toolCallFormat,
                    tools: tools
                )
                var didFinishWithInfo = false

                func emitPendingToolCalls() {
                    for toolCall in toolCallProcessor.drainToolCalls() {
                        continuation.yield(.toolCall(toolCall))
                    }
                }

                func finishBufferedOutput() {
                    if let text = toolCallProcessor.processEOS(returnBufferedText: true),
                       !text.isEmpty {
                        continuation.yield(.chunk(text))
                    }
                    emitPendingToolCalls()
                }

                for await event in tokenStream {
                    guard !Task.isCancelled else {
                        break
                    }
                    switch event {
                    case .token(let token):
                        detokenizer.append(token: token)
                        if let chunk = detokenizer.next() {
                            if let text = toolCallProcessor.processChunk(chunk),
                               !text.isEmpty {
                                continuation.yield(.chunk(text))
                            }
                            emitPendingToolCalls()
                        }
                    case .info(let info):
                        finishBufferedOutput()
                        continuation.yield(.info(info))
                        didFinishWithInfo = true
                    }
                }

                if !didFinishWithInfo {
                    finishBufferedOutput()
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    func saveCache(to url: URL) async throws {
        guard let cache else {
            throw ChatSessionError.noCacheAvailable
        }
        try savePromptCache(url: url, cache: cache)
    }

}

struct MLXServerRawChatSessionPlan {
    var session: MLXServerRawChatSession
    var request: MLXServerGenerationRequest
    var cachedPromptTokenCount: Int?
    var cachedPrefixMessageCount: Int
}

