import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    @Test
    func ordinaryToolCompletionRetiresActiveSubAgentOverview() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:before-ordinary-completion",
            text: "\n👥 Sub-Agents:\n   running\n",
            overviewBatchID: "wave"
        )
        let toolCall = exampleReadFileCall(id: "ordinary-completion-with-overview")
        let eventsBeforeCompletion = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let completionText = await renderer.capturedText(droppingFirst: eventsBeforeCompletion)
        #expect(completionText.hasPrefix("\u{1B}[3A\r"))
        #expect(completionText.components(separatedBy: "\u{1B}[2K").count - 1 >= 3)
        #expect(TerminalANSIText.stripANSI(completionText).contains("local.readFile"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
    }

    @Test
    func toolStartDuringBottomOverlayTransitionWaitsForTheNewAnchor() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let toolCall = exampleReadFileCall(id: "tool-started-during-chat-repaint")
        await renderer.beginBottomOverlayTransition(maximumInPlaceRows: 6)
        let eventsBeforeStart = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 6)

        #expect(await renderer.capturedWriteEvents().count == eventsBeforeStart)
        #expect(await renderer.snapshot().activeToolCallID == nil)

        await renderer.endBottomOverlayTransition(maximumInPlaceRows: 6)

        let reanchored = await renderer.snapshot()
        let replayText = await renderer.capturedText(droppingFirst: eventsBeforeStart)
        #expect(reanchored.activeToolCallID == toolCall.id)
        #expect(reanchored.activeToolRenderedRowCount > 0)
        #expect(TerminalANSIText.stripANSI(replayText).contains("local.readFile"))
    }

    @Test
    func bottomOverlayTransitionAbandonsUnreachableToolRowsAppendSafely() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let toolCall = exampleReadFileCall(id: "tool-outside-reduced-chat-region")
        await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 3)
        let started = await renderer.snapshot()
        let eventsBeforeTransition = await renderer.capturedWriteEvents().count

        await renderer.beginBottomOverlayTransition(maximumInPlaceRows: 3)
        await renderer.endBottomOverlayTransition(maximumInPlaceRows: 1)

        let transitionEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeTransition)
        )
        #expect(
            transitionEvents.first?.text.hasPrefix(
                "\u{1B}[\(started.activeToolRenderedRowCount)A\r"
            ) == true
        )
        #expect(!transitionEvents.plainText().contains(
            "local.readFile"
        ))
        #expect(await renderer.snapshot().activeToolCallID == nil)

        let eventsBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done"),
            maximumInPlaceRows: 1
        )
        let completionText = await renderer.capturedText(droppingFirst: eventsBeforeCompletion)
        #expect(!containsCursorUpSequence(completionText))
        #expect(TerminalANSIText.stripANSI(completionText).contains("local.readFile"))
    }

    @Test
    func hiddenSharedChatDockReanchorsOverviewEvenWhenCapacityDoesNotChange() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:before-hidden-chat",
            text: "\n👥 Sub-Agents:\n   running\n",
            overviewBatchID: "wave"
        )
        let eventsBeforeTransition = await renderer.capturedWriteEvents().count

        // A compact Chat dock can be folded into existing chrome. Its capacity
        // delta is zero, but the status bar still emits an absolute cursor move.
        await renderer.beginBottomOverlayTransition(maximumInPlaceRows: 6)
        await renderer.endBottomOverlayTransition()
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:after-hidden-chat",
            text: "\n👥 Sub-Agents:\n   completed\n",
            overviewBatchID: "wave",
            maximumInPlaceRows: 6
        )
        let transitionText = (await renderer.capturedWriteEvents())
            .dropFirst(eventsBeforeTransition)
            .prefix(eventsBeforeRefresh - eventsBeforeTransition).renderedText()
        let refreshText = await renderer.capturedText(droppingFirst: eventsBeforeRefresh)

        #expect(transitionText.hasPrefix("\u{1B}[3A\r"))
        #expect(!containsCursorUpSequence(refreshText))
        #expect(TerminalANSIText.stripANSI(refreshText).contains("completed"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 3)
    }
}
