import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    @Test
    func standardPreservesCompactANSICompletionWithoutSourceChanges() async {
        let toolCall = exampleEditFileCall(id: "standard-ansi-edit")
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            toolNow: { clock.now }
        )
        await renderer.writeToolCallStarted(toolCall)
        let startEventCount = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Updated", summary: "Updated")
        )
        let completion = await renderer.capturedText(droppingFirst: startEventCount)
        let compactCompletion = compactCompletionText(for: toolCall, newline: false)

        #expect(completion.contains(compactCompletion))
        #expect(!completion.contains("oldValue"))
        #expect(!completion.contains("newValue"))
    }

    @Test
    func standardKeepsPendingAndCompletionCompact() async {
        let old = (0..<150).map { "let old\($0) = \($0)" }.joined(separator: "\n")
        let new = (0..<150).map { "let new\($0) = \($0)" }.joined(separator: "\n")
        let toolCall = presentedToolCall(
            id: "large-edit",
            name: "local.editFile",
            argumentsObject: [
                "path": "/tmp/Large.swift",
                "old": old,
                "new": new
            ],
            argumentsJSON: "{}"
        )
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 120 }
        )

        await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 6)
        let startedEvents = await renderer.capturedWriteEvents()
        let startedText = startedEvents.plainText()
        #expect(!startedText.contains("old0"))
        #expect(!startedText.contains("new0"))

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Updated", summary: "Updated"),
            maximumInPlaceRows: 6
        )
        let completionText = await renderer.capturedPlainText(droppingFirst: startedEvents.count)

        #expect(!completionText.contains("old149"))
        #expect(!completionText.contains("new149"))
        #expect(!completionText.contains("truncated"))
    }

    /// Characterization: without source rows the standard block degenerates to
    /// exactly the compact block, byte for byte, with no appendix.
    @Test
    func standardCompletionWithoutSourceRowsIsExactlyTheCompactBlock() async throws {
        let toolCall = exampleReadFileCall(id: "standard-characterization-read")
        let clock = StreamingClock()
        let renderer = makeRenderer(standardErrorIsTerminal: true, toolNow: { clock.now })
        await renderer.writeToolCallStarted(toolCall)
        let startEventCount = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "let value = 1", summary: "Read")
        )
        let completion = await renderer.capturedText(droppingFirst: startEventCount)
        let compactCompletion = compactCompletionText(for: toolCall, newline: true)

        #expect(completion.hasSuffix(compactCompletion))
        let controlPrefix = String(completion.dropLast(compactCompletion.count))
        #expect(TerminalANSIText.stripANSI(controlPrefix).allSatisfy { $0 == "\r" || $0 == "\n" })
        #expect(!TerminalANSIText.stripANSI(completion).contains("let value = 1"))
    }

    @Test
    func standardShowsCompactStatusWithoutMutationSource() async {
        let toolCall = exampleEditFileCall(id: "standard-edit")
        let standard = makeRenderer(standardErrorIsTerminal: true)
        await standard.writeToolCallStarted(toolCall)
        await standard.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Updated", summary: "Updated")
        )
        let standardText = await standard.capturedPlainText()
        #expect(!standardText.contains("oldValue"))
        #expect(!standardText.contains("newValue"))
        #expect(standardText.contains("local.editFile"))
        #expect(standardText.contains("/tmp/Example.swift"))
        #expect(standardText.contains("✅"))
        #expect(!standardText.contains("kind:"))
        #expect(!standardText.contains("change:"))
        #expect(!standardText.contains("status:"))

    }

    @Test
    func standardHidesCodeAndDiffFromNonMutationPresentation() {
        let toolCall = presentedToolCall(
            id: "standard-inspect-source",
            name: "thirdparty.inspect",
            argumentsObject: [
                "code": "let hiddenSource = true",
                "old": "let before = 1",
                "new": "let after = 2"
            ],
            argumentsJSON: "{}",
            presentation: ToolPresentationDefinition(
                title: "Inspection",
                action: "Inspect",
                kind: .inspect,
                sections: [
                    .code(
                        label: "source",
                        value: .argument(["code"], format: .text)
                    ),
                    .diff(
                        label: "comparison",
                        old: .argument(["old"], format: .text),
                        new: .argument(["new"], format: .text)
                    )
                ]
            )
        )

        #expect(TerminalChat.standardToolCallRows(for: toolCall).isEmpty)
    }

    @Test
    func standardShowsCompactFileReadWithoutRawOutput() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = presentedToolCall(
            id: "read-details",
            name: "local.readFile",
            argumentsObject: ["path": "/tmp/Secret.swift"],
            argumentsJSON: #"{"path":"/tmp/Secret.swift"}"#
        )
        await renderer.writeToolCallStarted(toolCall)
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "let secret = true", summary: "Read")
        )
        let text = await renderer.capturedPlainText()
        #expect(text.contains("local.readFile"))
        #expect(text.contains("/tmp/Secret.swift"))
        #expect(!text.contains("let secret = true"))
        #expect(!text.contains("status:"))
        #expect(text.contains("⏳"))
        #expect(text.contains("✅"))
        let snapshot = await renderer.snapshot()
        #expect(snapshot.activeToolCallID == nil)
        #expect(snapshot.activeToolCallID == nil)

    }

    @Test
    func standardMultiEditCompletionRewritesPendingTitleWithDiffs() async {
        let maximumInPlaceRows = 11
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        let toolCall = presentedToolCall(
            id: "multi-edit-detailed",
            name: "local.multiEdit",
            argumentsObject: [
                "path": "Sources/Feature.swift",
                "edits": [
                    ["old": "let old = 1", "new": "let new = 2"],
                    ["old": "let before = false", "new": "let after = true"]
                ]
            ],
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(
            toolCall,
            maximumInPlaceRows: maximumInPlaceRows
        )
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "done", summary: "2 edits applied"),
            maximumInPlaceRows: maximumInPlaceRows
        )

        let completionEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventCountBeforeCompletion)
        )
        let completionText = completionEvents.plainText()
        let rewriteSequence = completionEvents.first?.text ?? ""

        #expect(started.activeToolRenderedRowCount <= maximumInPlaceRows - 1)
        #expect(
            rewriteSequence.hasPrefix(
                "\u{1B}[\(started.activeToolRenderedRowCount)A\r"
            )
        )
        #expect(completionText.components(separatedBy: "local.multiEdit").count - 1 == 1)
        #expect(!completionText.contains("parameters:"))
        #expect(!completionText.contains("old"))
        #expect(!completionText.contains("new"))
        #expect(!completionText.contains("let old = 1"))
        #expect(!completionText.contains("let new = 2"))
    }

    @Test
    func standardToolRowsStayWithinRewriteWidth() async throws {
        let terminalColumns = 40
        let longArgument = String(repeating: "x", count: 100)
        let renderer = makeRenderer(
            stdinIsTerminal: true,
            standardErrorIsTerminal: true,
            columnWidthProvider: { terminalColumns }
        )
        let toolCall = presentedToolCall(
            id: "tool-detailed-wrap",
            name: "local.exec",
            argumentsObject: ["command": longArgument],
            argumentsJSON: #"{"command":"placeholder"}"#
        )
        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let startedEvents = await renderer.capturedWriteEvents()
        let renderedStart = try #require(startedEvents.last?.text)
        let renderedRows = renderedStart
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        // Every standard row leaves one trailing cell so terminal auto-wrap
        // cannot add an unaccounted row beside the input overlay.
        #expect(renderedRows.count == started.activeToolRenderedRowCount)
        #expect(
            renderedRows.allSatisfy {
                TerminalANSIText.visibleWidth($0) <= terminalColumns
            }
        )

        let eventCountBeforeCompletion = startedEvents.count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )
        let completionEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventCountBeforeCompletion)
        )
        let clearSequence = try #require(completionEvents.first?.text)

        #expect(
            clearSequence.hasPrefix(
                "\u{1B}[\(started.activeToolRenderedRowCount)A\r"
            )
        )
        #expect(
            clearSequence.components(separatedBy: "\u{1B}[2K").count - 1
                == started.activeToolRenderedRowCount
        )
    }

    @Test
    func detailedMutationCompletionUsesTerminalSafeSideBySideBudget() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let toolCall = presentedToolCall(
            id: "detailed-crlf-tab-diff",
            name: "local.editFile",
            argumentsObject: [
                "path": "Sources/Feature.swift",
                "old": "// removed\r\n\tlet oldValue = 1",
                "new": "let newValue = 2\r\n\tlet replacement = 3"
            ],
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(toolCall)
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "", summary: "updated")
        )

        let completionText = await renderer.capturedText(on: .standardError, droppingFirst: eventCountBeforeCompletion)
        let visibleRows = TerminalANSIText.stripANSI(completionText)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let sideBySideRows = visibleRows.filter {
            $0.contains("// removed") && $0.contains("let newValue = 2")
        }

        #expect(sideBySideRows.isEmpty)
    }

    @Test
    func detailedMutationCompletionKeepsColumnsSeparateForAnsiHostilePayload() async {
        // End-to-end guard for the former in-band boundary sentinel: a payload
        // containing that exact sequence must not be able to split the row at
        // the wrong place or leak into the other column.
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 120 }
        )
        let toolCall = presentedToolCall(
            id: "detailed-ansi-collision",
            name: "local.editFile",
            argumentsObject: [
                "path": "Sources/Feature.swift",
                "old": "\u{1B}[0m │ let injected = 1",
                "new": "let replacement = 2"
            ],
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(toolCall)
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "", summary: "updated")
        )

        let completionText = await renderer.capturedText(on: .standardError, droppingFirst: eventCountBeforeCompletion)
        let visibleRows = TerminalANSIText.stripANSI(completionText)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let diffRows = visibleRows.filter {
            $0.contains("let injected = 1") && $0.contains("let replacement = 2")
        }

        #expect(diffRows.isEmpty)
    }

    @Test
    func detailedPatchBlockNeutralizesControlSequencesFromPatchDerivedTarget() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        let toolCall = presentedToolCall(
            id: "detailed-patch-injection",
            name: "local.applyPatch",
            argumentsObject: [
                "patch": "*** Update File: Sources/\u{1B}[2JInjected.swift\n@@\n-let a = 1\n+let b = 2\n"
            ],
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(toolCall)
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "", summary: "patched")
        )

        let text = await renderer.capturedText(on: .standardError)
        let visibleRows = TerminalANSIText.stripANSI(text)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)

        #expect(!text.contains("\u{1B}[2J"))
        #expect(!visibleRows.contains { $0.hasPrefix("target: ") })
        #expect(visibleRows.filter { !$0.hasPrefix("  ") }.allSatisfy { !$0.contains("\u{1B}") })
        #expect(visibleRows.allSatisfy { TerminalChat.displayWidth($0) <= 100 })
    }

    /// Characterization: a standard completion is the byte-identical compact
    /// block followed only by the source appendix. Anything preceding the shared
    /// compact bytes must be pure cursor control, never printable text.
    @Test
    func standardCompletionHasNoSourceAppendix() async throws {
        let toolCall = exampleEditFileCall(id: "standard-characterization-edit")
        let clock = StreamingClock()
        let renderer = makeRenderer(standardErrorIsTerminal: true, toolNow: { clock.now })
        await renderer.writeToolCallStarted(toolCall)
        let startEventCount = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Updated", summary: "Updated")
        )
        let completion = await renderer.capturedText(droppingFirst: startEventCount)
        let compactCompletion = compactCompletionText(for: toolCall, newline: false)

        let compactRange = try #require(completion.range(of: compactCompletion))
        let controlPrefix = String(completion[completion.startIndex..<compactRange.lowerBound])
        let appendix = String(completion[compactRange.upperBound...])

        #expect(TerminalANSIText.stripANSI(controlPrefix).allSatisfy { $0 == "\r" || $0 == "\n" })
        #expect(!TerminalANSIText.stripANSI(appendix).contains("oldValue"))
        #expect(!TerminalANSIText.stripANSI(appendix).contains("newValue"))
        // The appendix never repeats the compact prefix content.
        #expect(!TerminalANSIText.stripANSI(appendix).contains("local.editFile"))
        // No blank source appendix is emitted; the block is compact only.
    }
}
