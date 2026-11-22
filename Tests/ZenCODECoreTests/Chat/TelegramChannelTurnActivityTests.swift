//
//  TelegramChannelTurnActivityTests.swift
//  ZenCODE
//
//  What the Telegram channel shows of a turn it presents besides its
//  responses: the reasoning blocks (whole, before what closed them, a
//  boundary of the response before them when content closes them, and the
//  two cases of a turn that moved onto the channel), the root tool calls as
//  rows of the activity message (`agent.message` left out, ❌ as the
//  terminal judges it), the sub-agent status (one message per turn, edited
//  in place, deduplicated by signature for the presenter's life) with its
//  responses sent once and remembered least recently presented first, the
//  backlog policy (C: what the sub-agents showed when the drive began is
//  never sent, captured once per drive), the publications and the refresh
//  the presenter starts, which send nothing once another channel took the
//  slot, nothing after the turn's reporting ended, and the task-graph
//  observer of an ACP slot (none of its own on the terminal's slot). The
//  host tests run real turns from the chat over a scripted backend and Bot
//  API. Nothing reaches the network; every test runs in a UUID support
//  directory.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite("Telegram channel turn activity", .serialized, .timeLimit(.minutes(2)))
struct TelegramChannelTurnActivityTests {
    private typealias Support = TelegramChannelTestSupport
    typealias Fixtures = TelegramTurnActivityFixtures
    private typealias Effect = TelegramTurnActivityEffect

    // MARK: - Thinking and tool activity

    /// The reasoning goes out whole once the response closes it, the
    /// response at the tool call, then the call's row; `agent.message` has
    /// no row, as in the terminal's tool blocks; a `local.exec` that exits
    /// with 1 is ❌, as the terminal marks it; a row ends with the time its
    /// result carries, none without one; no argument or result is sent.
    @Test
    func theChatSeesTheThoughtThenTheResponseThenTheToolRows() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let presenter = channel.presenter
            await presenter.turnWillStart(await Self.request(for: terminal))
            let log = TelegramTurnActivityWireLog()
            let reporter = await Fixtures.install(log, on: channel)
            let read = Fixtures.toolCall(id: "1", name: "local.read", arguments: ["path": "Package.swift"])
            let message = Fixtures.toolCall(
                id: "2", name: "agent.message", arguments: ["id": "worker", "message": "secret instructions"]
            )
            let exec = Fixtures.toolCall(id: "3", name: "local.exec", arguments: ["command": "swift build"])
            let failedExit = Fixtures.result("exit_code: 1\nerror: build failed", summary: "exit_code: 1")

            await presenter.presentThought("I should read ")
            await presenter.presentThought("the manifest.")
            await presenter.presentAssistantContent("Reading the manifest.")
            await presenter.presentToolCallStarted(read)
            await reporter.flush()
            await presenter.presentToolCallStarted(message)
            await presenter.presentToolCallCompleted(message, result: Fixtures.result())
            await presenter.presentToolCallSettled(message, result: Fixtures.result())
            await presenter.presentToolCallCompleted(
                read, result: Fixtures.result("manifest contents", elapsed: .milliseconds(1_250))
            )
            await reporter.flush()
            await presenter.presentToolCallStarted(exec)
            await reporter.flush()
            await presenter.presentToolCallCompleted(exec, result: failedExit)
            await reporter.flush()

