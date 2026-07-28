//
//  TerminalChatRenderCoordinatorTests.swift
//  ZenCODETests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Terminal chat async render coordinator")
struct TerminalChatRenderCoordinatorTests {
    @Test
    func compactToolCompletionClearsOnlyOwnedRows() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = DirectAgentToolCall(
            id: "tool-1",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count
        #expect(started.activeCompactToolCallID == toolCall.id)
        #expect(started.activeCompactToolRenderedRowCount > 0)

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let completed = await renderer.snapshot()
        let events = await renderer.capturedWriteEvents()
        let stderr = events
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        let completionEvents = Array(events.dropFirst(eventCountBeforeCompletion))
        let rewriteSequence = completionEvents.first?.text ?? ""

        #expect(completed.activeCompactToolCallID == nil)
        #expect(completed.activeCompactToolRenderedRowCount == 0)
        #expect(rewriteSequence.hasPrefix("\u{1B}[\(started.activeCompactToolRenderedRowCount)A\r"))
        #expect(
            rewriteSequence.components(separatedBy: "\u{1B}[2K").count - 1
                == started.activeCompactToolRenderedRowCount
        )
        #expect(!completionEvents.map(\.text).joined().contains("\u{1B}[J"))
        #expect(stderr.contains("⏳"))
        #expect(stderr.contains("✅"))
        #expect(events.map(\.sequence) == Array(0..<UInt64(events.count)))
    }

    @Test
    func compactPermissionDeniedCompletionUsesWarningInsteadOfSuccessIcon() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = DirectAgentToolCall(
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

        let completionText = await renderer.capturedWriteEvents()
            .dropFirst(eventCountBeforeCompletion)
            .map(\.text)
            .joined()

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
        let toolCall = DirectAgentToolCall(
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
        let completionText = completionEvents.map(\.text).joined()
        let visibleCompletionText = TerminalANSIText.stripANSI(completionText)
        let renderedCompletion = TerminalANSIText.stripANSI(
            completionEvents.last?.text ?? ""
        )
        let renderedLines = renderedCompletion
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        #expect(containsCursorUpSequence(completionText))
        #expect(visibleCompletionText.contains("⚠️  1.20s exit 7"))
        #expect(
            completionText.contains(
                "⚠️  \(TerminalChat.toolDurationColor)1.20s\(TerminalChat.toolValueColor) exit 7"
            )
        )
        #expect(renderedLines.allSatisfy {
            TerminalChat.displayWidth($0) <= terminalColumns - 1
        })
        #expect(started.activeCompactToolRenderedRowCount == 2)
    }

    @Test
    func compactLocalExecMetadataUsesCanonicalExitCodeAndCleanMissingStartFallback() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = DirectAgentToolCall(
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
        let missingStartText = await renderer.capturedWriteEvents()
            .map(\.text)
            .joined()
        #expect(missingStartText.contains("⚠️  exit 23"))
        #expect(!missingStartText.contains("0.00s"))

        let successfulToolCall = DirectAgentToolCall(
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
    func compactCompletionKeepsActiveStyleWhenDetailLevelChanges() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = DirectAgentToolCall(
            id: "compact-style-change",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.setToolOutputDetailLevel(.expanded)
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let events = await renderer.capturedWriteEvents()
        let completionText = events
            .dropFirst(eventCountBeforeCompletion)
            .map(\.text)
            .joined()

        #expect(started.activeCompactToolCallID == toolCall.id)
        #expect(containsCursorUpSequence(completionText))
        #expect(!completionText.contains("status: ✅"))
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
        let toolCall = DirectAgentToolCall(
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
        let toolCall = DirectAgentToolCall(
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

        let combined = await renderer.capturedWriteEvents().map(\.text).joined()
        #expect(afterEmptyDeltas.activeCompactToolCallID == toolCall.id)
        #expect(
            afterEmptyDeltas.activeCompactToolRenderedRowCount
                == started.activeCompactToolRenderedRowCount
        )
        let completionEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventCountBeforeCompletion)
        )
        #expect(!completionEvents.map(\.text).joined().contains("\u{1B}[J"))
        #expect(combined.contains("✅"))
    }

    @Test
    func detailedToolCompletionClearsOnlyOwnedRows() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = DirectAgentToolCall(
            id: "tool-detailed",
            name: "local.readFile",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await renderer.setToolOutputDetailLevel(.expanded)
        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let events = await renderer.capturedWriteEvents()
        let completionEvents = Array(events.dropFirst(eventCountBeforeCompletion))
        let rewriteSequence = completionEvents.first?.text ?? ""

        #expect(started.activeDetailedToolCallID == toolCall.id)
        #expect(started.activeDetailedToolRenderedRowCount > 0)
        #expect(rewriteSequence.hasPrefix("\u{1B}[\(started.activeDetailedToolRenderedRowCount)A\r"))
        #expect(
            rewriteSequence.components(separatedBy: "\u{1B}[2K").count - 1
                == started.activeDetailedToolRenderedRowCount
        )
        #expect(!completionEvents.map(\.text).joined().contains("\u{1B}[J"))
    }

    @Test
    func detailedToolCompletionShowsElapsedTime() {
        let toolCall = DirectAgentToolCall(
            id: "detailed-elapsed",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        let rowsWithElapsed = TerminalChat.detailedToolCallCompletedRows(
            for: toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done"),
            elapsed: .milliseconds(1_200)
        )
        #expect(rowsWithElapsed.last?.plainText == "status: ✅ 1.20s")

        let failedRows = TerminalChat.detailedToolCallCompletedRows(
            for: toolCall,
            result: DirectAgentToolResult(output: "Boom", summary: "Boom", status: .failed),
            elapsed: .milliseconds(350)
        )
        #expect(failedRows.last?.plainText == "status: ⚠️  0.35s")

        let rowsWithoutElapsed = TerminalChat.detailedToolCallCompletedRows(
            for: toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )
        #expect(rowsWithoutElapsed.last?.plainText == "status: ✅")
    }

    @Test
    func detailedToolCompletionRendersElapsedTime() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = DirectAgentToolCall(
            id: "detailed-elapsed-render",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await renderer.setToolOutputDetailLevel(.expanded)
        await renderer.writeToolCallStarted(toolCall)
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let stderr = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        // The expanded status row carries the formatted elapsed duration next
        // to the completion icon, mirroring the compact detail. The label/value
        // split inserts an ANSI color code between "status:" and the value, so
        // assert on the contiguous value fragment instead.
        #expect(stderr.contains("✅ "))
        #expect(stderr.contains("s"))
    }

    @Test
    func externalAuthorizationPromptRelinquishesToolRowsBeforeCompletion() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = DirectAgentToolCall(
            id: "authorized-delete",
            name: "local.delete",
            argumentsObject: ["path": "ProvaTest.swift"],
            argumentsJSON: #"{"path":"ProvaTest.swift"}"#
        )
        await renderer.setToolOutputDetailLevel(.expanded)
        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()

        await renderer.beginExternalTerminalPrompt()
        let guarded = await renderer.snapshot()
        let deferred = await renderer.renderTaskGraphOverview(
            signature: "graph:during-authorization",
            markdown: "## Tasks\n\n- waiting for authorization\n"
        )

        #expect(started.activeDetailedToolCallID == toolCall.id)
        #expect(started.activeDetailedToolRenderedRowCount > 0)
        #expect(guarded.activeDetailedToolCallID == nil)
        #expect(guarded.activeDetailedToolRenderedRowCount == 0)
        #expect(deferred == .deferred)

        await renderer.endExternalTerminalPrompt()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Deleted", summary: "Deleted")
        )

        let completionText = await renderer.capturedWriteEvents()
            .dropFirst(eventCountBeforeCompletion)
            .map(\.text)
            .joined()
        #expect(!containsCursorUpSequence(completionText))
        #expect(!completionText.contains("\u{1B}[2K"))
        #expect(completionText.contains("status:"))
    }

    @Test
    func detailedToolRowsReserveTrailingColumnBeforeInPlaceRewrite() async throws {
        let terminalColumns = 40
        let longArgument = String(repeating: "x", count: 100)
        let renderer = makeRenderer(
            stdinIsTerminal: true,
            standardErrorIsTerminal: true,
            columnWidthProvider: { terminalColumns }
        )
        let toolCall = DirectAgentToolCall(
            id: "tool-detailed-wrap",
            name: "local.exec",
            argumentsObject: ["command": longArgument],
            argumentsJSON: #"{"command":"placeholder"}"#
        )

        await renderer.setToolOutputDetailLevel(.expanded)
        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let startedEvents = await renderer.capturedWriteEvents()
        let renderedStart = try #require(startedEvents.last?.text)
        let renderedRows = renderedStart
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        // The interactive-chat inset occupies two cells. Every expanded row
        // must leave one further cell unused so an auto-wrap cannot add an
        // uncounted row next to the reserved status/input overlay.
        #expect(renderedRows.count == started.activeDetailedToolRenderedRowCount)
        #expect(
            renderedRows.allSatisfy {
                TerminalANSIText.visibleWidth($0) <= terminalColumns - 1
            }
        )
        let renderedLongCharacterCount = TerminalANSIText.stripANSI(renderedStart)
            .reduce(into: 0) { count, character in
                if character == "x" {
                    count += 1
                }
            }
        #expect(renderedLongCharacterCount >= longArgument.count)

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
                "\u{1B}[\(started.activeDetailedToolRenderedRowCount)A\r"
            )
        )
        #expect(
            clearSequence.components(separatedBy: "\u{1B}[2K").count - 1
                == started.activeDetailedToolRenderedRowCount
        )
    }

    @Test
    func detailedToolBlockBeyondScrollRegionAppendsCompletionWithoutErasingOverlay() async {
        let scrollableRows = 12
        // The *started* block must exceed the scrolling region: that is the
        // precondition for the append-only completion path under test.
        // Expanded mutation tools now render their payload only on completion,
        // so this fixture uses a tool whose parameters are shown at start time.
        let script = (0..<40)
            .map { "echo line\($0)" }
            .joined(separator: "\n")
        let renderer = makeRenderer(
            stdinIsTerminal: true,
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let toolCall = DirectAgentToolCall(
            id: "tool-overflowing-scroll-region",
            name: "local.exec",
            argumentsObject: [
                "cwd": "/tmp/project",
                "command": script
            ],
            argumentsJSON: "{}"
        )

        await renderer.setToolOutputDetailLevel(.expanded)
        await renderer.writeToolCallStarted(
            toolCall,
            maximumInPlaceRows: scrollableRows
        )
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done"),
            maximumInPlaceRows: scrollableRows
        )

        let completionText = (await renderer.capturedWriteEvents())
            .dropFirst(eventCountBeforeCompletion)
            .map(\.text)
            .joined()

        #expect(started.activeDetailedToolRenderedRowCount > scrollableRows)
        #expect(!containsCursorUpSequence(completionText))
        #expect(TerminalANSIText.stripANSI(completionText).contains("status: ✅"))
    }

    @Test
    func expandedMutationCompletionBeyondScrollRegionAppendsWithoutErasingOverlay() async {
        // Companion case for expanded mutations: the payload appears only on
        // completion, so the started block stays small while the completion
        // far exceeds the scrolling region.
        let scrollableRows = 4
        let content = (0..<40)
            .map { "let value\($0) = \($0)" }
            .joined(separator: "\n")
        let renderer = makeRenderer(
            stdinIsTerminal: true,
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let toolCall = DirectAgentToolCall(
            id: "tool-expanded-write-overflow",
            name: "local.writeFile",
            argumentsObject: [
                "path": "/tmp/project/Sources/App.swift",
                "content": content
            ],
            argumentsJSON: "{}"
        )

        await renderer.setToolOutputDetailLevel(.expanded)
        await renderer.writeToolCallStarted(
            toolCall,
            maximumInPlaceRows: scrollableRows
        )
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Wrote file", summary: "Wrote file"),
            maximumInPlaceRows: scrollableRows
        )

        let completionText = (await renderer.capturedWriteEvents())
            .dropFirst(eventCountBeforeCompletion)
            .map(\.text)
            .joined()
        let visibleRows = TerminalANSIText.stripANSI(completionText)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        #expect(started.activeDetailedToolRenderedRowCount > scrollableRows)
        #expect(!containsCursorUpSequence(completionText))
        #expect(visibleRows.contains { $0.contains("status: ✅") })
        #expect(visibleRows.allSatisfy { TerminalChat.displayWidth($0) <= 80 })
    }

    @Test
    func overviewIsDeferredUntilToolNoLongerOwnsRows() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = DirectAgentToolCall(
            id: "tool-2",
            name: "tasks.list",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(toolCall)
        let countBeforeOverview = await renderer.capturedWriteEvents().count

        let deferred = await renderer.renderTaskGraphOverview(
            signature: "graph:1",
            markdown: "## Task graph\n\n- first\n"
        )
        let deferredSnapshot = await renderer.snapshot()
        let countAfterDeferredOverview = await renderer.capturedWriteEvents().count

        #expect(deferred == .deferred)
        #expect(deferredSnapshot.deferredTaskGraphOverviewRender)
        #expect(deferredSnapshot.lastRenderedTaskGraphOverviewSignature == nil)
        #expect(countAfterDeferredOverview == countBeforeOverview)

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )
        #expect(await renderer.shouldPublishDeferredOverview(.taskGraph))

        let rendered = await renderer.renderTaskGraphOverview(
            signature: "graph:1",
            markdown: "## Task graph\n\n- first\n"
        )
        let countAfterRenderedOverview = await renderer.capturedWriteEvents().count
        let duplicate = await renderer.renderTaskGraphOverview(
            signature: "graph:1",
            markdown: "## Task graph\n\n- first\n"
        )
        let finalEvents = await renderer.capturedWriteEvents()
        let combined = finalEvents.map(\.text).joined()

        #expect(rendered == .rendered)
        #expect(duplicate == .unchanged)
        #expect(finalEvents.count == countAfterRenderedOverview)
        #expect(combined.contains("Task graph"))
        #expect(combined.firstRange(of: "✅")?.lowerBound != nil)
        #expect(combined.firstRange(of: "Task graph")?.lowerBound != nil)
        if let completion = combined.firstRange(of: "✅")?.lowerBound,
           let overview = combined.firstRange(of: "Task graph")?.lowerBound {
            #expect(completion < overview)
        }
    }

    @Test
    func taskGraphOverviewAfterTasksUpdateUsesOnlyOneBlankRowAfterToolCompletion() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            standardOutputIsTerminal: true
        )
        let toolCall = DirectAgentToolCall(
            id: "task-update",
            name: "tasks.update",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        // Plain streaming prose is intentionally not newline-terminated before
        // the tool starts, matching the event sequence reported in the TUI.
        await renderer.writeAssistantContent("Checking the task graph.")
        await renderer.writeToolCallStarted(toolCall)
        let deferred = await renderer.renderTaskGraphOverview(
            signature: "graph:after-update",
            markdown: "Tasks\n"
        )
        #expect(deferred == .deferred)

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Updated", summary: "Updated")
        )
        let eventsBeforeOverview = await renderer.capturedWriteEvents()

        let rendered = await renderer.renderTaskGraphOverview(
            signature: "graph:after-update",
            markdown: "Tasks\n"
        )
        let overviewEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventsBeforeOverview.count)
        )
        let completedToolText = eventsBeforeOverview
            .last { $0.channel == .standardError }?
            .text ?? ""
        let overviewText = overviewEvents
            .filter { $0.channel == .standardOutput }
            .map(\.text)
            .joined()
        let boundary = TerminalANSIText.stripANSI(completedToolText + overviewText)

        #expect(rendered == .rendered)
        #expect(boundary.contains("✅"))
        #expect(boundary.contains("\n\nTasks"))
        #expect(!boundary.contains("\n\n\nTasks"))
    }

    @Test
    func interleavedFailureDrainsOverviewDeferredByTool() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = DirectAgentToolCall(
            id: "tool-cancelled",
            name: "tasks.list",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(toolCall)
        _ = await renderer.renderTaskGraphOverview(
            signature: "graph:cancelled",
            markdown: "## Task graph\n\n- pending\n"
        )

        await renderer.writeFailureMessage("Stopped.\n")

        let snapshot = await renderer.snapshot()
        let combined = await renderer.capturedWriteEvents().map(\.text).joined()
        #expect(snapshot.activeCompactToolCallID == nil)
        #expect(!snapshot.deferredTaskGraphOverviewRender)
        #expect(combined.contains("Stopped."))
        #expect(combined.contains("Task graph"))
        if let stopped = combined.firstRange(of: "Stopped.")?.lowerBound,
           let overview = combined.firstRange(of: "Task graph")?.lowerBound {
            #expect(stopped < overview)
        }
    }

    @Test
    func latestOverviewWaitsForAssistantFormattingBoundary() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeAssistantContent("Answer")
        let first = await renderer.renderTaskGraphOverview(
            signature: "graph:1",
            markdown: "## Task graph\n\n- stale\n"
        )
        await renderer.writeAssistantContent(" continues")
        let latest = await renderer.renderTaskGraphOverview(
            signature: "graph:2",
            markdown: "## Task graph\n\n- latest\n"
        )

        let deferred = await renderer.snapshot()
        let beforeFinish = await renderer.capturedWriteEvents()
        #expect(first == .deferred)
        #expect(latest == .deferred)
        #expect(deferred.deferredTaskGraphOverviewRender)
        #expect(!beforeFinish.map(\.text).joined().contains("Task graph"))

        await renderer.finishStreamingOutput()

        let rendered = await renderer.snapshot()
        let combined = await renderer.capturedWriteEvents().map(\.text).joined()
        #expect(!rendered.deferredTaskGraphOverviewRender)
        #expect(rendered.lastRenderedTaskGraphOverviewSignature == "graph:2")
        #expect(combined.contains("Answer continues"))
        #expect(!combined.contains("stale"))
        #expect(combined.contains("latest"))
        if let answer = combined.firstRange(of: "Answer continues")?.lowerBound,
           let overview = combined.firstRange(of: "Task graph")?.lowerBound {
            #expect(answer < overview)
        }
    }

    @Test
    func staleOverviewCallbackDoesNotDiscardNewerPendingPayload() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)
        _ = await renderer.renderTaskGraphOverview(
            signature: "graph:1",
            markdown: "## Task graph\n\n- initial\n",
            revision: 1
        )
        await renderer.writeAssistantContent("Answer")
        _ = await renderer.renderTaskGraphOverview(
            signature: "graph:3",
            markdown: "## Task graph\n\n- current\n",
            revision: 3
        )

        let stale = await renderer.renderTaskGraphOverview(
            signature: "graph:2",
            markdown: "## Task graph\n\n- stale\n",
            revision: 2
        )
        let deferred = await renderer.snapshot()
        await renderer.finishStreamingOutput()

        let rendered = await renderer.snapshot()
        let combined = await renderer.capturedWriteEvents().map(\.text).joined()
        #expect(stale == .unchanged)
        #expect(deferred.deferredTaskGraphOverviewRender)
        #expect(rendered.lastRenderedTaskGraphOverviewSignature == "graph:3")
        #expect(combined.contains("current"))
        #expect(!combined.contains("stale"))
    }

    @Test
    func newerPublicationFencesAnOlderGraphSnapshotEvenWhenItFinishesFirst() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)
        let olderPublication = await renderer.beginOverviewPublication(.taskGraph)
        let newerPublication = await renderer.beginOverviewPublication(.taskGraph)

        let current = await renderer.renderTaskGraphOverview(
            signature: "new-graph:1",
            markdown: "## Task graph\n\n- current\n",
            revision: newerPublication
        )
        let stale = await renderer.renderTaskGraphOverview(
            signature: "old-graph:99",
            markdown: "## Task graph\n\n- stale\n",
            revision: olderPublication
        )

        let combined = await renderer.capturedWriteEvents().map(\.text).joined()
        #expect(current == .rendered)
        #expect(stale == .unchanged)
        #expect(combined.contains("current"))
        #expect(!combined.contains("stale"))
    }

    @Test
    func staleResetCannotDiscardANewerDeferredOverview() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)
        await renderer.writeAssistantContent("Answer")
        let stalePublication = await renderer.beginOverviewPublication(.taskGraph)
        _ = await renderer.renderTaskGraphOverview(
            signature: "old-graph:1",
            markdown: "## Task graph\n\n- stale\n",
            revision: stalePublication
        )
        let currentPublication = await renderer.beginOverviewPublication(.taskGraph)
        _ = await renderer.renderTaskGraphOverview(
            signature: "new-graph:1",
            markdown: "## Task graph\n\n- current\n",
            revision: currentPublication
        )

        await renderer.resetOverview(.taskGraph, revision: stalePublication)
        await renderer.finishStreamingOutput()

        let combined = await renderer.capturedWriteEvents().map(\.text).joined()
        #expect(combined.contains("current"))
        #expect(!combined.contains("stale"))
    }

    @Test
    func suspendedOverviewWaitsUntilTheInteractiveOverlayIsReleased() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)
        await renderer.setOverviewPublishingSuspended(true)

        let result = await renderer.renderTaskGraphOverview(
            signature: "graph:menu",
            markdown: "## Task graph\n\n- after menu\n"
        )
        #expect(result == .deferred)
        #expect(await renderer.capturedWriteEvents().isEmpty)

        await renderer.setOverviewPublishingSuspended(false)

        let combined = await renderer.capturedWriteEvents().map(\.text).joined()
        #expect(combined.contains("after menu"))
    }

    @Test
    func deferredOverviewStartsOnANewLineForNonTerminalOutput() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeAssistantContent("Answer")
        _ = await renderer.renderTaskGraphOverview(
            signature: "graph:non-tty",
            markdown: "## Task graph\n\n- current\n"
        )
        await renderer.finishStreamingOutput()

        let output = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardOutput }
            .map(\.text)
            .joined()
        #expect(output.contains("Answer\n## Task graph"))
    }

    @Test
    func stderrOverviewCannotSuppressTheNonTerminalAssistantNewline() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeAssistantContent("Answer")
        _ = await renderer.renderSubAgentOverview(
            signature: "agents:1",
            text: "Agents updated.\n\n",
            force: false,
            rememberSignature: true
        )
        await renderer.finishStreamingOutput()
        await renderer.writeOutput("\n")

        let output = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardOutput }
            .map(\.text)
            .joined()
        #expect(output == "Answer\n")
    }

    @Test
    func completedSubAgentResponseUsesMarkdownAndRendersOnlyOnce() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let response = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "agent-1:completion-1",
            heading: "   ✅ Response from reviewer:\n",
            markdown: "**Finished** with `code`.\n\n- first\n- second"
        )

        let first = await renderer.renderSubAgentOverview(
            signature: "agents:completed",
            text: "Agents completed.\n",
            responses: [response],
            force: false,
            rememberSignature: true
        )
        let duplicate = await renderer.renderSubAgentOverview(
            signature: "agents:completed",
            text: "Agents completed.\n",
            responses: [response],
            force: false,
            rememberSignature: true
        )
        let refreshed = await renderer.renderSubAgentOverview(
            signature: "agents:refreshed",
            text: "Agents refreshed.\n",
            responses: [response],
            force: false,
            rememberSignature: true
        )

        let events = await renderer.capturedWriteEvents()
        let stdout = events
            .filter { $0.channel == .standardOutput }
            .map(\.text)
            .joined()
        let stderr = events
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        let snapshot = await renderer.snapshot()

        #expect(first == .rendered)
        #expect(duplicate == .unchanged)
        #expect(refreshed == .rendered)
        #expect(stdout.isEmpty)
        #expect(stderr.components(separatedBy: "Finished").count - 1 == 1)
        #expect(stderr.contains("\u{1B}[1mFinished\u{1B}[0m"))
        #expect(stderr.contains("\(TerminalMarkdownPalette.detected.inlineCodeForeground)code\u{1B}[0m"))
        #expect(!stderr.contains("**Finished**"))
        #expect(stderr.components(separatedBy: "Response from reviewer").count - 1 == 1)
        #expect(stderr.contains("Agents refreshed."))
        #expect(snapshot.lastRenderedSubAgentOverviewSignature == "agents:refreshed")
    }

    @Test
    func deferredSubAgentResponseIsConsumedOnlyAfterItRenders() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)
        let response = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "agent-2:completion-1",
            heading: "   ✅ Response from planner:\n",
            markdown: "Deferred answer"
        )
        await renderer.setOverviewPublishingSuspended(true)

        let deferred = await renderer.renderSubAgentOverview(
            signature: "agents:deferred",
            text: "Agents deferred.\n",
            responses: [response],
            force: false,
            rememberSignature: true
        )
        #expect(deferred == .deferred)
        #expect(await renderer.capturedWriteEvents().isEmpty)

        await renderer.setOverviewPublishingSuspended(false)
        let refreshed = await renderer.renderSubAgentOverview(
            signature: "agents:after-deferred",
            text: "Agents refreshed.\n",
            responses: [response],
            force: false,
            rememberSignature: true
        )
        let combined = await renderer.capturedWriteEvents().map(\.text).joined()

        #expect(refreshed == .rendered)
        #expect(combined.components(separatedBy: "Deferred answer").count - 1 == 1)
        #expect(combined.components(separatedBy: "Response from planner").count - 1 == 1)
        #expect(combined.contains("Agents refreshed."))
    }

    @Test
    func subAgentOverviewRefreshReplacesThePreviousSectionInPlace() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:1",
            text: "\n👥 Sub-Agents:\n   1 total\n   running\n",
            force: false,
            rememberSignature: true
        )
        let firstSnapshot = await renderer.snapshot()
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:2",
            text: "\n👥 Sub-Agents:\n   1 total\n   completed\n",
            force: false,
            rememberSignature: true
        )
        let events = await renderer.capturedWriteEvents()
        let refreshText = events
            .dropFirst(eventsBeforeRefresh)
            .map(\.text)
            .joined()
        let plainStderr = TerminalANSIText.stripANSI(
            events
                .filter { $0.channel == .standardError }
                .map(\.text)
                .joined()
        )

        #expect(firstSnapshot.activeSubAgentOverviewRowCount == 4)
        #expect(refreshText.hasPrefix("\u{1B}[4A\r"))
        #expect(refreshText.components(separatedBy: "\u{1B}[2K").count - 1 == 4)
        #expect(!refreshText.contains("\u{1B}[J"))
        #expect(plainStderr.components(separatedBy: "Sub-Agents:").count - 1 == 2)
        #expect(plainStderr.contains("completed"))
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 4)
    }

    @Test
    func subAgentOverviewIsAppendedWhenOtherOutputFollowedIt() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:1",
            text: "\n👥 Sub-Agents:\n   1 total\n",
            force: false,
            rememberSignature: true
        )
        await renderer.writeSystemMessage("Interleaved message.\n")
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:2",
            text: "\n👥 Sub-Agents:\n   2 total\n",
            force: false,
            rememberSignature: true
        )
        let refreshText = await renderer.capturedWriteEvents()
            .dropFirst(eventsBeforeRefresh)
            .map(\.text)
            .joined()

        #expect(!refreshText.contains("\u{1B}[2K"))
        #expect(TerminalANSIText.stripANSI(refreshText).contains("2 total"))
    }

    @Test
    func subAgentOverviewIsAppendedWhenStandardErrorIsNotATerminal() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            columnWidthProvider: { 80 }
        )

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:1",
            text: "\n👥 Sub-Agents:\n   1 total\n",
            force: false,
            rememberSignature: true
        )
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:2",
            text: "\n👥 Sub-Agents:\n   2 total\n",
            force: false,
            rememberSignature: true
        )
        let refreshText = await renderer.capturedWriteEvents()
            .dropFirst(eventsBeforeRefresh)
            .map(\.text)
            .joined()

        #expect(!refreshText.contains("\u{1B}[2K"))
        #expect(refreshText.contains("2 total"))
    }

    @Test
    func subAgentOverviewTallerThanTheScrollRegionIsAppended() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:1",
            text: "\n👥 Sub-Agents:\n   1 total\n   running\n",
            force: false,
            rememberSignature: true,
            maximumInPlaceRows: 2
        )
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:2",
            text: "\n👥 Sub-Agents:\n   1 total\n   completed\n",
            force: false,
            rememberSignature: true,
            maximumInPlaceRows: 2
        )
        let refreshText = await renderer.capturedWriteEvents()
            .dropFirst(eventsBeforeRefresh)
            .map(\.text)
            .joined()

        #expect(!refreshText.contains("\u{1B}[2K"))
        #expect(TerminalANSIText.stripANSI(refreshText).contains("completed"))
    }

    @Test
    func subAgentCompletedResponseIsNeverErasedByALaterRefresh() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let response = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "agent-3:completion-1",
            heading: "   ✅ Response from reviewer:\n",
            markdown: "Final answer"
        )

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:completed",
            text: "\n👥 Sub-Agents:\n   1 total\n",
            responses: [response],
            force: false,
            rememberSignature: true
        )
        // A section followed by a printed response gives up its rewrite slot.
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:after-response",
            text: "\n👥 Sub-Agents:\n   1 total closed\n",
            responses: [response],
            force: false,
            rememberSignature: true
        )
        let events = await renderer.capturedWriteEvents()
        let refreshText = events
            .dropFirst(eventsBeforeRefresh)
            .map(\.text)
            .joined()
        let plainStderr = TerminalANSIText.stripANSI(
            events
                .filter { $0.channel == .standardError }
                .map(\.text)
                .joined()
        )

        #expect(!refreshText.contains("\u{1B}[2K"))
        #expect(plainStderr.components(separatedBy: "Final answer").count - 1 == 1)
        #expect(plainStderr.contains("1 total closed"))
    }

    @Test
    func thoughtFragmentsAreBufferedUntilTheStreamIsFlushed() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeThought("Planning")
        await renderer.writeThought(" safely")

        #expect(await renderer.capturedWriteEvents().isEmpty)

        await renderer.finishStreamingOutput()
        let events = await renderer.capturedWriteEvents()
        let combined = events.map(\.text).joined()

        #expect(events.count == 1)
        #expect(combined.contains("Planning safely"))
    }

    @Test
    func subsequentSubmittedPromptsReceiveOneDimWidthSafeTurnRule() async {
        let terminalColumns = 7
        let rule = String(repeating: "─", count: 5)
        let renderer = makeRenderer(
            stdinIsTerminal: true,
            standardErrorIsTerminal: true,
            columnWidthProvider: { terminalColumns }
        )

        await renderer.writeSubmittedPrompt("first turn")
        let firstTurn = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        await renderer.writeSubmittedPrompt("second turn")
        await renderer.writeSubmittedPrompt("third turn")

        let stderr = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        let visibleRows = TerminalANSIText.stripANSI(stderr)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let ruleRows = visibleRows.filter { row in
            let trimmed = row.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && trimmed.allSatisfy { $0 == "─" }
        }

        #expect(!TerminalANSIText.stripANSI(firstTurn).contains(rule))
        #expect(ruleRows.count == 2)
        #expect(ruleRows.allSatisfy {
            TerminalChat.displayWidth($0) <= terminalColumns - 1
        })
        #expect(stderr.components(separatedBy: "\u{1B}[90m\(rule)\u{1B}[0m").count - 1 == 2)
        #expect(stderr.components(separatedBy: "> first turn").count - 1 == 1)
        #expect(stderr.components(separatedBy: "> second turn").count - 1 == 1)
        #expect(stderr.components(separatedBy: "> third turn").count - 1 == 1)
    }

    @Test
    func terminalThinkingFoldsAcrossDeltasAndReportsOmittedLines() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            terminalThoughtLineLimit: 2
        )

        await renderer.writeThought("first\nsecond\n")
        await renderer.writeThought("third\n")
        await renderer.writeThought("fourth\n")
        await renderer.finishThoughtOutput()

        let stderr = TerminalANSIText.stripANSI(
            await renderer.capturedWriteEvents()
                .filter { $0.channel == .standardError }
                .map(\.text)
                .joined()
        )

        #expect(stderr.contains("first"))
        #expect(stderr.contains("second"))
        #expect(!stderr.contains("third"))
        #expect(!stderr.contains("fourth"))
        #expect(stderr.contains("… 2 thinking lines omitted"))
    }

    @Test
    func terminalThinkingFoldsNoNewlineTextByPhysicalTerminalRows() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 8 },
            terminalThoughtLineLimit: 2
        )

        // With one trailing terminal cell reserved, each physical thought row
        // has seven content columns. The state must persist across deltas.
        await renderer.writeThought("abcdefghij")
        await renderer.writeThought("klmnopqrst")
        await renderer.finishThoughtOutput()

        let stderr = TerminalANSIText.stripANSI(
            await renderer.capturedWriteEvents()
                .filter { $0.channel == .standardError }
                .map(\.text)
                .joined()
        )

        #expect(stderr.contains("abcdefg\nhijklmn\n"))
        #expect(!stderr.contains("opqrst"))
        #expect(stderr.contains("… 1 thinking lines omitted"))
    }

    @Test
    func terminalThinkingCountsAnUnterminatedHiddenTail() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            terminalThoughtLineLimit: 1
        )

        await renderer.writeThought("visible\n")
        await renderer.writeThought("hidden tail without newline")
        await renderer.finishThoughtOutput()

        let stderr = TerminalANSIText.stripANSI(
            await renderer.capturedWriteEvents()
                .filter { $0.channel == .standardError }
                .map(\.text)
                .joined()
        )

        #expect(stderr.contains("visible"))
        #expect(!stderr.contains("hidden tail without newline"))
        #expect(stderr.contains("… 1 thinking lines omitted"))
    }

    @Test
    func nonTerminalThinkingNeverFolds() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            terminalThoughtLineLimit: 1
        )

        await renderer.writeThought("first\nsecond\n")
        await renderer.writeThought("third\n")
        await renderer.finishThoughtOutput()

        let stderr = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()

        #expect(stderr.contains("first\nsecond\nthird"))
        #expect(!stderr.contains("thinking lines omitted"))
    }

    @Test
    func terminalThinkingFoldResetsForTheNextStream() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            terminalThoughtLineLimit: 1
        )

        await renderer.writeThought("first visible\nfirst hidden\n")
        await renderer.finishThoughtOutput()
        await renderer.writeThought("second visible\nsecond hidden\n")
        await renderer.finishThoughtOutput()

        let stderr = TerminalANSIText.stripANSI(
            await renderer.capturedWriteEvents()
                .filter { $0.channel == .standardError }
                .map(\.text)
                .joined()
        )

        #expect(stderr.contains("first visible"))
        #expect(stderr.contains("second visible"))
        #expect(!stderr.contains("first hidden"))
        #expect(!stderr.contains("second hidden"))
        #expect(stderr.components(separatedBy: "… 1 thinking lines omitted").count - 1 == 2)
    }

    @Test
    func thoughtFoldingSurvivesToolAndAssistantInterleavingWithoutLosingAssistantContent() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            standardOutputIsTerminal: true,
            terminalThoughtLineLimit: 1
        )
        let toolCall = DirectAgentToolCall(
            id: "thought-fold-interleave",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeThought("first visible\nfirst hidden\n")
        // Starting a tool completes the first thought stream and must publish
        // its fold notice before the tool owns the terminal rows.
        await renderer.writeToolCallStarted(toolCall)
        await renderer.writeAssistantContent("Assistant answer survives")
        await renderer.finishAssistantContent()
        await renderer.writeThought("second visible\nsecond hidden\n")
        await renderer.finishStreamingOutput()

        let events = await renderer.capturedWriteEvents()
        let stderr = TerminalANSIText.stripANSI(
            events
                .filter { $0.channel == .standardError }
                .map(\.text)
                .joined()
        )
        let stdout = TerminalANSIText.stripANSI(
            events
                .filter { $0.channel == .standardOutput }
                .map(\.text)
                .joined()
        )

        #expect(stderr.contains("🛠️  agent.wait ⏳"))
        #expect(stderr.components(separatedBy: "… 1 thinking lines omitted").count - 1 == 2)
        #expect(!stderr.contains("first hidden"))
        #expect(!stderr.contains("second hidden"))
        #expect(stdout.contains("Assistant answer survives"))
    }

    @Test
    func finishingNonTerminalAssistantDoesNotAppendANewline() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeAssistantContent("Answer*")
        await renderer.finishStreamingOutput()

        let stdout = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardOutput }
            .map(\.text)
            .joined()
        #expect(stdout == "Answer*")
    }

    @Test
    func scheduledFlushKeepsAQuietStreamResponsive() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            streamingFlushDelay: .milliseconds(5)
        )

        await renderer.writeThought("Planning")
        await renderer.waitForScheduledStreamingFlush()

        let events = await renderer.capturedWriteEvents()
        #expect(!events.isEmpty)
        #expect(events.map(\.text).joined().contains("Planning"))

        await renderer.finishStreamingOutput()
    }

    @Test
    func firstStreamingChunkIsFlushedImmediatelyWithoutDelay() async {
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            streamingFlushDelay: .milliseconds(32),
            streamingNow: { clock.now }
        )

        await renderer.writeAssistantContent("Answer")
        // Leading-edge: the very first chunk must already be visible
        // without waiting for the 32 ms trailing-edge timer.
        let events = await renderer.capturedWriteEvents()
        #expect(!events.isEmpty)
        #expect(events.map(\.text).joined().contains("Answer"))
    }

    @Test
    func subsequentStreamingChunksAreCoalescedAfterLeadingEdgeFlush() async {
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            streamingFlushDelay: .seconds(5),
            streamingNow: { clock.now }
        )

        await renderer.writeAssistantContent("Answer")
        let firstCount = await renderer.capturedWriteEvents().count
        #expect(firstCount == 1)

        // Still inside the idle window: the next chunk must NOT be
        // emitted immediately — it is coalesced for the trailing-edge timer.
        // The large flush delay guarantees the real Task.sleep timer cannot
        // fire between the write and the assertion on a slow CI: the clock
        // controls the leading-edge idle check, but the timer sleeps in wall
        // time, so only an oversized delay eliminates the race.
        clock.advance(by: .milliseconds(1))
        await renderer.writeAssistantContent(" continues")
        let secondCount = await renderer.capturedWriteEvents().count
        #expect(secondCount == 1)

        // Flush the coalesced remainder deterministically. finishStreamingOutput
        // cancels the pending trailing-edge timer and emits the buffered chunk.
        await renderer.finishStreamingOutput()
        let events = await renderer.capturedWriteEvents()
        #expect(events.count == 2)
        #expect(events.map(\.text).joined().contains("Answer continues"))
    }

    @Test
    func leadingEdgeReArmsAfterIdleWindowElapses() async {
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            streamingFlushDelay: .milliseconds(32),
            streamingNow: { clock.now }
        )

        await renderer.writeAssistantContent("First")
        let firstEvents = await renderer.capturedWriteEvents()
        #expect(firstEvents.count == 1)

        // Advance past the idle window so the leading edge re-arms.
        clock.advance(by: .milliseconds(40))
        await renderer.writeAssistantContent("Second")
        let secondEvents = await renderer.capturedWriteEvents()
        #expect(secondEvents.count == 2)
    }

    @Test
    func leadingEdgeFlushPreservesWriteEventOrder() async {
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            streamingFlushDelay: .milliseconds(32),
            streamingNow: { clock.now }
        )

        await renderer.writeAssistantContent("alpha")
        clock.advance(by: .milliseconds(1))
        await renderer.writeAssistantContent("beta")
        await renderer.waitForScheduledStreamingFlush()

        let events = await renderer.capturedWriteEvents()
        #expect(events.count == 2)
        #expect(events.map(\.sequence) == [0, 1])
        #expect(events[0].text.contains("alpha"))
        #expect(events[1].text.contains("beta"))
    }

    @Test
    func leadingEdgeFlushPreservesCrossChannelWriteEventOrder() async {
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            streamingFlushDelay: .seconds(5),
            streamingNow: { clock.now }
        )

        // Thought on stderr: the thinking title is the very first chunk of a
        // burst and is leading-edge flushed immediately so the user sees it
        // without waiting for the trailing-edge timer.
        await renderer.writeThought("Planning")
        let afterThought = await renderer.capturedWriteEvents()
        #expect(afterThought.allSatisfy { $0.channel == .standardError })
        #expect(afterThought.map(\.text).joined().contains("Thinking:"))

        // Cross-channel switch to assistant on stdout. writeAssistantContent
        // first finishes the pending thought (flushing the coalesced body and
        // trailing newlines to stderr), then buffers the assistant chunk.
        // The large flush delay guarantees the real timer cannot fire during
        // the assertions below.
        clock.advance(by: .milliseconds(1))
        await renderer.writeAssistantContent("Answer")
        let afterSwitch = await renderer.capturedWriteEvents()

        // The thought body was flushed to stderr by the finish.
        #expect(afterSwitch.filter { $0.channel == .standardError }
            .map(\.text).joined().contains("Planning"))
        // The assistant chunk on stdout is still coalesced behind the timer
        // (not yet flushed) because the thought-finish reset the idle window.
        #expect(afterSwitch.filter { $0.channel == .standardOutput }.isEmpty)

        // Flush the coalesced assistant remainder and cancel the timer.
        await renderer.finishStreamingOutput()
        let events = await renderer.capturedWriteEvents()

        // Sequence numbers are strictly monotonic across both channels.
        #expect(events.map(\.sequence) == Array(0..<UInt64(events.count)))

        // Every stderr (thought) event precedes every stdout (assistant) event.
        if let lastStderr = events.lastIndex(where: { $0.channel == .standardError }),
           let firstStdout = events.firstIndex(where: { $0.channel == .standardOutput }) {
            #expect(lastStderr < firstStdout)
        }

        // The assistant content is present on stdout after the flush.
        #expect(events.filter { $0.channel == .standardOutput }
            .map(\.text).joined().contains("Answer"))
    }

    @Test
    func thoughtAndAssistantDeltasShareOneOrderedStreamingState() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeThought("Planning")
        await renderer.writeThought(" safely")
        await renderer.writeAssistantContent("Answer")
        await renderer.finishStreamingOutput()

        let events = await renderer.capturedWriteEvents()
        let combined = events.map(\.text).joined()

        #expect(combined.components(separatedBy: "🤔 Thinking:").count == 2)
        #expect(combined.contains("Planning safely"))
        #expect(combined.contains("Answer"))
        #expect(!combined.contains("\n\n\n"))
        if let thought = combined.firstRange(of: "Planning safely")?.lowerBound,
           let answer = combined.firstRange(of: "Answer")?.lowerBound {
            #expect(thought < answer)
        }
    }

    @Test
    func subAgentOverviewStaysDeferredWhenPublishingSuspendedDuringAgentToolBlock() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = DirectAgentToolCall(
            id: "wait-tool",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(toolCall)
        let startedSnapshot = await renderer.snapshot()

        await renderer.setOverviewPublishingSuspended(true)

        // Capture write events before the render attempt — no new output
        // should be produced while publication is suspended.
        let writeCountBeforeRender = await renderer.capturedWriteEvents().count

        let result = await renderer.renderSubAgentOverview(
            signature: "agents:suspended",
            text: "Agents updated.\n\n",
            force: false,
            rememberSignature: true
        )
        let suspendedSnapshot = await renderer.snapshot()
        let writeCountAfterRender = await renderer.capturedWriteEvents().count

        // Publication is suspended: the overview must stay deferred and the
        // active agent.* tool block must NOT be interrupted — its in-place
        // rewrite rows must remain intact for a later toolCallCompleted.
        #expect(result == .deferred)
        #expect(suspendedSnapshot.lastRenderedSubAgentOverviewSignature == nil)
        #expect(suspendedSnapshot.deferredSubAgentOverviewRender)
        #expect(suspendedSnapshot.activeCompactToolCallID == toolCall.id)
        #expect(
            suspendedSnapshot.activeCompactToolRenderedRowCount
                == startedSnapshot.activeCompactToolRenderedRowCount
        )
        // No writes at all: neither the overview body nor a stray newline
        // from an interrupted tool block.
        #expect(writeCountBeforeRender == writeCountAfterRender)

        // Resume and complete: the tool block was preserved, so the
        // completion handler can still clear the owned rows correctly.
        await renderer.setOverviewPublishingSuspended(false)
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )
        let completedSnapshot = await renderer.snapshot()
        #expect(completedSnapshot.activeCompactToolCallID == nil)
        #expect(completedSnapshot.activeCompactToolRenderedRowCount == 0)
    }

    @Test
    func staleCompletionDoesNotRelinquishNewerToolOwnership() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let first = DirectAgentToolCall(
            id: "overlap-first",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        let second = DirectAgentToolCall(
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
        let staleCompletionText = (await renderer.capturedWriteEvents())
            .dropFirst(eventCountBeforeStaleCompletion)
            .map(\.text)
            .joined()

        #expect(afterStaleCompletion.activeCompactToolCallID == second.id)
        #expect(!containsCursorUpSequence(staleCompletionText))
        #expect(staleCompletionText.contains("✅"))

        let eventCountBeforeOwningCompletion = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            second,
            result: DirectAgentToolResult(output: "second", summary: "second")
        )
        let afterOwningCompletion = await renderer.snapshot()
        let owningCompletionText = (await renderer.capturedWriteEvents())
            .dropFirst(eventCountBeforeOwningCompletion)
            .map(\.text)
            .joined()

        #expect(afterOwningCompletion.activeCompactToolCallID == nil)
        #expect(containsCursorUpSequence(owningCompletionText))
    }

    @Test
    func detailedCompletionKeepsItsOwnedStyleAfterSwitchingToCompact() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = DirectAgentToolCall(
            id: "detailed-style-change",
            name: "local.readFile",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.setToolOutputDetailLevel(.expanded)
        await renderer.writeToolCallStarted(toolCall)
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count
        await renderer.setToolOutputDetailLevel(.compact)
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let completionText = (await renderer.capturedWriteEvents())
            .dropFirst(eventCountBeforeCompletion)
            .map(\.text)
            .joined()
        #expect(containsCursorUpSequence(completionText))
        #expect(TerminalANSIText.stripANSI(completionText).contains("status: ✅"))
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
        let toolCall = DirectAgentToolCall(
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

        let completionText = (await renderer.capturedWriteEvents())
            .dropFirst(eventCountBeforeCompletion)
            .map(\.text)
            .joined()
        #expect(cachedWidth.readCount == 1)
        #expect(freshWidth.readCount == 1)
        #expect(!containsCursorUpSequence(completionText))
        #expect(completionText.contains("✅"))
    }

    @Test
    func separateTerminalTopologyClosesAssistantOutputUsingStdoutCursor() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            standardOutputIsTerminal: true,
            cursorTopology: .separate
        )

        await renderer.writeAssistantContent("Answer")
        // stderr ends a row on its own terminal, not on stdout's terminal.
        await renderer.writeError("\n")
        await renderer.finishAssistantContent()

        let stdout = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardOutput }
            .map(\.text)
            .joined()
        #expect(TerminalANSIText.stripANSI(stdout) == "Answer\n")
    }

    @Test
    func sharedTerminalTopologyReusesTheErrorCursorForAssistantCompletion() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            standardOutputIsTerminal: true,
            cursorTopology: .shared
        )

        await renderer.writeAssistantContent("Answer")
        await renderer.writeError("\n")
        await renderer.finishAssistantContent()

        let stdout = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardOutput }
            .map(\.text)
            .joined()
        // The shared stderr newline already closed the physical row, so stdout
        // must not add a duplicate line boundary.
        #expect(TerminalANSIText.stripANSI(stdout) == "Answer")
    }

    @Test
    func aLoneThoughtAsteriskIsFlushedAtEndOfStream() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeThought("*")
        await renderer.finishThoughtOutput()

        let stderr = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        #expect(stderr.contains("🤔 Thinking:"))
        #expect(stderr.contains("*"))
    }

    @Test
    func expandedMutationCompletionUsesTerminalSafeSideBySideBudget() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )
        let toolCall = DirectAgentToolCall(
            id: "expanded-crlf-tab-diff",
            name: "local.editFile",
            argumentsObject: [
                "path": "Sources/Feature.swift",
                "oldString": "// removed\r\n\tlet oldValue = 1",
                "newString": "let newValue = 2\r\n\tlet replacement = 3"
            ],
            argumentsJSON: "{}"
        )
        await renderer.setToolOutputDetailLevel(.expanded)
        await renderer.writeToolCallStarted(toolCall)
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "", summary: "updated")
        )

        let completionText = await renderer.capturedWriteEvents()
            .dropFirst(eventCountBeforeCompletion)
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        let visibleRows = TerminalANSIText.stripANSI(completionText)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let sideBySideRows = visibleRows.filter {
            $0.contains("// removed") && $0.contains("let newValue = 2")
        }

        #expect(sideBySideRows.count == 1)
        #expect(sideBySideRows.allSatisfy { TerminalChat.displayWidth($0) <= 80 })
        #expect(sideBySideRows.allSatisfy { !$0.contains("\r") && !$0.contains("\t") })
        // `let` comes after a comment on the old side, so this color can only
        // appear when the coordinator renders the new column independently.
        #expect(completionText.contains("\u{1B}[38;5;141mlet"))
    }

    @Test
    func expandedMutationCompletionKeepsColumnsSeparateForAnsiHostilePayload() async {
        // End-to-end guard for the former in-band boundary sentinel: a payload
        // containing that exact sequence must not be able to split the row at
        // the wrong place or leak into the other column.
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 120 }
        )
        let toolCall = DirectAgentToolCall(
            id: "expanded-ansi-collision",
            name: "local.editFile",
            argumentsObject: [
                "path": "Sources/Feature.swift",
                "oldString": "\u{1B}[0m │ let injected = 1",
                "newString": "let replacement = 2"
            ],
            argumentsJSON: "{}"
        )
        await renderer.setToolOutputDetailLevel(.expanded)
        await renderer.writeToolCallStarted(toolCall)
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "", summary: "updated")
        )

        let completionText = await renderer.capturedWriteEvents()
            .dropFirst(eventCountBeforeCompletion)
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        let visibleRows = TerminalANSIText.stripANSI(completionText)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let diffRows = visibleRows.filter { $0.contains("let injected = 1") }

        #expect(diffRows.count == 1)
        #expect(diffRows.allSatisfy { $0.contains("let replacement = 2") })
        #expect(visibleRows.allSatisfy { TerminalChat.displayWidth($0) <= 120 })
    }

    @Test
    func expandedToolBlockNeutralizesControlSequencesInPathMetadataEndToEnd() async {
        // End-to-end guard: a hostile path must not be able to emit ESC, CR, LF
        // or a tab through the title, the location row or the change row of the
        // expanded block, at start or at completion.
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        let toolCall = DirectAgentToolCall(
            id: "expanded-path-injection",
            name: "local.writeFile",
            argumentsObject: [
                "path": "Sources/\u{1B}[2J\u{1B}[1;1H\u{9B}31mApp\u{7F}.swift",
                "content": "let value = 1"
            ],
            argumentsJSON: "{}"
        )

        await renderer.setToolOutputDetailLevel(.expanded)
        await renderer.writeToolCallStarted(toolCall)
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "", summary: "written")
        )

        let text = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        // Split on both newline and CR: a CR here belongs to the coordinator's
        // own cursor repositioning, never to the payload.
        let visibleRows = TerminalANSIText.stripANSI(text)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)
        let metadataRows = visibleRows.filter { !$0.hasPrefix("  ") }

        for row in metadataRows {
            #expect(!row.contains("\u{1B}"))
            #expect(!row.contains("\u{9B}"))
            #expect(!row.contains("\t"))
            #expect(!row.contains("\u{7F}"))
        }
        // No screen-clear or cursor-home sequence may survive anywhere.
        #expect(!text.contains("\u{1B}[2J"))
        #expect(!text.contains("\u{1B}[1;1H"))
        #expect(visibleRows.contains { $0.contains("change: write ") })
        #expect(visibleRows.allSatisfy { TerminalChat.displayWidth($0) <= 100 })
    }

    @Test
    func expandedPatchBlockNeutralizesControlSequencesFromPatchDerivedTarget() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        let toolCall = DirectAgentToolCall(
            id: "expanded-patch-injection",
            name: "local.applyPatch",
            argumentsObject: [
                "patch": "*** Update File: Sources/\u{1B}[2JInjected.swift\n@@\n-let a = 1\n+let b = 2\n"
            ],
            argumentsJSON: "{}"
        )

        await renderer.setToolOutputDetailLevel(.expanded)
        await renderer.writeToolCallStarted(toolCall)
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "", summary: "patched")
        )

        let text = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        let visibleRows = TerminalANSIText.stripANSI(text)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)

        #expect(!text.contains("\u{1B}[2J"))
        #expect(visibleRows.contains { $0.hasPrefix("change: patch ") })
        #expect(visibleRows.filter { !$0.hasPrefix("  ") }.allSatisfy { !$0.contains("\u{1B}") })
        #expect(visibleRows.allSatisfy { TerminalChat.displayWidth($0) <= 100 })
    }

    @Test
    func expandedRemoveAndMoveXcodeAliasesRenderMutationChangeRows() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        await renderer.setToolOutputDetailLevel(.expanded)

        let removeCall = DirectAgentToolCall(
            id: "expanded-xcode-rm",
            name: "xcode.rm",
            argumentsObject: ["path": "Sources/Legacy.swift"],
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(removeCall)
        await renderer.writeToolCallCompleted(
            removeCall,
            result: DirectAgentToolResult(output: "", summary: "removed")
        )

        let moveCall = DirectAgentToolCall(
            id: "expanded-xcode-mv",
            name: "xcode.mv",
            argumentsObject: [
                "sourcePath": "Sources/Old.swift",
                "destinationPath": "Sources/New.swift"
            ],
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(moveCall)
        await renderer.writeToolCallCompleted(
            moveCall,
            result: DirectAgentToolResult(output: "", summary: "moved")
        )

        let visibleText = TerminalANSIText.stripANSI(
            await renderer.capturedWriteEvents()
                .filter { $0.channel == .standardError }
                .map(\.text)
                .joined()
        )

        // The `change: pending` row proves the alias is classified as a mutation
        // at start time, and the completion rows come from the routed cases.
        #expect(visibleText.contains("change: pending"))
        #expect(visibleText.contains("change: delete Sources/Legacy.swift"))
        #expect(visibleText.contains("change: move"))
        #expect(visibleText.contains("from: Sources/Old.swift"))
        #expect(visibleText.contains("to: Sources/New.swift"))
    }

    @Test
    func expandedXcodeMoveHidesRawControlCharacterParameters() async {
        // The markers make each hostile scalar distinguishable from terminal
        // framing emitted by the coordinator itself. `xcode.mv` only renders
        // sanitized metadata rows, never its raw parameter JSON.
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        let toolCall = DirectAgentToolCall(
            id: "expanded-xcode-mv-parameter-injection",
            name: "xcode.mv",
            argumentsObject: [
                "sourcePath": "Sources/Old\nLF_MARKER\u{1B}ESC_MARKER\rCR_MARKER\tTAB_MARKER\u{9B}C1_MARKER.swift",
                "destinationPath": "Sources/New.swift"
            ],
            argumentsJSON: "{}"
        )

        await renderer.setToolOutputDetailLevel(.expanded)
        await renderer.writeToolCallStarted(toolCall)
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "", summary: "moved")
        )

        let text = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        let visibleText = TerminalANSIText.stripANSI(text)

        #expect(!visibleText.contains("parameters:"))
        for rawSequence in [
            "\nLF_MARKER", "\u{1B}ESC_MARKER", "\rCR_MARKER",
            "\tTAB_MARKER", "\u{9B}C1_MARKER"
        ] {
            #expect(!text.contains(rawSequence))
        }
        #expect(visibleText.contains("change: move"))
        #expect(visibleText.contains("from: Sources/Old LF_MARKER ESC_MARKER CR_MARKER TAB_MARKER C1_MARKER.swift"))
        #expect(visibleText.contains("to: Sources/New.swift"))
    }

    @Test
    func expandedEmptyPayloadRendersDistinctlyFromLiteralMarkerPayload() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        await renderer.setToolOutputDetailLevel(.expanded)

        let emptyCall = DirectAgentToolCall(
            id: "expanded-empty-payload",
            name: "local.writeFile",
            argumentsObject: ["path": "Sources/Empty.swift", "content": ""],
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(emptyCall)
        await renderer.writeToolCallCompleted(
            emptyCall,
            result: DirectAgentToolResult(output: "", summary: "written")
        )
        let emptyEventCount = await renderer.capturedWriteEvents().count

        let literalCall = DirectAgentToolCall(
            id: "expanded-literal-marker",
            name: "local.writeFile",
            argumentsObject: ["path": "Sources/Literal.swift", "content": "<empty>"],
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(literalCall)
        await renderer.writeToolCallCompleted(
            literalCall,
            result: DirectAgentToolResult(output: "", summary: "written")
        )

        let allEvents = await renderer.capturedWriteEvents()
        let emptyText = TerminalANSIText.stripANSI(
            allEvents.prefix(emptyEventCount)
                .filter { $0.channel == .standardError }
                .map(\.text)
                .joined()
        )
        let literalText = TerminalANSIText.stripANSI(
            allEvents.dropFirst(emptyEventCount)
                .filter { $0.channel == .standardError }
                .map(\.text)
                .joined()
        )

        // The empty payload has no numbered line; the literal one does.
        #expect(emptyText.contains("<empty>"))
        #expect(!emptyText.contains("1 │ <empty>"))
        #expect(literalText.contains("1 │ <empty>"))
    }

    private func makeRenderer(
        stdinIsTerminal: Bool = false,
        standardErrorIsTerminal: Bool,
        standardOutputIsTerminal: Bool = false,
        streamingFlushDelay: Duration? = nil,
        streamingNow: @Sendable @escaping () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        toolNow: @Sendable @escaping () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        columnWidthProvider: (@Sendable () -> Int)? = nil,
        freshColumnWidthProvider: (@Sendable () -> Int)? = nil,
        terminalThoughtLineLimit: Int = 12,
        cursorTopology: TerminalChatRenderCoordinator.CursorTopology? = nil
    ) -> TerminalChatRenderCoordinator {
        let resolvedTopology: TerminalChatRenderCoordinator.CursorTopology?
        if let cursorTopology {
            resolvedTopology = cursorTopology
        } else if standardOutputIsTerminal && standardErrorIsTerminal {
            // Existing tests with two captured TTY channels model the legacy
            // one-terminal transcript explicitly.
            resolvedTopology = .shared
        } else {
            resolvedTopology = nil
        }
        return TerminalChatRenderCoordinator(
            stdinIsTerminal: stdinIsTerminal,
            standardOutput: nil,
            standardError: nil,
            standardOutputIsTerminal: standardOutputIsTerminal,
            standardErrorIsTerminal: standardErrorIsTerminal,
            cursorTopology: resolvedTopology,
            capturesWrites: true,
            streamingFlushDelay: streamingFlushDelay,
            streamingNow: streamingNow,
            toolNow: toolNow,
            columnWidthProvider: columnWidthProvider,
            freshColumnWidthProvider: freshColumnWidthProvider,
            terminalThoughtLineLimit: terminalThoughtLineLimit
        )
    }
}

