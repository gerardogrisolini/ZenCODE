//
//  ChatGPTSubscriptionGenerationClient+Prompt.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
#if os(macOS)
import Foundation
#if canImport(os)
import os
#endif

extension ChatGPTSubscriptionGenerationClient {
    public func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        if sessions[sessionID] == nil {
            createSession(
                id: sessionID,
                cwd: configuration.workingDirectory.path,
                systemPrompt: nil
            )
        }
        guard var session = sessions[sessionID] else {
            throw ChatGPTSubscriptionGenerationError.missingSession
        }

        let credentials = try await CodexAgentModel.loadValidCredentials()
        let modelLLMID = modelLLMID()
        let modelID = CodexAgentModel.modelID(fromLLMID: modelLLMID)
        await onEvent(.modelLoaded(CodexAgentModel.selectionTitle(forLLMID: modelLLMID)))
        let requestConfiguration = RequestConfiguration(
            modelID: modelLLMID,
            workingDirectory: session.cwd,
            systemPrompt: session.systemPrompt ?? "",
            sessionKey: session.cacheKey?.nilIfBlank ?? session.id,
            history: [],
            allowedToolNames: session.allowedToolNames,
            thinkingSelection: session.thinkingSelection,
            appMode: configuration.appMode
                )
        let sessionIdentity = SessionIdentity(configuration: requestConfiguration)
        let chatGPTSessionID = sessionIDsByIdentity[sessionIdentity] ?? UUID().uuidString
        storeSessionID(chatGPTSessionID, for: sessionIdentity)
        session.chatGPTSessionID = chatGPTSessionID
        sessions[sessionID] = session

                        let client = ChatGPTSubscriptionResponsesClient(
            credentials: credentials,
            urlSession: urlSession,
            webSocketPool: webSocketPool,
            usesWebSocketTransport: usesWebSocketTransport
        )
        let reasoningEffort = session.thinkingSelection
            .flatMap(Self.chatGPTReasoningEffort(for:))
        let maxContextWindowTokens = resolvedContextWindowTokenLimit(
            forLLMID: modelLLMID
        )

        session.messages.append(
            RemoteGenerationClient.remoteMessage(
                role: AgentRuntimeMessage.Role.user.rawValue,
                content: prompt,
                attachments: attachments
            )
        )

        var accumulatedText = ""
        var generationStats: [RemoteGenerationStats] = []
        var didRetryAfterContextLimit = false


        for round in 0..<configuration.maxToolRounds {
            if let result = compactSessionIfNeeded(
                &session,
                maxTokens: maxContextWindowTokens,
                maxOutputTokens: configuration.maxOutputTokens,
                sessionIdentity: sessionIdentity
            ) {
                sessions[sessionID] = session
                await onEvent(.diagnostic(Self.compactionDiagnostic(from: result)))
            }

            while true {
                let toolCatalog = RemoteToolWireCatalog(
                    descriptors: await toolExecutor.descriptors(
                        allowedToolNames: session.allowedToolNames,
                        preferredWorkspaceRootURL: URL(fileURLWithPath: session.cwd)
                    )
                )
                if configuration.verboseLogging {
                    await onEvent(
                        .diagnostic(
                            RemoteGenerationClient.toolExposureDiagnostic(
                                from: toolCatalog.bindings.map(\.descriptor)
                            )
                        )
                    )
                }
                let requestPayload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
                    from: toolCatalog.wireMessages(from: session.messages),
                    continuation: session.continuation
                )
                let expectsPromptCache = RemoteGenerationClient.messagesExpectPromptCache(
                    session.messages
                )
                let instructions = requestPayload.instructions?.nilIfBlank
                    ?? "You are a helpful coding assistant."
                let toolPayloads = toolCatalog.responsesToolPayloads
                let requestStartedAt = Date()
                let streamAccumulator = StreamAccumulator()
                let completion: ChatGPTSubscriptionResponsesClient.StreamCompletion

                do {
                    completion = try await client.streamEvents(
                        input: JSONValue.acpValue(from: requestPayload.input),
                        model: modelID,
                        instructions: instructions,
                        reasoningEffort: reasoningEffort,
                        textVerbosity: "medium",
                        sessionID: session.chatGPTSessionID ?? chatGPTSessionID,
                        cachedWebSocketInput: requestPayload.cachedWebSocketInput.map {
                            JSONValue.acpValue(from: $0)
                        },
                        previousResponseID: requestPayload.previousResponseID,
                        toolPayloads: JSONValue.acpValue(from: toolPayloads),
                        maxOutputTokens: configuration.maxOutputTokens
                    ) { object in
                        try Task.checkCancellation()
                        let events = try streamAccumulator.ingest(object)
                        for event in events {
                            await onEvent(event)
                        }
                    }
                } catch {
                    guard Self.isContextLimitError(error), !didRetryAfterContextLimit else {
                        throw error
                    }
                    guard let result = compactSessionForContextLimitRetry(
                        &session,
                        maxTokens: maxContextWindowTokens,
                        maxOutputTokens: configuration.maxOutputTokens,
                        sessionIdentity: sessionIdentity
                    ) else {
                        await onEvent(.diagnostic(Self.contextLimitRetryUnavailableDiagnostic()))
                        throw error
                    }
                    didRetryAfterContextLimit = true
                    sessions[sessionID] = session
                    await onEvent(.diagnostic(Self.contextLimitRetryDiagnostic(from: result)))
                    continue
                }

                streamAccumulator.recordCompletionResponseID(completion.responseID)
                let streamResult = try streamAccumulator.result(toolCatalog: toolCatalog)
                if !streamResult.didEmitContent,
                   !streamResult.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await onEvent(.content(streamResult.text))
                }
                generationStats.append(
                    RemoteGenerationStats(
                        usage: streamResult.usage,
                        requestStartedAt: requestStartedAt,
                        firstDeltaAt: streamResult.firstDeltaAt,
                        finishedAt: Date(),
                        generatedCharacterCount: streamResult.text.count
                    )
                )
                accumulatedText.append(streamResult.text)

