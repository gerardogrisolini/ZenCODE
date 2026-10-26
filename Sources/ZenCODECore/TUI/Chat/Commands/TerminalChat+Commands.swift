//
//  TerminalChat+Commands.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation

struct TerminalChatCommandDescriptor: Sendable, Equatable {
    var command: String
    var summary: String
    var help: String
    var requiresArgument: Bool = false
    var availability: TerminalChatCommandAvailability = .always
}

enum TerminalChatCommandAvailability: Sendable, Equatable {
    case always
    case builderAgent
    case telegramEnabled
    /// The current model has a DS4 runtime (in-process engine).
    case ds4Model
}

struct TerminalOptionalCommandAvailability: Sendable, Equatable {
    var telegramEnabled: Bool
    var voiceEnabled: Bool

    static func load() -> Self {
        from(manifest: AgentSettingsManifestStore.load())
    }

    static func from(manifest: AgentSettingsManifest?) -> Self {
        Self(
            telegramEnabled: manifest?.telegram?.isEnabled == true,
            voiceEnabled: manifest?.voice?.isConfigured == true
        )
    }
}

enum TerminalSubmittedLineRole: Sendable, Equatable {
    case empty
    case prompt
    case slashCommand(token: String)
}

extension TerminalChat {
    nonisolated static func submittedLineRole(for line: String) -> TerminalSubmittedLineRole {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .empty
        }
        guard let command = commandToken(from: trimmed) else {
            return .prompt
        }
        return .slashCommand(token: command)
    }

    nonisolated static func isKnownSlashCommand(_ line: String) -> Bool {
        guard let command = commandToken(from: line) else {
            return false
        }
        if command == "/session" {
            return true
        }
        return allCommandDescriptors.contains { $0.command == command }
    }

    nonisolated static func shouldSuspendPanelInput(for line: String) -> Bool {
        switch submittedLineRole(for: line) {
        case .empty, .prompt:
            return false
        case .slashCommand:
            return true
        }
    }

    nonisolated static func isAvailableDuringGeneration(for line: String) -> Bool {
        guard let command = commandToken(from: line) else {
            return false
        }
        let arguments = line
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
        if arguments == ["/tools", "logs"] {
            return true
        }
        switch command {
        case "/help":
            return true
        case "/tasks":
            let action = line
                .dropFirst("/tasks".count)
                .split(whereSeparator: \.isWhitespace)
                .first?
                .lowercased() ?? "status"
            return ["status", "list", "ls"].contains(action)
        case "/telegram":
            return true
        case "/voice":
            return true
        default:
            return false
        }
    }

    func unavailableLocalSlashCommandMessage(for line: String) -> String? {
        guard let command = Self.commandToken(from: line) else {
            return nil
        }

        switch command {
        case "/telegram":
            return isTelegramCommandVisible()
                ? nil
                : Self.unknownCommandMessage(for: line)
        case "/ds4":
            return currentModelUsesDS4Runtime()
                ? nil
                : Self.unknownCommandMessage(for: line)
        default:
            return nil
        }
    }

    func generatingSlashCommandMessage(for line: String) -> String {
        if let unavailableMessage = unavailableLocalSlashCommandMessage(for: line) {
            return unavailableMessage
        }
        guard Self.isKnownSlashCommand(line) else {
            return Self.unknownCommandMessage(for: line)
        }
        let command = Self.commandToken(from: line) ?? line.trimmingCharacters(in: .whitespacesAndNewlines)
        return "ZenCODE: command '\(command)' is unavailable while a prompt is running.\n"
    }

    func visibleCommandDescriptorsForCurrentAgent() -> [TerminalChatCommandDescriptor] {
        let availability = optionalCommandAvailability
        return Self.visibleCommandDescriptors(
            builderAgentEnabled: AgentProfileStore.isBuilderAgent(selectedAgent),
            telegramEnabled: availability.telegramEnabled,
            ds4ModelEnabled: currentModelUsesDS4Runtime()
        )
    }

    nonisolated static func visibleCommandDescriptors(
        builderAgentEnabled: Bool,
        telegramEnabled: Bool,
        ds4ModelEnabled: Bool = false
    ) -> [TerminalChatCommandDescriptor] {
        allCommandDescriptors.filter { descriptor in
            switch descriptor.availability {
            case .always:
                return true
            case .builderAgent:
                return builderAgentEnabled
            case .telegramEnabled:
                return telegramEnabled
            case .ds4Model:
                return ds4ModelEnabled
            }
        }
    }

    func visibleCommandNamesForCurrentAgent() -> [String] {
        visibleCommandDescriptorsForCurrentAgent().map(\.command)
    }

    func isTelegramConfigured() -> Bool {
        optionalCommandAvailability.telegramEnabled
    }

    func isTelegramCommandVisible() -> Bool {
        isTelegramConfigured()
    }

    func isVoiceConfigured() -> Bool {
        optionalCommandAvailability.voiceEnabled
    }

    nonisolated static func commandToken(from line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else {
            return nil
        }
        return trimmed
            .split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)
    }

    nonisolated static func unknownCommandMessage(for line: String) -> String {
        let command = commandToken(from: line) ?? line.trimmingCharacters(in: .whitespacesAndNewlines)
        return "ZenCODE: unknown command '\(command)'.\n"
    }

    private nonisolated static let allCommandDescriptors: [TerminalChatCommandDescriptor] = [
        TerminalChatCommandDescriptor(
            command: "/help",
            summary: "show command help",
            help: "/help shows this command list."
        ),
        TerminalChatCommandDescriptor(
            command: "/setup",
            summary: "configure ZenCODE",
            help: "/setup saves the current session, opens setup, then restores the session with the new configuration."
        ),
        TerminalChatCommandDescriptor(
            command: "/models",
            summary: "switch model",
            help: "/models shows configured models and lets you switch the current session model."
        ),
        TerminalChatCommandDescriptor(
            command: "/think",
            summary: "set thinking level",
            help: "/think opens a menu to select the current model thinking level."
        ),
        TerminalChatCommandDescriptor(
            command: "/ds4",
            summary: "DS4 engine status and runtime controls",
            help: """
            /ds4 status             Show model, backend, library, context, KV cache and runtime values (DS4 models only)
            /ds4 power <1-100>      Set the engine power for this session
            /ds4 steer <-100..100>  Set the FFN directional steering scale (needs a steering file)
            /ds4 hints on|off       Brief programming hints, from the next conversation boundary
            DS4 values last for this session only and are never saved.
            """,
            availability: .ds4Model
        ),
        TerminalChatCommandDescriptor(
            command: "/agents",
            summary: "switch agent, set project agents",
            help: "/agents opens a menu of agent profiles. Enter selects the highlighted agent (the session resets when it differs from the current one); Space/X associates the ticked profiles with the current project, and those are the only profiles the sub-agents tool can delegate to. Esc/Q cancels without changes. /agents list shows the profiles, and /agents <name|number> switches agent directly."
        ),
        TerminalChatCommandDescriptor(
            command: "/tools",
            summary: "select tool groups",
            help: "/tools selects which tool groups are available to the model. /tools logs opens the platform system log viewer."
        ),
        TerminalChatCommandDescriptor(
            command: "/feature",
            summary: "list/manage features",
            help: "/feature creates and manages Swift feature packages (Builder agent only). /feature list opens the enable/disable menu, /feature status prints known feature packages, and /feature promote <id> (--linux|--no-linux) [--repository path] prepares a generated package for a Git checkout without committing or pushing.",
            availability: .builderAgent
        ),
        TerminalChatCommandDescriptor(
            command: "/skills",
            summary: "select/install/uninstall prompt skills",
            help: "/skills selects installed prompt skills, installs one from GitHub or a local folder, or opens a picker to uninstall selected app-installed skills."
        ),
        TerminalChatCommandDescriptor(
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
        TerminalChatCommandDescriptor(
            command: "/attach",
            summary: "attach/list/delete files",
            help: "/attach opens the terminal picker at the user's home directory when used without arguments, or attaches image/video files from paths. /attach list shows pending attachments. /attach delete [all|number] removes pending attachments."
        ),
                TerminalChatCommandDescriptor(
            command: "/open",
            summary: "open a file or URL",
                        help: "/open lists files, URLs, and attachments from the conversation (newest first) to open, or use /open <file-or-url> directly."
        ),
        TerminalChatCommandDescriptor(
            command: "/artifacts",
            summary: "show session file artifacts",
            help: "/artifacts shows all file artifacts from the current session, grouped by turn. It accepts no arguments."
        ),
        TerminalChatCommandDescriptor(
            command: "/changes",
            summary: "show last file changes",
            help: "/changes shows the most recent file change summary. Use /changes diff to include patches."
        ),
        TerminalChatCommandDescriptor(
            command: "/undo",
            summary: "revert last file changes",
            help: "/undo reverts the most recent tracked file changes."
        ),
        TerminalChatCommandDescriptor(
            command: "/tasks",
            summary: "inspect and control session tasks",
            help: "/tasks shows the current task graph. Use /tasks show <id>, /tasks retry <id>, /tasks cancel <id>, or /tasks clear."
        ),
        TerminalChatCommandDescriptor(
            command: "/plan",
            summary: "plan work via sub-agents",
            help: "/plan <goal> creates a new unapproved plan. Use /plan save to persist its todo-derived graph for this project, /plan load in a new session to restore the newest saved draft as unapproved, /plan list to review saved plans, /plan delete <plan|prefix|all> to remove saved plans from the project library, /plan status to show item progress, /plan approve to provide a descriptive Goal, approve it, and start implementation, or /plan clear to discard the active plan in this session (saved copies are kept).",
            requiresArgument: true
        ),
        TerminalChatCommandDescriptor(
            command: "/goal",
            summary: "work until complete or genuinely blocked",
            help: "/goal <goal> works until completion or a genuine blocker, using a persistent task graph. Execute directly or delegate when useful; validate the result before completing tasks.",
            requiresArgument: true
        ),
                TerminalChatCommandDescriptor(
            command: "/review",
            summary: "review changes via sub-agents",
            help: "/review [focus] reviews tracked session file changes and also verifies approved-plan coverage when a plan is active."
        ),
        TerminalChatCommandDescriptor(
            command: "/cron",
            summary: "schedule prompts with crontab: list, add, remove, run, mailto",
            help: """
            /cron [list]                                                       List the prompts scheduled in your crontab
            /cron add [-json] [-agent <name>] <schedule> [-f <path>] <prompt>  Schedule a headless prompt that runs in the working directory of this session (five cron fields or an @alias); -json mails JSONL instead of text; -agent runs it with that agent profile (default: Developer); -f reads the prompt from a file (absolute path)
            /cron remove <n>                                                   Remove scheduled prompt number n
            /cron run <n>                                                      Run scheduled prompt number n now
            /cron mailto [address|none|default]                                Show or set where cron mails results (none disables mail)
            """
        ),
        TerminalChatCommandDescriptor(
            command: "/telegram",
            summary: "turn Telegram on/off",
            help: "/telegram shows Telegram status. Use /telegram on or /telegram off for this TUI session.",
            availability: .telegramEnabled
        ),
        TerminalChatCommandDescriptor(
            command: "/voice",
            summary: "voice mode on/off/pause/resume",
            help: "/voice on starts voice mode with any agent in the interactive terminal: utterances become prompts through local speech recognition and answers are read aloud (macOS uses the system speech frameworks; Linux uses the sherpa-onnx files downloaded from /setup > Voice mode and turns the microphone off while reading). Esc stops the reading. /voice off stops voice mode; /voice pause stops listening and reading aloud, /voice resume restarts both, and /voice alone toggles pause/resume. Voice mode lasts only for this TUI session."
        ),
        TerminalChatCommandDescriptor(
            command: "/exit",
            summary: "close session",
            help: "/exit closes the session."
        )
    ]
}