/// Mutable, thread-safe-ish box for simulating terminal resize in tests.
/// Tests are single-threaded (async on one task), so plain `var` is safe;
/// `@unchecked Sendable` satisfies the `@Sendable` closure requirement.
private final class ColumnWidthBox: @unchecked Sendable {
    var width: Int
    var readCount = 0
    init(_ width: Int) { self.width = width }
}

/// Controllable clock for deterministic leading-edge flush tests.  Because
/// the render coordinator is an actor and tests are single-tasked, the plain
/// `var` is safe to mutate between `await` points; `@unchecked Sendable`
/// satisfies the `@Sendable` closure requirement.
private final class StreamingClock: @unchecked Sendable {
    private(set) var now = ContinuousClock().now
    func advance(by duration: Duration) {
        now = now.advanced(by: duration)
    }
}

/// Detects a CSI cursor-up sequence (`ESC [ <digits> A`), the destructive
/// move emitted only by ``TerminalChatRenderCoordinator``'s
/// ``clearOwnedToolRows``. Color/reset codes end in `m`, erase-line ends in
/// `K`, and cursor-down ends in `B`, so none of them ever produce a false
/// positive here.
private func containsCursorUpSequence(_ text: String) -> Bool {
    var pos = text.startIndex
    while let r = text.range(of: "\u{1B}[", range: pos..<text.endIndex) {
        var i = r.upperBound
        var sawDigit = false
        while i < text.endIndex, text[i].isNumber {
            sawDigit = true
            i = text.index(after: i)
        }
        if sawDigit, i < text.endIndex, text[i] == "A" {
            return true
        }
        pos = r.upperBound
    }
    return false
}

