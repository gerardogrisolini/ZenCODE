//
//  ChatGPTSubscriptionGenerationClient+Prompt.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore
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

        session.messages.append(
            RemoteGenerationClient.remoteMessage(
                role: AgentRuntimeMessage.Role.user.rawValue,
                content: prompt,
                attachments: attachments
            )
        )
        // This is the first durable turn mutation; it must precede credential
        // loading so concurrent compaction sees it and close invalidates the
        // in-flight operation rather than allowing it to restore the session.
        sessions[sessionID] = session
        guard let lease = sessionLease(for: sessionID) else {
            throw ChatGPTSubscriptionGenerationError.missingSession
        }
        let httpFallbackScopeID = Self.httpFallbackScopeID(for: lease)

        var credentials = try await CodexAgentModel.loadValidCredentials()
        guard let loadedSession = currentSession(for: lease) else {
            throw ChatGPTSubscriptionGenerationError.missingSession
        }
        session = loadedSession
        let modelLLMID = modelLLMID()
        let modelID = CodexAgentModel.modelID(fromLLMID: modelLLMID)
        await onEvent(.modelLoaded(CodexAgentModel.selectionTitle(forLLMID: modelLLMID)))
        guard let postLoadSession = currentSession(for: lease) else {
            throw ChatGPTSubscriptionGenerationError.missingSession
        }
        session = postLoadSession
        let requestConfiguration = RequestConfiguration(
            modelID: modelLLMID,
            workingDirectory: session.cwd,
            systemPrompt: session.systemPrompt ?? "",
            sessionKey: session.cacheKey?.nilIfBlank ?? session.id,
            connectionScopeID: connectionScopeID,
            history: [],
            allowedToolNames: session.allowedToolNames,
            thinkingSelection: session.thinkingSelection,
            appMode: configuration.appMode
                )
        let sessionIdentity = SessionIdentity(configuration: requestConfiguration)
        // Keep cache routing stable across transport resets. The WebSocket ID
        // may rotate after a failure, but the canonical identity must not.
        let proposedPromptCacheKey = promptCacheKey(for: sessionIdentity) ?? UUID().uuidString
        let promptCacheKey = storePromptCacheKey(
            proposedPromptCacheKey,
            for: sessionIdentity
        )
        let chatGPTSessionID = session.chatGPTSessionID ?? promptCacheKey
        guard mutateSession(for: lease, { session in
            if session.chatGPTSessionID == nil {
                session.chatGPTSessionID = chatGPTSessionID
            }
        }) else {
            throw ChatGPTSubscriptionGenerationError.missingSession
        }
        guard let resolvedSession = currentSession(for: lease) else {
            throw ChatGPTSubscriptionGenerationError.missingSession
        }
        session = resolvedSession

        var client = ChatGPTSubscriptionResponsesClient(
            credentials: credentials,
            webSocketPool: webSocketPool
        )
        let reasoningEffort = session.thinkingSelection
            .flatMap(Self.chatGPTReasoningEffort(for:))
        let maxContextWindowTokens = resolvedContextWindowTokenLimit(
            forLLMID: modelLLMID
        )

        var accumulatedText = ""
        var generationStats: [RemoteGenerationStats] = []
        var didRetryAfterContextLimit = false
        var didReportUnsatisfiableBudget = false
        var streamInterruptionRetries = 0


        for round in 0..<configuration.maxToolRounds {
            guard let roundSession = currentSession(for: lease) else {
                throw ChatGPTSubscriptionGenerationError.missingSession
            }
            session = roundSession
            if let result = compactSessionIfNeeded(
                &session,
                maxTokens: maxContextWindowTokens,
                maxOutputTokens: configuration.maxOutputTokens
            ) {
                guard mutateSession(for: lease, { $0 = session }) else {
                    throw ChatGPTSubscriptionGenerationError.missingSession
                }
                await onEvent(.diagnostic(Self.compactionDiagnostic(from: result)))
            }

            // The preflight may only compact a bounded number of times per
            // round. Every successful compaction strictly shrinks the prompt,
            // so this cap is a safety net rather than the termination
            // argument, but it keeps a mis-estimated overhead from spinning.
            var preflightCompactionAttempts = 0
            var lastRequestEstimate = SubscriptionCompactionSupport.RequestEstimate.unmeasured
            while true {
                guard let turnSession = currentSession(for: lease) else {
                    throw ChatGPTSubscriptionGenerationError.missingSession
                }
                session = turnSession
                let toolCatalog = RemoteToolWireCatalog(
                    descriptors: await toolExecutor.descriptors(
                        allowedToolNames: session.allowedToolNames,
                        preferredWorkspaceRootURL: URL(fileURLWithPath: session.cwd),
                        sessionID: session.id
                    )
                )
                guard let latestSession = currentSession(for: lease) else {
                    throw ChatGPTSubscriptionGenerationError.missingSession
                }
                session = latestSession
                // Applied to the outgoing copy alone on every tool round: each
                // round rebuilds from the fresh `session.messages` value, so
                // the block appears exactly once per request. Keeping
                // `session.messages` free of the block means it never reaches
                // history, snapshots or the cache key.
                let outgoingMessages = RemoteGenerationClient.applyingCurrentTurnMemory(
                    to: session.messages
                )
                let requestPayload = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
                    from: toolCatalog.wireMessages(from: outgoingMessages),
                    continuation: session.continuation
                )
                let hasContinuationReplay = requestPayload.previousResponseID?.nilIfBlank != nil
                    && requestPayload.cachedWebSocketInput != nil
                let usesHTTPFallback = webSocketPool.usesHTTPFallback(
                    scopeID: httpFallbackScopeID
                )
                let usesFreshContinuationReplay = !usesHTTPFallback
                    && session.continuation?.allowsFreshTransport == true
                    && hasContinuationReplay
                let instructions = requestPayload.instructions?.nilIfBlank
                    ?? "You are a helpful coding assistant."
                let toolPayloads = toolCatalog.responsesToolPayloads
                // Always estimated against the full history, never against the
                // continuation delta: both the preflight and the context-limit
                // retry compact `session.messages`, and a delta-sized estimate
                // would describe a different request than the one being fixed.
                let requestEstimate = Self.requestEstimate(
                    instructions: instructions,
                    fullHistoryInput: requestPayload.input,
                    toolPayloads: toolPayloads
                )
                if preflightCompactionAttempts
                    < AgentConversationCompactionPolicy.maximumPreflightCompactionAttempts {
                    let outcome = compactSessionForEstimatedContextIfNeeded(
                        &session,
                        estimate: requestEstimate,
                        maxTokens: maxContextWindowTokens,
                        maxOutputTokens: configuration.maxOutputTokens
                    )
                    switch outcome {
                    case let .compacted(result):
                        guard mutateSession(for: lease, { $0 = session }) else {
                            throw ChatGPTSubscriptionGenerationError.missingSession
                        }
                        preflightCompactionAttempts += 1
                        await onEvent(.diagnostic(Self.compactionDiagnostic(from: result)))
                        continue
                    case let .unsatisfiableBudget(
                        contextWindowTokens,
                        reservedOutputTokens,
                        overheadTokens
                    ):
                        // Compaction cannot make this request fit at all. Say so
                        // once and let the provider answer or fail, instead of
                        // repeating a pass that can never reach its target.
                        if !didReportUnsatisfiableBudget {
                            didReportUnsatisfiableBudget = true
                            await onEvent(
                                .diagnostic(
                                    Self.unsatisfiableBudgetDiagnostic(
                                        contextWindowTokens: contextWindowTokens,
                                        maxOutputTokens: reservedOutputTokens,
                                        overheadTokens: overheadTokens
                                    )
                                )
                            )
                        }
                    case .notNeeded:
                        break
                    }
                }
                lastRequestEstimate = requestEstimate
                let expectsPromptCache = RemoteGenerationClient.messagesExpectPromptCache(
                    session.messages
                )
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
                        threadID: session.id,
                        fallbackScopeID: httpFallbackScopeID,
                        promptCacheKey: promptCacheKey,
                        cachedWebSocketInput: requestPayload.cachedWebSocketInput.map {
                            JSONValue.acpValue(from: $0)
                        },
                        previousResponseID: requestPayload.previousResponseID,
                        allowsFreshWebSocketContinuation: usesFreshContinuationReplay,
                        toolPayloads: JSONValue.acpValue(from: toolPayloads),
                        maxOutputTokens: configuration.maxOutputTokens
                    ) { object in
                        try Task.checkCancellation()
                        let events = try await streamAccumulator.ingest(StreamAccumulatorObject(object))
                        for event in events {
                            await onEvent(event)
                        }
                    }
                } catch {
                    if Task.isCancelled
                        || ChatGPTSubscriptionResponsesClient.isCancellationError(error) {
                        throw error
                    }
                    let shouldRetryStreamInterruption =
                        Self.shouldRetryStreamInterruption(
                            error,
                            completedRetries: streamInterruptionRetries
                        )
                    if error is ChatGPTSubscriptionResponsesClient.ReplayUnsafeStreamFailure,
                       !shouldRetryStreamInterruption {
                        // A callback error or a non-transport stream failure may
                        // have crossed a side-effecting boundary and must not be
                        // replayed. A transient transport interruption is handled
                        // below by discarding this attempt's accumulator and
                        // reopening the turn on a fresh connection.
                        throw error
                    }
                    if hasContinuationReplay,
                       Self.continuationUnavailableError(from: error) != nil {
                        // The server no longer has the previous response state
                        // (for example the WebSocket died and store=false state
                        // expired). Fall back to a full conversation replay:
                        // requestPayload.input always carries the whole session.
                        guard mutateSession(for: lease, { session in
                            resetContinuationAndTransport(session: &session)
                        }) else {
                            throw ChatGPTSubscriptionGenerationError.missingSession
                        }
                        await onEvent(
                            .diagnostic(Self.continuationReplayFallbackDiagnostic())
                        )
                        continue
                    }
                    if shouldRetryStreamInterruption {
                        let interruptionError = Self.underlyingStreamInterruptionError(
                            error
                        )
                        // A 401/403 from either transport means the access token
                        // is stale on the server even though the local expiry
                        // window passed. Force a refresh before rebuilding the
                        // client and retrying on the session's active transport.
                        if Self.isAuthenticationFailure(interruptionError) {
                            do {
                                let refreshed = try await ChatGPTSubscriptionAuthService
                                    .refresh(credentials: credentials)
                                credentials = refreshed
                                client = ChatGPTSubscriptionResponsesClient(
                                    credentials: credentials,
                                    baseURL: client.baseURL,
                                    webSocketPool: webSocketPool
                                )
                                await onEvent(.diagnostic(Self.authRefreshDiagnostic()))
                            } catch {
                                if Task.isCancelled
                                    || ChatGPTSubscriptionResponsesClient
                                        .isCancellationError(error) {
                                    throw error
                                }
                            }
                        }
                        // The transport client could not replay after provisional
                        // stream callbacks. At this generation boundary, final
                        // content and tool calls are still buffered, so discarding
                        // the failed accumulator and replaying on a fresh connection
                        // cannot duplicate a committed assistant response or tool.
                        streamInterruptionRetries += 1
                        guard mutateSession(for: lease, { session in
                            resetContinuationAndTransport(session: &session)
                        }) else {
                            throw ChatGPTSubscriptionGenerationError.missingSession
                        }
                        await onEvent(
                            .diagnostic(Self.streamInterruptionRetryDiagnostic())
                        )
                        continue
                    }
                    guard Self.isContextLimitError(error), !didRetryAfterContextLimit else {
                        throw error
                    }
                    guard var latestSession = currentSession(for: lease),
                          let result = compactSessionForContextLimitRetry(
                              &latestSession,
                              maxTokens: maxContextWindowTokens,
                              maxOutputTokens: configuration.maxOutputTokens,
                              estimate: lastRequestEstimate
                          ) else {
                        await onEvent(.diagnostic(Self.contextLimitRetryUnavailableDiagnostic()))
                        throw error
                    }
                    didRetryAfterContextLimit = true
                    guard mutateSession(for: lease, { $0 = latestSession }) else {
                        throw ChatGPTSubscriptionGenerationError.missingSession
                    }
                    await onEvent(.diagnostic(Self.contextLimitRetryDiagnostic(from: result)))
                    continue
                }

                // A completed request establishes a fresh retry budget for the
                // next tool round; failures within one request remain bounded.
                streamInterruptionRetries = 0
                if completion.didActivateHTTPFallback {
                    await onEvent(.diagnostic(Self.httpFallbackDiagnostic()))
                }
                await streamAccumulator.recordCompletionResponseID(completion.responseID)
                let rawStreamResult = try await streamAccumulator.result()
                let streamResult = StreamAccumulatorResult(
                    text: rawStreamResult.text,
                    reasoningText: rawStreamResult.reasoningText,
                    stopReason: rawStreamResult.stopReason,
                    toolCalls: rawStreamResult.toolCalls.map {
                        toolCatalog.localToolCall(from: $0)
                    },
                    usage: rawStreamResult.usage,
                    firstDeltaAt: rawStreamResult.firstDeltaAt,
                    latestResponseID: rawStreamResult.latestResponseID,
                    didEmitContent: rawStreamResult.didEmitContent,
                    reasoningItemsJSON: rawStreamResult.reasoningItemsJSON
                )
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

                guard mutateSession(for: lease, { session in
                    Self.appendAssistantMessage(
                        text: streamResult.text,
                        reasoningText: streamResult.reasoningText,
                        toolCalls: streamResult.toolCalls,
                        reasoningItemsJSON: streamResult.reasoningItemsJSON,
                        responseID: streamResult.latestResponseID,
                        to: &session.messages
                    )
                    if let responseID = streamResult.latestResponseID?.nilIfBlank {
                        session.continuation = ChatGPTSubscriptionContinuationState(
                            responseID: responseID,
                            messageCount: session.messages.count,
                            instructions: instructions,
                            allowsFreshTransport: true
                        )
                    } else {
                        session.continuation = nil
                    }
                }) else {
                    throw ChatGPTSubscriptionGenerationError.missingSession
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
                    return DirectAgentResponse(
                        text: accumulatedText,
                        stopReason: streamResult.stopReason,
                        modelID: modelLLMID
                    )
                }

                for toolCall in streamResult.toolCalls {
                    await onEvent(.toolCallStarted(toolCall))
                    guard let activeSession = currentSession(for: lease) else {
                        throw ChatGPTSubscriptionGenerationError.missingSession
                    }
                    let result = await toolExecutor.execute(
                        sessionID: activeSession.id,
                        toolCall: toolCall,
                        workingDirectory: URL(fileURLWithPath: activeSession.cwd),
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
                        throw ChatGPTSubscriptionGenerationError.missingSession
                    }
                }

                if round == configuration.maxToolRounds - 1 {
                    throw ChatGPTSubscriptionGenerationError.tooManyToolRounds(
                        configuration.maxToolRounds
                    )
                }
                break
            }
        }
        throw ChatGPTSubscriptionGenerationError.tooManyToolRounds(configuration.maxToolRounds)
    }

    static func continuationReplayFallbackDiagnostic() -> String {
        "ChatGPT Subscription lost the previous response id (the WebSocket "
            + "continuation is no longer available); retrying this turn with a "
            + "full conversation replay."
    }

    static let maxStreamInterruptionRetries = 1

    static func streamInterruptionRetryDiagnostic() -> String {
        "ChatGPT Subscription response was interrupted by a transient transport "
            + "failure; reopening the connection and retrying this turn with "
            + "a full conversation replay."
    }

    static func httpFallbackDiagnostic() -> String {
        "ChatGPT Subscription switched this session from WebSocket to HTTP "
            + "streaming after a recoverable WebSocket backend failure."
    }

    static func shouldRetryStreamInterruption(
        _ error: Error,
        completedRetries: Int
    ) -> Bool {
        guard completedRetries >= 0,
              completedRetries < maxStreamInterruptionRetries else {
            return false
        }
        return isRetryableStreamInterruption(error)
    }

    static func underlyingStreamInterruptionError(_ error: Error) -> Error {
        if let failure = error as?
            ChatGPTSubscriptionResponsesClient.ReplayUnsafeStreamFailure {
            return failure.underlying
        }
        return error
    }

    static func isRetryableStreamInterruption(_ error: Error) -> Bool {
        let error = underlyingStreamInterruptionError(error)
        guard !ChatGPTSubscriptionResponsesClient.isCancellationError(error) else {
            return false
        }
        if let error = error as? RemoteTransportError,
           case let .upgradeRejected(status, _) = error,
           status == 429 {
            // The Responses client already applied its bounded backoff budget.
            // A second full-turn retry would only duplicate the same rate-limit
            // batch and delay the enriched limit error shown to the user.
            return false
        }
        return ChatGPTSubscriptionResponsesClient.isRetryableTransportError(error)
            || isAuthenticationFailure(error)
    }

    /// True when either transport returns an auth-related HTTP status (401/403).
    /// Such failures warrant a forced token refresh.
    static func isAuthenticationFailure(_ error: Error) -> Bool {
        if let error = error as? RemoteTransportError,
           case let .upgradeRejected(status, _) = error {
            return status == 401 || status == 403
        }
        if let error = error as? ChatGPTSubscriptionGenerationError,
           case let .http(status, _) = error {
            return status == 401 || status == 403
        }
        return false
    }

    static func authRefreshDiagnostic() -> String {
        "ChatGPT Subscription returned an authentication error; refreshed "
            + "the access token and will retry."
    }

    static func continuationUnavailableError(
        from error: Error
    ) -> ChatGPTSubscriptionGenerationError? {
        if let error = error as? ChatGPTSubscriptionGenerationError {
            switch error {
            case .continuationUnavailable:
                return error
            case let .http(_, output), let .responseFailed(output):
                guard messageIndicatesContinuationUnavailable(output) else {
                    return nil
                }
                return .continuationUnavailable(output)
            default:
                return nil
            }
        }

        let message = error.localizedDescription
        guard messageIndicatesContinuationUnavailable(message) else {
            return nil
        }
        return .continuationUnavailable(message)
    }

    static func messageIndicatesContinuationUnavailable(_ message: String) -> Bool {
        let normalized = message
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard normalized.contains("previous_response_id")
                || normalized.contains("previous response")
                || normalized.contains("response id")
                || normalized.contains("response_id")
                || normalized.contains("response with id") else {
            return false
        }

        if normalized.contains("unsupported parameter")
            && normalized.contains("previous_response_id") {
            return true
        }

        return normalized.contains("not found")
            || normalized.contains("cannot be found")
            || normalized.contains("could not be found")
            || normalized.contains("not available")
            || normalized.contains("unavailable")
            || normalized.contains("cannot resolve")
            || normalized.contains("could not resolve")
            || normalized.contains("does not exist")
            || normalized.contains("expired")
            || normalized.contains("invalid")
            || normalized.contains("missing")
    }
}
