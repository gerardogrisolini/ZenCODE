//
//  TerminalChat+Commands.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 07/06/26.
//

import Foundation

/// A slash command of the terminal chat: the shared descriptor.
typealias TerminalChatCommandDescriptor = ChatCommandDescriptor

/// The facts of the terminal chat that hide some of its own commands. They
/// occupy bits 16 and 17 of ``ChatCommandContext``, above the facts Chat
/// defines.
extension ChatCommandContext {
    /// Telegram is configured (`/telegram`).
    static let telegramEnabled = ChatCommandContext(rawValue: 1 << 16)
    /// The current model has a DS4 runtime (in-process engine) (`/ds4`).
    static let ds4Model = ChatCommandContext(rawValue: 1 << 17)
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
        commandRegistry.descriptor(forLine: line) != nil
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
        guard commandToken(from: line) != nil else {
            return false
        }
        // `/tools logs` only opens the system log viewer, so it runs while a
        // prompt is generating even though `/tools` does not.
        let arguments = line
            .split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
        if arguments == ["/tools", "logs"] {
            return true
        }
        return commandRegistry.isAvailableDuringGeneration(line)
    }

    func unavailableLocalSlashCommandMessage(for line: String) -> String? {
        // A hidden `/feature` answers from its own handler, which checks the
        // agent; only the commands hidden as unknown answer here.
        guard let descriptor = Self.commandRegistry.descriptor(forLine: line),
              descriptor.hiddenMessage == nil else {
            return nil
        }
        return Self.commandRegistry.message(
            forHiddenLine: line,
            context: currentCommandContext(),
            isGenerating: false
        )
    }

    func generatingSlashCommandMessage(for line: String) -> String {
        if let hiddenMessage = Self.commandRegistry.message(
            forHiddenLine: line,
            context: currentCommandContext(),
            isGenerating: true
        ) {
            return hiddenMessage
        }
        guard Self.isKnownSlashCommand(line) else {
            return Self.unknownCommandMessage(for: line)
        }
        return ChatCommandRegistry.unavailableDuringGenerationMessage(for: line)
    }

    /// The facts of this session that decide which commands are visible.
    func currentCommandContext() -> ChatCommandContext {
        Self.commandContext(
            builderAgentEnabled: AgentProfileStore.isBuilderAgent(selectedAgent),
            telegramEnabled: optionalCommandAvailability.telegramEnabled,
            ds4ModelEnabled: currentModelUsesDS4Runtime()
        )
    }

    nonisolated static func commandContext(
        builderAgentEnabled: Bool,
        telegramEnabled: Bool,
        ds4ModelEnabled: Bool
    ) -> ChatCommandContext {
        var context: ChatCommandContext = []
        if builderAgentEnabled {
            context.insert(.builderAgent)
        }
        if telegramEnabled {
            context.insert(.telegramEnabled)
        }
        if ds4ModelEnabled {
            context.insert(.ds4Model)
        }
        return context
    }

    func visibleCommandDescriptorsForCurrentAgent() -> [TerminalChatCommandDescriptor] {
        Self.commandRegistry.visibleDescriptors(in: currentCommandContext())
    }

    nonisolated static func visibleCommandDescriptors(
        builderAgentEnabled: Bool,
        telegramEnabled: Bool,
        ds4ModelEnabled: Bool = false
    ) -> [TerminalChatCommandDescriptor] {
        commandRegistry.visibleDescriptors(
            in: commandContext(
                builderAgentEnabled: builderAgentEnabled,
                telegramEnabled: telegramEnabled,
                ds4ModelEnabled: ds4ModelEnabled
            )
        )
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
        ChatCommandRegistry.commandToken(from: line)
    }

    nonisolated static func unknownCommandMessage(for line: String) -> String {
        ChatCommandRegistry.unknownCommandMessage(for: line)
    }

    /// The terminal chat's slash commands: the shared ones, with the commands
    /// only the terminal runs in their places.
    nonisolated static let commandRegistry = ChatCommandRegistry(
        shared: ChatCommandRegistry.sharedDescriptors,
        channel: [
            (after: "/help", descriptors: [
                TerminalChatCommandDescriptor(
                    command: "/setup",
                    summary: "configure ZenCODE",
                    help: "/setup saves the current session, opens setup, then restores the session with the new configuration.",
                    scope: .channel
                ),
            ]),
            (after: "/think", descriptors: [
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
                    scope: .channel,
                    availability: .ds4Model
                ),
            ]),
            (after: "/tools", descriptors: [
                TerminalChatCommandDescriptor(
                    command: "/feature",
                    summary: "list/manage features",
                    help: "/feature creates and manages Swift feature packages (Builder agent only). /feature list opens the enable/disable menu, /feature status prints known feature packages, and /feature promote <id> (--linux|--no-linux) [--repository path] prepares a generated package for a Git checkout without committing or pushing.",
                    scope: .channel,
                    availability: .builderAgent,
                    hiddenMessage: renderFeatureCommandUnavailableForAgent()
                ),
            ]),
            (after: "/review", descriptors: [
                TerminalChatCommandDescriptor(
                    command: "/cron",
                    summary: "schedule prompts with crontab: list, add, remove, run, mailto",
                    help: """
                    /cron [list]                                                       List the prompts scheduled in your crontab
                    /cron add [-json] [-agent <name>] <schedule> [-f <path>] <prompt>  Schedule a headless prompt that runs in the working directory of this session (five cron fields or an @alias); -json mails JSONL instead of text; -agent runs it with that agent profile (default: Developer); -f reads the prompt from a file (absolute path)
                    /cron remove <n>                                                   Remove scheduled prompt number n
                    /cron run <n>                                                      Run scheduled prompt number n now
                    /cron mailto [address|none|default]                                Show or set where cron mails results (none disables mail)
                    """,
                    scope: .channel
                ),
                TerminalChatCommandDescriptor(
                    command: "/telegram",
                    summary: "turn Telegram on/off",
                    help: "/telegram shows Telegram status. Use /telegram on or /telegram off for this TUI session.",
                    scope: .channel,
                    availability: .telegramEnabled,
                    availableDuringGeneration: true
                ),
                TerminalChatCommandDescriptor(
                    command: "/voice",
                    summary: "voice mode on/off/pause/resume",
                    help: "/voice on starts voice mode with any agent in the interactive terminal: utterances become prompts through local speech recognition and answers are read aloud (macOS uses the system speech frameworks; Linux uses the sherpa-onnx files downloaded from /setup > Voice mode and turns the microphone off while reading). Esc stops the reading. /voice off stops voice mode; /voice pause stops listening and reading aloud, /voice resume restarts both, and /voice alone toggles pause/resume. Voice mode lasts only for this TUI session.",
                    scope: .channel,
                    availableDuringGeneration: true
                ),
                TerminalChatCommandDescriptor(
                    command: "/exit",
                    summary: "close session",
                    help: "/exit closes the session.",
                    scope: .channel
                ),
            ]),
        ]
    )
}