@Suite("Tool block safety fuse on terminal resize")
struct TerminalChatToolBlockResizeTests {
    @Test
    func compactResizeFromWideToNarrowSkipsDestructiveClear() async {
        let widthBox = ColumnWidthBox(100)
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { widthBox.width }
        )
        let toolCall = DirectAgentToolCall(
            id: "resize-compact-100-40",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents()
            .count
        #expect(started.activeCompactToolCallID == toolCall.id)
        #expect(started.activeCompactToolRenderedRowCount > 0)

        // Simulate terminal shrink between start and completion.
        widthBox.width = 40
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let events = await renderer.capturedWriteEvents()
        let completionEvents = Array(events.dropFirst(eventCountBeforeCompletion))
        let completionText = completionEvents.map(\.text).joined()

        // No destructive cursor-up sequence — the stale row count must not be
        // used to move the cursor or erase rows.
        #expect(!containsCursorUpSequence(completionText))
        // The completed block (✅) is present in append-only mode.
        #expect(completionText.contains("✅"))
        // The pending block (⏳) remains visible because we skipped the clear.
        let stderr = events
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        #expect(stderr.contains("⏳"))
        #expect(stderr.contains("✅"))
    }

    @Test
    func compactResizeFromNarrowToWideSkipsDestructiveClear() async {
        let widthBox = ColumnWidthBox(40)
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { widthBox.width }
        )
        let toolCall = DirectAgentToolCall(
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
        let completionText = completionEvents.map(\.text).joined()

        #expect(!containsCursorUpSequence(completionText))
        #expect(completionText.contains("✅"))
    }

