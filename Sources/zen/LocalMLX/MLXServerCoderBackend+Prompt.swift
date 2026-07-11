#if ZENCODE_LOCAL_MLX
//
//  MLXServerCoderBackend+Prompt.swift
//  ZenCODE
//

import Foundation
import ZenCODECore
@preconcurrency import MLXLMCommon
import MLXServerCore

extension MLXServerCoderBackend {
    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        let lease = try await promptGates.acquire(key: sessionID)
        do {
            try Task.checkCancellation()
            let response = try await sendPromptExclusively(
                sessionID: sessionID,
                prompt: prompt,
                attachments: attachments,
                onEvent: onEvent
            )
            await lease.release()
            return response
        } catch {
            await lease.release()
            throw error
        }
    }

    private func sendPromptExclusively(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        if sessions[sessionID] == nil {
            createSession(
                id: sessionID,
                cwd: configuration.workingDirectory.path,
                systemPrompt: nil,
                history: [],
                cacheKey: nil,
                allowedToolNames: [],
                thinkingSelection: nil,
                preserveThinking: false
            )
        }
        guard let initialSession = sessions[sessionID] else {
            throw MLXServerCoderBackendError.missingSession
        }

        _ = try await preloadModel(onEvent: onEvent)
        var transactionSession = initialSession
        transactionSession.messages.append(
            Self.serverMessage(
                role: .user,
                content: prompt,
                attachments: attachments
            )
        )
        let transaction = try await runtime.beginChatSessionTransaction(
            request: generationRequest(
                for: transactionSession,
                sessionID: sessionID,
                tools: nil
            )
        )

        do {
            // The transaction acquisition may have waited for another prompt
            // using the same runtime cache. Refresh application state only
            // after exclusive ownership has been granted.
            guard var session = sessions[sessionID] else {
                throw MLXServerCoderBackendError.missingSession
            }
            let toolSpecs = await toolSpecs(
                allowedToolNames: session.allowedToolNames,
                preferredWorkspaceRootURL: session.cwd
            )
            try Task.checkCancellation()
            await runtime.captureChatSessionTransactionCheckpoint(
                transaction,
                request: generationRequest(
                    for: session,
                    sessionID: sessionID,
                    tools: toolSpecs
                )
            )

            session.messages.append(
                Self.serverMessage(
                    role: .user,
                    content: prompt,
                    attachments: attachments
                )
            )

            var accumulatedVisibleText = ""
            for _ in 0..<configuration.maxToolRounds {
                if let result = compactSessionIfNeeded(&session) {
                    await onEvent(.diagnostic(Self.compactionDiagnostic(from: result)))
                }
                let request = generationRequest(
                    for: session,
                    sessionID: sessionID,
                    tools: toolSpecs
                )
                await onEvent(.modelRuntime(request.runtimeKind.rawValue))
                let turn = try await runGenerationTurn(
                    request: request,
                    onEvent: onEvent
                )
                let directToolCalls = turn.toolCalls.map(Self.directToolCall(from:))
                appendAssistantTurn(turn, directToolCalls: directToolCalls, to: &session)
                accumulatedVisibleText += turn.visibleText

                if let completionInfo = turn.completionInfo {
                    await emitMetrics(
                        completionInfo,
                        onEvent: onEvent
                    )
                }
                try Task.checkCancellation()

                guard !turn.toolCalls.isEmpty else {
                    sessions[sessionID] = session
                    await runtime.commitChatSessionTransaction(transaction)
                    return DirectAgentResponse(
                        text: accumulatedVisibleText,
                        stopReason: "end_turn",
                        modelID: model.id
                    )
                }

                for directToolCall in directToolCalls {
                    await onEvent(.toolCallStarted(directToolCall))
                    let result = await toolExecutor.execute(
                        sessionID: sessionID,
                        toolCall: directToolCall,
                        workingDirectory: session.cwd,
                        allowedToolNames: session.allowedToolNames
                    )
                    try Task.checkCancellation()
                    await onEvent(.toolCallCompleted(directToolCall, result))
                    session.messages.append(
                        .tool(
                            result.output,
                            toolCallID: directToolCall.id,
                            toolName: directToolCall.name
                        )
                    )
                }
            }

            try Task.checkCancellation()
            sessions[sessionID] = session
            await runtime.commitChatSessionTransaction(transaction)
            throw MLXServerCoderBackendError.tooManyToolRounds(
                configuration.maxToolRounds
            )
        } catch is CancellationError {
            await runtime.rollbackChatSessionTransaction(transaction)
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                await runtime.rollbackChatSessionTransaction(transaction)
                throw CancellationError()
            }
            await runtime.commitChatSessionTransaction(transaction)
            throw error
        }
    }
}
#endif
