#if ZENCODE_LOCAL_MLX
//
//  MLXServerCoderBackend+Transcript.swift
//  ZenCODE
//

import Foundation
import ZenCODECore
@preconcurrency import MLXLMCommon
import MLXServerCore

extension MLXServerCoderBackend {
    static func initialMessages(
        systemPrompt: String?,
        history: [AgentRuntimeMessage]
    ) -> [MLXServerChatMessage] {
        var messages: [MLXServerChatMessage] = []
        if let systemPrompt = systemPrompt?.nilIfBlank {
            messages.append(.system(systemPrompt))
        }
        messages.append(
            contentsOf: history.map { message in
                serverMessage(
                    role: message.role,
                    content: message.content,
                    reasoningContent: message.reasoningContent,
                    attachments: message.attachments
                )
            }
        )
        return messages
    }

    static func replacingSystemPrompt(
        in messages: [MLXServerChatMessage],
        with systemPrompt: String?
    ) -> [MLXServerChatMessage] {
        let prompt = systemPrompt?.nilIfBlank
        var updatedMessages = messages
        if updatedMessages.first?.role == .system {
            if let prompt {
                updatedMessages[0] = .system(prompt)
            } else {
                updatedMessages.removeFirst()
            }
        } else if let prompt {
            updatedMessages.insert(.system(prompt), at: 0)
        }
        return updatedMessages
    }

    static func snapshotMessages(
        from messages: [MLXServerChatMessage]
    ) -> (systemPrompt: String?, history: [AgentRuntimeMessage]) {
        var remainingMessages = messages[...]
        let systemPrompt: String?
        if remainingMessages.first?.role == .system {
            systemPrompt = remainingMessages.first?.content.nilIfBlank
            remainingMessages = remainingMessages.dropFirst()
        } else {
            systemPrompt = nil
        }

        return (
            systemPrompt,
            remainingMessages.map(snapshotMessage(from:))
        )
    }

    static func snapshotMessage(
        from message: MLXServerChatMessage
    ) -> AgentRuntimeMessage {
        let attachments =
            message.imageURLs.map {
                AgentRuntimeAttachment(
                    kind: .image,
                    fileURL: $0,
                    originalFilename: $0.lastPathComponent
                )
            }
            + message.videoURLs.map {
                AgentRuntimeAttachment(
                    kind: .video,
                    fileURL: $0,
                    originalFilename: $0.lastPathComponent
                )
            }
        let toolCalls = message.toolCalls.map { toolCall in
            AgentRuntimeToolCall(
                id: toolCall.id,
                name: toolCall.function.name,
                argumentsJSON: jsonString(
                    from: toolCall.function.arguments.mapValues(\.anyValue)
                ) ?? "{}"
            )
        }
        return AgentRuntimeMessage(
            role: AgentRuntimeMessage.Role(rawValue: message.role.rawValue) ?? .user,
            content: message.content,
            reasoningContent: message.reasoningContent,
            attachments: attachments,
            toolCalls: toolCalls,
            toolCallID: message.toolCallID
        )
    }

    static func agentRuntimeMessage(
        from message: MLXServerChatMessage
    ) -> AgentRuntimeMessage {
        let attachments =
            message.imageURLs.map {
                AgentRuntimeAttachment(
                    kind: .image,
                    fileURL: $0,
                    originalFilename: $0.lastPathComponent
                )
            }
            + message.videoURLs.map {
                AgentRuntimeAttachment(
                    kind: .video,
                    fileURL: $0,
                    originalFilename: $0.lastPathComponent
                )
            }
        return AgentRuntimeMessage(
            role: AgentRuntimeMessage.Role(rawValue: message.role.rawValue) ?? .user,
            content: Self.compactionContent(from: message),
            attachments: attachments
        )
    }

    static func compactionContent(from message: MLXServerChatMessage) -> String {
        var sections: [String] = []
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            sections.append(message.content)
        }
        if !message.toolCalls.isEmpty {
            let names = message.toolCalls.map(\.function.name).joined(separator: ", ")
            sections.append("Assistant requested tools: \(names).")
        }
        if message.role == .tool, let toolCallID = message.toolCallID?.nilIfBlank {
            sections.append("Tool result id: \(toolCallID).")
        }
        if message.role == .tool, let toolName = message.toolName?.nilIfBlank {
            sections.append("Tool name: \(toolName).")
        }
        return sections.joined(separator: "\n\n")
    }

    static func serverMessage(
        from message: AgentRuntimeMessage
    ) -> MLXServerChatMessage {
        serverMessage(
            role: message.role,
            content: message.content,
            reasoningContent: message.reasoningContent,
            attachments: message.attachments,
            toolCalls: message.toolCalls,
            toolCallID: message.toolCallID,
            toolName: message.toolName
        )
    }

    static func serverMessage(
        role: AgentRuntimeMessage.Role,
        content: String,
        reasoningContent: String? = nil,
        attachments: [AgentRuntimeAttachment],
        toolCalls runtimeToolCalls: [AgentRuntimeToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil
    ) -> MLXServerChatMessage {
        let imageURLs = attachments.compactMap { attachment -> URL? in
            attachment.kind == .image ? attachment.fileURL : nil
        }
        let videoURLs = attachments.compactMap { attachment -> URL? in
            attachment.kind == .video ? attachment.fileURL : nil
        }

        switch role {
        case .system:
            return .system(content)
        case .user:
            return .user(content, imageURLs: imageURLs, videoURLs: videoURLs)
        case .assistant:
            let toolCalls = runtimeToolCalls.map { toolCall in
                MLXServerChatToolCall(
                    id: toolCall.id,
                    name: toolCall.name,
                    arguments: sendableJSONObject(from: toolCall.argumentsJSON) ?? [:]
                )
            }
            return .assistant(
                content,
                reasoningContent: reasoningContent,
                toolCalls: toolCalls
            )
        case .tool:
            return .tool(content, toolCallID: toolCallID, toolName: toolName)
        }
    }

    static func directToolCall(from toolCall: ToolCall) -> DirectAgentToolCall {
        let argumentsObject = toolCall.function.arguments.mapValues(\.anyValue)
        return DirectAgentToolCall(
            id: "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
            name: toolCall.function.name,
            argumentsObject: argumentsObject,
            argumentsJSON: jsonString(from: argumentsObject) ?? "{}"
        )
    }

    static func sendableJSONObject(from jsonString: String) -> [String: any Sendable]? {
        guard let data = jsonString.data(using: .utf8),
              let object = try? JSONDecoder().decode(ZenCODECore.JSONValue.self, from: data).mlxObjectValue else {
            return nil
        }
        var sendableObject: [String: any Sendable] = [:]
        for (key, value) in object {
            sendableObject[key] = value.sendableValue
        }
        return sendableObject
    }

    static func jsonString(from object: [String: Any]) -> String? {
        JSONValue(jsonObject: object).compactString(sortedKeys: true)
    }
}

#endif
