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

@Suite("Telegram channel turn activity", .serialized, .timeLimit(.minutes(2)))
struct TelegramChannelTurnActivityTests {
    private typealias Support = TelegramChannelTestSupport
    private typealias Fixtures = TelegramTurnActivityFixtures
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
            let read = Fixtures.toolCall(id: "1", name: "local.readFile", arguments: ["path": "Package.swift"])
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
            #expect(TerminalChat.toolResultIsFailure(for: exec, result: failedExit))
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
            let read = Fixtures.toolCall(id: "1", name: "local.readFile", arguments: ["path": "a.swift"])
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
            let read = Fixtures.toolCall(id: "1", name: "local.readFile", arguments: ["path": "a.swift"])

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
            let read = Fixtures.toolCall(id: "1", name: "local.readFile", arguments: ["path": "a.swift"])
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

    // MARK: - Turns from the chat

    /// A turn from the chat, end to end over the production wire: the
    /// reasoning as a `💭` message that an expandable blockquote covers
    /// by entity, the response, the
    /// sub-agent call's row (created, then its outcome written after the
    /// status that closed it), the `🤖 Sub-agent` status created at the
    /// call's start and edited at its settle, the response of the agent once,
    /// a new activity message for the next call with its ❌, then the
    /// outcome. Every edit targets a message the turn created.
    @Test
    func aTurnFromTheChatShowsItsThinkingToolRowsAndSubAgents() async throws {
        try await withHost { environment, slot in
            let wait = Fixtures.toolCall(id: "w1", name: "agent.wait", arguments: ["ids": ["worker"]])
            let exec = Fixtures.toolCall(id: "e1", name: "local.exec", arguments: ["command": "swift build"])
            await environment.backend.enqueue([
                .thought("Plan: wait for the worker."),
                .content("Waiting for the worker."),
                .snapshots([Fixtures.subAgent(id: "worker", status: .running, toolName: "local.exec", toolTarget: "swift test")]),
                .toolCallStarted(wait),
                .snapshots([Fixtures.subAgent(id: "worker", status: .idle, response: "Tests pass.")]),
                .toolCallCompleted(wait, Fixtures.result(elapsed: .milliseconds(420))),
                .toolCallStarted(exec),
                .toolCallCompleted(exec, Fixtures.result("exit_code: 1\nboom", summary: "exit_code: 1")),
                .content("Done."),
            ])
            let requests = try await Self.runTurnFromTheChat("Delegate it", in: slot, environment: environment)

            let sends = requests.filter { $0.method != "editMessageText" }
            #expect(sends.count == 7, "\(sends)")
            guard sends.count == 7 else { return }
            #expect(sends[0].method == "sendMessage")
            #expect(sends[0].isThinkingShape)
            #expect(sends[0].text == "💭 Plan: wait for the worker.")
            #expect(sends[1].text == "Waiting for the worker.")
            #expect(sends[2].method == "sendMessage")
            #expect(sends[3].method == "sendMessage")
            #expect(sends[3].text.hasPrefix("🤖 Sub-agent\n\n1 total"))
            #expect(sends[3].text.contains("[RUNNING]"))
            #expect(sends[4].text == "✅ Response from worker:\n\nTests pass.")
            #expect(sends[5].method == "sendMessage")
            #expect(sends[6].text.contains("ZenCODE completed"))
            #expect(sends[6].text.contains("Done."))

            let finalTexts = Self.finalTexts(requests)
            #expect(finalTexts[sends[2].messageID] == "✅ \(Fixtures.rowTitle(wait)) 420ms")
            #expect(finalTexts[sends[3].messageID]?.contains("[COMPLETED]") == true)
            #expect(finalTexts[sends[5].messageID] == "❌ \(Fixtures.rowTitle(exec))")
            let created = Set([sends[2].messageID, sends[3].messageID, sends[5].messageID])
            let edits = requests.enumerated().filter { $0.element.method == "editMessageText" }
            #expect(!edits.isEmpty)
            #expect(edits.allSatisfy { created.contains($0.element.messageID) })
            // The outcome of the sub-agent call is written after the status
            // that closed its message.
            let statusIndex = try #require(requests.firstIndex { $0.messageID == sends[3].messageID })
            let outcomeIndex = try #require(edits.first { $0.element.messageID == sends[2].messageID }?.offset)
            #expect(outcomeIndex > statusIndex)
            #expect(!requests.contains { $0.text.contains("boom") })
        }
    }

