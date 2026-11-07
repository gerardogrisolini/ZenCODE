//
//  TerminalChat+SharedChat.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    /// The input-panel catalogue combines ordinary slash commands with live
    /// agent mentions. Mention handles are readable aliases derived from the
    /// participant's display name by the actor-isolated catalogue, while routing
    /// always resolves back to the stable participant identifier.
    func panelSuggestionsForCurrentAgent() async -> [TerminalCommandSuggestion] {
        let commands = commandSuggestionsForCurrentAgent()
        return commands + (await sharedChatMentionSuggestions())
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
    ///
    /// The catalogue is ``SharedChatMentionParser/suggestions(for:handleMap:)``;
    /// the terminal adds the summaries and fits each agent's name to 48
    /// columns.
    nonisolated static func sharedChatMentionSuggestions(
        for participants: [AgentSharedChat.Participant],
        handleMap: [String: String]
    ) -> [TerminalCommandSuggestion] {
        SharedChatMentionParser.suggestions(for: participants, handleMap: handleMap)
            .map { suggestion in
                let summary = switch suggestion.target {
                case .coordinator:
                    "message the live coordinator"
                case .all:
                    "message the coordinator and all active agent instances"
                case let .agent(name):
                    "message active agent: \(sharedChatSuggestionLabel(name))"
                }
                return TerminalCommandSuggestion(command: suggestion.command, summary: summary)
            }
    }

    /// Hidden backward-compatibility handle: the legacy `@agent-Base64` spelling
    /// is still accepted by the parser but never offered by the autocomplete
    /// list. It encodes the stable participant identifier reversibly (see
    /// ``SharedChatMentionParser/mentionHandle(forParticipantID:)``).
    nonisolated static func sharedChatMentionHandle(forParticipantID participantID: String) -> String {
        SharedChatMentionParser.mentionHandle(forParticipantID: participantID)
    }

    func refreshSharedChatPanelSuggestions() async {
        await interactiveReader.setPanelCommandSuggestions(
            await panelSuggestionsForCurrentAgent()
        )
    }

    /// Live `@mention` catalogue only (reserved destinations plus the active
    /// agent instances). The input panel pulls this while the operator is
    /// editing a mention, so the list never depends on a roster notification
    /// having been delivered.
    func sharedChatMentionSuggestions() async -> [TerminalCommandSuggestion] {
        let roster = await sessionRunner.sharedChatMentionRoster(rootSessionID: sessionID)
        return Self.sharedChatMentionSuggestions(
            for: roster.participants,
            handleMap: roster.handleMap
        )
    }

    /// Installs the pull-based mention source on the input panel.
    func installSharedChatMentionSuggestionsProvider() async {
        interactiveReader.setPanelMentionSuggestionsProvider { [weak self] in
            await self?.sharedChatMentionSuggestions() ?? []
        }
    }

    /// A complete live mention (see ``SharedChatMentionParser/Route``).
    typealias SharedChatMentionRoute = SharedChatMentionParser.Route

    /// The parser must distinguish ordinary prompts from a valid live mention
    /// that omitted its message body. The latter is terminal input validation,
    /// not a prompt to queue behind a running generation (see
    /// ``SharedChatMentionParser/Parse``).
    typealias SharedChatMentionParse = SharedChatMentionParser.Parse

    /// Parses only a leading mention. `@coordinator` and `@all` always target
    /// the live broadcast destinations — the catalogue reserves those spellings
    /// for the whole session, so an agent named `all` or `coordinator` is
    /// disambiguated to `@all-2` / `@coordinator-2` and routes by its stable
    /// id; every other direct mention resolves a readable handle from the
    /// catalogue back to the stable participant id, with a hidden fallback to
    /// the legacy `@agent-Base64` spelling for backward compatibility (see
    /// ``SharedChatMentionParser/parse(from:readableHandles:)``).
    nonisolated static func parseSharedChatMention(
        from rawInput: String,
        readableHandles: [String: String] = [:]
    ) -> SharedChatMentionParse {
        SharedChatMentionParser.parse(from: rawInput, readableHandles: readableHandles)
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
    func isCurrentSharedChatDirectDestination(
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

    /// Publishes a live mention the operator typed or dictated. Returns
    /// `true` when the message was accepted by the room, `false` for a
    /// destination that is no longer active or a failed publication; the
    /// failure is already written to the terminal. A mention sent from
    /// Telegram is published by the slot's Telegram channel, which records
    /// its route for the coordinator turn it triggers.
    @discardableResult
    func sendSharedChatMention(_ route: SharedChatMentionRoute) async -> Bool {
        guard await isCurrentSharedChatDirectDestination(route.destination) else {
            await writeFailureMessage("ZenCODE message: selected agent is no longer active.\n")
            await refreshSharedChatPanelSuggestions()
            return false
        }

        let messageID = UUID()
        do {
            let delivery = try await sessionRunner.sendSharedChatMessage(
                text: route.text,
                destination: route.destination,
                rootSessionID: sessionID,
                messageID: messageID
            )
            assert(delivery.message.id == messageID)
            await refreshSharedChatPanelSuggestions()
            return true
        } catch {
            let safeError = Self.sharedChatInlineTerminalSafeText(error.localizedDescription)
            await writeFailureMessage("ZenCODE message: \(safeError)\n")
            return false
        }
    }

    /// Formats the original send instant in the local time zone, independently
    /// of the user's 12/24-hour clock preference (see
    /// ``SharedChatMessageLabel/timestamp(_:timeZone:)``).
    nonisolated static func sharedChatTimestamp(
        _ sentAt: Date,
        timeZone: TimeZone = .current
    ) -> String {
        SharedChatMessageLabel.timestamp(sentAt, timeZone: timeZone)
    }

    /// Builds the reader's author label from the sender, original send time and
    /// resolved recipients. Participant identities and delivery stay unchanged
    /// (see ``SharedChatMessageLabel/route(for:participantMap:timeZone:)``).
    nonisolated static func sharedChatIncomingCardRoute(
        for message: AgentSharedChat.Message,
        participantMap: [String: AgentSharedChat.Participant] = [:]
    ) -> String {
        SharedChatMessageLabel.route(for: message, participantMap: participantMap)
    }

    /// Replaces controls with visible inert text, preserving LF as the sole
    /// multiline separator. C0, C1, DEL, bidi/format controls and Unicode line
    /// separators are never emitted verbatim, so a payload cannot create an
    /// ANSI/OSC sequence, reorder a route label, or create a visual prompt row
    /// (see ``SharedChatMentionParser/terminalSafeText(_:)``).
    nonisolated static func sharedChatTerminalSafeText(_ text: String) -> String {
        SharedChatMentionParser.terminalSafeText(text)
    }

    /// ``sharedChatTerminalSafeText(_:)`` on one line (see
    /// ``SharedChatMentionParser/inlineTerminalSafeText(_:)``).
    nonisolated static func sharedChatInlineTerminalSafeText(_ text: String) -> String {
        SharedChatMentionParser.inlineTerminalSafeText(text)
    }

    private nonisolated static func sharedChatSuggestionLabel(_ name: String) -> String {
        fitDisplayWidth(sharedChatInlineTerminalSafeText(name), width: 48)
    }

    nonisolated static func sharedChatWrappedRows(_ text: String, width: Int) -> [String] {
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

}
