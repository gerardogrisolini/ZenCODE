//
//  ToolCallPreviewTests.swift
//  ZenCODE
//
//  The coordinator side of the live file write/edit preview: the transcript
//  preparation before its header, the writes that interrupt it and the text
//  that reopens it, the end of a call and of a turn, overviews held back
//  while its rows are open, the compact tool block that follows it, and the
//  repaint as a terminal and the primary screen show it.
//
//  The tool block merges into the preview (only its status row, without the
//  header, and without the target too when the path reached the header) when
//  the record of the ended call shows the same canonical tool and target, its
//  rows were still on screen, nothing was written in between, and the
//  terminal can rewrite the block in place; the merge survives a
//  bottom-overlay transition, whose writes stay in the footer. Every other
//  case keeps the full block: another call drawn after it, interleaved
//  output, a suspended call, a turn boundary, a different tool, a different
//  path, a channel that cannot rewrite, and a completion that lost the
//  block's rows.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite("Terminal chat tool-call preview")
struct TerminalChatToolCallPreviewTests: RenderCoordinatorTestSupport {
    private static let path = "/tmp/Example.swift"

    private static var wroteOneLine: DirectAgentToolResult {
        DirectAgentToolResult(output: "Wrote 1 line", summary: "Wrote 1 line")
    }

    func writePreview(
        content: [String],
        path: String = Self.path,
        ends: Bool = true
    ) -> [DirectAgentToolCallPreview] {
        var events: [DirectAgentToolCallPreview] = [
            .toolStarted(name: "local.writeFile"),
            .parameterStarted(name: "path"),
            .parameterText(path),
            .parameterEnded,
            .parameterStarted(name: "content")
        ]
        events += content.map(DirectAgentToolCallPreview.parameterText)
        if ends {
            events += [.parameterEnded, .ended]
        }
        return events
    }

    func send(
        _ events: [DirectAgentToolCallPreview],
        to renderer: TerminalChatRenderCoordinator
    ) async {
        for event in events {
            await renderer.writeToolCallPreview(event)
        }
    }

    /// A call to a drawn tool with `path` as its target, as the executor
    /// receives it after its preview.
    private func fileCall(
        id: String,
        name: String = "local.writeFile",
        path: String = Self.path
    ) -> DirectAgentToolCall {
        let arguments: [String: String] = name == "local.editFile"
            ? ["path": path, "old": "let x = 0\n", "new": "let x = 1\n"]
            : ["path": path, "content": "let x = 1\n"]
        let json = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return presentedToolCall(id: id, name: name, argumentsObject: arguments, argumentsJSON: json)
    }

    /// A call to `local.multiEdit` with `path` as its target, as the executor
    /// receives it after its preview.
    private func multiEditCall(id: String, path: String = Self.path) -> DirectAgentToolCall {
        let arguments: [String: Any] = [
            "path": path,
            "edits": [
                ["old": "let x = 0", "new": "let x = 1"],
                ["old": "let y = 0", "new": "let y = 1"]
            ]
        ]
        let json = (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
        return presentedToolCall(id: id, name: "local.multiEdit", argumentsObject: arguments, argumentsJSON: json)
    }

    private func screen(
        of renderer: TerminalChatRenderCoordinator,
        width: Int = 80
    ) async -> String {
        terminalScreenText(await renderer.capturedText(on: .standardError), width: width)
    }

    // MARK: - Preparation

    @Test
    func thePreviewClosesTheThoughtInProgress() async throws {
        let renderer = makeRenderer(standardErrorIsTerminal: true)

        await renderer.writeThought("Planning the file")
        #expect(await renderer.snapshot().isStreamingThoughtOutput)
        await renderer.writeToolCallPreview(.toolStarted(name: "local.writeFile"))

        #expect(await !renderer.snapshot().isStreamingThoughtOutput)
        #expect(await renderer.isStreamingToolCallPreview)
        await renderer.flushChatOutput()
        let stderr = await renderer.capturedPlainText(on: .standardError)
        let thought = try #require(stderr.range(of: "Planning the file"))
        let header = try #require(stderr.range(of: "🛠️  local.writeFile"))
        #expect(thought.upperBound <= header.lowerBound)
        // The thought's blank separator row is the tool separator too.
        #expect(stderr.contains("Planning the file\n\n🛠️  local.writeFile"))
    }

    @Test
    func aToolThatIsNotDrawnWritesNothingAndClosesNothing() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)

