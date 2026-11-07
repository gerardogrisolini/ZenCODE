//
//  ChatCommandRegistryTests.swift
//  ZenCODE
//
//  The slash-command registry: the terminal's commands placed among the shared
//  ones, their visibility, the commands that run while a prompt is generating,
//  line lookup, and the answers of hidden commands.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Chat command registry")
struct ChatCommandRegistryTests {
    // MARK: - Fixtures

    private static let channelCommands: Set<String> = [
        "/setup", "/ds4", "/feature", "/subagent", "/cron", "/telegram", "/voice", "/exit",
    ]

    private static let registry = TerminalChat.commandRegistry
    private static let sharedRegistry = ChatCommandRegistry(shared: ChatCommandRegistry.sharedDescriptors)

    // MARK: - Order and descriptors

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
            ("/subagent", true),
            ("/subagent x", true),
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
}
