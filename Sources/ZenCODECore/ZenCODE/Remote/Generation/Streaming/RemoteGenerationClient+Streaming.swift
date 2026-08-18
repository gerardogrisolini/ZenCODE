//
//  RemoteGenerationClient+Streaming.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/07/26.
//

import Foundation

extension RemoteGenerationClient {

    // MARK: - Configuration helpers

    public func validateConfiguration() throws {
        guard URL(string: provider.baseURL) != nil else {
            throw RemoteGenerationClientError.invalidBaseURL(provider.baseURL)
        }
        if provider.requiresAPIKey, apiKey == nil {
            throw RemoteGenerationClientError.missingAPIKey(provider.displayTitle)
        }
    }

    public func applyThinkingSelection(
        _ thinkingSelection: AgentThinkingSelection?,
        endpoint: AgentRemoteChatEndpoint,
        to body: inout [String: Any]
    ) {
        guard let thinkingSelection else {
            return
        }
        /* The persisted manifest is the only authorization source: when it
         declares the model's thinking options, only those selections may be
         serialized. The generic `.enabled` selection stays authorized when
         any effort level is allowed, because the effort dialects map it to
         the closest supported level below. An empty declaration means the
         capability is unknown (e.g. fallback providers without a manifest),
         so the payload is sent as-is instead of being silently dropped. */
        if !thinkingOptions.isEmpty {
            let isAuthorized = thinkingOptions.contains(thinkingSelection)
                || (thinkingSelection == .enabled && thinkingOptions.contains { $0.isEnabled })
            guard isAuthorized else {
                return
            }
        }
        switch thinkingPayloadStyle {
        case .none:
            return
        case .chatTemplateKwargs:
            var kwargs: [String: Any] = [
                "enable_thinking": thinkingSelection.isEnabled,
                "thinking": thinkingSelection.isEnabled
            ]
            if let effort = thinkingSelection.chatTemplateReasoningEffort {
                kwargs["reasoning_effort"] = effort
            }
            body["chat_template_kwargs"] = kwargs
        case .openRouterReasoning:
            var payload = thinkingSelection.openRouterReasoningPayload
            /* The Responses API only streams reasoning summaries when the
             client opts in via `reasoning.summary`. Without it, providers
             such as ds4-server generate reasoning but suppress it from the
             stream, so no thinking is visible in chat. "auto" matches the
             spec's default verbosity. */
            if endpoint == .responses && thinkingSelection.isEnabled {
                payload["summary"] = "auto"
            }
            body["reasoning"] = payload
        case .openAIResponsesReasoning:
            if thinkingSelection == .off {
                body["reasoning"] = ["effort": "none"]
                return
            }
            body["reasoning"] = [
                "effort": resolvedEffortSelection(thinkingSelection).rawValue,
                "summary": "auto"
            ]
        case .reasoningEffort:
            if thinkingSelection == .off {
                body["reasoning_effort"] = "none"
                return
            }
            body["reasoning_effort"] = resolvedEffortSelection(thinkingSelection).rawValue
        case let .thinkingObject(supportsDisable, keepAll):
            guard thinkingSelection.isEnabled || supportsDisable else {
                return
            }
            var thinking: [String: Any] = [
                "type": thinkingSelection.isEnabled ? "enabled" : "disabled"
            ]
            if thinkingSelection.isEnabled, keepAll {
                thinking["keep"] = "all"
            }
            body["thinking"] = thinking
        }
    }

    /* When the manifest options are known but only carry effort levels
     (no `.enabled`), the generic "thinking on" selection is mapped to the
     closest allowed effort. With unknown (empty) options, or when `.enabled`
     is itself a documented option, the selection passes through untouched.
     This mirrors the pre-52428e3 behavior where `.enabled` resolved to
     `.max`/`.medium` before serializing. */
    private func resolvedEffortSelection(
        _ thinkingSelection: AgentThinkingSelection
    ) -> AgentThinkingSelection {
        guard thinkingSelection == .enabled,
              thinkingOptions.contains(.enabled) == false,
              !thinkingOptions.isEmpty else {
            return thinkingSelection
        }
        if thinkingOptions.contains(.max) {
            return .max
        }
        if thinkingOptions.contains(.medium) {
            return .medium
        }
        return thinkingOptions.first { $0.isEnabled } ?? thinkingSelection
    }

