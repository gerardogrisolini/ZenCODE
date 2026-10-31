//
//  ChatCommandRegistry.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Who runs a slash command.
enum ChatCommandScope: Sendable, Equatable {
    /// The shared session layer runs it, whatever the channel.
    case shared
    /// Only the channel that declares it can run it; the shared commands
    /// answer ``ChatCommandAction/channelCommand`` for it.
    case channel
}

/// The facts about the session that decide which commands the operator sees.
///
/// Chat defines its own facts in the low bits. A channel that hides some of
/// its commands behind facts of its own adds them in an extension, from bit 16
/// up, so the two sets never collide.
struct ChatCommandContext: OptionSet, Sendable, Hashable {
    let rawValue: Int

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    /// The selected agent is the Builder.
    static let builderAgent = ChatCommandContext(rawValue: 1 << 0)
}

/// One slash command: its name, the line it shows in the command menu and in
/// `/help`, who runs it, when the operator sees it, and whether it runs while
/// a prompt is generating.
struct ChatCommandDescriptor: Sendable, Equatable {
    /// The command with its slash (`/help`).
    var command: String
    /// The short description of the command menu.
    var summary: String
    /// The command's line in `/help`.
    var help: String
    /// The command menu completes it with a trailing space, because it needs
    /// an argument.
    var requiresArgument: Bool = false
    /// Who runs it.
    var scope: ChatCommandScope = .shared
    /// The facts the session needs for the operator to see the command; empty
    /// means always.
    var availability: ChatCommandContext = []
    /// The command can run while a prompt is generating.
    var availableDuringGeneration: Bool = false
    /// When the command runs while a prompt is generating only for some
    /// actions: the command alone, or its first argument in lowercase when it
    /// is one of these. `nil` accepts any argument.
    var generationActions: Set<String>? = nil
    /// What the command answers while it is hidden: `nil` treats it as an
    /// unknown command; otherwise this text, and while a prompt is generating
    /// the message of a command that cannot run then.
    var hiddenMessage: String? = nil

    /// Whether the operator sees the command in `context`.
    func isVisible(in context: ChatCommandContext) -> Bool {
        context.isSuperset(of: availability)
    }
}

/// The slash commands of a chat session, in display order: the shared
/// commands, with the commands of the channel placed among them.
///
/// The registry finds the command a line names (the `/session` alias
/// included), lists the commands the operator sees, tells which commands run
/// while a prompt is generating, and gives the lines of `/help`.
struct ChatCommandRegistry: Sendable {
    /// Every command, in display order, hidden ones included.
    let descriptors: [ChatCommandDescriptor]

    /// Composes the shared commands, in their order, with the channel's
    /// groups: each group follows the shared command named by `after`, and
    /// groups with the same anchor keep their order.
    init(
        shared: [ChatCommandDescriptor],
        channel groups: [(after: String, descriptors: [ChatCommandDescriptor])] = []
    ) {
        let sharedCommands = Set(shared.map(\.command))
        for group in groups where !sharedCommands.contains(group.after) {
            preconditionFailure("ChatCommandRegistry: no shared command '\(group.after)' to place channel commands after.")
        }
        var descriptors: [ChatCommandDescriptor] = []
        for descriptor in shared {
            descriptors.append(descriptor)
            for group in groups where group.after == descriptor.command {
                descriptors.append(contentsOf: group.descriptors)
            }
        }
        self.descriptors = descriptors
    }

    // MARK: - Lines

