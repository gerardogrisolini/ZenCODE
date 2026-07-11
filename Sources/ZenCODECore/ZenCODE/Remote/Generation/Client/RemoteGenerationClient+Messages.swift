//
//  RemoteGenerationClient+Messages.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

extension RemoteGenerationClient {
    public static func systemPrompt(
        cwd: String,
        allowedToolNames: Set<String>?
    ) -> String {
        AgentStandaloneSystemPrompt.prompt(
            cwd: cwd,
            memoryToolEnabled: memoryToolEnabled(allowedToolNames)
        )
    }

    public static func initialMessages(
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        allowedToolNames: Set<String>?
    ) -> [[String: Any]] {
        let seededMessages = history.compactMap(remoteMessage(from:))
        if let firstRole = seededMessages.first?["role"] as? String,
           firstRole.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "system" {
            return seededMessages
        }

        let prompt = systemPrompt?.nilIfBlank
            ?? Self.systemPrompt(
                cwd: cwd,
                allowedToolNames: allowedToolNames
            )
        return [
            [
                "role": "system",
                "content": prompt
            ]
        ] + seededMessages
    }

    public static func replacingSystemPrompt(
        in messages: [[String: Any]],
        cwd: String,
        systemPrompt: String?,
        allowedToolNames: Set<String>?
    ) -> [[String: Any]] {
        let prompt = systemPrompt?.nilIfBlank
            ?? Self.systemPrompt(
                cwd: cwd,
                allowedToolNames: allowedToolNames
            )
        var updatedMessages = messages
        if let firstRole = updatedMessages.first?["role"] as? String,
           firstRole.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "system" {
            updatedMessages[0] = [
                "role": "system",
                "content": prompt
            ]
        } else {
            updatedMessages.insert(
                [
                    "role": "system",
                    "content": prompt
                ],
                at: 0
            )
        }
        return updatedMessages
    }

    public static func memoryToolEnabled(_ allowedToolNames: Set<String>?) -> Bool {
        guard let allowedToolNames else {
            return true
        }
        return allowedToolNames.contains { $0.hasPrefix("memory.") }
    }

    public static func remoteMessage(from message: AgentRuntimeMessage) -> [String: Any]? {
        var payload = remoteMessage(
            role: message.role.rawValue,
            content: message.content,
            attachments: message.attachments
        )
        if message.role == .assistant, !message.toolCalls.isEmpty {
            payload["tool_calls"] = message.toolCalls.map { toolCall in
                [
                    "id": toolCall.id ?? "call_\(UUID().uuidString.lowercased())",
                    "type": "function",
                    "function": [
                        "name": toolCall.name,
                        "arguments": toolCall.argumentsJSON
                    ]
                ] as [String: Any]
            }
        }
        if message.role == .assistant,
           let reasoningContent = message.reasoningContent?.nilIfBlank {
            payload["reasoning_content"] = reasoningContent
        }
        if message.role == .assistant,
           let reasoningItemsJSON = message.reasoningItemsJSON?.nilIfBlank {
            payload["reasoning_items"] = reasoningItemsJSON
        }
        if message.role == .assistant,
           let thinkingBlocksJSON = message.thinkingBlocksJSON?.nilIfBlank {
            payload["thinking_blocks"] = thinkingBlocksJSON
        }
        if message.role == .assistant,
           let providerResponseID = message.providerResponseID?.nilIfBlank {
            payload["response_id"] = providerResponseID
        }
        if message.role == .tool {
            if let toolCallID = message.toolCallID {
                payload["tool_call_id"] = toolCallID
            }
            if let toolName = message.toolName {
                payload["name"] = toolName
            }
        }
        guard responseMessagePayloadHasContent(payload) else {
            return nil
        }
        return payload
    }

    public static func remoteMessage(
        role: String,
        content: String,
        attachments: [AgentRuntimeAttachment]
    ) -> [String: Any] {
        let normalizedRole = role.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedContent = promptContent(
            content,
            role: normalizedRole,
            attachments: attachments
        )
        return [
            "role": normalizedRole.isEmpty ? "user" : normalizedRole,
            "content": chatCompletionsContentPayload(
                content: normalizedContent,
                attachments: attachments
            )
        ]
    }