    // MARK: - Backlog (C)

    /// The backlog policy is C: a response that completed before the channel
    /// drove the slot, which the primary channel showed, never reaches the
    /// chat, and the overview of those agents, unchanged since then, creates
    /// no `🤖 Sub-agent` status, not even around an `agent.*` call or at the
    /// end of the turn; a response that completes afterwards arrives once,
    /// with the turn's status.
    @Test
    func aResponseCompletedBeforeTheChannelDroveTheSlotNeverReachesTheChat() async throws {
        try await withHost { environment, slot in
            let wait = Fixtures.toolCall(id: "w1", name: "agent.wait", arguments: ["ids": ["worker"]])
            // A first turn creates the runner's backend, which reports the
            // sub-agents; then the primary channel drives the slot while the
            // worker completes.
            _ = try await Self.runTurnFromTheChat("Hello", in: slot, environment: environment)
            _ = await slot.host.deactivateTelegram(in: slot.id)
            await environment.backend.setSnapshots([
                Fixtures.subAgent(id: "worker", status: .idle, response: "Done before the link."),
            ])
            try await Self.activateTelegramAgain(in: slot, environment: environment)

            await environment.backend.enqueue([
                .toolCallStarted(wait), .toolCallCompleted(wait, Fixtures.result()), .content("Waited."),
            ])
            let unchanged = try await Self.runTurnFromTheChat("Wait for it", in: slot, environment: environment)
            #expect(!unchanged.contains { $0.text.contains("🤖") || $0.text.contains("Response from") }, "\(unchanged)")
            #expect(unchanged.contains { $0.text.contains("Waited.") })

            await environment.backend.enqueue([
                .snapshots([Fixtures.subAgent(id: "worker", status: .idle, response: "Done after the link.")]),
                .toolCallStarted(wait), .toolCallCompleted(wait, Fixtures.result()), .content("Waited again."),
            ])
            let changed = try await Self.runTurnFromTheChat("Wait again", in: slot, environment: environment)
            #expect(changed.filter { $0.method == "sendMessage" && $0.text.hasPrefix("🤖 Sub-agent") }.count == 1, "\(changed)")
            #expect(changed.filter { $0.text == "✅ Response from worker:\n\nDone after the link." }.count == 1)
            #expect(!changed.contains { $0.text.contains("Done before the link.") })
        }
    }

    /// The publications the presenter asks the controller for around a
    /// sub-agent call (at its start, at its settle, at the end of the model
    /// work) go through the same target as its refresh: once another channel
    /// took the slot, while the turn's reporter is still alive (the switch
    /// comes before `stopDriving` and `detach`), they send nothing; only the
    /// call's own row, which the slot's presenter sent before the switch,
    /// is shown.
    @Test
    func aDirectPublicationAfterAnotherChannelTookTheSlotSendsNothing() async throws {
        try await withHost { environment, slot in
            let channel = try #require(slot.host.telegramChannel(in: slot.id))
            let presenter = channel.presenter
            let wait = Fixtures.toolCall(id: "w1", name: "agent.wait", arguments: ["ids": ["worker"]])
            // A first turn creates the runner's backend, which reports the
            // sub-agents.
            _ = try await Self.runTurnFromTheChat("Hello", in: slot, environment: environment)
            _ = await slot.host.deactivateTelegram(in: slot.id)
            #expect(!channel.drivesSlot)
            await environment.backend.setSnapshots([
                Fixtures.subAgent(id: "worker", status: .idle, response: "Late."),
            ])
            #expect(await slot.host.incarnation(in: slot.id)?.controller.runtime.subAgentSnapshots().count == 1)
            let log = TelegramTurnActivityWireLog()
            let reporter = await Fixtures.install(log, on: channel)

            await presenter.presentToolCallStarted(wait)
            await reporter.flush()
            await presenter.presentToolCallSettled(wait, result: Fixtures.result())
            await presenter.turnWillFinish()
            await reporter.flush()

            #expect(await log.effects == [.create(id: 100, text: "⏳ \(Fixtures.rowTitle(wait))")])
            #expect(slot.host.incarnation(in: slot.id)?.controller.subAgentOverviewRefreshTask == nil)
            channel.activeProgressReporter = nil
            await reporter.retire()
        }
    }

