//
//  DS4MessageKeys.swift
//  ZenCODE
//
//  Private keys the in-process DS4 path stores in `RemoteGenerationClient`
//  message dictionaries so that every turn already sent is re-rendered
//  byte-identically - and, for the turns the engine generated, with the exact
//  token ids it sampled - and each round only prefills the new suffix of the KV.
//
//  The keys never leave the client: snapshots and compaction go through
//  `agentRuntimeMessages`, which reads only the known fields, and the
//  chat-completions wire builder drops every `ds4_` key.
//

import Foundation

enum DS4MessageKeys {
    /// Prefix shared by every private DS4 key.
    static let prefix = "ds4_"

    /// Assistant: exact generated text (reasoning, visible text and native
    /// tool markup) replayed verbatim after the assistant prefix.
    static let rawAssistant = "ds4_raw_assistant"
    /// Assistant: ids of the tokens the engine committed for this turn, in
    /// order (`DS4GenerateResult.tokens`, `[Int32]`), replayed as
    /// `DS4TranscriptOperation.tokens` instead of re-tokenizing `rawAssistant`
    /// (a BPE split of the text can differ from the sampled one and would
    /// break the common prefix with the live KV).
    static let rawTokens = "ds4_raw_tokens"
    /// Assistant: identity of the model that produced `rawTokens`
    /// (`DS4EngineInfo.tokenIdentity`). The ids are replayed only by an engine
    /// with the same identity; any other engine falls back to `rawAssistant`.
    static let rawTokensModel = "ds4_raw_tokens_model"
    /// Assistant: think mode (`DS4EngineABI.ThinkMode`) of the assistant
    /// prefix used when `rawAssistant` was generated.
    static let thinkMode = "ds4_think_mode"
    /// Assistant: tool calls with arguments in emission order
    /// (`[["name": …, "arguments": …]]`), used when no raw text is available.
    static let toolCallReplays = "ds4_tool_call_replays"
    /// Assistant: tool-role observation that follows the turn (malformed tool
    /// call error + syntax reminder, ds4_agent.c:10728-10741).
    static let toolObservation = "ds4_tool_observation"
    /// User: content exactly as rendered when the message was first sent
    /// (current-turn memory block and instruction included).
    static let userContent = "ds4_user_content"
    /// Any role: the system prompt reminder (every
    /// `AGENT_SYSTEM_PROMPT_REMINDER_TOKENS`) is rendered after this message.
    static let systemReminder = "ds4_system_reminder"
    /// User: system note rendered just before this message, recorded when the
    /// `/ds4 hints` setting changed at this conversation boundary
    /// (`agent_worker_append_hints_context`, ds4_agent.c:1524-1534). The text
    /// is stored so later renders reproduce it byte for byte.
    static let hintsNote = "ds4_hints_note"

    static func isPrivate(_ key: String) -> Bool {
        key.hasPrefix(prefix)
    }

    /// The ids stored in `rawTokens`, `nil` when the key is missing or empty.
    /// Accepts `[Int32]` (what the client stores) and `[Int]`.
    static func rawTokenIDs(of message: [String: Any]) -> [Int32]? {
        let ids: [Int32]
        if let stored = message[rawTokens] as? [Int32] {
            ids = stored
        } else if let stored = message[rawTokens] as? [Int] {
            ids = stored.compactMap { Int32(exactly: $0) }
            guard ids.count == stored.count else {
                return nil
            }
        } else {
            return nil
        }
        return ids.isEmpty ? nil : ids
    }

    /// `message` without its private DS4 keys.
    static func removingPrivateKeys(from message: [String: Any]) -> [String: Any] {
        guard message.keys.contains(where: isPrivate) else {
            return message
        }
        return message.filter { !isPrivate($0.key) }
    }
}

/// What the DS4 path records about a generated assistant turn, applied to the
/// assistant message by `RemoteGenerationClient.appendAssistantMessage`.
struct DS4AssistantTurn: Sendable {
    /// Every generated character, in order (`DS4ParsedOutput.rawText`).
    let rawText: String
    let thinkMode: Int32
    let toolCallReplays: [DS4ToolCallReplay]
    /// Observation returned to the model after a malformed tool call.
    let toolObservation: String?
    /// Context size of the engine session (exact `.contextWindow` maximum).
    let contextSize: Int
    /// Ids of the tokens committed for this turn (`DS4GenerateResult.tokens`),
    /// empty when the engine did not report them.
    let tokens: [Int32]
    /// Identity of the model that produced `tokens` (`DS4EngineInfo.tokenIdentity`).
    let tokensModel: String?

    init(
        rawText: String,
        thinkMode: Int32,
        toolCallReplays: [DS4ToolCallReplay],
        toolObservation: String?,
        contextSize: Int,
        tokens: [Int32] = [],
        tokensModel: String? = nil
    ) {
        self.rawText = rawText
        self.thinkMode = thinkMode
        self.toolCallReplays = toolCallReplays
        self.toolObservation = toolObservation
        self.contextSize = contextSize
        self.tokens = tokens
        self.tokensModel = tokensModel
    }

    func apply(to message: inout [String: Any]) {
        message[DS4MessageKeys.rawAssistant] = rawText
        message[DS4MessageKeys.thinkMode] = Int(thinkMode)
        // Ids without the model that produced them could never be replayed.
        if !tokens.isEmpty, let tokensModel {
            message[DS4MessageKeys.rawTokens] = tokens
            message[DS4MessageKeys.rawTokensModel] = tokensModel
        }
        if !toolCallReplays.isEmpty {
            message[DS4MessageKeys.toolCallReplays] = toolCallReplays.map { replay in
                ["name": replay.name, "arguments": replay.argumentsJSON]
            }
        }
        if let toolObservation {
            message[DS4MessageKeys.toolObservation] = toolObservation
        }
    }

    /// Whether the turn must be kept in history even without visible content:
    /// its tokens are part of the session KV.
    var requiresHistoryEntry: Bool {
        !rawText.isEmpty || !tokens.isEmpty || toolObservation != nil
    }

    /// The observation ds4-agent appends after a malformed tool call
    /// (ds4_agent.c:10728-10741).
    static func malformedToolCallObservation(detail: String, syntax: DS4ToolSyntax) -> String {
        "Tool error: invalid \(syntax.displayName) tool call: "
            + (detail.isEmpty ? "parse error" : detail) + "\n"
            + syntax.syntaxReminder
    }
}
