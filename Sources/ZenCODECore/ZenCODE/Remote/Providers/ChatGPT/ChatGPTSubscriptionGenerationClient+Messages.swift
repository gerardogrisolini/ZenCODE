//
//  ChatGPTSubscriptionGenerationClient+Messages.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if os(macOS)
import Foundation
#if canImport(os)
import os
#endif

extension ChatGPTSubscriptionGenerationClient {
    static func appendAssistantMessage(
        text: String,
        reasoningText: String,
        toolCalls: [DirectAgentToolCall],
        reasoningItemsJSON: String? = nil,
        responseID: String? = nil,
        to messages: inout [[String: Any]]
    ) {
        var message: [String: Any] = [
            "role": "assistant",
            "content": text
        ]
        if let reasoningText = reasoningText.nilIfBlank {
            message["reasoning_content"] = reasoningText
        }
        if let reasoningItemsJSON = reasoningItemsJSON?.nilIfBlank {
            message["reasoning_items"] = reasoningItemsJSON
        }
        if let responseID = responseID?.nilIfBlank {
            message["response_id"] = responseID
        }
        if !toolCalls.isEmpty {
            message["tool_calls"] = toolCalls.map { toolCall in
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

        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReasoning = reasoningText.nilIfBlank != nil
        let hasReasoningItems = reasoningItemsJSON?.nilIfBlank != nil
        if hasContent || hasReasoning || hasReasoningItems || !toolCalls.isEmpty {
            messages.append(message)
        }
    }

#if DEBUG
    public static func testIngestStreamObjects(
        _ objects: [[String: Any]]
    ) throws -> (text: String, contentText: String) {
        let accumulator = StreamAccumulator()
        var contentText = ""
        for object in objects {
            for event in try accumulator.ingest(object) {
                if case let .content(delta) = event {
                    contentText.append(delta)
                }
            }
        }
        let result = try accumulator.result(toolCatalog: RemoteToolWireCatalog(descriptors: []))
        return (result.text, contentText)
    }
#endif
}
#endif