    // MARK: - Publication order

    /// A publication that a later one overtook presents nothing: the
    /// controller reserves each publication before it reads the snapshots,
    /// so the order is the one in which the reads began, not the one in
    /// which they returned. Right after the channel starts driving the slot
    /// (its backlog still being read), a tick of the primary channel's
    /// refresh begins its read first and returns last; a publication around
    /// a tool call, reserved later, reads the newer snapshots, waits for the
    /// backlog, and presents them; the tick then sends nothing, so the
    /// `🤖 Sub-agent` status never goes back to the older rows.
    @Test
    func aPublicationOvertakenWhileItReadTheSnapshotsPresentsNothing() async throws {
        try await withHost { environment, slot in
            let channel = try #require(slot.host.telegramChannel(in: slot.id))
            // A first turn creates the runner's backend, which reports the
            // sub-agents.
            _ = try await Self.runTurnFromTheChat("Hello", in: slot, environment: environment)
            let controller = try #require(slot.host.incarnation(in: slot.id)?.controller)
            let backend = environment.backend
            await channel.stopDriving()
            await backend.setSnapshots(Self.runningAgents(1))
            // The drive begins: the read of its backlog waits.
            await backend.holdSnapshotReads(true)
            channel.startDriving()
            await backend.waitUntilSnapshotReadsAreHeld(1)
            let log = TelegramTurnActivityWireLog()
            let reporter = await Fixtures.install(log, on: channel)

            // The tick, on the slot's presenter: reserved first, its read
            // waits with the older snapshots.
            await backend.setSnapshots(Self.runningAgents(2))
            let tick = Task { @ChatSessionActor in
                await controller.publishSubAgentOverviewIfChanged()
            }
            await backend.waitUntilSnapshotReadsAreHeld(2)
            // The publication around the tool call, reserved later, reads the
            // newer snapshots at once and presents them after the backlog.
            await backend.holdSnapshotReads(false)
            await backend.setSnapshots(Self.runningAgents(3))
            await backend.releaseNextSnapshotRead()
            await controller.publishSubAgentOverviewIfChanged(
                presenter: TelegramSubAgentRefreshTarget(presenter: channel.presenter)
            )
            await reporter.flush()
            // The tick's read returns last.
            await backend.releaseNextSnapshotRead()
            await tick.value
            await reporter.flush()

            let effects = await log.effects
            #expect(effects.count == 1, "\(effects)")
            if case let .create(_, text) = effects.first {
                #expect(text.hasPrefix("🤖 Sub-agent\n\n3 total"), "\(text)")
            } else {
                Issue.record("Unexpected effects: \(effects)")
            }
            channel.activeProgressReporter = nil
            await reporter.retire()
        }
    }

    // MARK: - Task graph of an ACP slot

    /// On an ACP session's slot the channel runs the controller's task-graph
    /// observer while it drives the slot, follows the slot to the controller
    /// of a new incarnation (the old one keeps none), and stops it when it
    /// stops driving the slot.
    @Test
    func theTaskGraphObserverOfAnACPSlotFollowsTheIncarnationUntilTelegramOff() async throws {
        try await withHost(identity: .acpSession("acp-\(UUID().uuidString)")) { environment, slot in
            let channel = try #require(slot.host.telegramChannel(in: slot.id))
            let first = try #require(slot.host.incarnation(in: slot.id)?.controller)
            #expect(channel.runsTaskGraphObserver)
            // `startDriving` queued the binding synchronously: its task is the
            // barrier.
            await channel.taskGraphObservationTask?.value
            #expect(Self.observesTheTaskGraph(channel, of: first))

            let outcome = await first.handleCommandLine("/sessions new", context: [])
            #expect(outcome.action == .none)
            let second = try #require(slot.host.incarnation(in: slot.id)?.controller)
            #expect(second !== first)
            // The new incarnation queued the rebinding synchronously, after
            // the binding: awaiting it awaits both.
            await channel.taskGraphObservationTask?.value
            #expect(Self.observesTheTaskGraph(channel, of: second))
            #expect(first.taskGraphObserverTask == nil)

            _ = await slot.host.deactivateTelegram(in: slot.id)
            #expect(channel.taskGraphObservationTask == nil)
            #expect(channel.taskGraphObservedController == nil)
            #expect(second.taskGraphObserverTask == nil)
        }
    }

