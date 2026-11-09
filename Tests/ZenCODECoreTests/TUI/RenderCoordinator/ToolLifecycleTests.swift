import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    @Test
    func agentMessageLifecycleDoesNotRenderOrOwnTheMainToolBlock() async {
        let toolCall = presentedToolCall(
            id: "hidden-agent-message",
            name: "agent.message",
            argumentsObject: [
                "name": "worker",
                "message": "please review the diff"
            ],
            argumentsJSON: "{}"
        )
        let renderer = makeRenderer(standardErrorIsTerminal: true)

        await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 6)
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "sent", summary: "sent"),
            maximumInPlaceRows: 6
        )

        let snapshot = await renderer.snapshot()
        #expect(await renderer.capturedWriteEvents().isEmpty)
        #expect(snapshot.activeToolCallID == nil)
        #expect(snapshot.activeToolRenderedRowCount == 0)
    }

    @Test
    func compactToolCompletionClearsOnlyOwnedRows() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = presentedToolCall(
            id: "tool-1",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count
        #expect(started.activeToolCallID == toolCall.id)
        #expect(started.activeToolRenderedRowCount > 0)

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let completed = await renderer.snapshot()
        let events = await renderer.capturedWriteEvents()
        let stderr = events.renderedText(on: .standardError)
        let completionEvents = Array(events.dropFirst(eventCountBeforeCompletion))
        let rewriteSequence = completionEvents.first?.text ?? ""

        #expect(completed.activeToolCallID == nil)
        #expect(completed.activeToolRenderedRowCount == 0)
        #expect(rewriteSequence.hasPrefix("\u{1B}[\(started.activeToolRenderedRowCount)A\r"))
        #expect(
            rewriteSequence.components(separatedBy: "\u{1B}[2K").count - 1
                == started.activeToolRenderedRowCount
        )
        #expect(!completionEvents.renderedText().contains("\u{1B}[J"))
        #expect(stderr.contains("⏳"))
        #expect(stderr.contains("✅"))
        #expect(events.map(\.sequence) == Array(0..<UInt64(events.count)))
    }

    @Test
    func compactCompletionShowsElapsedMetadataWithinTheRedrawWidthBudget() async {
        let terminalColumns = 26
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { terminalColumns }
        )
        let toolCall = presentedToolCall(
            id: "timed-local-exec",
            name: "local.exec",
            argumentsObject: ["command": "a-very-long-command-that-needs-truncation"],
            argumentsJSON: #"{"command":"a-very-long-command-that-needs-truncation"}"#
        )

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count

        // The time is the one the result carries: no clock of the renderer
        // schedules a live compact-row redraw, completion is the only
        // subsequent rendering event.
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(
                output: "exit_code: 7\nstderr:\nboom",
                summary: "command failed",
                elapsed: .milliseconds(1_200)
            )
        )

        let completionEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventCountBeforeCompletion)
        )
        let completionText = completionEvents.renderedText()
        let visibleCompletionText = TerminalANSIText.stripANSI(completionText)
        let renderedCompletion = TerminalANSIText.stripANSI(
            completionEvents.last?.text ?? ""
        )
        let renderedLines = renderedCompletion
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        #expect(containsCursorUpSequence(completionText))
        #expect(visibleCompletionText.contains("1.20s"))
        #expect(visibleCompletionText.contains("exit 7"))
        #expect(
            completionText.contains(
                "⚠️  \(TerminalChat.toolDurationColor)1.20s\(TerminalChat.toolValueColor) exit 7"
            )
        )
        #expect(renderedLines.allSatisfy {
            TerminalTextMetrics.displayWidth($0) <= terminalColumns - 1
        })
        #expect(started.activeToolRenderedRowCount == 2)
    }

    @Test
    func completedLifecycleTakesItsTimeFromTheResult() {
        typealias Lifecycle = TerminalChatRenderCoordinator.ToolBlockLifecycle
        let toolCall = exampleReadFileCall(id: "factory-read")

        let timed = DirectAgentToolResult(output: "ok", summary: "ok", elapsed: .milliseconds(350))
        let timedLifecycle = Lifecycle.completed(for: toolCall, result: timed)
        #expect(timedLifecycle.isCompletion)
        #expect(timedLifecycle.compactStatusDetail == "350ms")
        #expect(
            timedLifecycle.compactStatusDetail
                == TerminalChat.compactToolCompletionDetail(for: toolCall, result: timed, elapsed: timed.elapsed)
        )
        if case let .completed(result, _) = timedLifecycle {
            #expect(result.elapsed == .milliseconds(350))
        } else {
            Issue.record("The factory did not build a completion")
        }

        let untimed = DirectAgentToolResult(output: "ok", summary: "ok")
        #expect(Lifecycle.completed(for: toolCall, result: untimed).compactStatusDetail == nil)
        #expect(Lifecycle.started.compactStatusDetail == nil)
    }

    @Test
    func compactLocalExecMetadataUsesCanonicalExitCodeAndCleanMissingStartFallback() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = presentedToolCall(
            id: "completed-without-start",
            name: "local.exec",
            argumentsObject: ["command": "false"],
            argumentsJSON: #"{"command":"false"}"#
        )

        // A replayed / otherwise unmatched completion has no duration, but a
        // canonical non-zero code in output remains useful failure metadata.
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(
                output: "exit_code: 23\nstderr:\nfailed",
                summary: "failed"
            )
        )
        let missingStartText = await renderer.capturedText()
        #expect(missingStartText.contains("⚠️  exit 23"))
        #expect(!missingStartText.contains("0ms"))

        let successfulToolCall = presentedToolCall(
            id: "successful-with-duration",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        let successfulDetail = TerminalChat.compactToolCompletionDetail(
            for: successfulToolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done"),
            elapsed: .milliseconds(1_200)
        )
        let successfulLines = TerminalChat.compactToolLines(
            for: successfulToolCall,
            statusIcon: "✅",
            statusDetail: successfulDetail,
            columnWidth: 80
        )
        #expect(successfulLines.last?.hasSuffix("✅ 1.20s") == true)
        #expect(
            TerminalChat.compactToolCompletionDetail(
                for: successfulToolCall,
                result: DirectAgentToolResult(output: "Done", summary: "Done"),
                elapsed: nil
            ) == nil
        )

        let zeroResult = DirectAgentToolResult(
            output: "exit_code: 0\n<no output>",
            summary: "exit_code: 0"
        )
        #expect(
            TerminalChat.compactToolCompletionDetail(
                for: toolCall,
                result: zeroResult,
                elapsed: nil
            ) == nil
        )

        let summaryExitResult = DirectAgentToolResult(
            output: "stderr:\ncommand failed",
            summary: "exit_code: -1",
            status: .failed
        )
        #expect(
            TerminalChat.compactToolCompletionDetail(
                for: toolCall,
                result: summaryExitResult,
                elapsed: nil
            ) == "exit -1"
        )

        let nonCanonicalResult = DirectAgentToolResult(
            output: "the command printed exit_code: 9 in its prose",
            summary: "failed: exit_code: 9",
            status: .failed
        )
        #expect(
            TerminalChat.compactToolCompletionDetail(
                for: toolCall,
                result: nonCanonicalResult,
                elapsed: nil
            ) == nil
        )

        let embeddedMarkerResult = DirectAgentToolResult(
            output: "stdout:\nexit_code: 9",
            summary: "failed",
            status: .failed
        )
        #expect(
            TerminalChat.compactToolCompletionDetail(
                for: toolCall,
                result: embeddedMarkerResult,
                elapsed: nil
            ) == nil
        )
    }

    @Test
    func emptyContentDoesNotRelinquishToolRows() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = presentedToolCall(
            id: "tool-empty-delta",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeAssistantContent("")
        await renderer.writeThought(" \n")
        let afterEmptyDeltas = await renderer.snapshot()
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let combined = await renderer.capturedText()
        #expect(afterEmptyDeltas.activeToolCallID == toolCall.id)
        #expect(
            afterEmptyDeltas.activeToolRenderedRowCount
                == started.activeToolRenderedRowCount
        )
        let completionEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventCountBeforeCompletion)
        )
        #expect(!completionEvents.renderedText().contains("\u{1B}[J"))
        #expect(combined.contains("✅"))
    }

    @Test
    func staleCompletionRelinquishesNewerToolOwnershipAndPreservesTranscript() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let first = presentedToolCall(
            id: "overlap-first",
            name: "agent.create",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        let second = presentedToolCall(
            id: "overlap-second",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(first)
        await renderer.writeToolCallStarted(second)
        let eventCountBeforeStaleCompletion = await renderer.capturedWriteEvents().count

        // The first completion is stale: the later start owns the one physical
        // rewrite slot, so this result must append without clearing that slot.
        await renderer.writeToolCallCompleted(
            first,
            result: DirectAgentToolResult(output: "first", summary: "first")
        )
        let afterStaleCompletion = await renderer.snapshot()
        let staleCompletionText = await renderer.capturedText(droppingFirst: eventCountBeforeStaleCompletion)

        #expect(afterStaleCompletion.activeToolCallID == nil)
        #expect(!containsCursorUpSequence(staleCompletionText))
        #expect(staleCompletionText.contains("✅"))

        let eventCountBeforeOwningCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            second,
            result: DirectAgentToolResult(output: "second", summary: "second")
        )
        let afterOwningCompletion = await renderer.snapshot()
        let owningCompletionText = await renderer.capturedText(droppingFirst: eventCountBeforeOwningCompletion)

        #expect(afterOwningCompletion.activeToolCallID == nil)
        #expect(!containsCursorUpSequence(owningCompletionText))
        let transcript = await renderer.capturedPlainText()
        // Compact cards do not include IDs or result summaries, so distinct
        // tool names demonstrate that both pending cards and both append-only
        // completions remain in the transcript.
        #expect(transcript.components(separatedBy: "agent.create").count - 1 == 2)
        #expect(transcript.components(separatedBy: "agent.wait").count - 1 == 2)
    }

    @Test
    func completionUsesExplicitFreshWidthProviderBeforeClearingRows() async {
        let cachedWidth = ColumnWidthBox(100)
        let freshWidth = ColumnWidthBox(40)
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: {
                cachedWidth.readCount += 1
                return cachedWidth.width
            },
            freshColumnWidthProvider: {
                freshWidth.readCount += 1
                return freshWidth.width
            }
        )
        let toolCall = presentedToolCall(
            id: "fresh-width-provider",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(toolCall)
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let completionText = await renderer.capturedText(droppingFirst: eventCountBeforeCompletion)
        #expect(cachedWidth.readCount == 1)
        #expect(freshWidth.readCount == 1)
        #expect(!containsCursorUpSequence(completionText))
        #expect(completionText.contains("✅"))
    }
}