            #expect(!failedExit.isFailure)
            #expect(ToolRenderingPolicy.toolResultIsFailure(for: exec, result: failedExit))
            let readRow = Fixtures.rowTitle(read)
            let execRow = Fixtures.rowTitle(exec)
            #expect(await log.effects == [
                .thought("I should read the manifest."),
                .message("Reading the manifest."),
                .create(id: 100, text: "⏳ \(readRow)"),
                .edit(id: 100, text: "✅ \(readRow) 1.25s"),
                .edit(id: 100, text: "✅ \(readRow) 1.25s\n⏳ \(execRow)"),
                .edit(id: 100, text: "✅ \(readRow) 1.25s\n❌ \(execRow)"),
            ])
            for text in await log.editableTexts.values {
                #expect(!text.contains("manifest contents"))
                #expect(!text.contains("build failed"))
                #expect(!text.contains("secret instructions"))
            }
            await channel.endTurnReporting()
            await terminal.sessionHost.shutdown()
        }
    }

    /// The handover sends no reasoning: a turn that moved onto the channel
    /// while it reasoned (no assistant text streaming) sends the whole
    /// block, what it reasoned before the move included.
    @Test
    func aTurnThatMovedWhileItReasonedSendsTheWholeThought() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let presenter = channel.presenter
            await presenter.turnDidMoveToChannel(ChatMovedTurn(
                request: await Self.request(for: terminal), liveAssistantText: "", liveThought: "First half, "
            ))
            let log = TelegramTurnActivityWireLog()
            let reporter = await Fixtures.install(log, on: channel)

            await presenter.presentThought("second half.")
            await presenter.presentAssistantContent("Answer.")
            let read = Fixtures.toolCall(id: "1", name: "local.read", arguments: ["path": "a.swift"])
            await presenter.presentToolCallStarted(read)
            await reporter.flush()

            #expect(await log.effects == [
                .thought("First half, second half."),
                .message("Answer."),
                .create(id: 100, text: "⏳ \(Fixtures.rowTitle(read))"),
            ])
            await channel.endTurnReporting()
            await terminal.sessionHost.shutdown()
        }
    }

    /// A reasoning block that assistant content closes is a boundary of the
    /// response before it: that response goes out first, then the thought,
    /// then the content after it, at the tool call.
    @Test
    func aThoughtBetweenTwoResponsesSendsTheFirstResponseBeforeTheThought() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let presenter = channel.presenter
            await presenter.turnWillStart(await Self.request(for: terminal))
            let log = TelegramTurnActivityWireLog()
            let reporter = await Fixtures.install(log, on: channel)
            let read = Fixtures.toolCall(id: "1", name: "local.read", arguments: ["path": "a.swift"])

            await presenter.presentAssistantContent("First ")
            await presenter.presentAssistantContent("response.")
            await presenter.presentThought("Second thought.")
            await presenter.presentAssistantContent("Second ")
            await presenter.presentAssistantContent("response.")
            await presenter.presentToolCallStarted(read)
            await reporter.flush()

            #expect(await log.effects == [
                .message("First response."),
                .thought("Second thought."),
                .message("Second response."),
                .create(id: 100, text: "⏳ \(Fixtures.rowTitle(read))"),
            ])
            await channel.endTurnReporting()
            await terminal.sessionHost.shutdown()
        }
    }
    /// Once the turn's reporting ended, nothing more reaches the chat: an
    /// outcome, a reasoning block, a response, a sub-agent overview.
    @Test
    func nothingReachesTheChatOnceTheTurnsReportingEnded() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let presenter = channel.presenter
            await presenter.turnWillStart(await Self.request(for: terminal))
            let log = TelegramTurnActivityWireLog()
            let reporter = await Fixtures.install(log, on: channel)
            let read = Fixtures.toolCall(id: "1", name: "local.read", arguments: ["path": "a.swift"])
            await presenter.presentToolCallStarted(read)
            await reporter.flush()

            await channel.endTurnReporting()
            await presenter.presentToolCallCompleted(read, result: Fixtures.result())
            await presenter.presentThought("late")
            await presenter.presentAssistantContent("late")
            await presenter.presentToolCallStarted(read)
            await presenter.presentSubAgentOverview(
                ChatSubAgentOverview(snapshots: [Fixtures.subAgent(id: "worker", status: .running)]),
                origin: .automatic, publication: nil
            )
            await reporter.flush()

            #expect(await log.effects == [.create(id: 100, text: "⏳ \(Fixtures.rowTitle(read))")])
            #expect(channel.activeProgressReporter == nil)
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Sub-agent status

    /// One `🤖 Sub-agent` status per turn, created at the first overview
    /// with an agent and edited in place: the terminal's summary row and one
    /// inline row per agent, plain and bounded. An unchanged overview sends
    /// nothing, in this turn or the next; an empty one creates nothing; a
    /// changed one in the next turn creates that turn's status, and its
    /// completed response is a message of its own.
    @Test
    func eachTurnHasOneSubAgentStatusEditedInPlace() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let presenter = channel.presenter
            let running = ChatSubAgentOverview(snapshots: [Fixtures.subAgent(
                id: "worker", status: .running, toolName: "local.exec", toolTarget: "swift test"
            )])
            let thinking = ChatSubAgentOverview(snapshots: [Fixtures.subAgent(
                id: "worker", status: .running, kind: .thinking, revision: 1
            )])
            let completed = ChatSubAgentOverview(snapshots: [Fixtures.subAgent(
                id: "worker", status: .idle, response: "All tests pass."
            )])

            await presenter.turnWillStart(await Self.request(for: terminal))
            let first = TelegramTurnActivityWireLog()
            let firstReporter = await Fixtures.install(first, on: channel)
            await presenter.presentSubAgentOverview(ChatSubAgentOverview(snapshots: []), origin: .automatic, publication: nil)
            await presenter.presentSubAgentOverview(running, origin: .automatic, publication: nil)
            await firstReporter.flush()
            await presenter.presentSubAgentOverview(running, origin: .automatic, publication: nil)
            await presenter.presentSubAgentOverview(thinking, origin: .automatic, publication: nil)
            await firstReporter.flush()

            let effects = await first.effects
            #expect(effects.count == 2)
            guard case let .create(id, runningText) = effects.first,
                  case let .edit(editedID, thinkingText) = effects.last else {
                Issue.record("Unexpected effects: \(effects)")
                return
            }
            #expect(editedID == id)
            for text in [runningText, thinkingText] {
                let lines = text.components(separatedBy: "\n")
                #expect(lines.count == 4, "\(text)")
                #expect(lines[0] == "🤖 Sub-agent")
                #expect(lines[1].isEmpty)
                #expect(lines[2].hasPrefix("1 total"))
                #expect(lines[3].contains("worker"))
                #expect(lines[3].contains("[RUNNING]"))
                #expect(!text.contains("\u{1B}"))
                #expect(lines.allSatisfy { $0.count <= TerminalTelegramTurnActivity.maximumStatusRowLength })
            }
            #expect(thinkingText.contains("thinking"))

            // The next turn: an unchanged overview sends nothing, a changed
            // one creates this turn's status and sends the response once.
            await presenter.turnWillStart(await Self.request(for: terminal))
            let second = TelegramTurnActivityWireLog()
            let secondReporter = await Fixtures.install(second, on: channel)
            await presenter.presentSubAgentOverview(thinking, origin: .automatic, publication: nil)
            await secondReporter.flush()
            #expect(await second.effects.isEmpty)
            await presenter.presentSubAgentOverview(completed, origin: .automatic, publication: nil)
            await presenter.presentSubAgentOverview(completed, origin: .automatic, publication: nil)
            await secondReporter.flush()
            let next = await second.effects
            #expect(next.count == 2)
            if case let .create(_, text) = next.first {
                #expect(text.contains("[COMPLETED]"))
            } else {
                Issue.record("Unexpected effects: \(next)")
            }
            #expect(next.last == .message("✅ Response from worker:\n\nAll tests pass."))
            await channel.endTurnReporting()
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Refresh

    /// The presenter runs the controller's refresh while a sub-agent call
    /// executes, as the terminal does: it starts with the call (once) and
    /// stops at its settle; another tool starts nothing.
    @Test
    func theRefreshRunsWhileASubAgentCallExecutesAndStopsAtItsSettle() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let presenter = channel.presenter
            let controller = terminal.chatSession
            let gate = DebounceGate()
            controller.subAgentOverviewRefresher.sleep = { try await gate.sleep($0) }
            await presenter.turnWillStart(await Self.request(for: terminal))
            await Fixtures.install(TelegramTurnActivityWireLog(), on: channel)
            let exec = Fixtures.toolCall(id: "1", name: "local.exec", arguments: ["command": "ls"])
            let wait = Fixtures.toolCall(id: "2", name: "agent.wait", arguments: ["ids": ["worker"]])

            await presenter.presentToolCallStarted(exec)
            #expect(controller.subAgentOverviewRefreshTask == nil)
            await presenter.presentToolCallStarted(wait)
            let refresh = try #require(controller.subAgentOverviewRefreshTask)
            await gate.waitForEntries(1)
            await presenter.presentToolCallStarted(wait)
            #expect(controller.subAgentOverviewRefreshTask == refresh)
            await presenter.presentToolCallSettled(wait, result: Fixtures.result())
            #expect(controller.subAgentOverviewRefreshTask == nil)

            await channel.endTurnReporting()
            await terminal.sessionHost.shutdown()
        }
    }

    /// The refresh stops with the turn (at its finish, or when its reporting
    /// ends) and when another channel takes the slot (`/telegram off` after
    /// `/telegram on`), so no refresh task is left; a refresh another channel
    /// started is left to it when the channel stops driving.
    @Test
    func theRefreshStopsWithTheTurnAndWhenTheChannelStopsDriving() async throws {
        try await Support.withSupport {
            let terminal = try Support.makeTerminal(transport: TelegramChannelTestTransport(botID: Support.uniqueBotID()))
            let channel = terminal.telegramChannel
            try await channel.attach()
            let presenter = channel.presenter
            let controller = terminal.chatSession
            let gate = DebounceGate()
            controller.subAgentOverviewRefresher.sleep = { try await gate.sleep($0) }
            let wait = Fixtures.toolCall(id: "2", name: "agent.wait", arguments: ["ids": ["worker"]])

            // The finish of the model work.
            await presenter.turnWillStart(await Self.request(for: terminal))
            await presenter.presentToolCallStarted(wait)
            #expect(controller.subAgentOverviewRefreshTask != nil)
            await presenter.turnWillFinish()
            #expect(controller.subAgentOverviewRefreshTask == nil)

            // The end of the turn's reporting.
            await presenter.presentToolCallStarted(wait)
            #expect(controller.subAgentOverviewRefreshTask != nil)
            await channel.endTurnReporting()
            #expect(controller.subAgentOverviewRefreshTask == nil)

            // Another channel takes the slot: `/telegram on` hands the slot
            // to the channel, `/telegram off` gives it back to the terminal.
            try await terminal.sessionHost.activateTelegram(in: terminal.terminalSlotID)
            #expect(channel.drivesSlot)
            await presenter.turnWillStart(await Self.request(for: terminal))
            await presenter.presentToolCallStarted(wait)
            #expect(controller.subAgentOverviewRefreshTask != nil)
            _ = await terminal.sessionHost.deactivateTelegram(in: terminal.terminalSlotID)
            #expect(!channel.drivesSlot)
            #expect(controller.subAgentOverviewRefreshTask == nil)

            // A refresh the terminal started is not the channel's to stop.
            controller.startSubAgentOverviewRefreshIfNeeded()
            channel.startDriving()
            await channel.stopDriving()
            #expect(controller.subAgentOverviewRefreshTask != nil)
            await controller.cancelSubAgentOverviewRefresh()

            await channel.endTurnReporting()
            await terminal.sessionHost.shutdown()
        }
    }

    // MARK: - Helpers

    @ChatSessionActor
    private static func request(for terminal: TerminalChat) async -> ChatTurnRequest {
        ChatTurnRequest(
            prompt: "go",
            sessionConfiguration: await terminal.chatSession.turnSessionConfiguration(
                for: .normal, responseLanguageSection: nil
            )
        )
    }

    @ChatSessionActor
    private static func request(for controller: ChatSessionController) async -> ChatTurnRequest {
        ChatTurnRequest(
            prompt: "go",
            sessionConfiguration: await controller.turnSessionConfiguration(
                for: .normal, responseLanguageSection: nil
            )
        )
    }
}