    /// The command a line names: its first space-separated word, once the line
    /// is trimmed, when it starts with a slash.
    static func commandToken(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            return nil
        }
        return trimmed
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
    }

    /// What follows `commandPrefix` in `command`, trimmed; empty when
    /// `command` does not start with it.
    static func arguments(from command: String, commandPrefix: String) -> String {
        guard command.hasPrefix(commandPrefix) else {
            return ""
        }
        return String(command.dropFirst(commandPrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The commands a line can name by another name.
    private static let aliases = ["/session": "/sessions"]

    /// The command a line names, hidden or not.
    func descriptor(forLine line: String) -> ChatCommandDescriptor? {
        guard let token = Self.commandToken(from: line) else {
            return nil
        }
        let command = Self.aliases[token] ?? token
        return descriptors.first { $0.command == command }
    }

    // MARK: - Visibility

    /// The commands the operator sees in `context`, in display order.
    func visibleDescriptors(in context: ChatCommandContext) -> [ChatCommandDescriptor] {
        descriptors.filter { $0.isVisible(in: context) }
    }

    /// The help line of each command the operator sees in `context`: the
    /// `commandHelp` of ``ChatSessionNotice/help(commandHelp:)``.
    func helpLines(in context: ChatCommandContext) -> [String] {
        visibleDescriptors(in: context).map(\.help)
    }

    // MARK: - Generation

    /// Whether the command a line names can run while a prompt is generating,
    /// read on the line without its leading spaces.
    func isAvailableDuringGeneration(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let token = Self.commandToken(from: trimmed),
              let descriptor = descriptor(forLine: trimmed),
              descriptor.availableDuringGeneration else {
            return false
        }
        guard let actions = descriptor.generationActions else {
            return true
        }
        guard let action = Self.arguments(from: trimmed, commandPrefix: token)
            .split(whereSeparator: \.isWhitespace)
            .first?
            .lowercased() else {
            return true
        }
        return actions.contains(action)
    }

    // MARK: - Messages

    /// The answer to a line that names no command.
    static func unknownCommandMessage(for line: String) -> String {
        let command = commandToken(from: line) ?? line.trimmingCharacters(in: .whitespacesAndNewlines)
        return "ZenCODE: unknown command '\(command)'.\n"
    }

    /// The answer to a command that cannot run while a prompt is generating.
    static func unavailableDuringGenerationMessage(for line: String) -> String {
        let command = commandToken(from: line) ?? line.trimmingCharacters(in: .whitespacesAndNewlines)
        return "ZenCODE: command '\(command)' is unavailable while a prompt is running.\n"
    }

    /// The answer to a line whose command is hidden in `context`; `nil` when
    /// the line names no command or one the operator sees.
    func message(
        forHiddenLine line: String,
        context: ChatCommandContext,
        isGenerating: Bool
    ) -> String? {
        guard let descriptor = descriptor(forLine: line),
              !descriptor.isVisible(in: context) else {
            return nil
        }
        guard let hiddenMessage = descriptor.hiddenMessage else {
            return Self.unknownCommandMessage(for: line)
        }
        return isGenerating
            ? Self.unavailableDuringGenerationMessage(for: line)
            : hiddenMessage
    }

    // MARK: - Shared commands

    /// The commands every channel shares, in display order.
    static let sharedDescriptors: [ChatCommandDescriptor] = [
        ChatCommandDescriptor(
            command: "/help",
            summary: "show command help",
            help: "/help shows this command list.",
            availableDuringGeneration: true
        ),
        ChatCommandDescriptor(
            command: "/models",
            summary: "switch model",
            help: "/models shows configured models and lets you switch the current session model."
        ),
        ChatCommandDescriptor(
            command: "/think",
            summary: "set thinking level",
            help: "/think opens a menu to select the current model thinking level."
        ),
        ChatCommandDescriptor(
            command: "/agents",
            summary: "switch agent, set project agents",
            help: "/agents opens a menu of agent profiles. Enter selects the highlighted agent (the session resets when it differs from the current one); Space/X associates the ticked profiles with the current project, and those are the only profiles the sub-agents tool can delegate to. Esc/Q cancels without changes. /agents list shows the profiles, and /agents <name|number> switches agent directly."
        ),
        ChatCommandDescriptor(
            command: "/tools",
            summary: "select tool groups",
            help: "/tools selects which tool groups are available to the model. /tools logs opens the platform system log viewer."
        ),
        ChatCommandDescriptor(
            command: "/skills",
            summary: "select/install/uninstall prompt skills",
            help: "/skills selects installed prompt skills, installs one from GitHub or a local folder, or opens a picker to uninstall selected app-installed skills."
        ),
        ChatCommandDescriptor(
            command: "/sessions",
            summary: "manage sessions and checkpoints",
            help: """
            /sessions                    List and select saved sessions
            /sessions <name>             Save or overwrite a named snapshot
            /sessions save               Save the current session
            /sessions new                Start a new session
            /sessions compact            Compact context
            /sessions delete             Delete a session
            /sessions restore [entry-id] Restore in-place from a checkpoint (interactive picker when omitted)
            """
        ),
        ChatCommandDescriptor(
            command: "/attach",
            summary: "attach/list/delete files",
            help: "/attach opens the terminal picker at the user's home directory when used without arguments, or attaches image/video files from paths. /attach list shows pending attachments. /attach delete [all|number] removes pending attachments."
        ),
        ChatCommandDescriptor(
            command: "/open",
            summary: "open a file or URL",
            help: "/open lists files, URLs, and attachments from the conversation (newest first) to open, or use /open <file-or-url> directly."
        ),
        ChatCommandDescriptor(
            command: "/artifacts",
            summary: "show session file artifacts",
            help: "/artifacts shows all file artifacts from the current session, grouped by turn. It accepts no arguments."
        ),
        ChatCommandDescriptor(
            command: "/changes",
            summary: "show last file changes",
            help: "/changes shows the most recent file change summary. Use /changes diff to include patches."
        ),
        ChatCommandDescriptor(
            command: "/undo",
            summary: "revert last file changes",
            help: "/undo reverts the most recent tracked file changes."
        ),
        ChatCommandDescriptor(
            command: "/tasks",
            summary: "inspect and control session tasks",
            help: "/tasks shows the current task graph. Use /tasks show <id>, /tasks retry <id>, /tasks cancel <id>, or /tasks clear.",
            availableDuringGeneration: true,
            generationActions: ["status", "list", "ls"]
        ),
        ChatCommandDescriptor(
            command: "/plan",
            summary: "plan work via sub-agents",
            help: "/plan <goal> creates a new unapproved plan. Use /plan save to persist its todo-derived graph for this project, /plan load in a new session to restore the newest saved draft as unapproved, /plan list to review saved plans, /plan delete <plan|prefix|all> to remove saved plans from the project library, /plan status to show item progress, /plan approve to provide a descriptive Goal, approve it, and start implementation, or /plan clear to discard the active plan in this session (saved copies are kept).",
            requiresArgument: true
        ),
        ChatCommandDescriptor(
            command: "/goal",
            summary: "work until complete or genuinely blocked",
            help: "/goal <goal> works until completion or a genuine blocker, using a persistent task graph. Execute directly or delegate when useful; validate the result before completing tasks.",
            requiresArgument: true
        ),
        ChatCommandDescriptor(
            command: "/review",
            summary: "review changes via sub-agents",
            help: "/review [focus] reviews tracked session file changes and also verifies approved-plan coverage when a plan is active."
        ),
    ]
}
