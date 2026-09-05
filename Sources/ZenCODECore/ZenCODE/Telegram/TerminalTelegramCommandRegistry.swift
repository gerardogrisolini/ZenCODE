//
//  TerminalTelegramCommandRegistry.swift
//  ZenCODE
//
//  The single Telegram command registry and its parsing surface: canonical
//  spellings, menu publication and ingress resolution. Extracted verbatim
//  from TerminalTelegramTurnProgressReporter.swift, which keeps only the
//  turn-progress actor.
//

import Foundation
import ToolCore

enum TerminalTelegramCommandAction: Equatable {
    case status
    case turnOn
    case turnOff
    case usage

    init(argument: String) {
        switch argument.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "":
            self = .status
        case "on":
            self = .turnOn
        case "off":
            self = .turnOff
        default:
            self = .usage
        }
    }
}
/// One entry of the single Telegram command registry.
///
/// `name` is the bare word published to Telegram (`"help"`); the canonical
/// slash form is derived as `"/\(name)"`. `aliases` are alternative lines the
/// remote operator may type instead, including plain-language triggers, and
/// are published nowhere: `setMyCommands` shows only the canonical name so the
/// menu stays short while plain words keep working.
public struct TerminalTelegramCommandSpecification: Sendable, Equatable {
    public let command: TerminalTelegramRemoteCommand
    public let name: String
    public let description: String
    public let aliases: [String]

    init(
        command: TerminalTelegramRemoteCommand,
        name: String,
        description: String,
        aliases: [String] = []
    ) {
        self.command = command
        self.name = name
        self.description = description
        self.aliases = aliases
    }

    /// Every accepted spelling of this command (canonical slash form first).
    public var allForms: [String] {
        ["/\(name)"] + aliases
    }
}

/// The single Telegram command registry.
///
/// Both consumers derive from this one table and nothing else:
/// `TerminalTelegramRemoteCommand` resolution (the ingress parser) and
/// `setMyCommands`/menu publishing, so a command can never be parseable but
/// missing from the menu, or listed in the menu but not parseable.
///
/// `/start` is deliberately absent. Telegram delivers `/start <payload>` on
/// every first contact (and on deep links), where the payload is the pairing
/// grant, not a command argument. Registering it as a menu command would
/// publish a "start" entry whose payload contract no remote answer needs.
public enum TerminalTelegramCommandRegistry {
    public static let commands: [TerminalTelegramCommandSpecification] = [
        TerminalTelegramCommandSpecification(
            command: .help,
            name: "help",
            description: "Show what ZenCODE can do from Telegram",
            aliases: ["help"]
        ),
        TerminalTelegramCommandSpecification(
            command: .status,
            name: "status",
            description: "Show session status and Telegram link state",
            aliases: ["status", "stato"]
        ),
        TerminalTelegramCommandSpecification(
            command: .chat,
            name: "chat",
            description: "Choose an active participant to message"
        ),
        TerminalTelegramCommandSpecification(
            command: .changes,
            name: "changes",
            description: "List the file changes of this session",
            aliases: ["changes", "modifiche"]
        ),
        TerminalTelegramCommandSpecification(
            command: .undo,
            name: "undo",
            description: "How to undo the session's file changes",
            aliases: ["undo", "undo changes", "annulla", "annulla modifiche"]
        ),
        TerminalTelegramCommandSpecification(
            command: .diff,
            name: "diff",
            description: "Send this session's diff as a document (asks first)",
            aliases: ["diff"]
        ),
        TerminalTelegramCommandSpecification(
            command: .report,
            name: "report",
            description: "Send the latest report/log file (asks first)",
            aliases: ["report", "log", "report file"]
        ),
    ]

    /// Accepted exact spellings per command, canonical form first. Derived, so
    /// adding a registry entry extends the parser automatically.
    public static var recognizedFormsByCommand: [TerminalTelegramRemoteCommand: [String]] {
        Dictionary(commands.map { ($0.command, $0.allForms) }, uniquingKeysWith: { first, _ in first })
    }

    /// Entries published to `setMyCommands` (and the local menu), in registry
    /// order. Telegram caps `BotCommand.description` at 256 characters and the
    /// command name at 32; these entries sit far below both.
    public static var botCommands: [TerminalTelegramBotCommand] {
        let remoteCommands = commands.map {
            TerminalTelegramBotCommand(command: $0.name, description: $0.description)
        }
        let workflowCommands = CoordinatorCommandFamily.allCases.map { family in
            TerminalTelegramBotCommand(
                command: family.rawValue,
                description: family.menuDescription
            )
        }
        return remoteCommands + workflowCommands
    }

    /// Resolves one trimmed, lowercased line to a command, or `nil` for an
    /// unknown line. Single entry point used by the ingress parser.
    ///
    /// `/start` stays recognised without being registered: a bare `/start`
    /// keeps its "already linked" answer and `/start <payload>` is consumed by
    /// the pairing grant flow.
    public static func resolve(_ line: String) -> TerminalTelegramRemoteCommand? {
        guard let first = commands.first(where: { specification in
            specification.allForms.contains { matches($0, line: line) }
        }) else {
            return nil
        }
        return first.command
    }

    /// One registry spelling against one normalized line.
    private static func matches(_ form: String, line: String) -> Bool {        guard form.first == "/" else {
            // A plain-language alias matches the whole line only: "status" must
            // not capture "status report please".
            return line == form
        }
        // A slash form matches exactly, or with a @botname suffix such as
        // "/help@zencode_bot".
        return line == form || line.hasPrefix(form + "@")
    }
}
/// Wire form of one `setMyCommands` entry (Bot API snake_case).
public struct TerminalTelegramBotCommand: Codable, Sendable, Equatable {
    public let command: String
    public let description: String

    public init(command: String, description: String) {
        self.command = command
        self.description = description
    }

    enum CodingKeys: String, CodingKey {
        case command
        case description
    }
}

public enum TerminalTelegramRemoteCommand: Equatable, Sendable {
    case start
    case help
    case status
    case chat
    case changes
    case undo
    case diff
    case report

    public init?(text: String) {
        let normalized = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        // The registry is the single authority for command spellings.
        if let resolved = TerminalTelegramCommandRegistry.resolve(normalized) {
            self = resolved
            return
        }
        // `/start` remains recognised without being registered (see the
        // registry doc-comment): first contact and deep links carry a pairing
        // payload, not command arguments.
        let command = normalized
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init) ?? normalized
        if command == "/start" || command.hasPrefix("/start@") {
            self = .start
            return
        }
        return nil
    }
}
