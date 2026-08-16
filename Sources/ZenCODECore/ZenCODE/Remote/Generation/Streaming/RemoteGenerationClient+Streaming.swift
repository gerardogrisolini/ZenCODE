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
        switch thinkingPayloadStyle {
        case .none, .alwaysOn:
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
        case let .openAIResponsesReasoning(allowed):
            if thinkingSelection == .off {
                guard allowed.contains(.off) else {
                    return
                }
                body["reasoning"] = ["effort": "none"]
                return
            }
            let resolved: AgentThinkingSelection
            if thinkingSelection == .enabled {
                resolved = allowed.contains(.medium) ? .medium : (allowed.first { $0.isEnabled } ?? .medium)
            } else {
                resolved = thinkingSelection
            }
            guard allowed.contains(resolved) else {
                return
            }
            body["reasoning"] = [
                "effort": resolved.rawValue,
                "summary": "auto"
            ]
        case let .reasoningEffort(allowed):
            if thinkingSelection == .off {
                if allowed.contains(.off) {
                    body["reasoning_effort"] = "none"
                }
                return
            }
            let resolved: AgentThinkingSelection
            if thinkingSelection == .enabled {
                resolved = allowed.contains(.max) ? .max
                    : (allowed.contains(.medium) ? .medium : (allowed.first ?? .high))
            } else {
                resolved = thinkingSelection
            }
            guard allowed.contains(resolved) else {
                return
            }
            body["reasoning_effort"] = resolved.rawValue
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

    public var thinkingPayloadStyle: AgentThinkingPayloadStyle {
        let model = provider.modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch (provider.providerProfileID, provider.protocolProfileID) {
        case (.openRouter, .openAIChatCompletions), (.openRouter, .openAIResponses):
            return .openRouterReasoning
        case (.openAI, .openAIResponses):
            guard Self.model(model, belongsTo: Self.openAIReasoningModelFamilies) else {
                return .none
            }
            return .openAIResponsesReasoning(
                allowed: Self.openAIResponsesReasoningAllowedSelections(for: model)
            )
        case (.openAI, .openAIChatCompletions):
            guard Self.model(model, belongsTo: Self.openAIReasoningModelFamilies) else {
                return .none
            }
            return .reasoningEffort(allowed: [.off, .minimal, .low, .medium, .high, .xhigh])
        case (.zAI, .openAIChatCompletions), (.zAI, .zaiCodingPlan):
            if Self.model(model, belongsTo: ["glm-5"]) {
                return .reasoningEffort(allowed: [.low, .medium, .high])
            }
            if Self.model(model, belongsTo: ["glm-4.5", "glm-4.6", "glm-4.7"]) {
                return .thinkingObject(supportsDisable: true, keepAll: false)
            }
            return .none
        case (.googleGemini, .openAIChatCompletions):
            guard Self.model(model, belongsTo: ["gemini-3"]) else {
                return .none
            }
            return .reasoningEffort(allowed: [.low, .medium, .high])
        case (.deepSeek, .openAIChatCompletions):
            if model == "deepseek-reasoner" {
                return .alwaysOn
            }
            return model == "deepseek-chat"
                ? .thinkingObject(supportsDisable: true, keepAll: false)
                : .none
        case (.moonshot, .openAIChatCompletions):
            if Self.model(model, belongsTo: ["kimi-k3"]) {
                return .reasoningEffort(allowed: [.low, .high, .max])
            }
            if Self.model(model, belongsTo: ["kimi-k2.7"]) {
                return .alwaysOn
            }
            return Self.model(model, belongsTo: ["kimi-k2.6"])
                ? .thinkingObject(supportsDisable: true, keepAll: true)
                : .none
        case (.nvidia, .openAIChatCompletions), (.modal, .openAIChatCompletions):
            return .chatTemplateKwargs
        default:
            return .none
        }
    }

    public var chatCompletionsReplayPolicy: AgentChatCompletionsReplayPolicy {
        let model = provider.modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if provider.providerProfileID == .moonshot,
           provider.protocolProfileID == .openAIChatCompletions,
           Self.model(model, belongsTo: ["kimi-k3", "kimi-k2.7", "kimi-k2.6"]) {
            return .preserveAllAssistantReasoning
        }
        if provider.providerProfileID == .deepSeek,
           provider.protocolProfileID == .openAIChatCompletions,
           model == "deepseek-chat" || model == "deepseek-reasoner" {
            return .currentToolRound(requiresPlaceholder: true)
        }
        return .stripReasoning
    }

    private static func model(_ model: String, belongsTo families: [String]) -> Bool {
        families.contains { family in
            model == family
                || model.hasPrefix(family + "-")
                || model.hasPrefix(family + ".")
                || model.hasPrefix(family + "/")
        }
    }

    /// Model families that accept the OpenAI reasoning parameters on both the
    /// Chat Completions and Responses dialects.
    static let openAIReasoningModelFamilies = ["gpt-5", "o1", "o3", "o4"]

    /// Model-aware effort selections for the OpenAI Responses reasoning
    /// dialect. Registry-listed models contribute their advertised levels,
    /// o-series models expose the low/medium/high ladder the API documents,
    /// and every other supported reasoning model fails closed to the registry
    /// default so an unsupported effort is never sent verbatim.
    static func openAIResponsesReasoningAllowedSelections(
        for model: String
    ) -> Set<AgentThinkingSelection> {
        if Self.model(model, belongsTo: ["gpt-5"]),
           let registryOption = CodexAgentModel.availableModels.first(where: {
               $0.modelID.caseInsensitiveCompare(model) == .orderedSame
           }) {
            return Set(
                registryOption.thinkingSupport.availableSelections
                    .compactMap { AgentThinkingSelection(rawValue: $0.rawValue) }
            )
        }
        if Self.model(model, belongsTo: ["o1", "o3", "o4"]) {
            return [.off, .low, .medium, .high]
        }
        return [.off, .low, .medium, .high, .xhigh]
    }

    public var isKimiChatCompletions: Bool {
        guard provider.providerProfileID == .moonshot,
              provider.protocolProfileID == .openAIChatCompletions else {
            return false
        }
        let model = provider.modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.model(model, belongsTo: ["kimi-k3", "kimi-k2.7", "kimi-k2.6"])
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
        let model = provider.modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return Self.model(model, belongsTo: Self.openAIReasoningModelFamilies)
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
