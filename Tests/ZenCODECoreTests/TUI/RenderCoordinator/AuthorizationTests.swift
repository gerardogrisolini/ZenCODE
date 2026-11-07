import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    @Test
    func externalAuthorizationPromptRelinquishesToolRowsBeforeCompletion() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = presentedToolCall(
            id: "authorized-delete",
            name: "local.delete",
            argumentsObject: ["path": "ProvaTest.swift"],
            argumentsJSON: #"{"path":"ProvaTest.swift"}"#
        )
        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()

        await renderer.beginExternalTerminalPrompt()
        let eventCountBeforeCard = await renderer.capturedWriteEvents().count
        let guarded = await renderer.snapshot()
        let deferred = await renderer.renderTaskGraphOverview(
            signature: "graph:during-authorization",
            markdown: "## Tasks\n\n- waiting for authorization\n"
        )

        #expect(started.activeToolCallID == toolCall.id)
        #expect(started.activeToolRenderedRowCount > 0)
        #expect(guarded.activeToolCallID == nil)
        #expect(guarded.activeToolRenderedRowCount == 0)
        #expect(deferred == .deferred)

        await renderer.endExternalTerminalPrompt()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Deleted", summary: "Deleted")
        )

        let completionText = await renderer.capturedText(droppingFirst: eventCountBeforeCompletion)
        #expect(!containsCursorUpSequence(completionText))
        #expect(completionText.contains("✅"))

        let events = await renderer.capturedWriteEvents()
        let screen = terminalScreenText(
            events.prefix(eventCountBeforeCard).renderedText()
                + permissionCardText
                + events.dropFirst(eventCountBeforeCard).renderedText()
        )
        #expect(screen.contains("Authorization footer"))
        #expect(screen.components(separatedBy: "local.delete").count - 1 == 1)
    }

    @Test(arguments: [
        ("memory.search", ["query": "authorization redraw"]),
        ("memory.update", ["id": "memory-entry-id", "content": "Updated entry"])
    ])
    func externalAuthorizationDefersMemoryToolRenderingUntilTheCardCloses(
        toolName: String,
        arguments: [String: String]
    ) async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        let toolCall = presentedToolCall(
            id: "\(toolName)-during-authorization",
            name: toolName,
            argumentsObject: arguments,
            argumentsJSON: "{}"
        )

        await renderer.beginExternalTerminalPrompt()
        let eventCountWhileCardIsOpen = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 20)
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Completed", summary: "Completed"),
            maximumInPlaceRows: 20
        )

        // The authorization reader owns the shared cursor until the operator
        // answers. Logical progress may continue, but no terminal byte may be
        // emitted into the card while it is waiting for that answer.
        #expect(
            await renderer.capturedWriteEvents().count
                == eventCountWhileCardIsOpen
        )

        await renderer.endExternalTerminalPrompt()
        let replay = await renderer.capturedText()
        let screen = terminalScreenText(
            permissionCardText + replay
        )
        #expect(screen.contains("Authorization footer"))
        #expect(screen.components(separatedBy: toolName).count - 1 == 1)
        #expect(screen.contains("✅"))
        #expect(!screen.contains("⏳"))
    }

    @Test(arguments: [
        ("memory.search", ["query": "semantic fallback"]),
        ("memory.update", ["id": "memory-entry-id", "content": "Updated entry"])
    ])
    func memoryFallbackDiagnosticWaitsForCompletionAndKeepsOneVisibleHeader(
        toolName: String,
        arguments: [String: String]
    ) async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        let toolCall = presentedToolCall(
            id: "\(toolName)-semantic-fallback",
            name: toolName,
            argumentsObject: arguments,
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 20)
        let eventCountWhilePending = await renderer.capturedWriteEvents().count

        await renderer.writeToolAdjacentSystemMessage(
            "[MemoryService][ERROR] semantic embedding failed; continuing with BM25-only results.\n"
        )
        #expect(await renderer.capturedWriteEvents().count == eventCountWhilePending)

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Completed", summary: "Completed"),
            maximumInPlaceRows: 20
        )
        let screen = terminalScreenText(
            await renderer.capturedText()
        )
        let completionRange = screen.range(of: "✅")
        let diagnosticRange = screen.range(of: "[MemoryService][ERROR]")
        #expect(screen.components(separatedBy: toolName).count - 1 == 1)
        #expect(!screen.contains("⏳"))
        #expect(completionRange != nil)
        #expect(diagnosticRange != nil)
        if let completionRange, let diagnosticRange {
            #expect(completionRange.lowerBound < diagnosticRange.lowerBound)
        }
    }

    @Test
    func externalAuthorizationReanchorsLatestSubAgentOverviewBelowTheCard() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:before-authorization",
            text: "\n👥 Sub-Agents:\n   worker one running\n",
            overviewBatchID: "wave",
            maximumInPlaceRows: 20
        )

        await renderer.beginExternalTerminalPrompt()
        let eventCountBeforeCard = await renderer.capturedWriteEvents().count
        let deferred = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:during-authorization",
            text: "\n👥 Sub-Agents:\n   worker one completed\n   worker two running\n",
            overviewBatchID: "wave",
            maximumInPlaceRows: 20
        )
        #expect(deferred == .deferred)
        #expect(await renderer.capturedWriteEvents().count == eventCountBeforeCard)

        await renderer.endExternalTerminalPrompt()
        let events = await renderer.capturedWriteEvents()
        let beforeCard = events.prefix(eventCountBeforeCard).renderedText()
        let afterCard = events.dropFirst(eventCountBeforeCard).renderedText()
        let screen = terminalScreenText(
            beforeCard + permissionCardText + afterCard
        )

        #expect(screen.contains("Authorization command"))
        #expect(screen.contains("Authorization footer"))
        #expect(screen.components(separatedBy: "👥 Sub-Agents:").count - 1 == 1)
        #expect(!screen.contains("worker one running"))
        #expect(screen.contains("worker one completed"))
        #expect(screen.contains("worker two running"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount > 0)
    }
}

private let permissionCardText = """

╭─ Authorization ─╮
│ Authorization command │
├─────────────────┤
│ Authorization footer  │
╰─────────────────╯

"""
