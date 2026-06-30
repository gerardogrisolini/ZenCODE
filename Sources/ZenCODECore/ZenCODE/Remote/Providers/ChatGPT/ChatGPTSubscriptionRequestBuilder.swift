//
//  ChatGPTSubscriptionRequestBuilder.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 15/06/26.
//
#if os(macOS)
import Foundation

public struct ChatGPTSubscriptionContinuationState: Equatable, Sendable {
    public let responseID: String
    public let messageCount: Int
    public let instructions: String

    public init(responseID: String, messageCount: Int, instructions: String) {
        self.responseID = responseID
        self.messageCount = messageCount
        self.instructions = instructions
    }
}

public enum ChatGPTSubscriptionRequestBuilder {
    public static func requestInputPayload(
        from messages: [[String: Any]],
        continuation: ChatGPTSubscriptionContinuationState?
    ) -> (instructions: String?, input: [Any], cachedWebSocketInput: [Any]?, previousResponseID: String?) {
        let fullPayload = RemoteGenerationClient.responsesInputPayload(from: messages)
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
        let deltaPayload = RemoteGenerationClient.responsesInputPayload(from: deltaMessages)
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
            "prompt_cache_key": sessionID
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
