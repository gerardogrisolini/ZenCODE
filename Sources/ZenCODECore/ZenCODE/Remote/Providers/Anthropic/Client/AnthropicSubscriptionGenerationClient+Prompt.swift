//
//  AnthropicSubscriptionGenerationClient+Prompt.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

import Foundation

extension AnthropicSubscriptionGenerationClient {
    public func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        if sessions[sessionID] == nil {
            createSession(id: sessionID, cwd: configuration.workingDirectory.path)
        }
        guard var session = sessions[sessionID] else {
            throw RemoteGenerationClientError.missingSession
        }

        session.messages.append(
            RemoteGenerationClient.remoteMessage(
                role: AgentRuntimeMessage.Role.user.rawValue,
                content: prompt,
                attachments: attachments
            )
        )
        // Persist before the first suspension. A session lease keeps a later
        // close/recreate from being overwritten by this in-flight turn.
        sessions[sessionID] = session
        guard let lease = sessionLease(for: sessionID) else {
            throw RemoteGenerationClientError.missingSession
        }

        let credentials = try await AnthropicSubscriptionAuthService.loadValidCredentials()
        guard currentSession(for: lease) != nil else {
            throw RemoteGenerationClientError.missingSession
        }
        let modelLLMID = modelLLMID()
        let modelID = AnthropicSubscriptionModel.modelID(fromLLMID: modelLLMID)
        await onEvent(.modelLoaded(AnthropicSubscriptionModel.selectionTitle(forLLMID: modelLLMID)))

        var accumulatedText = ""
        var generationStats: [RemoteGenerationStats] = []
        var didRetryAfterContextLimit = false
        var didRetryAfterThinkingReplayRejection = false

        for round in 0..<configuration.maxToolRounds {
            guard var session = currentSession(for: lease) else {
                throw RemoteGenerationClientError.missingSession
            }
            if let result = compactSessionIfNeeded(
                &session,
                modelLLMID: modelLLMID
            ) {
                guard mutateSession(for: lease, { $0.messages = session.messages }) else {
                    throw RemoteGenerationClientError.missingSession
                }
                await onEvent(.diagnostic(Self.compactionDiagnostic(from: result)))
            }

            while true {
                guard var session = currentSession(for: lease) else {
                    throw RemoteGenerationClientError.missingSession
                }
                let streamResult: RemoteStreamResult
                do {
                    streamResult = try await streamAnthropicMessages(
                        session: &session,
                        modelID: modelID,
                        modelLLMID: modelLLMID,
                        credentials: credentials,
                        includeThinkingBlocks: !didRetryAfterThinkingReplayRejection,
                        onEvent: onEvent
                    )
                } catch {
                    if !didRetryAfterThinkingReplayRejection,
                       Self.isThinkingReplayRejected(error) {
                        didRetryAfterThinkingReplayRejection = true
                        guard mutateSession(for: lease, { session in
                            session.messages = Self.removingThinkingBlocks(
                                from: session.messages
                            )
                        }) else {
                            throw RemoteGenerationClientError.missingSession
                        }
                        await onEvent(
                            .diagnostic(
                                "Anthropic rejected saved thinking blocks; retrying without replaying prior thinking blocks."
                            )
                        )
                        continue
                    }
                    guard Self.isContextLimitError(error), !didRetryAfterContextLimit else {
                        throw error
                    }
                    guard var currentSession = currentSession(for: lease),
                          let result = compactSessionForContextLimitRetry(
                              &currentSession,
                              modelLLMID: modelLLMID
                          ) else {
                        await onEvent(.diagnostic(Self.contextLimitRetryUnavailableDiagnostic()))
                        throw error
                    }
                    didRetryAfterContextLimit = true
                    guard mutateSession(for: lease, { $0.messages = currentSession.messages }) else {
                        throw RemoteGenerationClientError.missingSession
                    }
                    await onEvent(.diagnostic(Self.contextLimitRetryDiagnostic(from: result)))
                    continue
                }

                accumulatedText.append(streamResult.text)
                generationStats.append(streamResult.stats)
                guard mutateSession(for: lease, { session in
                    appendAssistantMessage(streamResult: streamResult, to: &session.messages)
                }) else {
                    throw RemoteGenerationClientError.missingSession
                }
                if let metrics = RemoteGenerationClient.generationMetrics(generationStats) {
                    await Self.publishAnthropicSubscriptionMetrics(
                        metrics,
                        maxTokens: resolvedContextWindowTokenLimit(forLLMID: modelLLMID),
                        modelID: modelID,
                        onEvent: onEvent
                    )
                }

                if streamResult.toolCalls.isEmpty {
                    if !configuration.appMode,
                       let summary = RemoteGenerationClient.generationSummary(generationStats) {
                        await onEvent(.diagnostic(summary))
                    }
                    return DirectAgentResponse(
                        text: accumulatedText,
                        stopReason: streamResult.stopReason,
                        modelID: modelID
                    )
                }

                for toolCall in streamResult.toolCalls {
                    await onEvent(.toolCallStarted(toolCall))
                    guard let activeSession = currentSession(for: lease) else {
                        throw RemoteGenerationClientError.missingSession
                    }
                    let result = await toolExecutor.execute(
                        sessionID: activeSession.id,
                        toolCall: toolCall,
                        workingDirectory: activeSession.cwd,
                        allowedToolNames: activeSession.allowedToolNames
                    )
                    await onEvent(.toolCallCompleted(toolCall, result))
                    guard mutateSession(for: lease, { session in
                        session.messages.append(
                            RemoteGenerationClient.toolResultMessage(
                                toolCall: toolCall,
                                result: result
                            )
                        )
                    }) else {
                        throw RemoteGenerationClientError.missingSession
                    }
                }

                if round == configuration.maxToolRounds - 1 {
                    throw RemoteGenerationClientError.tooManyToolRounds(configuration.maxToolRounds)
                }
                break
            }
        }
        throw RemoteGenerationClientError.tooManyToolRounds(configuration.maxToolRounds)
    }

    static func removingThinkingBlocks(
        from messages: [[String: Any]]
    ) -> [[String: Any]] {
        messages.map { message in
            guard message["thinking_blocks"] != nil else {
                return message
            }
            var copy = message
            copy.removeValue(forKey: "thinking_blocks")
            return copy
        }
    }

    static func isThinkingReplayRejected(_ error: Error) -> Bool {
        let message: String
        if let error = error as? RemoteGenerationClientError {
            switch error {
            case let .remoteFailure(output):
                message = output
            default:
                message = error.localizedDescription
            }
        } else {
            message = error.localizedDescription
        }
        return messageIndicatesThinkingReplayRejected(message)
    }

    static func messageIndicatesThinkingReplayRejected(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.contains("thinking") else {
            return false
        }
        return normalized.contains("invalid_thinking_signature")
            || normalized.contains("thinking_blocks_modified")
            || normalized.contains("signature")
            || normalized.contains("cannot be modified")
            || normalized.contains("redacted_thinking")
            || normalized.contains("thinking block")
    }
}