    public var thinkingPayloadStyle: AgentThinkingPayloadStyle {
        switch (provider.providerProfileID, provider.protocolProfileID) {
        case (.openRouter, .openAIChatCompletions), (.openRouter, .openAIResponses):
            return .openRouterReasoning
        case (.openAI, .openAIResponses):
            return .openAIResponsesReasoning
        case (.openAI, .openAIChatCompletions),
             (.zAI, .openAIChatCompletions), (.zAI, .zaiCodingPlan),
             (.googleGemini, .openAIChatCompletions),
             (.moonshot, .openAIChatCompletions):
            return .reasoningEffort
        case (.deepSeek, .openAIChatCompletions):
            // The provider dialect can express disable, but only models whose
            // persisted capability explicitly includes `.off` may use it.
            return .thinkingObject(
                supportsDisable: thinkingOptions.contains(.off),
                keepAll: false
            )
        case (.nvidia, .openAIChatCompletions), (.modal, .openAIChatCompletions):
            return .chatTemplateKwargs
        default:
            return .none
        }
    }

    public var chatCompletionsReplayPolicy: AgentChatCompletionsReplayPolicy {
        if provider.providerProfileID == .moonshot,
           provider.protocolProfileID == .openAIChatCompletions {
            return .preserveAllAssistantReasoning
        }
        if provider.providerProfileID == .deepSeek,
           provider.protocolProfileID == .openAIChatCompletions {
            return .currentToolRound(requiresPlaceholder: true)
        }
        return .stripReasoning
    }

    public var isKimiChatCompletions: Bool {
        guard provider.providerProfileID == .moonshot,
              provider.protocolProfileID == .openAIChatCompletions else {
            return false
        }
        return true
    }

    /// Chat Completions models that reject the legacy `max_tokens` parameter
    /// and only accept `max_completion_tokens`: Kimi documents it directly,
    /// and OpenAI reasoning models reject `max_tokens` outright.
    public var chatCompletionsMaxTokensParameter: String {
        if isKimiChatCompletions {
            return "max_completion_tokens"
        }
        guard provider.providerProfileID == .openAI,
              provider.protocolProfileID == .openAIChatCompletions else {
            return "max_tokens"
        }
        return !thinkingOptions.isEmpty
            ? "max_completion_tokens"
            : "max_tokens"
    }

    /// Whether the provider requires reasoning replay metadata on `/responses`.
    public var shouldSendResponsesReplayMetadata: Bool {
        provider.protocolProfileID == .openAIResponses
            && (provider.providerProfileID == .openAI || provider.providerProfileID == .openRouter)
    }

    public func applyStructuredOutputFormat(
        to body: inout [String: Any],
        endpoint: AgentRemoteChatEndpoint
    ) {
        guard let structuredOutput = configuration
            .generationParameterOverrides
            .structuredOutput?
            .nilIfEmpty else {
            return
        }

        switch endpoint {
        case .chatCompletions:
            if let responseFormat = structuredOutput.chatCompletionsResponseFormatPayload {
                body["response_format"] = responseFormat
            }
        case .responses:
            guard let format = structuredOutput.responsesTextFormatPayload else {
                return
            }
            var text = body["text"] as? [String: Any] ?? [:]
            text["format"] = format
            body["text"] = text
        }
    }

