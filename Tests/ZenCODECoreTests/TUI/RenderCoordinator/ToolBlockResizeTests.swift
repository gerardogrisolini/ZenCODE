import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatToolBlockResizeTests {
    @Test
    func compactResizeFromWideToNarrowSkipsDestructiveClear() async {
        let (widthBox, renderer) = makeResizableRenderer(width: 100)
        let toolCall = presentedToolCall(
            id: "resize-compact-100-40",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents()
            .count
        #expect(started.activeToolCallID == toolCall.id)
        #expect(started.activeToolRenderedRowCount > 0)

        // Simulate terminal shrink between start and completion.
        widthBox.width = 40
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let events = await renderer.capturedWriteEvents()
        let completionEvents = Array(events.dropFirst(eventCountBeforeCompletion))
        let completionText = completionEvents.renderedText()

        // No destructive cursor-up sequence — the stale row count must not be
        // used to move the cursor or erase rows.
        #expect(!containsCursorUpSequence(completionText))
        // The completed block (✅) is present in append-only mode.
        #expect(completionText.contains("✅"))
        // The pending block (⏳) remains visible because we skipped the clear.
        let stderr = events.renderedText(on: .standardError)
        #expect(stderr.contains("⏳"))
        #expect(stderr.contains("✅"))
    }

    @Test
    func compactResizeFromNarrowToWideSkipsDestructiveClear() async {
        let (widthBox, renderer) = makeResizableRenderer(width: 40)
        let toolCall = presentedToolCall(
            id: "resize-compact-40-100",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(toolCall)
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents()
            .count

        // Simulate terminal grow between start and completion.
        widthBox.width = 100
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let events = await renderer.capturedWriteEvents()
        let completionEvents = Array(events.dropFirst(eventCountBeforeCompletion))
        let completionText = completionEvents.renderedText()

        #expect(!containsCursorUpSequence(completionText))
        #expect(completionText.contains("✅"))
    }

    @Test
    func detailedResizeFromWideToNarrowSkipsDestructiveClear() async {
        let (widthBox, renderer) = makeResizableRenderer(width: 100)
        let toolCall = presentedToolCall(
            id: "resize-detailed-100-40",
            name: "local.exec",
            argumentsObject: ["command": "printf done"],
            argumentsJSON: #"{"command":"printf done"}"#
        )

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents()
            .count
        #expect(started.activeToolCallID == toolCall.id)
        #expect(started.activeToolRenderedRowCount > 0)

        // Simulate terminal shrink between start and completion.
        widthBox.width = 40
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let events = await renderer.capturedWriteEvents()
        let completionEvents = Array(events.dropFirst(eventCountBeforeCompletion))
        let completionText = completionEvents.renderedText()

        #expect(!containsCursorUpSequence(completionText))
        #expect(completionText.contains("✅"))
    }

    @Test
    func compactNoResizeClearsAsBefore() async {
        let (widthBox, renderer) = makeResizableRenderer(width: 100)
        let toolCall = presentedToolCall(
            id: "resize-compact-stable",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents()
            .count
        #expect(started.activeToolRenderedRowCount > 0)

        // Width unchanged: the completion should emit the normal destructive
        // clear + rewrite (same behaviour as before the safety fuse).
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let events = await renderer.capturedWriteEvents()
        let completionEvents = Array(events.dropFirst(eventCountBeforeCompletion))
        let rewriteSequence = completionEvents.first?.text ?? ""

        #expect(
            rewriteSequence.hasPrefix(
                "\u{1B}[\(started.activeToolRenderedRowCount)A\r"
            )
        )
        #expect(
            rewriteSequence.components(separatedBy: "\u{1B}[2K").count - 1
                == started.activeToolRenderedRowCount
        )
        #expect(!completionEvents.renderedText().contains("\u{1B}[J"))
    }

    @Test
    func detailedNoResizeClearsAsBefore() async {
        let (widthBox, renderer) = makeResizableRenderer(width: 100)
        let toolCall = presentedToolCall(
            id: "resize-detailed-stable",
            name: "local.exec",
            argumentsObject: ["command": "printf done"],
            argumentsJSON: #"{"command":"printf done"}"#
        )

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents()
            .count
        #expect(started.activeToolRenderedRowCount > 0)

        // Width unchanged: normal destructive clear + rewrite.
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let events = await renderer.capturedWriteEvents()
        let completionEvents = Array(events.dropFirst(eventCountBeforeCompletion))
        let rewriteSequence = completionEvents.first?.text ?? ""

        #expect(
            rewriteSequence.hasPrefix(
                "\u{1B}[\(started.activeToolRenderedRowCount)A\r"
            )
        )
        #expect(
            rewriteSequence.components(separatedBy: "\u{1B}[2K").count - 1
                == started.activeToolRenderedRowCount
        )
        #expect(!completionEvents.renderedText().contains("\u{1B}[J"))
    }
}
