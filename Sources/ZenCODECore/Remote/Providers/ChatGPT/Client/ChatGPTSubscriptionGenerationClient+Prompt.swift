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
        guard !RemoteSubscriptionModelID.modelID(fromLLMID: modelLLMID(), prefix: "chatgpt").isEmpty else {
            throw AgentCoreBackendError.missingRemoteProvider
        }
        return try await sendPrompt(
            sessionID: sessionID,
            prompt: prompt,
            attachments: attachments,
            loadCredentials: { try await ChatGPTSubscriptionAuthService.loadValidCredentials() },
            onEvent: onEvent
        )
    }

    // Internal credential seam keeps deterministic caller tests off real auth storage.
    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        loadCredentials: @Sendable () async throws -> CodexAgentCredentials,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        guard !RemoteSubscriptionModelID.modelID(fromLLMID: modelLLMID(), prefix: "chatgpt").isEmpty else {
            throw AgentCoreBackendError.missingRemoteProvider
        }
        if sessions[sessionID] == nil {
            guard !MemoryConsolidationContext.isIsolated else { throw CancellationError() }
            createSession(
                id: sessionID,
                cwd: configuration.workingDirectory.path,
                systemPrompt: nil
            )
        }
        guard var session = sessions[sessionID] else {
            throw ChatGPTSubscriptionGenerationError.missingSession
        }

        // The turn's memory block and instruction are recorded on the prompt,
        // so every later request sends it again as it was first sent.
        session.messages.append(
            RemoteGenerationClient.recordingTurnAddition(
                on: RemoteGenerationClient.remoteMessage(
                    role: AgentRuntimeMessage.Role.user.rawValue,
                    content: prompt,
                    attachments: attachments
                )
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

        var credentials = try await loadCredentials()
        guard let loadedSession = currentSession(for: lease) else {
            throw ChatGPTSubscriptionGenerationError.missingSession
        }
        session = loadedSession
        let modelLLMID = modelLLMID()
        let modelID = RemoteSubscriptionModelID.modelID(fromLLMID: modelLLMID, prefix: "chatgpt")
        await onEvent(.modelLoaded(AgentRemoteProvider.chatGPTSubscriptionDisplayTitle + " · " + RemoteSubscriptionModelID.modelID(fromLLMID: modelLLMID, prefix: "chatgpt")))
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
        let reasoningEffort = session.thinkingSelection.flatMap {
            Self.chatGPTReasoningEffort(for: $0,
                catalogLevels: configuration.generationParameterOverrides.subscriptionReasoningLevels)
        }
        let maxContextWindowTokens = resolvedContextWindowTokenLimit()

        var accumulatedText = ""
        var generationStats: [RemoteGenerationStats] = []
        var retryState = TurnRetryState()

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
            retryState.lastRequestEstimate = .unmeasured
            let outputRelay = RemoteRoundOutputRelay()
            let roundEvents: @Sendable (DirectAgentEvent) async -> Void = { event in
                await outputRelay.forward(event, to: onEvent)
            }
            while true {
                try Task.checkCancellation()
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
                // each prompt carries the block of its own turn exactly once
                // per request. The content of a session message never holds
                // the block, so it never reaches history, snapshots or the
                // cache key.
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
                if try await applyPreflightCompaction(
                    to: &session,
                    estimate: requestEstimate,
                    attempts: &preflightCompactionAttempts,
                    retryState: &retryState,
                    maxContextWindowTokens: maxContextWindowTokens,
                    lease: lease,
                    onEvent: onEvent
                ) {
                    continue
                }
                retryState.lastRequestEstimate = requestEstimate
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
                        preservesCatalogReasoningEffort: configuration.generationParameterOverrides.subscriptionReasoningLevels != nil,
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
                            await roundEvents(event)
                        }
                    }
                } catch {
                    switch Self.streamFailureDecision(
                        for: error,
                        isCancelled: Task.isCancelled,
                        hasContinuationReplay: hasContinuationReplay,
                        streamInterruptionRetries: retryState.streamInterruptionRetries,
                        didRetryAfterContextLimit: retryState.didRetryAfterContextLimit
                    ) {
                    case .rethrow:
                        throw error
                    case .replayWithoutContinuation:
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
                    case let .retryInterruption(refreshCredentials):
                        // Force a refresh before rebuilding the client and
                        // retrying on the session's active transport.
                        if refreshCredentials {
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
                        retryState.streamInterruptionRetries += 1
                        guard mutateSession(for: lease, { session in
                            resetContinuationAndTransport(session: &session)
                        }) else {
                            throw ChatGPTSubscriptionGenerationError.missingSession
                        }
                        await onEvent(
                            .diagnostic(Self.streamInterruptionRetryDiagnostic())
                        )
                        continue
                    case .retryAfterContextLimit:
                        guard var latestSession = currentSession(for: lease),
                              let result = compactSessionForContextLimitRetry(
                                  &latestSession,
                                  maxTokens: maxContextWindowTokens,
                                  maxOutputTokens: configuration.maxOutputTokens,
                                  estimate: retryState.lastRequestEstimate
                              ) else {
                            await onEvent(.diagnostic(Self.contextLimitRetryUnavailableDiagnostic()))
                            throw error
                        }
                        retryState.didRetryAfterContextLimit = true
                        guard mutateSession(for: lease, { $0 = latestSession }) else {
                            throw ChatGPTSubscriptionGenerationError.missingSession
                        }
                        await onEvent(.diagnostic(Self.contextLimitRetryDiagnostic(from: result)))
                        continue
                    }
                }

                // A completed request establishes a fresh retry budget for the
                // next tool round; failures within one request remain bounded.
                retryState.streamInterruptionRetries = 0
                if completion.didActivateHTTPFallback {
                    await onEvent(.diagnostic(Self.httpFallbackDiagnostic()))
                }
                await streamAccumulator.recordCompletionResponseID(completion.responseID)
                let rawStreamResult: StreamAccumulatorResult
                do {
                    rawStreamResult = try await streamAccumulator.result()
                } catch RemoteGenerationClientError.invalidToolArguments {
                    // response.completed has already entered the pool's cache.
                    // Discard that transport even when the turn's retry is spent;
                    // only validated history may seed a subsequent request.
                    guard mutateSession(for: lease, { session in
                        resetContinuationAndTransport(session: &session)
                    }) else {
                        throw ChatGPTSubscriptionGenerationError.missingSession
                    }
                    try Task.checkCancellation()
                    guard !retryState.didRetryInvalidToolArguments else {
                        throw RemoteGenerationClientError.invalidToolArguments
                    }
                    retryState.didRetryInvalidToolArguments = true
                    await outputRelay.beginRetry()
                    await onEvent(.diagnostic(
                        "Invalid tool arguments received. Retrying this generation round once."
                    ))
                    continue
                }
                // Cancellation must be observed before, never after, committing
                // an assistant tool-call batch that requires matching results.
                try Task.checkCancellation()
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
                    await roundEvents(.content(streamResult.text))
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
                RemoteGenerationClient.appendRoundText(streamResult.text, to: &accumulatedText)

                if let cacheWarning = RemoteGenerationClient.promptCacheWarning(
                    provider: "ChatGPT",
                    usage: streamResult.usage,
                    expectsCacheRead: expectsPromptCache
                ) {
                    await onEvent(.diagnostic(cacheWarning))
                }

                try Task.checkCancellation()
                try commitAssistantRound(streamResult, instructions: instructions, lease: lease)

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

                try await RemoteToolBatchDispatcher.dispatch(
                    streamResult.toolCalls,
                    toolExecutor: toolExecutor,
                    currentSession: {
                        currentSession(for: lease).map { session in
                            RemoteToolDispatchSession(
                                sessionID: session.id,
                                workingDirectory: URL(fileURLWithPath: session.cwd),
                                allowedToolNames: session.allowedToolNames
                            )
                        }
                    },
                    // Results land after the committed assistant message, so
                    // the continuation delta carries a function_call_output for
                    // every call of the batch, including cancelled ones.
                    appendToolResults: { messages in
                        mutateSession(for: lease) { session in
                            session.messages.append(contentsOf: messages)
                        }
                    },
                    missingSessionError: ChatGPTSubscriptionGenerationError.missingSession,
                    onEvent: onEvent
                )

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

    /// Retry bookkeeping of one prompt turn.
    ///
    /// The flags and the interruption counter span every tool round of the
    /// turn; `streamInterruptionRetries` restarts after each completed request.
    /// `lastRequestEstimate` restarts with each round and describes the request
    /// most recently sent, which a context-limit retry compacts against.
    private struct TurnRetryState {
        var didRetryAfterContextLimit = false
        var didReportUnsatisfiableBudget = false
        var streamInterruptionRetries = 0
        var didRetryInvalidToolArguments = false
        var lastRequestEstimate = SubscriptionCompactionSupport.RequestEstimate.unmeasured
    }

    /// Runs the estimated-context preflight for the request about to be sent.
    ///
    /// - Returns: `true` when the session was compacted and the request must
    ///   be rebuilt from the compacted history.
    private func applyPreflightCompaction(
        to session: inout AgentSession,
        estimate: SubscriptionCompactionSupport.RequestEstimate,
        attempts: inout Int,
        retryState: inout TurnRetryState,
        maxContextWindowTokens: Int?,
        lease: SessionLease,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> Bool {
        guard attempts < AgentConversationCompactionPolicy.maximumPreflightCompactionAttempts else {
            return false
        }
        let outcome = compactSessionForEstimatedContextIfNeeded(
            &session,
            estimate: estimate,
            maxTokens: maxContextWindowTokens,
            maxOutputTokens: configuration.maxOutputTokens
        )
        switch outcome {
        case let .compacted(result):
            guard mutateSession(for: lease, { $0 = session }) else {
                throw ChatGPTSubscriptionGenerationError.missingSession
            }
            attempts += 1
            await onEvent(.diagnostic(Self.compactionDiagnostic(from: result)))
            return true
        case let .unsatisfiableBudget(
            contextWindowTokens,
            reservedOutputTokens,
            overheadTokens
        ):
            // Compaction cannot make this request fit at all. Say so once per
            // turn and let the provider answer or fail, instead of repeating a
            // pass that can never reach its target.
            if !retryState.didReportUnsatisfiableBudget {
                retryState.didReportUnsatisfiableBudget = true
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
            return false
        case .notNeeded:
            return false
        }
    }

    /// Commits a completed round's assistant message together with the
    /// continuation it establishes for the next request.
    private func commitAssistantRound(
        _ streamResult: StreamAccumulatorResult,
        instructions: String,
        lease: SessionLease
    ) throws {
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
