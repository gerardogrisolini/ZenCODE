//
//  TelegramTUITests+ProgressAndResponses.swift
//  ZenCODE
//
//  Tests for the Telegram progress reporter, finalization delivery and the
//  publication of root responses in the chat.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension TelegramTUITests {
    @Test
    func telegramProgressReporterRequiresActiveTelegramSession() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let lease = try #require(terminal.telegramChannel.activeRouteLease)
        terminal.telegramChannel.controlState.isActive = false
        #expect(terminal.telegramChannel.makeTurnProgressReporter(for: lease) == nil)

        terminal.telegramChannel.controlState.isActive = true
        terminal.telegramChannel.controlState.wireLifecycleEpoch = nil
        #expect(terminal.telegramChannel.makeTurnProgressReporter(for: lease) == nil)
        terminal.telegramChannel.controlState.wireLifecycleEpoch = UUID()
        #expect(terminal.telegramChannel.makeTurnProgressReporter(for: lease) != nil)
    }

    @Test
    func telegramEgressRestoreRejectsAmbiguousOrForeignRoomRoutes() async throws {
        let terminal = TerminalChat(
            configuration: try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: AgentProfileStore.defaultProfiles(),
                workingDirectory: FileManager.default.temporaryDirectory
            ),
            stdinIsTerminal: false,
            telegramTransportFactory: nil
        )
        let settings = AgentTelegramSettingsManifest(
            enabled: true,
            botToken: "123456:ABCDEF",
            linkedChatID: 42,
            ownerUserID: 7,
            routes: [
                AgentTelegramRouteManifest(roomID: "another-session")
            ]
        )

        #expect(await terminal.telegramChannel.egressRoute(
            settings: settings,
            linkedChatID: 42
        ) == nil)
    }

    @Test
    func telegramUnknownSlashAndArgumentedRemoteCommandsAreRejected() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let lease = try #require(terminal.telegramChannel.activeRouteLease)
        let notices = Mutex<[String]>([])
        terminal.telegramChannel.onTelegramSystemMessage = { text, _ in
            notices.withLock { $0.append(text) }
            return true
        }

        guard case .handled = await terminal.telegramChannel.lineAction(for:
            "/bogus now", lease: lease
        ) else {
            Issue.record("Unknown slash command must not reach the model")
            return
        }
        guard case .handled = await terminal.telegramChannel.lineAction(for:
            "/status foo", lease: lease
        ) else {
            Issue.record("/status with an argument must not run or reach the model")
            return
        }
        guard case .runPrompt = await terminal.telegramChannel.lineAction(for:
            "status report please", lease: lease
        ) else {
            Issue.record("Plain text starting with an alias word stays a prompt")
            return
        }
        guard case .handled = await terminal.telegramChannel.lineAction(for:
            "/help@zencode_bot", lease: lease
        ) else {
            Issue.record("/help@bot should resolve")
            return
        }
        let delivered = notices.withLock { $0 }
        #expect(delivered.count == 3)
        #expect(delivered[0].hasPrefix("ZenCODE: unknown command '/bogus'. Available commands: /help"))
        #expect(delivered[1] == "ZenCODE: /status does not accept arguments.")
        #expect(delivered[2].contains("Remote commands:"))
    }

    @Test
    func telegramProgressReporterPublishesAllowedPayloadsInFIFOOrder() async {
        let collector = TelegramTestMessageCollector()
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await collector.append(message)
            return true
        }

        await reporter.enqueue(.tasks("📋 Task graph\n\n1 running"))
        #expect(await reporter.send(.authorization("🔐 Permission required\nRequest ID: A1")))
        await reporter.enqueue(.subAgentResponse("Reviewer completed."))
        await reporter.enqueue(.agentResponse("*ZenCODE completed*\n\nDone."))
        await reporter.enqueue(.summary("🪬 Summary: 1 file  +1 -0"))
        await reporter.flush()

        #expect(await collector.allMessages() == [
            "📋 Task graph\n\n1 running",
            "🔐 Permission required\nRequest ID: A1",
            "Reviewer completed.",
            "*ZenCODE completed*\n\nDone.",
            "🪬 Summary: 1 file  +1 -0"
        ])
    }

    @Test
    func telegramFinalizationDeliversResponseBeforeSummary() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.telegramChannel.activeProgressReporter = TerminalTelegramTurnProgressReporter(
            chatID: 42
        ) { message, _ in
            await collector.append(message)
            return true
        }
        let summary = TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "Sources/App.swift",
                additions: 1,
                deletions: 0,
                status: .modified,
                isBinary: false,
                existedBefore: true,
                beforeDataBase64: nil,
                patch: nil
            )
        ])

        await terminal.telegramChannel.activeProgressReporter?.enqueue(.tasks("📋 Task graph"))
        await terminal.telegramChannel.retireTurn(outcomePayload: .agentResponse("*ZenCODE completed*\n\nDone."),
            fileChangeSummary: summary
        )

        let messages = await collector.allMessages()
        #expect(messages.count == 3)
        #expect(messages[1] == "*ZenCODE completed*\n\nDone.")
        #expect(messages[2].hasPrefix("🪬 Summary:"))
        #expect(terminal.telegramChannel.activeProgressReporter == nil)
    }

    @Test
    func telegramFinalizationDeliversOutcomeAndSummaryWithoutReporter() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.telegramChannel.activeTurnLease = terminal.telegramChannel.activeRouteLease!
        terminal.telegramChannel.onDirectTelegramTurnMessage = { payload, chatID in
            #expect(chatID == 42)
            await collector.append(payload.text)
            return true
        }
        let summary = TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "Sources/App.swift",
                additions: 1,
                deletions: 0,
                status: .modified,
                isBinary: false,
                existedBefore: true,
                beforeDataBase64: nil,
                patch: nil
            )
        ])

        await terminal.telegramChannel.retireTurn(outcomePayload: .agentResponse("*ZenCODE completed*\n\nDone."),
            fileChangeSummary: summary
        )

        let messages = await collector.allMessages()
        #expect(messages.count == 2)
        #expect(messages[0] == "*ZenCODE completed*\n\nDone.")
        #expect(messages[1].hasPrefix("🪬 Summary:"))
        #expect(terminal.telegramChannel.activeProgressReporter == nil)
        #expect(terminal.telegramChannel.activeTurnLease == nil)
    }

    // MARK: - Root responses in the chat

    @Test
    func telegramAggregatesRootResponseDeltasIntoOneMessageAtToolBoundary() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        let reporter = Self.attachTestReporter(to: terminal, collector: collector)

        await terminal.telegramChannel.appendRootResponseDelta("Inspecting ")
        await terminal.telegramChannel.appendRootResponseDelta("the reporter")
        await terminal.telegramChannel.appendRootResponseDelta(" first.\n")
        #expect((await collector.allMessages()).isEmpty)

        await terminal.telegramChannel.publishRootResponseAtToolBoundary()
        await reporter.flush()

        #expect((await collector.allMessages()) == ["Inspecting the reporter first."])
    }

    @Test
    func telegramDoesNotDuplicateTrailingRootResponseAsFinalOutcome() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.telegramChannel.activeTurnLease = terminal.telegramChannel.activeRouteLease!
        _ = Self.attachTestReporter(to: terminal, collector: collector)

        await terminal.telegramChannel.appendRootResponseDelta("Intermediate.")
        await terminal.telegramChannel.publishRootResponseAtToolBoundary()
        // Trailing content that no tool call closes is the final response.
        await terminal.telegramChannel.appendRootResponseDelta("All done, ")
        await terminal.telegramChannel.appendRootResponseDelta("everything works.")

        await terminal.telegramChannel.retireTurn(outcomePayload: .agentResponse("All done, everything works."), fileChangeSummary: nil)

        #expect(
            (await collector.allMessages()) == [
                "Intermediate.",
                "All done, everything works."
            ]
        )
        #expect(terminal.telegramChannel.activeProgressReporter == nil)
    }

    /// Reasoning reaches the chat only through the channel's presenter, as a
    /// completed block, and a tool call only as its title and outcome (see
    /// `TelegramChannelTurnActivityTests`). What the terminal renders on its
    /// own, its reasoning with the tool identity it mentions, has no path to
    /// the chat, and the responses travel without any tool detail.
    @Test
    func telegramSendsTheResponsesButNotTheThinkingTheTerminalRendersOrToolDetails() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.telegramChannel.activeTurnLease = terminal.telegramChannel.activeRouteLease!
        let reporter = Self.attachTestReporter(to: terminal, collector: collector)

        // A turn that reasons on the terminal, answers, calls a tool, and
        // answers again: only the visible responses reach the chat.
        await terminal.writeThought("Secret reasoning about local.delete.\n")
        await terminal.telegramChannel.appendRootResponseDelta("Reading the manifest.")
        await terminal.telegramChannel.publishRootResponseAtToolBoundary()
        await terminal.telegramChannel.appendRootResponseDelta("Manifest looks fine.")
        await terminal.telegramChannel.publishRootResponseAtToolBoundary()
        await reporter.flush()

        let messages = await collector.allMessages()
        #expect(messages == ["Reading the manifest.", "Manifest looks fine."])
        for message in messages {
            #expect(!message.contains("Secret reasoning"))
            #expect(!message.contains("thinking"))
            #expect(!message.contains("local.delete"))
            #expect(!message.contains("local.readFile"))
        }
    }

    /// The aggregated root response is no longer cut at the 3,900-character
    /// limit of the messages edited in place: it is sent whole, up to the
    /// bound of the rich texts.
    @Test
    func telegramReporterKeepsTheAggregatedRootResponseUpToTheRichTextLimit() async {
        let collector = TelegramTestMessageCollector()
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await collector.append(message)
            return true
        }
        let limit = TerminalTelegramTurnProgressReporter.maximumRichTextLength

        for _ in 0..<10 {
            await reporter.appendAgentResponseDelta(String(repeating: "a", count: 1_000))
        }
        #expect(await reporter.hasPendingAgentResponse)
        await reporter.publishPendingAgentResponseAtBoundary()
        for _ in 0..<14 {
            await reporter.appendAgentResponseDelta(String(repeating: "b", count: 10_000))
        }
        await reporter.publishPendingAgentResponseAtBoundary()
        await reporter.flush()

        let messages = await collector.allMessages()
        #expect(messages.map(\.count) == [10_000, limit])
    }

    @Test
    func telegramFinalResponseTextExcludesAlreadyPublishedIntermediateResponses() async throws {
        let terminal = try await Self.activeTelegramTerminal()
        let collector = TelegramTestMessageCollector()
        terminal.telegramChannel.activeTurnLease = terminal.telegramChannel.activeRouteLease!
        _ = Self.attachTestReporter(to: terminal, collector: collector)

        await terminal.telegramChannel.appendRootResponseDelta("Inspecting the manifest.")
        await terminal.telegramChannel.publishRootResponseAtToolBoundary()
        await terminal.telegramChannel.appendRootResponseDelta("All done, everything works.")

        // A turn's response text accumulates every block it produced.
        let accumulated = "Inspecting the manifest.All done, everything works."
        let finalText = await terminal.telegramChannel.finalResponseText(
            fallback: accumulated
        )
        #expect(finalText == "All done, everything works.")

        await terminal.telegramChannel.retireTurn(outcomePayload: .agentResponse("*ZenCODE completed*\n\n\(finalText)"), fileChangeSummary: nil)

        let messages = await collector.allMessages()
        #expect(
            messages == [
                "Inspecting the manifest.",
                "*ZenCODE completed*\n\nAll done, everything works."
            ]
        )
    }

    @discardableResult
    private static func attachTestReporter(
        to terminal: TerminalChat,
        collector: TelegramTestMessageCollector
    ) -> TerminalTelegramTurnProgressReporter {
        let reporter = TerminalTelegramTurnProgressReporter(chatID: 42) { message, _ in
            await collector.append(message)
            return true
        }
        terminal.telegramChannel.activeProgressReporter = reporter
        return reporter
    }
}
