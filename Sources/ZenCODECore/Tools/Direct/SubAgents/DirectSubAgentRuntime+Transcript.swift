//
//  DirectSubAgentRuntime+Transcript.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 03/11/26.
//

import Foundation
import ToolCore

extension DirectSubAgentRuntime {
    /// The live transcript of the agent `agentID` of the root session
    /// `rootSessionID`, oldest first: its backend's current history, read in
    /// full, so the transcript of a running turn grows as the backend records
    /// it.
    ///
    /// The history is rebuilt with ``ChatTurnEntry/kinds(fromTranscript:)``
    /// and completed, for presentation only, with what the history does not
    /// keep:
    ///
    /// - An assistant message without reasoning shows the text of its
    ///   `thinking` blocks (``AgentRuntimeMessage/thinkingBlocksJSON``), joined
    ///   by a blank line, as its thought: a provider that keeps its reasoning
    ///   only in those blocks (Anthropic) still has it in the transcript.
    ///   `redacted_thinking` blocks have no text and are skipped. Reasoning the
    ///   message already has always wins.
    /// - A tool call gets the title and the presentation of the agent's own
    ///   tool descriptor with its name
    ///   (``AgentRuntimeBackend/activeToolDescriptors(sessionID:)``), so it is
    ///   shown with its target as it was live; the first descriptor wins when
    ///   names repeat. A call without a descriptor is left as rebuilt. The
    ///   descriptors are requested only when the transcript has a tool call:
    ///   by then the backend has already listed the agent's tools for its
    ///   requests, so a read never starts a feature's tool discovery
    ///   (`--list-tools`) or the consent it can ask for.
    ///
    /// The transcript also carries the durations of the agent's completed
    /// tool calls (``ChatSubAgentTranscript/toolDurations``, by tool call id):
    /// the time the tool executor measured for each call
    /// (``DirectAgentToolResult/elapsed``), recorded when the runtime handles
    /// its `.toolCallCompleted` event, for the agent's last 512 calls
    /// (`maximumRetainedToolCallDurationsPerAgent`). Every backend records a
    /// tool result in the history before it reports the completion, so a read
    /// between the two can show a completed call whose duration is not there
    /// yet: a later read has it.
    ///
    /// The read itself keeps no state: the runtime stores no copy of the
    /// history or of the descriptors, and the history itself is not changed;
    /// the durations are kept in memory only, in the agent's record.
    /// `nil` when no such agent exists, it belongs to another root session,
    /// or its backend no longer has the agent's session (the backend was shut
    /// down: the agent was closed, cancelled, failed, or released from
    /// standby). A caller that wants to show the conversation after the agent
    /// ends keeps its own last read.
    public func transcript(
        agentID: String,
        rootSessionID: String
    ) async -> ChatSubAgentTranscript? {
        guard let agent = agents[agentID],
              agent.rootSessionID == rootSessionID,
              let history = await agent.backend.snapshotSession(id: agent.sessionID)?.history else {
            return nil
        }
        // Actor reentrancy: while the backend was read the agent may have been
        // pruned or its record replaced. Decide on the record as it is after
        // the suspension.
        guard let current = agents[agentID],
              current.rootSessionID == rootSessionID else {
            return nil
        }
        let kinds = ChatTurnEntry.kinds(
            fromTranscript: history.map(Self.transcriptMessageWithThinkingBlockReasoning)
        )
        guard kinds.contains(where: Self.isToolCallKind) else {
            return ChatSubAgentTranscript(
                agentID: agentID,
                kinds: kinds,
                toolDurations: current.toolCallDurations.byCallID
            )
        }
        let descriptors = await current.backend.activeToolDescriptors(
            sessionID: current.sessionID
        )
        // Actor reentrancy again: decide on the record as it is after the
        // descriptors were read, its durations included.
        guard let latest = agents[agentID],
              latest.rootSessionID == rootSessionID else {
            return nil
        }
        let descriptorsByName = Dictionary(
            descriptors.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return ChatSubAgentTranscript(
            agentID: agentID,
            kinds: kinds.map { Self.transcriptKind($0, presentedWith: descriptorsByName) },
            toolDurations: latest.toolCallDurations.byCallID
        )
    }

    /// `message` with the text of its `thinking` blocks as its reasoning, when
    /// it is an assistant message without reasoning whose blocks have text;
    /// otherwise `message` unchanged. Every other field is kept.
    private static func transcriptMessageWithThinkingBlockReasoning(
        _ message: AgentRuntimeMessage
    ) -> AgentRuntimeMessage {
        guard message.role == .assistant,
              message.reasoningContent == nil,
              let reasoning = thinkingText(fromThinkingBlocksJSON: message.thinkingBlocksJSON) else {
            return message
        }
        return AgentRuntimeMessage(
            role: message.role,
            content: message.content,
            reasoningContent: reasoning,
            reasoningItemsJSON: message.reasoningItemsJSON,
            thinkingBlocksJSON: message.thinkingBlocksJSON,
            anthropicContentBlocksJSON: message.anthropicContentBlocksJSON,
            providerResponseID: message.providerResponseID,
            attachments: message.attachments,
            toolCalls: message.toolCalls,
            toolCallID: message.toolCallID,
            toolName: message.toolName,
            toolResultIsError: message.toolResultIsError
        )
    }

    /// The `thinking` text of the blocks in `json` (a JSON array of block
    /// objects), in order and joined by a blank line. Only `thinking` blocks
    /// count, whatever their signature; blocks without text are skipped.
    /// `nil` when `json` is not such an array or no block has text.
    private static func thinkingText(fromThinkingBlocksJSON json: String?) -> String? {
        guard let data = json?.data(using: .utf8),
              let decoded = try? JSONDecoder().decode(JSONValue.self, from: data),
              case let .array(blocks) = decoded else {
            return nil
        }
        let texts = blocks.compactMap { block -> String? in
            guard case let .object(fields) = block,
                  fields["type"] == .string("thinking"),
                  case let .string(text)? = fields["thinking"] else {
                return nil
            }
            return text.nilIfBlank
        }
        return texts.joined(separator: "\n\n").nilIfBlank
    }

    private static func isToolCallKind(_ kind: ChatTurnEntry.Kind) -> Bool {
        switch kind {
        case .toolCallStarted, .toolCallCompleted:
            true
        default:
            false
        }
    }

    /// `kind` with its tool call presented by its descriptor, if any.
    private static func transcriptKind(
        _ kind: ChatTurnEntry.Kind,
        presentedWith descriptorsByName: [String: DirectToolDescriptor]
    ) -> ChatTurnEntry.Kind {
        switch kind {
        case let .toolCallStarted(call):
            .toolCallStarted(presentedToolCall(call, descriptorsByName: descriptorsByName))
        case let .toolCallCompleted(call, result):
            .toolCallCompleted(
                presentedToolCall(call, descriptorsByName: descriptorsByName),
                result: result
            )
        default:
            kind
        }
    }

    /// `call` with the title and the presentation of its descriptor: the same
    /// ID, name, and arguments. `call` unchanged when it has no descriptor.
    private static func presentedToolCall(
        _ call: DirectAgentToolCall,
        descriptorsByName: [String: DirectToolDescriptor]
    ) -> DirectAgentToolCall {
        guard let descriptor = descriptorsByName[call.name] else {
            return call
        }
        return DirectAgentToolCall(
            id: call.id,
            name: call.name,
            argumentsObject: call.argumentsObject,
            argumentsJSON: call.argumentsJSON,
            descriptorTitle: descriptor.title,
            presentation: descriptor.presentation
        )
    }
}
