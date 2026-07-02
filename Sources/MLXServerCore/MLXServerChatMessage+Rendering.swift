//
//  MLXServerChatMessage+Rendering.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 25/05/26.
//

import CryptoKit
import Foundation
import MLX
@preconcurrency import MLXLMCommon
import Tokenizers

extension MLXServerChatMessage {
    func rawTemplateMessage(
        toolResultStyle: MLXServerToolResultTemplateStyle
    ) -> [String: any Sendable] {
        switch role {
        case .system, .user:
            return [
                "role": role.rawValue,
                "content": content
            ]
        case .assistant:
            var message: [String: any Sendable] = [
                "role": role.rawValue,
                "content": content
            ]
            if let reasoningContent {
                message["reasoning_content"] = reasoningContent
            }
            if !toolCalls.isEmpty {
                message["tool_calls"] = toolCalls.map(Self.rawToolCallPayload)
            }
            return message
        case .tool:
            return rawToolResultMessage(style: toolResultStyle)
        }
    }

    private func rawToolResultMessage(
        style: MLXServerToolResultTemplateStyle
    ) -> [String: any Sendable] {
        var message: [String: any Sendable] = [
            "role": role.rawValue,
            "content": style == .toolResponses ? "" : content
        ]
        if let toolCallID {
            message["tool_call_id"] = toolCallID
        }
        if let toolName {
            message["name"] = toolName
        }
        if style == .toolResponses {
            message["tool_responses"] = [
                [
                    "name": toolName ?? "unknown",
                    "response": content
                ] as [String: any Sendable]
            ]
        }
        return message
    }

    private static func rawToolCallPayload(
        _ toolCall: MLXServerChatToolCall
    ) -> [String: any Sendable] {
        var payload: [String: any Sendable] = [
            "type": "function",
            "function": [
                "name": toolCall.function.name,
                "arguments": toolCall.function.arguments.mapValues(Self.sendableTemplateValue)
            ] as [String: any Sendable]
        ]
        if let id = toolCall.id?.trimmingCharacters(in: .whitespacesAndNewlines),
           !id.isEmpty {
            payload["id"] = id
        }
        return payload
    }

    private static func sendableTemplateValue(_ value: JSONValue) -> any Sendable {
        switch value {
        case .null:
            return "null"
        case .bool(let value):
            return value
        case .int(let value):
            return value
        case .double(let value):
            return value
        case .string(let value):
            return value
        case .array(let values):
            return values.map(Self.sendableTemplateValue)
        case .object(let values):
            return values.mapValues(Self.sendableTemplateValue)
        }
    }

    var mlxChatMessage: Chat.Message {
        Chat.Message(
            role: mlxRole,
            content: templateContent,
            images: imageURLs.map(UserInput.Image.url),
            videos: videoURLs.map(UserInput.Video.url)
        )
    }

    /// `Chat.Message` carries plain content only; assistant tool calls are
    /// rendered inline so transcript rehydration keeps the calls visible to
    /// the model even without template-native tool-call structures.
    private var templateContent: String {
        guard role == .assistant, !toolCalls.isEmpty else {
            return content
        }
        let renderedCalls = toolCalls.map(Self.toolCallTemplateContent)
        let callsText = renderedCalls.joined(separator: "\n")
        return content.isEmpty ? callsText : "\(content)\n\(callsText)"
    }

    private static func toolCallTemplateContent(_ toolCall: MLXServerChatToolCall) -> String {
        var lines = [
            "<tool_call>",
            "<function=\(toolCall.function.name)>"
        ]
        for key in toolCall.function.arguments.keys.sorted() {
            guard let value = toolCall.function.arguments[key] else {
                continue
            }
            lines.append("<parameter=\(key)>")
            lines.append(toolArgumentTemplateValue(value))
            lines.append("</parameter>")
        }
        lines.append("</function>")
        lines.append("</tool_call>")
        return lines.joined(separator: "\n")
    }

    private static func toolArgumentTemplateValue(_ value: JSONValue) -> String {
        if case .string(let string) = value {
            return string
        }
        guard JSONSerialization.isValidJSONObject(value.anyValue),
              let data = try? JSONSerialization.data(
                  withJSONObject: value.anyValue,
                  options: [.sortedKeys, .withoutEscapingSlashes]
              ) else {
            return String(describing: value.anyValue)
        }
        return String(decoding: data, as: UTF8.self)
    }

    var mlxRole: Chat.Message.Role {
        switch role {
        case .system:
            .system
        case .user:
            .user
        case .assistant:
            .assistant
        case .tool:
            .tool
        }
    }
}
