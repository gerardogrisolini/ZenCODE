//
//  TelegramChannelLifecycleTests.swift
//  ZenCODE
//
//  The link of a ``TelegramChannel``: attach, detach, and shutdown with the
//  texts the terminal writes, the per-bot registry, the status and remote
//  texts, the poll-health notices, the route checks and the egress seams,
//  the endings of a turn with their texts, the channel's presenter (overview
//  dedup, notice capture, workflow notice texts), the route revoked under a
//  turn, and the consent the channel asks in the chat. The channel is the
//  slot's channel of a terminal whose output is captured; Telegram is a Bot
//  API double; every test runs in a UUID support directory.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@ChatSessionActor
@Suite("Telegram channel lifecycle", .serialized, .timeLimit(.minutes(2)))
struct TelegramChannelLifecycleTests {
    private typealias Support = TelegramChannelTestSupport

    private static let activationText = "Telegram remote control is active.\nLinked chat: Test\n"

    private static let oneFileSummary = TurnFileChangeSummary(entries: [
        .init(
            path: "Value.swift", additions: 1, deletions: 1, status: .modified,
            isBinary: false, existedBefore: true, beforeDataBase64: nil, patch: nil
        ),
    ])

    private static let twoFileSummary = TurnFileChangeSummary(entries: [
        .init(
            path: "Added.swift", additions: 3, deletions: 0, status: .added,
            isBinary: false, existedBefore: false, beforeDataBase64: nil, patch: nil
        ),
        .init(
            path: "Removed.swift", additions: 0, deletions: 2, status: .deleted,
            isBinary: false, existedBefore: true, beforeDataBase64: nil, patch: nil
        ),
    ])

    // MARK: - Attach

