//
//  ChatTurnEntry+Transcript.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/11/26.
//

import Foundation
import ToolCore

extension ChatTurnEntry {
    /// The entries of one closed assistant block: its reasoning, trimmed as
    /// ``AgentRuntimeMessage`` stores it, then its content as streamed, each
    /// only when it is not blank. The one definition of a block's entries,
    /// shared by the live log and the transcript rebuild.
    static func blockKinds(assistantContent: String, reasoningContent: String?) -> [Kind] {
        var kinds: [Kind] = []
        if let reasoning = reasoningContent?.nilIfBlank {
            kinds.append(.thought(reasoning))
        }
        if assistantContent.nilIfBlank != nil {
            kinds.append(.assistantText(assistantContent))
        }
        return kinds
    }

    /// Rebuilds a transcript (the controller's ``ChatSessionController/transcript``,
    /// a saved session's transcript, or a runtime history) as log entries,
    /// oldest first. The one transcript rebuild of the log: the controller
    /// uses it when it restores a saved session.
    ///
    /// - A user message is a turn's ``Kind/userPrompt(text:attachments:origin:)``,
    ///   with an ``ChatTurnOrigin/unknown`` origin, which the transcript does
    ///   not record.
    /// - An assistant message is a block (``blockKinds(assistantContent:reasoningContent:)``)
    ///   followed by a ``Kind/toolCallStarted(_:)`` for each of its tool calls.
    /// - A tool message is the ``Kind/toolCallCompleted(_:result:)`` of the
    ///   call with its ID, preceded by a ``Kind/toolCallStarted(_:)`` when
    ///   the call did not start earlier in the same turn. The result keeps
    ///   what the transcript stores: the output, the attachments, and the
    ///   error flag.
    /// - System messages (the truncation marker) are skipped.
    ///
    /// A tool call without an ID gets `restored-tool-<message>-<call>`, from
    /// its position, so a rebuild of the same transcript is always equal.
    static func kinds(fromTranscript messages: [AgentRuntimeMessage]) -> [Kind] {
        var kinds: [Kind] = []
        var startedCalls: [String: DirectAgentToolCall] = [:]
        for (messageIndex, message) in messages.enumerated() {
            switch message.role {
            case .system:
                continue
            case .user:
                startedCalls = [:]
                kinds.append(.userPrompt(
                    text: message.content,
                    attachments: message.attachments,
                    origin: .unknown
                ))
            case .assistant:
                kinds.append(contentsOf: blockKinds(
                    assistantContent: message.content,
                    reasoningContent: message.reasoningContent
                ))
                for (callIndex, toolCall) in message.toolCalls.enumerated() {
                    let call = restoredToolCall(
                        id: toolCall.id ?? "restored-tool-\(messageIndex)-\(callIndex)",
                        name: toolCall.name,
                        argumentsJSON: toolCall.argumentsJSON
                    )
                    guard startedCalls[call.id] == nil else { continue }
                    startedCalls[call.id] = call
                    kinds.append(.toolCallStarted(call))
                }
            case .tool:
                let callID = message.toolCallID ?? "restored-tool-\(messageIndex)-0"
                let call: DirectAgentToolCall
                if let started = startedCalls[callID] {
                    call = started
                } else {
                    call = restoredToolCall(
                        id: callID,
                        name: message.toolName ?? "tool.result",
                        argumentsJSON: "{}"
                    )
                    startedCalls[callID] = call
                    kinds.append(.toolCallStarted(call))
                }
                kinds.append(.toolCallCompleted(call, result: DirectAgentToolResult(
                    output: message.content,
                    summary: restoredToolResultSummary(message.content),
                    status: message.toolResultIsError == true ? .failed : .completed,
                    attachments: message.attachments
                )))
            }
        }
        return kinds
    }

    private static func restoredToolCall(
        id: String,
        name: String,
        argumentsJSON: String
    ) -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: id,
            name: name,
            argumentsObject: DirectToolExecutor.toolArguments(from: argumentsJSON)
                .mapValues(\.jsonObject),
            argumentsJSON: argumentsJSON
        )
    }

    /// The transcript of `entries` as runtime messages, oldest first: the
    /// inverse of ``kinds(fromTranscript:)``, for a channel that renders log
    /// entries with the renderer of a saved transcript (the terminal's
    /// catch-up after `/telegram off`).
    ///
    /// - A ``Kind/userPrompt(text:attachments:origin:)`` is a user message.
    /// - A ``Kind/thought(_:)`` and the ``Kind/assistantText(_:)`` that follows
    ///   it form one assistant message (reasoning and content); the
    ///   ``Kind/toolCallStarted(_:)`` entries that follow the block are its
    ///   tool calls. Tool calls without a preceding block form an assistant
    ///   message without content.
    /// - A ``Kind/toolCallCompleted(_:result:)`` is the tool message of its
    ///   call, with the result's output and error flag.
    /// - Every other kind (artifacts, notices, phases) has no message.
    static func transcriptMessages(from entries: [ChatTurnEntry]) -> [AgentRuntimeMessage] {
        var messages: [AgentRuntimeMessage] = []
        var pendingReasoning: String?
        var pendingContent: String?
        var pendingToolCalls: [AgentRuntimeToolCall] = []

        func flushAssistantMessage() {
            guard pendingReasoning != nil || pendingContent != nil || !pendingToolCalls.isEmpty else {
                return
            }
            messages.append(AgentRuntimeMessage(
                role: .assistant,
                content: pendingContent ?? "",
                reasoningContent: pendingReasoning,
                toolCalls: pendingToolCalls
            ))
            pendingReasoning = nil
            pendingContent = nil
            pendingToolCalls = []
        }

        for entry in entries {
            switch entry.kind {
            case let .userPrompt(text, attachments, _):
                flushAssistantMessage()
                messages.append(AgentRuntimeMessage(role: .user, content: text, attachments: attachments))
            case let .thought(text):
                // A thought opens a new block: the previous one is complete.
                flushAssistantMessage()
                pendingReasoning = text
            case let .assistantText(text):
                if pendingContent != nil || !pendingToolCalls.isEmpty {
                    flushAssistantMessage()
                }
                pendingContent = text
            case let .toolCallStarted(call):
                pendingToolCalls.append(AgentRuntimeToolCall(
                    id: call.id,
                    name: call.name,
                    argumentsJSON: call.argumentsJSON
                ))
            case let .toolCallCompleted(call, result):
                flushAssistantMessage()
                messages.append(AgentRuntimeMessage(
                    role: .tool,
                    content: result.output,
                    attachments: result.attachments,
                    toolCallID: call.id,
                    toolName: call.name,
                    toolResultIsError: result.status == .failed ? true : nil
                ))
            case .fileArtifacts, .notice, .workflowNotice, .turnPhase:
                continue
            }
        }
        flushAssistantMessage()
        return messages
    }

    /// The first line of a restored tool output, which stands in for the
    /// summary the transcript does not store.
    private static func restoredToolResultSummary(_ output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
    }
}

