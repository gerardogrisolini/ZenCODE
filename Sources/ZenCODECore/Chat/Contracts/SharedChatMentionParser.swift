//
//  SharedChatMentionParser.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Live shared-chat `@mentions`, for every channel that lets the operator
/// address a participant: the parser that turns a leading mention into a
/// destination, the mention catalogue a channel offers, and the sanitizer of
/// the text a mention carries.
///
/// Mention handles are readable aliases assigned by the session's mention
/// catalogue from the participant's display name; routing always resolves
/// back to the stable participant identifier. `@coordinator` and `@all` are
/// reserved for the whole session.
///
/// The terminal chat keeps its historical names (`TerminalChat`'s
/// `parseSharedChatMention(from:readableHandles:)`,
/// `sharedChatMentionSuggestions(for:handleMap:)`,
/// `sharedChatTerminalSafeText(_:)` and the others) as forwarders to this
/// type, so the terminal and the Telegram companion parse and sanitize
/// exactly the same way.
public enum SharedChatMentionParser {
    /// A complete mention: where the message goes and its sanitized text.
    public struct Route: Sendable, Equatable {
        public let destination: AgentSharedChat.Destination
        public let text: String
    }

    /// The parser must distinguish ordinary prompts from a valid live mention
    /// that omitted its message body. The latter is input validation, not a
    /// prompt to queue behind a running generation.
    public enum Parse: Sendable, Equatable {
        case none
        case missingText(destination: AgentSharedChat.Destination)
        case route(Route)
    }

    /// One entry of the mention catalogue, without presentation: a channel
    /// renders it as it needs (the terminal fits the agent's name to its
    /// columns, Telegram turns it into a picker button).
    public struct Suggestion: Sendable, Equatable {
        /// Whom the mention addresses.
        public enum Target: Sendable, Equatable {
            /// The live coordinator (`@coordinator`).
            case coordinator
            /// The coordinator and every active agent instance (`@all`).
            case all
            /// One active agent instance, by its display name, unsanitized.
            case agent(name: String)
        }

        /// The readable handle, without the leading `@`.
        public let handle: String
        public let target: Target

        public init(handle: String, target: Target) {
            self.handle = handle
            self.target = target
        }

        /// The mention as the operator types it: `@handle` and one space.
        public var command: String {
            "@\(handle) "
        }
    }

    /// Input is bounded before parsing or sanitising it. These mirrors of the
    /// bus limits avoid a large trim/split/Base64 allocation when a helper is
    /// called with an adversarial String directly.
    private static let maximumInputScalars = AgentSharedChat.maximumMessageLength
    private static let maximumInputUTF8 = AgentSharedChat.maximumMessageUTF8Length

    // MARK: - Parsing

    /// Parses only a leading mention. `@coordinator` and `@all` always target
    /// the live broadcast destinations — the catalogue reserves those spellings
    /// for the whole session, so an agent named `all` or `coordinator` is
    /// disambiguated to `@all-2` / `@coordinator-2` and routes by its stable
    /// id; every other direct mention resolves a readable handle from the
    /// catalogue back to the stable participant id, with a hidden fallback to
    /// the legacy `@agent-Base64` spelling for backward compatibility.
    public static func parse(
        from rawInput: String,
        readableHandles: [String: String] = [:]
    ) -> Parse {
        let input = boundedRawInput(rawInput)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.first == "@" else { return .none }
        let pieces = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let mention = pieces.first, mention.count > 1 else {
            return .none
        }

        let rawTarget = mention.dropFirst()
        // Reject a huge token before materialising it as a String for lookup or
        // Base64 decoding.
        guard rawTarget.utf8.count <= maximumMentionHandleUTF8Length else {
            return .none
        }
        let target = String(rawTarget)
        let destination: AgentSharedChat.Destination
        if target.caseInsensitiveCompare("coordinator") == .orderedSame {
            destination = .coordinator
        } else if target.caseInsensitiveCompare("all") == .orderedSame {
            destination = .all
        } else if let participantID = readableHandles[target] {
            // Readable catalogue handle: routing is always by stable id.
            destination = .direct([participantID])
        } else if let participantID = participantID(fromMentionHandle: target) {
            // Hidden backward-compatibility: the legacy `@agent-Base64` spelling.
            destination = .direct([participantID])
        } else {
            return .none
        }

        guard pieces.count == 2,
              let rawText = String(pieces[1]).nilIfBlank else {
            return .missingText(destination: destination)
        }
        let text = terminalSafeText(rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .missingText(destination: destination)
        }
        return .route(Route(destination: destination, text: text))
    }