    public static func promptContent(
        _ content: String,
        role: String,
        attachments: [AgentRuntimeAttachment]
    ) -> String {
        let text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard role == "user", text.isEmpty, !attachments.isEmpty else {
            return text
        }
        return "Analyze the attached media."
    }

    /// Strips internal reasoning replay metadata from chat-completions history
    /// messages so the wire payload stays within the OpenAI schema.
    ///
    /// `reasoning_items`, `thinking_blocks`, and `response_id` are internal
    /// replay fields for the Responses/Anthropic endpoints; on
    /// `/chat/completions` providers such as DeepSeek tokenize (and bill) them
    /// as prompt content. `reasoning_content` is kept only on assistant
    /// tool-call messages of the current round (after the last user message),
    /// matching the DeepSeek thinking-mode tool-call replay contract; the CoT
    /// of previous rounds must not be re-sent.
    ///
    /// When `requiresReasoningContentPlaceholder` is true (DeepSeek), assistant
    /// messages whose reasoning is dropped keep an empty `reasoning_content`
    /// field: the DeepSeek thinking mode rejects replayed assistant messages
    /// that omit the field entirely.
    public static func chatCompletionsWireHistoryMessages(
        from messages: [[String: Any]],
        requiresReasoningContentPlaceholder: Bool = false
    ) -> [[String: Any]] {
        let lastUserIndex = messages.lastIndex { message in
            stringValue(message["role"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "user"
        }
        return messages.enumerated().compactMap { index, message -> [String: Any]? in
            var message = message
            message.removeValue(forKey: "reasoning_items")
            message.removeValue(forKey: "thinking_blocks")
            message.removeValue(forKey: "response_id")
            message.removeValue(forKey: "provider_response_id")

            let isCurrentRound = lastUserIndex.map { index > $0 } ?? false
            let hasToolCalls = !((message["tool_calls"] as? [[String: Any]])?.isEmpty ?? true)
            if !(isCurrentRound && hasToolCalls) {
                message.removeValue(forKey: "reasoning_content")
            }

            let role = stringValue(message["role"])?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if role == "assistant", !responseMessagePayloadHasContent(message) {
                return nil
            }
            if role == "assistant",
               requiresReasoningContentPlaceholder,
               message["reasoning_content"] == nil {
                message["reasoning_content"] = ""
            }
            return message
        }
    }

    public static func responseMessagePayloadHasContent(_ message: [String: Any]) -> Bool {
        if let content = contentString(from: message["content"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !content.isEmpty {
            return true
        }

        return !chatCompletionsImageContentItems(from: message["content"]).isEmpty
            || responseReasoningText(from: message) != nil
            || !((message["tool_calls"] as? [[String: Any]])?.isEmpty ?? true)
    }

    public static func chatCompletionsContentPayload(
        content: String,
        attachments: [AgentRuntimeAttachment]
    ) -> Any {
        let imageItems = imageDataURLs(from: attachments).map { dataURL in
            [
                "type": "image_url",
                "image_url": [
                    "url": dataURL
                ]
            ]
        }
        guard !imageItems.isEmpty else {
            return content
        }

        var items: [[String: Any]] = []
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            items.append([
                "type": "text",
                "text": content
            ])
        }
        items.append(contentsOf: imageItems)
        return items
    }

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

    private static func responsesInputPayload(
        from messages: [[String: Any]],
        validate: Bool
    ) throws -> (instructions: String?, input: [Any]) {
        var instructions: [String] = []
        var input: [Any] = []
        let lastUserIndex = messages.lastIndex { message in
            (message["role"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() == "user"
        }

        for (index, message) in messages.enumerated() {
            let role = (message["role"] as? String ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
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
                    try validateResponsesContentItemsConvertible(
                        from: message["content"],
                        role: role
                    )
                }
                let contentItems = responsesContentItems(
                    from: message["content"],
                    role: role
                )
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
                    if let payload = try responseFunctionCallPayload(
                        from: toolCall,
                        validate: validate
                    ) {
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
                input.append(
                    responseFunctionCallOutputPayload(
                        callID: callID,
                        output: output
                    )
                )
            }
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

    public static func responsesMessagePayload(
        role: String,
        contentItems: [[String: Any]]
    ) -> [String: Any] {
        [
            "type": "message",
            "role": role,
            "content": contentItems
        ]
    }

    public static func responsesContentItems(
        from value: Any?,
        role: String = "user"
    ) -> [[String: Any]] {
        let textType = responsesTextContentType(forRole: role)
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return []
            }
            return [
                [
                    "type": textType,
                    "text": trimmed
                ]
            ]
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
                return [
                    "type": textType,
                    "text": text
                ]
            case "refusal":
                guard textType == "output_text",
                      let refusal = stringValue(item["refusal"])?.nilIfBlank
                          ?? stringValue(item["text"])?.nilIfBlank else {
                    return nil
                }
                return [
                    "type": "refusal",
                    "refusal": refusal
                ]
            case "input_image":
                guard textType == "input_text" else {
                    return nil
                }
                guard let imageURL = stringValue(item["image_url"])?.nilIfBlank else {
                    return nil
                }
                return [
                    "type": "input_image",
                    "image_url": imageURL
                ]
            case "image_url":
                guard textType == "input_text" else {
                    return nil
                }
                guard let imageURL = chatCompletionsImageURL(from: item)?.nilIfBlank else {
                    return nil
                }
                return [
                    "type": "input_image",
                    "image_url": imageURL
                ]
            default:
                return nil
            }
        }
    }

    private static func validateResponsesContentItemsConvertible(
        from value: Any?,
        role: String
    ) throws {
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
            case "input_image":
                guard textType == "input_text",
                      stringValue(item["image_url"])?.nilIfBlank != nil else {
                    throw RemoteGenerationClientError.invalidRequestPayload(
                        "Cannot convert input_image content item to Responses input for role '\(role)'."
                    )
                }
            case "image_url":
                guard textType == "input_text",
                      chatCompletionsImageURL(from: item)?.nilIfBlank != nil else {
                    throw RemoteGenerationClientError.invalidRequestPayload(
                        "Cannot convert image_url content item to Responses input for role '\(role)'."
                    )
                }
            default:
                throw RemoteGenerationClientError.invalidRequestPayload(
                    "Unsupported Responses content item type '\(type ?? "<missing>")' for role '\(role)'."
                )
            }
        }
    }

    public static func responsesTextContentType(forRole role: String) -> String {
        role.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() == "assistant" ? "output_text" : "input_text"
    }

    public static func responseFunctionCallPayload(
        from toolCall: [String: Any]
    ) -> [String: Any]? {
        try? responseFunctionCallPayload(from: toolCall, validate: false)
    }

    private static func responseFunctionCallPayload(
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

    public static func responseFunctionCallOutputPayload(
        callID: String,
        output: String
    ) -> [String: Any] {
        [
            "type": "function_call_output",
            "call_id": callID,
            "output": output
        ]
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
        [
            "type": "reasoning",
            "summary": [],
            "content": [
                [
                    "type": "reasoning_text",
                    "text": text
                ]
            ]
        ]
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
        if let summary = item["summary"] {
            sanitized["summary"] = summary
        } else {
            sanitized["summary"] = []
        }
        if let content = item["content"] {
            sanitized["content"] = content
        } else if let text = stringValue(item["text"])?.nilIfBlank {
            sanitized["content"] = [
                [
                    "type": "reasoning_text",
                    "text": text
                ]
            ]
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

    /// Returns a copy of `messages` with all `image_url` content blocks removed.
    /// Content that was an array of blocks is collapsed back to a plain text
    /// string when only text remains, or set to an empty string when the array
    /// contained only image blocks.
    public static func messagesStrippingImageContent(
        from messages: [[String: Any]]
    ) -> [[String: Any]] {
        messages.map { message in
            var stripped = message
            guard let content = message["content"] else {
                return stripped
            }
            if content is String {
                return stripped
            }
            guard var items = content as? [[String: Any]] else {
                return stripped
            }
            items.removeAll { item in
                stringValue(item["type"])?.lowercased() == "image_url"
            }
            if items.isEmpty {
                stripped["content"] = ""
            } else if items.count == 1,
                      stringValue(items[0]["type"])?.lowercased() == "text" {
                stripped["content"] = stringValue(items[0]["text"]) ?? ""
            } else {
                stripped["content"] = items
            }
            return stripped
        }
    }

    /// Returns `true` when any message in the array contains at least one
    /// `image_url` content block.
    public static func messagesContainImageContent(
        _ messages: [[String: Any]]
    ) -> Bool {
        messages.contains { message in
            !chatCompletionsImageContentItems(from: message["content"]).isEmpty
        }
    }

    /// Returns `true` when the error indicates the remote provider rejected
    /// `image_url` content blocks because it only accepts `text` blocks.
    /// This is common with OpenAI-compatible proxies and non-vision models
    /// that use strict serde deserialization on the server side.
    public static func isImageContentRejectedError(_ error: Error) -> Bool {
        let message = (error as? RemoteGenerationClientError)
            .flatMap { error in
                if case let .remoteFailure(msg) = error { return msg }
                return nil
            }
            ?? String(describing: error)
        let lowercased = message.lowercased()
        return lowercased.contains("image_url")
            && (lowercased.contains("expected `text`")
                || lowercased.contains("expected text")
                || lowercased.contains("unknown variant"))
    }

    public static func chatCompletionsImageContentItems(from value: Any?) -> [[String: Any]] {
        guard let items = value as? [[String: Any]] else {
            return []
        }
        return items.filter { item in
            stringValue(item["type"])?.lowercased() == "image_url"
                && chatCompletionsImageURL(from: item)?.nilIfBlank != nil
        }
    }

    public static func chatCompletionsImageURL(from item: [String: Any]) -> String? {
        if let imageURL = item["image_url"] as? String {
            return imageURL
        }
        if let imageURL = item["image_url"] as? [String: Any] {
            return stringValue(imageURL["url"])
        }
        return nil
    }

    public static func imageDataURLs(from attachments: [AgentRuntimeAttachment]) -> [String] {
        attachments.compactMap { attachment in
            guard attachment.kind == .image,
                  let data = attachmentData(for: attachment) else {
                return nil
            }
            return "data:\(mimeType(for: attachment));base64,\(data.base64EncodedString())"
        }
    }

    public static func attachmentData(for attachment: AgentRuntimeAttachment) -> Data? {
        if let data = attachment.data {
            return data
        }
        guard let fileURL = attachment.fileURL else {
            return nil
        }
        return try? Data(contentsOf: fileURL)
    }

    public static func mimeType(for attachment: AgentRuntimeAttachment) -> String {
        if let contentType = attachment.contentType,
           contentType.contains("/") {
            return contentType
        }

        let pathExtension = URL(fileURLWithPath: attachment.originalFilename)
            .pathExtension
            .lowercased()
        switch pathExtension {
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        case "heic":
            return "image/heic"
        default:
            return "image/png"
        }
    }

    public static func isResponseToolCallItem(_ item: [String: Any]) -> Bool {
        let type = stringValue(item["type"])?.lowercased()
        return type == "function_call" || type == "custom_tool_call"
    }

    public static func isResponseReasoningItem(_ item: [String: Any]) -> Bool {
        stringValue(item["type"])?.lowercased() == "reasoning"
    }

    public static func responseOutputText(from item: [String: Any]) -> String? {
        guard stringValue(item["type"])?.lowercased() == "message" else {
            return nil
        }
        if let string = item["content"] as? String {
            return string
        }
        if let items = item["content"] as? [[String: Any]] {
            let text = items
                .compactMap { item -> String? in
                    if let text = item["text"] as? String {
                        return text
                    }
                    return item["content"] as? String
                }
                .joined()
            return text.isEmpty ? nil : text
        }
        return nil
    }

}
