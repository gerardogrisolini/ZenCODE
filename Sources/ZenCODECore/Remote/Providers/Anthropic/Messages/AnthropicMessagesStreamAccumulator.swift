//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation
import ToolCore

/// Stateful parser for one Anthropic Messages SSE response. Content blocks are
/// retained by index so their exact interleaving can be replayed later.
///
/// Streamed `text`, `thinking` and `signature` deltas are appended to
/// per-index buffers instead of being rebuilt inside `blocks`, so each delta
/// costs its own length rather than a copy of everything accumulated so far;
/// `result(requestStartedAt:)` folds the buffers back into the blocks.
struct AnthropicMessagesStreamAccumulator {
    private var blocks: [Int: [String: Any]] = [:]
    private var toolJSON: [Int: String] = [:]
    private var textBuffers: [Int: String] = [:]
    private var thinkingBuffers: [Int: String] = [:]
    private var signatureBuffers: [Int: String] = [:]
    private var text = ""
    private var reasoning = ""
    private var stopReason = "end_turn"
    private var usage: RemoteGenerationUsage?
    private var firstDeltaAt: Date?
    private var sawMessageStop = false

    mutating func ingest(
        _ object: [String: Any],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws {
        let type = RemoteGenerationClient.stringValue(object["type"])?.lowercased() ?? ""
        switch type {
        case "message_start":
            if let message = object["message"] as? [String: Any] { updateUsage(message["usage"]) }
        case "content_block_start":
            guard let index = JSONValue.intValue(fromJSONObject: object["index"]),
                  let block = object["content_block"] as? [String: Any],
                  let blockType = RemoteGenerationClient.stringValue(block["type"])?.lowercased() else { return }
            switch blockType {
            case "text":
                let initial = RemoteGenerationClient.stringValue(block["text"]) ?? ""
                var saved = block
                saved["text"] = initial
                startBlock(saved, at: index)
                if !initial.isEmpty { markDelta(); text += initial; await onEvent(.content(initial)) }
            case "thinking":
                let initial = RemoteGenerationClient.stringValue(block["thinking"]) ?? ""
                var saved = block
                saved["thinking"] = initial
                if let signature = RemoteGenerationClient.stringValue(block["signature"]) { saved["signature"] = signature }
                startBlock(saved, at: index)
                if !initial.isEmpty { markDelta(); reasoning += initial; await onEvent(.thought(initial)) }
            case "redacted_thinking":
                startBlock(block, at: index)
            case "tool_use":
                var saved = block
                saved["id"] = RemoteGenerationClient.stringValue(block["id"]) ?? "toolu_\(UUID().uuidString.lowercased())"
                saved["name"] = RemoteGenerationClient.stringValue(block["name"]) ?? "tool"
                if saved["input"] == nil { saved["input"] = [:] }
                startBlock(saved, at: index)
                toolJSON[index] = ""
                markDelta()
            default: break
            }
        case "content_block_delta":
            guard let index = JSONValue.intValue(fromJSONObject: object["index"]),
                  let delta = object["delta"] as? [String: Any] else { return }
            switch RemoteGenerationClient.stringValue(delta["type"])?.lowercased() {
            case "text_delta":
                let value = RemoteGenerationClient.stringValue(delta["text"]) ?? ""
                guard !value.isEmpty else { return }
                markDelta(); text += value
                if textBuffers[index] == nil {
                    textBuffers[index] = streamedFieldBase("text", at: index, placeholderType: "text")
                }
                textBuffers[index]?.append(value)
                await onEvent(.content(value))
            case "thinking_delta":
                let value = RemoteGenerationClient.stringValue(delta["thinking"]) ?? ""
                guard !value.isEmpty else { return }
                markDelta(); reasoning += value
                if thinkingBuffers[index] == nil {
                    thinkingBuffers[index] = streamedFieldBase("thinking", at: index, placeholderType: "thinking")
                }
                thinkingBuffers[index]?.append(value)
                await onEvent(.thought(value))
            case "signature_delta":
                let value = RemoteGenerationClient.stringValue(delta["signature"]) ?? ""
                if signatureBuffers[index] == nil {
                    signatureBuffers[index] = streamedFieldBase("signature", at: index, placeholderType: "thinking")
                }
                signatureBuffers[index]?.append(value)
            case "citations_delta":
                guard let citation = delta["citation"] as? [String: Any] else { return }
                var block = blocks[index] ?? ["type": "text", "text": ""]
                var citations = block["citations"] as? [[String: Any]] ?? []
                citations.append(citation)
                block["citations"] = citations
                blocks[index] = block
            case "input_json_delta": toolJSON[index, default: ""] += RemoteGenerationClient.stringValue(delta["partial_json"]) ?? ""
            default: break
            }
        case "message_delta":
            if let delta = object["delta"] as? [String: Any],
               let reason = RemoteGenerationClient.stringValue(delta["stop_reason"])?.nilIfBlank { stopReason = reason }
            updateUsage(object["usage"])
        case "message_stop": sawMessageStop = true
        case "error":
            throw RemoteGenerationClientError.remoteFailure(
                RemoteStreamTransport.responseErrorMessage(from: object) ?? "Anthropic stream error"
            )
        case "ping", "content_block_stop": break
        default: break
        }
    }

    mutating func result(requestStartedAt: Date) throws -> RemoteStreamResult {
        guard sawMessageStop else {
            throw RemoteGenerationClientError.remoteFailure("Anthropic streaming response ended before message_stop.")
        }
        var ordered: [[String: Any]] = []
        var calls: [DirectAgentToolCall] = []
        for index in blocks.keys.sorted() {
            guard var block = materializedBlock(at: index),
                  let type = RemoteGenerationClient.stringValue(block["type"])?.lowercased() else { continue }
            if type == "tool_use" {
                let fragments = toolJSON[index] ?? ""
                if !fragments.isEmpty {
                    guard let data = fragments.data(using: .utf8),
                          let json = try? JSONDecoder().decode(JSONValue.self, from: data),
                          let object = json.objectValue else { throw RemoteGenerationClientError.invalidToolArguments }
                    block["input"] = object.mapValues(\.jsonObject)
                }
                guard let id = RemoteGenerationClient.stringValue(block["id"])?.nilIfBlank,
                      let name = RemoteGenerationClient.stringValue(block["name"])?.nilIfBlank,
                      let input = block["input"] as? [String: Any] else { throw RemoteGenerationClientError.invalidToolArguments }
                calls.append(DirectAgentToolCall(id: id, name: name, argumentsObject: input, argumentsJSON: AgentJSONSupport.jsonString(from: input)))
            }
            if let valid = AnthropicMessagesWireCodec.validAssistantBlock(block) { ordered.append(valid) }
        }
        let thinking = ordered.filter {
            let type = RemoteGenerationClient.stringValue($0["type"])?.lowercased()
            return type == "thinking" || type == "redacted_thinking"
        }
        return RemoteStreamResult(
            text: text,
            reasoningText: reasoning,
            stopReason: calls.isEmpty ? stopReason : "tool_calls",
            toolCalls: calls,
            stats: RemoteGenerationStats(usage: usage, requestStartedAt: requestStartedAt, firstDeltaAt: firstDeltaAt, finishedAt: Date(), generatedCharacterCount: text.count),
            assistantThinkingBlocksJSON: AnthropicMessagesWireCodec.jsonString(thinking),
            anthropicContentBlocksJSON: AnthropicMessagesWireCodec.jsonString(ordered)
        )
    }

    private mutating func markDelta() { if firstDeltaAt == nil { firstDeltaAt = Date() } }

    /// A `content_block_start` replaces whatever was streamed at `index`.
    private mutating func startBlock(_ block: [String: Any], at index: Int) {
        blocks[index] = block
        textBuffers[index] = nil
        thinkingBuffers[index] = nil
        signatureBuffers[index] = nil
    }

    /// Value the first delta of `field` at `index` appends to: the field as
    /// the block currently holds it. A delta without a preceding
    /// `content_block_start` creates a placeholder block of `placeholderType`.
    private mutating func streamedFieldBase(_ field: String, at index: Int, placeholderType: String) -> String {
        if blocks[index] == nil { blocks[index] = ["type": placeholderType, placeholderType: ""] }
        return RemoteGenerationClient.stringValue(blocks[index]?[field]) ?? ""
    }

    /// The block at `index` with its streamed fields folded back in.
    private func materializedBlock(at index: Int) -> [String: Any]? {
        guard var block = blocks[index] else { return nil }
        if let value = textBuffers[index] { block["text"] = value }
        if let value = thinkingBuffers[index] { block["thinking"] = value }
        if let value = signatureBuffers[index] { block["signature"] = value }
        return block
    }

    private mutating func updateUsage(_ value: Any?) {
        guard let object = value as? [String: Any] else { return }
        func integer(_ key: String) -> Int? { JSONValue.intValue(fromJSONObject: object[key]) }
        let cached = integer("cache_read_input_tokens") ?? usage?.cachedPromptTokens ?? 0
        let processed = if integer("input_tokens") != nil || integer("cache_creation_input_tokens") != nil {
            (integer("input_tokens") ?? 0) + (integer("cache_creation_input_tokens") ?? 0)
        } else { usage?.processedPromptTokens ?? 0 }
        let prompt = processed + cached
        let output = integer("output_tokens") ?? usage?.completionTokens ?? 0
        usage = RemoteGenerationUsage(
            promptTokens: prompt, completionTokens: output, totalTokens: prompt + output,
            contextTokens: nil, processedPromptTokens: processed, cachedPromptTokens: cached,
        )
    }
}