        await renderer.writeThought("Planning")
        await send([
            .toolStarted(name: "local.applyPatch"),
            .parameterStarted(name: "path"),
            .parameterText(Self.path),
            .parameterEnded,
            .ended
        ], to: renderer)

        #expect(await renderer.snapshot().isStreamingThoughtOutput)
        #expect(await !renderer.isStreamingToolCallPreview)
        #expect(await renderer.capturedWriteEvents().isEmpty)
    }

    @Test
    func aNonInteractiveChannelReceivesThePreviewAsPlainText() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await send(writePreview(content: ["let x = 1\n", "\u{1B}[2Jy\n"]), to: renderer)

        let stderr = await renderer.capturedText(on: .standardError)
        #expect(stderr == "🛠️  local.writeFile /tmp/Example.swift\nlet x = 1\n␛[2Jy\n")
    }

    @Test
    func blankSourceRowsAreKeptAsWritten() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await send(writePreview(content: ["a\n\n\n\nb\n"]), to: renderer)

        #expect(await renderer.capturedText(on: .standardError)
            == "🛠️  local.writeFile /tmp/Example.swift\na\n\n\n\nb\n")
    }

    // MARK: - Tool block after the preview

    @Test
    func theCompactToolBlockAfterThePreviewKeepsOnlyItsStatus() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let reference = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = fileCall(id: "write-1")

        await send(writePreview(content: ["let x = 1\n"]), to: renderer)
        // The preview is append-only transcript: it owns no tool rows.
        #expect(await renderer.snapshot().activeToolCallID == nil)

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        #expect(started.activeToolCallID == toolCall.id)
        // The preview header already showed the canonical name and the path:
        // the block owns one status row and no separator.
        #expect(started.activeToolRenderedRowCount == 1)
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(toolCall, result: Self.wroteOneLine)

        let events = await renderer.capturedWriteEvents()
        let rewrite = events.dropFirst(eventCountBeforeCompletion).first?.text ?? ""
        #expect(rewrite.hasPrefix("\u{1B}[1A\r"))
        #expect(rewrite.components(separatedBy: "\u{1B}[2K").count - 1 == 1)
        #expect(await renderer.snapshot().activeToolCallID == nil)
        #expect(await renderer.previewMergedToolCallID == nil)

        let completed = terminalScreenText(events.renderedText(on: .standardError), width: columns)
        #expect(completed == "\n\n🛠️  local.writeFile /tmp/Example.swift\nlet x = 1\n✅\n\n")
        #expect(!completed.contains("⏳"))

        // Without a preview the block keeps its header and its target.
        await reference.writeToolCallStarted(toolCall)
        await reference.writeToolCallCompleted(toolCall, result: Self.wroteOneLine)
        #expect(await screen(of: reference, width: columns) == "\n\n🛠️  local.writeFile\n/tmp/Example.swift ✅\n\n")
    }

    @Test
    func theToolBlockOfAMultiEditAfterThePreviewKeepsOnlyItsStatus() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let reference = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = multiEditCall(id: "multi-1")
        let applied = DirectAgentToolResult(output: "Applied 2 edits", summary: "Applied 2 edits")

        // The JSON of `edits` arrives cut inside a key: only the old and new
        // text of each edit is drawn.
        await send([
            .toolStarted(name: "local.multiEdit"),
            .parameterStarted(name: "path"),
            .parameterText(Self.path),
            .parameterEnded,
            .parameterStarted(name: "edits"),
            .parameterText(#"[{"old": "let x = 0", "ne"#),
            .parameterText(#"w": "let x = 1"}, {"old": "let y = 0\n", "new": "let y = 1"}]"#),
            .parameterEnded,
            .ended
        ], to: renderer)
        #expect(await renderer.snapshot().activeToolCallID == nil)

        await renderer.writeToolCallStarted(toolCall)
        // The preview header already showed the canonical name and the path.
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 1)
        #expect(await renderer.previewMergedToolCallID == toolCall.id)
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(toolCall, result: applied)

        let events = await renderer.capturedWriteEvents()
        let rewrite = events.dropFirst(eventCountBeforeCompletion).first?.text ?? ""
        #expect(rewrite.hasPrefix("\u{1B}[1A\r"))
        #expect(rewrite.components(separatedBy: "\u{1B}[2K").count - 1 == 1)
        let completed = terminalScreenText(events.renderedText(on: .standardError), width: columns)
        #expect(completed == [
            "", "", "🛠️  local.multiEdit /tmp/Example.swift",
            "- let x = 0", "+ let x = 1", "- let y = 0", "+ let y = 1",
            "✅", "", ""
        ].joined(separator: "\n"))
        #expect(completed.components(separatedBy: "local.multiEdit").count - 1 == 1)

        // Without a preview the block keeps its header and its target.
        await reference.writeToolCallStarted(toolCall)
        await reference.writeToolCallCompleted(toolCall, result: applied)
        #expect(await screen(of: reference, width: columns) == "\n\n🛠️  local.multiEdit\n/tmp/Example.swift ✅\n\n")
    }

    @Test
    func aBlockWhosePathThePreviewDidNotShowKeepsItsOwnHeader() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = fileCall(id: "write-1")

        // The preview streamed a path the call does not carry.
        await send(writePreview(content: ["let x = 1\n"], path: "/tmp/Other.swift"), to: renderer)
        await renderer.writeToolCallStarted(toolCall)
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 2)
        await renderer.writeToolCallCompleted(toolCall, result: Self.wroteOneLine)

        let shown = await screen(of: renderer, width: columns)
        #expect(shown == [
            "", "", "🛠️  local.writeFile /tmp/Other.swift", "let x = 1",
            "", "🛠️  local.writeFile", "/tmp/Example.swift ✅", "", ""
        ].joined(separator: "\n"))
    }

    @Test
    func aBlockWhosePathArrivedAfterTheTextKeepsItsTargetWithoutTheHeader() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = fileCall(id: "write-1")

        // The content arrived before the path, so the header closed without it.
        await send(writeWithContentBeforeThePath(path: Self.path), to: renderer)
        await renderer.writeToolCallStarted(toolCall)
        // The header named the tool: the block owns only its status row,
        // which keeps the target the header could not show.
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 1)
        #expect(await renderer.previewMergedToolCallID == toolCall.id)
        #expect(await screen(of: renderer, width: columns)
            == "\n\n🛠️  local.writeFile\nlet x = 1\n/tmp/Example.swift ⏳\n")
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(toolCall, result: Self.wroteOneLine)

        let events = await renderer.capturedWriteEvents()
        let rewrite = events.dropFirst(eventCountBeforeCompletion).first?.text ?? ""
        #expect(rewrite.hasPrefix("\u{1B}[1A\r"))
        #expect(rewrite.components(separatedBy: "\u{1B}[2K").count - 1 == 1)
        #expect(await renderer.previewMergedToolCallID == nil)
        let shown = terminalScreenText(events.renderedText(on: .standardError), width: columns)
        #expect(shown == [
            "", "", "🛠️  local.writeFile", "let x = 1",
            "/tmp/Example.swift ✅", "", ""
        ].joined(separator: "\n"))
        #expect(shown.components(separatedBy: "local.writeFile").count - 1 == 1)
    }

    @Test
    func anEditWrittenWithThePathLastIsNotFollowedByASecondHeader() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = fileCall(id: "edit-1", name: "local.editFile")

        // The arguments in alphabetical order, as DS4 models may write them.
        await send([
            .toolStarted(name: "local.editFile"),
            .parameterStarted(name: "new"),
            .parameterText("let x = 1\n"),
            .parameterEnded,
            .parameterStarted(name: "old"),
            .parameterText("let x = 0\n"),
            .parameterEnded,
            .parameterStarted(name: "path"),
            .parameterText(Self.path),
            .parameterEnded,
            .ended
        ], to: renderer)
        await renderer.writeToolCallStarted(toolCall)
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 1)
        await renderer.writeToolCallCompleted(toolCall, result: Self.wroteOneLine)

        let shown = await screen(of: renderer, width: columns)
        #expect(shown == [
            "", "", "🛠️  local.editFile", "+ let x = 1", "- let x = 0",
            "/tmp/Example.swift ✅", "", ""
        ].joined(separator: "\n"))
        #expect(shown.components(separatedBy: "local.editFile").count - 1 == 1)
    }

    @Test
    func aMultiEditWrittenWithThePathLastIsNotFollowedByASecondHeader() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = multiEditCall(id: "multi-1")
        let applied = DirectAgentToolResult(output: "Applied 2 edits", summary: "Applied 2 edits")

        await send([
            .toolStarted(name: "local.multiEdit"),
            .parameterStarted(name: "edits"),
            .parameterText(#"[{"new": "let x = 1", "old": "let x = 0"}]"#),
            .parameterEnded,
            .parameterStarted(name: "path"),
            .parameterText(Self.path),
            .parameterEnded,
            .ended
        ], to: renderer)
        await renderer.writeToolCallStarted(toolCall)
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 1)
        await renderer.writeToolCallCompleted(toolCall, result: applied)

        let shown = await screen(of: renderer, width: columns)
        #expect(shown == [
            "", "", "🛠️  local.multiEdit", "+ let x = 1", "- let x = 0",
            "/tmp/Example.swift ✅", "", ""
        ].joined(separator: "\n"))
    }

    @Test
    func aSuspendedCallWhosePathArrivedLastKeepsTheFullBlock() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = fileCall(id: "write-1")

        // A message lands after the whole call but before its end: the call
        // ends suspended, so the rows above the block are not the preview's.
        let events = writeWithContentBeforeThePath(path: Self.path)
        await send(Array(events.dropLast()), to: renderer)
        await renderer.writeSystemMessage("Note\n")
        await renderer.writeToolCallPreview(.ended)
        await renderer.writeToolCallStarted(toolCall)
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 2)
        #expect(await renderer.previewMergedToolCallID == nil)
        await renderer.writeToolCallCompleted(toolCall, result: Self.wroteOneLine)

        let shown = await screen(of: renderer, width: columns)
        #expect(shown == [
            "", "", "🛠️  local.writeFile", "let x = 1", "Note",
            "", "🛠️  local.writeFile", "/tmp/Example.swift ✅", "", ""
        ].joined(separator: "\n"))
    }

    @Test
    func theMergedBlockStartsWithOnlyItsStatusRow() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = fileCall(id: "write-1")

        await send(writePreview(content: ["let x = 1\n"]), to: renderer)
        await renderer.writeToolCallStarted(toolCall)

        #expect(await renderer.snapshot().activeToolRenderedRowCount == 1)
        #expect(await renderer.previewMergedToolCallID == toolCall.id)
        #expect(await screen(of: renderer, width: columns)
            == "\n\n🛠️  local.writeFile /tmp/Example.swift\nlet x = 1\n⏳\n")
    }

    @Test
    func twoDrawnCallsOfOneBlockKeepTheirOwnHeaders() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })

        // One generated block draws both calls before either runs: the first
        // block no longer follows its preview, and the second finds no record.
        await send(writePreview(content: ["let x = 1\n"], path: "/tmp/A.swift", ends: false) + [
            .parameterEnded,
            .toolStarted(name: "local.editFile"),
            .parameterStarted(name: "path"),
            .parameterText("/tmp/B.swift"),
            .parameterEnded,
            .parameterStarted(name: "new"),
            .parameterText("let x = 1\n"),
            .parameterEnded,
            .ended
        ], to: renderer)
        await renderer.writeToolCallStarted(fileCall(id: "write-a", path: "/tmp/A.swift"))
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 2)
        await renderer.writeToolCallStarted(fileCall(id: "edit-b", name: "local.editFile", path: "/tmp/B.swift"))
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 2)
        #expect(await renderer.previewMergedToolCallID == nil)

        let shown = await screen(of: renderer, width: columns)
        #expect(shown == [
            "", "", "🛠️  local.writeFile /tmp/A.swift", "let x = 1",
            "", "🛠️  local.editFile /tmp/B.swift", "+ let x = 1",
            "", "🛠️  local.writeFile", "/tmp/A.swift ⏳",
            "", "🛠️  local.editFile", "/tmp/B.swift ⏳", ""
        ].joined(separator: "\n"))
    }

    @Test
    func outputBetweenThePreviewAndTheBlockKeepsTheHeader() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = fileCall(id: "write-1")

        await send(writePreview(content: ["let x = 1\n"]), to: renderer)
        await renderer.writeSystemMessage("Note\n")
        await renderer.writeToolCallStarted(toolCall)
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 2)
        await renderer.writeToolCallCompleted(toolCall, result: Self.wroteOneLine)

        let shown = await screen(of: renderer, width: columns)
        #expect(shown == [
            "", "", "🛠️  local.writeFile /tmp/Example.swift", "let x = 1", "Note",
            "", "🛠️  local.writeFile", "/tmp/Example.swift ✅", "", ""
        ].joined(separator: "\n"))
    }

    @Test
    func aSuspendedCallThatEndsKeepsItsHeader() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = fileCall(id: "write-1")

        await send(writePreview(content: ["let x = 1\n"], ends: false), to: renderer)
        await renderer.writeSystemMessage("Note\n")
        await renderer.writeToolCallPreview(.ended)
        await renderer.writeToolCallStarted(toolCall)
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 2)
        await renderer.writeToolCallCompleted(toolCall, result: Self.wroteOneLine)

        let shown = await screen(of: renderer, width: columns)
        #expect(shown == [
            "", "", "🛠️  local.writeFile /tmp/Example.swift", "let x = 1", "Note",
            "", "🛠️  local.writeFile", "/tmp/Example.swift ✅", "", ""
        ].joined(separator: "\n"))
    }

    @Test
    func aCompletionAfterTheBlockLostItsRowsKeepsTheHeader() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = fileCall(id: "write-1")

        await send(writePreview(content: ["let x = 1\n"]), to: renderer)
        await renderer.writeToolCallStarted(toolCall)
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 1)
        // The message ends the block's ownership of its row: the completion
        // is appended and cannot lean on the preview header above it.
        await renderer.writeSystemMessage("Note\n")
        await renderer.writeToolCallCompleted(toolCall, result: Self.wroteOneLine)

        #expect(await renderer.previewMergedToolCallID == nil)
        let shown = await screen(of: renderer, width: columns)
        #expect(shown == [
            "", "", "🛠️  local.writeFile /tmp/Example.swift", "let x = 1", "⏳", "", "Note",
            "🛠️  local.writeFile", "/tmp/Example.swift ✅", "", ""
        ].joined(separator: "\n"))
    }

    @Test
    func theDrawingsAreForgottenAtTheTurnBoundary() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { 80 })
        let toolCall = fileCall(id: "write-1")

        await send(writePreview(content: ["let x = 1\n"]), to: renderer)
        await renderer.finishStreamingOutput()
        await renderer.writeToolCallStarted(toolCall)

        #expect(await renderer.snapshot().activeToolRenderedRowCount == 2)
        #expect(await renderer.previewMergedToolCallID == nil)
    }

    @Test
    func aBlockWhoseToolDiffersKeepsItsOwnHeader() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = fileCall(id: "append-1", name: "local.append")

        // Same target, but the preview header named another tool.
        await send(writePreview(content: ["let x = 1\n"]), to: renderer)
        await renderer.writeToolCallStarted(toolCall)
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 2)
        await renderer.writeToolCallCompleted(toolCall, result: Self.wroteOneLine)

        let shown = await screen(of: renderer, width: columns)
        #expect(shown == [
            "", "", "🛠️  local.writeFile /tmp/Example.swift", "let x = 1",
            "", "🛠️  local.append", "/tmp/Example.swift ✅", "", ""
        ].joined(separator: "\n"))
    }

    @Test
    func aBlockOnANonInteractiveChannelKeepsItsHeader() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)
        let toolCall = fileCall(id: "write-1")

        // The completion cannot rewrite the start in place: the start keeps
        // the full block so the completion never stands without it.
        await send(writePreview(content: ["let x = 1\n"]), to: renderer)
        await renderer.writeToolCallStarted(toolCall)
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 2)
        await renderer.writeToolCallCompleted(toolCall, result: Self.wroteOneLine)

        #expect(await renderer.previewMergedToolCallID == nil)
        let shown = await screen(of: renderer)
        #expect(shown == [
            "🛠️  local.writeFile /tmp/Example.swift", "let x = 1",
            "🛠️  local.writeFile", "/tmp/Example.swift ⏳",
            "🛠️  local.writeFile", "/tmp/Example.swift ✅", "", ""
        ].joined(separator: "\n"))
    }

    @Test
    func aRepublishedMergedBlockKeepsItsLayoutAfterBottomOverlayTransition() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = fileCall(id: "write-1")

        await send(writePreview(content: ["let x = 1\n"]), to: renderer)
        await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 6)
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 1)

        await renderer.beginBottomOverlayTransition(maximumInPlaceRows: 6)
        await renderer.endBottomOverlayTransition(maximumInPlaceRows: 6)
        let republished = await renderer.snapshot()
        #expect(republished.activeToolCallID == toolCall.id)
        #expect(republished.activeToolRenderedRowCount == 1)

        await renderer.writeToolCallCompleted(toolCall, result: Self.wroteOneLine, maximumInPlaceRows: 6)
        #expect(await screen(of: renderer, width: columns)
            == "\n\n🛠️  local.writeFile /tmp/Example.swift\nlet x = 1\n✅\n\n")
    }

    @Test
    func aStartDeferredByBottomOverlayTransitionKeepsTheMergedLayout() async {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })
        let toolCall = fileCall(id: "write-1")

        await send(writePreview(content: ["let x = 1\n"]), to: renderer)
        await renderer.beginBottomOverlayTransition(maximumInPlaceRows: 6)
        let eventsBeforeStart = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 6)
        #expect(await renderer.capturedWriteEvents().count == eventsBeforeStart)

        // The status bar writes of the transition go to the footer's reserved
        // rows, not to the transcript: no output stands between the preview
        // and the replayed start, so the block still merges into the header.
        await renderer.endBottomOverlayTransition(maximumInPlaceRows: 6)
        #expect(await renderer.snapshot().activeToolRenderedRowCount == 1)
        await renderer.writeToolCallCompleted(toolCall, result: Self.wroteOneLine, maximumInPlaceRows: 6)

        let shown = await screen(of: renderer, width: columns)
        #expect(shown == "\n\n🛠️  local.writeFile /tmp/Example.swift\nlet x = 1\n✅\n\n")
    }

    // MARK: - Repaint on screen

    @Test
    func theRepaintLeavesTheSameRowWithoutResiduesOrExtraRows() async throws {
        let columns = 80
        let renderer = makeRenderer(
            stdinIsTerminal: true,
            standardErrorIsTerminal: true,
            columnWidthProvider: { columns }
        )

        await send(writePreview(content: ["let x", " = 1\n", "x = y\n", "let s = \"é\"\n", "func f() {}"]),
                   to: renderer)
        await renderer.flushChatOutput()
        let writes = await renderer.capturedWriteEvents()
        let stderr = writes.renderedText(on: .standardError)

        // Only a carriage return moves the cursor back: no erase, no vertical move.
        #expect(containsOnlySGREscapes(stderr))
        #expect(stderr.components(separatedBy: "\r").count - 1 == 2)

        let rows = [
            " 🛠️  local.writeFile /tmp/Example.swift",
            " let x = 1",
            " x = y",
            " let s = \"é\"",
            " func f() {}"
        ]
        #expect(terminalScreenText(stderr, width: columns)
            == (["", ""] + rows + [""]).joined(separator: "\n"))

        // The primary screen forwards the carriage return and overwrites the
        // glyphs it already holds with the same glyphs.
        let capture = PrimaryScreenCapture(rows: 16, columns: columns)
        let screen = capture.screen()
        screen.commitFooter(
            geometry: .init(rows: 16, columns: columns),
            reservedRows: 1,
            sequence: "\u{1B}[16;1H\u{1B}[2KSTATUS| ready"
        )
        let bytesBefore = capture.bytes.count
        for write in writes where write.channel == .standardError {
            screen.append(write.text)
        }
        let emitted = String(capture.bytes.dropFirst(bytesBefore))
        #expect(emitted.contains("\r"))
        let visible = capture.visible.components(separatedBy: "\n")
        for row in rows.dropFirst() {
            #expect(visible.filter { $0 == row }.count == 1, "\(row)")
        }
        let header = try #require(visible.firstIndex(of: rows[0]))
        #expect(Array(visible[(header + 1)...].prefix(rows.count - 1)) == Array(rows.dropFirst()))
        #expect(visible[header + rows.count] == "")
    }
}