    @Test
    func detailedResizeFromWideToNarrowSkipsDestructiveClear() async {
        let widthBox = ColumnWidthBox(100)
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { widthBox.width }
        )
        let toolCall = DirectAgentToolCall(
            id: "resize-detailed-100-40",
            name: "local.readFile",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await renderer.setToolOutputDetailLevel(.expanded)

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents()
            .count
        #expect(started.activeDetailedToolCallID == toolCall.id)
        #expect(started.activeDetailedToolRenderedRowCount > 0)

        // Simulate terminal shrink between start and completion.
        widthBox.width = 40
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done")
        )

        let events = await renderer.capturedWriteEvents()
        let completionEvents = Array(events.dropFirst(eventCountBeforeCompletion))
        let completionText = completionEvents.map(\.text).joined()

        #expect(!containsCursorUpSequence(completionText))
        #expect(completionText.contains("✅"))
    }

    @Test
    func compactNoResizeClearsAsBefore() async {
        let widthBox = ColumnWidthBox(100)
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { widthBox.width }
        )
        let toolCall = DirectAgentToolCall(
            id: "resize-compact-stable",
            name: "agent.wait",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents()
            .count
        #expect(started.activeCompactToolRenderedRowCount > 0)

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
                "\u{1B}[\(started.activeCompactToolRenderedRowCount)A\r"
            )
        )
        #expect(
            rewriteSequence.components(separatedBy: "\u{1B}[2K").count - 1
                == started.activeCompactToolRenderedRowCount
        )
        #expect(!completionEvents.map(\.text).joined().contains("\u{1B}[J"))
    }

    @Test
    func detailedNoResizeClearsAsBefore() async {
        let widthBox = ColumnWidthBox(100)
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { widthBox.width }
        )
        let toolCall = DirectAgentToolCall(
            id: "resize-detailed-stable",
            name: "local.readFile",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await renderer.setToolOutputDetailLevel(.expanded)

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents()
            .count
        #expect(started.activeDetailedToolRenderedRowCount > 0)

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
                "\u{1B}[\(started.activeDetailedToolRenderedRowCount)A\r"
            )
        )
        #expect(
            rewriteSequence.components(separatedBy: "\u{1B}[2K").count - 1
                == started.activeDetailedToolRenderedRowCount
        )
        #expect(!completionEvents.map(\.text).joined().contains("\u{1B}[J"))
    }

    @Test
    func semanticDetailedToolKeepsTheExistingOwnedRowRedrawContract() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 100 }
        )
        let toolCall = DirectAgentToolCall(
            id: "semantic-redraw",
            name: "thirdparty.edit",
            argumentsObject: [
                "path": "/tmp/App.swift",
                "old": "old",
                "new": "new"
            ],
            argumentsJSON: "{}",
            presentation: ToolPresentationDefinition(
                title: "Source file",
                action: "Edit",
                kind: .edit,
                target: .argument(["path"], format: .path),
                sections: [
                    .diff(
                        label: "change",
                        old: .argument(["old"], format: .text),
                        new: .argument(["new"], format: .text)
                    )
                ]
            )
        )
        await renderer.setToolOutputDetailLevel(.expanded)

        await renderer.writeToolCallStarted(toolCall)
        let started = await renderer.snapshot()
        let eventCountBeforeCompletion = await renderer.capturedWriteEvents().count

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "done", summary: "done")
        )

        let completionEvents = Array(
            (await renderer.capturedWriteEvents()).dropFirst(eventCountBeforeCompletion)
        )
        let completionText = TerminalANSIText.stripANSI(
            completionEvents.map(\.text).joined()
        )
        let rewriteSequence = completionEvents.first?.text ?? ""

        #expect(started.activeDetailedToolRenderedRowCount > 0)
        #expect(
            rewriteSequence.hasPrefix(
                "\u{1B}[\(started.activeDetailedToolRenderedRowCount)A\r"
            )
        )
        #expect(completionText.contains("Source file"))
        #expect(completionText.contains("target: /tmp/App.swift"))
        #expect(completionText.contains("status: ✅"))
        #expect(!completionEvents.map(\.text).joined().contains("\u{1B}[J"))
    }

    private func makeRenderer(
        standardErrorIsTerminal: Bool,
        columnWidthProvider: @Sendable @escaping () -> Int
    ) -> TerminalChatRenderCoordinator {
        TerminalChatRenderCoordinator(
            stdinIsTerminal: false,
            standardOutput: nil,
            standardError: nil,
            standardOutputIsTerminal: false,
            standardErrorIsTerminal: standardErrorIsTerminal,
            capturesWrites: true,
            streamingFlushDelay: nil,
            columnWidthProvider: columnWidthProvider
        )
    }
}
