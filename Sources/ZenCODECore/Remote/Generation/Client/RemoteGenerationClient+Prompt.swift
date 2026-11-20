//
//  RemoteGenerationClient+Prompt.swift
//  ZenCODE
//
//  The prompt loop of RemoteGenerationClient: generation rounds, tool
//  execution and history updates until the model ends the turn.
//

import Foundation
import ToolCore

extension RemoteGenerationClient {
    public func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        if sessions[sessionID] == nil {
            guard !MemoryConsolidationContext.isIsolated else { throw CancellationError() }
            createSession(id: sessionID, cwd: configuration.workingDirectory.path)
        }
        guard var session = sessions[sessionID] else {
            throw RemoteGenerationClientError.missingSession
        }

        // The turn's memory block and instruction are recorded on the prompt,
        // so every later request sends it again as it was first sent. The
        // in-process DS4 path records them as well, for a history that is the
        // same under every provider; it renders from its own frozen content
        // (`DS4MessageKeys.userContent`) and freezes it again from this
        // record in a session created from its history.
        session.messages.append(
            Self.recordingTurnAddition(
                on: Self.remoteMessage(
                    role: "user",
                    content: prompt,
                    attachments: attachments
                )
            )
        )
        // Persist immediately so concurrent actor operations (compaction,
        // option updates) observe and build on the latest messages instead of
        // being silently overwritten by the local copy at the end of the loop.
        sessions[sessionID] = session
        guard let lease = sessionLease(for: sessionID) else {
            throw RemoteGenerationClientError.missingSession
        }

        _ = try await preloadModel(onEvent: onEvent)
        guard currentSession(for: lease) != nil else {
            throw RemoteGenerationClientError.missingSession
        }

