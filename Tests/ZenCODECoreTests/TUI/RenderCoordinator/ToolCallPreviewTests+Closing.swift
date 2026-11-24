//
//  ToolCallPreviewTests+Closing.swift
//  ZenCODE
//
//  Tests of how the coordinator closes, suspends and reopens the live file
//  preview, and of the overviews held back while its rows are open.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatToolCallPreviewTests {
    // MARK: - Closing

    @Test
    func assistantContentAfterAnUnfinishedPreviewClosesItFirst() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            standardOutputIsTerminal: true,
            columnWidthProvider: { 80 }
        )

        await send(writePreview(content: ["let x"], ends: false), to: renderer)
        await renderer.writeAssistantContent("Done.")
        #expect(await !renderer.isStreamingToolCallPreview)
        await renderer.finishStreamingOutput()

        let screen = terminalScreenText(await renderer.capturedText(), width: 80)
        #expect(screen == [
            "", "", "🛠️  local.write", "let x", "💬 Done.", ""
        ].joined(separator: "\n"))
    }

    @Test
    func theEndOfTheTurnClosesAnUnfinishedPreview() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await send(writePreview(content: ["let x = 1\nlet y"], ends: false), to: renderer)
        await renderer.finishStreamingOutput()

        #expect(await !renderer.isStreamingToolCallPreview)
        #expect(await renderer.capturedText(on: .standardError)
            == "🛠️  local.write\nlet x = 1\nlet y\n")
    }

    @Test
    func aPathStreamingDuringAnInterleavedMessageWritesNothingAndSourceTextReopensTheToolNameAlone() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await send([.toolStarted(name: "local.edit"), .parameterStarted(name: "path"), .parameterText("Sources/")],
                   to: renderer)
        await renderer.writeSystemMessage("Note\n")
        // The call is only suspended: none of its rows is open.
        #expect(await !renderer.isStreamingToolCallPreview)
        await renderer.writeToolCallPreview(.parameterText("A.swift"))
        // The rest of the path writes nothing, so it does not reopen the header.
        #expect(await !renderer.isStreamingToolCallPreview)
        #expect(await renderer.capturedText(on: .standardError) == "🛠️  local.edit\nNote\n")
        await send([.parameterEnded, .parameterStarted(name: "new"), .parameterText("let x = 1\n")], to: renderer)
        // Source text does, with the tool name alone.
        #expect(await renderer.isStreamingToolCallPreview)
        await send([.parameterEnded, .ended], to: renderer)

        #expect(await !renderer.isStreamingToolCallPreview)
        #expect(await renderer.capturedText(on: .standardError)
            == "🛠️  local.edit\nNote\n🛠️  local.edit\n+ let x = 1\n")
    }

    @Test
    func aMessageInTheMiddleOfTheContentLosesNoRowOfTheFile() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await send(writePreview(content: ["let a = 1\nlet b"], ends: false), to: renderer)
        await renderer.writeSystemMessage("Note\n")
        await send([.parameterText(" = 2\nlet c = 3\n"), .parameterText("let d = 4"), .parameterEnded, .ended],
                   to: renderer)

        #expect(await renderer.capturedText(on: .standardError) == [
            "🛠️  local.write", "let a = 1", "let b",
            "Note",
            "🛠️  local.write", " = 2", "let c = 3", "let d = 4", ""
        ].joined(separator: "\n"))
    }

    @Test
    func theReopenedPreviewIsPreparedLikeItsStartOnTheTerminal() async throws {
        let columns = 80
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { columns })

        await send(writePreview(content: ["let a = 1\nlet b = 2"], ends: false), to: renderer)
        await renderer.writeSystemMessage("Note\n")
        // The line break of the row the interruption ended draws nothing.
        await send([.parameterText("\nlet c = 3\n"), .parameterEnded, .ended], to: renderer)
        await renderer.flushChatOutput()
        let stderr = await renderer.capturedText(on: .standardError)

        #expect(containsOnlySGREscapes(stderr))
        let screen = terminalScreenText(stderr, width: columns)
        let rows = screen.components(separatedBy: "\n")
        #expect(rows.filter { $0 == "🛠️  local.write" }.count == 2)
        for row in ["let a = 1", "let b = 2", "let c = 3", "Note"] {
            #expect(rows.filter { $0 == row }.count == 1, "\(row)")
        }
        let note = try #require(rows.firstIndex(of: "Note"))
        let reopened = try #require(rows.lastIndex(of: "🛠️  local.write"))
        #expect(note < reopened)
        // The tool separator before the reopened header, the rest of the file
        // right below it.
        #expect(rows[reopened - 1] == "")
        #expect(Array(rows[(reopened + 1)...]) == ["let c = 3", ""])
    }

    @Test
    func theEndOfASuspendedCallOrANewCallWritesNothingForIt() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)

        await send(writePreview(content: ["let x = 1\n"], ends: false), to: renderer)
        await renderer.writeSystemMessage("Note\n")
        await renderer.flushChatOutput()
        let written = await renderer.capturedWriteEvents().count
        await send([.parameterEnded, .ended, .parameterText("let y = 2\n")], to: renderer)
        await renderer.flushChatOutput()
        #expect(await renderer.capturedWriteEvents().count == written)

        // A new call that is not drawn forgets the suspended one as well.
        await send(writePreview(content: ["let x = 1\n"], ends: false), to: renderer)
        await renderer.writeSystemMessage("Note\n")
        await renderer.flushChatOutput()
        let rewritten = await renderer.capturedWriteEvents().count
        await send([.toolStarted(name: "local.read"), .parameterText("let y = 2\n")], to: renderer)
        await renderer.flushChatOutput()
        #expect(await renderer.capturedWriteEvents().count == rewritten)
        #expect(await !renderer.isStreamingToolCallPreview)
    }

    @Test
    func aSuspendedCallIsForgottenAtTheEndOfTheTurnAndAtANewTurn() async {
        let ended = makeRenderer(standardErrorIsTerminal: false)
        await send(writePreview(content: ["let x = 1\n"], ends: false), to: ended)
        await ended.writeSystemMessage("Note\n")
        await ended.finishStreamingOutput()
        await ended.writeToolCallPreview(.parameterText("let y = 2\n"))
        #expect(await ended.capturedText(on: .standardError) == "🛠️  local.write\nlet x = 1\nNote\n")

        let next = makeRenderer(standardErrorIsTerminal: false)
        await send(writePreview(content: ["let x = 1\n"], ends: false), to: next)
        await next.writeSystemMessage("Note\n")
        await next.beginTranscriptTurn()
        await next.writeToolCallPreview(.parameterText("let y = 2\n"))
        #expect(await next.capturedText(on: .standardError) == "🛠️  local.write\nlet x = 1\nNote\n")

        // A call still open at a new turn is closed as an interruption would,
        // then forgotten.
        let open = makeRenderer(standardErrorIsTerminal: false)
        await send(writePreview(content: ["let x"], ends: false), to: open)
        await open.beginTranscriptTurn()
        #expect(await !open.isStreamingToolCallPreview)
        await open.writeToolCallPreview(.parameterText(" = 1\n"))
        #expect(await open.capturedText(on: .standardError) == "🛠️  local.write\nlet x\n")
    }

    @Test
    func overviewsWaitForThePreviewToEnd() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await send(writePreview(content: ["let x = 1\n"], ends: false), to: renderer)
        let result = await renderer.renderTaskGraphOverview(signature: "plan", markdown: "# Plan\n")
        #expect(result == .deferred)
        #expect(await renderer.snapshot().deferredTaskGraphOverviewRender)

        await renderer.writeToolCallPreview(.ended)
        #expect(await renderer.shouldPublishDeferredOverview(.taskGraph))
        await renderer.finishStreamingOutput()

        let stdout = await renderer.capturedPlainText(on: .standardOutput)
        #expect(stdout.contains("Plan"))
        #expect(await !renderer.snapshot().deferredTaskGraphOverviewRender)
    }

    @Test
    func aSuspendedCallDefersNoOverview() async throws {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await send(writePreview(content: ["let x = 1\n"], ends: false), to: renderer)
        #expect(await renderer.renderTaskGraphOverview(signature: "plan", markdown: "# Plan\n") == .deferred)
        // The interruption suspends the call: the overview it held back goes
        // out after the message, and a new one is not held back.
        await renderer.writeSystemMessage("Note\n")
        #expect(await !renderer.snapshot().deferredTaskGraphOverviewRender)
        #expect(await renderer.renderTaskGraphOverview(signature: "plan-2", markdown: "# Later\n") == .rendered)
        await renderer.writeToolCallPreview(.parameterText("let y = 2\n"))
        await renderer.finishStreamingOutput()

        let stdout = await renderer.capturedPlainText(on: .standardOutput)
        let plan = try #require(stdout.range(of: "Plan"))
        let later = try #require(stdout.range(of: "Later"))
        #expect(plan.upperBound <= later.lowerBound)
        #expect(await renderer.capturedText(on: .standardError) == [
            "🛠️  local.write", "let x = 1",
            "Note",
            "🛠️  local.write", "let y = 2", ""
        ].joined(separator: "\n"))
    }
}
