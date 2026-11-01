//
//  TelegramSessionCompanionTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// The Telegram companion's core: attach, detach, shutdown, the status and
/// remote texts, egress through its seams, poll-health notices, and the
/// per-bot attachment registry; the mirror of the turn (root-response
/// buffer, tool boundaries, outcomes, overviews, route validation), the
/// companion's presenter, and the consent race; what the companion answers
/// to the Telegram ingress (`/diff` and the artifact consent, inbound
/// attachments, voice notes, the shared-chat relay and its replies, the
/// `/chat` picker) and the mention parser it shares with the terminal; and
/// the ingress itself: authorization, the busy gate, ForceReply, admission
/// to the channel's queue, the dispatch of the remote commands and of
/// `/plan` `/goal` `/review` through the controller, the mirror-only
/// policy, the permission replies on a route several sessions share, and
/// the consumer of a channel without a loop; and the topic mode and legacy
/// mode of the link: the reuse, creation and announcement of the session's
/// topic, the fallback to the shared route, the rebind with its rename, and
/// the close and prune at detach and shutdown.
///
/// Every text the terminal writes today is compared with the text the
/// companion gives its channel, produced by the terminal itself on the same
/// settings (its writes are captured through `telegramImmediateCommandOutput`).
/// The mirrored messages are compared the same way: the terminal and the
/// companion each mirror to a reporter whose messages a log records, and run
/// the same turn. Each test runs in its own support directory, with control
/// services on private dispatchers and a registry of its own.
@Suite(.serialized)
struct TelegramSessionCompanionTests {
    private static let pairedSettings = AgentTelegramSettingsManifest(
        enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42,
        linkedChatTitle: "Test", ownerUserID: 7, routes: [.init(roomID: "default")]
    )

    private static let defaultRouteKey = TerminalTelegramRouteKey(
        chatID: 42, userID: 7, roomID: "default"
    )

    // MARK: - Attach

