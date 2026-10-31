//
//  ChatCommandRegistryTests.swift
//  ZenCODE
//
//  The slash-command registry: the shared commands, the terminal's commands
//  placed among them, the `/help` lines, the commands that run while a prompt
//  is generating, and the answers of hidden commands.
//

import Foundation
import Testing
@testable import ZenCODECore

/// The expectations are literal copies of the command table the terminal chat
/// kept before the registry (`TerminalChat+Commands.swift`), not calls to the
/// code that now produces it.
@Suite("Chat command registry")
struct ChatCommandRegistryTests {
    // MARK: - Fixtures

    /// When the terminal showed a command.
    private enum Shown {
        case always
        case builderAgent
        case telegramEnabled
        case ds4Model
    }

    private struct Command {
        let command: String
        let summary: String
        let help: String
        var requiresArgument = false
        var shown: Shown = .always
    }

    /// The terminal's command table, in its order.
    private static let terminalCommands: [Command] = [
        Command(
            command: "/help",
            summary: "show command help",
            help: "/help shows this command list."
        ),
        Command(
            command: "/setup",
            summary: "configure ZenCODE",
            help: "/setup saves the current session, opens setup, then restores the session with the new configuration."
        ),
        Command(
            command: "/models",
            summary: "switch model",
            help: "/models shows configured models and lets you switch the current session model."
        ),
        Command(
            command: "/think",
            summary: "set thinking level",
            help: "/think opens a menu to select the current model thinking level."
        ),
        Command(
            command: "/ds4",
            summary: "DS4 engine status and runtime controls",
            help: """
            /ds4 status             Show model, backend, library, context, KV cache and runtime values (DS4 models only)
            /ds4 power <1-100>      Set the engine power for this session
            /ds4 steer <-100..100>  Set the FFN directional steering scale (needs a steering file)
            /ds4 hints on|off       Brief programming hints, from the next conversation boundary
            DS4 values last for this session only and are never saved.
            """,
            shown: .ds4Model
        ),
        Command(
            command: "/agents",
            summary: "switch agent, set project agents",
            help: "/agents opens a menu of agent profiles. Enter selects the highlighted agent (the session resets when it differs from the current one); Space/X associates the ticked profiles with the current project, and those are the only profiles the sub-agents tool can delegate to. Esc/Q cancels without changes. /agents list shows the profiles, and /agents <name|number> switches agent directly."
        ),
        Command(
            command: "/tools",
            summary: "select tool groups",
            help: "/tools selects which tool groups are available to the model. /tools logs opens the platform system log viewer."
        ),
        Command(
            command: "/feature",
            summary: "list/manage features",
            help: "/feature creates and manages Swift feature packages (Builder agent only). /feature list opens the enable/disable menu, /feature status prints known feature packages, and /feature promote <id> (--linux|--no-linux) [--repository path] prepares a generated package for a Git checkout without committing or pushing.",
            shown: .builderAgent
        ),
        Command(
            command: "/skills",
            summary: "select/install/uninstall prompt skills",
            help: "/skills selects installed prompt skills, installs one from GitHub or a local folder, or opens a picker to uninstall selected app-installed skills."
        ),
        Command(
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
        Command(
            command: "/attach",
            summary: "attach/list/delete files",
            help: "/attach opens the terminal picker at the user's home directory when used without arguments, or attaches image/video files from paths. /attach list shows pending attachments. /attach delete [all|number] removes pending attachments."
        ),
        Command(
            command: "/open",
            summary: "open a file or URL",
            help: "/open lists files, URLs, and attachments from the conversation (newest first) to open, or use /open <file-or-url> directly."
        ),
        Command(
            command: "/artifacts",
            summary: "show session file artifacts",
            help: "/artifacts shows all file artifacts from the current session, grouped by turn. It accepts no arguments."
        ),
        Command(
            command: "/changes",
            summary: "show last file changes",
            help: "/changes shows the most recent file change summary. Use /changes diff to include patches."
        ),
        Command(
            command: "/undo",
            summary: "revert last file changes",
            help: "/undo reverts the most recent tracked file changes."
        ),
        Command(
            command: "/tasks",
            summary: "inspect and control session tasks",
            help: "/tasks shows the current task graph. Use /tasks show <id>, /tasks retry <id>, /tasks cancel <id>, or /tasks clear."
        ),
        Command(
            command: "/plan",
            summary: "plan work via sub-agents",
            help: "/plan <goal> creates a new unapproved plan. Use /plan save to persist its todo-derived graph for this project, /plan load in a new session to restore the newest saved draft as unapproved, /plan list to review saved plans, /plan delete <plan|prefix|all> to remove saved plans from the project library, /plan status to show item progress, /plan approve to provide a descriptive Goal, approve it, and start implementation, or /plan clear to discard the active plan in this session (saved copies are kept).",
            requiresArgument: true
        ),
        Command(
            command: "/goal",
            summary: "work until complete or genuinely blocked",
            help: "/goal <goal> works until completion or a genuine blocker, using a persistent task graph. Execute directly or delegate when useful; validate the result before completing tasks.",
            requiresArgument: true
        ),
        Command(
            command: "/review",
            summary: "review changes via sub-agents",
            help: "/review [focus] reviews tracked session file changes and also verifies approved-plan coverage when a plan is active."
        ),
        Command(
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
        Command(
            command: "/telegram",
            summary: "turn Telegram on/off",
            help: "/telegram shows Telegram status. Use /telegram on or /telegram off for this TUI session.",
            shown: .telegramEnabled
        ),
        Command(
            command: "/voice",
            summary: "voice mode on/off/pause/resume",
            help: "/voice on starts voice mode with any agent in the interactive terminal: utterances become prompts through local speech recognition and answers are read aloud (macOS uses the system speech frameworks; Linux uses the sherpa-onnx files downloaded from /setup > Voice mode and turns the microphone off while reading). Esc stops the reading. /voice off stops voice mode; /voice pause stops listening and reading aloud, /voice resume restarts both, and /voice alone toggles pause/resume. Voice mode lasts only for this TUI session."
        ),
        Command(
            command: "/exit",
            summary: "close session",
            help: "/exit closes the session."
        ),
    ]

    /// The `/help` text the terminal wrote for the commands it showed.
    private static func terminalHelpText(
        builderAgent: Bool,
        telegramEnabled: Bool,
        ds4Model: Bool
    ) -> String {
        let commandHelp = terminalCommands.filter { command in
            switch command.shown {
            case .always: true
            case .builderAgent: builderAgent
            case .telegramEnabled: telegramEnabled
            case .ds4Model: ds4Model
            }
        }.map(\.help)
        return (["Type a prompt and press return."]
            + commandHelp
            + [
                "Live chat: @coordinator <message>, @all <message>, or an @agent-name handle.",
                "Ctrl+G toggles default/full access for local.exec approvals in the interactive panel.",
                "Editing: Ctrl+A/Ctrl+E line start/end, Alt+</Alt+> draft start/end, "
                    + "Alt+←/→ (or ESC b / ESC f) word motion.",
            ]).joined(separator: "\n") + "\n\n"
    }

    private static let channelCommands: Set<String> = [
        "/setup", "/ds4", "/feature", "/cron", "/telegram", "/voice", "/exit",
    ]

    private static let registry = TerminalChat.commandRegistry
    private static let sharedRegistry = ChatCommandRegistry(shared: ChatCommandRegistry.sharedDescriptors)

    // MARK: - Order and descriptors

    @Test
    func theTerminalRegistryKeepsTheOrderOfToday() {
        #expect(Self.registry.descriptors.map(\.command) == [
            "/help", "/setup", "/models", "/think", "/ds4", "/agents", "/tools",
            "/feature", "/skills", "/sessions", "/attach", "/open", "/artifacts",
            "/changes", "/undo", "/tasks", "/plan", "/goal", "/review", "/cron",
            "/telegram", "/voice", "/exit",
        ])
    }

