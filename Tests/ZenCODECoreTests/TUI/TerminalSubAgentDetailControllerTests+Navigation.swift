//
//  TerminalSubAgentDetailControllerTests+Navigation.swift
//  ZenCODE
//
//  Tests of the sub-agent detail controller for Esc in an agent's detail: back
//  to the agent list when the panel opened on it, closed otherwise.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalSubAgentDetailControllerTests {
    // MARK: Esc in an agent's detail

    /// The index the focus marks in the agent list, `nil` outside it.
    private func listFocus(_ controller: TerminalSubAgentDetailController) -> Int? {
        guard case let .choosing(_, focusedIndex) = controller.panel.mode else { return nil }
        return focusedIndex
    }

    /// The entries of the agent list, `nil` outside it.
    private func listEntries(
        _ controller: TerminalSubAgentDetailController
    ) -> [TerminalSubAgentDetailPanel.ChoiceEntry]? {
        guard case let .choosing(entries, _) = controller.panel.mode else { return nil }
        return entries
    }

    @Test func escInTheDetailOfAnAgentFromTheListGoesBackToTheList() async {
        let harness = DetailHarness(transcript: transcript(["SECOND_AGENT"], agentID: "agent-2"))
        let controller = harness.makeController()
        let agents = [
            agent("agent-1", name: "worker", profileName: "Developer"),
            agent("agent-2", name: "reviewer", profileName: "Reviewer"),
            agent("agent-3", name: "tester", profileName: "Tester")
        ]
        controller.open(choosing: agents)
        #expect(controller.returnsToList)
        let entries = listEntries(controller)
        await controller.handle(.focusNext)
        await controller.handle(.confirm)
        #expect(controller.agentID == "agent-2")
        #expect(controller.panel.mode == .showing)
        #expect(harness.modeChanges == [false])
        await waitUntil("the agent's transcript is read") { controller.panel.availability == .available }
        #expect(harness.feed.reads == ["agent-2"])

        // Esc leaves the detail, not the panel: the list is back, focused on
        // the agent that was read, with the layout it opened with, and the
        // keys are routed to it again.
        await controller.handle(.close)
        #expect(!controller.isStopped)
        #expect(harness.closeReasons.isEmpty)
        #expect(harness.modeChanges == [false, true])
        #expect(controller.agentID == nil)
        #expect(controller.snapshot == nil)
        #expect(listFocus(controller) == 1)
        #expect(listEntries(controller) == entries)
        #expect(controller.panel.headerRows.isEmpty)
        #expect(controller.panel.bodyRows.isEmpty)
        #expect(controller.panel.title == TerminalSubAgentDetailPanel.subAgentTitle)
        let frame = controller.panel.frameLines(rows: 20, columns: 60, border: controller.border)
        #expect(harness.frames.last == frame)
        #expect(Array(bodyContents(frame).prefix(8)) == [
            "  worker",
            "    agent: Developer",
            "",
            "▸ reviewer",
            "┃   agent: Reviewer",
            "",
            "  tester",
            "    agent: Tester"
        ])
        #expect(harness.resize.isSubscribed)

        // The list works as before: it opens another agent, which Esc leaves
        // again, and the agent opened a second time is read again.
        await controller.handle(.focusPrevious)
        await controller.handle(.confirm)
        #expect(controller.agentID == "agent-1")
        #expect(harness.modeChanges == [false, true, false])
        await waitUntil("the agent's transcript is read") { controller.panel.availability == .available }
        #expect(harness.feed.reads == ["agent-2", "agent-1"])
        #expect(controller.panel.headerRows == header(agents[0]))
        await controller.handle(.close)
        #expect(listFocus(controller) == 0)
        #expect(harness.modeChanges == [false, true, false, true])
        #expect(harness.closeReasons.isEmpty)

        await controller.handle(.focusNext)
        await controller.handle(.focusNext)
        await controller.handle(.confirm)
        await controller.handle(.close)
        #expect(listFocus(controller) == 2)

        // Esc in the list closes the panel.
        await controller.handle(.close)
        #expect(harness.closeReasons == [.dismissed])
        #expect(controller.isStopped)
        #expect(harness.modeChanges == [false, true, false, true, false, true])
    }

    @Test func escInTheDetailOpenedDirectlyClosesThePanel() async {
        let harness = DetailHarness(transcript: transcript(["FIRST"]))
        let controller = harness.makeController()
        controller.open(agentID: "agent-1", snapshot: agent())
        #expect(!controller.returnsToList)
        #expect(controller.panel.mode == .showing)
        await waitUntil("the agent's transcript is read") { controller.panel.availability == .available }

        await controller.handle(.close)
        #expect(harness.closeReasons == [.dismissed])
        #expect(controller.isStopped)
        #expect(harness.modeChanges.isEmpty)
    }

    /// The keys that are not Esc leave the detail of an agent picked from the
    /// list where it is.
    @Test func theOtherKeysDoNotLeaveTheDetailOfAnAgentFromTheList() async {
        let harness = DetailHarness(transcript: transcript(["FIRST"]))
        let controller = harness.makeController()
        controller.open(choosing: [agent("agent-1"), agent("agent-2", name: "other")])
        await controller.handle(.confirm)
        await waitUntil("the agent's transcript is read") { controller.panel.availability == .available }

        for action: TerminalSubAgentDetailAction in [
            .scrollUp, .scrollDown, .pageUp, .pageDown, .top, .bottom, .focusPrevious, .focusNext, .confirm, .closeList
        ] {
            await controller.handle(action)
            #expect(controller.panel.mode == .showing)
            #expect(controller.agentID == "agent-1")
        }
        #expect(harness.modeChanges == [false])
        #expect(harness.closeReasons.isEmpty)
        controller.stop()
    }

    /// The list Esc goes back to is the one the panel opened with, and the
    /// agent is no longer followed: nothing updates the panel any more.
    @Test func goingBackEndsTheFollowingAndDoesNotUpdateTheList() async {
        let harness = DetailHarness(transcript: transcript(["FIRST"]))
        let controller = harness.makeController()
        let agents = [
            agent("agent-1", name: "worker", profileName: "Developer"),
            agent("agent-2", name: "other")
        ]
        controller.open(choosing: agents)
        let entries = listEntries(controller)
        await controller.handle(.confirm)
        await waitUntil("the controller subscribes") { harness.feed.isSubscribed }
        let ended = agent("agent-1", name: "worker", status: .idle, pending: false, second: 5, profileName: "Reviewer")
        harness.feed.yield([ended, agents[1]])
        await waitUntil("the update is applied") { controller.snapshot?.profileName == "Reviewer" }

        await controller.handle(.close)
        #expect(listFocus(controller) == 0)
        #expect(listEntries(controller) == entries)
        await waitUntil("the wait is cancelled") { harness.gate.pendingCount(DetailHarness.updateInterval) == 0 }
        let frames = harness.frames.count
        let reads = controller.transcriptReadCount

        harness.feed.yield([agent("agent-1", name: "worker", second: 9, profileName: "Tester"), agents[1]])
        await settle()
        #expect(harness.frames.count == frames)
        #expect(controller.transcriptReadCount == reads)
        #expect(controller.snapshot == nil)
        #expect(listEntries(controller) == entries)
        controller.stop()
    }

    /// A read still in flight when Esc goes back answers into the list: it
    /// draws nothing and changes nothing.
    @Test func aReadInFlightWhenEscGoesBackChangesNothing() async {
        let harness = DetailHarness(transcript: transcript(["LATE"]))
        harness.feed.holdReads()
        let controller = harness.makeController()
        controller.open(choosing: [agent("agent-1"), agent("agent-2", name: "other")])
        await controller.handle(.confirm)
        await waitUntil("the read is in flight") { harness.feed.heldReadCount == 1 }

        await controller.handle(.close)
        let frames = harness.frames.count
        harness.feed.releaseReads()
        await settle()
        #expect(harness.frames.count == frames)
        #expect(listFocus(controller) == 0)
        #expect(controller.agentID == nil)
        #expect(controller.panel.bodyRows.isEmpty)
        #expect(controller.panel.availability == .loading)
        controller.stop()
    }
}
