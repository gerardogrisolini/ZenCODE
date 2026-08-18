import Foundation
import ToolCore

extension RemoteGenerationClient {
    func streamAnthropicMessages(
        messages: [[String: Any]],
        sessionID: String,
        allowedToolNames: Set<String>?,
        preferredWorkspaceRootURL: URL?,
        thinkingSelection: AgentThinkingSelection?,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> RemoteStreamResult {
        let catalog = await remoteToolCatalog(
            allowedToolNames: allowedToolNames,
            preferredWorkspaceRootURL: preferredWorkspaceRootURL,
            sessionID: sessionID,
            onEvent: onEvent
        )
        let wireMessages = catalog.wireMessages(from: messages)
        let body = try Self.anthropicMessagesRequestBody(
            modelID: provider.modelID,
            messages: wireMessages,
            toolCatalog: catalog,
            maxTokens: configuration.maxOutputTokens ?? AnthropicSubscriptionModel.defaultMaxOutputTokens,
            thinkingSelection: thinkingSelection
        )
        let request = try RemoteStreamTransport.buildHTTPStreamingRequest(
            path: "/messages", body: body, provider: provider, apiKey: apiKey,
            endpointBaseURLOverride: streamEndpointBaseURLOverride
        )
        if !configuration.appMode {
            await onEvent(.diagnostic("Remote request: \(provider.displayTitle) \(provider.modelID)."))
        }
        let started = Date()
        let response = try await openStream(for: request)
        try await RemoteStreamTransport.validateHTTPResponse(response)
        var accumulator = AnthropicMessagesStreamAccumulator()
        for try await event in response.body.sseEvents() {
            try Task.checkCancellation()
            let payload = event.data.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !payload.isEmpty, let object = RemoteStreamTransport.jsonObject(from: payload) else { continue }
            try await accumulator.ingest(object, onEvent: onEvent)
        }
        let result = try accumulator.result(requestStartedAt: started)
        return RemoteStreamResult(
            text: result.text,
            reasoningText: result.reasoningText,
            stopReason: result.stopReason,
            toolCalls: result.toolCalls.map(catalog.localToolCall),
            stats: result.stats,
            assistantThinkingBlocksJSON: result.assistantThinkingBlocksJSON,
            anthropicContentBlocksJSON: result.anthropicContentBlocksJSON
        )
    }

    static func anthropicMessagesRequestBody(
        modelID: String,
        messages: [[String: Any]],
        toolCatalog: RemoteToolWireCatalog,
        maxTokens: Int,
        thinkingSelection: AgentThinkingSelection?
    ) throws -> [String: Any] {
        let converted = AnthropicMessagesWireCodec.payload(from: messages)
        let effectiveMaxTokens = max(maxTokens, 1)
        var body: [String: Any] = [
            "model": modelID,
            "messages": converted.messages,
            "max_tokens": effectiveMaxTokens,
            "stream": true
        ]
        if let system = converted.system { body["system"] = system }
        let tools: [[String: Any]] = toolCatalog.bindings.compactMap { binding in
            guard let function = binding.chatCompletionToolPayload?["function"] as? [String: Any],
                  let schema = function["parameters"] else { return nil }
            return [
                "name": binding.wireName,
                "description": binding.descriptor.description,
                "input_schema": schema
            ]
        }
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = ["type": "auto"]
        }
        try applyAnthropicThinking(
            selection: thinkingSelection,
            modelID: modelID,
            maxTokens: effectiveMaxTokens,
            body: &body
        )
        return body
    }

    static func applyAnthropicThinking(
        selection: AgentThinkingSelection?,
        modelID: String,
        maxTokens: Int,
        body: inout [String: Any]
    ) throws {
        guard AnthropicSubscriptionGenerationClient.supportsThinking(modelID: modelID) else {
            return
        }
        let payload = AnthropicSubscriptionGenerationClient.thinkingPayload(
            for: selection,
            modelID: modelID,
            maxTokens: maxTokens
        )
        if let thinking = payload.thinking {
            body["thinking"] = thinking
        }
        if let outputConfig = payload.outputConfig {
            body["output_config"] = outputConfig
        }
    }
}
