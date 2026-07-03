//
//  AnthropicSubscriptionGenerationClient+Payload.swift
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
    func appendAssistantMessage(
        streamResult: RemoteStreamResult,
        to messages: inout [[String: Any]]
    ) {
        var message: [String: Any] = [
            "role": "assistant",
            "content": streamResult.text
        ]
        if let thinkingBlocksJSON = streamResult.assistantThinkingBlocksJSON?.nilIfBlank {
            message["thinking_blocks"] = thinkingBlocksJSON
        }
        if !streamResult.toolCalls.isEmpty {
            message["tool_calls"] = streamResult.toolCalls.map { toolCall in
                [
                    "id": toolCall.id,
                    "type": "function",
                    "function": [
                        "name": toolCall.name,
                        "arguments": toolCall.argumentsJSON
                    ]
                ] as [String: Any]
            }
        }

        let hasContent = !streamResult.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let hasThinkingBlocks = streamResult.assistantThinkingBlocksJSON?.nilIfBlank != nil
        if hasContent || !streamResult.toolCalls.isEmpty || hasThinkingBlocks {
            messages.append(message)
        }
    }
}

extension AnthropicSubscriptionGenerationClient {
    static func anthropicMessagesPayload(
        from messages: [[String: Any]],
        includeThinkingBlocks: Bool = true
    ) -> (system: String?, messages: [[String: Any]]) {
        var systemParts: [String] = []
        var anthropicMessages: [[String: Any]] = []

        for message in messages {
            let role = (message["role"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if role == "system" {
                if let text = RemoteGenerationClient.contentString(from: message["content"])?.nilIfBlank {
                    systemParts.append(text)
                }
                continue
            }

            switch role {
            case "assistant":
                let blocks = assistantContentBlocks(
                    from: message,
                    includeThinkingBlocks: includeThinkingBlocks
                )
                if !blocks.isEmpty {
                    anthropicMessages.append([
                        "role": "assistant",
                        "content": blocks
                    ])
                }
            case "tool":
                if let block = toolResultBlock(from: message) {
                    appendUserBlocks([block], to: &anthropicMessages)
                }
            default:
                let blocks = userContentBlocks(from: message["content"])
                if !blocks.isEmpty {
                    anthropicMessages.append([
                        "role": "user",
                        "content": blocks
                    ])
                }
            }
        }

        return (
            systemParts.joined(separator: "\n\n").nilIfBlank,
            anthropicMessages
        )
    }

    static func appendUserBlocks(_ blocks: [[String: Any]], to messages: inout [[String: Any]]) {
        guard !blocks.isEmpty else {
            return
        }
        if let last = messages.indices.last,
           (messages[last]["role"] as? String) == "user",
           var content = messages[last]["content"] as? [[String: Any]] {
            content.append(contentsOf: blocks)
            messages[last]["content"] = content
        } else {
            messages.append([
                "role": "user",
                "content": blocks
            ])
        }
    }


    /// Number of trailing conversation messages that receive a moving cache
    /// breakpoint. Together with the single system breakpoint this uses the
    /// full Anthropic budget of 4 breakpoints per request. Multiple moving
    /// breakpoints keep prefix-cache hits alive even when a turn appends more
    /// than ~20 content blocks (the server-side lookback limit per breakpoint).
    static let cacheControlMessageBreakpointCount = 3

    static let cacheableBlockTypes: Set<String> = [
        "text", "image", "tool_result", "tool_use"
    ]

    static func addingCacheControlBreakpoints(
        _ messages: [[String: Any]]
    ) -> [[String: Any]] {
        var messages = messages
        var remaining = cacheControlMessageBreakpointCount
        for index in messages.indices.reversed() {
            guard remaining > 0 else {
                break
            }
            if markLastCacheableBlock(in: &messages[index]) {
                remaining -= 1
            }
        }
        return messages
    }

    /// Adds a cache breakpoint to the last cacheable block of the message.
    /// Thinking blocks are never marked: cache_control on a thinking block
    /// interferes with Anthropic's signature validation.
    private static func markLastCacheableBlock(
        in message: inout [String: Any]
    ) -> Bool {
        if var content = message["content"] as? [[String: Any]] {
            for blockIndex in content.indices.reversed() {
                guard let type = stringValue(content[blockIndex]["type"])?.lowercased(),
                      cacheableBlockTypes.contains(type) else {
                    continue
                }
                content[blockIndex]["cache_control"] = cacheControl()
                message["content"] = content
                return true
            }
            return false
        }

        if let text = stringValue(message["content"])?.nilIfBlank {
            message["content"] = [
                [
                    "type": "text",
                    "text": text,
                    "cache_control": cacheControl()
                ]
            ]
            return true
        }
        return false
    }

    static func userContentBlocks(from value: Any?) -> [[String: Any]] {
        if let text = RemoteGenerationClient.contentString(from: value)?.nilIfBlank,
           !(value is [[String: Any]]) {
            return [["type": "text", "text": text]]
        }

        guard let items = value as? [[String: Any]] else {
            return []
        }
        return items.compactMap { item in
            let type = stringValue(item["type"])?.lowercased()
            switch type {
            case "text", "input_text", "output_text":
                guard let text = stringValue(item["text"])?.nilIfBlank else {
                    return nil
                }
                return ["type": "text", "text": text]
            case "image_url", "input_image":
                guard let imageURL = RemoteGenerationClient.chatCompletionsImageURL(from: item)?.nilIfBlank,
                      let imageBlock = anthropicImageBlock(fromDataURL: imageURL) else {
                    return nil
                }
                return imageBlock
            default:
                return nil
            }
        }
    }

    static func assistantContentBlocks(
        from message: [String: Any],
        includeThinkingBlocks: Bool = true
    ) -> [[String: Any]] {
        var blocks: [[String: Any]] = []
        // Signed thinking blocks must precede text/tool_use so Anthropic can
        // verify them and keep the interleaved-thinking prefix cache valid.
        if includeThinkingBlocks {
            blocks.append(contentsOf: thinkingBlocks(from: message["thinking_blocks"]))
        }
        if let text = RemoteGenerationClient.contentString(from: message["content"])?.nilIfBlank {
            blocks.append(["type": "text", "text": text])
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            blocks.append(contentsOf: toolCalls.compactMap(toolUseBlock(from:)))
        }
        return blocks
    }

    static func thinkingBlocks(from value: Any?) -> [[String: Any]] {
        if let blocks = value as? [[String: Any]] {
            return blocks
        }
        guard let json = stringValue(value)?.nilIfBlank,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .array(items) = decoded else {
            return []
        }
        return items.compactMap { $0.jsonObject as? [String: Any] }
    }

    static func toolUseBlock(from toolCall: [String: Any]) -> [String: Any]? {
        guard let function = toolCall["function"] as? [String: Any],
              let name = stringValue(function["name"])?.nilIfBlank else {
            return nil
        }
        let id = stringValue(toolCall["id"])?.nilIfBlank ?? "toolu_\(UUID().uuidString.lowercased())"
        return [
            "type": "tool_use",
            "id": id,
            "name": name,
            "input": jsonObject(fromJSONString: stringValue(function["arguments"]) ?? "{}")
        ]
    }

    static func toolResultBlock(from message: [String: Any]) -> [String: Any]? {
        guard let toolUseID = stringValue(message["tool_call_id"])?.nilIfBlank else {
            return nil
        }
        return [
            "type": "tool_result",
            "tool_use_id": toolUseID,
            "content": RemoteGenerationClient.contentString(from: message["content"]) ?? ""
        ]
    }

    static func anthropicImageBlock(fromDataURL dataURL: String) -> [String: Any]? {
        guard dataURL.hasPrefix("data:"),
              let commaIndex = dataURL.firstIndex(of: ",") else {
            return nil
        }
        let header = String(dataURL[dataURL.index(dataURL.startIndex, offsetBy: "data:".count)..<commaIndex])
        let data = String(dataURL[dataURL.index(after: commaIndex)...])
        let mediaType = header.components(separatedBy: ";").first?.nilIfBlank ?? "image/png"
        return [
            "type": "image",
            "source": [
                "type": "base64",
                "media_type": mediaType,
                "data": data
            ]
        ]
    }

    static func anthropicTools(from bindings: [RemoteToolWireCatalog.Binding]) -> [[String: Any]] {
        bindings.compactMap { binding in
            guard let schema = binding.descriptor.schemaObject else {
                return nil
            }
            // No cache breakpoint on tools: they precede the system blocks in
            // Anthropic's cacheable prefix, so the system breakpoint already
            // covers them.
            return [
                "name": binding.wireName,
                "description": binding.descriptor.description,
                "eager_input_streaming": true,
                "input_schema": schema
            ]
        }
    }
}
#endif
