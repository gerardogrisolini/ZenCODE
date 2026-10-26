//
//  DS4CheckpointTrailer.swift
//  ZenCODE
//
//  Opaque trailer stored in an explicitly saved DS4 KV checkpoint (`.ds4kv`).
//
//  Why it exists. The KV cache holds the exact tokens of the turns already
//  evaluated, and `DS4TranscriptRenderer` re-renders those turns byte for byte
//  only thanks to the private `ds4_*` keys of the messages (`DS4MessageKeys`:
//  the raw assistant text, the frozen user content with the memory block, the
//  tool-call replays, the malformed-call observation, the think mode, the
//  system-prompt reminder flag, the `/ds4 hints` note before a user message
//  and the token ids of the turns the engine generated). Those keys never
//  reach the `.session` file
//  (snapshots go through `agentRuntimeMessages`, which reads only the known
//  fields), so after a restore the renderer would synthesize different text
//  and the common prefix with the loaded KV would collapse at the first
//  assistant turn. The trailer carries the keys next to the KV and
//  `apply(to:)` re-attaches them to the restored messages.
//
//  Format (JSON, UTF-8, keys sorted), version 1:
//
//    {
//      "format": "zencode-ds4-session",
//      "version": 1,
//      "messages": [
//        { "index": 3, "role": "assistant", "fingerprint": "<32 hex>",
//          "ds4": { "ds4_raw_assistant": "...", "ds4_think_mode": 2,
//                   "ds4_raw_tokens": [151644, 872, ...],
//                   "ds4_raw_tokens_model": "41-2-<model name>",
//                   "ds4_tool_call_replays": [{"name": "...", "arguments": "{...}"}],
//                   "ds4_tool_observation": "...", "ds4_user_content": "...",
//                   "ds4_system_reminder": true,
//                   "ds4_hints_note": "..." } }
//      ]
//    }
//
//  Only messages with at least one `ds4_*` key are listed, in message order;
//  every `ds4` member is optional. `ds4_raw_tokens` are the exact token ids
//  the engine committed for the turn and `ds4_raw_tokens_model` the identity of
//  the model that produced them (`DS4EngineInfo.tokenIdentity`): the renderer
//  replays the ids instead of tokenizing the text again only for that model.
//
//  Version. The token members were added without changing the version: they
//  are optional, a trailer written before them decodes with `nil` ids (the turn
//  is replayed from its text) and an older build, which ignores unknown
//  members, keeps reading the rest of a newer trailer. A bump would make
//  older builds drop all the metadata.
//
//  `index` is the position in the live message
//  array at save time (the restored array can be shifted: the system prompt
//  and the dynamic-context message are rebuilt), `role` is informational and
//  `fingerprint` identifies the visible message: the SHA-256 prefix of its
//  normalized role, trimmed text, tool-call names and tool-call id. Unknown
//  format or version means "no metadata" (the KV is still loaded).
//
//  Matching. `apply(to:)` walks the entries in order with a cursor over the
//  restored messages: an entry attaches to the message at its own index when
//  the fingerprint agrees, otherwise to the first following message with the
//  same fingerprint, otherwise it is ignored. A wrong or missing attachment
//  can only shorten the reusable prefix of the KV, never corrupt a prompt.
//

import Foundation

struct DS4CheckpointTrailer: Codable, Equatable, Sendable {
    static let formatName = "zencode-ds4-session"
    static let currentVersion = 1

    /// A tool call replay (`DS4ToolCallReplay`) as stored in the trailer.
    struct Replay: Codable, Equatable, Sendable {
        var name: String
        var arguments: String
    }

    /// The private `ds4_*` keys of one message.
    struct Keys: Codable, Equatable, Sendable {
        var rawAssistant: String?
        var rawTokens: [Int32]?
        var rawTokensModel: String?
        var thinkMode: Int?
        var toolCallReplays: [Replay]?
        var toolObservation: String?
        var userContent: String?
        var systemReminder: Bool?
        var hintsNote: String?

        enum CodingKeys: String, CodingKey {
            case rawAssistant = "ds4_raw_assistant"
            case rawTokens = "ds4_raw_tokens"
            case rawTokensModel = "ds4_raw_tokens_model"
            case thinkMode = "ds4_think_mode"
            case toolCallReplays = "ds4_tool_call_replays"
            case toolObservation = "ds4_tool_observation"
            case userContent = "ds4_user_content"
            case systemReminder = "ds4_system_reminder"
            case hintsNote = "ds4_hints_note"
        }

        var isEmpty: Bool {
            rawAssistant == nil && rawTokens == nil && rawTokensModel == nil && thinkMode == nil
                && toolCallReplays == nil
                && toolObservation == nil && userContent == nil && systemReminder == nil
                && hintsNote == nil
        }

        init(
            rawAssistant: String? = nil,
            rawTokens: [Int32]? = nil,
            rawTokensModel: String? = nil,
            thinkMode: Int? = nil,
            toolCallReplays: [Replay]? = nil,
            toolObservation: String? = nil,
            userContent: String? = nil,
            systemReminder: Bool? = nil,
            hintsNote: String? = nil
        ) {
            self.rawAssistant = rawAssistant
            self.rawTokens = rawTokens
            self.rawTokensModel = rawTokensModel
            self.thinkMode = thinkMode
            self.toolCallReplays = toolCallReplays
            self.toolObservation = toolObservation
            self.userContent = userContent
            self.systemReminder = systemReminder
            self.hintsNote = hintsNote
        }