    // MARK: - Helpers

    /// Whether `channel` runs the task-graph observer of `controller`.
    @ChatSessionActor
    private static func observesTheTaskGraph(
        _ channel: TelegramChannel, of controller: ChatSessionController
    ) -> Bool {
        channel.taskGraphObservedController === controller && controller.taskGraphObserverTask != nil
    }

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

    /// `count` running sub-agents, `agent-1` to `agent-count`: their status
    /// says `count total`.
    private static func runningAgents(_ count: Int) -> [DirectSubAgentRuntime.AgentSnapshot] {
        (1 ... count).map { Fixtures.subAgent(id: "agent-\($0)", status: .running) }
    }

    /// The ending of a turn that completed with the response `text`.
    private static func completed(_ text: String) -> ChatTurnEnding {
        ChatTurnEnding(outcome: .completed(
            DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "test-model")
        ))
    }

    /// Sends `prompt` from the chat and returns the requests of its turn,
    /// once its outcome was sent and the turn ended on the channel of
    /// `slot`.
    ///
    /// Nothing follows the outcome, deterministically: once the channel's
    /// task for the turn ended, the turn's reporter was flushed, retired, and
    /// revoked (its wire quiesced) and the presenter's refresh stopped, so
    /// nothing of the turn can still send.
    @ChatSessionActor
    private static func runTurnFromTheChat(
        _ prompt: String, in slot: HostSlot, environment: HostEnvironment
    ) async throws -> [TurnActivityTransport.Request] {
        let channel = try #require(slot.host.telegramChannel(in: slot.id))
        let before = await environment.transport.requests.count
        let promptsBefore = await environment.backend.prompts.count
        try await environment.transport.deliver(prompt)
        let finished = await ACPTelegramTestSupport.waitUntil(timeout: .seconds(60)) {
            await environment.transport.requests.dropFirst(before).contains { $0.text.contains("ZenCODE completed") }
        }
        #expect(finished)
        let ended = await ACPTelegramTestSupport.waitUntil(timeout: .seconds(60)) {
            await Self.turnHasEnded(on: channel)
        }
        #expect(ended)
        #expect(await environment.backend.prompts.count == promptsBefore + 1)
        return Array(await environment.transport.requests.dropFirst(before))
    }

    /// Whether no turn of `channel` runs or reports: its task ended, its
    /// reporter is gone, and the session holds no reservation.
    @ChatSessionActor
    private static func turnHasEnded(on channel: TelegramChannel) -> Bool {
        channel.activeTurnTask == nil && channel.activeProgressReporter == nil && !channel.isSessionGenerating
    }

    /// `/telegram on` again on `slot`, after a `/telegram off`: the slot is
    /// handed to the channel once more, which polls the chat again.
    @ChatSessionActor
    private static func activateTelegramAgain(in slot: HostSlot, environment: HostEnvironment) async throws {
        let polls = await environment.transport.pollCount
        try await slot.host.activateTelegram(in: slot.id)
        #expect(slot.host.telegramChannel(in: slot.id)?.drivesSlot == true)
        #expect(await ACPTelegramTestSupport.waitUntil { await environment.transport.pollCount > polls })
    }

    /// The text each message shows at the end, by its id.
    private static func finalTexts(_ requests: [TurnActivityTransport.Request]) -> [Int: String] {
        var texts: [Int: String] = [:]
        for request in requests {
            texts[request.messageID] = request.text
        }
        return texts
    }

    /// Runs `body` with a host over the scripted backend whose slot
    /// (`identity`, a window by default) Telegram drives, in a UUID support
    /// directory with paired settings.
    private func withHost(
        identity: ChatSlotIdentity = .window("telegram-turn-activity"),
        _ body: @escaping @Sendable @ChatSessionActor (HostEnvironment, HostSlot) async throws -> Void
    ) async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let environment = try HostEnvironment(root: root)
            try await Task(name: "ZenCODE.Tests.telegram-turn-activity") { @ChatSessionActor in
                let slot = try environment.openSlot(identity: identity)
                try await slot.host.activateTelegram(in: slot.id)
                _ = await ACPTelegramTestSupport.waitUntil {
                    await environment.transport.pollCount > 0
                }
                do {
                    try await body(environment, slot)
                } catch {
                    await slot.host.shutdown()
                    throw error
                }
                await slot.host.shutdown()
            }.value
        }
    }
}