    @Test
    func theSharedCommandsKeepTheirOrderWithoutTheChannelCommands() {
        #expect(ChatCommandRegistry.sharedDescriptors.map(\.command) == [
            "/help", "/models", "/think", "/agents", "/tools", "/skills",
            "/sessions", "/attach", "/open", "/artifacts", "/changes", "/undo",
            "/tasks", "/plan", "/goal", "/review",
        ])
        #expect(ChatCommandRegistry.sharedDescriptors.allSatisfy { $0.scope == .shared })
        #expect(ChatCommandRegistry.sharedDescriptors.allSatisfy { $0.availability.isEmpty })
    }

    @Test
    func everyDescriptorKeepsItsSummaryHelpAndArgument() {
        let descriptors = Self.registry.descriptors
        #expect(descriptors.count == Self.terminalCommands.count)
        for (descriptor, command) in zip(descriptors, Self.terminalCommands) {
            #expect(descriptor.command == command.command)
            #expect(descriptor.summary == command.summary, "\(command.command)")
            #expect(descriptor.help == command.help, "\(command.command)")
            #expect(descriptor.requiresArgument == command.requiresArgument, "\(command.command)")
        }
    }

    @Test
    func onlyTheChannelCommandsAreScopedToTheChannel() {
        let channel = Self.registry.descriptors.filter { $0.scope == .channel }.map(\.command)
        #expect(Set(channel) == Self.channelCommands)
        #expect(channel.count == Self.channelCommands.count)
    }

    @Test
    func channelGroupsFollowTheirAnchorInOrder() {
        func descriptor(_ command: String) -> ChatCommandDescriptor {
            ChatCommandDescriptor(command: command, summary: "", help: command)
        }
        let registry = ChatCommandRegistry(
            shared: [descriptor("/a"), descriptor("/b"), descriptor("/c")],
            channel: [
                (after: "/b", descriptors: [descriptor("/x")]),
                (after: "/a", descriptors: [descriptor("/y")]),
                (after: "/b", descriptors: [descriptor("/z"), descriptor("/w")]),
            ]
        )
        #expect(registry.descriptors.map(\.command) == ["/a", "/y", "/b", "/x", "/z", "/w", "/c"])
    }

    // MARK: - Visibility and /help

    @Test
    func helpIsIdenticalForEveryBuilderTelegramAndDS4Combination() {
        for builderAgent in [false, true] {
            for telegramEnabled in [false, true] {
                for ds4Model in [false, true] {
                    let label = "builder: \(builderAgent), telegram: \(telegramEnabled), ds4: \(ds4Model)"
                    let context = TerminalChat.commandContext(
                        builderAgentEnabled: builderAgent,
                        telegramEnabled: telegramEnabled,
                        ds4ModelEnabled: ds4Model
                    )
                    let help = ChatSessionNoticeText.text(
                        for: .help(commandHelp: Self.registry.helpLines(in: context))
                    )
                    #expect(
                        help == Self.terminalHelpText(
                            builderAgent: builderAgent,
                            telegramEnabled: telegramEnabled,
                            ds4Model: ds4Model
                        ),
                        "\(label)"
                    )
                    #expect(
                        TerminalChat.visibleCommandDescriptors(
                            builderAgentEnabled: builderAgent,
                            telegramEnabled: telegramEnabled,
                            ds4ModelEnabled: ds4Model
                        ) == Self.registry.visibleDescriptors(in: context),
                        "\(label)"
                    )
                }
            }
        }
    }

    @Test
    func eachChannelCommandIsVisibleOnlyWithItsFact() {
        func visible(_ context: ChatCommandContext) -> Set<String> {
            Set(Self.registry.visibleDescriptors(in: context).map(\.command))
        }
        let always = visible([])
        #expect(!always.contains("/ds4"))
        #expect(!always.contains("/feature"))
        #expect(!always.contains("/telegram"))
        #expect(visible(.ds4Model).subtracting(always) == ["/ds4"])
        #expect(visible(.builderAgent).subtracting(always) == ["/feature"])
        #expect(visible(.telegramEnabled).subtracting(always) == ["/telegram"])
        #expect(always.isSuperset(of: ["/setup", "/cron", "/voice", "/exit"]))
    }

    // MARK: - Generation

    @Test
    func generationAvailabilityTable() {
        let table: [(line: String, available: Bool)] = [
            ("/help", true),
            ("/help extra", true),
            ("/tasks", true),
            ("/tasks   ", true),
            ("/tasks status", true),
            ("/tasks list", true),
            ("/tasks ls", true),
            ("/tasks LIST", true),
            ("/tasks show task-1", false),
            ("/tasks retry task-1", false),
            ("/tasks cancel task-1", false),
            ("/tasks clear", false),
            ("/telegram", true),
            ("/telegram on", true),
            ("/telegram off", true),
            ("/voice", true),
            ("/voice pause", true),
            ("/tools logs", true),
            ("/TOOLS LOGS", true),
            ("/tools", false),
            ("/tools status", false),
            ("/tools logs extra", false),
            ("/setup", false),
            ("/models", false),
            ("/ds4 status", false),
            ("/feature list", false),
            ("/cron", false),
            ("/sessions", false),
            ("/session save", false),
            ("/open", false),
            ("/changes", false),
            ("/plan status", false),
            ("/goal ship it", false),
            ("/review", false),
            ("/exit", false),
            ("/unknown", false),
            ("hello", false),
            ("", false),
        ]
        for (line, available) in table {
            #expect(TerminalChat.isAvailableDuringGeneration(for: line) == available, "\(line)")
        }
    }

    @Test
    func toolsLogsIsTheTerminalsAndNotTheRegistrys() {
        #expect(!Self.registry.isAvailableDuringGeneration("/tools logs"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/tools logs"))
    }

    @Test
    func theSharedCommandsAloneRunHelpAndReadOnlyTasksDuringGeneration() {
        let available = ChatCommandRegistry.sharedDescriptors
            .filter(\.availableDuringGeneration)
            .map(\.command)
        #expect(available == ["/help", "/tasks"])
        #expect(Self.sharedRegistry.isAvailableDuringGeneration("/tasks list"))
        #expect(!Self.sharedRegistry.isAvailableDuringGeneration("/tasks retry task-1"))
        #expect(!Self.sharedRegistry.isAvailableDuringGeneration("/telegram"))
    }

    // MARK: - Lines with leading spaces

    @Test
    func tasksDuringGenerationIsReadOnTheLineWithoutLeadingSpaces() {
        #expect(TerminalChat.isAvailableDuringGeneration(for: "  /tasks"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "  /tasks list"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "\t/tasks ls"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "   /tasks status  "))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "  /tasks retry task-1"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "  /tasks clear"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "  /help"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "  /plan status"))
    }

    @Test
    func linesWithLeadingSpacesFindTheirCommand() {
        #expect(Self.registry.descriptor(forLine: "   /help")?.command == "/help")
        #expect(Self.registry.descriptor(forLine: "\t/plan fix the parser")?.command == "/plan")
        #expect(Self.registry.descriptor(forLine: "  /session save")?.command == "/sessions")
        #expect(Self.registry.descriptor(forLine: "  plain prompt") == nil)
        #expect(TerminalChat.isKnownSlashCommand("  /tasks"))
        #expect(ChatCommandRegistry.commandToken(from: "  /plan fix it ") == "/plan")
        #expect(TerminalChat.commandToken(from: "  /plan fix it ") == "/plan")
        #expect(TerminalChat.unknownCommandMessage(for: "  /nope x") == "ZenCODE: unknown command '/nope'.\n")
    }

    @Test
    func argumentsKeepTheSemanticsOfSlashCommandArguments() {
        #expect(ChatCommandRegistry.arguments(from: "/plan  fix it  ", commandPrefix: "/plan") == "fix it")
        #expect(ChatCommandRegistry.arguments(from: "/plan", commandPrefix: "/plan") == "")
        #expect(ChatCommandRegistry.arguments(from: "  /plan fix", commandPrefix: "/plan") == "")
        #expect(ChatCommandRegistry.arguments(from: "/goal x", commandPrefix: "/plan") == "")
        #expect(TerminalChat.slashCommandArguments(from: "/plan  fix it  ", commandPrefix: "/plan") == "fix it")
    }

    // MARK: - Lookup

    @Test
    func theSessionAliasFindsSessions() {
        #expect(Self.registry.descriptor(forLine: "/session")?.command == "/sessions")
        #expect(Self.registry.descriptor(forLine: "/session save")?.command == "/sessions")
        #expect(Self.registry.descriptor(forLine: "/sessionx") == nil)
        #expect(TerminalChat.isKnownSlashCommand("/session save"))
    }

    @Test
    func hiddenCommandsAreStillKnown() {
        for command in ["/telegram on", "/ds4 status", "/feature list"] {
            #expect(TerminalChat.isKnownSlashCommand(command), "\(command)")
        }
        #expect(!TerminalChat.isKnownSlashCommand("/agents-md"))
        #expect(!TerminalChat.isKnownSlashCommand("/HELP"))
        #expect(!TerminalChat.isKnownSlashCommand("help"))
    }

    // MARK: - Hidden commands

    @Test
    func hiddenCommandsKeepTheirMessages() {
        let hidden: ChatCommandContext = []
        let unknownTelegram = "ZenCODE: unknown command '/telegram'.\n"
        let unknownDS4 = "ZenCODE: unknown command '/ds4'.\n"
        let featureForBuilder = "ZenCODE: /feature is only available with the Builder agent. Switch with /agents Builder.\n"
        let featureUnavailable = "ZenCODE: command '/feature' is unavailable while a prompt is running.\n"

        for isGenerating in [false, true] {
            #expect(
                Self.registry.message(forHiddenLine: "/telegram on", context: hidden, isGenerating: isGenerating)
                    == unknownTelegram
            )
            #expect(
                Self.registry.message(forHiddenLine: "/ds4 status", context: hidden, isGenerating: isGenerating)
                    == unknownDS4
            )
        }
        #expect(
            Self.registry.message(forHiddenLine: "/feature list", context: hidden, isGenerating: false)
                == featureForBuilder
        )
        #expect(
            Self.registry.message(forHiddenLine: "/feature list", context: hidden, isGenerating: true)
                == featureUnavailable
        )
    }

    @Test
    func visibleOrUnknownCommandsHaveNoHiddenMessage() {
        let everything: ChatCommandContext = [.builderAgent, .telegramEnabled, .ds4Model]
        for line in ["/telegram on", "/ds4 status", "/feature list", "/help", "/tasks"] {
            for isGenerating in [false, true] {
                #expect(
                    Self.registry.message(forHiddenLine: line, context: everything, isGenerating: isGenerating) == nil,
                    "\(line)"
                )
            }
        }
        #expect(Self.registry.message(forHiddenLine: "/help", context: [], isGenerating: false) == nil)
        #expect(Self.registry.message(forHiddenLine: "/nope", context: [], isGenerating: false) == nil)
        #expect(Self.registry.message(forHiddenLine: "hello", context: [], isGenerating: true) == nil)
    }

    @Test
    func theGenerationMessageNamesTheTypedCommand() {
        #expect(
            ChatCommandRegistry.unavailableDuringGenerationMessage(for: "  /session save")
                == "ZenCODE: command '/session' is unavailable while a prompt is running.\n"
        )
        #expect(
            ChatCommandRegistry.unknownCommandMessage(for: "/telegram on")
                == "ZenCODE: unknown command '/telegram'.\n"
        )
    }
}