    // MARK: - Catalogue

    /// Builds discoverable reserved mentions plus safe, unique direct mentions
    /// for active agent *instances*. `@coordinator` and `@all` are always the
    /// first two suggestions and are never offered as direct-agent handles
    /// (the catalogue disambiguates a colliding agent to `@all-2` /
    /// `@coordinator-2`). The remaining agents are ordered by their readable
    /// display name (locale-aware, case-insensitive) with `joinedAt` as the
    /// tie-breaker, never by handle or by the internal id. Each handle is a
    /// readable alias assigned by the catalogue from the participant's display
    /// name; the stable id is never leaked into the list.
    public static func suggestions(
        for participants: [AgentSharedChat.Participant],
        handleMap: [String: String]
    ) -> [Suggestion] {
        let idToHandle = Dictionary(
            handleMap.map { ($0.value, $0.key) },
            uniquingKeysWith: { _, latest in latest }
        )
        var seenHandles = Set<String>()
        let reserved = [
            Suggestion(handle: "coordinator", target: .coordinator),
            Suggestion(handle: "all", target: .all),
        ]
        let agents = participants
            .filter { $0.kind == .agent && $0.isActive }
            .sorted { lhs, rhs in
                switch lhs.name.localizedCaseInsensitiveCompare(rhs.name) {
                case .orderedAscending: return true
                case .orderedDescending: return false
                case .orderedSame: return lhs.joinedAt < rhs.joinedAt
                }
            }
            .compactMap { participant -> Suggestion? in
                guard let handle = idToHandle[participant.id],
                      handle != "all", handle != "coordinator",
                      seenHandles.insert(handle).inserted else {
                    return nil
                }
                return Suggestion(handle: handle, target: .agent(name: participant.name))
            }
        return reserved + agents
    }

