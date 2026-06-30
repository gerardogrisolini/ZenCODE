//
//  AnthropicSubscriptionGenerationClient+Streaming.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//
#if os(macOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

extension AnthropicSubscriptionGenerationClient {
    func streamAnthropicMessages(
        session: inout AgentSession,
        modelID: String,
        modelLLMID: String,
        credentials: AnthropicSubscriptionCredentials,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> RemoteStreamResult {
        let toolDescriptors = await toolExecutor.descriptors(
            allowedToolNames: session.allowedToolNames,
            preferredWorkspaceRootURL: session.cwd
        )
        if configuration.verboseLogging {
            await onEvent(.diagnostic(RemoteGenerationClient.toolExposureDiagnostic(from: toolDescriptors)))
        }
        let toolCatalog = RemoteToolWireCatalog(descriptors: toolDescriptors)
        let thinkingEnabled = Self.supportsThinking(modelID: modelID)
            && (session.thinkingSelection?.isEnabled ?? false)
        let expectsPromptCache = RemoteGenerationClient.messagesExpectPromptCache(
            session.messages
        )
                let anthropicPayload = Self.anthropicMessagesPayload(
            from: toolCatalog.wireMessages(from: session.messages),
            includeThinkingBlocks: thinkingEnabled
        )
                let requestMessages = Self.addingCacheControlToLastUserMessage(
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

        var request = URLRequest(url: Self.apiBaseURL.appendingPathComponent("messages"))
        request.httpMethod = "POST"
        request.timeoutInterval = 900
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue(
            Self.oauthBetaHeader(forModelID: modelID),
            forHTTPHeaderField: "anthropic-beta"
        )
        request.setValue("true", forHTTPHeaderField: "anthropic-dangerous-direct-browser-access")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("claude-cli/\(Self.claudeCodeVersion)", forHTTPHeaderField: "User-Agent")
        request.setValue("cli", forHTTPHeaderField: "x-app")
        request.httpBody = try JSONValue(
            jsonObject: AnthropicSubscriptionRequestBuilder.sanitizedPayload(body)
        ).jsonData(
            outputFormatting: [.withoutEscapingSlashes]
        )

        if !configuration.appMode {
            await onEvent(.diagnostic("Remote request: \(provider.displayTitle) \(modelID)."))
        }

        let requestStartedAt = Date()
        let (bytes, response) = try await urlSession.bytes(for: request)
        try await Self.validateHTTPResponse(response, bytes: bytes)

        if let subscriptionUsage = Self.subscriptionUsage(fromHTTPResponse: response) {
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

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let payload = RemoteGenerationClient.ssePayload(from: line),
                  payload != "[DONE]",
                  let object = RemoteGenerationClient.jsonObject(from: payload) else {
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

#endif
