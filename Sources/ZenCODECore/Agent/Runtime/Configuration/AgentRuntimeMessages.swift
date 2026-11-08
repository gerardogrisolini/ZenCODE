//
//  AgentRuntimeMessages.swift
//  ZenCODE
//
//  Attachments, tool calls, messages and session snapshots exchanged with a
//  runtime backend.
//

import ToolCore
import Foundation

public struct AgentRuntimeAttachment: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case image
        case video
    }

    public let kind: Kind
    public let fileURL: URL?
    public let data: Data?
    public let contentType: String?
    public let originalFilename: String

    public init(
        kind: Kind,
        fileURL: URL? = nil,
        data: Data? = nil,
        contentType: String? = nil,
        originalFilename: String
    ) {
        self.kind = kind
        self.fileURL = fileURL
        self.data = data
        self.contentType = contentType?.nilIfBlank
        self.originalFilename = originalFilename.nilIfBlank ?? "attachment"
    }
}

public struct AgentRuntimeToolCall: Codable, Equatable, Sendable {
    public let id: String?
    public let name: String
    public let argumentsJSON: String

    public init(
        id: String?,
        name: String,
        argumentsJSON: String
    ) {
        self.id = id?.nilIfBlank
        self.name = name.nilIfBlank ?? "tool"
        self.argumentsJSON = argumentsJSON.nilIfBlank ?? "{}"
    }
}

public struct AgentRuntimeMessage: Codable, Equatable, Sendable {
    public enum Role: String, Codable, Sendable {
        case system
        case user
        case assistant
        case tool
    }

    public let role: Role
    public let content: String
    public let reasoningContent: String?
    public let reasoningItemsJSON: String?
    public let thinkingBlocksJSON: String?
    /// Ordered Anthropic assistant content blocks, serialized verbatim for
    /// signed-thinking/tool replay. Optional for backward-compatible snapshots.
    public let anthropicContentBlocksJSON: String?
    public let providerResponseID: String?
    public let attachments: [AgentRuntimeAttachment]
    public let toolCalls: [AgentRuntimeToolCall]
    public let toolCallID: String?
    public let toolName: String?
    /// Anthropic `tool_result.is_error`. Optional so snapshots written before
    /// this field was introduced continue to decode unchanged.
    public let toolResultIsError: Bool?

    public init(
        role: Role,
        content: String,
        reasoningContent: String? = nil,
        reasoningItemsJSON: String? = nil,
        thinkingBlocksJSON: String? = nil,
        anthropicContentBlocksJSON: String? = nil,
        providerResponseID: String? = nil,
        attachments: [AgentRuntimeAttachment] = [],
        toolCalls: [AgentRuntimeToolCall] = [],
        toolCallID: String? = nil,
        toolName: String? = nil,
        toolResultIsError: Bool? = nil
    ) {
        self.role = role
        self.content = content
        self.reasoningContent = reasoningContent?.nilIfBlank
        self.reasoningItemsJSON = reasoningItemsJSON?.nilIfBlank
        self.thinkingBlocksJSON = thinkingBlocksJSON?.nilIfBlank
        self.anthropicContentBlocksJSON = anthropicContentBlocksJSON?.nilIfBlank
        self.providerResponseID = providerResponseID?.nilIfBlank
        self.attachments = attachments
        self.toolCalls = toolCalls
        self.toolCallID = toolCallID?.nilIfBlank
        self.toolName = toolName?.nilIfBlank
        self.toolResultIsError = toolResultIsError
    }

    /// The same message with `content` and `reasoningContent` replaced; a
    /// `nil` argument keeps the current value. Every other field is kept.
    func replacing(
        content: String? = nil,
        reasoningContent: String? = nil
    ) -> AgentRuntimeMessage {
        AgentRuntimeMessage(
            role: role,
            content: content ?? self.content,
            reasoningContent: reasoningContent ?? self.reasoningContent,
            reasoningItemsJSON: reasoningItemsJSON,
            thinkingBlocksJSON: thinkingBlocksJSON,
            anthropicContentBlocksJSON: anthropicContentBlocksJSON,
            providerResponseID: providerResponseID,
            attachments: attachments,
            toolCalls: toolCalls,
            toolCallID: toolCallID,
            toolName: toolName,
            toolResultIsError: toolResultIsError
        )
    }
}

/// Encodes session-specific instructions as one recognisable leading user
/// message. The wire representation remains a normal user message for every
/// provider; the marker lets snapshots, restores, and compaction keep this
/// mutable context out of the durable conversation transcript.
public enum AgentRuntimeDynamicContext {
    public static let marker = "ZenCODE session context:\n"

    public static func message(for context: String?) -> AgentRuntimeMessage? {
        guard let context = context?.nilIfBlank else {
            return nil
        }
        return AgentRuntimeMessage(role: .user, content: marker + context)
    }

    public static func context(from message: AgentRuntimeMessage?) -> String? {
        guard let message,
              message.role == .user,
              message.attachments.isEmpty,
              message.toolCalls.isEmpty,
              message.toolCallID == nil,
              message.toolName == nil,
              message.content.hasPrefix(marker) else {
            return nil
        }
        return String(message.content.dropFirst(marker.count)).nilIfBlank
    }