                if let cacheWarning = RemoteGenerationClient.promptCacheWarning(
                    provider: "ChatGPT",
                    usage: streamResult.usage,
                    expectsCacheRead: expectsPromptCache
                ) {
                    await onEvent(.diagnostic(cacheWarning))
                }

                if configuration.verboseLogging,
                   let cacheDiagnostic = RemoteGenerationClient.cacheUsageDiagnostic(
                       provider: "ChatGPT",
                       usage: streamResult.usage
                   ) {
                    await onEvent(.diagnostic(cacheDiagnostic))
                }

                Self.appendAssistantMessage(
                    text: streamResult.text,
                    reasoningText: streamResult.reasoningText,
                    toolCalls: streamResult.toolCalls,
                    reasoningItemsJSON: streamResult.reasoningItemsJSON,
                    to: &session.messages
                )
                if let responseID = streamResult.latestResponseID?.nilIfBlank {
                    session.continuation = ChatGPTSubscriptionContinuationState(
                        responseID: responseID,
                        messageCount: session.messages.count,
                        instructions: instructions
                    )
                } else {
                    session.continuation = nil
                }

                if let metrics = RemoteGenerationClient.generationMetrics(generationStats) {
                    await Self.publishChatGPTSubscriptionMetrics(
                        metrics,
                        estimatedContextTokens: nil,
                        completionTokens: streamResult.usage?.completionTokens,
                        generatedText: streamResult.text,
                        maxTokens: maxContextWindowTokens,
                        modelID: modelLLMID,
                        onEvent: onEvent
                    )
                }

                if streamResult.toolCalls.isEmpty {
                    sessions[sessionID] = session
                    return DirectAgentResponse(
                        text: accumulatedText,
                        stopReason: streamResult.stopReason,
                        modelID: modelLLMID
                    )
                }

                for toolCall in streamResult.toolCalls {
                    await onEvent(.toolCallStarted(toolCall))
                    let result = await toolExecutor.execute(
                        sessionID: session.id,
                        toolCall: toolCall,
                        workingDirectory: URL(fileURLWithPath: session.cwd),
                        allowedToolNames: session.allowedToolNames
                    )
                    await onEvent(.toolCallCompleted(toolCall, result))
                    session.messages.append([
                        "role": "tool",
                        "tool_call_id": toolCall.id,
                        "name": toolCall.name,
                        "content": result.output
                    ])
                }

                if round == configuration.maxToolRounds - 1 {
                    sessions[sessionID] = session
                    throw ChatGPTSubscriptionGenerationError.tooManyToolRounds(
                        configuration.maxToolRounds
                    )
                }
                break
            }
        }

        sessions[sessionID] = session
        throw ChatGPTSubscriptionGenerationError.tooManyToolRounds(configuration.maxToolRounds)
    }
}

#endif
