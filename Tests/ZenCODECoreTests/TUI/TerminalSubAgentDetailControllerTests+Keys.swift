//
//  TerminalSubAgentDetailControllerTests+Keys.swift
//  ZenCODE
//
//  Tests of the sub-agent detail controller for the list keys, the list
//  entries, closing and the viewport.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalSubAgentDetailControllerTests {
    // MARK: Keys

    @Test func theListMovesTheFocusAndEnterOpensTheFocusedAgent() async {
        let harness = DetailHarness(transcript: transcript(["SECOND_AGENT"], agentID: "agent-2"))
        let controller = harness.makeController()
        let agents = [
            agent("agent-1", name: "worker", profileName: "Developer"),
            agent("agent-2", name: "worker", status: .idle, pending: false, profileName: "Developer"),
            agent("agent-3", name: "reviewer", profileName: "Developer"),
            agent("agent-4", name: "  ", profileName: "Developer")
        ]
        controller.open(choosing: agents)
        func focus() -> Int? {
            guard case let .choosing(_, focusedIndex) = controller.panel.mode else { return nil }
            return focusedIndex
        }
        guard case let .choosing(entries, _) = controller.panel.mode else {
            Issue.record("The list is not shown")
            return
        }
        #expect(entries.map(\.id) == ["agent-1", "agent-2", "agent-3", "agent-4"])
        // The title is the name alone, or the id when the name is blank.
        #expect(entries.map(\.title) == ["worker", "worker", "reviewer", "agent-4"])
        // Agents sharing a name carry their id as the first detail row, on a
        // line of its own; a blank name is the id, which needs no second row.
        let profile = TerminalSubAgentOverviewLayout.metadataText(label: "agent:", value: "Developer")
        func id(_ value: String) -> String {
            TerminalSubAgentOverviewLayout.metadataText(label: "id:   ", value: value)
        }
        #expect(entries.map(\.details) == [
            [id("agent-1"), profile], [id("agent-2"), profile], [profile], [profile]
        ])
        #expect(focus() == 0)
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60))

        await controller.handle(.scrollDown)
        #expect(focus() == 1)
        await controller.handle(.scrollUp)
        #expect(focus() == 0)
        await controller.handle(.scrollUp)
        #expect(focus() == 3)
        await controller.handle(.focusNext)
        #expect(focus() == 0)
        await controller.handle(.focusNext)
        #expect(focus() == 1)
        await controller.handle(.pageDown)
        await controller.handle(.bottom)
        #expect(focus() == 1)
        #expect(harness.frames.last == controller.panel.frameLines(rows: 20, columns: 60))

        // The list reads nothing.
        await settle()
        #expect(harness.feed.reads.isEmpty)
        #expect(harness.feed.subscriptionCount == 0)

        await controller.handle(.confirm)
        #expect(controller.panel.mode == .showing)
        #expect(controller.agentID == "agent-2")
        #expect(harness.modeChanges == [false])
        #expect(controller.panel.headerRows == header(agents[1]))
        await waitUntil("the agent's transcript is read") { controller.panel.availability == .available }
        #expect(harness.feed.reads == ["agent-2"])
        #expect(controller.panel.bodyRows == rows(["SECOND_AGENT"]))
        controller.stop()
    }

    @Test func theListEntriesShowTheAgentAndTheModelOfTheSnapshots() async {
        typealias Layout = TerminalSubAgentOverviewLayout
        let harness = DetailHarness(transcript: nil)
        let controller = harness.makeController(modelTitleResolver: { "Title of \($0)" })
        let agents = [
            agent(
                "agent-1",
                name: "worker",
                profileName: "Developer",
                configuredModelID: "gpt-5",
                modelID: "gpt-5-2025",
                metrics: DirectAgentGenerationMetrics(
                    promptTokenCount: 1_200,
                    cachedPromptTokenCount: 300,
                    completionTokenCount: 80
                )
            ),
            agent("agent-2", name: "tester", modelID: "local-model"),
            agent("agent-3", name: "planner", profileName: "Planner"),
            agent("agent-4", name: "bare", profileName: "  ")
        ]
        controller.open(choosing: agents)
        guard case let .choosing(entries, _) = controller.panel.mode else {
            Issue.record("The list is not shown")
            return
        }
        // The labels of the detail header, one field per row: the agent and
        // the configured model, titled, without the token counters.
        #expect(entries[0].details == [
            Layout.metadataText(label: "agent:", value: "Developer"),
            Layout.metadataText(label: "model:", value: "Title of gpt-5")
        ])
        // Without a configured model the reported one.
        #expect(entries[1].details == [Layout.metadataText(label: "model:", value: "Title of local-model")])
        #expect(entries[2].details == [Layout.metadataText(label: "agent:", value: "Planner")])
        // A blank profile and no model leave no row.
        #expect(entries[3].details.isEmpty)

        // Only what does not go stale: no status, no activity, no counters.
        let text = entries.flatMap { [$0.title] + $0.details }.map(TerminalANSIText.stripANSI)
        #expect(text == [
            "worker", "agent: Developer", "model: Title of gpt-5",
            "tester", "model: Title of local-model",
            "planner", "agent: Planner",
            "bare"
        ])

        // The whole list fits the frame, one blank row between the entries.
        let frame = controller.panel.frameLines(rows: 20, columns: 60)
        #expect(harness.frames.last == frame)
        #expect(Array(bodyContents(frame).prefix(11)) == [
            "▸ worker",
            "┃   agent: Developer",
            "┃   model: Title of gpt-5",
            "",
            "  tester",
            "    model: Title of local-model",
            "",
            "  planner",
            "    agent: Planner",
            "",
            "  bare"
        ])
        #expect(bodyContents(frame).dropFirst(11).allSatisfy { $0.isEmpty })

        // Enter opens the agent of the focused entry.
        await controller.handle(.focusNext)
        await controller.handle(.focusNext)
        await controller.handle(.confirm)
        #expect(controller.agentID == "agent-3")
        #expect(controller.snapshot?.profileName == "Planner")
        controller.stop()
    }

    @Test func theListEntryShowsTheTaskWithItsAttemptOnTheSameRow() async {
        typealias Layout = TerminalSubAgentOverviewLayout
        let harness = DetailHarness(transcript: nil)
        let controller = harness.makeController()
        let agents = [
            agent("agent-1", name: "worker", taskID: "parser-core", taskAttemptOrdinal: 2),
            agent("agent-2", name: "tester", taskID: "docs"),
            // The attempt belongs to the task row: without a task it has none.
            agent("agent-3", name: "planner", taskAttemptOrdinal: 3),
            agent("agent-4", name: "blank", taskID: "  ", taskAttemptOrdinal: 1),
            agent("agent-5", name: "spaced", taskID: "parser\ncore", taskAttemptOrdinal: 4)
        ]
        controller.open(choosing: agents)
        guard case let .choosing(entries, _) = controller.panel.mode else {
            Issue.record("The list is not shown")
            return
        }
        let dot = " \(Layout.dimText("·")) "
        #expect(entries[0].details == [
            Layout.metadataText(label: "task: ", value: "parser-core") + dot
                + Layout.metadataText(label: "attempt:", value: "2")
        ])
        #expect(entries[1].details == [Layout.metadataText(label: "task: ", value: "docs")])
        #expect(entries[2].details.isEmpty)
        #expect(entries[3].details.isEmpty)
        // The task id is on one line, as in the detail header.
        #expect(entries[4].details == [
            Layout.metadataText(label: "task: ", value: "parser core") + dot
                + Layout.metadataText(label: "attempt:", value: "4")
        ])

        let text = entries.flatMap { [$0.title] + $0.details }.map(TerminalANSIText.stripANSI)
        #expect(text == [
            "worker", "task:  parser-core · attempt: 2",
            "tester", "task:  docs",
            "planner",
            "blank",
            "spaced", "task:  parser core · attempt: 4"
        ])
        controller.stop()
    }

    @Test func theListEntryOmitsEveryMissingFieldAndKeepsTheOrderOfTheDetailHeader() async {
        typealias Layout = TerminalSubAgentOverviewLayout
        let harness = DetailHarness(transcript: nil)
        let controller = harness.makeController(modelTitleResolver: { "Title of \($0)" })
        let agents = [
            // Every field, the shared name included.
            agent(
                "agent-1",
                name: "worker",
                profileName: "Developer",
                taskID: "parser-core",
                taskAttemptOrdinal: 2,
                configuredModelID: "gpt-5"
            ),
            // Only the id, the task and the model.
            agent("agent-2", name: "worker", taskID: "docs", modelID: "local-model"),
            // No field at all: the title alone.
            agent("agent-3", name: "bare"),
            // Only the task.
            agent("agent-4", name: "lonely", taskID: "cleanup")
        ]
        controller.open(choosing: agents)
        guard case let .choosing(entries, _) = controller.panel.mode else {
            Issue.record("The list is not shown")
            return
        }
        let text = entries.map { entry in ([entry.title] + entry.details).map(TerminalANSIText.stripANSI) }
        #expect(text == [
            [
                "worker",
                "id:    agent-1",
                "agent: Developer",
                "task:  parser-core · attempt: 2",
                "model: Title of gpt-5"
            ],
            ["worker", "id:    agent-2", "task:  docs", "model: Title of local-model"],
            ["bare"],
            ["lonely", "task:  cleanup"]
        ])
        // An agent without fields has no detail row, not even an empty one.
        #expect(entries[2].details.isEmpty)
        controller.stop()
    }

    @Test func theListFramePutsTheValuesOfEveryLabelOnTheSameColumn() async {
        let harness = DetailHarness(transcript: nil)
        let controller = harness.makeController(modelTitleResolver: { "Title of \($0)" })
        let agents = [
            agent(
                "agent-1",
                name: "worker",
                profileName: "Developer",
                taskID: "parser-core",
                taskAttemptOrdinal: 2,
                configuredModelID: "gpt-5"
            ),
            agent("agent-2", name: "worker", taskID: "docs"),
            agent("agent-3", name: "tester", profileName: "Tester")
        ]
        controller.open(choosing: agents)
        let frame = controller.panel.frameLines(rows: 20, columns: 60)
        #expect(harness.frames.last == frame)
        let contents = bodyContents(frame)
        #expect(Array(contents.prefix(12)) == [
            "▸ worker",
            "┃   id:    agent-1",
            "┃   agent: Developer",
            "┃   task:  parser-core · attempt: 2",
            "┃   model: Title of gpt-5",
            "",
            "  worker",
            "    id:    agent-2",
            "    task:  docs",
            "",
            "  tester",
            "    agent: Tester"
        ])
        #expect(contents.dropFirst(12).allSatisfy { $0.isEmpty })

        // Whatever the entry, every value starts at the column after the
        // longest label: the four columns of the gutter, the label completed
        // to six columns and the separating space.
        let valueColumn = 4 + 6 + 1
        let labels = ["id:", "agent:", "task:", "model:"]
        let fieldRows = contents.filter { $0.hasPrefix("┃   ") || $0.hasPrefix("    ") }
        #expect(fieldRows.count == 7)
        for row in fieldRows {
            let label = String(row.dropFirst(4).prefix(valueColumn - 4))
            #expect(label.hasSuffix(" "), "No separator in \"\(row)\"")
            #expect(labels.contains(label.trimmingCharacters(in: .whitespaces)), "Unknown label in \"\(row)\"")
            #expect(row.dropFirst(valueColumn).first != " ", "The value of \"\(row)\" is not on column \(valueColumn)")
        }
        controller.stop()
    }

    @Test func theListEntriesShowNoStatusNoActivityAndNoCounters() async {
        let harness = DetailHarness(transcript: nil)
        let controller = harness.makeController(modelTitleResolver: { "Title of \($0)" })
        let agents = [
            agent(
                "agent-1",
                name: "worker",
                status: .running,
                pending: true,
                activity: "WRITING_THE_PARSER",
                toolName: "swift.build",
                toolIsRunning: true,
                profileName: "Developer",
                taskID: "parser-core",
                taskAttemptOrdinal: 2,
                configuredModelID: "gpt-5",
                metrics: DirectAgentGenerationMetrics(
                    promptTokenCount: 1_200,
                    cachedPromptTokenCount: 300,
                    completionTokenCount: 80
                )
            ),
            agent("agent-2", name: "done", status: .idle, pending: false, profileName: "Developer")
        ]
        controller.open(choosing: agents)
        guard case let .choosing(entries, _) = controller.panel.mode else {
            Issue.record("The list is not shown")
            return
        }
        let text = entries.flatMap { [$0.title] + $0.details }.map(TerminalANSIText.stripANSI)
        #expect(text == [
            "worker",
            "agent: Developer",
            "task:  parser-core · attempt: 2",
            "model: Title of gpt-5",
            "done",
            "agent: Developer"
        ])
        let everything = (text + bodyContents(controller.panel.frameLines(rows: 20, columns: 60))).joined(separator: "\n")
        for stale in [
            "RUNNING", "IDLE", "ACTIVE", "running", "idle", "WRITING_THE_PARSER", "swift.build",
            "c:", "p:", "g:", "1.2", "error"
        ] {
            #expect(!everything.contains(stale), "The list shows \"\(stale)\"")
        }
        controller.stop()
    }

    // MARK: Closing

    @Test func closingIsIdempotentAndNothingFollowsIt() async {
        let harness = DetailHarness(transcript: transcript(["FIRST"]))
        let controller = harness.makeController()
        controller.open(choosing: [agent()])
        #expect(harness.resize.isSubscribed)

        await controller.handle(.close)
        await controller.close(reason: .replaced)
        await controller.close(reason: .dismissed)
        #expect(harness.closeReasons == [.dismissed])
        #expect(controller.isStopped)
        #expect(harness.resize.cancellationCount == 1)
        await waitUntil("the poll is cancelled") { harness.gate.pendingCount(DetailHarness.pollInterval) == 0 }

        let frames = harness.frames.count
        await controller.handle(.scrollDown)
        await controller.handle(.confirm)
        controller.open(agentID: "agent-1", snapshot: agent())
        controller.open(choosing: [agent()])
        controller.stop()
        await settle()
        #expect(harness.frames.count == frames)
        #expect(harness.modeChanges.isEmpty)
        #expect(harness.feed.reads.isEmpty)
        #expect(harness.closeReasons == [.dismissed])
    }

    @Test func nothingIsPresentedAfterStopNotEvenByAReadInFlight() async {
        let harness = DetailHarness(transcript: transcript(["LATE"]))
        harness.feed.holdReads()
        let controller = harness.makeController()
        controller.open(agentID: "agent-1", snapshot: agent())
        await waitUntil("the read is in flight") { harness.feed.heldReadCount == 1 }
        let frames = harness.frames.count

        controller.stop()
        controller.stop()
        harness.feed.releaseReads()
        await settle()
        #expect(harness.frames.count == frames)
        #expect(controller.panel.availability == .loading)
        #expect(harness.feed.subscriptionCount == 0)
        #expect(harness.resize.cancellationCount == 1)

        // A close after a stop reports nothing.
        await controller.close(reason: .dismissed)
        #expect(harness.closeReasons.isEmpty)
    }

    // MARK: Viewport

    @Test(arguments: [false, true])
    func closesWhenTheScreenTurnsAppendOnly(throughResizeSignal: Bool) async {
        let harness = DetailHarness(transcript: transcript(["FIRST"]))
        let controller = harness.makeController()
        controller.open(agentID: "agent-1", snapshot: agent())
        await waitUntil("the poll waits") { harness.gate.pendingCount(DetailHarness.pollInterval) == 1 }

        harness.isCancelled = true
        if throughResizeSignal {
            harness.resize.signal()
        } else {
            #expect(harness.gate.release(DetailHarness.pollInterval))
        }
        await waitUntil("the controller closes") { !harness.closeReasons.isEmpty }
        #expect(harness.closeReasons == [.layoutUnavailable])
        // `onClosed` runs in a task that is not cancelled.
        #expect(harness.closedWhileCancelled == [false])
        #expect(controller.isStopped)
        #expect(harness.resize.cancellationCount == 1)

        let frames = harness.frames.count
        harness.isCancelled = false
        harness.viewport = (rows: 10, columns: 40)
        harness.resize.signal()
        await settle()
        #expect(harness.frames.count == frames)
        #expect(harness.closeReasons == [.layoutUnavailable])
    }
}
