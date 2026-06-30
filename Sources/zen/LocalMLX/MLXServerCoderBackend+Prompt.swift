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
        guard var session = sessions[sessionID] else {
            throw MLXServerCoderBackendError.missingSession
        }

        _ = try await preloadModel(onEvent: onEvent)
        session.messages.append(
            Self.serverMessage(
                role: .user,
                content: prompt,
                attachments: attachments
            )
        )

                // Tool specs depend only on the session's allowed tool names and
        // working directory, neither of which changes within a single
        // sendPrompt call. Compute them once (this includes the async MCP
        // round-trip) and reuse them across every tool round.
        let toolSpecs = await toolSpecs(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd
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
                await emitMetrics(completionInfo, onEvent: onEvent)
            }

            guard !turn.toolCalls.isEmpty else {
                sessions[sessionID] = session
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

        sessions[sessionID] = session
        throw MLXServerCoderBackendError.tooManyToolRounds(configuration.maxToolRounds)
    }
}

#endif
