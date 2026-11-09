import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct TerminalSubAgentTranscriptRenderingTests {
    // MARK: - Fixtures

    private func readFileCall(id: String, path: String = "/tmp/Example.swift") -> DirectAgentToolCall {
        presentedToolCall(
            id: id,
            name: "local.readFile",
            argumentsObject: ["path": path],
            argumentsJSON: #"{"path":"\#(path)"}"#
        )
    }

    private func agentMessageCall(id: String) -> DirectAgentToolCall {
        presentedToolCall(
            id: id,
            name: "agent.message",
            argumentsObject: [
                "name": "worker",
                "message": "please review the diff"
            ],
            argumentsJSON: "{}"
        )
    }

    private func plainRows(_ kinds: [ChatTurnEntry.Kind], width: Int = 80) -> [String] {
        TerminalChat.renderSubAgentTranscriptRows(kinds, width: width, standardErrorIsTerminal: false)
    }

    private func occurrences(of needle: String, in rows: [String]) -> Int {
        rows.reduce(0) { count, row in
            count + TerminalANSIText.stripANSI(row).components(separatedBy: needle).count - 1
        }
    }

    private func expectRowsFit(_ rows: [String], width: Int) {
        for row in rows {
            #expect(TerminalANSIText.visibleWidth(row) <= width, "\(row.debugDescription)")
        }
    }

    private func snapshot(
        status: DirectSubAgentRuntime.Status = .running,
        pending: Bool = true,
        currentActivity: String? = nil,
        currentActivityKind: DirectSubAgentRuntime.ActivityKind? = nil,
        currentThought: String? = nil,
        currentToolName: String? = nil,
        currentToolIsRunning: Bool = false,
        latestOutput: String? = nil,
        latestError: String? = nil
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: "agent_transcript_worker",
            taskID: "plan-graph-task-2",
            taskAttemptOrdinal: 3,
            name: "transcript-renderer",
            role: "Renders the transcript of a delegated sub-agent",
            profileName: "Developer",
            status: status,
            pending: pending,
            configuredModelID: "openai:gpt-test",
            currentActivity: currentActivity,
            currentActivityKind: currentActivityKind,
            currentThought: currentThought,
            currentToolName: currentToolName,
            currentToolIsRunning: currentToolIsRunning,
            latestMetrics: DirectAgentGenerationMetrics(
                promptTokenCount: 12_345,
                cachedPromptTokenCount: 9_000,
                completionTokenCount: 678
            ),
            latestOutput: latestOutput,
            latestError: latestError,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    // MARK: - Conversation kinds

    @Test
    func userPromptRendersThePromptBandPrefixes() {
        let rows = plainRows([
            .userPrompt(text: "Fix the build\nthen run the tests", attachments: [], origin: .unknown)
        ])

        #expect(rows == ["> Fix the build", "  then run the tests"])
    }

    @Test
    func thoughtRendersTheThinkingTitleAndItsParagraph() {
        let rows = plainRows([.thought("Weighing the two options.")])

        #expect(rows == [TerminalChat.thinkingPlaceholder, "Weighing the two options."])
    }

    @Test
    func assistantTextRendersItsMarkdownSource() {
        let rows = plainRows([.assistantText("Done: all tests are green.\nNext: commit.")])

        #expect(rows == ["Done: all tests are green.", "Next: commit."])
    }

    @Test
    func startedToolCallRendersTheCanonicalCompactRowsAsPending() {
        let call = readFileCall(id: "read-1")
        let expected = TerminalChat.toolPresentationRows(
            for: call,
            result: nil,
            statusDetail: nil,
            contentInsetWidth: 0,
            columnWidth: 81,
            includesSourceChanges: false
        ).compactRows.map(\.plainText)

        let rows = plainRows([.toolCallStarted(call)])

        #expect(rows == expected)
        #expect(rows.contains { $0.contains("local.readFile") })
        #expect(rows.contains { $0.contains("⏳") })
    }

    @Test
    func completedToolCallIsRenderedOnceWhereItStartedWithItsResult() throws {
        let call = readFileCall(id: "read-1")
        let rows = plainRows([
            .toolCallStarted(call),
            .assistantText("Reading the file."),
            .toolCallCompleted(call, result: DirectAgentToolResult(output: "contents", summary: "contents"))
        ])

        #expect(occurrences(of: "local.readFile", in: rows) == 1)
        #expect(occurrences(of: "✅", in: rows) == 1)
        #expect(occurrences(of: "⏳", in: rows) == 0)
        let toolRow = try #require(rows.firstIndex { $0.contains("local.readFile") })
        let textRow = try #require(rows.firstIndex { $0.contains("Reading the file.") })
        #expect(toolRow < textRow)
    }

    @Test
    func parallelToolCallsKeepTheirOrderAndRenderOnceEach() {
        let first = readFileCall(id: "read-1", path: "/tmp/First.swift")
        let second = readFileCall(id: "read-2", path: "/tmp/Second.swift")
        let result = DirectAgentToolResult(output: "ok", summary: "ok")
        let rows = plainRows([
            .toolCallStarted(first),
            .toolCallStarted(second),
            .toolCallCompleted(first, result: result),
            .toolCallCompleted(second, result: result)
        ])

        #expect(occurrences(of: "First.swift", in: rows) == 1)
        #expect(occurrences(of: "Second.swift", in: rows) == 1)
        #expect(occurrences(of: "✅", in: rows) == 2)
        #expect(occurrences(of: "⏳", in: rows) == 0)
        let firstRow = rows.firstIndex { $0.contains("First.swift") } ?? .max
        let secondRow = rows.firstIndex { $0.contains("Second.swift") } ?? .min
        #expect(firstRow < secondRow)
    }

    /// The plain rows the main chat draws for `call` completed with `result`
    /// after `elapsed`, at the default width of ``plainRows(_:width:)``.
    private func mainChatCompletedRows(
        _ call: DirectAgentToolCall,
        result: DirectAgentToolResult,
        elapsed: Duration?
    ) -> [String] {
        let presentation = TerminalChat.toolPresentationRows(
            for: call,
            result: result,
            statusDetail: TerminalChat.compactToolCompletionDetail(for: call, result: result, elapsed: elapsed),
            contentInsetWidth: 0,
            columnWidth: 81,
            includesSourceChanges: false
        )
        return presentation.compactRows.map(\.plainText) + presentation.detailRows.map(\.plainText)
    }

    @Test
    func completedToolCallShowsItsMeasuredDurationAsTheMainChatDoes() {
        let call = readFileCall(id: "read-1")
        let result = DirectAgentToolResult(output: "contents", summary: "contents")
        let elapsed = Duration.milliseconds(1_250)

        let rows = TerminalChat.renderSubAgentTranscriptRows(
            [.toolCallStarted(call), .toolCallCompleted(call, result: result)],
            toolDurations: ["read-1": elapsed],
            width: 80,
            standardErrorIsTerminal: false
        )

        #expect(rows == mainChatCompletedRows(call, result: result, elapsed: elapsed))
        #expect(occurrences(of: ToolCallPresentation.elapsedTimeText(elapsed), in: rows) == 1)
        #expect(occurrences(of: "✅", in: rows) == 1)
    }

    @Test
    func failedProcessShowsItsDurationBeforeItsExitCode() {
        let call = presentedToolCall(
            id: "exec-1",
            name: "local.exec",
            argumentsObject: ["command": "swift test"],
            argumentsJSON: #"{"command":"swift test"}"#
        )
        let elapsed = Duration.seconds(3)
        let rows = TerminalChat.renderSubAgentTranscriptRows(
            [
                .toolCallStarted(call),
                .toolCallCompleted(call, result: DirectAgentToolResult(
                    output: "exit_code: 2\nstderr: failure",
                    summary: "exit_code: 2"
                ))
            ],
            toolDurations: ["exec-1": elapsed],
            width: 80,
            standardErrorIsTerminal: false
        )

        #expect(occurrences(of: "\(ToolCallPresentation.elapsedTimeText(elapsed)) exit 2", in: rows) == 1)
    }

    @Test
    func suppressedToolsHaveNoRows() {
        let hidden = agentMessageCall(id: "message-1")
        let rows = plainRows([
            .assistantText("Asking the worker."),
            .toolCallStarted(hidden),
            .toolCallCompleted(hidden, result: DirectAgentToolResult(output: "sent", summary: "sent"))
        ])

        #expect(rows == ["Asking the worker."])
        #expect(plainRows([.toolCallStarted(hidden)]).isEmpty)
    }

    @Test
    func entriesAreSeparatedByExactlyOneBlankRow() {
        let call = readFileCall(id: "read-1")
        let rows = plainRows([
            .userPrompt(text: "Do it", attachments: [], origin: .unknown),
            .turnPhase(.started),
            .thought("Thinking it over."),
            .assistantText("On it."),
            .toolCallStarted(call)
        ])

        let blankIndexes = rows.indices.filter { rows[$0].isEmpty }
        #expect(blankIndexes.count == 3)
        #expect(rows.first == "> Do it")
        #expect(rows.last?.isEmpty == false)
        for index in blankIndexes {
            #expect(!rows[index - 1].isEmpty)
            #expect(!rows[index + 1].isEmpty)
        }
    }

    // MARK: - Width and styling

    @Test(arguments: [false, true])
    func everyRowFitsTheWidth(standardErrorIsTerminal: Bool) {
        let width = 28
        let longWord = String(repeating: "x", count: 70)
        let call = readFileCall(
            id: "read-long",
            path: "/tmp/a/very/long/path/to/a/deeply/nested/Source/File.swift"
        )
        let kinds: [ChatTurnEntry.Kind] = [
            .userPrompt(
                text: "Please refactor \(longWord) and also handle 漢字漢字漢字漢字漢字漢字漢字漢字 🚀🚀🚀🚀🚀🚀🚀🚀🚀🚀",
                attachments: [],
                origin: .unknown
            ),
            .thought("A **long** reasoning paragraph that keeps going well beyond the width \(longWord)."),
            .assistantText("""
            # Heading that is longer than the panel width

            - a list item that wraps across several rows of the panel
            - `inline code \(longWord)`

            ```swift
            let value = "\(longWord)"
            ```
            """),
            .toolCallStarted(call),
            .toolCallCompleted(call, result: DirectAgentToolResult(output: "ok", summary: "ok"))
        ]

        let rows = TerminalChat.renderSubAgentTranscriptRows(
            kinds,
            width: width,
            standardErrorIsTerminal: standardErrorIsTerminal
        )

        #expect(!rows.isEmpty)
        expectRowsFit(rows, width: width)
        if !standardErrorIsTerminal {
            #expect(rows.allSatisfy { !$0.contains("\u{1B}") })
        }
    }

    // MARK: - Header and live activity

    @Test
    func detailHeaderShowsIdentityMetadataAndErrorWithoutActivityOrResponse() {
        let rows = TerminalChat.subAgentDetailHeaderRows(
            snapshot(
                status: .failed,
                pending: false,
                currentActivity: "Working on the parser",
                currentActivityKind: .content,
                latestOutput: "the final response",
                latestError: "backend crashed"
            ),
            modelTitleResolver: { _ in "GPT Test" },
            width: 120
        ).map { TerminalANSIText.stripANSI($0) }
        let text = rows.joined(separator: "\n")

        #expect(text.contains("transcript-renderer"))
        #expect(text.contains("[FAILED]"))
        #expect(text.contains("id: agent_transcript_worker"))
        #expect(text.contains("role: Renders the transcript"))
        #expect(text.contains("agent: Developer"))
        #expect(text.contains("task: plan-graph-task-2"))
        #expect(text.contains("attempt: 3"))
        #expect(text.contains("model: GPT Test"))
        #expect(text.contains("g:"))
        #expect(text.contains("❌ backend crashed"))
        #expect(!text.contains("Working on the parser"))
        #expect(!text.contains("the final response"))
        #expect(!text.contains("Sub-Agents:"))
    }

    @Test(arguments: [12, 30, 39, 80])
    func detailHeaderRowsFitTheWidth(width: Int) {
        let header = TerminalChat.subAgentDetailHeaderRows(
            snapshot(
                currentActivity: "Working on the parser and the renderer of the very long transcript",
                currentActivityKind: .content,
                latestError: "a long error message that certainly does not fit the narrow panel"
            ),
            modelTitleResolver: { $0 },
            width: width
        )

        #expect(!header.isEmpty)
        expectRowsFit(header, width: width)
    }

    // MARK: - Live activity

    private func liveActivity(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        width: Int = 80,
        standardErrorIsTerminal: Bool
    ) -> [String] {
        TerminalChat.subAgentLiveActivityRows(
            snapshot,
            width: width,
            standardErrorIsTerminal: standardErrorIsTerminal
        )
    }

    /// The `🤔 thinking…` title, as the transcript draws it.
    private func thinkingTitle(standardErrorIsTerminal: Bool) -> String {
        standardErrorIsTerminal
            ? "\(TerminalStyle.Thinking.title)\(TerminalChat.thinkingPlaceholder)\(TerminalStyle.reset)"
            : TerminalChat.thinkingPlaceholder
    }

    @Test(arguments: [false, true])
    func liveActivityShowsTheReasoningAsAThinkingBlock(standardErrorIsTerminal: Bool) {
        let paragraph = "Weighing the options.\n\nThe second paragraph also wraps around the width."

        for width in [30, 80] {
            let rows = liveActivity(
                snapshot(currentActivityKind: .thinking, currentThought: paragraph),
                width: width,
                standardErrorIsTerminal: standardErrorIsTerminal
            )
            let transcriptRows = TerminalChat.renderSubAgentTranscriptRows(
                [.thought(paragraph)],
                width: width,
                standardErrorIsTerminal: standardErrorIsTerminal
            )

            #expect(rows == transcriptRows)
            #expect(rows.first == thinkingTitle(standardErrorIsTerminal: standardErrorIsTerminal))
            #expect(rows.count > 1)
            #expect(!rows.contains { $0.contains("Sub-Agents:") || $0.contains("💬") })
            if standardErrorIsTerminal {
                for row in rows {
                    // Written on its own, a row leaves no style open.
                    #expect(TerminalANSIText.updatedActiveStyle("", scanning: row).isEmpty)
                }
            } else {
                #expect(rows.allSatisfy { !$0.contains("\u{1B}") })
            }
        }
    }

    /// The live activity shows the whole reasoning of the phase
    /// (`currentThought`), not only the paragraph in progress: the earlier
    /// paragraphs stay, also once the paragraph in progress ended. Without
    /// `currentThought` the paragraph in progress alone is not shown: the
    /// placeholder is.
    @Test(arguments: [false, true])
    func liveActivityShowsTheWholeReasoningOfThePhase(standardErrorIsTerminal: Bool) {
        let thought = "Weighing the options.\n\nReading the parser next."

        for paragraph in ["Reading the parser next.", nil] {
            let rows = liveActivity(
                snapshot(
                    currentActivity: paragraph,
                    currentActivityKind: .thinking,
                    currentThought: thought
                ),
                width: 80,
                standardErrorIsTerminal: standardErrorIsTerminal
            )

            #expect(rows == TerminalChat.renderSubAgentTranscriptRows(
                [.thought(thought)],
                width: 80,
                standardErrorIsTerminal: standardErrorIsTerminal
            ))
            let plainRows = rows.map(TerminalANSIText.stripANSI)
            #expect(plainRows.contains { $0.contains("Weighing the options.") })
            #expect(plainRows.contains { $0.contains("Reading the parser next.") })
        }

        let withoutThought = liveActivity(
            snapshot(
                currentActivity: "Reading the parser next.",
                currentActivityKind: .thinking
            ),
            width: 80,
            standardErrorIsTerminal: standardErrorIsTerminal
        )
        #expect(withoutThought == [thinkingTitle(standardErrorIsTerminal: standardErrorIsTerminal)])
    }

    @Test(arguments: [false, true])
    func liveActivityHasNoRowsWhileAToolRuns(standardErrorIsTerminal: Bool) {
        // As the runtime leaves the agent at a call's start: the message that
        // preceded the call, if any, and the call running.
        let agents = [
            snapshot(currentToolName: "local.readFile", currentToolIsRunning: true),
            snapshot(
                currentActivityKind: .thinking,
                currentThought: "Weighing the options.",
                currentToolName: "local.readFile",
                currentToolIsRunning: true
            ),
            snapshot(
                currentActivity: "Working on the parser",
                currentActivityKind: .content,
                currentToolName: "local.exec",
                currentToolIsRunning: true
            )
        ]

        for agent in agents {
            #expect(liveActivity(agent, standardErrorIsTerminal: standardErrorIsTerminal).isEmpty)
        }
    }

    /// The runtime keeps the name and the target of a call after its result
    /// until the next model state, and the deltas of the next message do not
    /// change the snapshot: an agent that writes after a call, without
    /// reasoning first, still shows the placeholder.
    @Test(arguments: [false, true])
    func liveActivityAfterACompletedToolIsThePlaceholderAgain(standardErrorIsTerminal: Bool) {
        let placeholder = [thinkingTitle(standardErrorIsTerminal: standardErrorIsTerminal)]
        let agents = [
            // The call completed; the model writes its next message.
            snapshot(currentToolName: "local.readFile", currentToolIsRunning: false),
            // The message that preceded the call stays as the activity.
            snapshot(
                currentActivity: "Working on the parser",
                currentActivityKind: .content,
                currentToolName: "local.exec",
                currentToolIsRunning: false
            )
        ]

        for agent in agents {
            #expect(agent.currentToolName != nil)
            #expect(liveActivity(agent, standardErrorIsTerminal: standardErrorIsTerminal) == placeholder)
        }
    }

    /// Only the running flag tells a running call from a completed one with
    /// the same name.
    @Test(arguments: [false, true])
    func liveActivityFollowsTheRunningFlagOfTheSameCall(standardErrorIsTerminal: Bool) {
        let running = snapshot(
            currentActivity: "Reading.",
            currentActivityKind: .content,
            currentToolName: "local.readFile",
            currentToolIsRunning: true
        )
        let completed = snapshot(
            currentActivity: "Reading.",
            currentActivityKind: .content,
            currentToolName: "local.readFile",
            currentToolIsRunning: false
        )

        #expect(liveActivity(running, standardErrorIsTerminal: standardErrorIsTerminal).isEmpty)
        #expect(
            liveActivity(completed, standardErrorIsTerminal: standardErrorIsTerminal)
                == [thinkingTitle(standardErrorIsTerminal: standardErrorIsTerminal)]
        )
    }

    @Test(arguments: [false, true])
    func liveActivityHasNoRowsWhenTheAgentIsNotPending(standardErrorIsTerminal: Bool) {
        let agents = [
            snapshot(status: .idle, pending: false),
            snapshot(
                status: .standby,
                pending: false,
                currentActivityKind: .thinking,
                currentThought: "Weighing the options."
            ),
            snapshot(
                status: .failed,
                pending: false,
                currentActivity: "Working on the parser",
                currentActivityKind: .content,
                currentToolName: "local.readFile",
                currentToolIsRunning: true,
                latestError: "backend crashed"
            ),
            snapshot(status: .closed, pending: false, currentToolName: "agent.message")
        ]

        for agent in agents {
            #expect(liveActivity(agent, standardErrorIsTerminal: standardErrorIsTerminal).isEmpty)
        }
    }

    @Test(arguments: [false, true], [1, 5, 12, 30, 39, 80])
    func liveActivityRowsFitTheWidth(standardErrorIsTerminal: Bool, width: Int) {
        let agents = [
            snapshot(
                currentActivity: "Working on the parser and the renderer of the very long transcript",
                currentActivityKind: .content
            ),
            snapshot(currentActivityKind: .thinking),
            snapshot(
                currentActivityKind: .thinking,
                currentThought: "Weighing the options and the very long reasoning that wraps.\n\nSecond paragraph."
            )
        ]

        for agent in agents {
            let rows = liveActivity(agent, width: width, standardErrorIsTerminal: standardErrorIsTerminal)
            #expect(!rows.isEmpty)
            expectRowsFit(rows, width: width)
        }
    }
}