        /// The private keys of `message`.
        init(message: [String: Any]) {
            rawAssistant = message[DS4MessageKeys.rawAssistant] as? String
            // Ids and model travel together: ids alone could not be replayed.
            if let model = message[DS4MessageKeys.rawTokensModel] as? String,
               let ids = DS4MessageKeys.rawTokenIDs(of: message) {
                rawTokens = ids
                rawTokensModel = model
            }
            thinkMode = message[DS4MessageKeys.thinkMode] as? Int
            toolCallReplays = (message[DS4MessageKeys.toolCallReplays] as? [[String: String]])?
                .compactMap { entry in
                    guard let name = entry["name"], let arguments = entry["arguments"] else {
                        return nil
                    }
                    return Replay(name: name, arguments: arguments)
                }
            toolObservation = message[DS4MessageKeys.toolObservation] as? String
            userContent = message[DS4MessageKeys.userContent] as? String
            systemReminder = message[DS4MessageKeys.systemReminder] as? Bool
            hintsNote = message[DS4MessageKeys.hintsNote] as? String
        }

        /// Writes the keys into `message` with the types the renderer reads.
        func write(into message: inout [String: Any]) {
            if let rawAssistant {
                message[DS4MessageKeys.rawAssistant] = rawAssistant
            }
            if let rawTokens, !rawTokens.isEmpty, let rawTokensModel {
                message[DS4MessageKeys.rawTokens] = rawTokens
                message[DS4MessageKeys.rawTokensModel] = rawTokensModel
            }
            if let thinkMode {
                message[DS4MessageKeys.thinkMode] = thinkMode
            }
            if let toolCallReplays {
                message[DS4MessageKeys.toolCallReplays] = toolCallReplays.map { replay in
                    ["name": replay.name, "arguments": replay.arguments]
                }
            }
            if let toolObservation {
                message[DS4MessageKeys.toolObservation] = toolObservation
            }
            if let userContent {
                message[DS4MessageKeys.userContent] = userContent
            }
            if let systemReminder {
                message[DS4MessageKeys.systemReminder] = systemReminder
            }
            if let hintsNote {
                message[DS4MessageKeys.hintsNote] = hintsNote
            }
        }
    }

    struct Entry: Codable, Equatable, Sendable {
        var index: Int
        var role: String
        var fingerprint: String
        var ds4: Keys
    }

    var format: String = Self.formatName
    var version: Int = Self.currentVersion
    var messages: [Entry]

    // MARK: Capture

    /// The trailer of the live `messages` of a session.
    static func capture(from messages: [[String: Any]]) -> DS4CheckpointTrailer {
        let entries = messages.enumerated().compactMap { index, message -> Entry? in
            let keys = Keys(message: message)
            guard !keys.isEmpty else {
                return nil
            }
            return Entry(
                index: index,
                role: DS4TranscriptRenderer.role(of: message),
                fingerprint: fingerprint(of: message),
                ds4: keys
            )
        }
        return DS4CheckpointTrailer(messages: entries)
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    /// `nil` when `data` is not a trailer of a supported format and version.
    static func decode(_ data: Data) -> DS4CheckpointTrailer? {
        guard let trailer = try? JSONDecoder().decode(DS4CheckpointTrailer.self, from: data),
              trailer.format == formatName,
              trailer.version == currentVersion else {
            return nil
        }
        return trailer
    }

    // MARK: Apply

    /// Re-attaches the stored keys to the restored `messages` whose
    /// fingerprint agrees (see the file header). Returns how many entries were
    /// attached.
    @discardableResult
    func apply(to messages: inout [[String: Any]]) -> Int {
        let fingerprints = messages.map(Self.fingerprint(of:))
        var cursor = 0
        var attached = 0
        for entry in self.messages.sorted(by: { $0.index < $1.index }) {
            let target: Int?
            if entry.index >= cursor, entry.index < messages.count,
               fingerprints[entry.index] == entry.fingerprint {
                target = entry.index
            } else {
                target = (cursor..<messages.count).first { fingerprints[$0] == entry.fingerprint }
            }
            guard let target else {
                continue
            }
            entry.ds4.write(into: &messages[target])
            cursor = target + 1
            attached += 1
        }
        return attached
    }

    // MARK: Fingerprint

    /// Identity of the visible part of a message, stable across the snapshot
    /// round trip (`.session` file and `RemoteGenerationClient.initialMessages`):
    /// normalized role, trimmed text, tool-call names (assistant) and tool-call
    /// id (tool result). Private `ds4_*` keys and reasoning never take part.
    static func fingerprint(of message: [String: Any]) -> String {
        let role = DS4TranscriptRenderer.role(of: message)
        let content = (RemoteGenerationClient.contentString(from: message["content"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let toolNames = RemoteGenerationClient.runtimeToolCalls(from: message).map(\.name).joined(separator: ",")
        let toolCallID = role == "tool"
            ? RemoteGenerationClient.stringValue(message["tool_call_id"]) ?? ""
            : ""
        let identity = [role, content, toolNames, toolCallID].joined(separator: "\u{1F}")
        return String(Data(identity.utf8).sha256Hex().prefix(32))
    }
}