        var accumulatedText = ""
        var generationStats: [RemoteGenerationStats] = []
        var didRetryWithoutImages = false
        var didRetryInvalidToolArguments = false
        var didRetryAfterContextLimit = false
        for round in 0..<configuration.maxToolRounds {
            // Re-read shared state at the start of each round so changes applied
            // by concurrent operations between rounds are not lost.
            guard let session = currentSession(for: lease) else {
                throw RemoteGenerationClientError.missingSession
            }
            var expectsPromptCache = Self.messagesExpectPromptCache(session.messages)
            // Every tool round rebuilds the outgoing payload from the fresh
            // value of `session.messages`, so each prompt carries the memory
            // block of its own turn on each round's request — exactly once,
            // because the block is never written into the content of a
            // session message. That keeps it out of the conversation text and
            // the cache key; the prompt-cache expectation above is
            // deliberately computed from the unmodified array. A compaction in
            // this round rewrites the prompt prefix, so it clears the expectation.
            let outputRelay = RemoteRoundOutputRelay()
            let roundEvents: @Sendable (DirectAgentEvent) async -> Void = { event in
                await outputRelay.forward(event, to: onEvent)
            }
            // The preflight may compact a bounded number of times per round.
            var preflightCompactionAttempts = 0
            let streamResult: RemoteStreamResult
            while true {
                try Task.checkCancellation()
                if ds4Generation == nil,
                   let result = try compactSessionBeforeRequest(
                       lease: lease,
                       attempts: &preflightCompactionAttempts
                   ) {
                    expectsPromptCache = false
                    await onEvent(.diagnostic(
                        SubscriptionCompactionSupport.compactionDiagnostic(from: result)
                    ))
                }
                guard let activeSession = currentSession(for: lease) else {
                    throw RemoteGenerationClientError.missingSession
                }
                let outgoingMessages = Self.applyingCurrentTurnMemory(to: activeSession.messages)
                do {
                    if let ds4Generation {
                        // The DS4 path renders its own prompt from the
                        // session (it persists the current-turn memory and
                        // may compact), so it takes the lease, not a copy.
                        streamResult = try await streamDS4Engine(
                            ds4Generation,
                            lease: lease,
                            onEvent: roundEvents
                        )
                    } else if provider.protocolProfileID == .anthropicMessages {
                        streamResult = try await streamAnthropicMessages(
                            messages: outgoingMessages,
                            sessionID: session.id,
                            allowedToolNames: session.allowedToolNames,
                            preferredWorkspaceRootURL: session.cwd,
                            thinkingSelection: session.thinkingSelection,
                            onEvent: roundEvents
                        )
                    } else {
                        switch provider.chatEndpoint {
                        case .chatCompletions:
                            streamResult = try await streamChatCompletions(
                                messages: outgoingMessages,
                                sessionID: session.id,
                                allowedToolNames: session.allowedToolNames,
                                preferredWorkspaceRootURL: session.cwd,
                                thinkingSelection: session.thinkingSelection,
                                onEvent: roundEvents
                            )
                        case .responses:
                            streamResult = try await streamResponses(
                                messages: outgoingMessages,
                                sessionID: session.id,
                                allowedToolNames: session.allowedToolNames,
                                preferredWorkspaceRootURL: session.cwd,
                                thinkingSelection: session.thinkingSelection,
                                onEvent: roundEvents
                            )
                        }
                    }
                    // Calibrated against the session array this request was
                    // built from; the outgoing copy also carries the turn memory.
                    recordContextCalibration(
                        for: lease,
                        messages: activeSession.messages,
                        usage: streamResult.stats.usage
                    )
                    break
                } catch {
                    try Task.checkCancellation()
                    guard currentSession(for: lease) != nil else {
                        throw RemoteGenerationClientError.missingSession
                    }
                    if case RemoteGenerationClientError.invalidToolArguments = error,
                       !didRetryInvalidToolArguments {
                        didRetryInvalidToolArguments = true
                        await outputRelay.beginRetry()
                        await onEvent(.diagnostic(
                            "Invalid tool arguments received. Retrying this generation round once."
                        ))
                        continue
                    }
                    if !didRetryWithoutImages,
                       Self.isImageContentRejectedError(error),
                       Self.messagesContainImageContent(session.messages) {
                        didRetryWithoutImages = true
                        guard mutateSession(for: lease, { session in
                            session.messages = Self.messagesStrippingImageContent(
                                from: session.messages
                            )
                        }) else {
                            throw RemoteGenerationClientError.missingSession
                        }
                        // Stripped images change what the provider counts.
                        contextCalibrationBySessionID[lease.id] = nil
                        await onEvent(.diagnostic(
                            "\(provider.displayTitle) does not support image input with the selected model. Retrying without attached images."
                        ))
                        continue
                    }
                    if ds4Generation == nil,
                       !didRetryAfterContextLimit,
                       Self.isContextLimitRejection(error) {
                        // One retry per turn: the provider refused the prompt
                        // for its length, so a second refusal is surfaced.
                        didRetryAfterContextLimit = true
                        guard let result = try compactSessionForContextLimitRetry(lease: lease) else {
                            await onEvent(.diagnostic(
                                SubscriptionCompactionSupport.contextLimitRetryUnavailableDiagnostic(
                                    provider: provider.displayTitle
                                )
                            ))
                            throw error
                        }
                        expectsPromptCache = false
                        await outputRelay.beginRetry()
                        await onEvent(.diagnostic(
                            SubscriptionCompactionSupport.contextLimitRetryDiagnostic(
                                provider: provider.displayTitle,
                                from: result
                            )
                        ))
                        continue
                    }
                    throw error
                }
            }

            try Task.checkCancellation()
            guard currentSession(for: lease) != nil else {
                throw RemoteGenerationClientError.missingSession
            }
            Self.appendRoundText(streamResult.text, to: &accumulatedText)
            generationStats.append(streamResult.stats)
            if let cacheWarning = Self.promptCacheWarning(
                provider: provider.displayTitle,
                usage: streamResult.stats.usage,
                expectsCacheRead: expectsPromptCache
            ) {
                await onEvent(.diagnostic(cacheWarning))
            }
            try Task.checkCancellation()
            guard mutateSession(for: lease, { session in
                appendAssistantMessage(
                    streamResult: streamResult,
                    to: &session.messages
                )
            }) else {
                throw RemoteGenerationClientError.missingSession
            }
            if let metrics = Self.generationMetrics(generationStats) {
                await Self.publishGenerationMetrics(
                    metrics,
                    maxTokens: streamResult.ds4Turn?.contextSize ?? configuration.configuredContextWindowLimit,
                    modelID: provider.modelID,
                    isApproximate: streamResult.ds4Turn == nil,
                    onEvent: onEvent
                )
            }

            if streamResult.toolCalls.isEmpty, streamResult.ds4Turn?.toolObservation != nil {
                // Malformed DS4 tool call: the observation is already in the
                // assistant message; the model retries in a new round.
                if round == configuration.maxToolRounds - 1 {
                    throw RemoteGenerationClientError.tooManyToolRounds(configuration.maxToolRounds)
                }
                continue
            }

            if streamResult.toolCalls.isEmpty {
                if !configuration.appMode,
                   let summary = Self.generationSummary(generationStats) {
                    await onEvent(.diagnostic(summary))
                }
                return DirectAgentResponse(
                    text: accumulatedText,
                    stopReason: streamResult.stopReason,
                    modelID: provider.modelID
                )
            }

            try await RemoteToolBatchDispatcher.dispatch(
                streamResult.toolCalls,
                toolExecutor: toolExecutor,
                currentSession: {
                    currentSession(for: lease).map { session in
                        RemoteToolDispatchSession(
                            sessionID: session.id,
                            workingDirectory: session.cwd,
                            allowedToolNames: session.allowedToolNames
                        )
                    }
                },
                appendToolResults: { messages in
                    mutateSession(for: lease) { session in
                        session.messages.append(contentsOf: messages)
                    }
                },
                missingSessionError: RemoteGenerationClientError.missingSession,
                onEvent: onEvent
            )

            if round == configuration.maxToolRounds - 1 {
                throw RemoteGenerationClientError.tooManyToolRounds(configuration.maxToolRounds)
            }
        }
        throw RemoteGenerationClientError.tooManyToolRounds(configuration.maxToolRounds)
    }
}
