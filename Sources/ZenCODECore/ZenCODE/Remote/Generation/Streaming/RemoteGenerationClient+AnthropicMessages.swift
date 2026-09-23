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
            dialect: .anthropicMessages,
            onEvent: onEvent
        )
        let wireMessages = catalog.wireMessages(from: messages)
        let body = try Self.anthropicMessagesRequestBody(
            modelID: provider.modelID,
            messages: wireMessages,
            toolCatalog: catalog,
            maxTokens: configuration.maxOutputTokens ?? 64_000,
            thinkingSelection: thinkingSelection,
            thinkingMode: configuration.generationParameterOverrides.subscriptionThinkingMode,
            thinkingOptions: thinkingOptions
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
        thinkingSelection: AgentThinkingSelection?,
        thinkingMode: String? = nil,
        thinkingOptions: [AgentThinkingSelection] = []
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
        let tools = toolCatalog.bindings.compactMap(\.anthropicMessagesToolPayload)
        if !tools.isEmpty {
            body["tools"] = tools
            body["tool_choice"] = ["type": "auto"]
        }
        // Without an explicit wire mode, configured thinking authorization uses
        // the generic manual budget path; adaptive is never inferred from IDs.
        let payload = AnthropicSubscriptionGenerationClient.catalogThinkingPayload(
            mode: thinkingMode ?? "enabled", selection: thinkingSelection,
            options: thinkingOptions, maxTokens: effectiveMaxTokens
        )
        if let thinking = payload.thinking { body["thinking"] = thinking }
        if let outputConfig = payload.outputConfig { body["output_config"] = outputConfig }
        return body
    }
}
