//
//  ExternalPromptToolStartTests.swift
//  ZenCODE
//
//  Tool calls that run while an external prompt holds the terminal: a
//  `/subagent` or `/artifacts` panel stays open while the turn keeps calling
//  tools, and leaves the transcript too few rows to rewrite a pending block.
//  The start is not drawn: the completion is the call's only block, written
//  without a rewrite, and a call still running when the prompt ends is drawn
//  then and replaced in place as usual.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    @Test
    func aToolRunBehindAnExternalPromptIsDrawnOnceWithoutARewrite() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { 100 })
        await renderer.beginExternalTerminalPrompt()
        for index in 0..<3 {
            let toolCall = exampleReadFileCall(id: "read-\(index)")
            await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 20)
            #expect(await renderer.snapshot().activeToolCallID == nil)
            await renderer.writeToolCallCompleted(
                toolCall,
                result: DirectAgentToolResult(output: "Read", summary: "Read"),
                maximumInPlaceRows: 20
            )
        }
        await renderer.endExternalTerminalPrompt()

        // No hourglass row and no cursor-up erase: nothing relies on a rewrite
        // the covered transcript could not perform.
        let output = await renderer.capturedText(on: .standardError)
        #expect(!containsCursorUpSequence(output))
        #expect(!output.contains("⏳"))
        let screen = terminalScreenText(output, width: 100)
        #expect(screen.components(separatedBy: "local.readFile").count - 1 == 3)
        #expect(screen.components(separatedBy: "✅").count - 1 == 3)
        #expect(await renderer.snapshot().activeToolCallID == nil)
    }

    @Test
    func aToolStillRunningWhenTheExternalPromptEndsIsDrawnAndRewrittenInPlace() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true, columnWidthProvider: { 100 })
        let toolCall = exampleReadFileCall(id: "read-running")

        await renderer.beginExternalTerminalPrompt()
        await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 20)
        await renderer.writeToolAdjacentSystemMessage("Adjacent diagnostic\n")
        await renderer.endExternalTerminalPrompt()

        #expect(await renderer.snapshot().activeToolCallID == toolCall.id)
        let started = await renderer.capturedText(on: .standardError)
        #expect(started.contains("⏳"))
        #expect(!started.contains("Adjacent diagnostic"))

        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Read", summary: "Read"),
            maximumInPlaceRows: 20
        )
        let completion = await renderer.capturedText(droppingFirst: eventCountBeforeCompletion)
        #expect(containsCursorUpSequence(completion))

        let screen = terminalScreenText(await renderer.capturedText(on: .standardError), width: 100)
        #expect(screen.components(separatedBy: "local.readFile").count - 1 == 1)
        #expect(!screen.contains("⏳"))
        let completionRange = screen.range(of: "✅")
        let diagnosticRange = screen.range(of: "Adjacent diagnostic")
        #expect(completionRange != nil)
        #expect(diagnosticRange != nil)
        if let completionRange, let diagnosticRange {
            #expect(completionRange.lowerBound < diagnosticRange.lowerBound)
        }
    }
}
