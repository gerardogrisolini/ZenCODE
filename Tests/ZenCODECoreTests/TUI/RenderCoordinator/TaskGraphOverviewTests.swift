import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension TerminalChatRenderCoordinatorTests {
    @Test
    func overviewIsDeferredUntilToolNoLongerOwnsRows() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = presentedToolCall(
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
        let combined = finalEvents.renderedText()

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
        let toolCall = presentedToolCall(
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
        let overviewText = overviewEvents.renderedText(on: .standardOutput)
        let boundary = TerminalANSIText.stripANSI(completedToolText + overviewText)

        #expect(rendered == .rendered)
        #expect(boundary.contains("✅"))
        #expect(boundary.contains("\n\nTasks"))
        #expect(!boundary.contains("\n\n\nTasks"))
    }

    @Test
    func interleavedFailureDrainsOverviewDeferredByTool() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = presentedToolCall(
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
        let combined = await renderer.capturedText()
        #expect(snapshot.activeToolCallID == nil)
        #expect(!snapshot.deferredTaskGraphOverviewRender)
        #expect(combined.contains("Stopped."))
        #expect(combined.contains("Task graph"))
        if let stopped = combined.firstRange(of: "Stopped.")?.lowerBound,
           let overview = combined.firstRange(of: "Task graph")?.lowerBound {
            #expect(stopped < overview)
        }
    }

    @Test
    func finalFileChangeSummaryFollowsPendingOverviewWithoutDrainingAfterward() async throws {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let toolCall = presentedToolCall(
            id: "tool-before-final-summary",
            name: "tasks.list",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await renderer.writeToolCallStarted(toolCall)
        let deferred = await renderer.renderTaskGraphOverview(
            signature: "graph:before-final-summary",
            markdown: "## Task graph\n\n- pending\n"
        )

        await renderer.writeFinalFileChangeSummaryMessage(
            "\n🪬 Summary: 1 file  +1 -0\n  modified Sources/App.swift  +1 -0\n"
        )

        let snapshot = await renderer.snapshot()
        let output = await renderer.capturedPlainText()
        let overviewRange = try #require(output.range(of: "Task graph"))
        let summaryRange = try #require(output.range(of: "🪬 Summary:"))
        #expect(deferred == .deferred)
        #expect(!snapshot.deferredTaskGraphOverviewRender)
        #expect(overviewRange.lowerBound < summaryRange.lowerBound)
        #expect(!output[summaryRange.upperBound...].contains("Task graph"))
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
        #expect(!beforeFinish.renderedText().contains("Task graph"))

        await renderer.finishStreamingOutput()

        let rendered = await renderer.snapshot()
        let combined = await renderer.capturedText()
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
        let combined = await renderer.capturedText()
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

        let combined = await renderer.capturedText()
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

        let combined = await renderer.capturedText()
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

        let combined = await renderer.capturedText()
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

        let output = await renderer.capturedText(on: .standardOutput)
        #expect(output.contains("Answer\n## Task graph"))
    }

    @Test
    func stderrOverviewCannotSuppressTheNonTerminalAssistantNewline() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeAssistantContent("Answer")
        _ = await renderer.renderRememberedSubAgentOverview(
            signature: "agents:1",
            text: "Agents updated.\n\n",
        )
        await renderer.finishStreamingOutput()
        await renderer.writeOutput("\n")

        let output = await renderer.capturedText(on: .standardOutput)
        #expect(output == "💬 Answer\n")
    }
}
