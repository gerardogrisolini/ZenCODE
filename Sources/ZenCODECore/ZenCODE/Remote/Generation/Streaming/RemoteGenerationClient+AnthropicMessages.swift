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

    static let anthropicMinimumUsefulOutputTokens = 1_024
    static let anthropicMinimumThinkingAndOutputTokens = 2_048

    static func applyAnthropicThinking(
        selection: AgentThinkingSelection?,
        modelID: String,
        maxTokens: Int,
        body: inout [String: Any]
    ) throws {
        guard let selection else { return }
        let model = modelID.lowercased()
        let adaptive = model.contains("4-6") || model.contains("4.6")
            || model.contains("4-7") || model.contains("4.7")
            || model.contains("4-8") || model.contains("4.8")
            || model.range(of: #"claude-[a-z-]*5([-.]|$)"#, options: .regularExpression) != nil
        if selection == .off {
            // Always-on Mythos/Fable families fail closed by omitting an invalid
            // disable request. Other current families accept explicit disabled.
            if !model.contains("mythos") && !model.contains("fable") {
                body["thinking"] = ["type": "disabled"]
            }
            return
        }
        if adaptive {
            body["thinking"] = ["type": "adaptive"]
            if selection != .enabled {
                body["output_config"] = ["effort": anthropicEffort(selection, model: model)]
            }
            return
        }
        // Claude 4.5 and older extended-thinking models use a manual budget.
        guard maxTokens >= anthropicMinimumThinkingAndOutputTokens else {
            throw RemoteGenerationClientError.invalidRequestPayload(
                "Anthropic manual thinking cannot fit in max_tokens=\(maxTokens)."
            )
        }
        let budget = min(
            max(1_024, anthropicBudget(selection)),
            maxTokens - anthropicMinimumUsefulOutputTokens
        )
        body["thinking"] = ["type": "enabled", "budget_tokens": budget]
        if model.contains("opus-4-5") || model.contains("opus-4.5") {
            body["output_config"] = ["effort": anthropicEffort(selection, model: model)]
        }
    }

    private static func anthropicEffort(_ selection: AgentThinkingSelection, model: String) -> String {
        switch selection {
        case .minimal: return "low"
        case .xhigh:
            return model.contains("4-7") || model.contains("4.7")
                || model.contains("4-8") || model.contains("4.8")
                || model.contains("-5") ? "xhigh" : "max"
        case .max, .ultra: return "max"
        case .enabled, .off: return "high"
        case .low, .medium, .high: return selection.rawValue
        }
    }

    private static func anthropicBudget(_ selection: AgentThinkingSelection) -> Int {
        switch selection {
        case .minimal: return 1_024
        case .low: return 4_096
        case .medium: return 8_192
        case .enabled, .high: return 16_384
        case .xhigh: return 32_768
        case .max, .ultra: return 64_000
        case .off: return 1_024
        }
    }
}
