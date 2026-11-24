import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    private func multiReadCall(_ id: String) -> DirectAgentToolCall {
        presentedToolCall(
            id: id,
            name: "local.multiRead",
            argumentsObject: ["paths": ["Sources/A.swift", "Sources/B.swift", "Sources/C.swift"]],
            argumentsJSON: #"{"paths":["Sources/A.swift","Sources/B.swift","Sources/C.swift"]}"#
        )
    }

    @Test(arguments: [2, 3])
    func multiReadPendingFitsSmallRewriteBudget(_ height: Int) async {
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { 100 })
        let call = multiReadCall("small-\(height)")
        await renderer.writeToolCallStarted(call, maximumInPlaceRows: height)
        let started = await renderer.snapshot()
        let startText = await renderer.capturedText(on: .standardError)
        #expect(started.activeToolRenderedRowCount <= height - 1)
        #expect(startText.contains("⏳"))
        #expect(!startText.contains("Sources/A.swift"))
        let beforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            call, result: DirectAgentToolResult(output: "Read", summary: "Read"),
            maximumInPlaceRows: height
        )
        let completion = await renderer.capturedText(droppingFirst: beforeCompletion)
        #expect(containsCursorUpSequence(completion))
        let screen = terminalScreenText(await renderer.capturedText(on: .standardError), width: 100)
        #expect(!screen.contains("⏳"))
        #expect(screen.components(separatedBy: "local.multiRead").count - 1 == 1)
        for path in ["Sources/A.swift", "Sources/B.swift", "Sources/C.swift"] {
            #expect(screen.components(separatedBy: path).count - 1 == 1)
        }
        #expect(screen.contains("✅"))
    }

    @Test(arguments: [0, 1])
    func multiReadWithoutReplaceableRowsOnlyDrawsCompletion(_ height: Int) async {
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { 100 })
        let call = multiReadCall("zero-\(height)")
        await renderer.writeToolCallStarted(call, maximumInPlaceRows: height)
        let start = await renderer.capturedText(on: .standardError)
        #expect(!start.contains("⏳"))
        #expect(!start.contains("Sources/A.swift"))
        #expect(await renderer.snapshot().activeToolCallID == nil)
        let beforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            call, result: DirectAgentToolResult(output: "Read", summary: "Read"),
            maximumInPlaceRows: height
        )
        #expect(!containsCursorUpSequence(await renderer.capturedText(droppingFirst: beforeCompletion)))
        let screen = terminalScreenText(await renderer.capturedText(on: .standardError), width: 100)
        #expect(screen.components(separatedBy: "local.multiRead").count - 1 == 1)
        for path in ["Sources/A.swift", "Sources/B.swift", "Sources/C.swift"] {
            #expect(screen.components(separatedBy: path).count - 1 == 1)
        }
        #expect(screen.contains("✅"))
    }

    @Test
    func multiReadPendingKeepsAllTargetsWhenItFitsExactly() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { 100 })
        let call = multiReadCall("fits")
        await renderer.writeToolCallStarted(call, maximumInPlaceRows: 6)
        let started = await renderer.snapshot()
        let startText = await renderer.capturedText(on: .standardError)
        #expect(started.activeToolRenderedRowCount == 5)
        for path in ["Sources/A.swift", "Sources/B.swift", "Sources/C.swift"] {
            #expect(startText.contains(path))
        }
        let beforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            call, result: DirectAgentToolResult(output: "Read", summary: "Read"),
            maximumInPlaceRows: 6
        )
        #expect(containsCursorUpSequence(await renderer.capturedText(droppingFirst: beforeCompletion)))
        let screen = terminalScreenText(await renderer.capturedText(on: .standardError), width: 100)
        #expect(!screen.contains("⏳"))
        for path in ["Sources/A.swift", "Sources/B.swift", "Sources/C.swift"] {
            #expect(screen.components(separatedBy: path).count - 1 == 1)
        }
    }

    @Test
    func multiReadPendingDoesNotRewriteAfterHeightShrinks() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { 100 })
        let call = multiReadCall("shrunk")
        await renderer.writeToolCallStarted(call, maximumInPlaceRows: 6)
        let beforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            call, result: DirectAgentToolResult(output: "Read", summary: "Read"),
            maximumInPlaceRows: 3
        )
        #expect(!containsCursorUpSequence(await renderer.capturedText(droppingFirst: beforeCompletion)))
    }

    @Test
    func multiReadDetachedForOverlayCanReturnInSmallerBudget() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { 100 })
        let call = multiReadCall("overlay")
        await renderer.writeToolCallStarted(call, maximumInPlaceRows: 6)
        await renderer.beginBottomOverlayTransition(maximumInPlaceRows: 6)
        await renderer.endBottomOverlayTransition(maximumInPlaceRows: 3)
        let replay = await renderer.snapshot()
        #expect(replay.activeToolCallID == call.id)
        #expect(replay.activeToolRenderedRowCount <= 2)
        let beforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            call, result: DirectAgentToolResult(output: "Read", summary: "Read"),
            maximumInPlaceRows: 3
        )
        #expect(containsCursorUpSequence(await renderer.capturedText(droppingFirst: beforeCompletion)))
        let screen = terminalScreenText(await renderer.capturedText(on: .standardError), width: 100)
        #expect(!screen.contains("⏳"))
        for path in ["Sources/A.swift", "Sources/B.swift", "Sources/C.swift"] {
            #expect(screen.components(separatedBy: path).count - 1 == 1)
        }
    }

    @Test
    func multiReadStartedDuringOverlayUsesNewBudget() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { 100 })
        let call = multiReadCall("overlay-start")
        await renderer.beginBottomOverlayTransition(maximumInPlaceRows: 6)
        await renderer.writeToolCallStarted(call, maximumInPlaceRows: 6)
        await renderer.endBottomOverlayTransition(maximumInPlaceRows: 3)
        #expect(await renderer.snapshot().activeToolRenderedRowCount <= 2)
        let beforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            call, result: DirectAgentToolResult(output: "Read", summary: "Read"),
            maximumInPlaceRows: 3
        )
        #expect(containsCursorUpSequence(await renderer.capturedText(droppingFirst: beforeCompletion)))
        let screen = terminalScreenText(await renderer.capturedText(on: .standardError), width: 100)
        #expect(!screen.contains("⏳"))
        for path in ["Sources/A.swift", "Sources/B.swift", "Sources/C.swift"] {
            #expect(screen.components(separatedBy: path).count - 1 == 1)
        }
    }

    @Test
    func multiReadDeferredByExternalPromptUsesItsBudget() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { 100 })
        let call = multiReadCall("prompt")
        await renderer.beginExternalTerminalPrompt()
        await renderer.writeToolCallStarted(call, maximumInPlaceRows: 3)
        await renderer.endExternalTerminalPrompt()
        #expect(await renderer.snapshot().activeToolRenderedRowCount <= 2)
        let beforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            call, result: DirectAgentToolResult(output: "Read", summary: "Read"),
            maximumInPlaceRows: 3
        )
        #expect(containsCursorUpSequence(await renderer.capturedText(droppingFirst: beforeCompletion)))
        let screen = terminalScreenText(await renderer.capturedText(on: .standardError), width: 100)
        #expect(!screen.contains("⏳"))
        for path in ["Sources/A.swift", "Sources/B.swift", "Sources/C.swift"] {
            #expect(screen.components(separatedBy: path).count - 1 == 1)
        }
    }
}
