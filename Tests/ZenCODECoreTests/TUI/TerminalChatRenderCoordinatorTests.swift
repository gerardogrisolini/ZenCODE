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
        #expect(boundary.contains("✅\n\nTasks"))
        #expect(!boundary.contains("✅\n\n\nTasks"))
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

    private func makeRenderer(
        stdinIsTerminal: Bool = false,
        standardErrorIsTerminal: Bool,
        standardOutputIsTerminal: Bool = false,
        streamingFlushDelay: Duration? = nil,
        streamingNow: @Sendable @escaping () -> ContinuousClock.Instant = {
            ContinuousClock().now
        },
        columnWidthProvider: @Sendable @escaping () -> Int = {
            TerminalChat.terminalColumnCount()
        }
    ) -> TerminalChatRenderCoordinator {
        TerminalChatRenderCoordinator(
            stdinIsTerminal: stdinIsTerminal,
            standardOutput: nil,
            standardError: nil,
            standardOutputIsTerminal: standardOutputIsTerminal,
            standardErrorIsTerminal: standardErrorIsTerminal,
            capturesWrites: true,
            streamingFlushDelay: streamingFlushDelay,
            streamingNow: streamingNow,
            columnWidthProvider: columnWidthProvider
        )
    }
}

/// Mutable, thread-safe-ish box for simulating terminal resize in tests.
/// Tests are single-threaded (async on one task), so plain `var` is safe;
/// `@unchecked Sendable` satisfies the `@Sendable` closure requirement.
private final class ColumnWidthBox: @unchecked Sendable {
    var width: Int
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
