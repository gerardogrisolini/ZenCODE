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
    func wrappedPromptRowsStayAlignedAfterThePromptMarker() {
        let rows = plainRows(
            [.userPrompt(text: "abcdefghijklmnopqrstuvwxyz\nsecond", attachments: [], origin: .unknown)],
            width: 12
        )

        #expect(rows == ["> abcdefghij", "  klmnopqrst", "  uvwxyz", "  second"])
    }

    @Test
    func userPromptOnATerminalPadsTheBandToTheWidth() {
        let width = 24
        let rows = TerminalChat.renderSubAgentTranscriptRows(
            [.userPrompt(text: "Fix the build and then run every test", attachments: [], origin: .unknown)],
            width: width,
            standardErrorIsTerminal: true
        )

        #expect(rows.count == 2)
        for row in rows {
            #expect(row.hasPrefix(TerminalStyle.Prompt.background))
            #expect(row.hasSuffix(TerminalStyle.reset))
            #expect(!row.contains("\u{1B}[K"))
            #expect(TerminalANSIText.visibleWidth(row) == width)
        }
        #expect(TerminalANSIText.stripANSI(rows[0]).hasPrefix("> Fix the build"))
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

    @Test
    func completedToolCallWithoutAStartIsRenderedWhereItArrives() {
        let call = readFileCall(id: "orphan")
        let rows = plainRows([
            .assistantText("Before."),
            .toolCallCompleted(call, result: DirectAgentToolResult(output: "ok", summary: "ok"))
        ])

        #expect(occurrences(of: "local.readFile", in: rows) == 1)
        #expect(occurrences(of: "✅", in: rows) == 1)
        #expect(rows.first == "Before.")
    }

    @Test
    func failedProcessShowsItsExitCodeWithoutElapsedTime() {
        let call = presentedToolCall(
            id: "exec-1",
            name: "local.exec",
            argumentsObject: ["command": "swift test"],
            argumentsJSON: #"{"command":"swift test"}"#
        )
        let rows = plainRows([
            .toolCallStarted(call),
            .toolCallCompleted(call, result: DirectAgentToolResult(
                output: "exit_code: 2\nstderr: failure",
                summary: "exit_code: 2"
            ))
        ])

        #expect(occurrences(of: "⚠️", in: rows) == 1)
        #expect(occurrences(of: "exit 2", in: rows) == 1)
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
    func nonConversationKindsHaveNoRows() {
        let ignored: [ChatTurnEntry.Kind] = [
            .turnPhase(.started),
            .turnPhase(.modelReturned),
            .turnPhase(.finishing),
            .notice(.operationFailed(description: "boom")),
            .workflowNotice(.blocked(graphID: "graph", message: "waiting")),
            .fileArtifacts(
                SessionFileArtifactHistory.Turn(number: 1, artifacts: []),
                agentID: "agent_transcript_worker",
                isSealed: false
            )
        ]

        #expect(plainRows(ignored).isEmpty)
        #expect(TerminalChat.renderSubAgentTranscriptRows(
            ignored,
            width: 80,
            standardErrorIsTerminal: true
        ).isEmpty)
        #expect(plainRows(ignored + [.assistantText("Only this.")] + ignored) == ["Only this."])
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

    @Test
    func thoughtRowsCarryTheirOwnStyle() {
        let width = 30
        let rows = TerminalChat.renderSubAgentTranscriptRows(
            [.thought("First paragraph of the reasoning that wraps.\n\nSecond paragraph that also wraps around.")],
            width: width,
            standardErrorIsTerminal: true
        )
        let bodyRows = rows.dropFirst().filter {
            !TerminalANSIText.stripANSI($0).trimmingCharacters(in: .whitespaces).isEmpty
        }

        #expect(rows.first == "\(TerminalStyle.Thinking.title)\(TerminalChat.thinkingPlaceholder)\(TerminalStyle.reset)")
        #expect(bodyRows.count >= 4)
        for row in rows {
            // Written on its own, a row leaves no style open.
            #expect(TerminalANSIText.updatedActiveStyle("", scanning: row).isEmpty, "\(row.debugDescription)")
        }
        for row in bodyRows {
            // Every row with visible text opens the thinking style itself.
            #expect(row.hasPrefix(TerminalStyle.Thinking.body), "\(row.debugDescription)")
        }
        expectRowsFit(rows, width: width)
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
    func detailHeaderAndLiveActivityRowsFitTheWidth(width: Int) {
        let agent = snapshot(
            currentActivity: "Working on the parser and the renderer of the very long transcript",
            currentActivityKind: .content,
            latestError: "a long error message that certainly does not fit the narrow panel"
        )

        let header = TerminalChat.subAgentDetailHeaderRows(
            agent,
            modelTitleResolver: { $0 },
            width: width
        )
        let activity = TerminalChat.subAgentLiveActivityRows(agent, width: width)

        #expect(!header.isEmpty)
        #expect(!activity.isEmpty)
        expectRowsFit(header, width: width)
        expectRowsFit(activity, width: width)
    }

    @Test
    func liveActivityRowsShowTheCurrentActivity() {
        let content = TerminalChat.subAgentLiveActivityRows(
            snapshot(currentActivity: "Working on the parser", currentActivityKind: .content),
            width: 80
        ).map { TerminalANSIText.stripANSI($0) }
        let thinking = TerminalChat.subAgentLiveActivityRows(
            snapshot(currentActivity: "Weighing the options.", currentActivityKind: .thinking),
            width: 80
        ).map { TerminalANSIText.stripANSI($0) }

        #expect(content.contains { $0.contains("💬 Working on the parser") })
        #expect(!content.contains { $0.contains("Sub-Agents:") })
        #expect(thinking.contains { $0.contains(TerminalChat.thinkingPlaceholder) })
        #expect(thinking.contains { $0.contains("Weighing the options.") })
    }
}