    /// Hidden backward-compatibility handle: the legacy `@agent-Base64` spelling
    /// is still accepted by the parser but never offered by the catalogue. It
    /// encodes the stable participant identifier reversibly.
    static func mentionHandle(forParticipantID participantID: String) -> String {
        let boundedID = boundedRawInput(participantID)
        let encoded = Data(boundedID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "agent-\(encoded)"
    }

    // MARK: - Sanitizer

    /// Replaces controls with visible inert text, preserving LF as the sole
    /// multiline separator. C0, C1, DEL, bidi/format controls and Unicode line
    /// separators are never emitted verbatim, so a payload cannot create an
    /// ANSI/OSC sequence, reorder a route label, or create a visual prompt row.
    public static func terminalSafeText(_ text: String) -> String {
        var result = ""
        var scalarCount = 0
        var utf8Count = 0
        for scalar in text.unicodeScalars {
            guard canConsumeRawScalar(
                scalar,
                scalarCount: scalarCount,
                utf8Count: utf8Count
            ) else {
                result += "…"
                break
            }
            scalarCount += 1
            utf8Count += utf8Length(of: scalar)
            switch scalar.value {
            case 0x0A:
                result.unicodeScalars.append(scalar)
            case 0x09:
                result += "    "
            case 0x00...0x1F:
                // U+2400…U+241F are the Unicode control pictures, including
                // ESC → ␛ and CR → ␍.
                if let picture = UnicodeScalar(0x2400 + scalar.value) {
                    result.unicodeScalars.append(picture)
                }
            case 0x7F:
                result += "␡"
            case 0x80...0x9F:
                // Unicode has no complete C1 control-picture block. An ASCII
                // notation is unambiguous, terminal-safe and width-aware.
                result += String(format: "<C1-%02X>", scalar.value)
            case 0x2028:
                result += "<LS>"
            case 0x2029:
                result += "<PS>"
            default:
                if scalar.properties.isBidiControl
                    || scalar.properties.isJoinControl
                    || scalar.properties.generalCategory == .format {
                    // Keep the event visible but inert. This is intentionally
                    // ASCII so no terminal can reinterpret it as a directional
                    // or zero-width formatting instruction.
                    result += String(format: "<U+%04X>", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }

    /// ``terminalSafeText(_:)`` on one line: every whitespace run becomes one
    /// space, and a text left blank becomes "unnamed agent".
    public static func inlineTerminalSafeText(_ text: String) -> String {
        let flattened = terminalSafeText(text)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return flattened.nilIfBlank ?? "unnamed agent"
    }

    // MARK: - Bounds

    /// Copies at most the bus's scalar and UTF-8 budget without normalising
    /// characters. Parsing still sees ordinary spaces exactly as entered, but
    /// never has to trim or split an unbounded adversarial value.
    private static func boundedRawInput(_ raw: String) -> String {
        var bounded = String.UnicodeScalarView()
        var scalarCount = 0
        var utf8Count = 0
        for scalar in raw.unicodeScalars {
            guard canConsumeRawScalar(
                scalar,
                scalarCount: scalarCount,
                utf8Count: utf8Count
            ) else {
                break
            }
            bounded.append(scalar)
            scalarCount += 1
            utf8Count += utf8Length(of: scalar)
        }
        return String(bounded)
    }

    private static var maximumMentionHandleUTF8Length: Int {
        // Base64URL has no padding, so ceil(bytes / 3) * 4 is its longest
        // canonical representation. The small fixed `agent-` prefix is checked
        // separately by the parser.
        ((AgentSharedChat.maximumParticipantIdentifierUTF8Length + 2) / 3) * 4
    }

    private static func canConsumeRawScalar(
        _ scalar: Unicode.Scalar,
        scalarCount: Int,
        utf8Count: Int
    ) -> Bool {
        let scalarUTF8Length = utf8Length(of: scalar)
        return scalarCount < maximumInputScalars
            && utf8Count <= maximumInputUTF8 - scalarUTF8Length
    }

    private static func utf8Length(of scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0...0x7F:
            return 1
        case 0x80...0x7FF:
            return 2
        case 0x800...0xFFFF:
            return 3
        default:
            return 4
        }
    }

    private static func participantID(fromMentionHandle handle: String) -> String? {
        guard handle.hasPrefix("agent-") else { return nil }
        let encoded = String(handle.dropFirst("agent-".count))
        guard !encoded.isEmpty,
              encoded.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 0x41 && scalar.value <= 0x5A)
                      || (scalar.value >= 0x61 && scalar.value <= 0x7A)
                      || (scalar.value >= 0x30 && scalar.value <= 0x39)
                      || scalar == "-"
                      || scalar == "_"
              }) else {
            return nil
        }
        let standardBase64 = encoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddedBase64 = standardBase64 + String(
            repeating: "=",
            count: (4 - standardBase64.count % 4) % 4
        )
        guard let data = Data(base64Encoded: paddedBase64),
              let participantID = String(data: data, encoding: .utf8),
              !participantID.isEmpty,
              // Reject non-canonical encodings so every valid handle has one
              // spelling and completion/routing cannot collide by alias.
              mentionHandle(forParticipantID: participantID) == handle else {
            return nil
        }
        return participantID
    }
}