    public static func validateRemoteToolPayloads(
        bindings: [RemoteToolWireCatalog.Binding],
        endpoint: AgentRemoteChatEndpoint
    ) throws {
        let invalidNames = bindings.compactMap { binding -> String? in
            switch endpoint {
            case .chatCompletions:
                return binding.chatCompletionToolPayload == nil
                    ? binding.descriptor.name
                    : nil
            case .responses:
                return binding.responsesToolPayload == nil
                    ? binding.descriptor.name
                    : nil
            }
        }

        guard invalidNames.isEmpty else {
            throw RemoteGenerationClientError.invalidRequestPayload(
                "Cannot expose remote tools with invalid JSON schemas: \(invalidNames.sorted().joined(separator: ", "))."
            )
        }
    }

    func remoteToolCatalog(
        allowedToolNames: Set<String>?,
        preferredWorkspaceRootURL: URL?,
        sessionID: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async -> RemoteToolWireCatalog {
        let descriptors = await toolExecutor.descriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL,
            sessionID: sessionID
        )
        if configuration.verboseLogging {
            await onEvent(.diagnostic(
                RemoteStreamTransport.toolExposureDiagnostic(from: descriptors)
            ))
        }
        return RemoteToolWireCatalog(descriptors: descriptors)
    }

    // MARK: - Chat Completions

