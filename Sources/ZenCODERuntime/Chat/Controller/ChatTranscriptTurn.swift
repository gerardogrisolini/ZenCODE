//
//  ChatTranscriptTurn.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The transcript of one chat turn, assembled from runtime events.
///
/// Tool calls split coordinator content into blocks: the last block, not the
/// runtime's aggregated response text, is the turn's final assistant content.
actor ChatTranscriptTurn {
    var transcriptMessages: [AgentRuntimeMessage]
    var assistantContent = ""
    var reasoningContent = ""
    var startedToolCallIDs = Set<String>()
    var completedToolCallIDs = Set<String>()

    init(prompt: String, attachments: [AgentRuntimeAttachment]) {
        let userMessage = AgentRuntimeMessage(
            role: .user,
            content: prompt,
            attachments: attachments
        )
        self.transcriptMessages = [userMessage]
    }

    func appendThought(_ delta: String) {
        reasoningContent.append(delta)
    }

    func appendAssistantContent(_ delta: String) {
        assistantContent.append(delta)
    }

    /// The final assistant block in this turn. Tool calls deliberately split
    /// assistant output into blocks, so callers must not infer its meaning from
    /// the runtime's aggregated final response text.
    func lastAssistantContent() -> String? {
        if let content = assistantContent.nilIfBlank {
            return content
        }
        return transcriptMessages.reversed().lazy.compactMap { message in
            message.role == .assistant ? message.content.nilIfBlank : nil
        }.first
    }

    func appendToolCallStarted(_ toolCall: DirectAgentToolCall) {
        guard startedToolCallIDs.insert(toolCall.id).inserted else {
            return
        }
        flushAssistantMessage()
        transcriptMessages.append(
            AgentRuntimeMessage(
                role: .assistant,
                content: "",
                toolCalls: [Self.runtimeToolCall(from: toolCall)]
            )
        )
    }

    func appendToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) {
        appendToolCallStarted(toolCall)
        guard completedToolCallIDs.insert(toolCall.id).inserted else {
            return
        }
        transcriptMessages.append(
            AgentRuntimeMessage(
                role: .tool,
                content: result.output,
                attachments: result.attachments,
                toolCallID: toolCall.id,
                toolName: toolCall.name
            )
        )
    }

    /// Closes the last block with `finalResponseText` (see
    /// ``ChatTurnBlockRules/finalBlock(assistantContent:reasoningContent:finalResponseText:)``)
    /// and returns the turn's messages.
    func messages(finalResponseText: String? = nil) -> [AgentRuntimeMessage] {
        let block = ChatTurnBlockRules.finalBlock(
            assistantContent: assistantContent,
            reasoningContent: reasoningContent,
            finalResponseText: finalResponseText
        )
        assistantContent = block.assistantContent
        reasoningContent = block.reasoningContent
        flushAssistantMessage()
        return transcriptMessages
    }

    func flushAssistantMessage() {
        guard ChatTurnBlockRules.hasBlock(
            assistantContent: assistantContent,
            reasoningContent: reasoningContent
        ) else {
            return
        }
        transcriptMessages.append(
            AgentRuntimeMessage(
                role: .assistant,
                content: assistantContent,
                reasoningContent: reasoningContent
            )
        )
        assistantContent = ""
        reasoningContent = ""
    }

    static func runtimeToolCall(
        from toolCall: DirectAgentToolCall
    ) -> AgentRuntimeToolCall {
        AgentRuntimeToolCall(
            id: toolCall.id,
            name: toolCall.name,
            argumentsJSON: toolCall.argumentsJSON
        )
    }
}
