//
//  AnthropicThinkingBlockAccumulator.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 10/06/26.
//
#if os(macOS)
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Accumulates the signed `thinking` / `redacted_thinking` content blocks that
/// Anthropic streams alongside text and tool calls. Re-sending these blocks (with
/// their original `signature`) on later requests keeps the interleaved-thinking
/// prefix cache valid, so previously processed context is not re-billed.
struct AnthropicThinkingBlockAccumulator {
    private struct PartialThinkingBlock {
        var type: String
        var thinking: String
        var signature: String
        var data: String?
    }

    private var partialsByIndex: [Int: PartialThinkingBlock] = [:]

    mutating func ingestContentBlockStart(_ object: [String: Any]) {
        guard let index = AnthropicSubscriptionGenerationClient.intValue(object["index"]),
              let contentBlock = object["content_block"] as? [String: Any] else {
            return
        }
        let type = AnthropicSubscriptionGenerationClient.stringValue(contentBlock["type"])?
            .lowercased()
        switch type {
        case "thinking":
            partialsByIndex[index] = PartialThinkingBlock(
                type: "thinking",
                thinking: AnthropicSubscriptionGenerationClient.stringValue(contentBlock["thinking"]) ?? "",
                signature: AnthropicSubscriptionGenerationClient.stringValue(contentBlock["signature"]) ?? "",
                data: nil
            )
        case "redacted_thinking":
            partialsByIndex[index] = PartialThinkingBlock(
                type: "redacted_thinking",
                thinking: "",
                signature: "",
                data: AnthropicSubscriptionGenerationClient.stringValue(contentBlock["data"])
            )
        default:
            break
        }
    }

    mutating func ingestDelta(index: Int, delta: [String: Any]) {
        let deltaType = AnthropicSubscriptionGenerationClient.stringValue(delta["type"])?
            .lowercased() ?? ""
        switch deltaType {
        case "thinking_delta":
            guard let text = AnthropicSubscriptionGenerationClient.stringValue(delta["thinking"]),
                  !text.isEmpty else {
                return
            }
            var partial = partialsByIndex[index] ?? PartialThinkingBlock(
                type: "thinking",
                thinking: "",
                signature: "",
                data: nil
            )
            partial.thinking.append(text)
            partialsByIndex[index] = partial
        case "signature_delta":
            guard let signature = AnthropicSubscriptionGenerationClient.stringValue(delta["signature"]),
                  !signature.isEmpty else {
                return
            }
            var partial = partialsByIndex[index] ?? PartialThinkingBlock(
                type: "thinking",
                thinking: "",
                signature: "",
                data: nil
            )
            partial.signature.append(signature)
            partialsByIndex[index] = partial
        default:
            break
        }
    }

    /// Returns the finalized thinking blocks in stream order, dropping any block
    /// that is missing the data required for Anthropic to accept it on replay.
    func finalize() -> [[String: Any]] {
        partialsByIndex.keys.sorted().compactMap { index -> [String: Any]? in
            guard let partial = partialsByIndex[index] else {
                return nil
            }
            if partial.type == "redacted_thinking" {
                guard let data = partial.data?.nilIfBlank else {
                    return nil
                }
                return ["type": "redacted_thinking", "data": data]
            }
            // A signed thinking block requires both the text and the signature;
            // without the signature Anthropic rejects the replayed block.
            guard !partial.thinking.isEmpty, !partial.signature.isEmpty else {
                return nil
            }
            return [
                "type": "thinking",
                "thinking": partial.thinking,
                "signature": partial.signature
            ]
        }
    }
}
#endif