    public func streamChatCompletions(
        messages: [[String: Any]],
        sessionID: String,
        allowedToolNames: Set<String>?,
        preferredWorkspaceRootURL: URL? = nil,
        thinkingSelection: AgentThinkingSelection?,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> RemoteStreamResult {
        let toolCatalog = await remoteToolCatalog(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL,
            sessionID: sessionID,
            onEvent: onEvent
        )
        let sanitizedMessages = Self.chatCompletionsWireHistoryMessages(
            from: messages,
            replayPolicy: chatCompletionsReplayPolicy
        )
        let wireMessages = Self.chatCompletionsMessagesExpandingToolImages(
            from: toolCatalog.wireMessages(from: sanitizedMessages)
        )
        var body: [String: Any] = [
            "model": provider.modelID,
            "messages": wireMessages,
            "stream": true,
            "stream_options": [
                "include_usage": true
            ]
        ]
        applyThinkingSelection(thinkingSelection, endpoint: .chatCompletions, to: &body)
        applyStructuredOutputFormat(to: &body, endpoint: .chatCompletions)
        if isKimiChatCompletions {
            body["prompt_cache_key"] = sessionID
        } else if provider.chatEndpoint.usesSessionID
            || provider.providerProfileID == .openRouter {
            body["session_id"] = sessionID
        }
        let toolPayloads = toolCatalog.chatCompletionToolPayloads
        try Self.validateRemoteToolPayloads(
            bindings: toolCatalog.bindings,
            endpoint: .chatCompletions
        )
        if !toolPayloads.isEmpty {
            body["tools"] = toolPayloads
            body["tool_choice"] = "auto"
        }
        if let maxTokens = configuration.maxOutputTokens {
            body[chatCompletionsMaxTokensParameter] = maxTokens
        }

        let result = try await streamRequest(
            path: provider.chatEndpoint.path,
            body: body,
            onEvent: onEvent,
            eventParser: ChatCompletionsStreamParser.parse
        )
        return RemoteStreamResult(
            text: result.text,
            reasoningText: result.reasoningText,
            stopReason: result.stopReason,
            toolCalls: result.toolCalls.map(toolCatalog.localToolCall),
            stats: result.stats
        )
    }

    // MARK: - Responses

    public func streamResponses(
        messages: [[String: Any]],
        sessionID: String,
        allowedToolNames: Set<String>?,
        preferredWorkspaceRootURL: URL? = nil,
        thinkingSelection: AgentThinkingSelection?,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> RemoteStreamResult {
        let toolCatalog = await remoteToolCatalog(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL,
            sessionID: sessionID,
            onEvent: onEvent
        )
        let normalizedInput = try Self.validatedResponsesInputPayload(
            from: toolCatalog.wireMessages(from: messages)
        )
        var body: [String: Any] = [
            "model": provider.modelID,
            "input": normalizedInput.input,
            "stream": true
        ]
        if shouldSendResponsesReplayMetadata {
            body["store"] = false
            body["include"] = [
                "reasoning.encrypted_content"
            ]
            body["prompt_cache_key"] = sessionID
        }
        if let instructions = normalizedInput.instructions {
            body["instructions"] = instructions
        }
        applyThinkingSelection(thinkingSelection, endpoint: .responses, to: &body)
        applyStructuredOutputFormat(to: &body, endpoint: .responses)
        if provider.chatEndpoint.usesSessionID
            || provider.providerProfileID == .openRouter {
            body["session_id"] = sessionID
        }
        let toolPayloads = toolCatalog.responsesToolPayloads
        try Self.validateRemoteToolPayloads(
            bindings: toolCatalog.bindings,
            endpoint: .responses
        )
        if !toolPayloads.isEmpty {
            body["tools"] = toolPayloads
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = true
        }
        if let maxTokens = configuration.maxOutputTokens {
            body["max_output_tokens"] = maxTokens
        }

        let result = try await streamRequest(
            path: provider.chatEndpoint.path,
            body: body,
            onEvent: onEvent,
            eventParser: ResponsesStreamParser.parse
        )
        return RemoteStreamResult(
            text: result.text,
            reasoningText: result.reasoningText,
            stopReason: result.stopReason,
            toolCalls: result.toolCalls.map(toolCatalog.localToolCall),
            stats: result.stats,
            reasoningItemsJSON: result.reasoningItemsJSON
        )
    }

    // MARK: - Stream transport + accumulation

    public func streamRequest(
        path: String,
        body: [String: Any],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void,
        eventParser: @escaping ([String: Any]) -> [ParsedRemoteStreamEvent]
    ) async throws -> RemoteStreamResult {
        let request = try RemoteStreamTransport.buildHTTPStreamingRequest(
            path: path,
            body: body,
            provider: provider,
            apiKey: apiKey,
            endpointBaseURLOverride: streamEndpointBaseURLOverride
        )

        if !configuration.appMode {
            await onEvent(.diagnostic(
                "Remote request: \(provider.displayTitle) \(provider.modelID)."
            ))
        }
        let requestStartedAt = Date()
        let response = try await openStream(for: request)
        try await RemoteStreamTransport.validateHTTPResponse(response)

        var accumulator = RemoteStreamAccumulator()
        var didReceiveDone = false
        for try await event in response.body.sseEvents() {
            try Task.checkCancellation()
            let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            if payload == "[DONE]" {
                didReceiveDone = true
                break
            }
            guard let object = RemoteStreamTransport.jsonObject(from: payload) else {
                continue
            }
            for event in eventParser(object) {
                try await accumulator.ingest(event, onEvent: onEvent)
            }
        }
        if isKimiChatCompletions, !didReceiveDone {
            throw RemoteGenerationClientError.remoteFailure(
                "Kimi streaming response ended before the [DONE] marker."
            )
        }
        await accumulator.finish(onEvent: onEvent)
        return try accumulator.result(requestStartedAt: requestStartedAt)
    }

    /// Retries only while opening the transport before its response head. Once
    /// `RemoteTransportCore` returns a head, failures propagate from the body
    /// so partial text or tool calls are never replayed by issuing the
    /// streaming POST again.
    func openStream(
        for request: RemoteHTTPStreamingRequest
    ) async throws -> RemoteHTTPStreamingResponse {
        var attempt = 0
        while true {
            do {
                // `openHTTPStream` resolves only after the response head, so
                // the retry loop cannot observe a post-head/body failure.
                return try await transport.openHTTPStream(request)
            } catch {
                guard RemoteStreamTransport.shouldRetryStreamOpening(
                    error: error,
                    attempt: attempt
                ) else {
                    throw error
                }
                try Task.checkCancellation()
                try await Task.sleep(
                    nanoseconds: RemoteStreamTransport
                        .streamOpeningRetryDelayNanoseconds(attempt: attempt)
                )
                attempt += 1
            }
        }
    }
}
