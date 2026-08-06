//
//  TerminalChat+SharedChat.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension TerminalChat {
    /// The input-panel catalogue combines ordinary slash commands with live
    /// agent mentions. Mention handles intentionally encode the stable
    /// participant identifier rather than its display name: names are mutable,
    /// may contain spaces/control characters, and need not be unique.
    func panelSuggestionsForCurrentAgent() async -> [TerminalCommandSuggestion] {
        let commands = commandSuggestionsForCurrentAgent()
        let participants = await sessionRunner.sharedChatParticipants(rootSessionID: sessionID)
        return commands + Self.sharedChatMentionSuggestions(for: participants)
    }

    /// Builds safe, unique direct-mention completions for active agents. The
    /// `agent-` prefix makes every generated handle distinct from the reserved
    /// `@all` broadcast token; Base64URL preserves a one-to-one mapping with an
    /// agent ID even when display names are duplicated or contain whitespace.
    nonisolated static func sharedChatMentionSuggestions(
        for participants: [AgentSharedChat.Participant]
    ) -> [TerminalCommandSuggestion] {
        var seenHandles = Set<String>()
        let suggestions = participants
            .filter { $0.kind == .agent && $0.isActive }
            .compactMap { participant -> TerminalCommandSuggestion? in
                let handle = sharedChatMentionHandle(forParticipantID: participant.id)
                guard handle != "all", seenHandles.insert(handle).inserted else {
                    return nil
                }
                let label = sharedChatSuggestionLabel(participant.name)
                return TerminalCommandSuggestion(
                    command: "@\(handle) ",
                    summary: "message active agent: \(label)"
                )
            }
        return suggestions.sorted {
            $0.command.localizedCaseInsensitiveCompare($1.command) == .orderedAscending
        }
    }

    /// Returns an ASCII-only, reversible mention handle for an agent ID. This
    /// is deliberately separate from a display name and is never `all`.
    nonisolated static func sharedChatMentionHandle(forParticipantID participantID: String) -> String {
        let encoded = Data(participantID.utf8)
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

    /// Parses only a leading mention. `@all` is a reserved convenience
    /// broadcast; every direct mention must be an ID-backed terminal-safe
    /// handle emitted by ``sharedChatMentionSuggestions(for:)``.
    nonisolated static func sharedChatMentionRoute(
        from rawInput: String
    ) -> SharedChatMentionRoute? {
        let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.first == "@" else { return nil }
        let pieces = input.split(maxSplits: 1, whereSeparator: \.isWhitespace)
        guard let mention = pieces.first, mention.count > 1,
              pieces.count == 2,
              let rawText = String(pieces[1]).nilIfBlank else {
            return nil
        }

        let target = String(mention.dropFirst())
        let text = sharedChatTerminalSafeText(rawText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if target.caseInsensitiveCompare("all") == .orderedSame {
            return SharedChatMentionRoute(destination: .all, text: text)
        }
        guard let participantID = sharedChatParticipantID(fromMentionHandle: target) else {
            return nil
        }
        return SharedChatMentionRoute(destination: .direct([participantID]), text: text)
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

    func sendSharedChatMention(_ route: SharedChatMentionRoute) async {
        guard await isCurrentSharedChatDirectDestination(route.destination) else {
            await writeFailureMessage("ZenCODE shared chat: selected agent is no longer active.\n")
            await refreshSharedChatPanelSuggestions()
            return
        }

        do {
            let delivery = try await sessionRunner.sendSharedChatMessage(
                text: route.text,
                destination: route.destination,
                rootSessionID: sessionID
            )
            let targets = delivery.recipients.map { "@\($0.name)" }.joined(separator: ", ")
            await writePreformattedMessage(
                Self.renderSharedChatCard(
                    route: "You → \(targets)",
                    text: delivery.message.text
                )
            )
            await refreshSharedChatPanelSuggestions()
        } catch {
            let safeError = Self.sharedChatInlineTerminalSafeText(error.localizedDescription)
            await writeFailureMessage("ZenCODE shared chat: \(safeError)\n")
        }
    }

    /// Messages sent by agents to the coordinator are rendered before their
    /// prompt injection. This preserves a visible audit trail while the actor
    /// remains transient and independent from the persistent conversation.
    func renderSharedChatMessages(_ messages: [AgentSharedChat.Message]) async {
        for message in messages {
            await writePreformattedMessage(
                Self.renderSharedChatCard(
                    route: "@\(message.sender.name) → coordinator",
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

        // Keep the historical four-column right margin when available, while
        // never imposing a minimum larger than the terminal itself.
        let outerWidth = min(88, max(12, availableWidth - 4))
        let contentWidth = outerWidth - 4
        let title = fitDisplayWidth("Shared chat · \(safeRoute)", width: outerWidth - 5)
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
    /// multiline separator. C0, C1, DEL and CR are never emitted verbatim, so
    /// a payload cannot create an ANSI/OSC sequence or return the cursor.
    private nonisolated static func sharedChatTerminalSafeText(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
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
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
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
        let heading = fitDisplayWidth("Shared chat · \(route)", width: width)
        let rows = sharedChatWrappedRows(text, width: width)
        return ([heading] + rows).joined(separator: "\n") + "\n"
    }
}