    @Test
    func attachLinksTheSessionWithTheTerminalActivationText() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9301))
            let terminalWrites = await Self.capturing(terminal) {
                await terminal.startTelegramControl()
            }
            let channel = ScriptedCompanionChannel()
            let attachments = TelegramCompanionAttachments()
            let companion = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9301),
                channel: channel, attachments: attachments
            )

            try await companion.attach()

            #expect(terminalWrites == ["Telegram remote control is active.\nLinked chat: Test\n"])
            #expect(channel.notices == terminalWrites.map { .init(text: $0, channel: .system) })
            #expect(companion.isActive)
            #expect(companion.controlState.botID == 9301)
            #expect(companion.linkedChatID == 42)
            #expect(companion.linkedChatTitle == "Test")
            #expect(companion.linkedUserID == 7)
            let lease = try #require(companion.activeRouteLease)
            #expect(lease.key == Self.defaultRouteKey)
            #expect(lease == terminal.telegramActiveRouteLease)
            #expect(attachments.attachedCount(botID: 9301) == 1)

            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    @Test
    func attachWithoutPairingThrowsTheTerminalText() async throws {
        let unpaired = AgentTelegramSettingsManifest(enabled: true, botToken: "123456:ABCDEF")
        try await Self.withSupport(telegram: unpaired) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9302))
            // The terminal hides `/telegram` without a pairing; the channel
            // keeps that guard, so it is lifted to reach the same failure.
            terminal.optionalCommandAvailability = .init(telegramEnabled: true, voiceEnabled: false)
            let terminalWrites = await Self.capturing(terminal) {
                await terminal.startTelegramControl()
            }
            let transport = CompanionTelegramTransport(botID: 9302)
            let channel = ScriptedCompanionChannel()
            let attachments = TelegramCompanionAttachments()
            let companion = Self.makeCompanion(
                on: terminal, transport: transport, channel: channel, attachments: attachments
            )

            do throws(TelegramCompanionAttachError) {
                try await companion.attach()
                Issue.record("attach linked an unpaired session")
            } catch {
                #expect(error == .notPaired)
                #expect([error.failureText] == terminalWrites)
            }
            #expect(terminalWrites == ["ZenCODE: Telegram is not paired. Run the /setup command in zen.\n"])
            #expect(channel.notices.isEmpty)
            #expect(!companion.isActive)
            #expect(await transport.requestCount == 0)
            #expect(attachments.attachedCount(botID: 9302) == 0)
        }
    }

    @Test
    func attachWithoutAUsableRouteThrowsTheTerminalText() async throws {
        let foreignRoute = AgentTelegramSettingsManifest(
            enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42,
            linkedChatTitle: "Test", ownerUserID: 7, routes: [.init(roomID: "foreign-session")]
        )
        try await Self.withSupport(telegram: foreignRoute) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9303))
            let terminalWrites = await Self.capturing(terminal) {
                await terminal.startTelegramControl()
            }
            let transport = CompanionTelegramTransport(botID: 9303)
            let channel = ScriptedCompanionChannel()
            let attachments = TelegramCompanionAttachments()
            let companion = Self.makeCompanion(
                on: terminal, transport: transport, channel: channel, attachments: attachments
            )

            do throws(TelegramCompanionAttachError) {
                try await companion.attach()
                Issue.record("attach linked a session without its route")
            } catch {
                #expect(error == .invalidConfiguration)
                #expect([error.failureText] == terminalWrites)
            }
            #expect(terminalWrites == [
                "ZenCODE: Telegram configuration is invalid. Run /setup to pair Telegram again.\n"
            ])
            #expect(channel.notices.isEmpty)
            #expect(companion.activeRouteLease == nil)
            #expect(await transport.requestCount == 0)
            #expect(attachments.attachedCount(botID: 9303) == 0)
        }
    }

    @Test
    func attachThatCannotStartRecordsTheTerminalErrorAndStaysUnregistered() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: Self.unauthorizedGetMeTransport())
            let terminalWrites = await Self.capturing(terminal) {
                await terminal.startTelegramControl()
            }
            let channel = ScriptedCompanionChannel()
            let attachments = TelegramCompanionAttachments()
            let companion = Self.makeCompanion(
                on: terminal, transport: Self.unauthorizedGetMeTransport(),
                channel: channel, attachments: attachments
            )

            do throws(TelegramCompanionAttachError) {
                try await companion.attach()
                Issue.record("attach succeeded with a rejected token")
            } catch {
                guard case let .controlFailed(description) = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
                #expect([error.failureText] == terminalWrites)
                #expect(companion.controlState.lastError == description)
                #expect(terminal.telegramControlState.lastError == description)
            }
            #expect(terminalWrites.count == 1)
            #expect(channel.notices.isEmpty)
            #expect(!companion.isActive)
            // As in the terminal, the linked chat stays recorded after a
            // failed start.
            #expect(companion.linkedChatID == terminal.telegramLinkedChatID)
            #expect(companion.activeRouteLease == terminal.telegramActiveRouteLease)
            #expect(companion.controlState.botID == nil)
            #expect(attachments.attachedCount(botID: 9301) == 0)
        }
    }

    @Test
    func repeatedAttachRestartsTheServiceAndRegistersOnce() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9304))
            let terminalWrites = await Self.capturing(terminal) {
                await terminal.startTelegramControl()
                await terminal.startTelegramControl()
            }
            let channel = ScriptedCompanionChannel()
            let attachments = TelegramCompanionAttachments()
            let companion = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9304),
                channel: channel, attachments: attachments
            )

            try await companion.attach()
            let firstEpoch = try #require(companion.controlState.wireLifecycleEpoch)
            try await companion.attach()
            let secondEpoch = try #require(companion.controlState.wireLifecycleEpoch)

            #expect(firstEpoch != secondEpoch)
            #expect(channel.noticeTexts == terminalWrites)
            #expect(channel.noticeTexts.count == 2)
            #expect(attachments.attachedCount(botID: 9304) == 1)

            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    @Test
    func failedReattachRemovesTheRegistration() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9305))
            let transport = CompanionTelegramTransport(botID: 9305)
            let attachments = TelegramCompanionAttachments()
            let companion = Self.makeCompanion(
                on: terminal, transport: transport,
                channel: ScriptedCompanionChannel(), attachments: attachments
            )

            try await companion.attach()
            #expect(attachments.attachedCount(botID: 9305) == 1)
            await transport.setGetMeFails(true)
            do throws(TelegramCompanionAttachError) {
                try await companion.attach()
                Issue.record("attach succeeded with a rejected token")
            } catch {
                guard case .controlFailed = error else {
                    Issue.record("unexpected error \(error)")
                    return
                }
            }

            #expect(!companion.isActive)
            #expect(attachments.attachedCount(botID: 9305) == 0)
            await companion.shutdown()
        }
    }

    @Test
    func attachMovesARunningPrimaryTurnOntoTheRoute() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9306))
            terminal.activeTelegramTurnOrigin = .local
            await terminal.startTelegramControl()
            let companion = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9306),
                channel: ScriptedCompanionChannel(), attachments: TelegramCompanionAttachments()
            )
            companion.activeTurnOrigin = .primary

            try await companion.attach()

            let lease = try #require(companion.activeRouteLease)
            #expect(companion.activeTurnOrigin == .telegram(lease))
            #expect(terminal.activeTelegramTurnOrigin == .telegramLease(lease))

            terminal.activeTelegramTurnOrigin = nil
            companion.activeTurnOrigin = nil
            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    // MARK: - Detach and shutdown

    @Test
    func detachUnlinksWithTheTerminalTextAndLeavesTheRegistry() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9307))
            await terminal.startTelegramControl()
            let terminalWrites = await Self.capturing(terminal) {
                await terminal.stopTelegramControl()
            }
            let channel = ScriptedCompanionChannel()
            let attachments = TelegramCompanionAttachments()
            let companion = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9307),
                channel: channel, attachments: attachments
            )
            try await companion.attach()
            channel.clear()

            await companion.detach()

            #expect(terminalWrites == ["Telegram remote control stopped.\n"])
            #expect(channel.notices == terminalWrites.map { .init(text: $0, channel: .system) })
            #expect(!companion.isActive)
            #expect(companion.controlState.wireLifecycleEpoch == nil)
            #expect(companion.controlState.botID == 9307)
            #expect(companion.linkedChatID == nil)
            #expect(companion.linkedChatTitle == nil)
            #expect(companion.linkedUserID == nil)
            #expect(companion.activeRouteLease == nil)
            #expect(attachments.attachedCount(botID: 9307) == 0)
        }
    }

    @Test
    func detachWithoutAttachTellsTheTerminalTextAndKeepsOtherRegistrations() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9308))
            let terminalWrites = await Self.capturing(terminal) {
                await terminal.stopTelegramControl()
            }
            let attachments = TelegramCompanionAttachments()
            let attached = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9308),
                channel: ScriptedCompanionChannel(), attachments: attachments
            )
            try await attached.attach()
            let channel = ScriptedCompanionChannel()
            let neverAttached = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9308),
                channel: channel, attachments: attachments
            )

            await neverAttached.detach()

            #expect(channel.noticeTexts == terminalWrites)
            #expect(!neverAttached.isActive)
            #expect(attachments.attachedCount(botID: 9308) == 1)
            await attached.shutdown()
        }
    }

    @Test
    func shutdownStopsTheServiceSilentlyAndUnregisters() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9309))
            let channel = ScriptedCompanionChannel()
            let attachments = TelegramCompanionAttachments()
            let companion = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9309),
                channel: channel, attachments: attachments
            )
            try await companion.attach()
            channel.clear()

            await companion.shutdown()

            #expect(channel.notices.isEmpty)
            #expect(!companion.isActive)
            #expect(await companion.controlService.currentState().isActive == false)
            #expect(attachments.attachedCount(botID: 9309) == 0)
        }
    }

    // MARK: - Attachments

    @Test
    func attachmentsCountTheCompanionsOfEachBot() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9310))
            let attachments = TelegramCompanionAttachments()
            let first = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9310),
                channel: ScriptedCompanionChannel(), attachments: attachments
            )
            let second = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9310),
                channel: ScriptedCompanionChannel(), attachments: attachments
            )
            let otherBot = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9311),
                channel: ScriptedCompanionChannel(), attachments: attachments
            )

            try await first.attach()
            try await second.attach()
            try await otherBot.attach()
            #expect(attachments.attachedCount(botID: 9310) == 2)
            #expect(attachments.attachedCount(botID: 9311) == 1)

            await first.detach()
            #expect(attachments.attachedCount(botID: 9310) == 1)
            await second.shutdown()
            #expect(attachments.attachedCount(botID: 9310) == 0)
            #expect(attachments.attachedCount(botID: 9311) == 1)
            await otherBot.shutdown()
            #expect(attachments.attachedCount(botID: 9311) == 0)
        }
    }

    @Test
    func attachmentsFollowIdentityAndHoldCompanionsWeakly() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9312))
            let attachments = TelegramCompanionAttachments()
            var companion: TelegramSessionCompanion? = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9312),
                channel: ScriptedCompanionChannel(), attachments: attachments
            )

            attachments.register(try #require(companion), botID: 1)
            attachments.register(try #require(companion), botID: 1)
            #expect(attachments.attachedCount(botID: 1) == 1)
            attachments.register(try #require(companion), botID: 2)
            #expect(attachments.attachedCount(botID: 1) == 0)
            #expect(attachments.attachedCount(botID: 2) == 1)
            attachments.unregister(try #require(companion))
            attachments.unregister(try #require(companion))
            #expect(attachments.attachedCount(botID: 2) == 0)

            attachments.register(try #require(companion), botID: 3)
            companion = nil
            #expect(attachments.attachedCount(botID: 3) == 0)
        }
    }

    // MARK: - Texts

    @Test
    func statusTextMatchesTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9313))
            await terminal.startTelegramControl()
            let terminalWrites = await Self.capturing(terminal) {
                await terminal.printTelegramStatus()
            }
            let companion = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9313),
                channel: ScriptedCompanionChannel(), attachments: TelegramCompanionAttachments()
            )
            try await companion.attach()

            #expect([await companion.statusText() + "\n"] == terminalWrites)
            #expect(terminalWrites == ["Telegram: Active as @zencode_bot\nBot: @zencode_bot\nLinked chat: Test\n"])

            let states = [
                TerminalTelegramControlState(
                    isConfigured: true, isActive: true, statusText: "Active as @zencode_bot",
                    botUsername: "zencode_bot", lastError: "Telegram send failed",
                    lastMessagePreview: nil, wireLifecycleEpoch: UUID(),
                    pollError: "Telegram polling failed: Unauthorized",
                    commandMenuError: "Could not publish Telegram command menu: Unauthorized"
                ),
                TerminalTelegramControlState(
                    isConfigured: true, isActive: false, statusText: "Configured",
                    botUsername: " ", lastError: nil, lastMessagePreview: nil
                ),
                TerminalTelegramControlState.inactive(settings: nil),
            ]
            for state in states {
                for title in ["Test", nil, "  "] as [String?] {
                    terminal.telegramControlState = state
                    terminal.telegramLinkedChatTitle = title
                    #expect(
                        TelegramSessionCompanion.statusText(controlState: state, linkedChatTitle: title)
                            == terminal.telegramStatusText()
                    )
                }
            }

            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    @Test
    func remoteTextsMatchTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9314))
            let companion = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9314),
                channel: ScriptedCompanionChannel(), attachments: TelegramCompanionAttachments()
            )

            #expect(companion.remoteStatusText() == terminal.telegramRemoteStatusText())
            #expect(companion.remoteHelpText() == terminal.telegramRemoteHelpText())
            #expect(
                TelegramSessionCompanion.remoteCommandList(policy: .full)
                    == TerminalChat.telegramRemoteCommandList()
            )
            #expect(companion.remoteChangesText() == terminal.telegramRemoteChangesText())
            #expect(companion.remoteChangesText() == "No tracked file changes.")
            for summary in [Self.oneFileSummary, Self.twoFileSummary] {
                terminal.lastFileChangeSummary = summary
                #expect(companion.remoteChangesText() == terminal.telegramRemoteChangesText())
            }
        }
    }

    /// A mirror-only companion lists only the commands it accepts. The list
    /// follows the order of the refusal text (D7), not the registry's, so
    /// the help, the refusal and the unknown-command answer name the same
    /// commands in the same order; its help is the D7 text.
    @Test
    func mirrorOnlyListsOnlyTheCommandsItAccepts() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            #expect(
                TelegramSessionCompanion.remoteCommandList(policy: .mirrorOnly)
                    == "/help, /status, /changes, /diff, /chat"
            )
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9315))
            let companion = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9315),
                channel: ScriptedCompanionChannel(), attachments: TelegramCompanionAttachments(),
                configuration: .init(primaryChannelDescription: "ACP", policy: .mirrorOnly)
            )

            #expect(companion.remoteHelpText() == """
                Telegram mirrors the ZenCODE session driven by the ACP; send prompts there.
                Remote commands: /help, /status, /changes, /diff, /chat.
                /diff sends a file only after you confirm it with an explicit button; nothing is uploaded automatically.
                Permission replies: /allow ID, /always ID, /deny ID. Gated operations (shell commands, deletions, git push/restore) are asked here too.
                Prompts, voice notes, /plan, /goal, /review and /undo are not available from Telegram in this session.
                """)
            #expect(companion.remoteHelpText() != terminal.telegramRemoteHelpText())
            #expect(companion.mirrorOnlyRefusalText.contains(
                "/help, /status, /changes, /diff and /chat"
            ))
        }
    }

    // MARK: - Poll health

    @Test
    func pollHealthNoticesMatchTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9316))
            await terminal.startTelegramControl()
            let notices: [TerminalTelegramPollHealthNotice] = [
                .failing("Telegram polling failed: Unauthorized"), .recovered,
            ]
            let terminalWrites = await Self.capturing(terminal) {
                for notice in notices {
                    await terminal.writeTelegramPollHealthNotice(notice)
                }
            }
            let channel = ScriptedCompanionChannel()
            let companion = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9316),
                channel: channel, attachments: TelegramCompanionAttachments()
            )
            try await companion.attach()
            channel.clear()

            for notice in notices {
                await companion.presentPollHealthNotice(notice)
            }

            #expect(channel.noticeTexts == terminalWrites)
            #expect(channel.notices.map(\.channel) == [.failure, .system])

            await terminal.stopTelegramControl()
            await companion.detach()
            let terminalWritesWhileStopped = await Self.capturing(terminal) {
                await terminal.writeTelegramPollHealthNotice(.recovered)
            }
            channel.clear()
            await companion.presentPollHealthNotice(.recovered)
            #expect(terminalWritesWhileStopped.isEmpty)
            #expect(channel.notices.isEmpty)
        }
    }

    @Test
    func persistentPollingFailureReachesTheChannelAfterTheActivationText() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9317))
            // deleteWebhook and getMe succeed; every later request (getUpdates,
            // setMyCommands) is rejected as a revoked token.
            let transport = ScriptedTelegramTransport(responses: [
                (200, Data(#"{"ok":true,"result":true}"#.utf8)),
                (200, Self.getMeBody(botID: 9317)),
                (401, Self.unauthorizedBody),
            ])
            let channel = ScriptedCompanionChannel()
            let companion = Self.makeCompanion(
                on: terminal, transport: transport,
                channel: channel, attachments: TelegramCompanionAttachments()
            )

            try await companion.attach()
            try await Self.waitUntil { channel.notices.count >= 2 }

            try #require(channel.notices.count == 2)
            #expect(channel.notices[0] == .init(
                text: "Telegram remote control is active.\nLinked chat: Test\n", channel: .system
            ))
            #expect(channel.notices[1].channel == .failure)
            #expect(channel.notices[1].text.hasPrefix(
                "ZenCODE: Telegram is not receiving messages. Telegram polling failed: "
            ))
            #expect(channel.notices[1].text.hasSuffix(
                "/telegram status shows the latest error.\n"
            ))
            #expect(await companion.statusText().contains("Polling error: Telegram polling failed: "))

            await companion.shutdown()
        }
    }

    // MARK: - Egress

    @Test
    func originChecksFollowTheLinkAndTheRouteLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9318))
            await terminal.startTelegramControl()
            let companion = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9318),
                channel: ScriptedCompanionChannel(), attachments: TelegramCompanionAttachments()
            )
            try await companion.attach()
            let lease = try #require(companion.activeRouteLease)
            let stale = TerminalTelegramRouteLease(key: lease.key, generation: lease.generation + 1)
            let origins: [(TerminalPromptOrigin, TelegramTurnOrigin)] = [
                (.local, .primary),
                (.telegramLease(lease), .telegram(lease)),
                (.telegramLease(stale), .telegram(stale)),
            ]

            for (terminalOrigin, companionOrigin) in origins {
                #expect(companion.outgoingChatID(for: companionOrigin)
                    == terminal.telegramOutgoingChatID(for: terminalOrigin))
                #expect(await companion.validateOrigin(companionOrigin)
                    == terminal.validateTelegramOrigin(terminalOrigin))
                #expect((companion.wireFence(for: companionOrigin) == nil)
                    == (terminal.telegramWireFence(for: terminalOrigin) == nil))
            }
            #expect(companion.outgoingChatID(for: .telegram(lease)) == 42)
            #expect(await companion.validateOrigin(.telegram(lease)))
            #expect(!(await companion.validateOrigin(.telegram(stale))))
            let fence = try #require(companion.wireFence(for: .telegram(lease)))
            #expect(fence.lease == lease)
            #expect(fence.lifecycleEpoch == companion.controlState.wireLifecycleEpoch)

            await companion.detach()
            #expect(companion.outgoingChatID(for: .telegram(lease)) == nil)
            #expect(!(await companion.validateOrigin(.telegram(lease))))
            #expect(companion.wireFence(for: .telegram(lease)) == nil)
            _ = await terminal.telegramControlService.stop()
        }
    }

    @Test
    func systemMessagesGoThroughTheSeamsBeforeTheService() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9319))
            let transport = CompanionTelegramTransport(botID: 9319)
            let companion = Self.makeCompanion(
                on: terminal, transport: transport,
                channel: ScriptedCompanionChannel(), attachments: TelegramCompanionAttachments()
            )
            try await companion.attach()
            let lease = try #require(companion.activeRouteLease)
            let routed = Recorder<String>()
            let legacy = Recorder<String>()

            companion.onTelegramRoutedSystemMessage = { text, chatID, topicID in
                routed.append("\(text)|\(chatID)|\(topicID.map(String.init) ?? "nil")")
                return true
            }
            companion.onTelegramSystemMessage = { text, chatID in
                legacy.append("\(text)|\(chatID)")
                return true
            }
            #expect(await companion.sendSystemMessage("routed", to: 42, origin: .telegram(lease)))
            companion.onTelegramRoutedSystemMessage = nil
            #expect(await companion.sendSystemMessage("legacy", to: 42, origin: .telegram(lease)))
            companion.onTelegramSystemMessage = nil
            #expect(await companion.sendSystemMessage("wire", to: 42, origin: .telegram(lease)))
            #expect(!(await companion.sendSystemMessage("other chat", to: 43, origin: .telegram(lease))))
            #expect(!(await companion.sendSystemMessage("primary", to: 42, origin: .primary)))
            await companion.sendSystemMessageIfLinked("unlinked", origin: .primary)
            await companion.sendSystemMessageIfLinked("linked", origin: .telegram(lease))

            #expect(routed.values == ["routed|42|nil"])
            #expect(legacy.values == ["legacy|42"])
            #expect(await transport.sentTexts == ["wire", "linked"])

            await companion.shutdown()
        }
    }

    @Test
    func failedSendIsRecordedAndPresentedLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(
                transport: CompanionTelegramTransport(botID: 9320, sendMessageFails: true)
            )
            await terminal.startTelegramControl()
            let terminalLease = try #require(terminal.telegramActiveRouteLease)
            let terminalWrites = await Self.capturing(terminal) {
                _ = await terminal.sendTelegramSystemMessage(
                    "hello", to: 42, origin: .telegramLease(terminalLease)
                )
            }
            let channel = ScriptedCompanionChannel()
            let companion = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9320, sendMessageFails: true),
                channel: channel, attachments: TelegramCompanionAttachments()
            )
            try await companion.attach()
            channel.clear()
            let lease = try #require(companion.activeRouteLease)

            #expect(!(await companion.sendSystemMessage("hello", to: 42, origin: .telegram(lease))))

            #expect(terminalWrites.count == 1)
            #expect(channel.notices == terminalWrites.map { .init(text: $0, channel: .failure) })
            #expect(companion.controlState.lastError != nil)
            #expect(companion.controlState.lastError == terminal.telegramControlState.lastError)

            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    @Test
    func turnMessagesNeedTheLinkAndPreferTheDirectSeam() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9321))
            let transport = CompanionTelegramTransport(botID: 9321)
            let companion = Self.makeCompanion(
                on: terminal, transport: transport,
                channel: ScriptedCompanionChannel(), attachments: TelegramCompanionAttachments()
            )
            let detachedLease = TerminalTelegramRouteLease(key: Self.defaultRouteKey, generation: 1)
            let direct = Recorder<String>()
            companion.onDirectTelegramTurnMessage = { payload, chatID in
                direct.append("\(payload.text)|\(chatID)")
                return true
            }
            #expect(!(await companion.sendTurnMessage(
                .authorization("detached"), to: 42, origin: .telegram(detachedLease)
            )))

            try await companion.attach()
            let lease = try #require(companion.activeRouteLease)
            #expect(await companion.sendTurnMessage(.authorization("direct"), to: 42, origin: .telegram(lease)))
            await companion.sendTurnMessageIfLinked(.authorization("unlinked"), origin: .primary)
            await companion.sendTurnMessageIfLinked(.authorization("linked"), origin: .telegram(lease))
            companion.onDirectTelegramTurnMessage = nil
            #expect(await companion.sendTurnMessage(.authorization("wire"), to: 42, origin: .telegram(lease)))

            #expect(direct.values == ["direct|42", "linked|42"])
            #expect(await transport.sentTexts == ["wire"])

            await companion.shutdown()
        }
    }

    // MARK: - Channel

    @Test
    func companionHoldsItsChannelWeaklyAndTheChannelHasDefaults() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9322))
            let defaults = ScriptedCompanionChannel()
            #expect(!defaults.isSessionGenerating())
            await defaults.overviewMirrorBarrier()
            await defaults.sharedChatPanelDidChange()

            var channel: ScriptedCompanionChannel? = ScriptedCompanionChannel()
            let companion = Self.makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: 9322),
                channel: try #require(channel), attachments: TelegramCompanionAttachments()
            )
            #expect(companion.channel != nil)

            channel = nil
            #expect(companion.channel == nil)
            await companion.detach()
            #expect(!companion.isActive)
        }
    }

    // MARK: - Turn mirror

    /// Root-response deltas wait in the reporter and leave as one message at
    /// the tool boundary, after the channel's overview barrier, as the
    /// terminal publishes them. The companion is driven through the presenter
    /// a turn starting now reads from the controller.
    @Test
    func rootResponseIsPublishedAtTheToolBoundaryAfterTheOverviewBarrier() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let (terminal, terminalLease) = try await Self.linkedTerminal(botID: 9330)
            await terminal.beginTelegramTurnProgressReporting(for: .telegramLease(terminalLease))
            let terminalLog = TurnMessageLog()
            let terminalReporter = await Self.installLog(terminalLog, on: terminal)
            await terminal.appendTelegramRootResponseDelta("Inspecting ")
            await terminal.appendTelegramRootResponseDelta("the reporter")
            await terminal.appendTelegramRootResponseDelta(" first.\n")
            await terminal.publishTelegramRootResponseAtToolBoundary()
            await terminalReporter.flush()

            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9331))
            let channel = TurnCompanionChannel()
            let (companion, lease) = try await Self.linkedCompanion(on: host, botID: 9331, channel: channel)
            let turn = Self.turnPresenter(of: host.chatSession)
            await companion.beginTurn(origin: .telegram(lease))
            let log = TurnMessageLog()
            let reporter = await Self.installLog(log, on: companion)
            // The barrier hands over a section the channel rendered before
            // the tool call.
            channel.onOverviewMirrorBarrier = { [companion] in
                await companion.enqueueOverview(
                    .tasks("📋 Task graph\n\n1 running"), epoch: companion.currentMirrorEpoch
                )
            }

            await turn.presentAssistantContent("Inspecting ")
            await turn.presentAssistantContent("the reporter")
            await turn.presentAssistantContent(" first.\n")
            await reporter.flush()
            #expect(await log.messages.isEmpty)
            #expect(channel.barrierCount == 0)

            await turn.presentToolCallStarted(Self.toolCall)
            await reporter.flush()
            let terminalMessages = await terminalLog.messages
            #expect(terminalMessages == ["Inspecting the reporter first."])
            #expect(channel.barrierCount == 1)
            #expect(await log.messages == ["📋 Task graph\n\n1 running"] + terminalMessages)

            // A boundary with nothing pending publishes nothing and does not
            // wait for the barrier.
            await turn.presentToolCallStarted(Self.toolCall)
            await reporter.flush()
            #expect(channel.barrierCount == 1)
            #expect(await log.messages.count == 2)

            // The final response waits for the barrier too.
            await turn.presentAssistantContent("Finished.")
            await companion.finishTurn(outcome: .completed("Inspecting the reporter first.\nFinished."))
            #expect(channel.barrierCount == 2)
            #expect(await log.messages == [
                "📋 Task graph\n\n1 running",
                "Inspecting the reporter first.",
                "📋 Task graph\n\n1 running",
                "*ZenCODE completed*\n\nFinished.",
            ])

            await companion.shutdown()
            await terminal.endTelegramTurnProgressReporting()
            _ = await terminal.telegramControlService.stop()
        }
    }

    /// After an intermediate response was mirrored, the final response is the
    /// text since the last tool boundary, not the turn's accumulated text,
    /// exactly as the terminal finishes the turn.
    @Test
    func finalResponseIsNotMirroredAgainAfterAnIntermediatePublication() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let accumulated = "Inspecting the manifest.All done, everything works."
            let (terminal, terminalLease) = try await Self.linkedTerminal(botID: 9332)
            await terminal.beginTelegramTurnProgressReporting(for: .telegramLease(terminalLease))
            let terminalLog = TurnMessageLog()
            await Self.installLog(terminalLog, on: terminal)
            await terminal.appendTelegramRootResponseDelta("Inspecting the manifest.")
            await terminal.publishTelegramRootResponseAtToolBoundary()
            await terminal.appendTelegramRootResponseDelta("All done, ")
            await terminal.appendTelegramRootResponseDelta("everything works.")
            await terminal.finishPromptResult(Self.terminalResult(
                for: .completed(accumulated), summary: Self.oneFileSummary,
                origin: .telegramLease(terminalLease)
            ))
            await terminal.stopTaskGraphObserver()

            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9333))
            let channel = TurnCompanionChannel()
            let (companion, _) = try await Self.linkedCompanion(on: host, botID: 9333, channel: channel)
            let turn = Self.turnPresenter(of: host.chatSession)
            await companion.beginTurn(origin: .primary)
            let log = TurnMessageLog()
            await Self.installLog(log, on: companion)
            await turn.presentAssistantContent("Inspecting the manifest.")
            await turn.presentToolCallStarted(Self.toolCall)
            await turn.presentAssistantContent("All done, ")
            await turn.presentAssistantContent("everything works.")
            await companion.finishTurn(
                outcome: .completed(accumulated), fileChangeSummary: Self.oneFileSummary
            )

            let messages = await log.messages
            #expect(messages == (await terminalLog.messages))
            #expect(messages == [
                "Inspecting the manifest.",
                "*ZenCODE completed*\n\nAll done, everything works.",
                Self.summaryText(Self.oneFileSummary),
            ])
            #expect(companion.activeProgressReporter == nil)
            #expect(companion.activeTurnOrigin == nil)
            #expect(companion.routeValidationTask == nil)
            #expect(companion.activePresenceLease == nil)

            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    /// Completed, empty, long, failed, and stopped turns, with and without a
    /// summary, are mirrored with the texts the terminal mirrors when it
    /// finishes the same turn.
    @Test
    func turnOutcomesAreMirroredWithTheTerminalTexts() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let (terminal, terminalLease) = try await Self.linkedTerminal(botID: 9334)
            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9335))
            let channel = TurnCompanionChannel()
            let (companion, _) = try await Self.linkedCompanion(on: host, botID: 9335, channel: channel)
            let cases: [(TelegramSessionCompanion.Outcome, TurnFileChangeSummary?)] = [
                (.completed("All done."), nil),
                (.completed("  \n"), nil),
                (.completed(String(repeating: "a", count: 4_000)), nil),
                (.completed("Changed two files."), Self.twoFileSummary),
                (.failed("The model is unavailable."), Self.oneFileSummary),
                (.cancelled, Self.twoFileSummary),
            ]
            var results: [[String]] = []
            for (outcome, summary) in cases {
                await terminal.beginTelegramTurnProgressReporting(for: .telegramLease(terminalLease))
                let terminalLog = TurnMessageLog()
                await Self.installLog(terminalLog, on: terminal)
                await terminal.finishPromptResult(Self.terminalResult(
                    for: outcome, summary: summary, origin: .telegramLease(terminalLease)
                ))

                await companion.beginTurn(origin: .primary)
                let log = TurnMessageLog()
                await Self.installLog(log, on: companion)
                await companion.finishTurn(outcome: outcome, fileChangeSummary: summary)

                let messages = await log.messages
                #expect(messages == (await terminalLog.messages), "\(outcome)")
                results.append(messages)
            }
            await terminal.stopTaskGraphObserver()

            #expect(results == [
                ["*ZenCODE completed*\n\nAll done."],
                ["*ZenCODE completed*\n\nDone."],
                ["*ZenCODE completed*\n\n" + String(repeating: "a", count: 3_600)],
                ["*ZenCODE completed*\n\nChanged two files.", Self.summaryText(Self.twoFileSummary)],
                ["ZenCODE failed: The model is unavailable.", Self.summaryText(Self.oneFileSummary)],
                ["Stopped.", Self.summaryText(Self.twoFileSummary)],
            ])

            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    /// Without a reporter the outcome and the summary go to the linked chat
    /// directly; without an outcome only the summary goes, as the terminal
    /// does when its loop is torn down during a turn.
    @Test
    func outcomeAndSummaryReachTheChatDirectlyWithoutAReporter() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let (terminal, terminalLease) = try await Self.linkedTerminal(botID: 9336)
            let terminalDirect = Recorder<String>()
            terminal.onDirectTelegramTurnMessage = { payload, chatID in
                terminalDirect.append("\(payload.text)|\(chatID)")
                return true
            }
            for outcome in [TerminalTelegramTurnPayload.agentResponse("*ZenCODE completed*\n\nDone."), nil] {
                await terminal.beginTelegramTurnProgressReporting(for: .telegramLease(terminalLease))
                await terminal.activeTelegramProgressReporter?.revokeAndWait()
                terminal.activeTelegramProgressReporter = nil
                await terminal.finalizeTelegramTurnProgressReporting(
                    outcome: outcome, fileChangeSummary: Self.oneFileSummary
                )
            }

            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9337))
            let channel = TurnCompanionChannel()
            let (companion, _) = try await Self.linkedCompanion(on: host, botID: 9337, channel: channel)
            let direct = Recorder<String>()
            companion.onDirectTelegramTurnMessage = { payload, chatID in
                direct.append("\(payload.text)|\(chatID)")
                return true
            }
            for outcome in [TelegramSessionCompanion.Outcome.completed("Done."), nil] {
                await companion.beginTurn(origin: .primary)
                await companion.activeProgressReporter?.revokeAndWait()
                companion.activeProgressReporter = nil
                await companion.finishTurn(outcome: outcome, fileChangeSummary: Self.oneFileSummary)
            }

            let summary = Self.summaryText(Self.oneFileSummary)
            #expect(direct.values == terminalDirect.values)
            #expect(direct.values == [
                "*ZenCODE completed*\n\nDone.|42", "\(summary)|42", "\(summary)|42",
            ])
            #expect(companion.activeTurnOrigin == nil)

            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    /// A response block that streams across `/telegram off` and
    /// `/telegram on` is suppressed: the chat never receives a fragment
    /// whose beginning it did not see. The next block is mirrored again.
    @Test
    func streamingResponseIsSuppressedAcrossDetachAndAttachLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let (terminal, terminalLease) = try await Self.linkedTerminal(botID: 9338)
            await terminal.beginTelegramTurnProgressReporting(for: .telegramLease(terminalLease))
            let terminalFirst = TurnMessageLog()
            await Self.installLog(terminalFirst, on: terminal)
            await terminal.appendTelegramRootResponseDelta("Visible beginning ")
            await terminal.stopTelegramControl()
            await terminal.appendTelegramRootResponseDelta("hidden middle ")
            await terminal.startTelegramControl()
            let terminalSecond = TurnMessageLog()
            let terminalReporter = await Self.installLog(terminalSecond, on: terminal)
            await terminal.appendTelegramRootResponseDelta("and the tail.")
            await terminal.publishTelegramRootResponseAtToolBoundary()
            await terminal.appendTelegramRootResponseDelta("Next response.")
            await terminal.publishTelegramRootResponseAtToolBoundary()
            await terminalReporter.flush()

            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9339))
            let channel = TurnCompanionChannel()
            let (companion, lease) = try await Self.linkedCompanion(on: host, botID: 9339, channel: channel)
            let turn = Self.turnPresenter(of: host.chatSession)
            await companion.beginTurn(origin: .primary)
            #expect(companion.activeTurnOrigin == .telegram(lease))
            let first = TurnMessageLog()
            await Self.installLog(first, on: companion)
            await turn.presentAssistantContent("Visible beginning ")
            await companion.detach()
            #expect(companion.activeProgressReporter == nil)
            #expect(companion.activeTurnOrigin == .telegram(lease))
            await turn.presentAssistantContent("hidden middle ")
            try await companion.attach()
            #expect(companion.activeProgressReporter != nil)
            #expect(companion.rootResponseBlockIsSuppressed)
            let second = TurnMessageLog()
            let reporter = await Self.installLog(second, on: companion)
            await turn.presentAssistantContent("and the tail.")
            await turn.presentToolCallStarted(Self.toolCall)
            await turn.presentAssistantContent("Next response.")
            await turn.presentToolCallStarted(Self.toolCall)
            await reporter.flush()

            #expect(await first.messages == (await terminalFirst.messages))
            #expect(await second.messages == (await terminalSecond.messages))
            #expect(await first.messages.isEmpty)
            #expect(await second.messages == ["Next response."])

            await companion.shutdown()
            await terminal.endTelegramTurnProgressReporting()
            _ = await terminal.telegramControlService.stop()
        }
    }

    /// A turn of the primary channel that starts while Telegram is detached
    /// is mirrored from the tool boundary after `/telegram on`, as the
    /// terminal mirrors it: the presenter is in the turn's fan-out from the
    /// start, because the companion registers it when it is created.
    @Test
    func attachInTheMiddleOfATurnMirrorsFromTheNextToolBoundaryLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let accumulated = "Before the link is up.After the boundary.Done here."
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9340))
            await terminal.beginTelegramTurnProgressReporting(for: .local)
            await terminal.appendTelegramRootResponseDelta("Before the link ")
            await terminal.startTelegramControl()
            let terminalLog = TurnMessageLog()
            await Self.installLog(terminalLog, on: terminal)
            await terminal.appendTelegramRootResponseDelta("is up.")
            await terminal.publishTelegramRootResponseAtToolBoundary()
            await terminal.appendTelegramRootResponseDelta("After the boundary.")
            await terminal.publishTelegramRootResponseAtToolBoundary()
            await terminal.appendTelegramRootResponseDelta("Done here.")
            await terminal.finishPromptResult(Self.terminalResult(
                for: .completed(accumulated), summary: nil, origin: .local
            ))
            await terminal.stopTaskGraphObserver()

            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9341))
            let channel = TurnCompanionChannel()
            let companion = Self.makeCompanion(
                on: host, transport: CompanionTelegramTransport(botID: 9341),
                channel: channel, attachments: TelegramCompanionAttachments()
            )
            let turn = Self.turnPresenter(of: host.chatSession)
            #expect(turn.companions.contains { $0 === companion.presenter })
            await companion.beginTurn(origin: .primary)
            #expect(companion.activeTurnOrigin == .primary)
            #expect(companion.activeProgressReporter == nil)
            await turn.presentAssistantContent("Before the link ")
            try await companion.attach()
            let lease = try #require(companion.activeRouteLease)
            #expect(companion.activeTurnOrigin == .telegram(lease))
            #expect(companion.activeProgressReporter != nil)
            let log = TurnMessageLog()
            await Self.installLog(log, on: companion)
            await turn.presentAssistantContent("is up.")
            await turn.presentToolCallStarted(Self.toolCall)
            await turn.presentAssistantContent("After the boundary.")
            await turn.presentToolCallStarted(Self.toolCall)
            await turn.presentAssistantContent("Done here.")
            await companion.finishTurn(outcome: .completed(accumulated))

            let messages = await log.messages
            #expect(messages == (await terminalLog.messages))
            #expect(messages == ["After the boundary.", "*ZenCODE completed*\n\nDone here."])

            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    // MARK: - Overviews

    /// Overview sections are fenced by the turn's mirror epoch, which the
    /// terminal's render coordinator gives `beginTurn`, and repeated task
    /// graphs are dropped within a turn, as the terminal's mirror hook does.
    @Test
    func overviewsAreFencedByTheTurnEpochAndDeduplicatedLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let (terminal, terminalLease) = try await Self.linkedTerminal(botID: 9342)
            await terminal.beginTelegramTurnProgressReporting(for: .telegramLease(terminalLease))
            let epoch = terminal.currentTelegramMirrorEpoch
            let terminalLog = TurnMessageLog()
            let terminalReporter = await Self.installLog(terminalLog, on: terminal)
            let notifications: [(TerminalChatRenderCoordinator.OverviewMirrorNotification, Int)] = [
                (.taskGraph(signature: "graph-1", markdown: "1 running"), epoch),
                (.taskGraph(signature: "graph-1", markdown: "1 running"), epoch),
                (.taskGraph(signature: "graph-2", markdown: "2 running"), epoch - 1),
                (.taskGraph(signature: "graph-3", markdown: "1 done"), epoch),
            ]
            for (notification, notificationEpoch) in notifications {
                await terminal.mirrorRenderedOverviewToTelegram(
                    notification: notification, epoch: notificationEpoch
                )
            }
            await terminalReporter.flush()

            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9343))
            let channel = TurnCompanionChannel()
            let (companion, _) = try await Self.linkedCompanion(on: host, botID: 9343, channel: channel)
            await companion.beginTurn(origin: .primary, mirrorEpoch: epoch)
            #expect(companion.currentMirrorEpoch == epoch)
            let log = TurnMessageLog()
            let reporter = await Self.installLog(log, on: companion)
            for (notification, notificationEpoch) in notifications {
                guard case let .taskGraph(signature, markdown) = notification else { continue }
                await companion.enqueueOverview(
                    .tasks("📋 Task graph\n\n\(markdown)"),
                    epoch: notificationEpoch, taskGraphSignature: signature
                )
            }
            // A sub-agent response arrives as the terminal builds it.
            let subAgent = try #require(TerminalChat.telegramSubAgentResponsePayload(
                heading: "🤖 worker", markdown: "Delegated answer."
            ))
            await companion.enqueueOverview(subAgent, epoch: epoch)
            await reporter.flush()
            let messages = await log.messages
            #expect(Array(messages.dropLast()) == (await terminalLog.messages))
            #expect(messages == [
                "📋 Task graph\n\n1 running", "📋 Task graph\n\n1 done", "🤖 worker\n\nDelegated answer.",
            ])

            // The next turn starts a new dedup and fences the previous epoch.
            await companion.beginTurn(origin: .primary, mirrorEpoch: epoch + 1)
            let next = TurnMessageLog()
            let nextReporter = await Self.installLog(next, on: companion)
            await companion.enqueueOverview(
                .tasks("📋 Task graph\n\n1 running"), epoch: epoch, taskGraphSignature: "graph-1"
            )
            await companion.enqueueOverview(
                .tasks("📋 Task graph\n\n1 running"), epoch: epoch + 1, taskGraphSignature: "graph-1"
            )
            await nextReporter.flush()
            #expect(await next.messages == ["📋 Task graph\n\n1 running"])

            // Without an epoch from the channel the companion advances its own.
            await companion.beginTurn(origin: .primary)
            #expect(companion.currentMirrorEpoch == epoch + 2)

            // Outside a mirrored turn a section has no audience and leaves no
            // trace in the dedup.
            await companion.finishTurn()
            await companion.enqueueOverview(
                .tasks("📋 Task graph\n\nlate"),
                epoch: companion.currentMirrorEpoch, taskGraphSignature: "graph-9"
            )
            #expect(companion.mirroredTaskGraphOverviewSignature != "graph-9")

            await companion.shutdown()
            await terminal.endTelegramTurnProgressReporting()
            _ = await terminal.telegramControlService.stop()
        }
    }

    // MARK: - Route validation

    /// A turn on a route lease is reported to the channel as soon as the
    /// route is revoked; the channel may end the turn's reporting from within
    /// the call, and the companion then forgets the turn and the route.
    @Test(.timeLimit(.minutes(1)))
    func revokedRouteIsReportedToTheChannelWhichEndsTheTurn() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9344))
            let channel = TurnCompanionChannel()
            let (companion, lease) = try await Self.linkedCompanion(on: host, botID: 9344, channel: channel)
            channel.onRouteInvalidated = { [companion] invalidated in
                // The channel stops the turn, then hands the rest back.
                await companion.routeWasInvalidated(invalidated)
            }

            // A turn that finishes stops its validation.
            await companion.beginTurn(origin: .primary)
            #expect(companion.routeValidationTask != nil)
            await companion.finishTurn()
            #expect(companion.routeValidationTask == nil)

            await companion.beginTurn(origin: .primary)
            #expect(companion.activeTurnOrigin == .telegram(lease))
            #expect(companion.routeValidationTask != nil)
            await companion.router.refresh(
                linkedChatID: 42, ownerUserID: 7,
                routes: [AgentTelegramRouteManifest(roomID: "default", generation: lease.generation + 1)]
            )
            #expect(await channel.nextInvalidatedLease() == lease)
            #expect(channel.invalidatedLeases == [lease])
            #expect(companion.routeValidationTask == nil)
            #expect(companion.activeTurnOrigin == nil)
            #expect(companion.activeProgressReporter == nil)
            #expect(companion.activePresenceLease == nil)
            #expect(companion.activeRouteLease == nil)

            // A turn of the primary channel without a route has nothing to
            // validate.
            await companion.detach()
            await companion.beginTurn(origin: .primary)
            #expect(companion.activeTurnOrigin == .primary)
            #expect(companion.routeValidationTask == nil)

            await companion.shutdown()
        }
    }

    // MARK: - Presenter

    /// The presenter is registered once, when the companion is created; it
    /// stays across `/telegram off`, holds the companion weakly so that a
    /// released companion is deallocated, and leaves at shutdown.
    @Test
    func presenterIsRegisteredOnceAndHoldsTheCompanionWeakly() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9345))
            let controller = host.chatSession
            let channel = TurnCompanionChannel()
            var companion: TelegramSessionCompanion? = Self.makeCompanion(
                on: host, transport: CompanionTelegramTransport(botID: 9345),
                channel: channel, attachments: TelegramCompanionAttachments()
            )
            weak let released = companion
            let presenter = try #require(companion?.presenter)
            let service = try #require(companion?.controlService)
            #expect(presenter.companion === companion)
            #expect(controller.companionPresenters.count(where: { $0 === presenter }) == 1)

            try await companion?.attach()
            await companion?.beginTurn(origin: .primary)
            #expect(companion?.activeProgressReporter != nil)
            #expect(companion?.routeValidationTask != nil)
            await companion?.detach()
            #expect(controller.companionPresenters.count(where: { $0 === presenter }) == 1)

            companion = nil
            #expect(released == nil)
            #expect(presenter.companion == nil)
            // A presenter whose companion is gone does nothing.
            await presenter.presentAssistantContent("ignored")
            await presenter.presentToolCallStarted(Self.toolCall)
            _ = await service.stop()

            let other = Self.makeCompanion(
                on: host, transport: CompanionTelegramTransport(botID: 9345),
                channel: channel, attachments: TelegramCompanionAttachments()
            )
            #expect(controller.companionPresenters.contains { $0 === other.presenter })
            await other.shutdown()
            #expect(!controller.companionPresenters.contains { $0 === other.presenter })
        }
    }

    /// While a remote command runs, the presenter collects the text of the
    /// session and workflow notices it receives, in order; outside a capture
    /// it collects nothing.
    @Test
    func noticeCaptureCollectsTheNoticesOfARemoteCommand() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9346))
            let channel = TurnCompanionChannel()
            let companion = Self.makeCompanion(
                on: host, transport: CompanionTelegramTransport(botID: 9346),
                channel: channel, attachments: TelegramCompanionAttachments()
            )
            let fanOut = Self.turnPresenter(of: host.chatSession)
            let blocked = ChatWorkflowNotice.blocked(graphID: "graph-1", message: "Waiting for review.")

            await fanOut.presentSessionNotice(.workflowMissingGoal)
            companion.presenter.beginNoticeCapture()
            await fanOut.presentSessionNotice(.workflowMissingGoal)
            await fanOut.presentWorkflowNotice(blocked)
            #expect(companion.presenter.endNoticeCapture() == [
                ChatSessionNoticeText.text(for: ChatSessionNotice.workflowMissingGoal),
                ChatSessionNoticeText.text(for: blocked),
            ])
            await fanOut.presentSessionNotice(.workflowMissingGoal)
            #expect(companion.presenter.endNoticeCapture().isEmpty)

            await companion.shutdown()
        }
    }

    /// `ChatSessionNoticeText.text(for:)` words every workflow notice as the
    /// terminal's presenter writes it.
    @Test
    func workflowNoticeTextsMatchTheTerminalPresenter() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9347))
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
                let terminalWrites = await Self.capturing(terminal) {
                    await presenter.presentWorkflowNotice(notice)
                }
                #expect(terminalWrites == [ChatSessionNoticeText.text(for: notice)], "\(notice)")
            }
            #expect(
                ChatSessionNoticeText.text(for: .blocked(graphID: "graph-1", message: "Waiting for review."))
                    == "Workflow \"graph-1\" is blocked: Waiting for review.\n"
                    + "Your next message resumes this same workflow; use /tasks clear to stop it.\n"
            )
            #expect(
                ChatSessionNoticeText.text(for: .awaitingReply(graphID: "graph-1", pendingTaskCount: 1))
                    == "Workflow \"graph-1\" asked a question and is still open (1 task open). "
                    + "Your next message answers it on the same task graph; "
                    + "use /tasks to review or /tasks clear to stop it.\n"
            )
        }
    }

    /// Under `.mirrorOnly` the streamed drafts carry no stop button; under
    /// `.full` they keep it.
    @Test(.timeLimit(.minutes(1)))
    func mirrorOnlyDraftsHaveNoStopButton() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            var canStops: [Bool] = []
            for policy in [TelegramSessionCompanion.Policy.full, .mirrorOnly] {
                let transport = CompanionTelegramTransport(botID: 9348)
                let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9348))
                let channel = TurnCompanionChannel()
                let (companion, _) = try await Self.linkedCompanion(
                    on: host, botID: 9348, channel: channel,
                    configuration: .init(primaryChannelDescription: "TUI", policy: policy),
                    transport: transport
                )
                await companion.beginTurn(origin: .primary)
                await companion.appendRootResponseDelta("Streaming the answer")
                canStops.append(await transport.firstDraftCanStop())
                await companion.shutdown()
            }
            #expect(canStops == [true, false])
        }
    }

    // MARK: - Consent

    /// The handler exists while the turn reaches the linked chat: a turn of
    /// the primary channel is routed onto the link's lease first, as the
    /// terminal routes a local prompt before it asks for its handler.
    @Test
    func consentHandlerFollowsTheLinkLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let (terminal, terminalLease) = try await Self.linkedTerminal(botID: 9350)
            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9351))
            let channel = TurnCompanionChannel()
            let (companion, lease) = try await Self.linkedCompanion(on: host, botID: 9351, channel: channel)

            let terminalOrigin = terminal.promptAttempt(prompt: "hello").origin
            #expect(terminalOrigin == .telegramLease(terminalLease))
            #expect(companion.routedOrigin(for: .primary) == .telegram(lease))
            #expect(terminal.telegramToolAuthorizationHandler(for: terminalOrigin) != nil)
            #expect(companion.toolAuthorizationHandler(for: .primary) != nil)
            #expect(companion.toolAuthorizationHandler(for: .telegram(lease)) != nil)

            await terminal.stopTelegramControl()
            await companion.detach()
            let detachedOrigin = terminal.promptAttempt(prompt: "hello").origin
            #expect(detachedOrigin == .local)
            #expect(companion.routedOrigin(for: .primary) == .primary)
            #expect(terminal.telegramToolAuthorizationHandler(for: detachedOrigin) == nil)
            #expect(companion.toolAuthorizationHandler(for: .primary) == nil)
            #expect(companion.toolAuthorizationHandler(for: .telegram(lease)) == nil)

            await companion.shutdown()
        }
    }

    /// Tools outside the gated set run without asking; a gated call of a
    /// turn that cannot reach the linked chat is denied with the terminal's
    /// text.
    @Test
    func ungatedToolsRunAndAnUnlinkedTurnIsDeniedLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let (terminal, _) = try await Self.linkedTerminal(botID: 9352)
            let terminalWrites = await Self.capturing(terminal) {
                #expect(await terminal.authorizeTelegramToolRequest(Self.readRequest, origin: .local))
                #expect(!(await terminal.authorizeTelegramToolRequest(Self.deleteRequest(), origin: .local)))
            }

            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9353))
            let channel = TurnCompanionChannel()
            let (companion, _) = try await Self.linkedCompanion(on: host, botID: 9353, channel: channel)
            #expect(await companion.authorizeToolRequest(Self.readRequest, origin: .primary))
            #expect(channel.notices.isEmpty)
            #expect(!(await companion.authorizeToolRequest(Self.deleteRequest(), origin: .primary)))

            #expect(terminalWrites == [
                "ZenCODE: Telegram cannot request permission for local.delete; the operation was denied.\n",
            ])
            #expect(channel.notices == terminalWrites.map { .init(text: $0, channel: .failure) })

            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    /// The primary channel and the linked chat are asked at once; a decision
    /// in the primary channel wins, cancels the Telegram request, and is
    /// told to the chat, with the terminal's texts and order.
    @Test(.timeLimit(.minutes(1)), arguments: zip(["r", "c"], [true, false]))
    func primaryDecisionWinsTheConsentRaceLikeTheTerminal(key: String, approves: Bool) async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let request = Self.deleteRequest()
            let terminalKeys = ConsentKeys()
            let terminalAuthorizer = LocalExecPermissionAuthorizer()
            await terminalAuthorizer.setConsentReader(terminalKeys.reader)
            let (terminal, terminalLease) = try await Self.linkedTerminal(
                botID: 9354, permissionAuthorizer: terminalAuthorizer
            )
            let terminalLog = TurnMessageLog()
            await Self.installLog(terminalLog, on: terminal)
            var terminalApproved: Bool?
            let terminalWrites = await Self.capturing(terminal) {
                let authorization = Task {
                    await terminal.authorizeTelegramToolRequest(request, origin: .telegramLease(terminalLease))
                }
                _ = await terminalLog.waitForMessages(count: 1)
                await terminalKeys.answer(key)
                terminalApproved = await authorization.value
            }
            let terminalMessages = await terminalLog.waitForMessages(count: 2)

            let keys = ConsentKeys()
            let authorizer = LocalExecPermissionAuthorizer()
            await authorizer.setConsentReader(keys.reader)
            let host = try Self.makeTerminal(
                transport: CompanionTelegramTransport(botID: 9355), permissionAuthorizer: authorizer
            )
            let channel = TurnCompanionChannel()
            let (companion, _) = try await Self.linkedCompanion(on: host, botID: 9355, channel: channel)
            let log = TurnMessageLog()
            await Self.installLog(log, on: companion)
            let handler = try #require(companion.toolAuthorizationHandler(for: .primary))
            let authorization = Task { await handler(request) }
            _ = await log.waitForMessages(count: 1)
            await keys.answer(key)
            let approved = await authorization.value
            let messages = await log.waitForMessages(count: 2)

            #expect(approved == approves)
            #expect(terminalApproved == approves)
            #expect(channel.noticeTexts == terminalWrites)
            #expect(channel.notices.map(\.channel) == [.system])
            #expect(terminalWrites == [
                "\nPermission required: Delete Sources/Old.swift\n"
                    + "Approve or deny in the terminal, or use /allow, /always or /deny in the linked chat.\n",
            ])
            #expect(messages.count == 2)
            #expect(messages[1] == terminalMessages[1])
            #expect(messages[1] == (approves
                ? "✅ Permission granted in the terminal for local.delete. Continuing."
                : "⛔ Permission denied in the terminal for local.delete."))
            for message in [messages[0], terminalMessages[0]] {
                let requestID = try #require(Self.permissionRequestID(in: message))
                #expect(message == TerminalTelegramPermissionBroker.permissionRequestMessage(
                    requestID: requestID, request: request
                ))
            }

            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    /// A reply in the linked chat wins while the primary channel's dialog is
    /// still open: the dialog is cancelled, the reply decides, and the
    /// primary channel is told, with the terminal's texts and order.
    @Test(.timeLimit(.minutes(1)), arguments: zip(["/allow", "/deny"], [true, false]))
    func telegramDecisionWinsTheConsentRaceLikeTheTerminal(command: String, approves: Bool) async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let request = Self.deleteRequest()
            let terminalAuthorizer = LocalExecPermissionAuthorizer()
            await terminalAuthorizer.setConsentReader(ConsentKeys().reader)
            let (terminal, terminalLease) = try await Self.linkedTerminal(
                botID: 9356, permissionAuthorizer: terminalAuthorizer
            )
            let terminalLog = TurnMessageLog()
            await Self.installLog(terminalLog, on: terminal)
            var terminalApproved: Bool?
            var terminalRequestID = ""
            let terminalWrites = await Self.capturing(terminal) {
                let authorization = Task {
                    await terminal.authorizeTelegramToolRequest(request, origin: .telegramLease(terminalLease))
                }
                let requestMessage = (await terminalLog.waitForMessages(count: 1))[0]
                terminalRequestID = Self.permissionRequestID(in: requestMessage) ?? ""
                _ = await terminal.handleTelegramPermissionResponseIfNeeded(
                    "\(command) \(terminalRequestID)", lease: terminalLease
                )
                terminalApproved = await authorization.value
            }
            let terminalMessages = await terminalLog.waitForMessages(count: 2)

            let authorizer = LocalExecPermissionAuthorizer()
            await authorizer.setConsentReader(ConsentKeys().reader)
            let host = try Self.makeTerminal(
                transport: CompanionTelegramTransport(botID: 9357), permissionAuthorizer: authorizer
            )
            let channel = TurnCompanionChannel()
            let (companion, lease) = try await Self.linkedCompanion(on: host, botID: 9357, channel: channel)
            let log = TurnMessageLog()
            await Self.installLog(log, on: companion)
            let handler = try #require(companion.toolAuthorizationHandler(for: .primary))
            let authorization = Task { await handler(request) }
            let requestMessage = (await log.waitForMessages(count: 1))[0]
            let requestID = try #require(Self.permissionRequestID(in: requestMessage))
            #expect(await companion.handlePermissionResponseIfNeeded("\(command) \(requestID)", lease: lease))
            let approved = await authorization.value
            let messages = await log.waitForMessages(count: 2)

            #expect(approved == approves)
            #expect(terminalApproved == approves)
            #expect(channel.noticeTexts == terminalWrites)
            #expect(channel.notices.map(\.channel) == [.system, .system])
            #expect(terminalWrites.last == (approves
                ? "Telegram approved local.delete.\n"
                : "Telegram denied local.delete.\n"))
            #expect(messages.count == 2)
            #expect(
                messages[1].replacingOccurrences(of: requestID, with: "ID")
                    == terminalMessages[1].replacingOccurrences(of: terminalRequestID, with: "ID")
            )

            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    /// When neither channel can decide (the primary channel has no operator
    /// and the request never reaches the chat), the call is denied with the
    /// terminal's texts and order.
    @Test(.timeLimit(.minutes(1)))
    func consentIsDeniedWhenNeitherChannelCanDecideLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let request = Self.deleteRequest()
            let terminalKeys = ConsentKeys()
            await terminalKeys.answer(nil)
            let terminalAuthorizer = LocalExecPermissionAuthorizer()
            await terminalAuthorizer.setConsentReader(terminalKeys.reader)
            let (terminal, terminalLease) = try await Self.linkedTerminal(
                botID: 9358, permissionAuthorizer: terminalAuthorizer
            )
            await Self.installLog(TurnMessageLog(), on: terminal, delivers: false)
            var terminalApproved: Bool?
            let terminalWrites = await Self.capturing(terminal) {
                terminalApproved = await terminal.authorizeTelegramToolRequest(
                    request, origin: .telegramLease(terminalLease)
                )
            }

            let keys = ConsentKeys()
            await keys.answer(nil)
            let authorizer = LocalExecPermissionAuthorizer()
            await authorizer.setConsentReader(keys.reader)
            let host = try Self.makeTerminal(
                transport: CompanionTelegramTransport(botID: 9359), permissionAuthorizer: authorizer
            )
            let channel = TurnCompanionChannel()
            let (companion, _) = try await Self.linkedCompanion(on: host, botID: 9359, channel: channel)
            await Self.installLog(TurnMessageLog(), on: companion, delivers: false)
            let approved = await companion.authorizeToolRequest(
                request, origin: companion.routedOrigin(for: .primary)
            )

            #expect(!approved)
            #expect(terminalApproved == false)
            #expect(channel.noticeTexts == terminalWrites)
            #expect(channel.notices.map(\.channel) == [.system, .failure])
            #expect(terminalWrites.last
                == "ZenCODE: no authorization channel could resolve local.delete; the operation was denied.\n")

            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    /// An "always" decision in the primary channel is remembered by the
    /// controller's authorizer, a `/always` in the linked chat by the
    /// permission broker for its route; the controller does not import the
    /// latter, as the terminal does not. A remembered request is not asked
    /// again.
    @Test(.timeLimit(.minutes(1)))
    func alwaysDecisionsAreRememberedWhereTheTerminalRemembersThem() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let keys = ConsentKeys()
            let authorizer = LocalExecPermissionAuthorizer()
            await authorizer.setConsentReader(keys.reader)
            let host = try Self.makeTerminal(
                transport: CompanionTelegramTransport(botID: 9360), permissionAuthorizer: authorizer
            )
            let channel = TurnCompanionChannel()
            let (companion, lease) = try await Self.linkedCompanion(on: host, botID: 9360, channel: channel)
            let log = TurnMessageLog()
            await Self.installLog(log, on: companion)
            let handler = try #require(companion.toolAuthorizationHandler(for: .primary))

            let primaryRequest = Self.deleteRequest("Sources/Primary.swift")
            let first = Task { await handler(primaryRequest) }
            _ = await log.waitForMessages(count: 1)
            await keys.answer("a")
            #expect(await first.value)
            _ = await log.waitForMessages(count: 2)
            #expect(await companion.controller.authorizer.isAlreadyAuthorized(primaryRequest))
            #expect(await handler(primaryRequest))
            #expect(channel.notices.count == 1)
            #expect(await log.messages.count == 2)
            #expect(await keys.readCount == 1)

            let telegramRequest = Self.deleteRequest("Sources/Telegram.swift")
            let second = Task { await handler(telegramRequest) }
            let requestMessage = (await log.waitForMessages(count: 3))[2]
            let requestID = try #require(Self.permissionRequestID(in: requestMessage))
            #expect(await companion.handlePermissionResponseIfNeeded("/always \(requestID)", lease: lease))
            #expect(await second.value)
            #expect(await companion.permissionBroker.isAlreadyAuthorized(telegramRequest, lease: lease))
            #expect(!(await companion.controller.authorizer.isAlreadyAuthorized(telegramRequest)))
            let noticeCount = channel.notices.count
            let messageCount = await log.messages.count
            #expect(await handler(telegramRequest))
            #expect(channel.notices.count == noticeCount)
            #expect(await log.messages.count == messageCount)

            await companion.shutdown()
        }
    }

    /// A permission reply without a pending request is answered on the
    /// turn's channel and not run as a prompt; other text is left alone, and
    /// a reply on a revoked route is consumed silently, as in the terminal.
    @Test
    func permissionRepliesAreAnsweredLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let (terminal, terminalLease) = try await Self.linkedTerminal(botID: 9361)
            let terminalLog = TurnMessageLog()
            await Self.installLog(terminalLog, on: terminal)
            var terminalResults: [Bool] = []
            for text in ["/allow", "hello"] {
                terminalResults.append(
                    await terminal.handleTelegramPermissionResponseIfNeeded(text, lease: terminalLease)
                )
            }

            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9362))
            let channel = TurnCompanionChannel()
            let (companion, lease) = try await Self.linkedCompanion(on: host, botID: 9362, channel: channel)
            let log = TurnMessageLog()
            await Self.installLog(log, on: companion)
            var results: [Bool] = []
            for text in ["/allow", "hello"] {
                results.append(await companion.handlePermissionResponseIfNeeded(text, lease: lease))
            }

            #expect(results == terminalResults)
            #expect(results == [true, false])
            #expect(await log.messages == (await terminalLog.messages))
            #expect(await log.messages.count == 1)
            let stale = TerminalTelegramRouteLease(key: lease.key, generation: lease.generation + 1)
            #expect(await companion.handlePermissionResponseIfNeeded("/allow", lease: stale))
            #expect(await log.messages.count == 1)

            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    // MARK: - Mention parser

    /// The terminal's parser, catalogue handles and sanitizer are the Chat
    /// ones: on the same inputs, the sanitizer's edge cases included, the
    /// terminal's forwarders answer what ``SharedChatMentionParser``
    /// answers, and the answers are the terminal's.
    @Test
    func mentionParserMatchesTheTerminalForwarders() {
        let handles = ["planner": "agent-1", "all-2": "agent-all"]
        let legacy = "@" + SharedChatMentionParser.mentionHandle(forParticipantID: "agent-7")
        let controls = "a\u{1B}[31mb\tc\u{7F}d\u{9B}e\u{2028}f\u{2029}g\u{202E}h\u{200B}i\nj\r"
        let inputs = [
            "@coordinator report status", "@COORDINATOR report", "@all  report status",
            "@coordinator", "@coordinator   ", "@planner do it", "@planner", "@all-2 hi",
            "@nobody hi", "plain prompt", "@", "@ hi", "  @planner  spaced  ",
            "\(legacy) legacy", legacy, "@agent-YWdlbnQtNw== padded", "@agent-!!! bad",
            "@" + String(repeating: "x", count: 2_000) + " huge",
            "@coordinator \(controls)", "@coordinator \u{202E}",
            "@coordinator " + String(repeating: "y", count: 13_000),
        ]
        for input in inputs {
            #expect(
                SharedChatMentionParser.parse(from: input, readableHandles: handles)
                    == TerminalChat.parseSharedChatMention(from: input, readableHandles: handles)
            )
        }
        let sanitized = "a␛[31mb    c␡d<C1-9B>e<LS>f<PS>g<U+202E>h<U+200B>i\nj␍"
        #expect(SharedChatMentionParser.parse(from: "@planner do it", readableHandles: handles)
            == .route(.init(destination: .direct(["agent-1"]), text: "do it")))
        #expect(SharedChatMentionParser.parse(from: "\(legacy) legacy")
            == .route(.init(destination: .direct(["agent-7"]), text: "legacy")))
        #expect(SharedChatMentionParser.parse(from: "@all-2 hi", readableHandles: handles)
            == .route(.init(destination: .direct(["agent-all"]), text: "hi")))
        #expect(SharedChatMentionParser.parse(from: "@coordinator \(controls)")
            == .route(.init(destination: .coordinator, text: String(sanitized.dropLast()))))
        #expect(SharedChatMentionParser.parse(from: "@coordinator \u{202E}")
            == .route(.init(destination: .coordinator, text: "<U+202E>")))
        #expect(SharedChatMentionParser.parse(from: "@COORDINATOR") == .missingText(destination: .coordinator))
        #expect(SharedChatMentionParser.parse(from: "@all   ") == .missingText(destination: .all))
        #expect(SharedChatMentionParser.parse(from: "@nobody hi") == .none)
        #expect(SharedChatMentionParser.parse(from: "@agent-YWdlbnQtNw== padded") == .none)

        let safeTexts = [
            (controls, sanitized),
            (String(repeating: "x", count: 12_001), String(repeating: "x", count: 12_000) + "…"),
        ]
        for (input, expected) in safeTexts {
            #expect(SharedChatMentionParser.terminalSafeText(input) == expected)
            #expect(TerminalChat.sharedChatTerminalSafeText(input) == expected)
        }
        let inlineTexts = [("  Worker \n\t one ", "Worker one"), (" \n\t ", "unnamed agent"), ("a\u{1B}b", "a␛b")]
        for (input, expected) in inlineTexts {
            #expect(SharedChatMentionParser.inlineTerminalSafeText(input) == expected)
            #expect(TerminalChat.sharedChatInlineTerminalSafeText(input) == expected)
        }
        #expect(SharedChatMentionParser.mentionHandle(forParticipantID: "agent-7") == "agent-YWdlbnQtNw")
        #expect(TerminalChat.sharedChatMentionHandle(forParticipantID: "agent-7") == "agent-YWdlbnQtNw")
    }

    /// The catalogue is the terminal's: the reserved mentions first, then
    /// the active agents by name with `joinedAt` breaking ties, one entry
    /// per handle. The terminal adds its summaries and fits the names; the
    /// picker buttons built from either side are the same.
    @Test
    func mentionSuggestionsMatchTheTerminalCatalogue() {
        let start = Date(timeIntervalSince1970: 1_000)
        let longName = String(repeating: "W", count: 60) + "\u{1B}"
        let participants: [AgentSharedChat.Participant] = [
            .init(id: "coordinator-id", name: "coordinator", kind: .coordinator, joinedAt: start),
            .init(id: "agent-b", name: "beta", kind: .agent, joinedAt: start.addingTimeInterval(1)),
            .init(id: "agent-a2", name: "Alpha", kind: .agent, joinedAt: start.addingTimeInterval(3)),
            .init(id: "agent-a1", name: "alpha", kind: .agent, joinedAt: start.addingTimeInterval(2)),
            .init(id: "agent-off", name: "asleep", kind: .agent, joinedAt: start, isActive: false),
            .init(id: "agent-all", name: "all", kind: .agent, joinedAt: start.addingTimeInterval(4)),
            .init(id: "agent-reserved", name: "x", kind: .agent, joinedAt: start),
            .init(id: "agent-raw", name: "raw", kind: .agent, joinedAt: start),
            .init(id: "agent-b", name: "beta", kind: .agent, joinedAt: start.addingTimeInterval(9)),
            .init(id: "agent-long", name: longName, kind: .agent, joinedAt: start.addingTimeInterval(5)),
        ]
        let handleMap = [
            "beta": "agent-b", "alpha": "agent-a1", "alpha-2": "agent-a2", "asleep": "agent-off",
            "all-2": "agent-all", "all": "agent-reserved", "long": "agent-long",
        ]

        let suggestions = SharedChatMentionParser.suggestions(for: participants, handleMap: handleMap)
        let terminalSuggestions = TerminalChat.sharedChatMentionSuggestions(
            for: participants, handleMap: handleMap
        )
        let commands = ["@coordinator ", "@all ", "@all-2 ", "@alpha ", "@alpha-2 ", "@beta ", "@long "]
        #expect(suggestions.map(\.command) == commands)
        #expect(terminalSuggestions.map(\.command) == commands)
        #expect(suggestions.map(\.target) == [
            .coordinator, .all, .agent(name: "all"), .agent(name: "alpha"), .agent(name: "Alpha"),
            .agent(name: "beta"), .agent(name: longName),
        ])
        #expect(terminalSuggestions.map(\.summary) == [
            "message the live coordinator",
            "message the coordinator and all active agent instances",
            "message active agent: all",
            "message active agent: alpha",
            "message active agent: Alpha",
            "message active agent: beta",
            "message active agent: "
                + TerminalChat.fitDisplayWidth(SharedChatMentionParser.inlineTerminalSafeText(longName), width: 48),
        ])

        let buttons = TelegramSessionCompanion.mentionPickerButtons(from: suggestions)
        let terminalButtons = TerminalChat.telegramMentionPickerButtons(from: terminalSuggestions)
        #expect(buttons.map(\.text) == ["@coordinator", "@all-2", "@alpha", "@alpha-2", "@beta", "@long"])
        #expect(buttons.map(\.text) == terminalButtons.map(\.text))
        #expect(buttons.map(\.callbackData) == terminalButtons.map(\.callbackData))
        #expect(TelegramSessionCompanion.mentionPickerCallbackPrefix == TerminalChat.telegramMentionPickerCallbackPrefix)
    }

    // MARK: - Mention picker and roster

    /// `/chat` offers the recipients of the session's roster, as the
    /// terminal's picker does on the same roster.
    @Test
    func mentionPickerOffersTheRosterLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let room = "companion-picker-\(UUID().uuidString)"
            let runner = try await Self.plannerRunner(room: room)
            let pair = try await Self.handLinked(room: room, runner: runner, channel: IngressCompanionChannel())

            await pair.terminal.handleTelegramMentionPickerRequest(chatID: 42, origin: .telegramLease(pair.lease))
            await pair.companion.handleMentionPickerRequest(chatID: 42, origin: .telegram(pair.lease))

            let cards = pair.companionCards.values
            #expect(cards == pair.terminalCards.values)
            #expect(cards.map(\.text) == [
                "Choose who to message. After selecting, reply to the next card with your message.",
            ])
            let suggestions = await pair.companion.sharedChatMentionSuggestions()
            let planner = try #require(suggestions.first { $0.target == .agent(name: "planner") })
            guard case let .inlineKeyboard(rows) = cards.first?.markup else {
                Issue.record("Expected an inline keyboard")
                return
            }
            #expect(rows.flatMap { $0 }.map(\.text) == ["@coordinator", "@\(planner.handle)"])
        }
    }

    /// Choosing a recipient answers with the ForceReply card and registers
    /// the roster's destination for its reply; a recipient that is not in
    /// the roster is told with the terminal's text.
    @Test
    func mentionPickerCallbackRegistersTheRosterTargetLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let room = "companion-picker-\(UUID().uuidString)"
            let runner = try await Self.plannerRunner(room: room)
            let pair = try await Self.handLinked(room: room, runner: runner, channel: IngressCompanionChannel())
            await pair.terminal.rebindTelegramSharedChatRelay(roomID: room)
            await pair.companion.rebindSharedChatRelay(roomID: room)
            let suggestions = await pair.companion.sharedChatMentionSuggestions()
            let planner = try #require(suggestions.first { $0.target == .agent(name: "planner") })
            let prefix = TelegramSessionCompanion.mentionPickerCallbackPrefix

            await pair.terminal.handleTelegramMentionPickerCallback(
                prefix + planner.handle, chatID: 42, origin: .telegramLease(pair.lease)
            )
            await pair.companion.handleMentionPickerCallback(
                prefix + planner.handle, chatID: 42, origin: .telegram(pair.lease)
            )
            let cards = pair.companionCards.values
            #expect(cards == pair.terminalCards.values)
            #expect(cards.map(\.markup) == [.forceReply])
            #expect(cards.map(\.text) == [
                "Writing to @\(planner.handle). Reply to this message with the content to send; it will not be treated as a normal prompt.",
            ])
            let target = await pair.companion.sharedChatRelay.replyTarget(
                forTelegramMessageID: Self.pickerReceipt, chatID: 42, lease: pair.lease
            )
            let terminalTarget = await pair.terminal.telegramSharedChatRelay.replyTarget(
                forTelegramMessageID: Self.pickerReceipt, chatID: 42, lease: pair.lease
            )
            #expect(target?.replyDestination == .direct(["agent-1"]))
            #expect(target?.senderKind == .agent)
            #expect(target?.senderName == planner.handle)
            #expect(terminalTarget?.replyDestination == target?.replyDestination)
            #expect(pair.companionTexts.values.isEmpty)

            // An unknown handle, and the legacy handle of an agent the roster
            // does not hold.
            for handle in ["ghost", SharedChatMentionParser.mentionHandle(forParticipantID: "agent-9")] {
                await pair.terminal.handleTelegramMentionPickerCallback(
                    prefix + handle, chatID: 42, origin: .telegramLease(pair.lease)
                )
                await pair.companion.handleMentionPickerCallback(
                    prefix + handle, chatID: 42, origin: .telegram(pair.lease)
                )
            }
            #expect(pair.companionTexts.values == Array(
                repeating: "ZenCODE message: that agent is no longer active. Run /chat again.", count: 2
            ))
            #expect(pair.companionTexts.values == pair.terminalTexts.values)
            #expect(pair.companionCards.values.count == 1)
        }
    }

    /// A direct destination is current only when it names one active agent
    /// of the session's roster; every other destination is current. The
    /// roster-based check answers what the terminal's answers.
    @Test
    func directDestinationsAreCheckedOnTheRosterLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let room = "companion-roster-\(UUID().uuidString)"
            let runner = try await Self.plannerRunner(room: room)
            let pair = try await Self.handLinked(room: room, runner: runner, channel: IngressCompanionChannel())
            let cases: [(AgentSharedChat.Destination, Bool)] = [
                (.direct(["agent-1"]), true),
                (.direct(["agent-9"]), false),
                (.direct([AgentSharedChat.coordinatorID(for: room)]), false),
                (.direct(["agent-1", "agent-9"]), true),
                (.direct([]), true),
                (.coordinator, true),
                (.all, true),
                (.operator, true),
                (.peers, true),
            ]
            for (destination, expected) in cases {
                #expect(await pair.companion.isCurrentSharedChatDirectDestination(destination) == expected)
                #expect(await pair.terminal.isCurrentSharedChatDirectDestination(destination) == expected)
            }
        }
    }

    // MARK: - Shared-chat relay

    /// Cards are forwarded only while the link is active, and invite a
    /// reply only while the ingress is read, with the terminal's texts.
    @Test
    func relayCardsFollowTheLinkAndTheIngressLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let room = "companion-relay-\(UUID().uuidString)"
            let runner = try await Self.plannerRunner(room: room)
            let pair = try await Self.handLinked(room: room, runner: runner, channel: IngressCompanionChannel())
            let terminalCards = RelayCardLog()
            let companionCards = RelayCardLog()
            pair.terminal.telegramSharedChatRelayStorage = Self.recordingRelay(terminalCards)
            pair.companion.sharedChatRelayStorage = Self.recordingRelay(companionCards)

            let unread = Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "need a decision")
            await pair.terminal.rebindTelegramSharedChatRelay(roomID: room)
            await pair.companion.rebindSharedChatRelay(roomID: room)
            await pair.terminal.forwardSharedChatMessagesToTelegram([unread], roomID: room)
            await pair.companion.forwardSharedChatMessages([unread], roomID: room)

            let read = Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "ship it?")
            pair.terminal.readsTelegramIngress = true
            pair.companion.readsIngress = true
            await pair.terminal.rebindTelegramSharedChatRelay(roomID: room)
            await pair.companion.rebindSharedChatRelay(roomID: room)
            await pair.terminal.forwardSharedChatMessagesToTelegram([read], roomID: room)
            await pair.companion.forwardSharedChatMessages([read], roomID: room)
            await pair.terminal.telegramSharedChatRelay.waitForPendingCards()
            await pair.companion.sharedChatRelay.waitForPendingCards()

            let texts = await companionCards.texts
            let terminalTexts = await terminalCards.texts
            #expect(texts == terminalTexts)
            #expect(texts.count == 2)
            #expect(texts.first?.hasSuffix(
                "This ZenCODE session does not read Telegram messages; answer from the terminal."
            ) == true)
            #expect(texts.last?.hasSuffix("Reply to this message to answer planner.") == true)

            // Unlinked, nothing is forwarded.
            pair.companion.controlState.isActive = false
            await pair.companion.forwardSharedChatMessages(
                [Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "late")],
                roomID: room
            )
            await pair.companion.sharedChatRelay.waitForPendingCards()
            #expect(await companionCards.texts.count == 2)
        }
    }

    /// A reply to an agent's card goes to that agent and tells the primary
    /// channel that the shared chat changed; a reply to a card whose sender
    /// is not in the roster is refused with the terminal's text, and a
    /// message that quotes no card of the room is not a reply.
    @Test
    func sharedChatRepliesReachTheirSenderLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let room = "companion-reply-\(UUID().uuidString)"
            let runner = try await Self.plannerRunner(room: room)
            let channel = IngressCompanionChannel()
            let pair = try await Self.handLinked(room: room, runner: runner, channel: channel)
            let terminalCards = RelayCardLog()
            let companionCards = RelayCardLog()
            pair.terminal.telegramSharedChatRelayStorage = Self.recordingRelay(terminalCards)
            pair.companion.sharedChatRelayStorage = Self.recordingRelay(companionCards)
            pair.terminal.readsTelegramIngress = true
            pair.companion.readsIngress = true
            await pair.terminal.rebindTelegramSharedChatRelay(roomID: room)
            await pair.companion.rebindSharedChatRelay(roomID: room)
            let messages = [
                Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "need a decision"),
                Self.agentMessage(room: room, senderID: "agent-9", name: "Ghost", text: "still there?"),
            ]
            await pair.terminal.forwardSharedChatMessagesToTelegram(messages, roomID: room)
            await pair.companion.forwardSharedChatMessages(messages, roomID: room)
            await pair.terminal.telegramSharedChatRelay.waitForPendingCards()
            await pair.companion.sharedChatRelay.waitForPendingCards()
            let receipts = await companionCards.receipts
            let terminalReceipts = await terminalCards.receipts
            try #require(receipts.count == 2 && terminalReceipts.count == 2)
            let origin = TelegramTurnOrigin.telegram(pair.lease)

            #expect(!(await pair.companion.handleSharedChatReplyIfNeeded(
                "hello", message: Self.incoming("hello", replyTo: nil), origin: origin
            )))
            #expect(!(await pair.companion.handleSharedChatReplyIfNeeded(
                "hello", message: Self.incoming("hello", replyTo: 1), origin: origin
            )))
            #expect(await pair.companion.directReplyTarget(
                for: Self.incoming("x", replyTo: receipts[0])
            )?.replyDestination == .direct(["agent-1"]))
            #expect(await pair.terminal.telegramDirectReplyTarget(
                for: Self.incoming("x", replyTo: terminalReceipts[0])
            )?.replyDestination == .direct(["agent-1"]))

            #expect(await pair.companion.handleSharedChatReplyIfNeeded(
                "ship it", message: Self.incoming("ship it", replyTo: receipts[0]), origin: origin
            ))
            #expect(channel.sharedChatChangeCount == 1)
            #expect(pair.companionTexts.values.isEmpty)
            let transcript = await runner.sharedChatTranscriptMessages(rootSessionID: room)
            #expect(transcript.contains { $0.text == "ship it" })

            #expect(await pair.terminal.handleTelegramSharedChatReplyIfNeeded(
                "too late", message: Self.incoming("too late", replyTo: terminalReceipts[1]),
                origin: .telegramLease(pair.lease)
            ))
            #expect(await pair.companion.handleSharedChatReplyIfNeeded(
                "too late", message: Self.incoming("too late", replyTo: receipts[1]), origin: origin
            ))
            #expect(pair.companionTexts.values == [
                "ZenCODE message: that agent is no longer active, so the reply was not delivered.",
            ])
            #expect(pair.companionTexts.values == pair.terminalTexts.values)
            #expect(channel.sharedChatChangeCount == 1)
        }
    }

    /// Quoting a card does not change what a command or a resolving mention
    /// means, as in the terminal; ordinary text stays a reply.
    @Test
    func replyRoutingPrecedenceMatchesTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let room = "companion-precedence-\(UUID().uuidString)"
            let runner = try await Self.plannerRunner(room: room)
            let pair = try await Self.handLinked(room: room, runner: runner, channel: IngressCompanionChannel())
            let suggestions = await pair.companion.sharedChatMentionSuggestions()
            let planner = try #require(suggestions.first { $0.target == .agent(name: "planner") })
            let claimed = [
                "/help", "/start 233B0EC4", "/plan route it", "/diff", "@coordinator status",
                "@all status", "@coordinator", "@\(planner.handle) hi", "@\(planner.handle)",
            ]
            let replies = ["@nobody hi", "yes, ship it", "answer with an email like a@b.com", "diff", "status"]
            for text in claimed {
                #expect(await pair.companion.replyRoutingHasPrecedence(over: text))
                #expect(await pair.terminal.telegramReplyRoutingHasPrecedence(over: text))
            }
            for text in replies {
                #expect(await pair.companion.replyRoutingHasPrecedence(over: text) == false)
                #expect(await pair.terminal.telegramReplyRoutingHasPrecedence(over: text) == false)
            }
        }
    }

    /// A rebind that the live lease does not cover retires the command
    /// receipts and unbinds the relay, as the terminal's does; a rebind it
    /// covers keeps them.
    @Test
    func rebindToAnotherRoomRetiresTheReceiptsLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let room = "companion-rebind-\(UUID().uuidString)"
            let pair = try await Self.handLinked(room: room, channel: IngressCompanionChannel())
            let companionCards = RelayCardLog()
            pair.companion.sharedChatRelayStorage = Self.recordingRelay(companionCards)
            let key = TerminalTelegramCommandReplyKey(chatID: 42, receiptMessageID: 90)
            let binding = TerminalTelegramCommandReplyBinding(command: "/plan", chatID: 42, lease: pair.lease)
            pair.terminal.telegramCommandReplyBindings[key] = binding
            pair.companion.commandReplyBindings[key] = binding

            await pair.terminal.rebindTelegramSharedChatRelay(roomID: room)
            await pair.companion.rebindSharedChatRelay(roomID: room)
            #expect(pair.companion.commandReplyBindings.count == 1)
            #expect(pair.terminal.telegramCommandReplyBindings.count == 1)

            await pair.terminal.rebindTelegramSharedChatRelay(roomID: "another-room")
            await pair.companion.rebindSharedChatRelay(roomID: "another-room")
            #expect(pair.companion.commandReplyBindings.isEmpty)
            #expect(pair.terminal.telegramCommandReplyBindings.isEmpty)
            await pair.companion.forwardSharedChatMessages(
                [Self.agentMessage(room: room, senderID: "agent-1", name: "planner", text: "unbound")],
                roomID: room
            )
            await pair.companion.sharedChatRelay.waitForPendingCards()
            #expect(await companionCards.texts.isEmpty)
        }
    }

    // MARK: - Voice

    /// A mirror-only companion refuses a voice note with the one refusal
    /// text, even with voice configured: before the work seam, and before
    /// anything is downloaded.
    @Test
    func mirrorOnlyRefusesAVoiceNoteBeforeTheDownload() async throws {
        try await Self.withSupport(
            telegram: Self.pairedSettings, voice: AgentVoiceSettingsManifest(enabled: true)
        ) {
            let channel = IngressCompanionChannel()
            let pair = try await Self.handLinked(
                room: "companion-voice-\(UUID().uuidString)", channel: channel,
                configuration: .init(primaryChannelDescription: "ACP client", policy: .mirrorOnly)
            )
            let effects = Recorder<TelegramSessionCompanion.TelegramWorkEffectForTesting>()
            pair.companion.onTelegramWorkEffectForTesting = { effect in
                effects.append(effect)
                return true
            }
            #expect(pair.companion.isVoiceConfigured)

            await pair.companion.handleVoiceMessage(Self.voiceNote, origin: .telegram(pair.lease))

            #expect(pair.companionTexts.values == [
                "ZenCODE: this session is driven by the ACP client; send prompts there. From Telegram you can use /help, /status, /changes, /diff and /chat, and answer permission requests with /allow, /always or /deny.",
            ])
            #expect(pair.companionTexts.values == [pair.companion.mirrorOnlyRefusalText])
            #expect(effects.values.isEmpty)
            #expect(pair.companion.voiceTranscriptions.activeCount == 0)
            #expect(channel.prompts.isEmpty)
            #expect(await pair.companionTransport.requestCount == 0)
        }
    }

    /// With the full policy a voice note passes the terminal's gates in the
    /// terminal's order: the work seam first, then the voice settings.
    @Test
    func voiceNotesPassTheTerminalGates() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let pair = try await Self.handLinked(
                room: "companion-voice-\(UUID().uuidString)", channel: IngressCompanionChannel()
            )
            let terminalEffects = Recorder<TerminalChat.TelegramWorkEffectForTesting>()
            let companionEffects = Recorder<TelegramSessionCompanion.TelegramWorkEffectForTesting>()
            pair.terminal.onTelegramWorkEffectForTesting = { effect in
                terminalEffects.append(effect)
                return true
            }
            pair.companion.onTelegramWorkEffectForTesting = { effect in
                companionEffects.append(effect)
                return true
            }
            await pair.terminal.handleTelegramVoiceMessage(
                Self.voiceNote, origin: .telegramLease(pair.lease),
                eventQueue: TerminalChatEventQueue(), transcriptions: TerminalVoiceTranscriptionRegistry()
            )
            await pair.companion.handleVoiceMessage(Self.voiceNote, origin: .telegram(pair.lease))
            #expect(terminalEffects.values == [.voiceTranscription])
            #expect(companionEffects.values == [.voiceTranscription])
            #expect(pair.companionTexts.values.isEmpty)

            pair.terminal.onTelegramWorkEffectForTesting = nil
            pair.companion.onTelegramWorkEffectForTesting = nil
            #expect(!pair.companion.isVoiceConfigured)
            await pair.terminal.handleTelegramVoiceMessage(
                Self.voiceNote, origin: .telegramLease(pair.lease),
                eventQueue: TerminalChatEventQueue(), transcriptions: TerminalVoiceTranscriptionRegistry()
            )
            await pair.companion.handleVoiceMessage(Self.voiceNote, origin: .telegram(pair.lease))
            #expect(pair.companionTexts.values == [AgentVoiceTranscriptionError.notEnabledMessage])
            #expect(pair.companionTexts.values == pair.terminalTexts.values)
            #expect(pair.companion.voiceTranscriptions.activeCount == 0)
            #expect(await pair.companionTransport.requestCount == 0)
        }
    }

    /// A voice note that cannot be downloaded runs in a slot of the
    /// companion, frees it, and its failure reaches the primary channel and
    /// the chat with the terminal's texts. Telegram is a scripted transport:
    /// no file and no transcription service is reached.
    @Test(.timeLimit(.minutes(1)))
    func failedVoiceDownloadIsReportedToTheChannelAndTheChat() async throws {
        try await Self.withSupport(
            telegram: Self.pairedSettings, voice: AgentVoiceSettingsManifest(enabled: true)
        ) {
            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9400))
            let channel = IngressCompanionChannel()
            let transport = CompanionTelegramTransport(botID: 9400)
            let companion = Self.makeCompanion(
                on: host, transport: transport, channel: channel,
                attachments: TelegramCompanionAttachments()
            )
            try await companion.attach()
            channel.clear()
            let lease = try #require(companion.activeRouteLease)

            await companion.handleVoiceMessage(Self.voiceNote, origin: .telegram(lease))
            try await Self.waitUntil { companion.voiceTranscriptions.activeCount == 0 }

            #expect(companion.voiceTranscriptions.activeCount == 0)
            #expect(channel.prompts.isEmpty)
            let notice = try #require(channel.notices.first)
            #expect(channel.notices.count == 1)
            #expect(notice.channel == .failure)
            #expect(notice.text.hasPrefix("ZenCODE: ") && notice.text.hasSuffix("\n"))
            let failure = String(notice.text.dropFirst("ZenCODE: ".count).dropLast())
            #expect(!failure.isEmpty)
            #expect(await transport.sentTexts.last == "Voice transcription failed: \(failure)")
            await companion.shutdown()
        }
    }

    /// A transcript is admitted through the primary channel as a direct
    /// prompt; a full queue, a refusal and a failure are told with the
    /// terminal's texts.
    @Test
    func transcriptionOutcomesGoThroughTheChannel() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let channel = IngressCompanionChannel()
            let pair = try await Self.handLinked(
                room: "companion-voice-\(UUID().uuidString)", channel: channel
            )
            let lease = pair.lease

            await pair.companion.voiceTranscriptionDidFinish(.success("summarize the diff"), lease: lease)
            #expect(channel.prompts == [.init(text: "summarize the diff", lease: lease, mode: .directPrompt)])
            #expect(channel.notices.isEmpty)
            #expect(pair.companionTexts.values.isEmpty)

            channel.admission = .queueFull
            await pair.companion.voiceTranscriptionDidFinish(.success("again"), lease: lease)
            #expect(channel.notices == [
                .init(text: "ZenCODE: prompt queue is full; voice prompt was not queued.\n", channel: .failure),
            ])
            #expect(pair.companionTexts.values == ["ZenCODE: prompt queue is full; voice prompt was not queued."])

            channel.clear()
            channel.admission = .refused
            await pair.companion.voiceTranscriptionDidFinish(.success("once more"), lease: lease)
            #expect(channel.notices.isEmpty)
            #expect(pair.companionTexts.values.last == pair.companion.mirrorOnlyRefusalText)

            await pair.companion.voiceTranscriptionDidFinish(.failure("Telegram file is unavailable."), lease: lease)
            #expect(channel.notices == [
                .init(text: "ZenCODE: Telegram file is unavailable.\n", channel: .failure),
            ])
            #expect(pair.companionTexts.values.last == "Voice transcription failed: Telegram file is unavailable.")
            #expect(channel.prompts.map(\.text) == ["summarize the diff", "again", "once more"])
            #expect(pair.companionTexts.values.count == 3)
        }
    }

    /// `cancelVoiceTranscriptions()` cancels a transcription in flight,
    /// waits for it, and closes admission for good: a later resume, as an
    /// attach does, does not reopen it.
    @Test(.timeLimit(.minutes(1)))
    func cancellingVoiceTranscriptionsClosesAdmissionForGood() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let pair = try await Self.handLinked(
                room: "companion-voice-\(UUID().uuidString)", channel: IngressCompanionChannel()
            )
            let registry = pair.companion.voiceTranscriptions
            let slot = try #require(registry.reserveSlot())
            let cancelled = Recorder<Bool>()
            let task = Task {
                defer { registry.release(slot) }
                try? await Task.sleep(for: .seconds(60))
                cancelled.append(Task.isCancelled)
            }
            registry.register(task, for: slot)

            await pair.companion.cancelVoiceTranscriptions()

            #expect(cancelled.values == [true])
            #expect(registry.activeCount == 0)
            #expect(registry.isShutDown)
            #expect(registry.reserveSlot() == nil)
            registry.resume()
            #expect(registry.reserveSlot() == nil)
        }
    }

    // MARK: - Artifacts

    /// `/diff` without an excerpt to send is answered with the terminal's
    /// text and stages nothing: no summary, and a summary whose only patch
    /// exceeds the upload budget.
    @Test
    func diffWithoutAnExcerptIsAnsweredLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let pair = try await Self.handLinked(
                room: "companion-diff-\(UUID().uuidString)", channel: IngressCompanionChannel()
            )
            let staging = Self.temporaryStagingDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }
            pair.companion.artifactStagingDirectory = staging

            await pair.terminal.handleTelegramDiffRequest(origin: .telegramLease(pair.lease))
            await pair.companion.handleDiffRequest(origin: .telegram(pair.lease))
            pair.terminal.lastFileChangeSummary = TurnFileChangeSummary(entries: [
                .init(
                    path: "Big.swift", additions: 1, deletions: 0, status: .modified,
                    isBinary: false, existedBefore: true, beforeDataBase64: nil,
                    patch: String(repeating: "+", count: TerminalTelegramMultipartForm.maximumBodyBytes + 1)
                ),
            ])
            #expect(pair.companion.controller.lastFileChangeSummary != nil)
            await pair.terminal.handleTelegramDiffRequest(origin: .telegramLease(pair.lease))
            await pair.companion.handleDiffRequest(origin: .telegram(pair.lease))

            #expect(pair.companionTexts.values == Array(
                repeating: "ZenCODE message: no diff is available for this session yet.", count: 2
            ))
            #expect(pair.companionTexts.values == pair.terminalTexts.values)
            #expect(!FileManager.default.fileExists(atPath: staging.path))
        }
    }

    /// `/diff` stages the bounded excerpt 0600 in the companion's staging
    /// directory, created 0700, and asks for consent with the two buttons;
    /// Cancel spends the offer, which removes the excerpt.
    @Test(.timeLimit(.minutes(1)))
    func diffStagesAPrivateExcerptAndCancelRemovesIt() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9401))
            let transport = CompanionTelegramTransport(botID: 9401)
            let (companion, lease) = try await Self.linkedCompanion(
                on: host, botID: 9401, channel: TurnCompanionChannel(), transport: transport
            )
            let staging = Self.temporaryStagingDirectory()
            defer { try? FileManager.default.removeItem(at: staging) }
            companion.artifactStagingDirectory = staging
            host.lastFileChangeSummary = Self.patchedSummary

            await companion.handleDiffRequest(origin: .telegram(lease))

            let files = try FileManager.default.contentsOfDirectory(
                at: staging, includingPropertiesForKeys: nil
            )
            #expect(files.count == 1)
            let excerpt = try #require(files.first)
            #expect(excerpt.lastPathComponent.hasPrefix("session-\(host.sessionID.prefix(8))-"))
            #expect(excerpt.pathExtension == "diff")
            let added = Self.patchedSummary.entries[1].status.rawValue
            #expect(companion.sessionDiffText() == "--- a/Value.swift\n+++ b/Value.swift\n@@ -1 +1 @@\n-let value = 1\n+let value = 2\n\(added) Added.swift (+3 -0)\n")
            // The excerpt is the diff text trimmed, as the terminal writes it.
            #expect(try String(contentsOf: excerpt, encoding: .utf8) == companion.sessionDiffText()?.nilIfBlank)
            #expect(try Self.permissions(of: excerpt) == 0o600)
            #expect(try Self.permissions(of: staging) == 0o700)
            #expect(await transport.sentTexts.last == "Send the session diff as a document?")
            let body = try #require(await transport.sentBodies.last)
            let offerID = try #require(Self.consentOfferID(in: body))

            #expect(await companion.handleArtifactConsentCallback(
                TerminalTelegramArtifactConsentKeyboard.callbackPrefix + "cancel:" + offerID,
                message: Self.incoming(nil, replyTo: nil), origin: .telegram(lease)
            ))
            #expect(await transport.sentTexts.last == "ZenCODE message: file send cancelled.")
            #expect(!FileManager.default.fileExists(atPath: excerpt.path))
            await companion.shutdown()
        }
    }

    /// A consent tap is claimed only for consent data; Send of an offer
    /// that does not exist, and Cancel, are answered with the terminal's
    /// texts.
    @Test(.timeLimit(.minutes(1)))
    func consentTapsAreAnsweredLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminalTransport = CompanionTelegramTransport(botID: 9402)
            let terminal = try Self.makeTerminal(transport: terminalTransport)
            await terminal.startTelegramControl()
            let terminalLease = try #require(terminal.telegramActiveRouteLease)
            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9403))
            let transport = CompanionTelegramTransport(botID: 9403)
            let (companion, lease) = try await Self.linkedCompanion(
                on: host, botID: 9403, channel: TurnCompanionChannel(), transport: transport
            )
            let message = Self.incoming(nil, replyTo: nil)

            #expect(!(await companion.handleArtifactConsentCallback(
                "zencode:mention:coordinator", message: message, origin: .telegram(lease)
            )))
            #expect(!(await terminal.handleTelegramArtifactConsentCallback(
                "zencode:mention:coordinator", message: message, origin: .telegramLease(terminalLease)
            )))
            let prefix = TerminalTelegramArtifactConsentKeyboard.callbackPrefix
            for data in [prefix + "send:zencode-artifact-missing", prefix + "cancel:zencode-artifact-missing"] {
                #expect(await terminal.handleTelegramArtifactConsentCallback(
                    data, message: message, origin: .telegramLease(terminalLease)
                ))
                #expect(await companion.handleArtifactConsentCallback(
                    data, message: message, origin: .telegram(lease)
                ))
            }
            let sent = Array(await transport.sentTexts.suffix(2))
            let terminalSent = Array(await terminalTransport.sentTexts.suffix(2))
            #expect(sent == [
                "ZenCODE message: that confirmation expired or no longer matches the file. Ask again with /diff.",
                "ZenCODE message: file send cancelled.",
            ])
            #expect(sent == terminalSent)
            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    /// An inbound attachment goes through the work seam first; one that
    /// cannot be received is answered with the terminal's text and leaves
    /// no temporary behind.
    @Test(.timeLimit(.minutes(1)))
    func inboundAttachmentsAreReceivedLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminalTransport = CompanionTelegramTransport(botID: 9404)
            let terminal = try Self.makeTerminal(transport: terminalTransport)
            await terminal.startTelegramControl()
            let terminalLease = try #require(terminal.telegramActiveRouteLease)
            let host = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9405))
            let transport = CompanionTelegramTransport(botID: 9405)
            let (companion, lease) = try await Self.linkedCompanion(
                on: host, botID: 9405, channel: TurnCompanionChannel(), transport: transport
            )
            let attachment = TerminalTelegramInboundAttachment(
                fileID: "file-1", fileUniqueID: nil, kind: .document,
                mimeType: "text/plain", fileSize: 4, fileName: "note.txt", messageID: 3
            )
            let message = TerminalTelegramIncomingMessage(
                chatID: 42, userID: 7, text: nil, voice: nil, messageID: 3,
                chatTitle: "Test", username: "operator", attachment: attachment
            )
            let effects = Recorder<TelegramSessionCompanion.TelegramWorkEffectForTesting>()
            companion.onTelegramWorkEffectForTesting = { effect in
                effects.append(effect)
                return true
            }
            let sentBefore = await transport.sentTexts.count
            await companion.handleInboundAttachment(attachment, message: message, origin: .telegram(lease))
            #expect(effects.values == [.attachmentDownload])
            #expect(await transport.sentTexts.count == sentBefore)

            companion.onTelegramWorkEffectForTesting = nil
            await terminal.handleTelegramInboundAttachment(
                attachment, message: message, origin: .telegramLease(terminalLease)
            )
            await companion.handleInboundAttachment(attachment, message: message, origin: .telegram(lease))
            let sent = await transport.sentTexts.last
            let terminalSent = await terminalTransport.sentTexts.last
            #expect(sent == "ZenCODE message: the attachment could not be received.")
            #expect(sent == terminalSent)
            #expect(await companion.controlService.inboundAttachmentFilenames(chatID: 42).isEmpty)
            await companion.shutdown()
            _ = await terminal.telegramControlService.stop()
        }
    }

    // MARK: - Ingress

    /// With the session free, every message is answered as the terminal
    /// answers it: the same texts, the same ForceReply cards, the same
    /// lines admitted on the message's route, and the same work started. A
    /// message from a group or from another user, a blank one, and any
    /// message on an inactive link are dropped without a word.
    @Test
    func idleIngressMatchesTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let pair = try await Self.handLinked(
                room: "companion-idle-\(UUID().uuidString)", channel: IngressCompanionChannel()
            )
            let terminalEffects = Recorder<TerminalChat.TelegramWorkEffectForTesting>()
            let companionEffects = Recorder<TelegramSessionCompanion.TelegramWorkEffectForTesting>()
            pair.terminal.onTelegramWorkEffectForTesting = { effect in
                terminalEffects.append(effect)
                return true
            }
            pair.companion.onTelegramWorkEffectForTesting = { effect in
                companionEffects.append(effect)
                return true
            }
            let messages: [TerminalTelegramIncomingMessage] = [
                Self.ownerMessage("/start"),
                Self.ownerMessage("/start 233B0EC4"),
                Self.ownerMessage("ordinary prompt"),
                Self.ownerMessage("/status"),
                Self.ownerMessage("/chat later"),
                Self.ownerMessage("/chat"),
                Self.ownerMessage("/plan"),
                Self.ownerMessage("route all frontends", replyTo: Self.pickerReceipt),
                Self.ownerMessage("/goal@zencode_bot"),
                Self.ownerMessage("implement parity", replyTo: Self.pickerReceipt),
                Self.ownerMessage("ordinary follow-up", replyTo: 5),
                Self.ownerMessage("@coordinator do work"),
                Self.ownerMessage("   \n "),
                Self.ownerMessage("/allow"),
                Self.ownerMessage(nil, attachment: Self.noteAttachment),
                Self.ownerMessage(nil, voice: Self.voiceNote),
                Self.ownerMessage("from a group", chatKind: .unsupported),
                Self.ownerMessage("from another user", userID: 8),
            ]
            var queued = TerminalQueuedPromptBuffer()
            var admitted: [ChatQueuedPrompt<TerminalTelegramRouteLease>] = []
            var queuedFlags: [Bool] = []
            for message in messages {
                let countBefore = queued.count
                await pair.terminal.handleTelegramMessage(
                    message, queuedPrompts: &queued, eventQueue: TerminalChatEventQueue(),
                    transcriptions: TerminalVoiceTranscriptionRegistry()
                )
                let didQueue = await pair.companion.handleIncomingMessage(
                    message, isSessionGenerating: false
                ) { prompt in
                    admitted.append(prompt)
                    return .queued
                }
                #expect(didQueue == (queued.count > countBefore), "\(message.text ?? "media")")
                queuedFlags.append(didQueue)
            }

            var terminalQueued: [TerminalQueuedPrompt] = []
            while let prompt = queued.dequeue() {
                terminalQueued.append(prompt)
            }
            #expect(admitted.map(\.text) == terminalQueued.map(\.text))
            #expect(admitted.map(\.text) == [
                "ordinary prompt", "/status", "/chat later", "/plan route all frontends",
                "/goal implement parity", "ordinary follow-up", "@coordinator do work",
            ])
            #expect(terminalQueued.allSatisfy { $0.origin == .telegramLease(pair.lease) })
            #expect(admitted.allSatisfy { $0.origin == pair.lease && $0.mode == .submittedLine })
            #expect(queuedFlags.count(where: { $0 }) == admitted.count)
            #expect(pair.companionTexts.values == pair.terminalTexts.values)
            #expect(pair.companionTexts.values.filter {
                $0 == "Telegram is already linked to this ZenCODE session. Send a prompt or /help."
            }.count == 2)
            #expect(pair.companionCards.values == pair.terminalCards.values)
            #expect(pair.companionCards.values.map(\.markup).filter { $0 == .forceReply }.count == 2)
            #expect(companionEffects.values == [.attachmentDownload, .voiceTranscription])
            #expect(terminalEffects.values == [.attachmentDownload, .voiceTranscription])

            // An inactive link reads nothing.
            pair.terminal.telegramControlState.isActive = false
            pair.companion.controlState.isActive = false
            let textCount = pair.companionTexts.values.count
            await pair.terminal.handleTelegramMessage(
                Self.ownerMessage("late prompt"), queuedPrompts: &queued,
                eventQueue: TerminalChatEventQueue(), transcriptions: TerminalVoiceTranscriptionRegistry()
            )
            #expect(!(await pair.companion.handleIncomingMessage(
                Self.ownerMessage("late prompt"), isSessionGenerating: false
            ) { prompt in
                admitted.append(prompt)
                return .queued
            }))
            #expect(queued.isEmpty)
            #expect(admitted.count == 7)
            #expect(pair.companionTexts.values.count == textCount)
        }
    }

    /// A full queue is told with the terminal's texts, for a prompt and for
    /// a command completed through its ForceReply; a prompt the channel
    /// refuses gets the refusal text.
    @Test
    func fullQueueAndRefusedPromptsAreAnsweredLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let pair = try await Self.handLinked(
                room: "companion-queue-\(UUID().uuidString)", channel: IngressCompanionChannel()
            )
            var queued = TerminalQueuedPromptBuffer(capacity: 1)
            queued.enqueue(TerminalQueuedPrompt(text: "already waiting", origin: .local))
            let messages = [
                Self.ownerMessage("overflow prompt"),
                Self.ownerMessage("/plan"),
                Self.ownerMessage("route all frontends", replyTo: Self.pickerReceipt),
            ]
            for message in messages {
                await pair.terminal.handleTelegramMessage(
                    message, queuedPrompts: &queued, eventQueue: TerminalChatEventQueue(),
                    transcriptions: TerminalVoiceTranscriptionRegistry()
                )
                #expect(!(await pair.companion.handleIncomingMessage(
                    message, isSessionGenerating: false, admit: { _ in .queueFull }
                )))
            }
            #expect(pair.companionTexts.values == pair.terminalTexts.values)
            #expect(pair.companionTexts.values == [
                "ZenCODE is busy and the prompt queue is full. Your prompt was not queued; try again after a running prompt completes.",
                "ZenCODE is busy and the prompt queue is full. Your command was not queued; try again after a running prompt completes.",
            ])

            #expect(!(await pair.companion.handleIncomingMessage(
                Self.ownerMessage("refused prompt"), isSessionGenerating: false, admit: { _ in .refused }
            )))
            #expect(pair.companionTexts.values.last == pair.companion.mirrorOnlyRefusalText)
        }
    }

    /// While the session generates, only permission replies, `/status`,
    /// `/chat`, the slash forms of `/help` and `/changes`, and the picker
    /// taps are answered; everything else is told the session is busy,
    /// before any work starts, exactly as in the terminal.
    @Test
    func busyGateMatchesTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let pair = try await Self.handLinked(
                room: "companion-busy-\(UUID().uuidString)", channel: IngressCompanionChannel()
            )
            let terminalEffects = Recorder<TerminalChat.TelegramWorkEffectForTesting>()
            let companionEffects = Recorder<TelegramSessionCompanion.TelegramWorkEffectForTesting>()
            pair.terminal.onTelegramWorkEffectForTesting = { effect in
                terminalEffects.append(effect)
                return true
            }
            pair.companion.onTelegramWorkEffectForTesting = { effect in
                companionEffects.append(effect)
                return true
            }
            let messages: [TerminalTelegramIncomingMessage] = [
                Self.ownerMessage("ordinary prompt"),
                Self.ownerMessage("/status"),
                Self.ownerMessage("stato"),
                Self.ownerMessage("/help"),
                Self.ownerMessage("help"),
                Self.ownerMessage("/changes"),
                Self.ownerMessage("changes"),
                Self.ownerMessage("/status now"),
                Self.ownerMessage("/diff"),
                Self.ownerMessage("/undo"),
                Self.ownerMessage("/start"),
                Self.ownerMessage("/plan route all frontends"),
                Self.ownerMessage("/plan"),
                Self.ownerMessage("/chat"),
                Self.ownerMessage("/allow"),
                Self.ownerMessage(nil, attachment: Self.noteAttachment),
                Self.ownerMessage(nil, voice: Self.voiceNote),
                Self.ownerMessage("@coordinator do work"),
                Self.ownerMessage(nil, callbackData: "zencode:mention:coordinator"),
                Self.ownerMessage(nil, callbackData: "unrelated"),
            ]
            var queued = TerminalQueuedPromptBuffer()
            for message in messages {
                await pair.terminal.handleTelegramMessage(
                    message, queuedPrompts: &queued, eventQueue: TerminalChatEventQueue(),
                    transcriptions: TerminalVoiceTranscriptionRegistry(), isSessionGenerating: true
                )
                #expect(!(await pair.companion.handleIncomingMessage(
                    message, isSessionGenerating: true
                ) { _ in
                    Issue.record("A busy session admitted a prompt")
                    return .queued
                }))
            }

            #expect(queued.isEmpty)
            #expect(pair.companionTexts.values == pair.terminalTexts.values)
            #expect(pair.companionCards.values == pair.terminalCards.values)
            #expect(pair.companionCards.values.count == 2)
            #expect(companionEffects.values.isEmpty)
            #expect(terminalEffects.values.isEmpty)
            let busy = pair.companionTexts.values.filter { $0 == TelegramSessionCompanion.busyMessageText }
            #expect(busy.count == 13)
            #expect(pair.companionTexts.values.filter { $0 == pair.companion.remoteStatusText() }.count == 2)
            #expect(pair.companionTexts.values.contains(pair.companion.remoteHelpText()))
            #expect(pair.companionTexts.values.contains(pair.companion.remoteChangesText()))
        }
    }

    /// The remote commands a line carries when it leaves the queue are
    /// answered as the terminal answers them, with the same texts and the
    /// same action: arguments refused, unknown commands listed, mentions
    /// diagnosed, prompts passed on, and `/plan` `/goal` `/review` run by
    /// the controller with their notices sent to the chat.
    @Test
    func lineDispatchMatchesTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let pair = try await Self.handLinked(
                room: "companion-lines-\(UUID().uuidString)", channel: IngressCompanionChannel()
            )
            pair.terminal.selectedToolKeys.insert("sub-agents")
            let lines = [
                "/help", "/help@zencode_bot", "/status", "/changes", "/undo", "/diff", "/start",
                "/start 233B0EC4", "/chat", "/status now", "/chat later", "/foo bar", "/allow",
                "status", "stato", "diff", "ordinary prompt", "@nobody hi", "@coordinator",
                "/plan", "/plan status", "/PLAN status", "/plan approve", "/plan clear", "/plan list",
                "/goal", "/review", "/review@zencode_bot routing", "/REVIEW routing",
            ]
            for line in lines {
                let terminalTextCount = pair.terminalTexts.values.count
                let companionTextCount = pair.companionTexts.values.count
                let terminalCardCount = pair.terminalCards.values.count
                let companionCardCount = pair.companionCards.values.count
                let terminalAction = Self.describe(
                    await pair.terminal.submittedTelegramLineAction(line, origin: .telegramLease(pair.lease))
                )
                let action = Self.describe(await pair.companion.lineAction(for: line, lease: pair.lease))
                #expect(action == terminalAction, "\(line)")
                #expect(
                    Array(pair.companionTexts.values.dropFirst(companionTextCount))
                        == Array(pair.terminalTexts.values.dropFirst(terminalTextCount)),
                    "\(line)"
                )
                #expect(
                    Array(pair.companionCards.values.dropFirst(companionCardCount))
                        == Array(pair.terminalCards.values.dropFirst(terminalCardCount)),
                    "\(line)"
                )
            }

            let texts = pair.companionTexts.values
            #expect(texts.contains("ZenCODE: /status does not accept arguments."))
            #expect(texts.contains("ZenCODE: /chat does not accept arguments."))
            #expect(texts.contains(
                "ZenCODE: unknown command '/foo'. Available commands: \(TelegramSessionCompanion.remoteCommandList(policy: .full))"
            ))
            #expect(texts.contains("Use /undo in the TUI to revert file changes."))
            #expect(texts.contains("ZenCODE message: add a message after the live mention."))
            #expect(texts.filter { $0.contains("No tracked session file changes to review") }.count == 3)
            #expect(await pair.companion.lineAction(for: "ordinary prompt", lease: pair.lease)
                == .runPrompt("ordinary prompt"))
            #expect(await pair.companion.lineAction(for: "/allow", lease: pair.lease) == .runPrompt("/allow"))

            // A line on a route that is no longer valid is dropped.
            let stale = TerminalTelegramRouteLease(key: pair.lease.key, generation: pair.lease.generation + 1)
            let count = texts.count
            #expect(await pair.companion.lineAction(for: "/status", lease: stale) == .handled)
            #expect(pair.companionTexts.values.count == count)
        }
    }

    /// `/plan` runs through the controller and returns the turn it starts,
    /// as the terminal's hidden prompt, without telling the chat; while the
    /// Planner waits, a plain line, a plain-word alias included, continues
    /// it, a slash command keeps its meaning, and a mutation it blocks is
    /// told to the chat with the terminal's text.
    @Test
    func planRunsThroughTheControllerAndRepliesContinueItLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminalPair = try await Self.handLinked(
                room: "companion-plan-terminal-\(UUID().uuidString)", channel: IngressCompanionChannel()
            )
            let companionPair = try await Self.handLinked(
                room: "companion-plan-\(UUID().uuidString)", channel: IngressCompanionChannel()
            )
            for pair in [terminalPair, companionPair] {
                pair.terminal.selectedToolKeys.insert("sub-agents")
            }
            let terminal = terminalPair.terminal
            let companion = companionPair.companion
            let terminalOrigin = TerminalPromptOrigin.telegramLease(terminalPair.lease)

            let terminalStart = Self.describe(
                await terminal.submittedTelegramLineAction("/plan route all frontends", origin: terminalOrigin)
            )
            let start = await companion.lineAction(for: "/plan route all frontends", lease: companionPair.lease)
            #expect(Self.describe(start) == terminalStart)
            guard case let .commandOutcome(outcome) = start,
                  case let .startTurn(prompt, purpose, locksResponseLanguage) = outcome.action else {
                Issue.record("/plan should start a planning turn")
                return
            }
            #expect(prompt.contains("Planning goal requested by the user: route all frontends"))
            #expect(purpose == .plan(originalGoal: "route all frontends"))
            #expect(!locksResponseLanguage)
            #expect(companionPair.companionTexts.values.isEmpty)
            #expect(terminalPair.terminalTexts.values.isEmpty)

            for pair in [terminalPair, companionPair] {
                var discussion = try #require(pair.terminal.planBrainstorming)
                discussion.recordPlannerOutput(
                    "Planner questions\n1. Keep it runtime-only?",
                    agentID: "planner-telegram",
                    revision: 1
                )
                pair.terminal.planBrainstorming = discussion
            }
            let lines = ["/plan approve", "/help", "Yes, runtime-only."]
            for line in lines {
                let terminalAction = Self.describe(
                    await terminal.submittedTelegramLineAction(line, origin: terminalOrigin)
                )
                let action = Self.describe(await companion.lineAction(for: line, lease: companionPair.lease))
                #expect(action == terminalAction, "\(line)")
            }
            #expect(companionPair.companionTexts.values == terminalPair.terminalTexts.values)
            #expect(companionPair.companionTexts.values.first
                == ChatSessionNoticeText.text(for: .planDiscussionBlocksMutation)
                    .trimmingCharacters(in: .whitespacesAndNewlines))
            #expect(companionPair.companionTexts.values.last == companion.remoteHelpText())

            // The alias "status" is a reply while the Planner waits.
            for pair in [terminalPair, companionPair] {
                var discussion = try #require(pair.terminal.planBrainstorming)
                discussion.recordPlannerOutput(
                    "Planner questions\n1. Another choice?",
                    agentID: "planner-telegram",
                    revision: 2
                )
                pair.terminal.planBrainstorming = discussion
            }
            let terminalAlias = Self.describe(
                await terminal.submittedTelegramLineAction("status", origin: terminalOrigin)
            )
            let alias = await companion.lineAction(for: "status", lease: companionPair.lease)
            #expect(Self.describe(alias) == terminalAlias)
            guard case let .commandOutcome(aliasOutcome) = alias,
                  case let .startTurn(_, aliasPurpose, _) = aliasOutcome.action else {
                Issue.record("The alias should continue the Planner")
                return
            }
            #expect(aliasPurpose == .plan(originalGoal: "route all frontends"))
            #expect(companionPair.companionTexts.values == terminalPair.terminalTexts.values)
        }
    }

    /// The coordinator command line handed to the controller is the
    /// registry's spelling of the command the coordinator parser read.
    @Test
    func coordinatorCommandLinesUseTheRegistrySpelling() throws {
        let cases = [
            ("/PLAN status", "/plan status"),
            ("/review\tfocus on routing", "/review focus on routing"),
            ("/goal", "/goal"),
            ("/Goal  ship  it ", "/goal ship  it"),
            ("/plan@zencode_bot approve", "/plan approve"),
        ]
        for (line, expected) in cases {
            let command = try #require(CoordinatorCommandParser.parse(line))
            #expect(TelegramSessionCompanion.coordinatorCommandLine(command, from: line) == expected)
        }
    }

    /// A live mention from Telegram reaches the room with the Telegram
    /// origin of the turn it triggers, which a trigger consumes once; a
    /// mention of an agent that is gone is reported on the primary channel
    /// only, with the terminal's text.
    @Test
    func liveMentionsArePublishedWithTheirTelegramOriginLikeTheTerminal() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let room = "companion-mention-\(UUID().uuidString)"
            let runner = try await Self.plannerRunner(room: room)
            let channel = IngressCompanionChannel()
            let pair = try await Self.handLinked(room: room, runner: runner, channel: channel)

            #expect(Self.describe(await pair.terminal.submittedTelegramLineAction(
                "@coordinator from the terminal", origin: .telegramLease(pair.lease)
            )) == "handled")
            #expect(await pair.companion.lineAction(
                for: "@planner from Telegram", lease: pair.lease
            ) == .handled)
            let transcript = await runner.sharedChatTranscriptMessages(rootSessionID: room)
            let terminalMessage = try #require(transcript.first { $0.text == "from the terminal" })
            let companionMessage = try #require(transcript.first { $0.text == "from Telegram" })
            #expect(pair.terminal.takeTelegramSharedChatOrigin(for: [terminalMessage])
                == .telegramLease(pair.lease))
            #expect(pair.companion.takeSharedChatOrigin(for: [terminalMessage, companionMessage])
                == .telegram(pair.lease))
            #expect(pair.companion.takeSharedChatOrigin(for: [companionMessage]) == nil)
            #expect(channel.sharedChatChangeCount == 1)
            #expect(pair.companionTexts.values.isEmpty)

            let gone = "@" + SharedChatMentionParser.mentionHandle(forParticipantID: "agent-404") + " hello"
            let terminalWrites = await Self.capturing(pair.terminal) {
                _ = await pair.terminal.submittedTelegramLineAction(gone, origin: .telegramLease(pair.lease))
            }
            #expect(await pair.companion.lineAction(for: gone, lease: pair.lease) == .handled)
            #expect(channel.notices == [
                .init(text: "ZenCODE message: selected agent is no longer active.\n", channel: .failure),
            ])
            #expect(channel.notices.map(\.text) == terminalWrites)
            #expect(channel.sharedChatChangeCount == 2)
            #expect(pair.companionTexts.values.isEmpty)
            #expect(pair.terminalTexts.values.isEmpty)
        }
    }

    /// A mirror-only companion refuses, busy or not and before the busy
    /// gate, everything that would drive the session, with the one refusal
    /// text; what it accepts keeps the busy gate, is answered at once
    /// without the channel's queue, and `/help` and `/start` say what the
    /// session is.
    @Test
    func mirrorOnlyRefusesWhatWouldDriveTheSessionBeforeTheBusyGate() async throws {
        try await Self.withSupport(
            telegram: Self.pairedSettings, voice: AgentVoiceSettingsManifest(enabled: true)
        ) {
            let channel = IngressCompanionChannel()
            let pair = try await Self.handLinked(
                room: "companion-mirror-\(UUID().uuidString)", channel: channel,
                configuration: .init(primaryChannelDescription: "ACP client", policy: .mirrorOnly)
            )
            let companion = pair.companion
            let effects = Recorder<TelegramSessionCompanion.TelegramWorkEffectForTesting>()
            companion.onTelegramWorkEffectForTesting = { effect in
                effects.append(effect)
                return true
            }
            let refusal = companion.mirrorOnlyRefusalText
            /// The texts `message` produced, with the queue never consulted.
            func answer(_ message: TerminalTelegramIncomingMessage, busy: Bool) async -> [String] {
                let count = pair.companionTexts.values.count
                let didQueue = await companion.handleIncomingMessage(message, isSessionGenerating: busy) { _ in
                    Issue.record("A mirror-only companion admitted a prompt")
                    return .queued
                }
                #expect(!didQueue)
                return Array(pair.companionTexts.values.dropFirst(count))
            }

            let refused: [TerminalTelegramIncomingMessage] = [
                Self.ownerMessage("please fix the bug"),
                Self.ownerMessage("/plan route all frontends"),
                Self.ownerMessage("/plan"),
                Self.ownerMessage("/PLAN@zencode_bot status"),
                Self.ownerMessage("/goal ship it"),
                Self.ownerMessage("/goal"),
                Self.ownerMessage("/review"),
                Self.ownerMessage("/review focus"),
                Self.ownerMessage("/undo"),
                Self.ownerMessage("/undo now"),
                Self.ownerMessage("undo"),
                Self.ownerMessage("annulla modifiche"),
                Self.ownerMessage(nil, voice: Self.voiceNote),
            ]
            for busy in [false, true] {
                for message in refused {
                    #expect(
                        await answer(message, busy: busy) == [refusal],
                        "\(message.text ?? "voice") busy: \(busy)"
                    )
                }
            }
            #expect(effects.values.isEmpty)
            #expect(pair.companionCards.values.isEmpty)
            #expect(companion.commandReplyBindings.isEmpty)
            #expect(channel.prompts.isEmpty)

            let help = """
                Telegram mirrors the ZenCODE session driven by the ACP client; send prompts there.
                Remote commands: /help, /status, /changes, /diff, /chat.
                /diff sends a file only after you confirm it with an explicit button; nothing is uploaded automatically.
                Permission replies: /allow ID, /always ID, /deny ID. Gated operations (shell commands, deletions, git push/restore) are asked here too.
                Prompts, voice notes, /plan, /goal, /review and /undo are not available from Telegram in this session.
                """
            #expect(companion.remoteHelpText() == help)
            let idle: [(String, String)] = [
                ("/status", companion.remoteStatusText()),
                ("status", companion.remoteStatusText()),
                ("/help", help),
                ("/start", "Telegram is already linked to this ZenCODE session. Send /help."),
                ("/start 233B0EC4", "Telegram is already linked to this ZenCODE session. Send /help."),
                ("/changes", companion.remoteChangesText()),
                ("/diff", "ZenCODE message: no diff is available for this session yet."),
                ("/status now", "ZenCODE: /status does not accept arguments."),
                ("/foo", "ZenCODE: unknown command '/foo'. Available commands: /help, /status, /changes, /diff, /chat"),
                ("@coordinator", "ZenCODE message: add a message after the live mention."),
            ]
            for (text, expected) in idle {
                #expect(await answer(Self.ownerMessage(text), busy: false) == [expected], "\(text)")
            }
            let allow = await answer(Self.ownerMessage("/allow"), busy: false)
            #expect(allow.count == 1 && allow != [refusal])
            #expect(await answer(Self.ownerMessage("@coordinator please look"), busy: false).isEmpty)
            #expect(effects.values == [.sharedChatPublication])
            #expect(await answer(Self.ownerMessage("/chat"), busy: false).isEmpty)
            #expect(pair.companionCards.values.count == 1)

            let busy: [(String, String)] = [
                ("/status", companion.remoteStatusText()),
                ("status", companion.remoteStatusText()),
                ("/help", help),
                ("/changes", companion.remoteChangesText()),
                ("/diff", TelegramSessionCompanion.busyMessageText),
                ("/start", TelegramSessionCompanion.busyMessageText),
                ("/foo", TelegramSessionCompanion.busyMessageText),
                ("@coordinator please look", TelegramSessionCompanion.busyMessageText),
            ]
            for (text, expected) in busy {
                #expect(await answer(Self.ownerMessage(text), busy: true) == [expected], "\(text)")
            }
            #expect(effects.values == [.sharedChatPublication])

            // A question waiting for a reply changes nothing: the reply is
            // refused and the alias stays a command.
            var discussion = PlanningCommandRuntimeState(goal: "route all frontends")
            discussion.recordPlannerOutput(
                "Planner questions\n1. Keep it runtime-only?", agentID: "planner-telegram", revision: 1
            )
            pair.terminal.planBrainstorming = discussion
            #expect(await answer(Self.ownerMessage("Yes, runtime-only."), busy: false) == [refusal])
            #expect(await answer(Self.ownerMessage("status"), busy: false) == [companion.remoteStatusText()])
            #expect(pair.terminal.planBrainstorming?.isAwaitingReply == true)

            // Called directly, a line is never run.
            for line in ["ordinary prompt", "/plan route", "/allow"] {
                #expect(await companion.lineAction(for: line, lease: pair.lease) == .handled, "\(line)")
                #expect(pair.companionTexts.values.last == refusal, "\(line)")
            }
            #expect(channel.prompts.isEmpty)
        }
    }

    /// D4 a′: with two companions attached to the same bot, a permission
    /// reply without a request ID on the route they share (General, an
    /// unknown topic that falls back to it) is refused, busy or not, and no
    /// broker decides; with its ID it decides. In the session's own topic,
    /// and with one companion, the reply without an ID decides as before.
    @Test(.timeLimit(.minutes(1)))
    func permissionRepliesWithoutAnIDOnTheSharedRouteNeedOneWithSeveralCompanions() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let attachments = TelegramCompanionAttachments()
            let room = "companion-shared-\(UUID().uuidString)"
            let first = try await Self.sharedBotMember(
                room: room, topicID: 70, botID: 9401, attachments: attachments
            )
            let second = try await Self.sharedBotMember(
                room: "companion-shared-other-\(UUID().uuidString)", topicID: 71,
                botID: 9401, attachments: attachments
            )
            #expect(attachments.attachedCount(botID: 9401) == 2)
            let companion = first.companion
            let refusal = "ZenCODE: several ZenCODE sessions are attached to this chat; reply with the request ID: /allow ID, /always ID or /deny ID."
            #expect(TelegramSessionCompanion.sharedRoutePermissionReplyText == refusal)
            let admit: (ChatQueuedPrompt<TerminalTelegramRouteLease>) -> TelegramPromptAdmission = { _ in
                Issue.record("A permission reply was admitted as a prompt")
                return .queued
            }

            let sharedLease = try await companion.router.resolve(chatID: 42, userID: 7, topicID: nil)
            #expect(sharedLease.key.roomID == "default" && sharedLease.key.topicID == nil)
            let shared = try await Self.pendingPermission(on: companion, lease: sharedLease)
            let refusedReplies: [(String, Int?, Bool)] = [
                ("/allow", nil, true),
                ("/always", nil, false),
                ("/deny@zencode_bot", 99, false),
                ("/allow !!!", nil, true),
            ]
            for (text, topicID, busy) in refusedReplies {
                #expect(!(await companion.handleIncomingMessage(
                    Self.ownerMessage(text, topicID: topicID), isSessionGenerating: busy, admit: admit
                )))
            }
            #expect(first.texts.values == [
                RoutedText(text: refusal, topicID: nil),
                RoutedText(text: refusal, topicID: nil),
                RoutedText(text: refusal, topicID: 99),
                RoutedText(text: refusal, topicID: nil),
            ])
            // The request was still pending: the reply with its ID decides it.
            _ = await companion.handleIncomingMessage(
                Self.ownerMessage("/deny \(shared.requestID)"), isSessionGenerating: true, admit: admit
            )
            #expect(await shared.decision.value == .denied)
            #expect(first.texts.values.last == RoutedText(
                text: "⛔ Permission \(shared.requestID) denied. The operation will not run.", topicID: nil
            ))

            // The session's own topic is attributed: no ID is needed.
            let topicLease = try await companion.router.resolve(chatID: 42, userID: 7, topicID: 70)
            #expect(topicLease.key.roomID == room && topicLease.key.topicID == 70)
            let topic = try await Self.pendingPermission(on: companion, lease: topicLease)
            _ = await companion.handleIncomingMessage(
                Self.ownerMessage("/allow", topicID: 70), isSessionGenerating: true, admit: admit
            )
            #expect(await topic.decision.value == .allowedOnce)
            #expect(first.texts.values.last == RoutedText(
                text: "✅ Permission \(topic.requestID) allowed once. Continuing.", topicID: 70
            ))

            // With one companion, the shared route is attributed as before.
            attachments.unregister(second.companion)
            #expect(attachments.attachedCount(botID: 9401) == 1)
            let single = try await Self.pendingPermission(on: companion, lease: sharedLease)
            _ = await companion.handleIncomingMessage(
                Self.ownerMessage("/always"), isSessionGenerating: false, admit: admit
            )
            #expect(await single.decision.value == .allowedAlways)
            #expect(first.texts.values.last == RoutedText(
                text: "✅ Permission \(single.requestID) allowed always. Continuing.", topicID: nil
            ))
            #expect(second.texts.values.isEmpty)
            #expect(first.channel.prompts.isEmpty)
        }
    }

    /// A channel without a loop has the companion read the ingress: a
    /// stop-generation update is ignored, the channel's generating state
    /// gates each message, a prompt is refused for lack of a queue, and
    /// the consumer stops with the link, leaving later messages unread.
    @Test(.timeLimit(.minutes(1)))
    func consumingReadsTheIngressUntilTheLinkStops() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            for policy in [TelegramSessionCompanion.Policy.mirrorOnly, .full] {
                let channel = IngressCompanionChannel()
                let pair = try await Self.handLinked(
                    room: "companion-consume-\(UUID().uuidString)", channel: channel,
                    configuration: .init(primaryChannelDescription: "ACP client", policy: policy)
                )
                let companion = pair.companion
                let (texts, continuation) = AsyncStream.makeStream(of: String.self)
                var iterator = texts.makeAsyncIterator()
                companion.onTelegramSystemMessage = { text, _ in
                    continuation.yield(text)
                    return true
                }
                let mailbox = companion.controlService.incomingMailbox
                let stop = Self.ownerMessage(nil, stoppedDraftID: 5)
                #expect(!(await companion.stoppedDraftBelongsToActiveTurn(stop)))
                #expect(!(await companion.stoppedDraftBelongsToActiveTurn(Self.ownerMessage("/status"))))

                companion.startConsuming()
                let consumer = try #require(companion.ingressConsumerTask)
                companion.startConsuming()
                #expect(companion.ingressConsumerTask == consumer)
                #expect(companion.readsIngress)

                #expect(await mailbox.send(stop))
                #expect(await mailbox.send(Self.ownerMessage("/start")))
                #expect(await iterator.next() == companion.alreadyLinkedText)
                #expect(await mailbox.send(Self.ownerMessage("ordinary prompt")))
                #expect(await iterator.next() == companion.mirrorOnlyRefusalText)
                channel.isGenerating = true
                #expect(await mailbox.send(Self.ownerMessage("/diff")))
                #expect(await iterator.next() == TelegramSessionCompanion.busyMessageText)
                #expect(await mailbox.send(Self.ownerMessage("/help")))
                #expect(await iterator.next() == companion.remoteHelpText())
                #expect(channel.prompts.isEmpty)

                if policy == .mirrorOnly {
                    await companion.detach()
                    #expect(channel.notices.last?.text == "Telegram remote control stopped.\n")
                    #expect(!companion.voiceTranscriptions.isShutDown)
                } else {
                    await companion.shutdown()
                    #expect(companion.voiceTranscriptions.isShutDown)
                }
                #expect(companion.ingressConsumerTask == nil)
                #expect(!companion.readsIngress)
                #expect(await mailbox.send(Self.ownerMessage("/status")))
                #expect(await mailbox.bufferedCountForTesting == 1)
            }
        }
    }

    // MARK: - Topics

    // Topic mode and legacy mode (`TelegramSessionCompanion+Topics.swift`):
    // the route the session uses, the notice in General, the fallback to the
    // shared route, the rebind and its rename, and the close and prune at
    // detach and shutdown. Every router persists to the test's settings, as
    // the terminal's does, so an attach reads back what an earlier one wrote.

    /// The default topic name is the folder and the last eight characters of
    /// the session ID, bounded to Telegram's 128 UTF-16 units.
    @Test
    func defaultTopicNameIsTheFolderAndTheSessionSuffixBounded() {
        let folder = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        #expect(TelegramSessionCompanion.defaultTopicName(
            workingDirectory: folder, sessionID: "0123456789abcdef"
        ) == "project · 89abcdef")
        #expect(TelegramSessionCompanion.defaultTopicName(
            workingDirectory: folder, sessionID: "abc"
        ) == "project · abc")
        let deep = URL(
            fileURLWithPath: "/tmp/" + String(repeating: "d", count: 200), isDirectory: true
        )
        #expect(TelegramSessionCompanion.defaultTopicName(
            workingDirectory: deep, sessionID: "0123456789abcdef"
        ) == String(repeating: "d", count: 128))
    }

    /// With Threaded mode and no topic of its own, the session creates one,
    /// binds it to a route of its own, and announces it once in General after
    /// the activation text; `/telegram status` names it. A repeated attach
    /// reuses the topic without a request or a notice.
    @Test(.timeLimit(.minutes(1)))
    func attachCreatesTheSessionTopicAndAnnouncesItOnceInGeneral() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let transport = CompanionTelegramTransport(
                botID: 9501, hasTopicsEnabled: true, createdTopicIDs: [501]
            )
            let commits = Recorder<[AgentTelegramRouteManifest]>()
            let member = try Self.topicMember(transport: transport, commits: commits)
            let companion = member.companion

            try await companion.attach()

            let name = Self.topicSessionName
            #expect(await transport.createdTopicNames == [name])
            #expect(member.channel.notices == [Self.activationNotice])
            #expect(await transport.sentMessages == [RoutedText(
                text: "ZenCODE session “project · 89abcdef” now has its own topic; messages sent here in General reach every attached session.",
                topicID: nil
            )])
            let lease = try #require(companion.activeRouteLease)
            #expect(lease == Self.topicLease(501))
            #expect(companion.sessionTopic == .init(lease: lease, name: name))
            let routes = [
                AgentTelegramRouteManifest(roomID: "default"),
                AgentTelegramRouteManifest(topicID: 501, roomID: Self.topicSessionID),
            ]
            #expect(commits.values == [routes])
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == routes)
            #expect(await companion.statusText() == Self.topicStatusText(topic: name))

            // A repeated `/telegram on` finds the topic active and reuses it.
            try await companion.attach()

            #expect(await transport.createdTopicNames == [name])
            #expect(await transport.sentMessages.count == 1)
            #expect(member.channel.notices == [Self.activationNotice, Self.activationNotice])
            #expect(companion.activeRouteLease == lease)
            #expect(companion.sessionTopic == .init(lease: lease, name: name))
            #expect(commits.values.count == 1)

            await companion.shutdown()
        }
    }

    /// A topic of the session still active in the router is reused, even
    /// with Threaded mode on: nothing is created, announced or persisted, and
    /// the status names the topic with its default name.
    @Test(.timeLimit(.minutes(1)))
    func attachReusesTheActiveSessionTopicWithoutANotice() async throws {
        let routes = [
            AgentTelegramRouteManifest(roomID: "default"),
            AgentTelegramRouteManifest(topicID: 444, roomID: Self.topicSessionID, generation: 3),
        ]
        try await Self.withSupport(telegram: Self.settings(routes: routes)) {
            let transport = CompanionTelegramTransport(
                botID: 9502, hasTopicsEnabled: true, createdTopicIDs: [501]
            )
            let commits = Recorder<[AgentTelegramRouteManifest]>()
            let member = try Self.topicMember(transport: transport, commits: commits)
            let companion = member.companion

            try await companion.attach()

            #expect(await transport.topicRequestCount == 0)
            #expect(await transport.sentMessages.isEmpty)
            #expect(member.channel.notices == [Self.activationNotice])
            let lease = try #require(companion.activeRouteLease)
            #expect(lease == Self.topicLease(444, generation: 3))
            #expect(companion.sessionTopic == .init(lease: lease, name: Self.topicSessionName))
            #expect(await companion.statusText() == Self.topicStatusText(topic: Self.topicSessionName))
            #expect(commits.values.isEmpty)

            await companion.shutdown()
        }
    }

    /// A topic that cannot be created leaves the session on the shared route,
    /// as in legacy mode: the error is recorded and presented after the
    /// activation text, nothing is announced or persisted, the status has no
    /// topic, and neither the rebind nor the detach writes anything.
    @Test(.timeLimit(.minutes(1)))
    func failedTopicCreationFallsBackToTheSharedRoute() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let transport = CompanionTelegramTransport(botID: 9503, hasTopicsEnabled: true)
            let commits = Recorder<[AgentTelegramRouteManifest]>()
            let member = try Self.topicMember(transport: transport, commits: commits)
            let companion = member.companion

            try await companion.attach()

            let description = "Telegram API error 400: \(CompanionTelegramTransport.createTopicFailure)"
            #expect(await transport.createdTopicNames == [Self.topicSessionName])
            #expect(member.channel.notices == [
                Self.activationNotice,
                .init(text: "ZenCODE: \(description)\n", channel: .failure),
            ])
            #expect(companion.controlState.lastError == description)
            #expect(companion.activeRouteLease?.key == Self.defaultRouteKey)
            #expect(companion.sessionTopic == nil)
            #expect(await transport.sentMessages.isEmpty)
            #expect(await companion.statusText() == Self.legacyStatusText)

            await companion.rebind(sessionID: "other-session", displayName: "Other")
            await companion.detach()

            #expect(await transport.topicRequestCount == 1)
            #expect(commits.values.isEmpty)
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == Self.pairedSettings.routes)
        }
    }

    /// Without Threaded mode the session uses the route every session shares,
    /// as before topics: no topic, no notice, no `Topic:` line; a message
    /// from a topic no route knows moves the link onto it as before; and
    /// neither the rebind, nor the detach, nor the shutdown writes anything.
    @Test(.timeLimit(.minutes(1)))
    func legacyModeSharesTheRouteAndWritesNothing() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let transport = CompanionTelegramTransport(botID: 9504, createdTopicIDs: [501])
            let commits = Recorder<[AgentTelegramRouteManifest]>()
            let member = try Self.topicMember(transport: transport, commits: commits)
            let companion = member.companion

            try await companion.attach()

            #expect(companion.activeRouteLease?.key == Self.defaultRouteKey)
            #expect(companion.sessionTopic == nil)
            #expect(member.channel.notices == [Self.activationNotice])
            #expect(await companion.statusText() == Self.legacyStatusText)

            #expect(await companion.handleIncomingMessage(
                Self.ownerMessage("hello", topicID: 999), isSessionGenerating: false,
                admit: { _ in .queued }
            ))
            #expect(companion.activeRouteLease?.key == Self.defaultRouteKey)
            #expect(companion.activeRouteLease?.effectiveMessageThreadID == 999)

            await companion.rebind(sessionID: "other-session", displayName: "Other")
            await companion.detach()
            try await companion.attach()
            await companion.shutdown()

            #expect(await transport.topicRequestCount == 0)
            #expect(await transport.sentMessages.isEmpty)
            #expect(commits.values.isEmpty)
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == Self.pairedSettings.routes)
        }
    }

    /// On a new or loaded session the channel rebinds the topic: its route
    /// moves to the new session with the next generation, the previous lease
    /// stops validating, the topic is renamed with the name bounded like
    /// Telegram's, and the status names it.
    @Test(.timeLimit(.minutes(1)))
    func rebindMovesTheTopicToTheNewSessionAndRenamesIt() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let transport = CompanionTelegramTransport(
                botID: 9505, hasTopicsEnabled: true, createdTopicIDs: [501]
            )
            let commits = Recorder<[AgentTelegramRouteManifest]>()
            let member = try Self.topicMember(transport: transport, commits: commits)
            let companion = member.companion
            try await companion.attach()
            let created = try #require(companion.activeRouteLease)
            let loadedSessionID = "loaded-session-fedcba9876543210"
            member.terminal.sessionID = loadedSessionID

            await companion.rebind(sessionID: loadedSessionID, displayName: "Parser refactor")

            let rebound = Self.topicLease(501, roomID: loadedSessionID, generation: 2)
            #expect(companion.activeRouteLease == rebound)
            #expect(companion.sessionTopic == .init(lease: rebound, name: "Parser refactor"))
            await #expect(throws: TerminalTelegramRouteDenial.staleGeneration) {
                try await companion.router.validate(created)
            }
            #expect(await transport.renamedTopics == [RoutedText(text: "Parser refactor", topicID: 501)])
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == [
                AgentTelegramRouteManifest(roomID: "default"),
                AgentTelegramRouteManifest(topicID: 501, roomID: loadedSessionID, generation: 2),
            ])
            #expect(commits.values.count == 2)
            #expect(await companion.statusText() == Self.topicStatusText(topic: "Parser refactor"))
            #expect(member.channel.notices == [Self.activationNotice])

            // A name beyond Telegram's limit is renamed and shown bounded.
            let long = "Session " + String(repeating: "x", count: 200)
            let bounded = TerminalTelegramAPIClient.boundedTopicName(long)
            #expect(bounded.utf16.count == 128 && long.hasPrefix(bounded))

            await companion.rebind(sessionID: loadedSessionID, displayName: long)

            #expect(companion.activeRouteLease == Self.topicLease(501, roomID: loadedSessionID, generation: 3))
            #expect(await transport.renamedTopics.last == RoutedText(text: bounded, topicID: 501))
            #expect(companion.sessionTopic?.name == bounded)
            #expect(await companion.statusText() == Self.topicStatusText(topic: bounded))

            await companion.shutdown()
        }
    }

    /// A rename Telegram refuses keeps the rebind, is recorded and presented
    /// on the primary channel like a failed creation, and leaves the topic's
    /// name as it was.
    @Test(.timeLimit(.minutes(1)))
    func failedRenameKeepsTheRebindAndTheTopicName() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let transport = CompanionTelegramTransport(
                botID: 9506, hasTopicsEnabled: true, createdTopicIDs: [501], renameTopicFails: true
            )
            let commits = Recorder<[AgentTelegramRouteManifest]>()
            let member = try Self.topicMember(transport: transport, commits: commits)
            let companion = member.companion
            try await companion.attach()
            let loadedSessionID = "loaded-session-fedcba9876543210"
            member.terminal.sessionID = loadedSessionID

            await companion.rebind(sessionID: loadedSessionID, displayName: "Parser refactor")

            let description = "Telegram API error 400: \(CompanionTelegramTransport.renameTopicFailure)"
            #expect(await transport.renamedTopics == [RoutedText(text: "Parser refactor", topicID: 501)])
            #expect(member.channel.notices == [
                Self.activationNotice,
                .init(text: "ZenCODE: \(description)\n", channel: .failure),
            ])
            #expect(companion.controlState.lastError == description)
            let rebound = Self.topicLease(501, roomID: loadedSessionID, generation: 2)
            #expect(companion.activeRouteLease == rebound)
            #expect(companion.sessionTopic == .init(lease: rebound, name: Self.topicSessionName))
            #expect(await companion.statusText() == Self.topicStatusText(topic: Self.topicSessionName))

            await companion.shutdown()
        }
    }

    /// The detach closes the topic's route and prunes the inactive routes
    /// beyond 32, the lowest topics first. Only active topics are reused, so
    /// a rebind while detached does nothing and the next attach creates and
    /// announces a new topic.
    @Test(.timeLimit(.minutes(1)))
    func detachClosesAndPrunesAndTheNextAttachCreatesANewTopic() async throws {
        try await Self.withSupport(telegram: Self.settings(routes: Self.routesBeforePruning)) {
            let transport = CompanionTelegramTransport(
                botID: 9507, hasTopicsEnabled: true, createdTopicIDs: [502]
            )
            let commits = Recorder<[AgentTelegramRouteManifest]>()
            let member = try Self.topicMember(transport: transport, commits: commits)
            let companion = member.companion
            try await companion.attach()
            #expect(companion.activeRouteLease == Self.topicLease(501))

            await companion.detach()

            // One commit closes the topic, one prunes topic 1.
            #expect(commits.values.count == 2)
            #expect(commits.values.last == Self.routesAfterPruning)
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == Self.routesAfterPruning)
            #expect(companion.sessionTopic == nil)
            #expect(companion.activeRouteLease == nil)
            #expect(member.channel.notices == [
                Self.activationNotice,
                .init(text: "Telegram remote control stopped.\n", channel: .system),
            ])

            await companion.rebind(sessionID: "other-session", displayName: "Other")

            #expect(commits.values.count == 2)
            #expect(await transport.topicRequestCount == 0)

            try await companion.attach()

            #expect(await transport.createdTopicNames == [Self.topicSessionName])
            #expect(await transport.sentMessages == [RoutedText(
                text: TelegramSessionCompanion.generalTopicNoticeText(topicName: Self.topicSessionName),
                topicID: nil
            )])
            #expect(companion.activeRouteLease == Self.topicLease(502))

            await companion.shutdown()
        }
    }

    /// The shutdown closes and prunes like the detach, because the terminal
    /// always ends through it, and presents nothing.
    @Test(.timeLimit(.minutes(1)))
    func shutdownClosesTheTopicAndPrunesTheInactiveRoutes() async throws {
        try await Self.withSupport(telegram: Self.settings(routes: Self.routesBeforePruning)) {
            let transport = CompanionTelegramTransport(botID: 9508, hasTopicsEnabled: true)
            let commits = Recorder<[AgentTelegramRouteManifest]>()
            let member = try Self.topicMember(transport: transport, commits: commits)
            let companion = member.companion
            try await companion.attach()
            #expect(companion.activeRouteLease == Self.topicLease(501))
            member.channel.clear()

            await companion.shutdown()

            #expect(commits.values.count == 2)
            #expect(commits.values.last == Self.routesAfterPruning)
            #expect(AgentSettingsManifestStore.load()?.telegram?.routes == Self.routesAfterPruning)
            #expect(companion.sessionTopic == nil)
            #expect(member.channel.notices.isEmpty)
            #expect(await transport.topicRequestCount == 0)
        }
    }

    // MARK: - Support

    private static let unauthorizedBody = Data(
        #"{"ok":false,"error_code":401,"description":"Unauthorized"}"#.utf8
    )

    private static func getMeBody(botID: Int64) -> Data {
        Data(#"{"ok":true,"result":{"id":\#(botID),"is_bot":true,"first_name":"ZenCODE","username":"zencode_bot"}}"#.utf8)
    }

    /// deleteWebhook succeeds and getMe is rejected, so `start()` fails
    /// before polling.
    private static func unauthorizedGetMeTransport() -> ScriptedTelegramTransport {
        ScriptedTelegramTransport(responses: [
            (200, Data(#"{"ok":true,"result":true}"#.utf8)),
            (401, unauthorizedBody),
        ])
    }

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

    /// Runs `body` on the chat-session actor with a fresh support directory
    /// holding `telegram` (and `voice`) as its settings, then removes the
    /// directory.
    private static func withSupport(
        telegram: AgentTelegramSettingsManifest?,
        voice: AgentVoiceSettingsManifest? = nil,
        _ body: @escaping @Sendable @ChatSessionActor () async throws -> Void
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "zencode-telegram-companion-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(models: [], telegram: telegram, voice: voice),
            to: directory.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        )
        try await AppStorageDirectory.withSupportDirectoryURL(directory) {
            try await body()
        }
    }

    /// A terminal chat whose Telegram service uses `transport` on a private
    /// dispatcher, whose writes are captured instead of reaching the real
    /// terminal, and which reads its interactive-only Telegram commands.
    @ChatSessionActor
    private static func makeTerminal(
        transport: any TelegramHTTPTransport,
        permissionAuthorizer: LocalExecPermissionAuthorizer? = nil,
        sessionRunner: AgentCoreSessionRunner? = nil
    ) throws -> TerminalChat {
        TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true)
            ),
            stdinIsTerminal: true,
            sessionRunner: sessionRunner ?? AgentCoreSessionRunner(taskGraphStore: nil),
            permissionAuthorizer: permissionAuthorizer,
            telegramTransportFactory: { transport },
            renderCoordinator: TerminalChatRenderCoordinator(
                stdinIsTerminal: false,
                standardOutput: nil,
                standardError: nil,
                standardOutputIsTerminal: false,
                standardErrorIsTerminal: false,
                cursorTopology: .separate,
                capturesWrites: true,
                streamingFlushDelay: nil,
                columnWidthProvider: { 100 }
            )
        )
    }

    /// A companion of `terminal`'s session with its own router, read from
    /// the settings like the terminal's, unless `router` is given, and its
    /// own control service on a private dispatcher.
    @ChatSessionActor
    private static func makeCompanion(
        on terminal: TerminalChat,
        transport: any TelegramHTTPTransport,
        channel: any TelegramCompanionChannel,
        attachments: TelegramCompanionAttachments,
        configuration: TelegramSessionCompanion.Configuration = .init(
            primaryChannelDescription: "TUI", policy: .full
        ),
        router: TerminalTelegramSessionRouter? = nil
    ) -> TelegramSessionCompanion {
        let settings = AgentSettingsManifestStore.load()?.telegram
        return TelegramSessionCompanion(
            controller: terminal.chatSession,
            sessionRunner: terminal.sessionRunner,
            router: router ?? TerminalTelegramSessionRouter(
                linkedChatID: settings?.linkedChatID,
                ownerUserID: settings?.ownerUserID,
                routes: settings?.routes ?? []
            ),
            controlService: TerminalTelegramControlService(transportFactory: { transport }),
            channel: channel,
            configuration: configuration,
            attachments: attachments
        )
    }

    /// What `terminal` writes while `operation` runs, one entry per write.
    @ChatSessionActor
    private static func capturing(
        _ terminal: TerminalChat,
        _ operation: () async -> Void
    ) async -> [String] {
        terminal.telegramImmediateCommandOutput = []
        await operation()
        let writes = terminal.telegramImmediateCommandOutput ?? []
        terminal.telegramImmediateCommandOutput = nil
        return writes
    }

    /// Polls `condition` for up to five seconds.
    @ChatSessionActor
    private static func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Topics support

    /// The session of the topic tests; its last eight characters name its
    /// topic.
    private static let topicSessionID = "topic-session-0123456789abcdef"

    /// The default topic name of ``topicSessionID`` in `/tmp/project`.
    private static let topicSessionName = "project · 89abcdef"

    /// What the companion presents when the link is active.
    @ChatSessionActor
    private static var activationNotice: ScriptedCompanionChannel.Notice {
        .init(text: "Telegram remote control is active.\nLinked chat: Test\n", channel: .system)
    }

    /// `/telegram status` of an active link without a topic of its own.
    private static let legacyStatusText =
        "Telegram: Active as @zencode_bot\nBot: @zencode_bot\nLinked chat: Test"

    /// `/telegram status` of an active link in topic mode.
    private static func topicStatusText(topic: String) -> String {
        legacyStatusText + "\nTopic: \(topic)"
    }

    /// The lease of topic `topicID` bound to `roomID` in chat 42.
    private static func topicLease(
        _ topicID: Int, roomID: String = topicSessionID, generation: UInt64 = 1
    ) -> TerminalTelegramRouteLease {
        TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, topicID: topicID, roomID: roomID),
            generation: generation, effectiveMessageThreadID: topicID
        )
    }

    /// ``pairedSettings`` with `routes`.
    private static func settings(routes: [AgentTelegramRouteManifest]) -> AgentTelegramSettingsManifest {
        AgentTelegramSettingsManifest(
            enabled: true, botToken: "123456:ABCDEF", linkedChatID: 42,
            linkedChatTitle: "Test", ownerUserID: 7, routes: routes
        )
    }

    /// The routes of the pruning tests: the shared route, 32 closed topics of
    /// earlier sessions, and the session's active topic 501.
    private static let routesBeforePruning =
        [AgentTelegramRouteManifest(roomID: "default")]
        + closedTopics(1...32)
        + [AgentTelegramRouteManifest(topicID: 501, roomID: topicSessionID)]

    /// Once topic 501 is closed 33 routes are inactive, and the lowest
    /// topic, 1, is pruned.
    private static let routesAfterPruning =
        [AgentTelegramRouteManifest(roomID: "default")]
        + closedTopics(2...32)
        + [AgentTelegramRouteManifest(
            topicID: 501, roomID: topicSessionID, lifecycle: .closed, generation: 2
        )]

    private static func closedTopics(_ topicIDs: ClosedRange<Int>) -> [AgentTelegramRouteManifest] {
        topicIDs.map {
            AgentTelegramRouteManifest(
                topicID: $0, roomID: "earlier-session-\($0)", lifecycle: .closed, generation: 2
            )
        }
    }

    /// A companion of a terminal session ``topicSessionID`` on `transport`,
    /// whose router is read from the settings and persists every commit to
    /// them, as the terminal's does, recording it in `commits`.
    @ChatSessionActor
    private static func topicMember(
        transport: CompanionTelegramTransport,
        commits: Recorder<[AgentTelegramRouteManifest]>
    ) throws -> TopicMember {
        let terminal = try makeTerminal(transport: CompanionTelegramTransport(botID: 1))
        terminal.sessionID = topicSessionID
        let channel = ScriptedCompanionChannel()
        let settings = AgentSettingsManifestStore.load()?.telegram
        let router = TerminalTelegramSessionRouter(
            linkedChatID: settings?.linkedChatID,
            ownerUserID: settings?.ownerUserID,
            routes: settings?.routes ?? [],
            persist: { ownerUserID, routes in
                try AgentSettingsManifestStore.saveTelegramRoutes(routes, ownerUserID: ownerUserID)
                commits.append(routes)
            }
        )
        let companion = makeCompanion(
            on: terminal, transport: transport, channel: channel,
            attachments: TelegramCompanionAttachments(), router: router
        )
        return TopicMember(terminal: terminal, channel: channel, companion: companion)
    }

    // MARK: - Ingress support

    /// The receipt the picker seams answer with.
    private static let pickerReceipt = 91

    private static let voiceNote = TerminalTelegramVoiceAttachment(
        fileID: "voice-1", fileUniqueID: nil, duration: 2, mimeType: "audio/ogg", fileSize: 4
    )

    private static let patchedSummary = TurnFileChangeSummary(entries: [
        .init(
            path: "Value.swift", additions: 1, deletions: 1, status: .modified,
            isBinary: false, existedBefore: true, beforeDataBase64: nil,
            patch: "--- a/Value.swift\n+++ b/Value.swift\n@@ -1 +1 @@\n-let value = 1\n+let value = 2"
        ),
        .init(
            path: "Added.swift", additions: 3, deletions: 0, status: .added,
            isBinary: false, existedBefore: false, beforeDataBase64: nil, patch: nil
        ),
    ])

    /// A terminal of session `room` and a companion of the same session,
    /// each linked by hand to chat 42 on the route of `room`, the way the
    /// round-trip tests link a terminal: no control service is started, and
    /// the system messages and picker cards of each are recorded through
    /// the seams instead of being sent.
    @ChatSessionActor
    private static func handLinked(
        room: String,
        runner: AgentCoreSessionRunner? = nil,
        channel: any TelegramCompanionChannel,
        configuration: TelegramSessionCompanion.Configuration = .init(
            primaryChannelDescription: "TUI", policy: .full
        )
    ) async throws -> HandLinkedPair {
        let terminal = try makeTerminal(
            transport: CompanionTelegramTransport(botID: 1), sessionRunner: runner
        )
        terminal.sessionID = room
        let route = AgentTelegramRouteManifest(roomID: room, generation: 1)
        let lease = TerminalTelegramRouteLease(
            key: .init(chatID: 42, userID: 7, roomID: room), generation: 1
        )
        let state = TerminalTelegramControlState(
            isConfigured: true, isActive: true, statusText: "Active", botUsername: "zencode_bot",
            lastError: nil, lastMessagePreview: nil, wireLifecycleEpoch: UUID()
        )
        await terminal.telegramSessionRouter.refresh(linkedChatID: 42, ownerUserID: 7, routes: [route])
        terminal.telegramLinkedChatID = 42
        terminal.telegramControlState = state
        terminal.telegramActiveRouteLease = lease

        let companionTransport = CompanionTelegramTransport(botID: 2)
        let companion = makeCompanion(
            on: terminal, transport: companionTransport, channel: channel,
            attachments: TelegramCompanionAttachments(), configuration: configuration
        )
        await companion.router.refresh(linkedChatID: 42, ownerUserID: 7, routes: [route])
        companion.linkedChatID = 42
        companion.linkedUserID = 7
        companion.controlState = state
        companion.activeRouteLease = lease

        let pair = HandLinkedPair(
            terminal: terminal, companion: companion, lease: lease,
            companionTransport: companionTransport
        )
        let receipt = pickerReceipt
        let (terminalTexts, companionTexts) = (pair.terminalTexts, pair.companionTexts)
        let (terminalCards, companionCards) = (pair.terminalCards, pair.companionCards)
        terminal.onTelegramSystemMessage = { text, _ in
            terminalTexts.append(text)
            return true
        }
        companion.onTelegramSystemMessage = { text, _ in
            companionTexts.append(text)
            return true
        }
        terminal.onTelegramMentionPickerMessage = { text, chatID, markup in
            terminalCards.append(PickerCard(text: text, chatID: chatID, markup: markup))
            return receipt
        }
        companion.onTelegramMentionPickerMessage = { text, chatID, markup in
            companionCards.append(PickerCard(text: text, chatID: chatID, markup: markup))
            return receipt
        }
        return pair
    }

    /// A session runner whose backend holds a live shared chat for `room`,
    /// with its coordinator and one active agent, `agent-1`, named
    /// "planner".
    private static func plannerRunner(room: String) async throws -> AgentCoreSessionRunner {
        let backend = SharedChatRuntimeBackend()
        let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
        let configuration = AgentCoreSessionConfiguration(
            sessionID: room, modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil, cacheKey: nil, history: [], allowedToolNames: []
        )
        try await runner.createSession(configuration: configuration)
        _ = try await runner.preloadModel(configuration: configuration, onEvent: { _ in })
        await backend.enqueueCoordinatorMessage(text: "ready", roomID: room)
        return runner
    }

    /// A relay whose cards `log` records instead of sending.
    private static func recordingRelay(_ log: RelayCardLog) -> TerminalTelegramSharedChatRelay {
        TerminalTelegramSharedChatRelay(
            validateLease: { _ in true },
            send: { text, _, _ in await log.record(text) }
        )
    }

    /// A message of an agent of `room` to the operator.
    private static func agentMessage(
        room: String, senderID: String, name: String, text: String
    ) -> AgentSharedChat.Message {
        AgentSharedChat.Message(
            roomID: room,
            sender: AgentSharedChat.Participant(id: senderID, name: name, kind: .agent),
            recipientIDs: [AgentSharedChat.operatorID(for: room)],
            text: text
        )
    }

    /// A message of the owner in chat 42, quoting `replyTo` when given.
    private static func incoming(_ text: String?, replyTo: Int?) -> TerminalTelegramIncomingMessage {
        TerminalTelegramIncomingMessage(
            chatID: 42, userID: 7, text: text, voice: nil, messageID: 77,
            chatTitle: "Test", username: "operator", replyToMessageID: replyTo
        )
    }

    /// A message in chat 42 of `userID` (the owner by default), of any of
    /// the shapes the ingress reads.
    private static func ownerMessage(
        _ text: String?,
        topicID: Int? = nil,
        userID: Int64 = 7,
        chatKind: TerminalTelegramChatKind = .privateChat,
        replyTo: Int? = nil,
        voice: TerminalTelegramVoiceAttachment? = nil,
        attachment: TerminalTelegramInboundAttachment? = nil,
        callbackData: String? = nil,
        stoppedDraftID: Int? = nil
    ) -> TerminalTelegramIncomingMessage {
        TerminalTelegramIncomingMessage(
            chatID: 42, userID: userID, topicID: topicID, chatKind: chatKind,
            text: text, voice: voice, messageID: 78, chatTitle: "Test", username: "operator",
            replyToMessageID: replyTo,
            callbackQueryID: callbackData.map { _ in "callback-1" }, callbackData: callbackData,
            stoppedMessageGenerationDraftID: stoppedDraftID, attachment: attachment
        )
    }

    /// A document the ingress admits.
    private static let noteAttachment = TerminalTelegramInboundAttachment(
        fileID: "note-1", fileUniqueID: nil, kind: .document,
        mimeType: "text/plain", fileSize: 4, fileName: "note.txt", messageID: 78
    )

    /// What the terminal's `submittedTelegramLineAction` answered, in words
    /// the companion's answer shares (see the other `describe`).
    private static func describe(_ action: TerminalSubmittedLineAction) -> String {
        switch action {
        case .continueChat: "handled"
        case let .runPrompt(prompt): "prompt: \(prompt)"
        case let .runHiddenPrompt(prompt, purpose): "turn \(purpose): \(prompt)"
        case .exitChat, .requestSetup, .prefillPrompt: "other"
        }
    }

    /// What the companion's `lineAction` answered, in the terminal's terms:
    /// a command that starts no turn continues the chat, a turn the command
    /// built is a hidden prompt.
    private static func describe(_ action: TelegramCompanionLineAction) -> String {
        switch action {
        case .handled: "handled"
        case let .runPrompt(prompt): "prompt: \(prompt)"
        case let .commandOutcome(outcome):
            switch outcome.action {
            case .none, .channelCommand: "handled"
            case let .startTurn(prompt, purpose, locksResponseLanguage):
                locksResponseLanguage ? "prompt: \(prompt)" : "turn \(purpose): \(prompt)"
            }
        }
    }

    /// A companion of session `room` linked by hand to chat 42 on bot
    /// `botID` and registered under it in `attachments`. Its router holds the
    /// route every session shares (`default`, no topic) and the session's
    /// topic `topicID`; its system messages are recorded with their topic.
    @ChatSessionActor
    private static func sharedBotMember(
        room: String,
        topicID: Int,
        botID: Int64,
        attachments: TelegramCompanionAttachments
    ) async throws -> SharedBotMember {
        let terminal = try makeTerminal(transport: CompanionTelegramTransport(botID: botID))
        terminal.sessionID = room
        let channel = IngressCompanionChannel()
        let member = SharedBotMember(
            terminal: terminal,
            channel: channel,
            companion: makeCompanion(
                on: terminal, transport: CompanionTelegramTransport(botID: botID),
                channel: channel, attachments: attachments
            )
        )
        let companion = member.companion
        await companion.router.refresh(linkedChatID: 42, ownerUserID: 7, routes: [
            AgentTelegramRouteManifest(roomID: "default", generation: 1),
            AgentTelegramRouteManifest(topicID: topicID, roomID: room, generation: 1),
        ])
        companion.linkedChatID = 42
        companion.linkedUserID = 7
        companion.controlState = TerminalTelegramControlState(
            isConfigured: true, isActive: true, statusText: "Active", botUsername: "zencode_bot",
            lastError: nil, lastMessagePreview: nil, wireLifecycleEpoch: UUID(), botID: botID
        )
        companion.activeRouteLease = try await companion.router.resolve(
            chatID: 42, userID: 7, topicID: nil
        )
        attachments.register(companion, botID: botID)
        let texts = member.texts
        companion.onTelegramRoutedSystemMessage = { text, _, topicID in
            texts.append(RoutedText(text: text, topicID: topicID))
            return true
        }
        return member
    }

    /// Asks `companion`'s broker to authorize a deletion on `lease`, and
    /// returns the decision in flight with the request ID the chat was sent.
    @ChatSessionActor
    private static func pendingPermission(
        on companion: TelegramSessionCompanion,
        lease: TerminalTelegramRouteLease
    ) async throws -> (decision: Task<TerminalTelegramPermissionOutcome, Never>, requestID: String) {
        let (requests, continuation) = AsyncStream.makeStream(of: String.self)
        let broker = companion.permissionBroker
        let request = deleteRequest()
        let decision = Task {
            await broker.authorize(request, lease: lease) { message in
                continuation.yield(message)
                return true
            }
        }
        var iterator = requests.makeAsyncIterator()
        let message = try #require(await iterator.next())
        return (decision, try #require(permissionRequestID(in: message)))
    }

    /// A staging directory of the test's own, not created yet.
    private static func temporaryStagingDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "zencode-companion-artifacts-\(UUID().uuidString)", isDirectory: true
        )
    }

    private static func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    /// The offer of the Send button in a `sendMessage` body.
    private static func consentOfferID(in body: String) -> String? {
        let marker = TerminalTelegramArtifactConsentKeyboard.callbackPrefix + "send:"
        guard let range = body.range(of: marker) else { return nil }
        let offerID = body[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" }
        return offerID.isEmpty ? nil : String(offerID)
    }

    // MARK: - Turn support

    private static var toolCall: DirectAgentToolCall {
        DirectAgentToolCall(id: "call-1", name: "local.readFile", argumentsObject: [:], argumentsJSON: "{}")
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

    /// The summary text the terminal mirrors for `summary`.
    private static func summaryText(_ summary: TurnFileChangeSummary) -> String {
        TurnFileChangeSummaryPresentation.text(summary, includesCommandHint: true)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The terminal's generation result for a turn that ended with `outcome`.
    private static func terminalResult(
        for outcome: TelegramSessionCompanion.Outcome,
        summary: TurnFileChangeSummary?,
        origin: TerminalPromptOrigin
    ) -> TerminalChatGenerationResult {
        switch outcome {
        case let .completed(text):
            .success(TerminalChatGenerationSuccess(
                response: DirectAgentResponse(
                    text: text, stopReason: "end_turn", modelID: "remote-community/test"
                ),
                origin: origin,
                fileChangeSummary: summary,
                automaticallyCompletedPlan: nil,
                finalAssistantContent: text
            ))
        case let .failed(message):
            .failure(TerminalChatGenerationFailure(
                message: message, isCancellation: false, origin: origin, fileChangeSummary: summary
            ))
        case .cancelled:
            .failure(TerminalChatGenerationFailure(
                message: "cancelled", isCancellation: true, origin: origin, fileChangeSummary: summary
            ))
        }
    }

    /// A terminal chat linked to Telegram with `/telegram on`, and its
    /// validated route lease.
    @ChatSessionActor
    private static func linkedTerminal(
        botID: Int64,
        permissionAuthorizer: LocalExecPermissionAuthorizer? = nil
    ) async throws -> (TerminalChat, TerminalTelegramRouteLease) {
        let terminal = try makeTerminal(
            transport: CompanionTelegramTransport(botID: botID),
            permissionAuthorizer: permissionAuthorizer
        )
        await terminal.startTelegramControl()
        return (terminal, try #require(terminal.telegramActiveRouteLease))
    }

    /// An attached companion of `terminal`'s session, and its validated
    /// route lease. The activation notice is cleared from `channel`.
    @ChatSessionActor
    private static func linkedCompanion(
        on terminal: TerminalChat,
        botID: Int64,
        channel: TurnCompanionChannel,
        configuration: TelegramSessionCompanion.Configuration = .init(
            primaryChannelDescription: "TUI", policy: .full
        ),
        transport: CompanionTelegramTransport? = nil
    ) async throws -> (TelegramSessionCompanion, TerminalTelegramRouteLease) {
        let companion = makeCompanion(
            on: terminal, transport: transport ?? CompanionTelegramTransport(botID: botID),
            channel: channel, attachments: TelegramCompanionAttachments(),
            configuration: configuration
        )
        try await companion.attach()
        channel.clear()
        return (companion, try #require(companion.activeRouteLease))
    }

    /// The presenter a turn of `controller` starting now presents on, with
    /// a primary that renders nothing: the companions attached now, in order
    /// (see ``ChatSessionController/effectivePresenter(for:)``).
    @ChatSessionActor
    private static func turnPresenter(of controller: ChatSessionController) -> ChatFanOutPresenter {
        ChatFanOutPresenter(primary: SilentChatPresenter(), companions: controller.companionPresenters)
    }

    /// A reporter for chat 42 whose messages `log` records; each delivery
    /// reports `delivers`.
    private static func logReporter(
        _ log: TurnMessageLog, delivers: Bool
    ) -> TerminalTelegramTurnProgressReporter {
        TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await log.append(message)
            return delivers
        }
    }

    /// Replaces the reporter of `companion`'s turn with one that records
    /// into `log`.
    @ChatSessionActor
    @discardableResult
    private static func installLog(
        _ log: TurnMessageLog, on companion: TelegramSessionCompanion, delivers: Bool = true
    ) async -> TerminalTelegramTurnProgressReporter {
        await companion.activeProgressReporter?.revokeAndWait()
        let reporter = logReporter(log, delivers: delivers)
        companion.activeProgressReporter = reporter
        return reporter
    }

    /// Replaces the reporter of `terminal`'s turn with one that records into
    /// `log`.
    @ChatSessionActor
    @discardableResult
    private static func installLog(
        _ log: TurnMessageLog, on terminal: TerminalChat, delivers: Bool = true
    ) async -> TerminalTelegramTurnProgressReporter {
        await terminal.activeTelegramProgressReporter?.revokeAndWait()
        let reporter = logReporter(log, delivers: delivers)
        terminal.activeTelegramProgressReporter = reporter
        return reporter
    }
}

/// A primary channel that records what the companion presents and asks.
@ChatSessionActor
private final class ScriptedCompanionChannel: TelegramCompanionChannel {
    struct Notice: Equatable {
        let text: String
        let channel: ChatSessionNoticeChannel
    }

    let primaryChannelDescription = "TUI"
    private(set) var notices: [Notice] = []

    var noticeTexts: [String] {
        notices.map(\.text)
    }

    func clear() {
        notices = []
    }

    func commandContext() -> ChatCommandContext {
        []
    }

    func presentCompanionNotice(_ text: String, channel: ChatSessionNoticeChannel) async {
        notices.append(Notice(text: text, channel: channel))
    }

    func enqueueTelegramPrompt(
        _ text: String,
        lease: TerminalTelegramRouteLease,
        mode: ChatQueuedPromptMode
    ) async -> TelegramPromptAdmission {
        .refused
    }

    func telegramRouteWasInvalidated(_ lease: TerminalTelegramRouteLease) async {}
}

/// A Bot API double routed by method: getMe reports `botID` and, when asked,
/// Threaded mode (`has_topics_enabled`), getUpdates waits until it is
/// cancelled, sendMessage records its text and its topic,
/// sendRichMessageDraft records its `can_stop`, createForumTopic answers
/// with the next of `createdTopicIDs` (and fails once they are used up), and
/// editForumTopic records the rename (or fails with `renameTopicFails`).
private actor CompanionTelegramTransport: TelegramHTTPTransport {
    /// The description of a failed `createForumTopic`.
    static let createTopicFailure = "Bad Request: not enough rights to create a topic"
    /// The description of a failed `editForumTopic`.
    static let renameTopicFailure = "Bad Request: not enough rights to manage topics"

    private let botID: Int64
    private let sendMessageFails: Bool
    private let hasTopicsEnabled: Bool
    private var createdTopicIDs: [Int]
    private let renameTopicFails: Bool
    private var getMeFails = false
    private(set) var requestCount = 0
    private(set) var sentTexts: [String] = []
    /// The raw bodies of the `sendMessage` requests, reply markup included.
    private(set) var sentBodies: [String] = []
    /// The `sendMessage` texts, with the topic each was sent to.
    private(set) var sentMessages: [RoutedText] = []
    /// The names `createForumTopic` was asked for, failed requests included.
    private(set) var createdTopicNames: [String] = []
    /// The renames `editForumTopic` was asked for: the name and the topic.
    private(set) var renamedTopics: [RoutedText] = []
    private var draftCanStops: [Bool] = []
    private var draftWaiters: [CheckedContinuation<Bool, Never>] = []

    init(
        botID: Int64,
        sendMessageFails: Bool = false,
        hasTopicsEnabled: Bool = false,
        createdTopicIDs: [Int] = [],
        renameTopicFails: Bool = false
    ) {
        self.botID = botID
        self.sendMessageFails = sendMessageFails
        self.hasTopicsEnabled = hasTopicsEnabled
        self.createdTopicIDs = createdTopicIDs
        self.renameTopicFails = renameTopicFails
    }

    /// How many `createForumTopic` and `editForumTopic` requests arrived.
    var topicRequestCount: Int {
        createdTopicNames.count + renamedTopics.count
    }

    func setGetMeFails(_ fails: Bool) {
        getMeFails = fails
    }

    /// The `can_stop` of the first streamed draft, once one is sent.
    func firstDraftCanStop() async -> Bool {
        if let first = draftCanStops.first {
            return first
        }
        return await withCheckedContinuation { draftWaiters.append($0) }
    }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        requestCount += 1
        switch url.lastPathComponent {
        case "getMe":
            guard !getMeFails else {
                return (401, Data(#"{"ok":false,"error_code":401,"description":"Unauthorized"}"#.utf8))
            }
            let topics = hasTopicsEnabled ? #","has_topics_enabled":true"# : ""
            return (200, Data(
                #"{"ok":true,"result":{"id":\#(botID),"is_bot":true,"first_name":"ZenCODE","username":"zencode_bot"\#(topics)}}"#.utf8
            ))
        case "getUpdates":
            try await Task.sleep(for: .seconds(60))
            throw CancellationError()
        case "sendMessage":
            guard !sendMessageFails else {
                return (400, Data(#"{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}"#.utf8))
            }
            let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            sentTexts.append(object?["text"] as? String ?? "")
            sentBodies.append(body.map { String(decoding: $0, as: UTF8.self) } ?? "")
            sentMessages.append(RoutedText(
                text: object?["text"] as? String ?? "",
                topicID: object?["message_thread_id"] as? Int
            ))
            return (200, Data(#"{"ok":true,"result":{"message_id":9,"chat":{"id":42,"type":"private"},"date":0}}"#.utf8))
        case "createForumTopic":
            let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let name = object?["name"] as? String ?? ""
            createdTopicNames.append(name)
            guard !createdTopicIDs.isEmpty else {
                return (400, Data(#"{"ok":false,"error_code":400,"description":"\#(Self.createTopicFailure)"}"#.utf8))
            }
            let topic: [String: Any] = [
                "message_thread_id": createdTopicIDs.removeFirst(), "name": name, "icon_color": 7_322_096,
            ]
            let result = try JSONSerialization.data(withJSONObject: ["ok": true, "result": topic])
            return (200, result)
        case "editForumTopic":
            let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            renamedTopics.append(RoutedText(
                text: object?["name"] as? String ?? "",
                topicID: object?["message_thread_id"] as? Int
            ))
            guard !renameTopicFails else {
                return (400, Data(#"{"ok":false,"error_code":400,"description":"\#(Self.renameTopicFailure)"}"#.utf8))
            }
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        case "sendRichMessageDraft":
            let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let canStop = object?["can_stop"] as? Bool ?? true
            draftCanStops.append(canStop)
            let waiters = draftWaiters
            draftWaiters = []
            for waiter in waiters {
                waiter.resume(returning: canStop)
            }
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        default:
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        }
    }
}

/// Values appended from `@Sendable` seams, read back by the test.
private final class Recorder<Element: Sendable>: Sendable {
    private let storage = Mutex<[Element]>([])

    func append(_ element: Element) {
        storage.withLock { $0.append(element) }
    }

    var values: [Element] {
        storage.withLock { $0 }
    }
}

/// A primary presenter that renders nothing, so a fan-out reaches only the
/// companions.
private struct SilentChatPresenter: ChatSessionPresenter {}

/// A terminal and a companion of its session, linked by hand (see
/// `handLinked`), with what each sent through its seams.
private struct HandLinkedPair {
    let terminal: TerminalChat
    let companion: TelegramSessionCompanion
    let lease: TerminalTelegramRouteLease
    /// The companion's transport, which nothing should reach.
    let companionTransport: CompanionTelegramTransport
    let terminalTexts = Recorder<String>()
    let companionTexts = Recorder<String>()
    let terminalCards = Recorder<PickerCard>()
    let companionCards = Recorder<PickerCard>()
}

/// A message with a reply markup, as a picker seam receives it.
private struct PickerCard: Equatable, Sendable {
    let text: String
    let chatID: Int64
    let markup: TerminalTelegramReplyMarkup
}

/// A system message with the topic it was sent to.
private struct RoutedText: Equatable, Sendable {
    let text: String
    let topicID: Int?
}

/// A companion of the topic tests (see `topicMember`), with the terminal
/// whose session it follows and the channel that records its notices.
private struct TopicMember {
    let terminal: TerminalChat
    let channel: ScriptedCompanionChannel
    let companion: TelegramSessionCompanion
}

/// A companion linked by hand to a bot it shares with other companions
/// (see `sharedBotMember`), with the terminal and the channel it needs and
/// the system messages it sent.
private struct SharedBotMember {
    let terminal: TerminalChat
    let channel: IngressCompanionChannel
    let companion: TelegramSessionCompanion
    let texts = Recorder<RoutedText>()
}

/// A primary channel for the ingress tests: it records the companion's
/// notices, the prompts it is asked to queue, and the shared-chat changes,
/// and answers each prompt with ``admission``.
@ChatSessionActor
private final class IngressCompanionChannel: TelegramCompanionChannel {
    struct Notice: Equatable {
        let text: String
        let channel: ChatSessionNoticeChannel
    }

    struct Prompt: Equatable {
        let text: String
        let lease: TerminalTelegramRouteLease
        let mode: ChatQueuedPromptMode
    }

    let primaryChannelDescription = "TUI"
    var admission = TelegramPromptAdmission.queued
    /// What ``isSessionGenerating()`` answers.
    var isGenerating = false
    private(set) var notices: [Notice] = []
    private(set) var prompts: [Prompt] = []
    private(set) var sharedChatChangeCount = 0

    func clear() {
        notices = []
    }

    func commandContext() -> ChatCommandContext {
        []
    }

    func isSessionGenerating() -> Bool {
        isGenerating
    }

    func presentCompanionNotice(_ text: String, channel: ChatSessionNoticeChannel) async {
        notices.append(Notice(text: text, channel: channel))
    }

    func enqueueTelegramPrompt(
        _ text: String,
        lease: TerminalTelegramRouteLease,
        mode: ChatQueuedPromptMode
    ) async -> TelegramPromptAdmission {
        prompts.append(Prompt(text: text, lease: lease, mode: mode))
        return admission
    }

    func telegramRouteWasInvalidated(_ lease: TerminalTelegramRouteLease) async {}

    func sharedChatPanelDidChange() async {
        sharedChatChangeCount += 1
    }
}

/// The cards a test relay sent, each with the receipt it was given.
private actor RelayCardLog {
    private(set) var texts: [String] = []
    private(set) var receipts: [Int] = []

    func record(_ text: String) -> Int {
        let receipt = 9_001 + texts.count
        texts.append(text)
        receipts.append(receipt)
        return receipt
    }
}

/// A primary channel for the turn tests: it records the companion's notices
/// and the routes reported invalid, and runs the hooks a test gives its
/// overview barrier and its route invalidation.
@ChatSessionActor
private final class TurnCompanionChannel: TelegramCompanionChannel {
    struct Notice: Equatable {
        let text: String
        let channel: ChatSessionNoticeChannel
    }

    let primaryChannelDescription = "TUI"
    private(set) var notices: [Notice] = []
    private(set) var barrierCount = 0
    private(set) var invalidatedLeases: [TerminalTelegramRouteLease] = []
    /// Runs inside ``overviewMirrorBarrier()``.
    var onOverviewMirrorBarrier: (@ChatSessionActor () async -> Void)?
    /// Runs inside ``telegramRouteWasInvalidated(_:)``, before the lease is
    /// recorded.
    var onRouteInvalidated: (@ChatSessionActor (TerminalTelegramRouteLease) async -> Void)?
    private var invalidationWaiters: [CheckedContinuation<TerminalTelegramRouteLease, Never>] = []

    var noticeTexts: [String] {
        notices.map(\.text)
    }

    func clear() {
        notices = []
    }

    func commandContext() -> ChatCommandContext {
        []
    }

    func presentCompanionNotice(_ text: String, channel: ChatSessionNoticeChannel) async {
        notices.append(Notice(text: text, channel: channel))
    }

    func enqueueTelegramPrompt(
        _ text: String,
        lease: TerminalTelegramRouteLease,
        mode: ChatQueuedPromptMode
    ) async -> TelegramPromptAdmission {
        .refused
    }

    func telegramRouteWasInvalidated(_ lease: TerminalTelegramRouteLease) async {
        await onRouteInvalidated?(lease)
        invalidatedLeases.append(lease)
        let waiters = invalidationWaiters
        invalidationWaiters = []
        for waiter in waiters {
            waiter.resume(returning: lease)
        }
    }

    func overviewMirrorBarrier() async {
        barrierCount += 1
        await onOverviewMirrorBarrier?()
    }

    /// The first route reported invalid, once one is.
    func nextInvalidatedLease() async -> TerminalTelegramRouteLease {
        if let first = invalidatedLeases.first {
            return first
        }
        return await withCheckedContinuation { invalidationWaiters.append($0) }
    }
}

/// The messages a test reporter delivered, in order.
private actor TurnMessageLog {
    private(set) var messages: [String] = []
    private var waiters: [(count: Int, continuation: CheckedContinuation<[String], Never>)] = []

    func append(_ message: String) {
        messages.append(message)
        let ready = waiters.filter { $0.count <= messages.count }
        waiters.removeAll { $0.count <= messages.count }
        for waiter in ready {
            waiter.continuation.resume(returning: messages)
        }
    }

    /// The messages, once there are at least `count` of them.
    func waitForMessages(count: Int) async -> [String] {
        guard messages.count < count else {
            return messages
        }
        return await withCheckedContinuation { waiters.append((count, $0)) }
    }
}

/// The operator's keys for the terminal's consent dialog, answered by the
/// test. A read waits for the next answer; `nil` is end of input, and a
/// cancelled read returns `nil`, as the terminal's reader does.
private actor ConsentKeys {
    private var answers: [String?] = []
    private var waiter: CheckedContinuation<String?, Never>?
    private(set) var readCount = 0

    nonisolated var reader: ConsentKeyReader {
        { [self] _ in await self.read() }
    }

    func answer(_ key: String?) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: key)
        } else {
            answers.append(key)
        }
    }

    private func read() async -> String? {
        readCount += 1
        if !answers.isEmpty {
            return answers.removeFirst()
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: nil)
                } else {
                    waiter = continuation
                }
            }
        } onCancel: {
            Task { await self.cancelRead() }
        }
    }

    private func cancelRead() {
        let waiter = waiter
        self.waiter = nil
        waiter?.resume(returning: nil)
    }
}

// MARK: - Consent location

/// Where the primary channel asks for a permission is named in the consent
/// texts (``TelegramSessionCompanion/Configuration/consentLocationDescription``).
extension TelegramSessionCompanionTests {
    /// Parity: the terminal's companion keeps the terminal's texts, byte for
    /// byte, as they were before the location was configurable.
    @Test
    func terminalConsentTextsAreTheTerminalsByteForByte() async throws {
        try await Self.withSupport(telegram: Self.pairedSettings) {
            let terminal = try Self.makeTerminal(transport: CompanionTelegramTransport(botID: 9391))
            let configuration = terminal.telegramCompanion.configuration
            #expect(configuration == TelegramSessionCompanion.Configuration(
                primaryChannelDescription: "TUI", policy: .full
            ))
            #expect(configuration.consentLocationDescription == "the terminal")
            let location = configuration.consentLocationDescription
            #expect(TelegramSessionCompanion.primaryConsentDecisionText(
                approved: true, toolName: "local.delete", consentLocation: location
            ) == "✅ Permission granted in the terminal for local.delete. Continuing.")
            #expect(TelegramSessionCompanion.primaryConsentDecisionText(
                approved: false, toolName: "local.delete", consentLocation: location
            ) == "⛔ Permission denied in the terminal for local.delete.")
            #expect(TelegramSessionCompanion.permissionPendingText(
                for: Self.deleteRequest(), consentLocation: location
            ) == "\nPermission required: Delete Sources/Old.swift\n"
                + "Approve or deny in the terminal, or use /allow, /always or /deny in the linked chat.\n")
            await terminal.telegramCompanion.shutdown()
        }
    }

    /// An ACP session asks in the editor, and its consent texts say so.
    @Test
    func acpConsentTextsNameTheEditor() {
        let configuration = ACPTelegramCompanionChannel.configuration
        #expect(configuration == TelegramSessionCompanion.Configuration(
            primaryChannelDescription: "editor",
            policy: .mirrorOnly,
            consentLocationDescription: "the editor"
        ))
        let location = configuration.consentLocationDescription
        #expect(TelegramSessionCompanion.primaryConsentDecisionText(
            approved: true, toolName: "local.exec", consentLocation: location
        ) == "✅ Permission granted in the editor for local.exec. Continuing.")
        #expect(TelegramSessionCompanion.primaryConsentDecisionText(
            approved: false, toolName: "local.exec", consentLocation: location
        ) == "⛔ Permission denied in the editor for local.exec.")
        #expect(TelegramSessionCompanion.permissionPendingText(
            for: Self.deleteRequest(), consentLocation: location
        ) == "\nPermission required: Delete Sources/Old.swift\n"
            + "Approve or deny in the editor, or use /allow, /always or /deny in the linked chat.\n")
    }
}