// MARK: - Host fixtures

/// The scripted world of the host tests: the backend, the Bot API, and the
/// workspace.
private struct HostEnvironment: Sendable {
    let workspace: URL
    let backend = TurnActivityBackend()
    let transport = TurnActivityTransport(botID: ACPTelegramTestSupport.uniqueBotID())

    init(root: URL) throws {
        workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
    }

    /// A slot (`identity`) of a host over a runner on ``backend``, whose
    /// Telegram channel uses ``transport``.
    @ChatSessionActor
    func openSlot(identity: ChatSlotIdentity) throws -> HostSlot {
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [
                AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")
            ],
            workingDirectory: workspace
        )
        let interactionHost = ScriptedChatInteractionHost(capabilities: [.toolConsent, .textInput], decisions: [])
        let authorizer = ChatToolConsentAuthorizer(host: interactionHost)
        let runner = AgentCoreSessionRunner(
            defaultToolAuthorizationHandler: { request in await authorizer.authorize(request) },
            backendFactory: backend.factory,
            taskGraphStore: nil
        )
        let host = ChatSessionHost(
            runner: runner,
            environment: ChatSessionEnvironment(configuration: configuration, featureRuntime: nil),
            sleepAssertionReason: "ZenCODE Telegram turn activity test"
        )
        let transport = transport
        host.telegramTransportFactory = { transport }
        let presenter = TurnActivityPrimaryPresenter()
        var descriptor = ChatSlotDescriptor(
            identity: identity,
            workingDirectory: workspace,
            presenter: presenter,
            interaction: .host(interactionHost),
            authorizer: authorizer,
            defaultOrigin: .app,
            publishesState: false
        )
        descriptor.presentTurnEnding = { ending in
            await presenter.presentTurnEnding(ending)
        }
        let incarnation = try host.openSlot(descriptor, sessionID: "turn-activity-\(UUID().uuidString)")
        return HostSlot(host: host, id: incarnation.slotID)
    }
}

@ChatSessionActor
private struct HostSlot {
    let host: ChatSessionHost
    let id: ChatSlotID
}

/// The primary channel of the host tests, which presents nothing.
@ChatSessionActor
private final class TurnActivityPrimaryPresenter: ChatSlotChannelPresenter {
    init() {}

    func turnDidMoveToChannel(_ turn: ChatMovedTurn) async {}

    func presentTurnEnding(_ ending: ChatTurnEnding) async {}
}

