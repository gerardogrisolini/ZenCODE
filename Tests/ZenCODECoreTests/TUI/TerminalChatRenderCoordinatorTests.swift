//
//  TerminalChatRenderCoordinatorTests.swift
//  ZenCODETests
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite("Terminal chat async render coordinator")
struct TerminalChatRenderCoordinatorTests {

    @Test
    func agentWaitLifecycleIsAppendOnlyInCoordinator() async {
        let toolCall = presentedToolCall(
            id: "wait-live-overlay",
            name: "agent.wait",
            argumentsObject: ["name": "worker"],
            argumentsJSON: #"{"name":"worker"}"#
        )
        let renderer = makeRenderer(standardErrorIsTerminal: true)

        await renderer.writeToolCallStarted(toolCall, maximumInPlaceRows: 8)
        #expect(await renderer.capturedWriteEvents().isEmpty)

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Done", summary: "Done"),
            maximumInPlaceRows: 8
        )
        let completion = await renderer.capturedWriteEvents().map(\.text).joined()
        #expect(completion.contains("agent.wait"))
        #expect(!completion.contains("\u{1B}[1A"))
        #expect(!completion.contains("\u{1B}[2A"))
    }

    @Test
    func nonTTYFallbackAppendsPendingRowsForAnyTool() async {
        let toolCall = presentedToolCall(
            id: "fallback-search",
            name: "search.grep",
            argumentsObject: ["pattern": "needle"],
            argumentsJSON: #"{"pattern":"needle"}"#
        )
        let renderer = makeRenderer(standardErrorIsTerminal: false)

        await renderer.writeToolCallStarted(toolCall)
        #expect(await renderer.capturedWriteEvents().isEmpty)
        await renderer.writeToolCallStartedFallback(toolCall)

        let fallback = TerminalANSIText.stripANSI(
            await renderer.capturedWriteEvents().map(\.text).joined()
        )
        #expect(fallback.contains("search.grep"))
        #expect(fallback.contains("needle"))
        #expect(fallback.contains("⏳"))
    }

    @Test
    func standardPreservesCompactANSICompletionBeforeAppendingSourceChanges() async {
        let toolCall = presentedToolCall(
            id: "standard-ansi-edit",
            name: "local.editFile",
            argumentsObject: [
                "path": "/tmp/Example.swift",
                "old": "let oldValue = 1",
                "new": "let newValue = 2"
            ],
            argumentsJSON: "{}"
        )
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
        let completion = await renderer.capturedWriteEvents()
            .dropFirst(startEventCount)
            .map(\.text)
            .joined()
        let compactCompletion = TerminalChat.compactToolTerminalText(
            TerminalChat.compactToolLines(
                for: toolCall,
                statusIcon: "✅",
                statusDetail: "0ms"
            ),
            lineInset: "",
            newline: false
        )

        #expect(completion.contains(compactCompletion))
        #expect(completion.contains("oldValue"))
        #expect(completion.contains("newValue"))
    }

    @Test
    func standardKeepsPendingCompactAndEmitsAllSourceChangesOnCompletion() async {
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
        let startedText = TerminalANSIText.stripANSI(startedEvents.map(\.text).joined())
        #expect(!startedText.contains("old0"))
        #expect(!startedText.contains("new0"))

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Updated", summary: "Updated"),
            maximumInPlaceRows: 6
        )
        let completionText = TerminalANSIText.stripANSI(
            (await renderer.capturedWriteEvents())
                .dropFirst(startedEvents.count)
                .map(\.text)
                .joined()
        )

        #expect(completionText.contains("old149"))
        #expect(completionText.contains("new149"))
        #expect(!completionText.contains("truncated"))
    }

    @Test
    func delegatedToolEventsUseCanonicalRowsInsideTheIndentedOverview() async {
        let toolCall = presentedToolCall(
            id: "shared-render-edit",
            name: "local.editFile",
            argumentsObject: [
                "path": "/tmp/Example.swift",
                "old": "let oldValue = 1",
                "new": "let newValue = 2"
            ],
            argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(output: "Updated", summary: "Updated")
        let delegatedClock = StreamingClock()
        let delegatedRenderer = makeRenderer(
            standardErrorIsTerminal: true,
            toolNow: { delegatedClock.now },
            columnWidthProvider: { 120 }
        )

        await delegatedRenderer.recordSubAgentToolEvent(
            DirectSubAgentToolEvent(
                agentID: "agent-worker",
                agentName: "worker",
                toolCall: toolCall,
                lifecycle: .started
            )
        )
        delegatedClock.advance(by: .milliseconds(1_200))
        await delegatedRenderer.recordSubAgentToolEvent(
            DirectSubAgentToolEvent(
                agentID: "agent-worker",
                agentName: "worker",
                toolCall: toolCall,
                lifecycle: .completed(result)
            )
        )
        let presentationSnapshot = await delegatedRenderer
            .subAgentToolPresentationSnapshot()
        let agentSnapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-worker",
            name: "worker",
            role: "",
            status: .running,
            pending: true,
            currentToolName: toolCall.name,
            currentToolTarget: "/tmp/Example.swift",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let rows = TerminalChat.renderSubAgentOverviewRowsForTesting(
            [agentSnapshot],
            rowBudget: nil,
            toolPresentationsByAgentID: presentationSnapshot.presentationsByAgentID
        ).map { TerminalANSIText.stripANSI($0) }
        let toolRows = rows.filter {
            $0.contains(toolCall.name)
                || $0.contains("/tmp/Example.swift")
                || $0.contains("oldValue")
                || $0.contains("newValue")
        }

        // Recording delegated tools updates only the live overview model. It
        // must never append a coordinator-looking block to the transcript.
        #expect(await delegatedRenderer.capturedWriteEvents().isEmpty)
        #expect(toolRows.count >= 3)
        #expect(toolRows.allSatisfy { $0.hasPrefix("   ") })
        #expect(rows.contains { $0.contains("✅ 1.20s") })
        #expect(rows.contains { $0.contains("oldValue") })
        #expect(rows.contains { $0.contains("newValue") })
    }

    @Test
    func delegatedToolTimingScopesMatchingProviderCallIDsByAgent() async {
        let toolCall = presentedToolCall(
            id: "provider-reused-call-id",
            name: "search.grep",
            argumentsObject: ["pattern": "needle"],
            argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(output: "match", summary: "1 match")
        let clock = StreamingClock()
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            toolNow: { clock.now },
            columnWidthProvider: { 120 }
        )
        let firstStarted = DirectSubAgentToolEvent(
            agentID: "agent-first",
            agentName: "first",
            toolCall: toolCall,
            lifecycle: .started
        )
        let secondStarted = DirectSubAgentToolEvent(
            agentID: "agent-second",
            agentName: "second",
            toolCall: toolCall,
            lifecycle: .started
        )

        await renderer.recordSubAgentToolEvent(firstStarted)
        clock.advance(by: .milliseconds(100))
        await renderer.recordSubAgentToolEvent(secondStarted)
        clock.advance(by: .milliseconds(200))
        await renderer.recordSubAgentToolEvent(
            DirectSubAgentToolEvent(
                agentID: "agent-second",
                agentName: "second",
                toolCall: toolCall,
                lifecycle: .completed(result)
            )
        )
        clock.advance(by: .milliseconds(300))
        await renderer.recordSubAgentToolEvent(
            DirectSubAgentToolEvent(
                agentID: "agent-first",
                agentName: "first",
                toolCall: toolCall,
                lifecycle: .completed(result)
            )
        )

        let presentations = await renderer
            .subAgentToolPresentationSnapshot()
            .presentationsByAgentID
        if case let .completed(_, secondDetail, _)? = presentations["agent-second"]?.lifecycle {
            #expect(secondDetail == "200ms")
        } else {
            Issue.record("Second delegated tool did not complete")
        }
        if case let .completed(_, firstDetail, _)? = presentations["agent-first"]?.lifecycle {
            #expect(firstDetail == "600ms")
        } else {
            Issue.record("First delegated tool did not complete")
        }
        #expect(await renderer.capturedWriteEvents().isEmpty)
    }

    @Test
    func delegatedAgentKeepsOnlyItsLatestToolPresentation() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let first = presentedToolCall(
            id: "first-edit",
            name: "local.editFile",
            argumentsObject: [
                "path": "/tmp/Old.swift",
                "old": "let staleValue = 1",
                "new": "let staleValue = 2"
            ],
            argumentsJSON: "{}"
        )
        let second = presentedToolCall(
            id: "second-search",
            name: "search.grep",
            argumentsObject: ["pattern": "currentNeedle"],
            argumentsJSON: "{}"
        )

        for event in [
            DirectSubAgentToolEvent(
                agentID: "agent-worker",
                agentName: "worker",
                toolCall: first,
                lifecycle: .started
            ),
            DirectSubAgentToolEvent(
                agentID: "agent-worker",
                agentName: "worker",
                toolCall: first,
                lifecycle: .completed(
                    DirectAgentToolResult(output: "Updated", summary: "Updated")
                )
            ),
            DirectSubAgentToolEvent(
                agentID: "agent-worker",
                agentName: "worker",
                toolCall: second,
                lifecycle: .started
            )
        ] {
            await renderer.recordSubAgentToolEvent(event)
        }

        let presentations = await renderer
            .subAgentToolPresentationSnapshot()
            .presentationsByAgentID
        let current = presentations["agent-worker"]
        let snapshot = DirectSubAgentRuntime.AgentSnapshot(
            id: "agent-worker",
            name: "worker",
            role: "",
            status: .running,
            pending: true,
            currentToolName: second.name,
            currentToolTarget: "currentNeedle",
            latestOutput: nil,
            latestError: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        let rendered = TerminalChat.renderSubAgentOverviewRowsForTesting(
            [snapshot],
            rowBudget: nil,
            toolPresentationsByAgentID: presentations
        )
        .map { TerminalANSIText.stripANSI($0) }
        .joined(separator: "\n")

        #expect(presentations.count == 1)
        #expect(current?.toolCall.id == second.id)
        #expect(rendered.contains("search.grep"))
        #expect(rendered.contains("currentNeedle"))
        #expect(!rendered.contains("staleValue"))
        #expect(!rendered.contains("Old.swift"))
    }

    /// Characterization: a standard completion is the byte-identical compact
    /// block followed only by the source appendix. Anything preceding the shared
    /// compact bytes must be pure cursor control, never printable text.
    @Test
    func standardCompletionIsCompactBytesFollowedOnlyBySourceAppendix() async throws {
        let toolCall = presentedToolCall(
            id: "standard-characterization-edit",
            name: "local.editFile",
            argumentsObject: [
                "path": "/tmp/Example.swift",
                "old": "let oldValue = 1",
                "new": "let newValue = 2"
            ],
            argumentsJSON: "{}"
        )
        let clock = StreamingClock()
        let renderer = makeRenderer(standardErrorIsTerminal: true, toolNow: { clock.now })
        await renderer.writeToolCallStarted(toolCall)
        let startEventCount = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Updated", summary: "Updated")
        )
        let completion = await renderer.capturedWriteEvents()
            .dropFirst(startEventCount)
            .map(\.text)
            .joined()
        let compactCompletion = TerminalChat.compactToolTerminalText(
            TerminalChat.compactToolLines(
                for: toolCall,
                statusIcon: "✅",
                statusDetail: "0ms"
            ),
            lineInset: "",
            newline: false
        )

        let compactRange = try #require(completion.range(of: compactCompletion))
        let controlPrefix = String(completion[completion.startIndex..<compactRange.lowerBound])
        let appendix = String(completion[compactRange.upperBound...])

        #expect(TerminalANSIText.stripANSI(controlPrefix).allSatisfy { $0 == "\r" || $0 == "\n" })
        #expect(TerminalANSIText.stripANSI(appendix).contains("oldValue"))
        #expect(TerminalANSIText.stripANSI(appendix).contains("newValue"))
        // The appendix never repeats the compact prefix content.
        #expect(!TerminalANSIText.stripANSI(appendix).contains("local.editFile"))
        // Block terminator: the appendix newline plus the blank separator row.
        #expect(appendix.hasSuffix("\n\n"))
    }

    /// Characterization: without source rows the standard block degenerates to
    /// exactly the compact block, byte for byte, with no appendix.
    @Test
    func standardCompletionWithoutSourceRowsIsExactlyTheCompactBlock() async throws {
        let toolCall = presentedToolCall(
            id: "standard-characterization-read",
            name: "local.readFile",
            argumentsObject: ["path": "/tmp/Example.swift"],
            argumentsJSON: #"{"path":"/tmp/Example.swift"}"#
        )
        let clock = StreamingClock()
        let renderer = makeRenderer(standardErrorIsTerminal: true, toolNow: { clock.now })
        await renderer.writeToolCallStarted(toolCall)
        let startEventCount = await renderer.capturedWriteEvents().count
        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "let value = 1", summary: "Read")
        )
        let completion = await renderer.capturedWriteEvents()
            .dropFirst(startEventCount)
            .map(\.text)
            .joined()
        let compactCompletion = TerminalChat.compactToolTerminalText(
            TerminalChat.compactToolLines(
                for: toolCall,
                statusIcon: "✅",
                statusDetail: "0ms"
            ),
            lineInset: "",
            newline: true
        )

        #expect(completion.hasSuffix(compactCompletion))
        let controlPrefix = String(completion.dropLast(compactCompletion.count))
        #expect(TerminalANSIText.stripANSI(controlPrefix).allSatisfy { $0 == "\r" || $0 == "\n" })
        #expect(!TerminalANSIText.stripANSI(completion).contains("let value = 1"))
    }

    @Test
    func standardShowsCompactStatusAndMutationSource() async {
        let toolCall = presentedToolCall(
            id: "standard-edit",
            name: "local.editFile",
            argumentsObject: [
                "path": "/tmp/Example.swift",
                "old": "let oldValue = 1",
                "new": "let newValue = 2"
            ],
            argumentsJSON: "{}"
        )
        let standard = makeRenderer(standardErrorIsTerminal: true)
        await standard.writeToolCallStarted(toolCall)
        await standard.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Updated", summary: "Updated")
        )
        let standardText = TerminalANSIText.stripANSI(
            await standard.capturedWriteEvents().map(\.text).joined()
        )
        #expect(standardText.contains("oldValue"))
        #expect(standardText.contains("newValue"))
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
        let text = TerminalANSIText.stripANSI(
            await renderer.capturedWriteEvents().map(\.text).joined()
        )
        #expect(text.contains("local.readFile"))
        #expect(text.contains("/tmp/Secret.swift"))
        #expect(!text.contains("let secret = true"))
        #expect(!text.contains("status:"))
        #expect(!text.contains("⏳"))
        #expect(text.contains("✅"))
        let snapshot = await renderer.snapshot()
        #expect(snapshot.activeToolCallID == nil)
        #expect(snapshot.activeToolCallID == nil)

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
        let toolCall = presentedToolCall(
            id: "timed-local-exec",
            name: "local.exec",
            argumentsObject: ["command": "a-very-long-command-that-needs-truncation"],
            argumentsJSON: #"{"command":"a-very-long-command-that-needs-truncation"}"#
        )

        await renderer.writeToolCallStarted(toolCall)
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

        #expect(!containsCursorUpSequence(completionText))
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
        let missingStartText = await renderer.capturedWriteEvents()
            .map(\.text)
            .joined()
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
    func taskGraphOverviewRendersAlongsidePendingToolAndCompletionAppendsAfterward() async {
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
        let rendered = await renderer.renderTaskGraphOverview(
            signature: "graph:after-update",
            markdown: "Tasks\n"
        )
        #expect(rendered == .rendered)

        await renderer.writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(output: "Updated", summary: "Updated")
        )
        let events = await renderer.capturedWriteEvents()
        let overviewIndex = events.firstIndex { $0.text.contains("Tasks") }
        let completionIndex = events.firstIndex { $0.text.contains("✅") }
        #expect(overviewIndex != nil)
        #expect(completionIndex != nil)
        if let overviewIndex, let completionIndex {
            #expect(overviewIndex < completionIndex)
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
        #expect(output == "💬 Answer\n")
    }

    @Test
    func terminalOnlySubAgentOverviewDoesNotEnterMirrorQueue() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let recorder = OverviewMirrorRecorder()
        await renderer.setOverviewMirroringHandler { notification, _ in
            if case .taskGraph = notification {
                await recorder.record(.taskGraph)
            }
        }

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:terminal-only",
            text: "Agents updated.\n",
            force: false,
            rememberSignature: true
        )
        await renderer.waitForOverviewMirrorsToDrain()

        #expect(await recorder.recordedKinds().isEmpty)
    }

    @Test
    func completedSubAgentResponsesMirrorOncePerTokenAndInSnapshotOrder() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)
        let recorder = ResponseMirrorRecorder()
        await renderer.setOverviewMirroringHandler { notification, _ in
            if case let .subAgentResponse(response) = notification {
                await recorder.record(response)
            }
        }
        let first = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "worker\u{1F}1",
            heading: "   ✅ Response from first:\n",
            markdown: "Same answer"
        )
        let second = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "reviewer\u{1F}1",
            heading: "   ✅ Response from second:\n",
            markdown: "Second answer"
        )

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:one",
            text: "thinking: hidden\ntool: hidden\nmetadata: hidden\n",
            responses: [first, second],
            force: false,
            rememberSignature: true
        )
        // A status/closure refresh with the same completion revisions must not
        // publish either response again.
        _ = await renderer.renderSubAgentOverview(
            signature: "agents:refresh",
            text: "different overview only",
            responses: [first, second],
            force: false,
            rememberSignature: true
        )
        // A new revision remains a new response even when its Markdown is the
        // same as an earlier completion.
        let revisedFirst = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "worker\u{1F}2",
            heading: first.heading,
            markdown: first.markdown
        )
        _ = await renderer.renderSubAgentOverview(
            signature: "agents:revision-two",
            text: "overview only",
            responses: [revisedFirst],
            force: false,
            rememberSignature: true
        )
        await renderer.waitForOverviewMirrorsToDrain()

        #expect(await recorder.tokens() == ["worker\u{1F}1", "reviewer\u{1F}1", "worker\u{1F}2"])
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
    func completedSubAgentResponseImmediatelyFollowsMetadataAndIsIndented() async {
        let renderer = makeRenderer(standardErrorIsTerminal: false)
        let response = TerminalChatRenderCoordinator.SubAgentMarkdownResponse(
            token: "agent-1:completion-1",
            heading: "   ✅ Response from reviewer:\n",
            markdown: "First paragraph.\n\n- first\n- second\nA follow-up line."
        )

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:completed",
            text: "Agents completed.\n",
            responses: [response],
            force: false,
            rememberSignature: true
        )

        let stderr = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()

        #expect(
            stderr == "Agents completed.\n   ✅ Response from reviewer:\n   First paragraph.\n   \n   - first\n   - second\n   A follow-up line.\n\n"
        )
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
    func subAgentOverviewWithoutAnchorIsAlwaysAppended() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:unanchored:first",
            text: "\n👥 Sub-Agents:\n   first\n",
            force: false,
            rememberSignature: true
        )
        #expect(await renderer.snapshot().activeSubAgentOverviewRowCount == 0)
        let eventsBeforeRefresh = await renderer.capturedWriteEvents().count

        _ = await renderer.renderSubAgentOverview(
            signature: "agents:unanchored:second",
            text: "\n👥 Sub-Agents:\n   second\n",
            force: false,
            rememberSignature: true
        )
        let refreshText = (await renderer.capturedWriteEvents())
            .dropFirst(eventsBeforeRefresh)
            .map(\.text)
            .joined()

        #expect(!containsCursorUpSequence(refreshText))
        #expect(TerminalANSIText.stripANSI(refreshText).contains("second"))
    }

    /// Characterizes the cross-file seam between the streaming write buffer
    /// (+Streaming) and deferred overview publication (+Overviews): while a
    /// thought stream is active the overview defers, and finishing the stream
    /// must flush the buffered bytes to the terminal before the deferred
    /// section renders, preserving transcript order.
    @Test
    func deferredOverviewRendersAfterBufferedStreamingFlushesInOrder() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 80 }
        )

        // No trailing-edge timer is armed (streamingFlushDelay is nil in this
        // renderer), so these bytes stay pending inside the coordinator.
        await renderer.writeThought("still buffered reasoning\n")
        let bufferedEventCount = await renderer.capturedWriteEvents().count
        #expect(bufferedEventCount == 0)

        let result = await renderer.renderSubAgentOverview(
            signature: "agents:during-stream",
            text: "\n👥 Sub-Agents:\n   1 total\n   running\n",
            force: false,
            rememberSignature: true,
            overviewBatchID: "wave-with-stream"
        )
        #expect(result == .deferred)
        #expect(await renderer.capturedWriteEvents().count == 0)

        await renderer.finishStreamingOutput()

        let stderr = TerminalANSIText.stripANSI(
            (await renderer.capturedWriteEvents())
                .filter { $0.channel == .standardError }
                .map(\.text)
                .joined()
        )
        let bufferedRange = stderr.range(of: "still buffered reasoning")
        let overviewRange = stderr.range(of: "Sub-Agents")
        #expect(bufferedRange != nil)
        #expect(overviewRange != nil)
        #expect(bufferedRange!.lowerBound < overviewRange!.lowerBound)
        // The deferred section rendered exactly once, after the flush.
        #expect(stderr.components(separatedBy: "Sub-Agents").count - 1 == 1)
    }

    /// Characterizes the mirroring epoch seam: the queue lives as stored
    /// coordinator state while `advanceMirrorEpoch` mutates it from
    /// +Overviews. Each advanced epoch must stamp subsequent notifications so
    /// a turn boundary fences stale deliveries.
    @Test
    func mirrorEpochStampsNotificationsAtEachTurnBoundary() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let epochs = EpochRecorder()
        await renderer.setOverviewMirroringHandler { _, epoch in
            await epochs.append(epoch)
        }

        _ = await renderer.renderTaskGraphOverview(
            signature: "tasks:1",
            markdown: "# Tasks v1\n",
            force: true,
            rememberSignature: true
        )
        let firstEpoch = await renderer.advanceMirrorEpoch()
        #expect(firstEpoch == 1)
        _ = await renderer.renderTaskGraphOverview(
            signature: "tasks:2",
            markdown: "# Tasks v2\n",
            force: true,
            rememberSignature: true
        )
        await renderer.waitForOverviewMirrorsToDrain()

        let recorded = await epochs.values()
        #expect(recorded == [0, 1])
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

    /// Streamed reasoning replaces the section in place even when the new
    /// paragraph is taller or shorter than the one on screen: the refresh
    /// erases exactly the rows the previous paragraph owned, and only one
    /// paragraph stays visible in the live rewrite slot.
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
    func terminalThinkingShowsAllLinesAcrossDeltas() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true
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
        #expect(stderr.contains("third"))
        #expect(stderr.contains("fourth"))
        #expect(!stderr.contains("thinking lines omitted"))
    }

    @Test
    func terminalThinkingStaysContiguousAcrossDeltasAtNarrowWidth() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true,
            columnWidthProvider: { 8 }
        )

        // The coordinator no longer hard-wraps thinking; a narrow width must not
        // inject synthetic newlines. Send the thought across multiple deltas so
        // the streaming state is exercised, then assert the captured text is the
        // contiguous source content (plus only the coordinator's framing
        // newlines), not split by a computed column boundary.
        await renderer.writeThought("abcdefghij")
        await renderer.writeThought("klmnopqrst")
        await renderer.finishThoughtOutput()

        let stderr = TerminalANSIText.stripANSI(
            await renderer.capturedWriteEvents()
                .filter { $0.channel == .standardError }
                .map(\.text)
                .joined()
        )

        // The whole thought survives unbroken across the narrow width.
        #expect(stderr.contains("abcdefghijklmnopqrst"))
        #expect(!stderr.contains("abcdefg\nhijklmn\n"))
        #expect(!stderr.contains("thinking lines omitted"))
    }

    @Test
    func terminalThinkingCodeBlockDoesNotAddWidthBasedContinuationMarkers() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let longLine = "let explanation = \"a deliberately long value that must remain one logical line\""

        await renderer.writeThought("```swift\n\(longLine)\n```\n")
        await renderer.finishThoughtOutput()

        let stderr = TerminalANSIText.stripANSI(
            await renderer.capturedWriteEvents()
                .filter { $0.channel == .standardError }
                .map(\.text)
                .joined()
        )

        #expect(stderr.contains(longLine))
        #expect(!stderr.contains("↳"))
    }

    @Test
    func terminalThinkingShowsUnterminatedTail() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true
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
        #expect(stderr.contains("hidden tail without newline"))
        #expect(!stderr.contains("thinking lines omitted"))
    }

    @Test
    func nonTerminalThinkingPassesThroughUnchanged() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: false
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
    func terminalThinkingShowsAllContentAcrossStreams() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: true
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
        #expect(stderr.contains("first hidden"))
        #expect(stderr.contains("second hidden"))
        #expect(!stderr.contains("thinking lines omitted"))
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
        #expect(stdout == "💬 Answer*")
    }

    @Test
    func assistantBubblePrefixesMarkdownFirstEmittedAtFinish() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            standardOutputIsTerminal: true
        )

        await renderer.writeAssistantContent("**Answer**")
        await renderer.finishStreamingOutput()

        let stdout = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardOutput }
            .map(\.text)
            .joined()
        #expect(TerminalANSIText.stripANSI(stdout) == "💬 Answer\n")
    }

    @Test
    func assistantContentWithNarrowWidthStaysContiguousAfterBubblePrefix() async {
        let renderer = makeRenderer(
            standardErrorIsTerminal: false,
            standardOutputIsTerminal: true,
            columnWidthProvider: { 10 }
        )

        // The `💬 ` prefix shares the first output row. A narrow width must not
        // make the formatter inject synthetic line breaks before or after the
        // terminal's own auto-wrap: only the source newline survives.
        await renderer.writeAssistantContent("one two three four five six seven\n")
        await renderer.finishStreamingOutput()

        let stdout = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardOutput }
            .map(\.text)
            .joined()
        let visible = TerminalANSIText.stripANSI(stdout)

        // The bubble prefix is present and the content is contiguous.
        #expect(visible.hasPrefix("💬 "))
        #expect(visible.contains("one two three four five six seven"))
        // No synthetic line break between the prefix and the content.
        let afterPrefix = String(visible.dropFirst("💬 ".count))
        #expect(afterPrefix.hasSuffix("\n"))
        #expect(!String(afterPrefix.dropLast()).contains("\n"))
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
        #expect(afterThought.map(\.text).joined().contains("🤔"))

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

        #expect(combined.components(separatedBy: "🤔 thinking…").count == 2)
        #expect(combined.contains("Planning safely"))
        #expect(combined.contains("Answer"))
        #expect(!combined.contains("\n\n\n"))
        if let thought = combined.firstRange(of: "Planning safely")?.lowerBound,
           let answer = combined.firstRange(of: "Answer")?.lowerBound {
            #expect(thought < answer)
        }
    }

    @Test
    func newerSubAgentOverviewPublicationFencesAnOlderCallback() async {
        let renderer = makeRenderer(standardErrorIsTerminal: true)
        let staleRevision = await renderer.beginOverviewPublication(.subAgents)
        let currentRevision = await renderer.beginOverviewPublication(.subAgents)

        let current = await renderer.renderSubAgentOverview(
            signature: "agents:current",
            text: "Current wave\n",
            revision: currentRevision,
            force: false,
            rememberSignature: true,
            overviewBatchID: "current-wave"
        )
        let eventCountBeforeStaleCallback = await renderer.capturedWriteEvents().count
        let stale = await renderer.renderSubAgentOverview(
            signature: "agents:stale",
            text: "Stale wave\n",
            revision: staleRevision,
            force: false,
            rememberSignature: true,
            overviewBatchID: "stale-wave"
        )
        let staleText = (await renderer.capturedWriteEvents())
            .dropFirst(eventCountBeforeStaleCallback)
            .map(\.text)
            .joined()

        #expect(current == .rendered)
        #expect(stale == .unchanged)
        #expect(staleText.isEmpty)
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
        #expect(TerminalANSIText.stripANSI(stdout) == "💬 Answer\n")
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
        #expect(TerminalANSIText.stripANSI(stdout) == "💬 Answer")
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
        #expect(stderr.contains("🤔 thinking…"))
        #expect(stderr.contains("*"))
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

        let completionText = await renderer.capturedWriteEvents()
            .dropFirst(eventCountBeforeCompletion)
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        let visibleRows = TerminalANSIText.stripANSI(completionText)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let diffRows = visibleRows.filter {
            $0.contains("let injected = 1") && $0.contains("let replacement = 2")
        }

        #expect(diffRows.count == 1)
        #expect(diffRows.allSatisfy { $0.contains("let replacement = 2") })
        #expect(visibleRows.allSatisfy { TerminalChat.displayWidth($0) <= 120 })
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

        let text = await renderer.capturedWriteEvents()
            .filter { $0.channel == .standardError }
            .map(\.text)
            .joined()
        let visibleRows = TerminalANSIText.stripANSI(text)
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map(String.init)

        #expect(!text.contains("\u{1B}[2J"))
        #expect(!visibleRows.contains { $0.hasPrefix("target: ") })
        #expect(visibleRows.filter { !$0.hasPrefix("  ") }.allSatisfy { !$0.contains("\u{1B}") })
        #expect(visibleRows.allSatisfy { TerminalChat.displayWidth($0) <= 100 })
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
            freshColumnWidthProvider: freshColumnWidthProvider
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

private actor OverviewMirrorRecorder {
    private var kinds: [TerminalChatRenderCoordinator.OverviewKind] = []

    func record(_ kind: TerminalChatRenderCoordinator.OverviewKind) {
        kinds.append(kind)
    }

    func recordedKinds() -> [TerminalChatRenderCoordinator.OverviewKind] {
        kinds
    }
}

private actor ResponseMirrorRecorder {
    private var responses: [TerminalChatRenderCoordinator.SubAgentMarkdownResponse] = []

    func record(_ response: TerminalChatRenderCoordinator.SubAgentMarkdownResponse) {
        responses.append(response)
    }

    func tokens() -> [String] {
        responses.map(\.token)
    }
}

/// Records the epoch carried by each delivered mirror notification, so tests
/// can characterize the turn-boundary fencing contract of the mirror queue.
private actor EpochRecorder {
    private var recorded: [Int] = []

    func append(_ epoch: Int) {
        recorded.append(epoch)
    }

    func values() -> [Int] {
        recorded
    }
}
