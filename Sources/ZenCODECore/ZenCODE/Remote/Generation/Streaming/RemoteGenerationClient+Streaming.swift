//
//  RemoteGenerationClient+Streaming.swift
//  ZenCODE
//
//  Orchestrates remote chat-completions and responses streaming. The transport,
//  accumulator, and per-endpoint parsers have been extracted into their own
//  types so that this file stays focused on payload construction and wiring.
//

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

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
        to body: inout [String: Any]
    ) {
        guard let thinkingSelection else {
            return
        }
        switch thinkingPayloadStyle {
        case .openRouterReasoning:
            body["reasoning"] = thinkingSelection.openRouterReasoningPayload
        case .chatTemplateKwargs:
            var kwargs: [String: Any] = [
                "enable_thinking": thinkingSelection.isEnabled,
                "thinking": thinkingSelection.isEnabled
            ]
            if let reasoningEffort = thinkingSelection.chatTemplateReasoningEffort {
                kwargs["reasoning_effort"] = reasoningEffort
            }
            body["chat_template_kwargs"] = kwargs
        }
    }

    public var thinkingPayloadStyle: AgentThinkingPayloadStyle {
        if AgentRemoteProvider.isModalDirectBaseURL(provider.baseURL)
            || AgentRemoteProvider.isNVIDIABaseURL(provider.baseURL) {
            return .chatTemplateKwargs
        }
        return .openRouterReasoning
    }

    /// Whether the provider requires reasoning replay metadata on `/responses`.
    public var shouldSendResponsesReplayMetadata: Bool {
        AgentRemoteProvider.isOpenAIBaseURL(provider.baseURL)
            || AgentRemoteProvider.isOpenRouterBaseURL(provider.baseURL)
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

    // MARK: - Chat Completions

    public func streamChatCompletions(
        messages: [[String: Any]],
        sessionID: String,
        allowedToolNames: Set<String>?,
        preferredWorkspaceRootURL: URL? = nil,
        thinkingSelection: AgentThinkingSelection?,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> RemoteStreamResult {
        let toolDescriptors = await toolExecutor.descriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
        if configuration.verboseLogging {
            await onEvent(.diagnostic(
                RemoteStreamTransport.toolExposureDiagnostic(from: toolDescriptors)
            ))
        }
        let toolCatalog = RemoteToolWireCatalog(descriptors: toolDescriptors)
        var body: [String: Any] = [
            "model": provider.modelID,
            "messages": toolCatalog.wireMessages(from: messages),
            "stream": true,
            "stream_options": [
                "include_usage": true
            ]
        ]
        applyThinkingSelection(thinkingSelection, to: &body)
        applyStructuredOutputFormat(to: &body, endpoint: .chatCompletions)
        if provider.chatEndpoint.usesSessionID
            || AgentRemoteProvider.isOpenRouterBaseURL(provider.baseURL) {
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
            body["max_tokens"] = maxTokens
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
        let toolDescriptors = await toolExecutor.descriptors(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL
        )
        if configuration.verboseLogging {
            await onEvent(.diagnostic(
                RemoteStreamTransport.toolExposureDiagnostic(from: toolDescriptors)
            ))
        }
        let toolCatalog = RemoteToolWireCatalog(descriptors: toolDescriptors)
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
        applyThinkingSelection(thinkingSelection, to: &body)
        applyStructuredOutputFormat(to: &body, endpoint: .responses)
        if provider.chatEndpoint.usesSessionID
            || AgentRemoteProvider.isOpenRouterBaseURL(provider.baseURL) {
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
        let request = try RemoteStreamTransport.buildStreamRequest(
            path: path,
            body: body,
            provider: provider,
            apiKey: apiKey
        )

        if !configuration.appMode {
            await onEvent(.diagnostic(
                "Remote request: \(provider.displayTitle) \(provider.modelID)."
            ))
        }
        let requestStartedAt = Date()
        let (bytes, response) = try await urlSession.bytes(for: request)
        try await RemoteStreamTransport.validateHTTPResponse(response, bytes: bytes)

        var accumulator = RemoteStreamAccumulator()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let payload = RemoteStreamTransport.ssePayload(from: line) else {
                continue
            }
            if payload == "[DONE]" {
                break
            }
            guard let object = RemoteStreamTransport.jsonObject(from: payload) else {
                continue
            }
            for event in eventParser(object) {
                try await accumulator.ingest(event, onEvent: onEvent)
            }
        }
        await accumulator.finish(onEvent: onEvent)
        return try accumulator.result(requestStartedAt: requestStartedAt)
    }
}
