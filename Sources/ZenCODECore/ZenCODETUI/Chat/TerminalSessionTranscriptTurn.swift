//
//  TerminalSessionTranscriptTurn.swift
//  ZenCODE
//

import Foundation

actor TerminalSessionTranscriptTurn {
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
                toolCallID: toolCall.id,
                toolName: toolCall.name
            )
        )
    }

    func messages(finalResponseText: String? = nil) -> [AgentRuntimeMessage] {
        if let finalResponseText,
           shouldPromoteReasoningToContent(finalResponseText) {
            assistantContent = finalResponseText
            reasoningContent = ""
        }
        flushAssistantMessage()
        return transcriptMessages
    }

    func shouldPromoteReasoningToContent(_ finalResponseText: String) -> Bool {
        let finalText = finalResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty,
              assistantContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !reasoningContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return true
    }

    func flushAssistantMessage() {
        guard assistantContent.nilIfBlank != nil
            || reasoningContent.nilIfBlank != nil else {
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
