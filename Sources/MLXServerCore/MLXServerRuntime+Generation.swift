//
//  MLXServerRuntime+Generation.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//
import CryptoKit
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import Tokenizers

extension MLXServerRuntime {
    public func generate(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> AsyncStream<Generation> {
        let generationLease = try await generationGates.acquire(modelID: request.model.id)

        do {
            let container = try await container(
                for: request.model,
                runtimeKind: request.runtimeKind,
                parameters: request.parameters,
                progressHandler: progressHandler
            )
            let input = UserInput(
                chat: request.messages.map(\.mlxChatMessage),
                processing: .init(resize: request.mediaResize),
                tools: request.tools,
                additionalContext: request.additionalContext
            )
            let lmInput = try await container.prepare(input: input)
            let parameters = request.parameters
            let tools = request.tools
            let stream = try await container.perform(nonSendable: lmInput) { context, input in
                try MLXLMCommon.generate(
                    input: input,
                    parameters: parameters,
                    context: context,
                    tools: tools
                )
            }

            return AsyncStream { continuation in
                let task = Task {
                    for await event in stream {
                        if Task.isCancelled {
                            break
                        }
                        continuation.yield(event)
                    }
                    await generationLease.release()
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        } catch {
            await generationLease.release()
            throw error
        }
    }

    public func generateChatSession(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> AsyncThrowingStream<Generation, Error> {
        guard request.messages.allSatisfy({ $0.imageURLs.isEmpty && $0.videoURLs.isEmpty }) else {
            let stream = try await generate(request: request, progressHandler: progressHandler)
            return AsyncThrowingStream { continuation in
                let task = Task {
                    for await item in stream {
                        if Task.isCancelled {
                            break
                        }
                        continuation.yield(item)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in
                    task.cancel()
                }
            }
        }
        guard !request.messages.isEmpty else {
            throw MLXServerRuntimeError.emptyPrompt
        }

        let generationLease = try await generationGates.acquire(modelID: request.model.id)

        let resolved: ResolvedChatSession
        do {
            let container = try await container(
                for: request.model,
                runtimeKind: request.runtimeKind,
                parameters: request.parameters,
                progressHandler: progressHandler
            )
            resolved = await resolveChatSession(request: request, container: container)
        } catch {
            await generationLease.release()
            throw error
        }

        let cacheKey = resolved.cacheKey
        let requestFingerprints = request.messages.map(\.transcriptFingerprint)
        let toolsSignature = MLXServerChatSessionRequestSignature.tools(request.tools)
        let contextSignature = MLXServerChatSessionRequestSignature.additionalContext(
            request.additionalContext
        )
        let sessionTransfer = resolved.sessionTransfer
        let cachedPromptTokenCount = resolved.cachedPromptTokenCount
        let throwingStream: AsyncStream<Generation>
        do {
            throwingStream = try await sessionTransfer.session.streamDetails(
                request: request,
                cachedPromptTokenCount: cachedPromptTokenCount,
                cachedPrefixMessageCount: resolved.cachedPrefixMessageCount
            )
        } catch {
            discardChatSession(for: cacheKey)
            await generationLease.release()
            throw error
        }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var completionInfo: GenerateCompletionInfo?
                var wasCancelled = false
                for await item in throwingStream {
                    if Task.isCancelled {
                        wasCancelled = true
                        break
                    }
                    if case .info(let info) = item {
                        completionInfo = info
                    }
                    continuation.yield(item)
                }

                if wasCancelled || Task.isCancelled {
                    // A cancelled turn leaves a truncated assistant turn in
                    // the KV cache; storing it would make later requests
                    // continue on top of tokens that do not match the
                    // client transcript. Drop the session instead.
                    self.discardChatSession(for: cacheKey)
                    await generationLease.release()
                    continuation.finish(throwing: CancellationError())
                    return
                }

                self.finishChatSessionTurn(
                    cacheKey: cacheKey,
                    sessionTransfer: sessionTransfer,
                    requestFingerprints: requestFingerprints,
                    toolsSignature: toolsSignature,
                    contextSignature: contextSignature,
                    cachedPromptTokenCount: cachedPromptTokenCount,
                    completionInfo: completionInfo
                )
                await generationLease.release()
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public func generateText(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> MLXServerGenerationOutput {
        let stream = try await generate(request: request, progressHandler: progressHandler)
        return await Self.collectGenerationOutput(stream)
    }

    public func generateChatSessionText(
        request: MLXServerGenerationRequest,
        progressHandler: @Sendable @escaping (Progress) -> Void = { _ in }
    ) async throws -> MLXServerGenerationOutput {
        let stream = try await generateChatSession(request: request, progressHandler: progressHandler)
        return try await Self.collectThrowingGenerationOutput(stream)
    }

    static func collectGenerationOutput(
        _ stream: AsyncStream<Generation>
    ) async -> MLXServerGenerationOutput {
        var text = ""
        var toolCalls: [ToolCall] = []
        var info: GenerateCompletionInfo?

        for await event in stream {
            switch event {
            case .chunk(let chunk):
                text += chunk
            case .info(let completionInfo):
                info = completionInfo
            case .toolCall(let toolCall):
                toolCalls.append(toolCall)
            }
        }

        return MLXServerGenerationOutput(text: text, toolCalls: toolCalls, info: info)
    }

    static func collectThrowingGenerationOutput(
        _ stream: AsyncThrowingStream<Generation, Error>
    ) async throws -> MLXServerGenerationOutput {
        var text = ""
        var toolCalls: [ToolCall] = []
        var info: GenerateCompletionInfo?

        for try await event in stream {
            switch event {
            case .chunk(let chunk):
                text += chunk
            case .info(let completionInfo):
                info = completionInfo
            case .toolCall(let toolCall):
                toolCalls.append(toolCall)
            }
        }

        return MLXServerGenerationOutput(text: text, toolCalls: toolCalls, info: info)
    }
}
