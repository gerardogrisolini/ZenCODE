import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    @Test
    func delegatedToolTimingComesFromEachAgentsResultForMatchingProviderCallIDs() async {
        let toolCall = presentedToolCall(
            id: "provider-reused-call-id",
            name: "search.grep",
            argumentsObject: ["pattern": "needle"],
            argumentsJSON: "{}"
        )
        let firstResult = DirectAgentToolResult(
            output: "match", summary: "1 match", elapsed: .milliseconds(600)
        )
        let secondResult = DirectAgentToolResult(
            output: "match", summary: "1 match", elapsed: .milliseconds(200)
        )
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 120 }
        )
        let firstStarted = DirectSubAgentToolEvent(
            agentID: "agent-first",
            agentName: "first",
            toolCall: toolCall,
            lifecycle: .started
        )
        let secondStarted = DirectSubAgentToolEvent(
            agentID: "agent-second",
            agentName: "second",
            toolCall: toolCall,
            lifecycle: .started
        )

        await renderer.recordSubAgentToolEvent(firstStarted)
        await renderer.recordSubAgentToolEvent(secondStarted)
        await renderer.recordSubAgentToolEvent(
            DirectSubAgentToolEvent(
                agentID: "agent-second",
                agentName: "second",
                toolCall: toolCall,
                lifecycle: .completed(secondResult)
            )
        )
        await renderer.recordSubAgentToolEvent(
            DirectSubAgentToolEvent(
                agentID: "agent-first",
                agentName: "first",
                toolCall: toolCall,
                lifecycle: .completed(firstResult)
            )
        )

        let presentations = await renderer
            .subAgentToolPresentationSnapshot()
            .presentationsByAgentID
        if case let .completed(_, secondDetail)? = presentations["agent-second"]?.lifecycle {
            #expect(secondDetail == "200ms")
        } else {
            Issue.record("Second delegated tool did not complete")
        }
        if case let .completed(_, firstDetail)? = presentations["agent-first"]?.lifecycle {
            #expect(firstDetail == "600ms")
        } else {
            Issue.record("First delegated tool did not complete")
        }
        #expect(await renderer.capturedWriteEvents().isEmpty)
    }

    @Test
    func agentToolAndOverviewTransferTheSingleRewriteAnchorWithoutStalePendingSections() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 120 }
        )
        let toolCall = presentedToolCall(
            id: "wait-for-live-overview",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(toolCall)
        let pendingToolRows = await renderer.snapshot().activeToolRenderedRowCount
        let eventsBeforeOverview = await renderer.capturedWriteEvents().count

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:pending",
            text: "\n👥 Sub-Agents:\n   worker ⏳\n",
            overviewBatchID: "wave",
            maximumInPlaceRows: 20
        )
        let overviewEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeOverview)
        )
        let pendingOverviewRows = await renderer.snapshot().activeSubAgentOverviewRowCount

        #expect(pendingToolRows > 0)
        #expect(overviewEvents.first?.text.hasPrefix("\u{1B}[\(pendingToolRows)A\r") == true)
        #expect(await renderer.snapshot().activeToolCallID == nil)
        #expect(pendingOverviewRows > 0)

        let eventsBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done", elapsed: .milliseconds(1_200)),
            maximumInPlaceRows: 20
        )
        let completionEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeCompletion)
        )
        let completionText = completionEvents.renderedText()

        #expect(completionEvents.first?.text.hasPrefix("\u{1B}[\(pendingOverviewRows)A\r") == true)
        #expect(completionText.contains("✅"))
        #expect(TerminalANSIText.stripANSI(completionText).contains("1.20s"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)

        let eventsBeforeCompletedOverview = await renderer.capturedWriteEvents().count
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:completed",
            text: "\n👥 Sub-Agents:\n   worker ✅ 1.20s\n",
            overviewBatchID: "wave",
            maximumInPlaceRows: 20
        )
        let completedOverviewText = await renderer.capturedText(droppingFirst: eventsBeforeCompletedOverview)

        #expect(!containsCursorUpSequence(completedOverviewText))
        #expect(TerminalANSIText.stripANSI(completedOverviewText).contains("worker ✅ 1.20s"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount > 0)
    }

    @Test
    func agentWaitRedrawsUnchangedOverviewAfterTakingItsRewriteAnchor() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 120 }
        )
        let signature = "agents:unchanged"
        let overview = "\n👥 Sub-Agents:\n   worker ⏳\n"

        _ = await renderer.renderRememberedSubAgentOverview(
            signature: signature,
            text: overview,
            overviewBatchID: "wave",
            maximumInPlaceRows: 20
        )
        let initialOverviewRows = await renderer.snapshot().activeSubAgentOverviewRowCount
        let toolCall = presentedToolCall(
            id: "wait-for-unchanged-overview",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(
            toolCall,
            maximumInPlaceRows: 20
        )
        let started = await renderer.snapshot()
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        let result = await renderer.renderRememberedSubAgentOverview(
            signature: signature,
            text: overview,
            overviewBatchID: "wave",
            maximumInPlaceRows: 20
        )
        let refreshEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeRefresh)
        )
        let refreshed = await renderer.snapshot()

        #expect(initialOverviewRows > 0)
        #expect(started.activeToolCallID == toolCall.id)
        #expect(result == .rendered)
        #expect(
            refreshEvents.first?.text.hasPrefix(
                "\u{1B}[\(started.activeToolRenderedRowCount)A\r"
            ) == true
        )
        #expect(
            refreshEvents.plainText()
                .contains("worker ⏳")
        )
        #expect(refreshed.activeToolCallID == nil)
        #expect(refreshed.activeSubAgentOverviewRowCount > 0)
        #expect(refreshed.lastRenderedSubAgentOverviewSignature == signature)
    }
}
