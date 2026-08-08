//
//  AnthropicSubscriptionGenerationClient+Streaming.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

import Foundation
import ToolCore

extension AnthropicSubscriptionGenerationClient {
    /// Streams one Anthropic request for the session owned by `lease`.
    ///
    /// The session is addressed through the lease rather than an `inout` copy
    /// so that a preflight compaction is persisted into the actor-owned
    /// session the moment it happens. A local copy would have been discarded by
    /// the caller, which only writes the assistant reply back, so the very next
    /// round (and every snapshot) would have replayed the uncompacted history.
    ///
    /// `applyTurnMemory` decides whether the turn's memory block is merged into
    /// the outgoing copy of the last user message; the caller enables it on
    /// every round of the tool loop. This function materialises the message
    /// array itself from the lease instead of receiving it from the caller, so
    /// the caller cannot apply the memory block on its side; the decision has
    /// to be passed in and honoured here. It must be forwarded unchanged
    /// through the preflight-compaction recursion below: that recursion
    /// re-issues the *same* round, so dropping the flag there would silently
    /// lose the block whenever a round happens to compact.
    func streamAnthropicMessages(
        lease: SessionLease,
        modelID: String,
        modelLLMID: String,
        credentials: AnthropicSubscriptionCredentials,
        includeThinkingBlocks: Bool = true,
        applyTurnMemory: Bool,
        preflightCompactionAttempt: Int = 0,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> RemoteStreamResult {
        guard let initialSession = currentSession(for: lease) else {
            throw RemoteGenerationClientError.missingSession
        }
        let toolDescriptors = await toolExecutor.descriptors(
            allowedToolNames: initialSession.allowedToolNames,
            preferredWorkspaceRootURL: initialSession.cwd,
            sessionID: initialSession.id
        )
        if configuration.verboseLogging {
            await onEvent(.diagnostic(RemoteStreamTransport.toolExposureDiagnostic(from: toolDescriptors)))
        }
        // Re-read after the tool-descriptor suspension: the actor may have
        // accepted a compaction or a new turn in the meantime.
        guard let session = currentSession(for: lease) else {
            throw RemoteGenerationClientError.missingSession
        }
        let toolCatalog = RemoteToolWireCatalog(descriptors: toolDescriptors)
        let thinkingEnabled = Self.supportsThinking(modelID: modelID)
            && (session.thinkingSelection?.isEnabled ?? false)
        let replayThinkingBlocks = thinkingEnabled && includeThinkingBlocks
        let expectsPromptCache = RemoteGenerationClient.messagesExpectPromptCache(
            session.messages
        )
        // The outgoing copy is the only thing that carries the memory block.
        // `session.messages` stays untouched, so the actor-owned history, every
        // snapshot taken from it, and the cache key are unaffected — and the
        // prompt-cache expectation above is measured against that unmodified
        // array on purpose.
        let outgoingMessages = applyTurnMemory
            ? RemoteGenerationClient.applyingCurrentTurnMemory(to: session.messages)
            : session.messages
        let anthropicPayload = Self.anthropicMessagesPayload(
            from: toolCatalog.wireMessages(from: outgoingMessages),
            includeThinkingBlocks: replayThinkingBlocks
        )
        let requestMessages = Self.addingCacheControlBreakpoints(
            anthropicPayload.messages
        )
        let systemBlocks = Self.subscriptionSystemBlocks(
            userSystemPrompt: anthropicPayload.system
        )
        let tools = Self.anthropicTools(from: toolCatalog.bindings)
        let maxOutputTokens = resolvedMaxOutputTokens(
            forLLMID: modelLLMID,
            thinkingSelection: session.thinkingSelection
        )
        let estimatedContextTokens = AnthropicSubscriptionRequestBuilder
            .estimatedContextTokenCount(
                system: systemBlocks,
                messages: requestMessages,
                tools: tools
            )
        // Split with a single estimator: the tool catalogue and the provider's
        // own system blocks are static, while JSON wrappers and escaping stay
        // attached to the conversation as a scale-free rate.
        let requestEstimate = Self.requestEstimate(
            estimatedContextTokens: estimatedContextTokens,
            tools: tools
        )
        // Remember what this request costs beyond the conversation itself, so a
        // context-limit retry can subtract the real tool/system overhead. The
        // outgoing copy is used deliberately: the estimate above was measured
        // from that same array, so pairing it with the unmodified history would
        // charge the memory block to the static overhead and inflate the cached
        // reservation for every later round of the turn.
        recordRequestOverhead(
            estimate: requestEstimate,
            messages: outgoingMessages,
            for: lease
        )
        // Bounded: each successful compaction is guaranteed to shrink the
        // prompt, and the attempt cap keeps a pathological overhead estimate
        // (huge tool catalogue, oversized output reservation) from recursing.
        if preflightCompactionAttempt
            < AgentConversationCompactionPolicy.maximumPreflightCompactionAttempts {
            switch compactSessionForEstimatedContextIfNeeded(
                lease: lease,
                estimate: requestEstimate,
                modelLLMID: modelLLMID,
                maxOutputTokens: maxOutputTokens
            ) {
            case let .compacted(result):
                await onEvent(.diagnostic(Self.compactionDiagnostic(from: result)))
                return try await streamAnthropicMessages(
                    lease: lease,
                    modelID: modelID,
                    modelLLMID: modelLLMID,
                    credentials: credentials,
                    includeThinkingBlocks: includeThinkingBlocks,
                    applyTurnMemory: applyTurnMemory,
                    preflightCompactionAttempt: preflightCompactionAttempt + 1,
                    onEvent: onEvent
                )
            case let .unsatisfiableBudget(
                contextWindowTokens,
                reservedOutputTokens,
                overheadTokens
            ):
                // No conversation fits next to this reservation, so compaction
                // is skipped explicitly and the provider outcome is surfaced
                // instead of recursing towards an unreachable target. The
                // subsequent context-limit retry rebuilds this stream, so only
                // the first preflight of the user turn may publish the reason.
                if claimUnsatisfiableBudgetDiagnostic(for: lease) {
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

        var body: [String: Any] = [
            "model": modelID,
            "messages": requestMessages,
            "max_tokens": maxOutputTokens,
            "stream": true
        ]
        body["system"] = systemBlocks
        if !tools.isEmpty {
            body["tools"] = tools
        }
        applyThinkingSelection(
            session.thinkingSelection,
            to: &body,
            modelLLMID: modelLLMID
        )

        let requestBody = try JSONValue(
            jsonObject: AnthropicSubscriptionRequestBuilder.sanitizedPayload(body)
        ).jsonData(
            outputFormatting: [.withoutEscapingSlashes]
        )
        let request = RemoteHTTPStreamingRequest(
            url: messagesEndpointURLOverride
                ?? Self.apiBaseURL.appendingPathComponent("messages"),
            method: "POST",
            headers: [
                RemoteHTTPHeader(name: "Content-Type", value: "application/json"),
                RemoteHTTPHeader(name: "Accept", value: "application/json"),
                RemoteHTTPHeader(name: "anthropic-version", value: "2023-06-01"),
                RemoteHTTPHeader(
                    name: "anthropic-beta",
                    value: Self.oauthBetaHeader(forModelID: modelID)
                ),
                RemoteHTTPHeader(
                    name: "anthropic-dangerous-direct-browser-access",
                    value: "true"
                ),
                RemoteHTTPHeader(
                    name: "Authorization",
                    value: "Bearer \(credentials.accessToken)"
                ),
                RemoteHTTPHeader(
                    name: "User-Agent",
                    value: "claude-cli/\(Self.claudeCodeVersion)"
                ),
                RemoteHTTPHeader(name: "x-app", value: "cli")
            ],
            body: requestBody,
            timeout: .seconds(900)
        )

        if !configuration.appMode {
            await onEvent(.diagnostic("Remote request: \(provider.displayTitle) \(modelID)."))
        }

        let requestStartedAt = Date()
        // Deliberately no retry here. Unlike the OpenAI-compatible path,
        // Anthropic subscription messages historically never replayed a
        // request. An OAuth POST can be accepted by the service even if a
        // response head is lost, so adding a pre-head replay would risk
        // duplicate generation/tool transactions without an idempotency key.
        let response = try await transport.openHTTPStream(request)
        try await Self.validateHTTPResponse(response)

        if let subscriptionUsage = Self.subscriptionUsage(fromHeaders: response.headers) {
            await onEvent(.subscriptionUsage(subscriptionUsage))
        }

        var accumulatedText = ""
        var stopReason = "end_turn"
        var firstDeltaAt: Date?
        var usage: RemoteGenerationUsage?
        var contentNormalizer = ThinkingBoundarySpacingNormalizer()
        var toolAccumulator = AnthropicToolUseAccumulator()
        var thinkingAccumulator = AnthropicThinkingBlockAccumulator()

        func markFirstDelta() {
            if firstDeltaAt == nil {
                firstDeltaAt = Date()
            }
        }

        for try await event in response.body.sseEvents() {
            try Task.checkCancellation()
            let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard payload != "[DONE]",
                  let object = RemoteStreamTransport.jsonObject(from: payload) else {
                continue
            }

            let type = Self.stringValue(object["type"])?.lowercased() ?? ""
            switch type {
            case "message_start":
                if let message = object["message"] as? [String: Any],
                   let remoteUsage = Self.usage(from: message["usage"]) {
                    usage = remoteUsage
                }
            case "content_block_start":
                markFirstDelta()
                toolAccumulator.ingestContentBlockStart(object)
                thinkingAccumulator.ingestContentBlockStart(object)
                if let text = Self.contentBlockText(from: object), !text.isEmpty {
                    let normalizedDelta = contentNormalizer.append(text)
                    if !normalizedDelta.isEmpty {
                        accumulatedText.append(normalizedDelta)
                        await onEvent(.content(normalizedDelta))
                    }
                }
            case "content_block_delta":
                markFirstDelta()
                if let index = JSONValue.intValue(fromJSONObject: object["index"]),
                   let delta = object["delta"] as? [String: Any] {
                    thinkingAccumulator.ingestDelta(index: index, delta: delta)
                    let deltaType = Self.stringValue(delta["type"])?.lowercased() ?? ""
                    switch deltaType {
                    case "text_delta":
                        let text = Self.stringValue(delta["text"]) ?? ""
                        let normalizedDelta = contentNormalizer.append(text)
                        if !normalizedDelta.isEmpty {
                            accumulatedText.append(normalizedDelta)
                            await onEvent(.content(normalizedDelta))
                        }
                    case "thinking_delta":
                        let thinking = Self.stringValue(delta["thinking"]) ?? ""
                        if !thinking.isEmpty {
                            await onEvent(.thought(thinking))
                        }
                    case "input_json_delta":
                        toolAccumulator.ingestInputJSONDelta(
                            index: index,
                            partialJSON: Self.stringValue(delta["partial_json"]) ?? ""
                        )
                    default:
                        break
                    }
                }
            case "message_delta":
                if let delta = object["delta"] as? [String: Any],
                   let reason = Self.stringValue(delta["stop_reason"])?.nilIfBlank {
                    stopReason = reason
                }
                if let remoteUsage = Self.usage(from: object["usage"], previous: usage) {
                    usage = remoteUsage
                }
            case "error":
                throw RemoteGenerationClientError.remoteFailure(
                    Self.errorMessage(from: object) ?? "Anthropic Subscription request failed."
                )
            default:
                break
            }
        }

        let normalizedRemainder = contentNormalizer.finish()
        if !normalizedRemainder.isEmpty {
            markFirstDelta()
            accumulatedText.append(normalizedRemainder)
            await onEvent(.content(normalizedRemainder))
        }

        if configuration.verboseLogging,
           let cacheDiagnostic = RemoteGenerationClient.cacheUsageDiagnostic(
               provider: "Anthropic",
               usage: usage
           ) {
            await onEvent(.diagnostic(cacheDiagnostic))
        }
        if let cacheWarning = RemoteGenerationClient.promptCacheWarning(
            provider: "Anthropic",
            usage: usage,
            expectsCacheRead: expectsPromptCache
        ) {
            await onEvent(.diagnostic(cacheWarning))
        }

        let toolCalls = toolAccumulator.finalize().map(toolCatalog.localToolCall)
        let thinkingBlocks = thinkingAccumulator.finalize()
        let thinkingBlocksJSON: String?
        if thinkingBlocks.isEmpty {
            thinkingBlocksJSON = nil
        } else if let data = try? JSONValue(jsonObject: thinkingBlocks).jsonData(
            outputFormatting: [.withoutEscapingSlashes]
        ) {
            thinkingBlocksJSON = String(decoding: data, as: UTF8.self)
        } else {
            thinkingBlocksJSON = nil
        }
        return RemoteStreamResult(
            text: accumulatedText,
            stopReason: toolCalls.isEmpty ? stopReason : "tool_calls",
            toolCalls: toolCalls,
            stats: RemoteGenerationStats(
                usage: usage,
                requestStartedAt: requestStartedAt,
                firstDeltaAt: firstDeltaAt,
                finishedAt: Date(),
                generatedCharacterCount: accumulatedText.count
            ),
            assistantThinkingBlocksJSON: thinkingBlocksJSON
        )
    }
}