extension ChatTurnEntry {
    /// The bytes the entry keeps alive, estimated the way the controller
    /// estimates a transcript message (`transcriptRetainedByteCount(_:)`): a
    /// fixed overhead per value plus the UTF-8 bytes of its text, with the
    /// same per-attachment and per-tool-call counts. The log is bounded by
    /// ``ChatSessionController/maximumTranscriptBytes`` on this estimate.
    var retainedByteCount: Int {
        var total = 256
        switch kind {
        case let .userPrompt(text, attachments, _):
            ChatSessionController.addRetainedBytes(text, to: &total)
            for attachment in attachments {
                total = ChatSessionController.saturatingSum(
                    total,
                    ChatSessionController.transcriptRetainedByteCount(attachment)
                )
            }
        case let .assistantText(text), let .thought(text):
            ChatSessionController.addRetainedBytes(text, to: &total)
        case let .toolCallStarted(call):
            total = ChatSessionController.saturatingSum(total, Self.retainedByteCount(call))
        case let .toolCallCompleted(call, result):
            total = ChatSessionController.saturatingSum(total, Self.retainedByteCount(call))
            total = ChatSessionController.saturatingSum(total, Self.retainedByteCount(result))
        case let .fileArtifacts(turn, agentID, _):
            ChatSessionController.addRetainedBytes(agentID, to: &total)
            for artifact in turn.artifacts {
                total = ChatSessionController.saturatingSum(total, 128)
                ChatSessionController.addRetainedBytes(artifact.absolutePath, to: &total)
                ChatSessionController.addRetainedBytes(artifact.displayPath, to: &total)
                ChatSessionController.addRetainedBytes(artifact.oldText, to: &total)
                ChatSessionController.addRetainedBytes(artifact.newText, to: &total)
                ChatSessionController.addRetainedBytes(artifact.patch, to: &total)
                ChatSessionController.addRetainedBytes(artifact.explanation, to: &total)
            }
        case let .notice(notice):
            ChatSessionController.addRetainedBytes(ChatSessionNoticeText.text(for: notice), to: &total)
        case let .workflowNotice(notice):
            if case let .blocked(graphID, message) = notice {
                ChatSessionController.addRetainedBytes(graphID, to: &total)
                ChatSessionController.addRetainedBytes(message, to: &total)
            }
        case let .turnPhase(phase):
            if case let .ended(outcome) = phase {
                ChatSessionController.addRetainedBytes(outcome.message, to: &total)
            }
        }
        return total
    }

    private static func retainedByteCount(_ call: DirectAgentToolCall) -> Int {
        var total = ChatSessionController.transcriptRetainedToolCallByteCount(
            id: call.id,
            name: call.name,
            argumentsJSON: call.argumentsJSON
        )
        ChatSessionController.addRetainedBytes(call.descriptorTitle, to: &total)
        return total
    }

    private static func retainedByteCount(_ result: DirectAgentToolResult) -> Int {
        var total = 0
        ChatSessionController.addRetainedBytes(result.output, to: &total)
        ChatSessionController.addRetainedBytes(result.summary, to: &total)
        if result.modelOutput != result.output {
            ChatSessionController.addRetainedBytes(result.modelOutput, to: &total)
        }
        for attachment in result.attachments {
            total = ChatSessionController.saturatingSum(
                total,
                ChatSessionController.transcriptRetainedByteCount(attachment)
            )
        }
        for change in result.fileChanges {
            total = ChatSessionController.saturatingSum(total, 128)
            ChatSessionController.addRetainedBytes(change.path, to: &total)
            ChatSessionController.addRetainedBytes(change.oldText, to: &total)
            ChatSessionController.addRetainedBytes(change.newText, to: &total)
            ChatSessionController.addRetainedBytes(change.explanation, to: &total)
            ChatSessionController.addRetainedBytes(change.compactDiff?.patch, to: &total)
        }
        return total
    }
}
