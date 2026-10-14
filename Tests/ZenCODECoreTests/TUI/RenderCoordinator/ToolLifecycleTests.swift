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
    func compactPermissionDeniedCompletionUsesWarningInsteadOfSuccessIcon() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = presentedToolCall(
            id: "denied-local-exec",
            name: "local.exec",
            argumentsObject: ["command": "whoami"],
            argumentsJSON: #"{"command":"whoami"}"#
        )

        await renderer.writeToolCallStarted(toolCall)
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(
                output: "Command execution cancelled.",
                summary: "Command execution cancelled.",
                status: .permissionDenied
            )
        )

        let completionText = await renderer.capturedText(droppingFirst: eventCountBeforeCompletion)

        #expect(completionText.contains("⚠️"))
        #expect(!completionText.contains("✅"))
    }

    @Test
    func compactCompletionShowsElapsedMetadataWithinTheRedrawWidthBudget() async {
        let clock = StreamingClock()
        let terminalColumns = 26
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            toolNow: { clock.now },
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
        clock.advance(by: .milliseconds(1_200))

        // Advancing the injected clock alone cannot schedule a live compact-row
        // redraw. Completion is the only subsequent rendering event.
        #expect(await renderer.capturedWriteEvents().count == eventCountBeforeCompletion)

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(
                output: "exit_code: 7\nstderr:\nboom",
                summary: "command failed"
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
            TerminalChat.displayWidth($0) <= terminalColumns - 1
        })
        #expect(started.activeToolRenderedRowCount == 2)
    }

    @Test
    func elapsedTimeUsesMillisecondsBelowOneSecond() {
        #expect(TerminalChat.toolElapsedTimeText(.zero) == "0ms")
        #expect(TerminalChat.toolElapsedTimeText(.nanoseconds(1)) == "<0.01ms")
        #expect(TerminalChat.toolElapsedTimeText(.microseconds(820)) == "0.82ms")
        #expect(TerminalChat.toolElapsedTimeText(.milliseconds(12)) == "12.0ms")
        #expect(TerminalChat.toolElapsedTimeText(.milliseconds(350)) == "350ms")
        #expect(TerminalChat.toolElapsedTimeText(.milliseconds(1_200)) == "1.20s")

        let rendered = TerminalChat.renderCompactToolLine(
            "Read ✅ 0.82ms",
            isTitle: false
        )
        #expect(
            rendered.contains(
                "\(TerminalChat.toolDurationColor)0.82ms\(TerminalChat.toolValueColor)"
            )
        )
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
    func compactCompletionReadsColumnWidthOnce() async {
        let widthBox = ColumnWidthBox(100)
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: {
                widthBox.readCount += 1
                return widthBox.width
            }
        )
        let toolCall = presentedToolCall(
            id: "compact-width-capture",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(toolCall)
        #expect(widthBox.readCount == 1)

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        #expect(widthBox.readCount == 2)
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
