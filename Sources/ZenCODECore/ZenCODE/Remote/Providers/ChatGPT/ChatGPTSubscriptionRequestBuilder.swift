//
//  ChatGPTSubscriptionRequestBuilder.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 15/06/26.
//

#if os(macOS)
import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct ChatGPTSubscriptionContinuationState: Equatable, Sendable {
    public let responseID: String
    public let messageCount: Int
    public let instructions: String
    public let allowsFreshTransport: Bool

    public init(
        responseID: String,
        messageCount: Int,
        instructions: String,
        allowsFreshTransport: Bool = false
    ) {
        self.responseID = responseID
        self.messageCount = messageCount
        self.instructions = instructions
        self.allowsFreshTransport = allowsFreshTransport
    }
}

public enum ChatGPTSubscriptionRequestBuilder {
    public static func requestInputPayload(
        from messages: [[String: Any]],
        continuation: ChatGPTSubscriptionContinuationState?
    ) -> (instructions: String?, input: [Any], cachedWebSocketInput: [Any]?, previousResponseID: String?) {
        let fullPayload = chatGPTResponsesInputPayload(from: messages)
        let normalizedInstructions = fullPayload.instructions?.nilIfBlank

        guard let continuation,
              continuation.messageCount >= 0,
              continuation.messageCount <= messages.count,
              !continuation.responseID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              continuation.instructions == (normalizedInstructions ?? "") else {
            return (
                normalizedInstructions,
                fullPayload.input,
                nil,
                nil
            )
        }

        let deltaMessages = Array(messages[continuation.messageCount...])
        let deltaPayload = chatGPTResponsesInputPayload(from: deltaMessages)
        guard deltaPayload.instructions?.nilIfBlank == nil,
              !deltaPayload.input.isEmpty else {
            return (
                normalizedInstructions,
                fullPayload.input,
                nil,
                nil
            )
        }

        return (
            normalizedInstructions,
            fullPayload.input,
            deltaPayload.input,
            continuation.responseID
        )
    }

    static func chatGPTResponsesInputPayload(
        from messages: [[String: Any]]
    ) -> (instructions: String?, input: [Any]) {
        let payload = RemoteGenerationClient.responsesInputPayload(from: messages)
        return (
            payload.instructions,
            chatGPTInputPayload(from: payload.input)
        )
    }

    static func chatGPTInputPayload(from input: [Any]) -> [Any] {
        var seenReasoningIDs: Set<String> = []
        return input.compactMap { item in
            chatGPTInputItem(item, seenReasoningIDs: &seenReasoningIDs)
        }
    }

    private static func chatGPTInputItem(
        _ item: Any,
        seenReasoningIDs: inout Set<String>
    ) -> Any? {
        guard let object = item as? [String: Any] else {
            return item
        }
        let type = (object["type"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard type == "reasoning" else {
            return item
        }
        return chatGPTReasoningInputItem(
            from: object,
            seenReasoningIDs: &seenReasoningIDs
        )
    }

    private static func chatGPTReasoningInputItem(
        from item: [String: Any],
        seenReasoningIDs: inout Set<String>
    ) -> [String: Any]? {
        // Summary-only reasoning items cannot restore the reasoning chain
        // without the encrypted payload; replaying them only spends tokens.
        guard let encrypted = RemoteGenerationClient.stringValue(item["encrypted_content"])?.nilIfBlank
            ?? RemoteGenerationClient.stringValue(item["encryptedContent"])?.nilIfBlank else {
            return nil
        }
        // The "id" is used only for local deduplication and intentionally not
        // replayed: with store=false the API tries to resolve it server-side
        // and rejects the request. encrypted_content is self-contained.
        if let id = RemoteGenerationClient.stringValue(item["id"])?.nilIfBlank,
           !seenReasoningIDs.insert(id).inserted {
            return nil
        }
        return [
            "type": "reasoning",
            "encrypted_content": encrypted,
            "summary": item["summary"] ?? []
        ]
    }

    public static func requestBody(
        input: JSONValue,
        model: String,
        instructions: String,
        reasoningEffort: String?,
        textVerbosity: String,
        sessionID: String,
        toolPayloads: JSONValue = .array([]),
        maxOutputTokens: Int? = nil
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "store": false,
            "stream": true,
            "instructions": instructions,
            "input": input.acpJSONObject,
            "text": [
                "verbosity": textVerbosity
            ],
            "include": [
                "reasoning.encrypted_content"
            ],
            "prompt_cache_key": promptCacheKey(
                instructions: instructions,
                toolPayloads: toolPayloads,
                fallbackSessionID: sessionID
            )
        ]

        if case let .array(tools) = toolPayloads, !tools.isEmpty {
            body["tools"] = toolPayloads.acpJSONObject
            body["tool_choice"] = "auto"
            body["parallel_tool_calls"] = true
        }

        if let maxOutputTokens, maxOutputTokens > 0 {
            body["max_output_tokens"] = maxOutputTokens
        }

        let normalizedReasoningEffort = reasoningEffort?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank
        if let normalizedReasoningEffort,
           normalizedReasoningEffort != "none" {
            body["reasoning"] = [
                "effort": normalizedReasoningEffort,
                "summary": "auto"
            ]
        }

        return body
    }

    /// Content-addressed prompt cache key derived from the static request
    /// prefix (instructions + tool schemas). Requests sharing the same prefix
    /// are routed to the same cache shard even across sessions, unlike a
    /// per-session identifier which is always cache-cold on a new session.
    public static func promptCacheKey(
        instructions: String?,
        toolPayloads: JSONValue,
        fallbackSessionID: String
    ) -> String {
        let normalizedInstructions = instructions?.nilIfBlank ?? ""
        var toolsPart = ""
        if case let .array(tools) = toolPayloads,
           !tools.isEmpty,
           let data = try? toolPayloads.jsonData(
               outputFormatting: [.withoutEscapingSlashes, .sortedKeys]
           ) {
            toolsPart = String(decoding: data, as: UTF8.self)
        }
        guard !(normalizedInstructions.isEmpty && toolsPart.isEmpty) else {
            return fallbackSessionID
        }
        // \u{0} separator so instructions ending in the tool JSON cannot
        // collide with a request embedding that JSON in the instructions.
        let content = "\(normalizedInstructions)\u{0}\(toolsPart)"
        let digest = SHA256.hash(data: Data(content.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "pck_\(String(hex.prefix(24)))"
    }

    public static func estimatedContextTokenCount(
        instructions: String?,
        input: [Any],
        toolPayloads: [[String: Any]]
    ) -> Int? {
        var payload: [String: Any] = [:]
        if let instructions = instructions?.nilIfBlank {
            payload["instructions"] = instructions
        }
        if !input.isEmpty {
            payload["input"] = input
        }
        if !toolPayloads.isEmpty {
            payload["tools"] = toolPayloads
        }

        guard !payload.isEmpty,
              let data = try? JSONValue(jsonObject: payload).jsonData(
                  outputFormatting: [.withoutEscapingSlashes]
              ),
              !data.isEmpty else {
            return nil
        }
        return max(Int((Double(data.count) / 4.0).rounded(.up)), 1)
    }
}
#endif