/// A model backend whose prompts follow the script of ``enqueue(_:)``: the
/// reasoning, content, and tool-call events of each step, and the sub-agent
/// snapshots it reports from a step on. While ``holdSnapshotReads(_:)`` is
/// on, a read of the snapshots takes them as they are then and returns them
/// only once ``releaseNextSnapshotRead()`` lets it go, oldest first.
private actor TurnActivityBackend: AgentRuntimeBackend {
    enum Step: Sendable {
        case thought(String)
        case content(String)
        case toolCallStarted(DirectAgentToolCall)
        case toolCallCompleted(DirectAgentToolCall, DirectAgentToolResult)
        case snapshots([DirectSubAgentRuntime.AgentSnapshot])
    }

    private var scripts: [[Step]] = []
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var snapshots: [DirectSubAgentRuntime.AgentSnapshot] = []
    private(set) var prompts: [String] = []
    private var holdsSnapshotReads = false
    private var heldSnapshotReads: [CheckedContinuation<Void, Never>] = []
    private var heldSnapshotReadWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    nonisolated var factory: AgentRuntimeBackendFactory {
        { [self] _, _ in self }
    }

    func enqueue(_ steps: [Step]) {
        scripts.append(steps)
    }

    func setSnapshots(_ snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        self.snapshots = snapshots
    }

    /// Whether the reads that start from now on wait; a read already waiting
    /// keeps waiting.
    func holdSnapshotReads(_ holds: Bool) {
        holdsSnapshotReads = holds
    }

    /// Returns once `count` reads wait.
    func waitUntilSnapshotReadsAreHeld(_ count: Int) async {
        guard heldSnapshotReads.count < count else { return }
        await withCheckedContinuation { heldSnapshotReadWaiters.append((count, $0)) }
    }

    /// Lets the oldest read that waits return.
    func releaseNextSnapshotRead() {
        guard !heldSnapshotReads.isEmpty else { return }
        heldSnapshotReads.removeFirst().resume()
    }

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        let current = snapshots
        guard holdsSnapshotReads else { return current }
        await withCheckedContinuation { continuation in
            heldSnapshotReads.append(continuation)
            let held = heldSnapshotReads.count
            let ready = heldSnapshotReadWaiters.filter { $0.count <= held }
            heldSnapshotReadWaiters.removeAll { $0.count <= held }
            for waiter in ready {
                waiter.continuation.resume()
            }
        }
        return current
    }

    func createSession(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id, modelID: "test-model", workingDirectoryPath: cwd,
            systemPrompt: systemPrompt, cacheKey: cacheKey, history: history,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func createSessionIfNeeded(
        id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
        cacheKey: String?, allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool
    ) {
        guard sessions[id] == nil else { return }
        createSession(
            id: id, cwd: cwd, systemPrompt: systemPrompt, history: history, cacheKey: cacheKey,
            allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String, systemPrompt _: String?, allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?, preserveThinking _: Bool
    ) {}

    func closeSession(id: String) {
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        let steps = scripts.isEmpty ? [.content("Answer to: \(prompt)")] : scripts.removeFirst()
        var text = ""
        for step in steps {
            switch step {
            case let .thought(thought):
                await onEvent(.thought(thought))
            case let .content(content):
                text += content
                await onEvent(.content(content))
            case let .toolCallStarted(toolCall):
                await onEvent(.toolCallStarted(toolCall))
            case let .toolCallCompleted(toolCall, result):
                await onEvent(.toolCallCompleted(toolCall, result))
            case let .snapshots(snapshots):
                self.snapshots = snapshots
            }
        }
        if let snapshot = sessions[sessionID] {
            sessions[sessionID] = AgentRuntimeSessionSnapshot(
                sessionID: snapshot.sessionID, modelID: snapshot.modelID,
                workingDirectoryPath: snapshot.workingDirectoryPath,
                systemPrompt: snapshot.systemPrompt, cacheKey: snapshot.cacheKey,
                history: snapshot.history + [
                    AgentRuntimeMessage(role: .user, content: prompt),
                    AgentRuntimeMessage(role: .assistant, content: text),
                ],
                allowedToolNames: snapshot.allowedToolNames,
                thinkingSelection: snapshot.thinkingSelection,
                preserveThinking: snapshot.preserveThinking
            )
        }
        return DirectAgentResponse(text: text, stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

/// A Bot API double for one bot that records every message it sends,
/// edits, or deletes, in order: getUpdates returns what ``deliver(_:)``
/// queued, sendMessage and sendRichMessage answer receipts from 500 on, and
/// every other method succeeds.
actor TurnActivityTransport: TelegramHTTPTransport {
    /// One message effect: the method, the text (for a rich message every
    /// text of the document, joined by a newline), the message (the receipt
    /// of a send, the target of an edit or a deletion), and whether the
    /// message has the thinking message's shape: a `sendMessage` whose
    /// entities are exactly an `expandable_blockquote` and an `italic`.
    struct Request: Equatable, Sendable {
        let method: String
        let text: String
        let messageID: Int
        let isThinkingShape: Bool
    }

    let botID: Int64
    private(set) var requests: [Request] = []
    private(set) var pollCount = 0
    private var pendingUpdates: [String] = []
    private var nextUpdateID = 1
    private var nextMessageID = 500

    init(botID: Int64) {
        self.botID = botID
    }

    /// Queues a text of the owner in the linked chat for the next poll.
    func deliver(_ text: String) throws {
        let message: [String: Any] = [
            "message_id": nextMessageID,
            "from": ["id": 7, "is_bot": false, "first_name": "Owner", "username": "owner"],
            "chat": ["id": 42, "type": "private", "first_name": "Owner"],
            "date": 1,
            "text": text,
        ]
        nextMessageID += 1
        let update: [String: Any] = ["update_id": nextUpdateID, "message": message]
        nextUpdateID += 1
        let data = try JSONSerialization.data(withJSONObject: update)
        pendingUpdates.append(String(decoding: data, as: UTF8.self))
    }

    func send(
        url: URL, method: String, headers: [RemoteHTTPHeader], body: Data?, timeout: Duration?
    ) async throws -> (status: Int, body: Data) {
        let object = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        switch url.lastPathComponent {
        case "getMe":
            return (200, Data(
                #"{"ok":true,"result":{"id":\#(botID),"is_bot":true,"first_name":"ZenCODE","username":"zencode_bot"}}"#.utf8
            ))
        case "getUpdates":
            pollCount += 1
            while pendingUpdates.isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            let updates = pendingUpdates
            pendingUpdates = []
            return (200, Data(#"{"ok":true,"result":[\#(updates.joined(separator: ","))]}"#.utf8))
        case "sendMessage":
            let entities = object?["entities"] as? [Any] ?? []
            let types = entities.map { ($0 as? [String: Any])?["type"] as? String }
            return record(
                method: "sendMessage", text: object?["text"] as? String ?? "",
                isThinkingShape: types == ["expandable_blockquote", "italic"]
            )
        case "sendRichMessage":
            let richMessage = object?["rich_message"] as? [String: Any]
            let blocks = richMessage?["blocks"] as? [Any] ?? []
            return record(
                method: "sendRichMessage",
                text: blocks.map { Self.text(of: $0) }.joined(separator: "\n\n"),
                isThinkingShape: false
            )
        case "editMessageText":
            let messageID = object?["message_id"] as? Int ?? 0
            requests.append(Request(
                method: "editMessageText", text: object?["text"] as? String ?? "",
                messageID: messageID, isThinkingShape: false
            ))
            return (200, Self.messageBody(id: messageID))
        case "deleteMessage":
            requests.append(Request(
                method: "deleteMessage", text: "", messageID: object?["message_id"] as? Int ?? 0,
                isThinkingShape: false
            ))
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        default:
            return (200, Data(#"{"ok":true,"result":true}"#.utf8))
        }
    }

    private func record(method: String, text: String, isThinkingShape: Bool) -> (status: Int, body: Data) {
        let messageID = nextMessageID
        nextMessageID += 1
        requests.append(Request(
            method: method, text: text, messageID: messageID, isThinkingShape: isThinkingShape
        ))
        return (200, Self.messageBody(id: messageID))
    }

    private static func messageBody(id: Int) -> Data {
        Data(#"{"ok":true,"result":{"message_id":\#(id),"chat":{"id":42,"type":"private"},"date":0}}"#.utf8)
    }

    /// The text of a decoded rich block: its runs; for a details block its
    /// summary and then its blocks, each separated by a blank line, as the
    /// paragraphs of the Markdown it came from.
    private static func text(of block: Any) -> String {
        if let text = block as? String {
            return text
        }
        if let array = block as? [Any] {
            return array.map { text(of: $0) }.joined()
        }
        guard let object = block as? [String: Any] else { return "" }
        var parts: [String] = []
        if let summary = object["summary"] {
            parts.append(text(of: summary))
        }
        if let text = object["text"] {
            parts.append(Self.text(of: text))
        }
        if let blocks = object["blocks"] as? [Any] {
            parts.append(contentsOf: blocks.map { text(of: $0) })
        }
        return parts.joined(separator: "\n\n")
    }
}
