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
    case voiceEnabled
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
    static func submittedLineRole(for line: String) -> TerminalSubmittedLineRole {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .empty
        }
        guard let command = commandToken(from: trimmed) else {
            return .prompt
        }
        return .slashCommand(token: command)
    }

    static func isKnownSlashCommand(_ line: String) -> Bool {
        guard let command = commandToken(from: line) else {
            return false
        }
        if command == "/session" {
            return true
        }
        return allCommandDescriptors.contains { $0.command == command }
    }

    static func shouldSuspendPanelInput(for line: String) -> Bool {
        switch submittedLineRole(for: line) {
        case .empty, .prompt:
            return false
        case .slashCommand:
            return true
        }
    }

    static func isVoiceCommand(_ line: String) -> Bool {
        commandToken(from: line) == "/voice"
    }

    static func isAvailableDuringGeneration(for line: String) -> Bool {
        guard let command = commandToken(from: line) else {
            return false
        }
        switch command {
        case "/help", "/changes", "/open", "/tasks":
            return true
        case "/plan":
            let argument = String(line.dropFirst("/plan".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            return argument == "status"
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
        case "/voice":
            return isVoiceCommandVisible()
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
        if Self.isVoiceCommand(line) {
            return "ZenCODE: voice commands are unavailable while a prompt is running.\n"
        }
        let command = Self.commandToken(from: line) ?? line.trimmingCharacters(in: .whitespacesAndNewlines)
        return "ZenCODE: command '\(command)' is unavailable while a prompt is running.\n"
    }

    func visibleCommandDescriptorsForCurrentAgent() -> [TerminalChatCommandDescriptor] {
        let availability = optionalCommandAvailability
        return Self.visibleCommandDescriptors(
            builderAgentEnabled: AgentProfileStore.isBuilderAgent(selectedAgent),
            telegramEnabled: availability.telegramEnabled,
            voiceEnabled: availability.voiceEnabled
        )
    }

    static func visibleCommandDescriptors(
        builderAgentEnabled: Bool,
        telegramEnabled: Bool,
        voiceEnabled: Bool
    ) -> [TerminalChatCommandDescriptor] {
        allCommandDescriptors.filter { descriptor in
            switch descriptor.availability {
            case .always:
                return true
            case .builderAgent:
                return builderAgentEnabled
            case .telegramEnabled:
                return telegramEnabled
            case .voiceEnabled:
                return voiceEnabled
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

    func isVoiceCommandVisible() -> Bool {
        isVoiceConfigured()
    }

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

    static func unknownCommandMessage(for line: String) -> String {
        let command = commandToken(from: line) ?? line.trimmingCharacters(in: .whitespacesAndNewlines)
        return "ZenCODE: unknown command '\(command)'.\n"
    }

    private static let allCommandDescriptors: [TerminalChatCommandDescriptor] = [
        TerminalChatCommandDescriptor(
            command: "/help",
            summary: "show command help",
            help: "/help shows this command list."
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
            command: "/agents",
            summary: "switch agent",
            help: "/agents selects an agent profile and resets the session."
        ),
        TerminalChatCommandDescriptor(
            command: "/tools",
            summary: "select tool groups",
            help: "/tools selects which tool groups are available to the model."
        ),
        TerminalChatCommandDescriptor(
            command: "/feature",
            summary: "list/manage features",
            help: "/feature creates and manages Swift feature packages (Builder agent only). /feature list opens the enable/disable menu, /feature status prints known feature packages.",
            availability: .builderAgent
        ),
        TerminalChatCommandDescriptor(
            command: "/skills",
            summary: "select/install prompt skills",
            help: "/skills selects installed prompt skills or installs one from GitHub or a local folder."
        ),
        TerminalChatCommandDescriptor(
                        command: "/sessions",
            summary: "save/load/compact/new/delete sessions",
            help: "/sessions saves, restores, compacts context (/sessions compact), starts a new session (/sessions new), or deletes named session snapshots for this project."
        ),
        TerminalChatCommandDescriptor(
            command: "/attach",
            summary: "attach/list/delete files",
            help: "/attach <file> [file ...] attaches image or video files to the next prompt. /attach list shows pending attachments. /attach delete [all|number] removes pending attachments.",
            requiresArgument: true
        ),
                TerminalChatCommandDescriptor(
            command: "/open",
            summary: "open a file or URL",
                        help: "/open lists files, URLs, and attachments from the conversation (newest first) to open, or use /open <file-or-url> directly."
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
            help: "/plan <goal> creates a new unapproved plan. Use /plan status to show item progress, /plan approve to approve it and start implementation immediately, or /plan clear to remove it.",
            requiresArgument: true
        ),
                TerminalChatCommandDescriptor(
            command: "/review",
            summary: "review changes via sub-agents",
            help: "/review [focus] reviews tracked session file changes and also verifies approved-plan coverage when a plan is active."
        ),
        TerminalChatCommandDescriptor(
            command: "/telegram",
            summary: "turn Telegram on/off",
            help: "/telegram shows Telegram status. Use /telegram on or /telegram off for this TUI session.",
            availability: .telegramEnabled
        ),
        TerminalChatCommandDescriptor(
            command: "/voice",
            summary: "record a voice prompt",
            help: "/voice starts recording. Press Enter again to stop and send the transcript.",
            availability: .voiceEnabled
        ),
        TerminalChatCommandDescriptor(
            command: "/exit",
            summary: "close session",
            help: "/exit closes the session."
        )
    ]
}
