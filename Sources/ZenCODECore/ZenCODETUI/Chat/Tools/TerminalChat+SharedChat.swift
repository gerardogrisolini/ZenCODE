//
//  TerminalChat+SharedChat.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension TerminalChat {
    /// Terminal-facing input is bounded before parsing or sanitising it. These
    /// mirrors of the bus limits avoid a large trim/split/Base64 allocation when
    /// this public helper is called with an adversarial String directly.
    private nonisolated static let maximumSharedChatTerminalInputScalars = AgentSharedChat.maximumMessageLength
    private nonisolated static let maximumSharedChatTerminalInputUTF8 = AgentSharedChat.maximumMessageUTF8Length

    /// The input-panel catalogue combines ordinary slash commands with live
    /// agent mentions. Mention handles are readable aliases derived from the
    /// participant's display name by the actor-isolated catalogue, while routing
    /// always resolves back to the stable participant identifier.
    func panelSuggestionsForCurrentAgent() async -> [TerminalCommandSuggestion] {
        let commands = commandSuggestionsForCurrentAgent()
        let roster = await sessionRunner.sharedChatMentionRoster(rootSessionID: sessionID)
        return commands + Self.sharedChatMentionSuggestions(
            for: roster.participants,
            handleMap: roster.handleMap
        )
    }

    /// Builds discoverable reserved mentions plus safe, unique direct mentions
    /// for active agent *instances*. `@coordinator` and `@all` are always the
    /// first two suggestions and are never offered as direct-agent handles
    /// (the catalogue disambiguates a colliding agent to `@all-2` /
    /// `@coordinator-2`). The remaining agents are ordered by their readable
    /// display name (locale-aware, case-insensitive) with `joinedAt` as the
    /// tie-breaker, never by handle or by the internal id. Each `@handle` is a
    /// readable alias assigned by the catalogue from the participant's display
    /// name; the stable id is never leaked into the autocomplete list.
    nonisolated static func sharedChatMentionSuggestions(
        for participants: [AgentSharedChat.Participant],
        handleMap: [String: String]
    ) -> [TerminalCommandSuggestion] {
        let idToHandle = Dictionary(
            handleMap.map { ($0.value, $0.key) },
            uniquingKeysWith: { _, latest in latest }
        )
        var seenHandles = Set<String>()
        let reserved = [
            TerminalCommandSuggestion(
                command: "@coordinator ",
                summary: "message the live coordinator"
            ),
            TerminalCommandSuggestion(
                command: "@all ",
                summary: "message the coordinator and all active agent instances"
            ),
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
            .compactMap { participant -> TerminalCommandSuggestion? in
                guard let handle = idToHandle[participant.id],
                      handle != "all", handle != "coordinator",
                      seenHandles.insert(handle).inserted else {
                    return nil
                }
                let label = sharedChatSuggestionLabel(participant.name)
                return TerminalCommandSuggestion(
                    command: "@\(handle) ",
                    summary: "message active agent: \(label)"
                )
            }
        return reserved + agents
    }

    /// Hidden backward-compatibility handle: the legacy `@agent-Base64` spelling
    /// is still accepted by the parser but never offered by the autocomplete
    /// list. It encodes the stable participant identifier reversibly.
    nonisolated static func sharedChatMentionHandle(forParticipantID participantID: String) -> String {
        let boundedID = sharedChatBoundedRawInput(participantID)
        let encoded = Data(boundedID.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "agent-\(encoded)"
    }

    func refreshSharedChatPanelSuggestions() async {
        await interactiveReader.setPanelCommandSuggestions(
            await panelSuggestionsForCurrentAgent()
        )
    }

    struct SharedChatMentionRoute: Sendable, Equatable {
        let destination: AgentSharedChat.Destination
        let text: String
    }

    /// The parser must distinguish ordinary prompts from a valid live mention
    /// that omitted its message body. The latter is terminal input validation,
    /// not a prompt to queue behind a running generation.
    enum SharedChatMentionParse: Sendable, Equatable {
        case none
        case missingText(destination: AgentSharedChat.Destination)
        case route(SharedChatMentionRoute)
    }

    /// Parses only a leading mention. `@coordinator` and `@all` always target
    /// the live broadcast destinations — the catalogue reserves those spellings
    /// for the whole session, so an agent named `all` or `coordinator` is
    /// disambiguated to `@all-2` / `@coordinator-2` and routes by its stable
    /// id; every other direct mention resolves a readable handle from the
    /// catalogue back to the stable participant id, with a hidden fallback to
    /// the legacy `@agent-Base64` spelling for backward compatibility.
    nonisolated static func parseSharedChatMention(
        from rawInput: String,
        readableHandles: [String: String] = [:]
    ) -> SharedChatMentionParse {
        let input = sharedChatBoundedRawInput(rawInput)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.first == "@" else { return .none }
        let pieces = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let mention = pieces.first, mention.count > 1 else {
            return .none
        }

        let rawTarget = mention.dropFirst()
        // Reject a huge token before materialising it as a String for lookup or
        // Base64 decoding.
        guard rawTarget.utf8.count <= maximumSharedChatMentionHandleUTF8Length else {
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
        } else if let participantID = sharedChatParticipantID(fromMentionHandle: target) {
            // Hidden backward-compatibility: the legacy `@agent-Base64` spelling.
            destination = .direct([participantID])
        } else {
            return .none
        }

        guard pieces.count == 2,
              let rawText = String(pieces[1]).nilIfBlank else {
            return .missingText(destination: destination)
        }
        let text = sharedChatTerminalSafeText(rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return .missingText(destination: destination)
        }
        return .route(SharedChatMentionRoute(destination: destination, text: text))
    }

    /// Compatibility convenience for callers interested only in a complete
    /// route. Input handling must use ``parseSharedChatMention(from:readableHandles:)``
    /// so it can diagnose a recognised mention without text.
    nonisolated static func sharedChatMentionRoute(
        from rawInput: String,
        readableHandles: [String: String] = [:]
    ) -> SharedChatMentionRoute? {
        guard case let .route(route) = parseSharedChatMention(
            from: rawInput,
            readableHandles: readableHandles
        ) else {
            return nil
        }
        return route
    }

    /// The shared-chat actor accepts legacy display names as direct identifiers.
    /// The TUI must not use that ambiguous fallback: confirm that the decoded
    /// mention names one current active agent by ID before delivery.
    private func isCurrentSharedChatDirectDestination(
        _ destination: AgentSharedChat.Destination
    ) async -> Bool {
        guard case let .direct(identifiers) = destination,
              identifiers.count == 1,
              let identifier = identifiers.first else {
            return true
        }
        let participants = await sessionRunner.sharedChatParticipants(rootSessionID: sessionID)
        return participants.contains {
            $0.kind == .agent && $0.isActive && $0.id == identifier
        }
    }

    func sendSharedChatMention(_ route: SharedChatMentionRoute) async -> UUID? {
        guard await isCurrentSharedChatDirectDestination(route.destination) else {
            await writeFailureMessage("ZenCODE message: selected agent is no longer active.\n")
            await refreshSharedChatPanelSuggestions()
            return nil
        }

        do {
            let delivery = try await sessionRunner.sendSharedChatMessage(
                text: route.text,
                destination: route.destination,
                rootSessionID: sessionID
            )
            // Match the incoming-card route style (short display names) so the
            // operator's own sent card reads identically to the cards rendered
            // for messages received from agents, instead of leaking the long
            // prompt-only transcript identities into the terminal card title.
            let participantMap = Dictionary(
                uniqueKeysWithValues: delivery.recipients.map { ($0.id, $0) }
            )
            await writePreformattedMessage(
                Self.renderSharedChatCard(
                    route: Self.sharedChatIncomingCardRoute(
                        for: delivery.message,
                        participantMap: participantMap
                    ),
                    text: delivery.message.text
                )
            )
            await refreshSharedChatPanelSuggestions()
            return delivery.message.id
        } catch {
            let safeError = Self.sharedChatInlineTerminalSafeText(error.localizedDescription)
            await writeFailureMessage("ZenCODE message: \(safeError)\n")
            return nil
        }
    }

    /// Rendering history for one terminal observer.
    ///
    /// A long live session would otherwise accumulate one `UUID` per message
    /// forever. The capacity mirrors ``AgentSharedChat/maximumRetainedMessagesPerRoom``,
    /// the bound of the transcript this history deduplicates, and eviction is
    /// FIFO: an id old enough to be evicted can no longer be replayed by the
    /// Core, so eviction cannot resurrect a duplicate card.
    struct SharedChatRenderedMessageIDs: Sendable {
        static let capacity = AgentSharedChat.maximumRetainedMessagesPerRoom

        private var identifiers: Set<UUID> = []
        private var insertionOrder: [UUID] = []

        var count: Int { identifiers.count }

        init() {}

        /// Records `id` and reports whether it is new to this observer.
        @discardableResult
        mutating func insert(_ id: UUID) -> Bool {
            guard identifiers.insert(id).inserted else { return false }
            insertionOrder.append(id)
            if insertionOrder.count > Self.capacity {
                let evicted = insertionOrder.removeFirst()
                identifiers.remove(evicted)
            }
            return true
        }

        mutating func removeAll() {
            identifiers.removeAll(keepingCapacity: true)
            insertionOrder.removeAll(keepingCapacity: true)
        }
    }

    /// Messages sent by agents to the coordinator are rendered before their
    /// prompt injection. This preserves a visible audit trail while the actor
    /// remains transient and independent from the persistent conversation.
    nonisolated static func newlyReceivedSharedChatMessages(
        _ messages: [AgentSharedChat.Message],
        renderedMessageIDs: inout SharedChatRenderedMessageIDs
    ) -> [AgentSharedChat.Message] {
        messages.filter { renderedMessageIDs.insert($0.id) }
    }

    /// Builds the route label for a chat card from the message's sender and
    /// resolved recipients. Uses short display names only.
    nonisolated static func sharedChatIncomingCardRoute(
        for message: AgentSharedChat.Message,
        participantMap: [String: AgentSharedChat.Participant] = [:]
    ) -> String {
        let senderName = AgentSharedChat.displayName(for: message.sender)
        let coordinatorID = AgentSharedChat.coordinatorID(for: message.roomID)
        if message.recipientIDs.contains(coordinatorID) {
            return "\(senderName) → Coordinator"
        }
        if message.recipientIDs.count > 1 {
            return "\(senderName) → All"
        }
        if let recipientID = message.recipientIDs.first,
           AgentSharedChat.isOperatorIdentifier(recipientID) {
            return "\(senderName) → Operator"
        }
        if let recipientID = message.recipientIDs.first,
           let recipient = participantMap[recipientID] {
            return "\(senderName) → \(AgentSharedChat.displayName(for: recipient))"
        }
        return "\(senderName) → Agent"
    }

    func renderSharedChatMessages(_ messages: [AgentSharedChat.Message]) async {
        let participants = await sessionRunner.sharedChatParticipants(rootSessionID: sessionID)
        let participantMap = Dictionary(
            uniqueKeysWithValues: participants.map { ($0.id, $0) }
        )
        for message in messages {
            await writePreformattedMessage(
                Self.renderSharedChatCard(
                    route: Self.sharedChatIncomingCardRoute(
                        for: message,
                        participantMap: participantMap
                    ),
                    text: message.text
                )
            )
        }
    }

    /// Renders one transient chat message as a terminal-safe blue card. The
    /// border remains visible in captured/plain output, while ANSI colors are
    /// emitted only for an interactive terminal. At very narrow widths, the
    /// box becomes a plain wrapped transcript instead of overflowing.
    nonisolated static func renderSharedChatCard(
        route rawRoute: String,
        text rawText: String,
        terminalColumns: Int = terminalColumnCount(),
        usesColor: Bool = AgentOutput.standardErrorIsTerminal,
        appearance: TerminalMarkdownPalette.Appearance = TerminalMarkdownPalette.detected.appearance
    ) -> String {
        let availableWidth = max(1, terminalColumns)
        let safeRoute = sharedChatInlineTerminalSafeText(rawRoute)
        let normalizedText = sharedChatTerminalSafeText(rawText)

        // Four cells are necessary for the side borders and their interior
        // spacing. Below this conservative minimum, a box would either lose
        // all useful content or exceed the terminal, so emit plain rows.
        guard availableWidth >= 12 else {
            return renderSharedChatPlainFallback(
                route: safeRoute,
                text: normalizedText,
                width: availableWidth
            )
        }

        // Box width equals the full terminal width, matching the prompt bar.
        let outerWidth = max(12, availableWidth)
        let contentWidth = outerWidth - 4
        let titlePrefix = "Message · \(safeRoute)"
        let title = fitDisplayWidth(titlePrefix, width: outerWidth - 5)
        // ╭─ + space + title + space + rule + ╮ must equal `outerWidth`.
        let topRuleWidth = max(0, outerWidth - displayWidth(title) - 5)
        let topRule = String(repeating: "─", count: topRuleWidth)
        let top = "╭─ \(title) \(topRule)╮"
        let bottom = "╰\(String(repeating: "─", count: outerWidth - 2))╯"
        let rows = sharedChatWrappedRows(normalizedText, width: contentWidth)
        let bodyRows = rows.map {
            "│ \(sharedChatPaddedToDisplayWidth($0, width: contentWidth)) │"
        }

        guard usesColor else {
            return ([top] + bodyRows + [bottom]).joined(separator: "\n") + "\n"
        }

        let palette = TerminalStyle.SharedChat.palette(for: appearance)
        // `border` explicitly disables bold. The title is bold, so merely
        // changing its foreground color would otherwise leak bold into the
        // remainder of the top border.
        let coloredTop = "\(palette.border)╭─ \(palette.title)\(title)\(palette.border) \(topRule)╮\(TerminalStyle.reset)"
        let coloredRows = rows.map {
            "\(palette.border)│\(TerminalStyle.reset) \(palette.body)\(sharedChatPaddedToDisplayWidth($0, width: contentWidth))\(TerminalStyle.reset) \(palette.border)│\(TerminalStyle.reset)"
        }
        let coloredBottom = "\(palette.border)\(bottom)\(TerminalStyle.reset)"
        return ([coloredTop] + coloredRows + [coloredBottom]).joined(separator: "\n") + "\n"
    }

    /// Replaces controls with visible inert text, preserving LF as the sole
    /// multiline separator. C0, C1, DEL, bidi/format controls and Unicode line
    /// separators are never emitted verbatim, so a payload cannot create an
    /// ANSI/OSC sequence, reorder a route label, or create a visual prompt row.
    private nonisolated static func sharedChatTerminalSafeText(_ text: String) -> String {
        var result = ""
        var scalarCount = 0
        var utf8Count = 0
        for scalar in text.unicodeScalars {
            guard sharedChatCanConsumeRawScalar(
                scalar,
                scalarCount: scalarCount,
                utf8Count: utf8Count
            ) else {
                result += "…"
                break
            }
            scalarCount += 1
            utf8Count += sharedChatUTF8Length(of: scalar)
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

    /// Copies at most the bus's scalar and UTF-8 budget without normalising
    /// characters. Parsing still sees ordinary spaces exactly as entered, but
    /// never has to trim or split an unbounded adversarial value.
    private nonisolated static func sharedChatBoundedRawInput(_ raw: String) -> String {
        var bounded = String.UnicodeScalarView()
        var scalarCount = 0
        var utf8Count = 0
        for scalar in raw.unicodeScalars {
            guard sharedChatCanConsumeRawScalar(
                scalar,
                scalarCount: scalarCount,
                utf8Count: utf8Count
            ) else {
                break
            }
            bounded.append(scalar)
            scalarCount += 1
            utf8Count += sharedChatUTF8Length(of: scalar)
        }
        return String(bounded)
    }

    private nonisolated static var maximumSharedChatMentionHandleUTF8Length: Int {
        // Base64URL has no padding, so ceil(bytes / 3) * 4 is its longest
        // canonical representation. The small fixed `agent-` prefix is checked
        // separately by the parser.
        ((AgentSharedChat.maximumParticipantIdentifierUTF8Length + 2) / 3) * 4
    }

    private nonisolated static func sharedChatCanConsumeRawScalar(
        _ scalar: Unicode.Scalar,
        scalarCount: Int,
        utf8Count: Int
    ) -> Bool {
        let scalarUTF8Length = sharedChatUTF8Length(of: scalar)
        return scalarCount < maximumSharedChatTerminalInputScalars
            && utf8Count <= maximumSharedChatTerminalInputUTF8 - scalarUTF8Length
    }

    private nonisolated static func sharedChatUTF8Length(of scalar: Unicode.Scalar) -> Int {
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

    private nonisolated static func sharedChatInlineTerminalSafeText(_ text: String) -> String {
        let flattened = sharedChatTerminalSafeText(text)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return flattened.nilIfBlank ?? "unnamed agent"
    }

    private nonisolated static func sharedChatSuggestionLabel(_ name: String) -> String {
        fitDisplayWidth(sharedChatInlineTerminalSafeText(name), width: 48)
    }

    private nonisolated static func sharedChatParticipantID(fromMentionHandle handle: String) -> String? {
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
              sharedChatMentionHandle(forParticipantID: participantID) == handle else {
            return nil
        }
        return participantID
    }

    private nonisolated static func sharedChatWrappedRows(_ text: String, width: Int) -> [String] {
        let widthSafeText: String
        if width < 2 {
            // A two-cell glyph cannot physically fit a one-column terminal.
            // Preserve the row structure while using an inert one-cell marker
            // rather than allowing the fallback itself to overflow.
            widthSafeText = String(text.map { character in
                character == "\n" || TerminalANSIText.visibleWidth(of: character) <= width
                    ? String(character)
                    : "?"
            }.joined())
        } else {
            widthSafeText = text
        }
        let rows = widthSafeText
            .components(separatedBy: "\n")
            .flatMap { line in
                TerminalANSIText.wrapPreservingWhitespace(line, width: width)
            }
        return rows.isEmpty ? [""] : rows
    }

    private nonisolated static func sharedChatPaddedToDisplayWidth(_ text: String, width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - displayWidth(text)))
    }

    private nonisolated static func renderSharedChatPlainFallback(
        route: String,
        text: String,
        width: Int
    ) -> String {
        let heading = fitDisplayWidth("Message · \(route)", width: width)
        let rows = sharedChatWrappedRows(text, width: width)
        return ([heading] + rows).joined(separator: "\n") + "\n"
    }
}