    /// `attach()` links the session: the activation text reaches the primary
    /// channel, the link records the chat, its owner and the shared route,
    /// and the channel is registered under its bot. The terminal's
    /// `/telegram on` writes the same text, then its status line.
    @Test
    func attachLinksTheSessionWithTheActivationTextAndRegisters() async throws {
        try await Support.withSupport {
            let botID = Support.uniqueBotID()
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: botID))
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)

            try await channel.attach()

            #expect(recorder.notices == [.init(text: Self.activationText, channel: .system)])
            #expect(channel.isActive)
            #expect(channel.controlState.botID == botID)
            #expect(channel.linkedChatID == 42)
            #expect(channel.linkedChatTitle == "Test")
            #expect(channel.linkedUserID == 7)
            #expect(try #require(channel.activeRouteLease).key == Support.defaultRouteKey)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 1)
            await channel.detach()

            // The terminal's command: the channel's text, then the status line.
            channel.noticeSink = nil
            Support.standInForInteractiveLoop(of: terminal)
            let terminalWrites = await Support.capturing(terminal) {
                await terminal.startTelegramControl()
            }
            #expect(terminalWrites == [Self.activationText, TerminalChat.telegramDrivingStatusText])
            #expect(terminal.sessionHost.activeChannel(in: terminal.terminalSlotID) == .telegram)
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func attachWithoutPairingThrowsTheTerminalText() async throws {
        let unpaired = AgentTelegramSettingsManifest(enabled: true, botToken: "123456:ABCDEF")
        try await Support.withSupport(telegram: unpaired) {
            let botID = Support.uniqueBotID()
            let transport = TelegramChannelTestTransport(botID: botID)
            let terminal = try Support.makeTerminal(transport: transport)
            // The terminal hides `/telegram` without a pairing; the guard is
            // lifted to reach the same failure through the command.
            terminal.optionalCommandAvailability = .init(telegramEnabled: true, voiceEnabled: false)
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)

            do throws(TelegramChannelAttachError) {
                try await channel.attach()
                Issue.record("attach linked an unpaired session")
            } catch {
                #expect(error == .notPaired)
                #expect(error.failureText == "ZenCODE: Telegram is not paired. Run the /setup command in zen.\n")
            }
            #expect(recorder.notices.isEmpty)
            #expect(!channel.isActive)
            #expect(await transport.requestCount == 0)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 0)

            channel.noticeSink = nil
            Support.standInForInteractiveLoop(of: terminal)
            let terminalWrites = await Support.capturing(terminal) {
                await terminal.startTelegramControl()
            }
            #expect(terminalWrites == ["ZenCODE: Telegram is not paired. Run the /setup command in zen.\n"])
            #expect(terminal.sessionHost.activeChannel(in: terminal.terminalSlotID) == .primary)
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func attachWithoutAUsableRouteThrowsTheTerminalText() async throws {
        let foreignRoute = AgentTelegramSettingsManifest(
            enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42,
            linkedChatTitle: "Test", ownerUserID: 7, routes: [.init(roomID: "foreign-session")]
        )
        try await Support.withSupport(telegram: foreignRoute) {
            let botID = Support.uniqueBotID()
            let transport = TelegramChannelTestTransport(botID: botID)
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)

            do throws(TelegramChannelAttachError) {
                try await channel.attach()
                Issue.record("attach linked a session without its route")
            } catch {
                #expect(error == .invalidConfiguration)
                #expect(error.failureText
                    == "ZenCODE: Telegram configuration is invalid. Run /setup to pair Telegram again.\n")
            }
            #expect(recorder.notices.isEmpty)
            #expect(channel.activeRouteLease == nil)
            #expect(await transport.requestCount == 0)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 0)
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func attachThatCannotStartRecordsTheErrorAndStaysUnregistered() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: Support.unauthorizedGetMeTransport())
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)

            do throws(TelegramChannelAttachError) {
                try await channel.attach()
                Issue.record("attach succeeded with a rejected token")
            } catch {
                guard case let .controlFailed(description) = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
                #expect(error.failureText == "ZenCODE: \(description)\n")
                #expect(channel.controlState.lastError == description)
            }
            #expect(recorder.notices.isEmpty)
            #expect(!channel.isActive)
            // The linked chat stays recorded after a failed start.
            #expect(channel.linkedChatID == 42)
            #expect(channel.activeRouteLease?.key == Support.defaultRouteKey)
            #expect(channel.controlState.botID == nil)
            #expect(terminal.sessionHost.activeChannel(in: terminal.terminalSlotID) == .primary)
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func repeatedAttachRestartsTheServiceAndRegistersOnce() async throws {
        try await Support.withSupport {
            let botID = Support.uniqueBotID()
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: botID))
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)

            try await channel.attach()
            let firstEpoch = try #require(channel.controlState.wireLifecycleEpoch)
            try await channel.attach()
            let secondEpoch = try #require(channel.controlState.wireLifecycleEpoch)

            #expect(firstEpoch != secondEpoch)
            #expect(recorder.texts == [Self.activationText, Self.activationText])
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 1)
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func failedReattachRemovesTheRegistration() async throws {
        try await Support.withSupport {
            let botID = Support.uniqueBotID()
            let transport = TelegramChannelTestTransport(botID: botID)
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel

            try await channel.attach()
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 1)
            await transport.setGetMeFails(true)
            do throws(TelegramChannelAttachError) {
                try await channel.attach()
                Issue.record("attach succeeded with a rejected token")
            } catch {
                guard case .controlFailed = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
            }

            #expect(!channel.isActive)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 0)
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Detach and shutdown

    @Test
    func detachUnlinksWithTheStopTextAndLeavesTheRegistry() async throws {
        try await Support.withSupport {
            let botID = Support.uniqueBotID()
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: botID))
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)
            try await channel.attach()
            recorder.clear()

            await channel.detach()

            #expect(recorder.notices == [.init(text: "Telegram remote control stopped.\n", channel: .system)])
            #expect(!channel.isActive)
            #expect(channel.controlState.wireLifecycleEpoch == nil)
            #expect(channel.controlState.botID == botID)
            #expect(channel.linkedChatID == nil)
            #expect(channel.linkedChatTitle == nil)
            #expect(channel.linkedUserID == nil)
            #expect(channel.activeRouteLease == nil)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 0)

            // The terminal's `/telegram off` writes the same text.
            channel.noticeSink = nil
            Support.standInForInteractiveLoop(of: terminal)
            await terminal.startTelegramControl()
            let terminalWrites = await Support.capturing(terminal) {
                await terminal.stopTelegramControl()
            }
            #expect(terminalWrites == ["Telegram remote control stopped.\n"])
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func detachWithoutAttachTellsTheStopTextAndKeepsOtherRegistrations() async throws {
        try await Support.withSupport {
            let botID = Support.uniqueBotID()
            let attachedTerminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: botID))
            try await attachedTerminal.telegramChannel.attach()
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: botID))
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)

            await channel.detach()

            #expect(recorder.texts == ["Telegram remote control stopped.\n"])
            #expect(!channel.isActive)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 1)
            await attachedTerminal.sessionHost.shutdown()
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func shutdownStopsTheServiceSilentlyAndUnregisters() async throws {
        try await Support.withSupport {
            let botID = Support.uniqueBotID()
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: botID))
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)
            try await channel.attach()
            recorder.clear()

            await channel.shutdown()

            #expect(recorder.notices.isEmpty)
            #expect(!channel.isActive)
            #expect(await channel.controlService.currentState().isActive == false)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 0)
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Registry

    @Test
    func registryCountsTheChannelsOfEachBot() async throws {
        try await Support.withSupport {
            let botID = Support.uniqueBotID()
            let otherBotID = Support.uniqueBotID()
            let first = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: botID))
            let second = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: botID))
            let other = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: otherBotID))

            try await first.telegramChannel.attach()
            try await second.telegramChannel.attach()
            try await other.telegramChannel.attach()
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 2)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: otherBotID) == 1)

            await first.telegramChannel.detach()
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 1)
            await second.telegramChannel.shutdown()
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: botID) == 0)
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: otherBotID) == 1)
            await other.telegramChannel.shutdown()
            #expect(TelegramChannelRegistry.shared.attachedCount(botID: otherBotID) == 0)
            for terminal in [first, second, other] {
                await terminal.sessionHost.shutdown()
            }
        }
    }

    @Test
    func registryFollowsIdentityAndHoldsChannelsWeakly() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let registry = TelegramChannelRegistry()
            var channel: TelegramChannel? = TelegramChannel(
                host: terminal.sessionHost,
                slotID: terminal.terminalSlotID,
                sessionRunner: terminal.sessionRunner,
                router: TerminalTelegramSessionRouter(linkedChatID: 42, ownerUserID: 7, routes: []),
                controlService: TerminalTelegramControlService(
                    transportFactory: { TelegramChannelTestTransport(botID: 1) }
                ),
                primaryChannelDescription: "TUI",
                registry: registry
            )

            registry.register(try #require(channel), botID: 1)
            registry.register(try #require(channel), botID: 1)
            #expect(registry.attachedCount(botID: 1) == 1)
            registry.register(try #require(channel), botID: 2)
            #expect(registry.attachedCount(botID: 1) == 0)
            #expect(registry.attachedCount(botID: 2) == 1)
            registry.unregister(try #require(channel))
            registry.unregister(try #require(channel))
            #expect(registry.attachedCount(botID: 2) == 0)

            registry.register(try #require(channel), botID: 3)
            channel = nil
            #expect(registry.attachedCount(botID: 3) == 0)
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Texts

    /// `/telegram` writes the channel's status text; the static form words
    /// every control state the terminal showed.
    @Test
    func statusTextIsTheTerminals() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            Support.standInForInteractiveLoop(of: terminal)
            await terminal.startTelegramControl()
            let channel = terminal.telegramChannel
            let terminalWrites = await Support.capturing(terminal) {
                await terminal.printTelegramStatus()
            }

            #expect([await channel.statusText() + "\n"] == terminalWrites)
            #expect(terminalWrites == ["Telegram: Active as @zencode_bot\nBot: @zencode_bot\nLinked chat: Test\n"])

            let failing = TerminalTelegramControlState(
                isConfigured: true, isActive: true, statusText: "Active as @zencode_bot",
                botUsername: "zencode_bot", lastError: "Telegram send failed",
                lastMessagePreview: nil, wireLifecycleEpoch: UUID(),
                pollError: "Telegram polling failed: Unauthorized",
                commandMenuError: "Could not publish Telegram command menu: Unauthorized"
            )
            #expect(TelegramChannel.statusText(controlState: failing, linkedChatTitle: "Test") == """
                Telegram: Active as @zencode_bot
                Bot: @zencode_bot
                Linked chat: Test
                Polling error: Telegram polling failed: Unauthorized
                Command menu error: Could not publish Telegram command menu: Unauthorized
                Last error: Telegram send failed
                """)
            let configured = TerminalTelegramControlState(
                isConfigured: true, isActive: false, statusText: "Configured",
                botUsername: " ", lastError: nil, lastMessagePreview: nil
            )
            #expect(TelegramChannel.statusText(controlState: configured, linkedChatTitle: "  ") == "Telegram: Configured")
            #expect(TelegramChannel.statusText(controlState: configured, linkedChatTitle: nil, topicName: "Topic")
                == "Telegram: Configured\nTopic: Topic")
            #expect(TelegramChannel.statusText(controlState: .inactive(settings: nil), linkedChatTitle: "Test")
                == "Telegram: \(TerminalTelegramControlState.inactive(settings: nil).statusText)\nLinked chat: Test")
            await terminal.sessionHost.shutdown()
        }
    }

    /// The remote `/status`, `/help` and `/changes` texts, with and without
    /// file changes; the command list names every remote command.
    @Test
    func remoteTextsNameTheSessionAndItsChanges() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel

            #expect(channel.remoteStatusText() == """
                Session active.
                Agent: \(terminal.chatSession.selection.agent?.displayName ?? AgentProfileStore.developerAgentName)
                Model: \(terminal.chatSession.currentEffectiveModelID() ?? "default model")
                Working directory: /tmp/project
                """)
            #expect(channel.remoteHelpText().contains("Remote commands: \(TelegramChannel.remoteCommandList())."))
            #expect(TelegramChannel.remoteCommandList().contains("/status"))
            #expect(!TelegramChannel.remoteCommandList().contains("/telegram"))
            #expect(channel.remoteChangesText() == "No tracked file changes.")
            terminal.lastFileChangeSummary = Self.oneFileSummary
            #expect(channel.remoteChangesText().hasPrefix("1 modified file"))
            #expect(channel.remoteChangesText().contains("Value.swift"))
            terminal.lastFileChangeSummary = Self.twoFileSummary
            #expect(channel.remoteChangesText().hasPrefix("2 modified files"))
            #expect(channel.remoteChangesText().contains("Added.swift"))
            #expect(channel.remoteChangesText().contains("Removed.swift"))
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Poll health

    @Test
    func pollHealthNoticesHaveTheTerminalTexts() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)
            try await channel.attach()
            recorder.clear()

            await channel.presentPollHealthNotice(.failing("Telegram polling failed: Unauthorized"))
            await channel.presentPollHealthNotice(.recovered)

            #expect(recorder.notices == [
                .init(
                    text: "ZenCODE: Telegram is not receiving messages. Telegram polling failed: Unauthorized\n"
                        + "ZenCODE keeps retrying every minute. Check the bot token with /setup, or stop the other process polling this bot. /telegram shows the latest error.\n",
                    channel: .failure
                ),
                .init(text: "Telegram polling recovered; messages are being received again.\n", channel: .system),
            ])

            // Nothing is said once the link stopped.
            await channel.detach()
            recorder.clear()
            await channel.presentPollHealthNotice(.recovered)
            #expect(recorder.notices.isEmpty)
            await terminal.sessionHost.shutdown()
        }
    }

    /// A polling failure the service reports while the link starts is
    /// presented once the link is active, after the activation text.
    @Test
    func persistentPollingFailureIsPresentedAfterTheActivationText() async throws {
        try await Support.withSupport {
            let botID = Support.uniqueBotID()
            // deleteWebhook and getMe succeed; every later request (getUpdates,
            // setMyCommands) is rejected as a revoked token.
            let transport = ScriptedTelegramTransport(responses: [
                (200, Data(#"{"ok":true,"result":true}"#.utf8)),
                (200, Support.getMeBody(botID: botID)),
                (401, Support.unauthorizedBody),
            ])
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)

            try await channel.attach()
            try await Support.waitUntil { recorder.notices.count >= 2 }

            try #require(recorder.notices.count == 2)
            #expect(recorder.notices[0] == .init(text: Self.activationText, channel: .system))
            #expect(recorder.notices[1].channel == .failure)
            #expect(recorder.notices[1].text.hasPrefix(
                "ZenCODE: Telegram is not receiving messages. Telegram polling failed: "
            ))
            #expect(recorder.notices[1].text.hasSuffix("/telegram shows the latest error.\n"))
            #expect(await channel.statusText().contains("Polling error: Telegram polling failed: "))
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Egress

    @Test
    func routeChecksFollowTheLinkAndTheRoute() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let lease = try #require(channel.activeRouteLease)
            let stale = TerminalTelegramRouteLease(key: lease.key, generation: lease.generation + 1)

            #expect(channel.outgoingChatID(for: lease) == 42)
            #expect(channel.outgoingChatID(for: stale) == 42)
            #expect(await channel.validateLease(lease))
            #expect(!(await channel.validateLease(stale)))
            let fence = try #require(channel.wireFence(for: lease))
            #expect(fence.lease == lease)
            #expect(fence.lifecycleEpoch == channel.controlState.wireLifecycleEpoch)

            await channel.detach()
            #expect(channel.outgoingChatID(for: lease) == nil)
            #expect(!(await channel.validateLease(lease)))
            #expect(channel.wireFence(for: lease) == nil)
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func systemMessagesGoThroughTheSeamsBeforeTheService() async throws {
        try await Support.withSupport {
            let transport = TelegramChannelTestTransport(botID: Support.uniqueBotID())
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel
            try await channel.attach()
            let lease = try #require(channel.activeRouteLease)
            let routed = TelegramTestRecorder<String>()
            let legacy = TelegramTestRecorder<String>()

            channel.onTelegramRoutedSystemMessage = { text, chatID, topicID in
                routed.append("\(text)|\(chatID)|\(topicID.map(String.init) ?? "nil")")
                return true
            }
            channel.onTelegramSystemMessage = { text, chatID in
                legacy.append("\(text)|\(chatID)")
                return true
            }
            #expect(await channel.sendSystemMessage("routed", to: 42, lease: lease))
            channel.onTelegramRoutedSystemMessage = nil
            #expect(await channel.sendSystemMessage("legacy", to: 42, lease: lease))
            channel.onTelegramSystemMessage = nil
            #expect(await channel.sendSystemMessage("wire", to: 42, lease: lease))
            #expect(!(await channel.sendSystemMessage("other chat", to: 43, lease: lease)))
            await channel.sendSystemMessageIfLinked("linked", lease: lease)
            await channel.detach()
            await channel.sendSystemMessageIfLinked("unlinked", lease: lease)

            #expect(routed.values == ["routed|42|nil"])
            #expect(legacy.values == ["legacy|42"])
            #expect(await transport.sentTexts == ["wire", "linked"])
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func failedSendIsRecordedAndPresented() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(
                transport: TelegramChannelTestTransport(botID: Support.uniqueBotID(), sendMessageFails: true)
            )
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)
            try await channel.attach()
            recorder.clear()
            let lease = try #require(channel.activeRouteLease)

            #expect(!(await channel.sendSystemMessage("hello", to: 42, lease: lease)))

            let lastError = try #require(channel.controlState.lastError)
            #expect(recorder.notices == [.init(text: "ZenCODE: \(lastError)\n", channel: .failure)])
            #expect(lastError.contains("chat not found"))
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func turnMessagesNeedTheLinkAndPreferTheDirectSeam() async throws {
        try await Support.withSupport {
            let transport = TelegramChannelTestTransport(botID: Support.uniqueBotID())
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel
            let detachedLease = TerminalTelegramRouteLease(key: Support.defaultRouteKey, generation: 1)
            let direct = TelegramTestRecorder<String>()
            channel.onDirectTelegramTurnMessage = { payload, chatID in
                direct.append("\(payload.text)|\(chatID)")
                return true
            }
            #expect(!(await channel.sendTurnMessage(.authorization("detached"), to: 42, lease: detachedLease)))

            try await channel.attach()
            let lease = try #require(channel.activeRouteLease)
            #expect(await channel.sendTurnMessage(.authorization("direct"), to: 42, lease: lease))
            await channel.sendTurnMessageIfLinked(.authorization("linked"), lease: lease)
            channel.onDirectTelegramTurnMessage = nil
            #expect(await channel.sendTurnMessage(.authorization("wire"), to: 42, lease: lease))

            #expect(direct.values == ["direct|42", "linked|42"])
            #expect(await transport.sentTexts == ["wire"])
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Turn endings

    /// Completed, empty, long, failed, and stopped turns, with and without a
    /// summary, end in the chat with the terminal's texts.
    @Test
    func turnEndingsAreSentWithTheTerminalTexts() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let cases: [(ChatTurnEnding.Outcome, TurnFileChangeSummary?)] = [
                (.completed(Self.response("All done.")), nil),
                (.completed(Self.response("  \n")), nil),
                (.completed(Self.response(String(repeating: "a", count: 4_000))), nil),
                (.completed(Self.response("Changed two files.")), Self.twoFileSummary),
                (.failed("The model is unavailable."), Self.oneFileSummary),
                (.cancelled, Self.twoFileSummary),
            ]
            var results: [[String]] = []
            for (outcome, summary) in cases {
                await channel.beginTurn(adoptingStreamingBlock: false)
                let log = TelegramTurnMessageLog()
                await Self.installLog(log, on: channel)
                await channel.finishTurn(ending: ChatTurnEnding(outcome: outcome, fileChangeSummary: summary))
                results.append(await log.messages)
            }

            #expect(results == [
                ["*ZenCODE completed*\n\nAll done."],
                ["*ZenCODE completed*\n\nDone."],
                ["*ZenCODE completed*\n\n" + String(repeating: "a", count: 3_600)],
                ["*ZenCODE completed*\n\nChanged two files.", Self.summaryText(Self.twoFileSummary)],
                ["ZenCODE failed: The model is unavailable.", Self.summaryText(Self.oneFileSummary)],
                ["Stopped.", Self.summaryText(Self.twoFileSummary)],
            ])
            await terminal.sessionHost.shutdown()
        }
    }

    /// Without a reporter the outcome and the summary go to the linked chat
    /// directly; without an outcome only the summary goes.
    @Test
    func endingAndSummaryReachTheChatDirectlyWithoutAReporter() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let direct = TelegramTestRecorder<String>()
            channel.onDirectTelegramTurnMessage = { payload, chatID in
                direct.append("\(payload.text)|\(chatID)")
                return true
            }

            await channel.beginTurn(adoptingStreamingBlock: false)
            await channel.activeProgressReporter?.revokeAndWait()
            channel.activeProgressReporter = nil
            await channel.finishTurn(ending: ChatTurnEnding(
                outcome: .completed(Self.response("Done.")), fileChangeSummary: Self.oneFileSummary
            ))
            await channel.beginTurn(adoptingStreamingBlock: false)
            await channel.activeProgressReporter?.revokeAndWait()
            channel.activeProgressReporter = nil
            await channel.retireTurn(outcomePayload: nil, fileChangeSummary: Self.oneFileSummary)

            let summary = Self.summaryText(Self.oneFileSummary)
            #expect(direct.values == ["*ZenCODE completed*\n\nDone.|42", "\(summary)|42", "\(summary)|42"])
            #expect(channel.activeTurnLease == nil)
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Presenter

    /// The presenter sends the overviews as plain text: a task graph once per
    /// signature within a turn, the sub-agent response blocks once each
    /// without their metadata, a completed sub-agent response as its
    /// Markdown; the task-graph dedup starts over at every turn, the
    /// sub-agent responses are never sent again in a later turn; an overview
    /// with no reporter sending the turn is dropped.
    @Test
    func overviewsAreSentOnceAsPlainTextAndTheResponseDedupOutlivesTheTurn() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let presenter = channel.presenter
            let request = ChatTurnRequest(
                prompt: "go",
                sessionConfiguration: await terminal.chatSession.turnSessionConfiguration(
                    for: .normal, responseLanguageSection: nil
                )
            )

            // No turn: nothing is sent, nothing is remembered.
            let silent = TelegramTestRecorder<String>()
            channel.onDirectTelegramTurnMessage = { payload, _ in
                silent.append(payload.text)
                return true
            }
            await channel.enqueueOverview(.tasks("📋 Task graph\n\nlate"), taskGraphSignature: "graph-9")
            #expect(silent.values.isEmpty)
            #expect(channel.publishedTaskGraphOverviewSignature != "graph-9")
            channel.onDirectTelegramTurnMessage = nil

            await presenter.turnWillStart(request)
            let log = TelegramTurnMessageLog()
            let reporter = await Self.installLog(log, on: channel)
            let snapshots = [Self.subAgentSnapshot(
                id: "worker", response: "**Delegated** answer.", partial: "Looking into it."
            )]
            let overview = ChatSubAgentOverview(snapshots: snapshots)
            await channel.enqueueOverview(.tasks("📋 Task graph\n\n1 running"), taskGraphSignature: "graph-1")
            await channel.enqueueOverview(.tasks("📋 Task graph\n\n1 running"), taskGraphSignature: "graph-1")
            await channel.enqueueOverview(.tasks("📋 Task graph\n\n1 done"), taskGraphSignature: "graph-3")
            await presenter.presentSubAgentOverview(overview, origin: .automatic, publication: nil)
            await presenter.presentSubAgentOverview(overview, origin: .automatic, publication: nil)
            await reporter.flush()
            let messages = await log.messages
            #expect(messages.count == 4)
            #expect(Array(messages.prefix(2)) == ["📋 Task graph\n\n1 running", "📋 Task graph\n\n1 done"])
            for message in messages {
                #expect(!message.contains("\u{1B}["), "\(message)")
            }
            #expect(messages.dropFirst(2).first == "💬 worker:\n\nLooking into it.")
            let completed = try #require(messages.last)
            #expect(completed.hasSuffix("\n\n**Delegated** answer."))
            #expect(!completed.contains("worker:\n\nLooking"))
            // The heading loses the terminal's colors.
            #expect(TelegramChannelPresenter.subAgentResponsePayload(
                heading: "\u{1B}[36m   ✅ Response from worker:\u{1B}[0m\n", markdown: "**First** answer"
            )?.text == "✅ Response from worker:\n\n**First** answer")
            #expect(TelegramChannelPresenter.subAgentResponsePayload(heading: "💬 worker:", markdown: "  ") == nil)

            // The next turn starts a new task-graph dedup, and does not send
            // the same sub-agent responses again.
            await presenter.turnWillStart(request)
            let next = TelegramTurnMessageLog()
            let nextReporter = await Self.installLog(next, on: channel)
            await channel.enqueueOverview(.tasks("📋 Task graph\n\n1 running"), taskGraphSignature: "graph-1")
            await presenter.presentSubAgentOverview(overview, origin: .automatic, publication: nil)
            await nextReporter.flush()
            #expect(await next.messages.count == 1)
            #expect(await next.messages.first == "📋 Task graph\n\n1 running")

            await channel.endTurnReporting()
            await terminal.sessionHost.shutdown()
        }
    }

    @Test
    func noticeCaptureCollectsTheNoticesOfARemoteCommand() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            let presenter = channel.presenter
            let blocked = ChatWorkflowNotice.blocked(graphID: "graph-1", message: "Waiting for review.")

            await presenter.presentSessionNotice(.workflowMissingGoal)
            presenter.beginNoticeCapture()
            await presenter.presentSessionNotice(.workflowMissingGoal)
            await presenter.presentWorkflowNotice(blocked)
            #expect(presenter.endNoticeCapture() == [
                ChatSessionNoticeText.text(for: ChatSessionNotice.workflowMissingGoal),
                ChatSessionNoticeText.text(for: blocked),
            ])
            await presenter.presentSessionNotice(.workflowMissingGoal)
            #expect(presenter.endNoticeCapture().isEmpty)
            await terminal.sessionHost.shutdown()
        }
    }

    /// `ChatSessionNoticeText.text(for:)`, which the channel sends, words
    /// every workflow notice as the terminal's presenter writes it.
    @Test
    func workflowNoticeTextsMatchTheTerminalPresenter() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let presenter = TerminalChatSessionPresenter()
            presenter.chat = terminal
            let notices: [ChatWorkflowNotice] = [
                .awaitingReply(graphID: "graph-1", pendingTaskCount: 1),
                .awaitingReply(graphID: "graph-1", pendingTaskCount: 2),
                .blocked(graphID: "graph-1", message: "Waiting for review."),
                .openWithoutQuestion(graphID: "graph-1", pendingTaskCount: 3),
                .recoverableFailure(graphID: "graph-1", pendingTaskCount: 1),
            ]
            for notice in notices {
                let terminalWrites = await Support.capturing(terminal) {
                    await presenter.presentWorkflowNotice(notice)
                }
                #expect(terminalWrites == [ChatSessionNoticeText.text(for: notice)], "\(notice)")
            }
            #expect(
                ChatSessionNoticeText.text(for: .blocked(graphID: "graph-1", message: "Waiting for review."))
                    == "Workflow \"graph-1\" is blocked: Waiting for review.\n"
                    + "Your next message resumes this same workflow; use /tasks clear to stop it.\n"
            )
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Route validation

    /// A turn on a route lease is stopped as soon as the route is revoked:
    /// the turn's reporting ends and the link's route is forgotten.
    @Test
    func revokedRouteStopsTheTurn() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let lease = try #require(channel.activeRouteLease)

            // A turn that finishes stops its validation.
            await channel.beginTurn(adoptingStreamingBlock: false)
            #expect(channel.routeValidationTask != nil)
            await channel.endTurnReporting()
            #expect(channel.routeValidationTask == nil)

            await channel.beginTurn(adoptingStreamingBlock: false)
            #expect(channel.activeTurnLease == lease)
            #expect(channel.routeValidationTask != nil)
            await channel.router.refresh(
                linkedChatID: 42, ownerUserID: 7,
                routes: [AgentTelegramRouteManifest(roomID: "default", generation: lease.generation + 1)]
            )
            try await Support.waitUntil { channel.activeTurnLease == nil }
            #expect(channel.activeTurnLease == nil)
            #expect(channel.activeProgressReporter == nil)
            #expect(channel.routeValidationTask == nil)
            #expect(channel.activeRouteLease == nil)
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Consent

    /// Tools outside the gated set run without asking; a gated call while
    /// the channel has no link is denied with the terminal's text. Every
    /// destructive tool of the executor is gated.
    @Test
    func ungatedToolsRunAndAnUnlinkedChannelDenies() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)
            let authorizer = terminal.permissionAuthorizer.consentAuthorizer

            #expect(DirectToolExecutor.destructiveGatedToolNames.allSatisfy(
                ChatToolConsentAuthorizer.gatedToolNames.contains
            ))
            #expect(await authorizer.isAlreadyAuthorized(Self.readRequest))
            #expect(!(await authorizer.isAlreadyAuthorized(Self.deleteRequest())))
            #expect(await channel.requestToolConsent(Self.deleteRequest()) == nil)
            #expect(recorder.notices == [.init(
                text: "ZenCODE: Telegram cannot request permission for local.delete; the operation was denied.\n",
                channel: .failure
            )])
            await terminal.sessionHost.shutdown()
        }
    }

    /// The decision of the chat is told to the primary channel with the
    /// terminal's texts.
    @Test
    func permissionRepliesAreAnsweredAndToldToThePrimaryChannel() async throws {
        try await Support.withSupport {
            let transport = TelegramChannelTestTransport(botID: Support.uniqueBotID())
            let terminal = try Support.makeTerminal(transport: transport)
            let channel = terminal.telegramChannel
            let recorder = TelegramChannelNoticeRecorder()
            recorder.install(on: channel)
            try await channel.attach()
            recorder.clear()
            let lease = try #require(channel.activeRouteLease)

            for (command, expected, notice) in [
                ("/allow", ChatConsentDecision.allowOnce, "Telegram approved local.delete.\n"),
                ("/deny", .denyOnce, "Telegram denied local.delete.\n"),
            ] {
                let sentBefore = await transport.sentTexts.count
                let decision = Task { @ChatSessionActor in
                    await channel.requestToolConsent(Self.deleteRequest())
                }
                try await Support.waitUntil { await transport.sentTexts.count > sentBefore }
                let card = try #require(await transport.sentTexts.last)
                let requestID = try #require(Self.permissionRequestID(in: card))
                #expect(await channel.handlePermissionResponseIfNeeded("\(command) \(requestID)", lease: lease))
                #expect(await decision.value == expected)
                #expect(recorder.notices.last == .init(text: notice, channel: .system))
            }
            #expect(!(await channel.handlePermissionResponseIfNeeded("hello", lease: lease)))
            #expect(await channel.handlePermissionResponseIfNeeded("/allow nope", lease: lease))
            #expect(await transport.sentTexts.last == "No permission request is pending.")
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Support

    private static func response(_ text: String) -> DirectAgentResponse {
        DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "test-model")
    }

    private static var readRequest: AgentToolAuthorizationRequest {
        authorizationRequest(
            toolName: "local.readFile", title: "Read Sources/Main.swift",
            kind: "read", command: "read Sources/Main.swift"
        )
    }

    private static func deleteRequest(_ path: String = "Sources/Old.swift") -> AgentToolAuthorizationRequest {
        authorizationRequest(
            toolName: "local.delete", title: "Delete \(path)",
            kind: "destructive", command: "delete \(path)"
        )
    }

    private static func authorizationRequest(
        toolName: String, title: String, kind: String, command: String
    ) -> AgentToolAuthorizationRequest {
        AgentToolAuthorizationRequest(
            sessionID: "terminal-test",
            toolCallID: "tool-call-test",
            toolName: toolName,
            title: title,
            kind: kind,
            command: command,
            workingDirectory: "/tmp/project"
        )
    }

    /// The request ID a permission request message carries.
    private static func permissionRequestID(in message: String) -> String? {
        message
            .split(separator: "\n")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Request ID:") }
            .map {
                $0.replacingOccurrences(of: "Request ID:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
    }

    /// The summary text the channel sends for `summary`.
    private static func summaryText(_ summary: TurnFileChangeSummary) -> String {
        TurnFileChangeSummaryPresentation.text(summary, includesCommandHint: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Replaces the reporter of `channel`'s turn with one that records into
    /// `log`.
    @discardableResult
    private static func installLog(
        _ log: TelegramTurnMessageLog, on channel: TelegramChannel
    ) async -> TerminalTelegramTurnProgressReporter {
        await channel.activeProgressReporter?.revokeAndWait()
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await log.append(message)
            return true
        }
        channel.activeProgressReporter = reporter
        return reporter
    }

    /// A sub-agent snapshot with one completed response and one block
    /// promoted at a tool boundary.
    private static func subAgentSnapshot(
        id: String, response: String, partial: String
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        let date = Date(timeIntervalSince1970: 1_000)
        return DirectSubAgentRuntime.AgentSnapshot(
            id: id,
            name: id,
            role: "worker",
            status: .idle,
            pending: false,
            currentActivity: partial,
            currentActivityKind: .content,
            currentActivityRevision: 1,
            latestOutput: response,
            latestError: nil,
            createdAt: date,
            updatedAt: date
        )
    }
}

/// The messages a reporter delivered, in order.
actor TelegramTurnMessageLog {
    private(set) var messages: [String] = []

    func append(_ message: String) {
        messages.append(message)
    }
}
