//
//  RemoteGenerationClient+Responses.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

extension RemoteGenerationClient {
    public static func responsesInputPayload(
        from messages: [[String: Any]]
    ) -> (instructions: String?, input: [Any]) {
        guard let payload = try? responsesInputPayload(from: messages, validate: false) else {
            assertionFailure("Unvalidated Responses input conversion unexpectedly failed.")
            return (nil, [])
        }
        return payload
    }

    public static func validatedResponsesInputPayload(
        from messages: [[String: Any]]
    ) throws -> (instructions: String?, input: [Any]) {
        try responsesInputPayload(from: messages, validate: true)
    }

    static func responsesInputPayload(
        from messages: [[String: Any]],
        validate: Bool
    ) throws -> (instructions: String?, input: [Any]) {
        var instructions: [String] = []
        var input: [Any] = []
        var pendingToolImageItems: [[String: Any]] = []
        let lastUserIndex = messages.lastIndex { message in
            (message["role"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "user"
        }

        for (index, message) in messages.enumerated() {
            let role = (message["role"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if role != "tool", !pendingToolImageItems.isEmpty {
                input.append(responsesMessagePayload( role: "user", contentItems: pendingToolImageItems ))
                pendingToolImageItems.removeAll(keepingCapacity: true)
            }
            if role == "system" {
                if let content = contentString(from: message["content"]),
                   !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    instructions.append(content)
                }
                continue
            }

            if role == "assistant" {
                let reasoningItems = responsesReasoningItems(from: message["reasoning_items"])
                if !reasoningItems.isEmpty {
                    // Structured reasoning items (encrypted or plain) are the
                    // provider's own replay format: keep them for every round so
                    // stateless (`store: false`) providers retain reasoning state
                    // and the prompt prefix stays append-only for caching.
                    input.append(contentsOf: reasoningItems)
                } else if lastUserIndex.map({ index > $0 }) ?? true,
                          let reasoningText = responseReasoningText(from: message) {
                    // Loose reasoning text (for example imported from a
                    // chat-completions provider) is only replayed for the
                    // current round; re-sending the CoT of previous rounds
                    // would just inflate billed input tokens on every turn.
                    input.append(responseReasoningTextPayload(reasoningText))
                }
            }

            if role != "tool" {
                if validate {
                    try validateResponsesContentItemsConvertible(from: message["content"], role: role)
                }
                let contentItems = responsesContentItems(from: message["content"], role: role)
                if !contentItems.isEmpty {
                    input.append(
                        responsesMessagePayload(
                            role: role.isEmpty ? "user" : role,
                            contentItems: contentItems
                        )
                    )
                }
            }

            if let toolCalls = message["tool_calls"] as? [[String: Any]] {
                for toolCall in toolCalls {
                    if let payload = try responseFunctionCallPayload(from: toolCall, validate: validate) {
                        input.append(payload)
                    }
                }
            }

            if role == "tool" {
                guard let callID = stringValue(message["tool_call_id"])?.nilIfBlank else {
                    if validate, contentString(from: message["content"])?.nilIfBlank != nil {
                        throw RemoteGenerationClientError.invalidRequestPayload(
                            "Cannot convert tool output to Responses input without tool_call_id."
                        )
                    }
                    continue
                }
                guard let output = contentString(from: message["content"]) else {
                    if validate {
                        throw RemoteGenerationClientError.invalidRequestPayload(
                            "Cannot convert tool output for call_id '\(callID)' because content is missing."
                        )
                    }
                    continue
                }
                input.append(responseFunctionCallOutputPayload( callID: callID, output: output ))
                pendingToolImageItems.append(contentsOf: responsesToolImageItems(from: message))
            }
        }

        if !pendingToolImageItems.isEmpty {
            input.append(responsesMessagePayload( role: "user", contentItems: pendingToolImageItems ))
        }

        let resolvedInstructions = instructions
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return (
            resolvedInstructions.isEmpty ? nil : resolvedInstructions,
            input
        )
    }

    public static func responsesMessagePayload(role: String, contentItems: [[String: Any]]) -> [String: Any] {
        ["type": "message", "role": role, "content": contentItems]
    }

    public static func responsesContentItems(from value: Any?, role: String = "user") -> [[String: Any]] {
        let textType = responsesTextContentType(forRole: role)
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [["type": textType, "text": trimmed]]
        }

        guard let items = value as? [[String: Any]] else {
            return []
        }

        return items.compactMap { item in
            let type = stringValue(item["type"])?.lowercased()
            switch type {
            case "input_text", "output_text", "text":
                guard let text = stringValue(item["text"])?.nilIfBlank else {
                    return nil
                }
                return ["type": textType, "text": text]
            case "refusal":
                guard textType == "output_text",
                      let refusal = stringValue(item["refusal"])?.nilIfBlank
                          ?? stringValue(item["text"])?.nilIfBlank else {
                    return nil
                }
                return ["type": "refusal", "refusal": refusal]
            case "input_image", "image_url":
                guard textType == "input_text",
                      let imageURL = (type == "input_image"
                          ? stringValue(item["image_url"])
                          : chatCompletionsImageURL(from: item))?.nilIfBlank else {
                    return nil
                }
                return ["type": "input_image", "image_url": imageURL]
            default:
                return nil
            }
        }
    }

    static func validateResponsesContentItemsConvertible(from value: Any?, role: String) throws {
        guard let items = value as? [[String: Any]] else {
            return
        }
        let textType = responsesTextContentType(forRole: role)
        for item in items {
            let type = stringValue(item["type"])?.lowercased()
            switch type {
            case "input_text", "output_text", "text":
                guard stringValue(item["text"])?.nilIfBlank != nil else {
                    throw RemoteGenerationClientError.invalidRequestPayload(
                        "Cannot convert text content item to Responses input without text."
                    )
                }
            case "refusal":
                guard textType == "output_text",
                      stringValue(item["refusal"])?.nilIfBlank != nil
                          || stringValue(item["text"])?.nilIfBlank != nil else {
                    throw RemoteGenerationClientError.invalidRequestPayload(
                        "Cannot convert refusal content item to Responses input for role '\(role)'."
                    )
                }
            case "input_image", "image_url":
                guard textType == "input_text",
                      (type == "input_image"
                          ? stringValue(item["image_url"])
                          : chatCompletionsImageURL(from: item))?.nilIfBlank != nil else {
                    throw RemoteGenerationClientError.invalidRequestPayload(
                        "Cannot convert \(type, default: "") content item to Responses input for role '\(role)'."
                    )
                }
            default:
                throw RemoteGenerationClientError.invalidRequestPayload(
                    "Unsupported Responses content item type '\(type, default: "<missing>")' for role '\(role)'."
                )
            }
        }
    }

    public static func responsesTextContentType(forRole role: String) -> String {
        role.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "assistant" ? "output_text" : "input_text"
    }

    public static func responseFunctionCallPayload(from toolCall: [String: Any]) -> [String: Any]? {
        try? responseFunctionCallPayload(from: toolCall, validate: false)
    }

    static func responseFunctionCallPayload(
        from toolCall: [String: Any],
        validate: Bool
    ) throws -> [String: Any]? {
        guard let function = toolCall["function"] as? [String: Any],
              let name = stringValue(function["name"])?.nilIfBlank else {
            if validate {
                throw RemoteGenerationClientError.invalidRequestPayload(
                    "Cannot convert assistant tool_call to Responses function_call without function name."
                )
            }
            return nil
        }
        guard let callID = stringValue(toolCall["id"])?.nilIfBlank else {
            if validate {
                throw RemoteGenerationClientError.invalidRequestPayload(
                    "Cannot convert assistant tool_call '\(name)' to Responses function_call without a stable call_id."
                )
            }
            return nil
        }
        return [
            "type": "function_call",
            "call_id": callID,
            "name": name,
            "arguments": stringValue(function["arguments"]) ?? "{}"
        ]
    }

    public static func responseFunctionCallOutputPayload(callID: String, output: String) -> [String: Any] {
        ["type": "function_call_output", "call_id": callID, "output": output]
    }

    /// Decodes the stored encrypted reasoning items so they can be replayed in the
    /// Responses `input`. Accepts either a decoded array or the JSON string form
    /// persisted on the assistant message.
    public static func responsesReasoningItems(from value: Any?) -> [[String: Any]] {
        if let items = value as? [[String: Any]] {
            return items
        }
        guard let json = stringValue(value)?.nilIfBlank,
              let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .array(items) = decoded else {
            return []
        }
        return items.compactMap { $0.jsonObject as? [String: Any] }
    }

    public static func responseReasoningText(from message: [String: Any]) -> String? {
        stringValue(message["reasoning_content"])?.nilIfBlank
            ?? stringValue(message["reasoning"])?.nilIfBlank
            ?? stringValue(message["reasoning_text"])?.nilIfBlank
            ?? contentString(from: message["reasoning_details"])?.nilIfBlank
    }

    public static func responseReasoningTextPayload(_ text: String) -> [String: Any] {
        ["type": "reasoning", "summary": [], "content": [["type": "reasoning_text", "text": text]]]
    }

    /// True when a Responses reasoning output item carries state that can be
    /// replayed on a later request while `store` is disabled.
    public static func responseReasoningItemHasReplayableContent(_ item: [String: Any]) -> Bool {
        stringValue(item["encrypted_content"])?.nilIfBlank != nil
            || stringValue(item["encryptedContent"])?.nilIfBlank != nil
            || contentString(from: item["content"])?.nilIfBlank != nil
            || stringValue(item["text"])?.nilIfBlank != nil
    }

    /// Keeps only the fields the Responses API accepts when a reasoning item is
    /// replayed as input, dropping streaming-only metadata.
    public static func sanitizedResponseReasoningItem(_ item: [String: Any]) -> [String: Any] {
        var sanitized: [String: Any] = ["type": "reasoning"]
        if let id = stringValue(item["id"])?.nilIfBlank {
            sanitized["id"] = id
        }
        if let encrypted = stringValue(item["encrypted_content"])?.nilIfBlank
            ?? stringValue(item["encryptedContent"])?.nilIfBlank {
            sanitized["encrypted_content"] = encrypted
        }
        sanitized["summary"] = item["summary"] ?? []
        if let content = item["content"] {
            sanitized["content"] = content
        } else if let text = stringValue(item["text"])?.nilIfBlank {
            sanitized["content"] = [["type": "reasoning_text", "text": text]]
        }
        return sanitized
    }

    public static func contentString(from value: Any?) -> String? {
        if let string = value as? String {
            return string
        }
        if let items = value as? [[String: Any]] {
            let text = items.compactMap { item -> String? in
                if let text = item["text"] as? String {
                    return text
                }
                return item["content"] as? String
            }
            .joined(separator: "\n")
            return text.isEmpty ? nil : text
        }
        return nil
    }
}