    public static func separating(
        from history: [AgentRuntimeMessage]
    ) -> (context: String?, history: [AgentRuntimeMessage]) {
        guard let context = context(from: history.first) else {
            return (nil, history)
        }
        return (context, Array(history.dropFirst()))
    }

    public static func inserting(
        _ context: String?,
        into history: [AgentRuntimeMessage]
    ) -> [AgentRuntimeMessage] {
        guard let message = message(for: context) else {
            return history
        }
        return [message] + separating(from: history).history
    }
}

public struct AgentRuntimeSessionSnapshot: Sendable {
    public let sessionID: String
    public let modelID: String?
    public let workingDirectoryPath: String
    public let systemPrompt: String?
    public let dynamicContext: String?
    public let cacheKey: String?
    public let history: [AgentRuntimeMessage]
    public let allowedToolNames: Set<String>?
    public let thinkingSelection: AgentThinkingSelection?
    public let preserveThinking: Bool

    public init(
        sessionID: String,
        modelID: String? = nil,
        workingDirectoryPath: String,
        systemPrompt: String?,
        dynamicContext: String? = nil,
        cacheKey: String?,
        history: [AgentRuntimeMessage],
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        self.sessionID = sessionID.nilIfBlank ?? "agent-core-\(UUID().uuidString.lowercased())"
        self.modelID = modelID?.nilIfBlank
        self.workingDirectoryPath = workingDirectoryPath
        self.systemPrompt = systemPrompt?.nilIfBlank
        self.dynamicContext = dynamicContext?.nilIfBlank
        self.cacheKey = cacheKey?.nilIfBlank
        self.history = history
        self.allowedToolNames = allowedToolNames
        self.thinkingSelection = thinkingSelection
        self.preserveThinking = preserveThinking
    }
}

extension AgentRuntimeSessionSnapshot {
    public func replacingHistory(
        _ history: [AgentRuntimeMessage]
    ) -> AgentRuntimeSessionSnapshot {
        AgentRuntimeSessionSnapshot(
            sessionID: sessionID,
            modelID: modelID,
            workingDirectoryPath: workingDirectoryPath,
            systemPrompt: systemPrompt,
            dynamicContext: dynamicContext,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    /// Builds the message list used as compaction input: the optional system
    /// prompt, protected dynamic context, then recorded history. Shared by
    /// every local compaction flow so the context-message invariant stays
    /// consistent.
    public var compactionInputMessages: [AgentRuntimeMessage] {
        var messages: [AgentRuntimeMessage] = []
        if let systemPrompt = systemPrompt?.nilIfBlank {
            messages.append(AgentRuntimeMessage(role: .system, content: systemPrompt))
        }
        if let dynamicContextMessage = AgentRuntimeDynamicContext.message(for: dynamicContext) {
            messages.append(dynamicContextMessage)
        }
        messages.append(contentsOf: history)
        return messages
    }

    /// Rebuilds a snapshot from a compaction result, extracting the compacted
    /// system prompt from the head of the compacted messages when present.
    public func applyingCompaction(
        _ compactionResult: AgentConversationCompactionResult
    ) -> AgentRuntimeSessionSnapshot {
        var history = compactionResult.messages
        let systemPrompt: String?
        if history.first?.role == .system {
            systemPrompt = history.removeFirst().content
        } else {
            systemPrompt = self.systemPrompt
        }
        let separatedContext = AgentRuntimeDynamicContext.separating(from: history)
        return AgentRuntimeSessionSnapshot(
            sessionID: sessionID,
            modelID: modelID,
            workingDirectoryPath: workingDirectoryPath,
            systemPrompt: systemPrompt,
            dynamicContext: separatedContext.context ?? dynamicContext,
            cacheKey: cacheKey,
            history: separatedContext.history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }
}

public struct AgentRuntimeSessionCompactionResult: Sendable {
    public let snapshot: AgentRuntimeSessionSnapshot
    public let wasCompacted: Bool
    public let originalEstimatedTokenCount: Int
    public let estimatedTokenCount: Int
    public let maxTokens: Int?
    public let keptRecentMessageCount: Int

    public init(
        snapshot: AgentRuntimeSessionSnapshot,
        wasCompacted: Bool,
        originalEstimatedTokenCount: Int,
        estimatedTokenCount: Int,
        maxTokens: Int?,
        keptRecentMessageCount: Int
    ) {
        self.snapshot = snapshot
        self.wasCompacted = wasCompacted
        self.originalEstimatedTokenCount = originalEstimatedTokenCount
        self.estimatedTokenCount = estimatedTokenCount
        self.maxTokens = maxTokens
        self.keptRecentMessageCount = keptRecentMessageCount
    }

    public init(
        snapshot: AgentRuntimeSessionSnapshot,
        compactionResult: AgentConversationCompactionResult
    ) {
        self.init(
            snapshot: snapshot,
            wasCompacted: compactionResult.wasCompacted,
            originalEstimatedTokenCount: compactionResult.originalEstimatedTokenCount,
            estimatedTokenCount: compactionResult.estimatedTokenCount,
            maxTokens: compactionResult.maxTokens,
            keptRecentMessageCount: compactionResult.keptRecentMessageCount
        )
    }
}
