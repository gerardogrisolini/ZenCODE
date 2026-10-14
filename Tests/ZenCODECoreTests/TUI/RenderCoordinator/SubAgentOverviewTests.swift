import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    @Test
    func subAgentOverviewRefreshReplacesThePreviousSectionInPlace() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:1",
            text: "\n👥 Sub-Agents:\n   1 total\n   running\n",
            overviewBatchID: "same-wave"
        )
        let firstSnapshot = await renderer.snapshot()
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:2",
            text: "\n👥 Sub-Agents:\n   1 total\n   completed\n",
            overviewBatchID: "same-wave"
        )
        let events = await renderer.capturedWriteEvents()
        let refreshText = events
            .dropFirst(eventsBeforeRefresh).renderedText()
        let plainStderr = events.plainText(on: .standardError)

        #expect(firstSnapshot.activeSubAgentOverviewRowCount == 4)
        #expect(refreshText.hasPrefix("\u{1B}[4A\r"))
        #expect(refreshText.components(separatedBy: "\u{1B}[2K").count - 1 == 4)
        #expect(!refreshText.contains("\u{1B}[J"))
        #expect(plainStderr.components(separatedBy: "Sub-Agents:").count - 1 == 2)
        #expect(plainStderr.contains("completed"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 4)
    }

    @Test
    func externalOverlayRelinquishesSubAgentOverviewOwnership() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:before-chat",
            text: "\n👥 Sub-Agents:\n   running\n",
            overviewBatchID: "wave"
        )
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 3)
        await renderer.relinquishSubAgentOverviewOwnership()
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:after-chat",
            text: "\n👥 Sub-Agents:\n   completed\n",
            overviewBatchID: "wave"
        )
        let refreshText = await renderer.capturedText(droppingFirst: eventsBeforeRefresh)

        #expect(!containsCursorUpSequence(refreshText))
        #expect(!refreshText.contains("\u{1B}[2K"))
        #expect(TerminalANSIText.stripANSI(refreshText).contains("completed"))
    }

    @Test
    func emptySubAgentTransitionClearsOwnedRowsAndSignature() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:active",
            text: "\n👥 Sub-Agents:\n   running\n",
            overviewBatchID: "wave"
        )
        let eventCount = await renderer.capturedWriteEvents().count

        await renderer.clearSubAgentOverview()

        let teardown = await renderer.capturedText(droppingFirst: eventCount)
        let snapshot = await renderer.snapshot()
        #expect(teardown.hasPrefix("\u{1B}[3A\r"))
        #expect(snapshot.activeSubAgentOverviewRowCount == 0)
        #expect(snapshot.lastRenderedSubAgentOverviewSignature == nil)
    }

    @Test
    func emptySubAgentTransitionDoesNotClearRowsOutsideReducedOutputCapacity() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:before-chat-header",
            text: "\n👥 Sub-Agents:\n   running\n",
            overviewBatchID: "wave",
            maximumInPlaceRows: 3
        )
        let eventCount = await renderer.capturedWriteEvents().count

        // A dock appearing can shrink the output region below the existing
        // overview height. Its old rows are no longer safe to clear in place.
        await renderer.clearSubAgentOverview(maximumInPlaceRows: 2)

        let teardown = await renderer.capturedText(droppingFirst: eventCount)
        let snapshot = await renderer.snapshot()

        #expect(teardown.isEmpty)
        #expect(snapshot.activeSubAgentOverviewRowCount == 0)
        #expect(snapshot.lastRenderedSubAgentOverviewSignature == nil)
    }

    @Test
    func subAgentOverviewWithoutAnchorIsAlwaysAppended() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:unanchored:first",
            text: "\n👥 Sub-Agents:\n   first\n",
        )
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:unanchored:second",
            text: "\n👥 Sub-Agents:\n   second\n",
        )
        let refreshText = await renderer.capturedText(droppingFirst: eventsBeforeRefresh)

        #expect(!containsCursorUpSequence(refreshText))
        #expect(TerminalANSIText.stripANSI(refreshText).contains("second"))
    }

    @Test
    func subAgentOverviewIsAppendedWhenOtherOutputFollowedIt() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:1",
            text: "\n👥 Sub-Agents:\n   1 total\n",
        )
        await renderer.writeSystemMessage("Interleaved message.\n")
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:2",
            text: "\n👥 Sub-Agents:\n   2 total\n",
        )
        let refreshText = await renderer.capturedText(droppingFirst: eventsBeforeRefresh)

        #expect(!refreshText.contains("\u{1B}[2K"))
        #expect(TerminalANSIText.stripANSI(refreshText).contains("2 total"))
    }

    @Test
    func subAgentOverviewIsAppendedWhenStandardErrorIsNotATerminal() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            columnWidthProvider: { 80 }
        )

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:1",
            text: "\n👥 Sub-Agents:\n   1 total\n",
        )
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:2",
            text: "\n👥 Sub-Agents:\n   2 total\n",
        )
        let refreshText = await renderer.capturedText(droppingFirst: eventsBeforeRefresh)

        #expect(!refreshText.contains("\u{1B}[2K"))
        #expect(refreshText.contains("2 total"))
    }

    @Test
    func subAgentOverviewTallerThanTheScrollRegionIsAppended() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:1",
            text: "\n👥 Sub-Agents:\n   1 total\n   running\n",
            maximumInPlaceRows: 2
        )
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:2",
            text: "\n👥 Sub-Agents:\n   1 total\n   completed\n",
            maximumInPlaceRows: 2
        )
        let refreshText = await renderer.capturedText(droppingFirst: eventsBeforeRefresh)

        #expect(!refreshText.contains("\u{1B}[2K"))
        #expect(TerminalANSIText.stripANSI(refreshText).contains("completed"))
    }

    @Test
    func subAgentCompletedResponseIsNeverErasedByALaterRefresh() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let response = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "agent-3:completion-1",
            heading: "   ✅ Response from reviewer:\n",
            markdown: "Final answer"
        )

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:completed",
            text: "\n👥 Sub-Agents:\n   1 total\n",
            responses: [response],
        )
        // A section followed by a printed response gives up its rewrite slot.
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:after-response",
            text: "\n👥 Sub-Agents:\n   1 total closed\n",
            responses: [response],
        )
        let events = await renderer.capturedWriteEvents()
        let refreshText = events
            .dropFirst(eventsBeforeRefresh).renderedText()
        let plainStderr = events.plainText(on: .standardError)

        #expect(!refreshText.contains("\u{1B}[2K"))
        #expect(plainStderr.components(separatedBy: "Final answer").count - 1 == 1)
        #expect(plainStderr.contains("1 total closed"))
    }

    /// Streamed reasoning replaces the section in place even when the new
    /// paragraph is taller or shorter than the one on screen: the refresh
    /// erases exactly the rows the previous paragraph owned, and only one
    /// paragraph stays visible in the live rewrite slot.
    @Test
    func subAgentThinkingParagraphsOfDifferentHeightsRewriteTheSectionInPlace() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 200 }
        )

        func snapshot(_ paragraph: String) -> DirectSubAgentRuntime.AgentSnapshot {
            DirectSubAgentRuntime.AgentSnapshot(
                id: "agent_thinking",
                name: "researcher",
                role: "researcher",
                status: .running,
                pending: true,
                currentActivity: paragraph,
                currentActivityKind: .thinking,
                latestOutput: nil,
                latestError: nil,
                createdAt: Date(),
                updatedAt: Date()
            )
        }

        let shortParagraph = "Weighing the two options."
        let tallParagraph = String(
            repeating: "Weighing every dependency of the failing target. ",
            count: 6
        )
        let shortText = TerminalChat.renderSubAgentOverview([snapshot(shortParagraph)])
        let tallText = TerminalChat.renderSubAgentOverview([snapshot(tallParagraph)])

        // The coordinator-style header is stable and the only replaceable
        // content is the paragraph below it: no reasoning transcript accrues.
        let shortRowsText = TerminalANSIText.stripANSI(shortText)
            .components(separatedBy: "\n")
        let tallRowsText = TerminalANSIText.stripANSI(tallText)
            .components(separatedBy: "\n")
        #expect(shortRowsText.contains { $0.contains(TerminalChat.thinkingPlaceholder) })
        #expect(shortRowsText.contains { $0.contains(shortParagraph) })
        #expect(!shortRowsText.contains { $0.contains("🤔 \(shortParagraph)") })
        #expect(tallRowsText.contains { $0.contains(TerminalChat.thinkingPlaceholder) })
        #expect(tallText.components(separatedBy: "🤔").count - 1 == 1)

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:thinking:short",
            text: shortText,
            overviewBatchID: "thinking-wave"
        )
        let shortRows = await renderer.snapshot().activeSubAgentOverviewRowCount
        #expect(shortRows > 0)
        let eventsBeforeGrowth = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:thinking:tall",
            text: tallText,
            overviewBatchID: "thinking-wave"
        )
        let growthRefresh = await renderer.capturedText(droppingFirst: eventsBeforeGrowth)
        let tallRows = await renderer.snapshot().activeSubAgentOverviewRowCount

        #expect(tallRows > shortRows)
        #expect(growthRefresh.hasPrefix("\u{1B}[\(shortRows)A\r"))
        #expect(growthRefresh.components(separatedBy: "\u{1B}[2K").count - 1 == shortRows)
        #expect(!growthRefresh.contains("\u{1B}[J"))
        #expect(
            TerminalANSIText.stripANSI(growthRefresh)
                .contains("Weighing every dependency of the failing target.")
        )

        let eventsBeforeShrink = await renderer.capturedWriteEvents().count
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:thinking:short-again",
            text: shortText,
            overviewBatchID: "thinking-wave"
        )
        let shrinkRefresh = await renderer.capturedText(droppingFirst: eventsBeforeShrink)

        // Shrinking must erase every row the taller paragraph owned, otherwise
        // its tail would survive underneath the shorter one.
        #expect(shrinkRefresh.hasPrefix("\u{1B}[\(tallRows)A\r"))
        #expect(shrinkRefresh.components(separatedBy: "\u{1B}[2K").count - 1 == tallRows)
        #expect(!shrinkRefresh.contains("\u{1B}[J"))
        #expect(TerminalANSIText.stripANSI(shrinkRefresh).contains(shortParagraph))
        #expect(!TerminalANSIText.stripANSI(shrinkRefresh).contains(tallParagraph))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == shortRows)
    }

    @Test
    func subAgentOverviewStaysDeferredWhenPublishingSuspendedDuringAgentToolBlock() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = presentedToolCall(
            id: "wait-tool",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(toolCall)
        let startedSnapshot = await renderer.snapshot()

        await renderer.setOverviewPublishingSuspended(true)

        // Capture write events before the render attempt — no new output
        // should be produced while publication is suspended.
        let writeCountBeforeRender = await renderer.capturedWriteEvents().count

        let result = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:suspended",
            text: "Agents updated.\n\n",
        )
        let suspendedSnapshot = await renderer.snapshot()
        let writeCountAfterRender = await renderer.capturedWriteEvents().count

        // Publication is suspended: the overview must stay deferred and the
        // active agent.* tool block must NOT be interrupted — its in-place
        // rewrite rows must remain intact for a later toolCallCompleted.
        #expect(result == .deferred)
        #expect(suspendedSnapshot.lastRenderedSubAgentOverviewSignature == nil)
        #expect(suspendedSnapshot.deferredSubAgentOverviewRender)
        #expect(suspendedSnapshot.activeToolCallID == toolCall.id)
        #expect(
            suspendedSnapshot.activeToolRenderedRowCount
                == startedSnapshot.activeToolRenderedRowCount
        )
        // No writes at all: neither the overview body nor a stray newline
        // from an interrupted tool block.
        #expect(writeCountBeforeRender == writeCountAfterRender)

        // Resume and complete: the tool block was preserved, so the
        // completion handler can still clear the owned rows correctly.
        await renderer.setOverviewPublishingSuspended(false)
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )
        let completedSnapshot = await renderer.snapshot()
        #expect(completedSnapshot.activeToolCallID == nil)
        #expect(completedSnapshot.activeToolRenderedRowCount == 0)
    }

    @Test
    func subAgentOverviewDifferentWaveReusesTheOwnedLiveRegion() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:wave-a:running",
            text: "\n👥 Sub-Agents:\n   wave A running\n",
            overviewBatchID: "wave-a"
        )
        let eventCountBeforeNewWave = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:wave-b:running",
            text: "\n👥 Sub-Agents:\n   wave B running\n",
            overviewBatchID: "wave-b"
        )
        let newWaveText = await renderer.capturedText(droppingFirst: eventCountBeforeNewWave)

        // A different wave still replaces the single live Sub-Agents slot when
        // no intervening output has invalidated ownership of its physical rows.
        #expect(newWaveText.hasPrefix("\u{1B}[3A\r"))
        #expect(newWaveText.components(separatedBy: "\u{1B}[2K").count - 1 == 3)
        #expect(TerminalANSIText.stripANSI(newWaveText).contains("wave B running"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 3)
    }

    @Test
    func newerSubAgentOverviewPublicationFencesAnOlderCallback() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let staleRevision = await renderer.beginOverviewPublication(.subAgents)
        let currentRevision = await renderer.beginOverviewPublication(.subAgents)

        let current = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:current",
            text: "Current wave\n",
            revision: currentRevision,
            overviewBatchID: "current-wave"
        )
        let eventCountBeforeStaleCallback = await renderer.capturedWriteEvents().count
        let stale = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:stale",
            text: "Stale wave\n",
            revision: staleRevision,
            overviewBatchID: "stale-wave"
        )
        let staleText = await renderer.capturedText(droppingFirst: eventCountBeforeStaleCallback)

        #expect(current == .rendered)
        #expect(stale == .unchanged)
        #expect(staleText.isEmpty)
    }
}
