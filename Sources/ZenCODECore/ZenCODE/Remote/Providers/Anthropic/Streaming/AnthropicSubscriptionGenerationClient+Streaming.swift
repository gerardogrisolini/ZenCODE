//
//  AnthropicSubscriptionGenerationClient+Streaming.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//

import Foundation

extension AnthropicSubscriptionGenerationClient {
    func streamAnthropicMessages(
        session: inout AgentSession,
        modelID: String,
        modelLLMID: String,
        credentials: AnthropicSubscriptionCredentials,
        includeThinkingBlocks: Bool = true,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> RemoteStreamResult {
        let toolDescriptors = await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd,
            sessionID: session.id
        )
        if configuration.verboseLogging {
            await onEvent(.diagnostic(RemoteStreamTransport.toolExposureDiagnostic(from: toolDescriptors)))
        }
        let toolCatalog = RemoteToolWireCatalog(descriptors: toolDescriptors)
        let thinkingEnabled = Self.supportsThinking(modelID: modelID)
            && (session.thinkingSelection?.isEnabled ?? false)
        let replayThinkingBlocks = thinkingEnabled && includeThinkingBlocks
        let expectsPromptCache = RemoteGenerationClient.messagesExpectPromptCache(
            session.messages
        )
        let anthropicPayload = Self.anthropicMessagesPayload(
            from: toolCatalog.wireMessages(from: session.messages),
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
        if let result = compactSessionForEstimatedContextIfNeeded(
            &session,
            estimatedContextTokens: estimatedContextTokens,
            modelLLMID: modelLLMID,
            maxOutputTokens: maxOutputTokens
        ) {
            await onEvent(.diagnostic(Self.compactionDiagnostic(from: result)))
            return try await streamAnthropicMessages(
                session: &session,
                modelID: modelID,
                modelLLMID: modelLLMID,
                credentials: credentials,
                includeThinkingBlocks: includeThinkingBlocks,
                onEvent: onEvent
            )
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
                if let index = Self.intValue(object["index"]),
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
