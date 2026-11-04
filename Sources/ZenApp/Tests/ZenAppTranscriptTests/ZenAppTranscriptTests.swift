import Foundation
import SwiftUI
import Testing
import ToolCore
import ZenAppTheme
import ZenCODECore

@testable import ZenAppTranscript

// MARK: - Fixtures

private func toolCall(
    _ name: String,
    _ arguments: [String: Any] = [:],
    presentation: ToolPresentationDefinition? = nil
) -> DirectAgentToolCall {
    DirectAgentToolCall(
        id: "call-1",
        name: name,
        argumentsObject: arguments,
        argumentsJSON: "",
        presentation: presentation
    )
}

/// The presentation `local.exec` declares in `DirectProcessToolDescriptors`.
private let localExecPresentation = ToolPresentationDefinition(
    title: "Command",
    action: "Run",
    kind: .execute,
    target: .argument(["command"], format: .command)
)

// MARK: - Tool status

@Suite("Tool call status")
struct ZenToolCallStatusTests {
    @Test("a call without a result is running")
    func running() {
        #expect(ZenToolCallStatus(call: toolCall("local.readFile"), result: nil) == .running)
    }

    @Test("a completed result is completed")
    func completed() {
        let result = DirectAgentToolResult(output: "ok", summary: "ok")
        #expect(ZenToolCallStatus(call: toolCall("local.readFile"), result: result) == .completed)
    }

    @Test("a failed status or a tool-error output is failed")
    func failed() {
        let failed = DirectAgentToolResult(output: "boom", summary: "boom", status: .failed)
        let toolError = DirectAgentToolResult(output: "  Tool error: missing path", summary: "error")
        #expect(ZenToolCallStatus(call: toolCall("local.readFile"), result: failed) == .failed)
        #expect(ZenToolCallStatus(call: toolCall("local.readFile"), result: toolError) == .failed)
    }

    @Test("a permission denial is its own status, not a plain failure")
    func permissionDenied() {
        let denied = DirectAgentToolResult(output: "denied", summary: "denied", status: .permissionDenied)
        let status = ZenToolCallStatus(call: toolCall("local.exec", ["command": "rm -rf /"]), result: denied)
        #expect(status == .permissionDenied)
        #expect(status.glyph == "⊘")
        #expect(status.role == .failure)
    }

    @Test("local.exec fails on a non-zero canonical exit code only")
    func localExecExitCode() {
        let call = toolCall("local.exec", ["command": "false"])
        let nonZero = DirectAgentToolResult(output: "exit_code: 2\nstderr:\nboom", summary: "exit_code: 2")
        let zero = DirectAgentToolResult(output: "exit_code: 0\nstdout:\nok", summary: "exit_code: 0")
        let phrase = DirectAgentToolResult(output: "stdout:\nexit_code: 3", summary: "ran")
        #expect(ZenToolCallStatus(call: call, result: nonZero) == .failed)
        #expect(ZenToolCallStatus(call: call, result: zero) == .completed)
        #expect(ZenToolCallStatus(call: call, result: phrase) == .completed)
        // Another tool's output is never read as a process result.
        #expect(ZenToolCallStatus(call: toolCall("local.readFile"), result: nonZero) == .completed)
    }

    @Test("glyphs and color roles follow the brief")
    func glyphsAndRoles() {
        #expect(ZenToolCallStatus.running.glyph == "●")
        #expect(ZenToolCallStatus.completed.glyph == "✓")
        #expect(ZenToolCallStatus.failed.glyph == "✗")
        #expect(ZenToolCallStatus.running.role == .active)
        #expect(ZenToolCallStatus.completed.role == .success)
        #expect(ZenToolCallStatus.failed.role == .failure)
    }
}

// MARK: - Compact line

@Suite("Tool call compact line")
struct ZenToolCompactLineTests {
    @Test("local.exec shows its command on one line")
    func localExecWithPresentation() {
        let call = toolCall(
            "local.exec",
            ["command": "swift build \\\n    --target ZenAppTranscript"],
            presentation: localExecPresentation
        )
        let line = ZenToolCallFormatting.compactLine(for: call)
        #expect(line.title == "local.exec")
        #expect(line.target == "swift build \\ --target ZenAppTranscript")
    }

    @Test("local.exec without a presentation falls back to the command argument")
    func localExecWithoutPresentation() {
        let line = ZenToolCallFormatting.compactLine(for: toolCall("local.exec", ["command": "git status"]))
        #expect(line.title == "local.exec")
        #expect(line.target == "git status")
    }

    @Test("a generic tool shows its name and a safe argument target")
    func genericTool() {
        let withPath = ZenToolCallFormatting.compactLine(for: toolCall("custom.inspect", ["path": "Sources/App.swift"]))
        #expect(withPath.title == "custom.inspect")
        #expect(withPath.target == "Sources/App.swift")

        // Payload-like arguments are never used as a target.
        let withPayload = ZenToolCallFormatting.compactLine(for: toolCall("custom.send", ["content": "secret"]))
        #expect(withPayload.title == "custom.send")
        #expect(withPayload.target == nil)
    }

    @Test("the completion detail joins the elapsed time and a non-zero exit code")
    func completionDetail() {
        let call = toolCall("local.exec", ["command": "false"])
        let failed = DirectAgentToolResult(output: "exit_code: 1", summary: "exit_code: 1")
        #expect(ZenToolCallFormatting.completionDetail(for: call, result: failed, duration: .milliseconds(1_250)) == "1.25s exit 1")
        #expect(ZenToolCallFormatting.completionDetail(for: call, result: nil, duration: .milliseconds(420)) == "420ms")
        #expect(ZenToolCallFormatting.completionDetail(for: call, result: nil, duration: nil) == nil)
    }

    @Test("elapsed times are written like the terminal")
    func elapsedText() {
        #expect(ZenToolCallFormatting.elapsedText(.seconds(2)) == "2.00s")
        #expect(ZenToolCallFormatting.elapsedText(.milliseconds(420)) == "420ms")
        #expect(ZenToolCallFormatting.elapsedText(.microseconds(8_400)) == "8.40ms")
        #expect(ZenToolCallFormatting.elapsedText(.microseconds(45_500)) == "45.5ms")
        #expect(ZenToolCallFormatting.elapsedText(.zero) == "0ms")
        #expect(ZenToolCallFormatting.elapsedText(.nanoseconds(5)) == "<0.01ms")
    }

    @Test("agent.message is hidden like in the terminal")
    func hiddenTools() {
        #expect(ZenToolCallFormatting.isHidden(toolName: "agent.message"))
        #expect(!ZenToolCallFormatting.isHidden(toolName: "agent.create"))
    }
}

// MARK: - Line diff

@Suite("Line diff")
struct ZenLineDiffTests {
    @Test("a replaced line is a deletion followed by an addition")
    func replacedLine() {
        let rows = ZenToolCallFormatting.lineDiff(old: "a\nb\nc\n", new: "a\nx\nc\n")
        #expect(rows == [
            ZenTranscriptDiffRow(kind: .context, oldLineNumber: 1, newLineNumber: 1, text: "a"),
            ZenTranscriptDiffRow(kind: .deletion, oldLineNumber: 2, newLineNumber: nil, text: "b"),
            ZenTranscriptDiffRow(kind: .addition, oldLineNumber: nil, newLineNumber: 2, text: "x"),
            ZenTranscriptDiffRow(kind: .context, oldLineNumber: 3, newLineNumber: 3, text: "c")
        ])
    }

    @Test("an empty old text is all additions, an empty new text all deletions")
    func emptySides() {
        let added = ZenToolCallFormatting.lineDiff(old: "", new: "one\ntwo")
        #expect(added.map(\.kind) == [.addition, .addition])
        #expect(added.map(\.newLineNumber) == [1, 2])
        let removed = ZenToolCallFormatting.lineDiff(old: "one\ntwo", new: "")
        #expect(removed.map(\.kind) == [.deletion, .deletion])
        #expect(ZenToolCallFormatting.lineDiff(old: "", new: "").isEmpty)
    }

    @Test("identical texts are all context, CRLF counts as a line break")
    func identicalTexts() {
        let rows = ZenToolCallFormatting.lineDiff(old: "a\r\nb", new: "a\nb\n")
        #expect(rows.map(\.kind) == [.context, .context])
        #expect(ZenToolCallFormatting.contextHunks(rows).isEmpty)
    }

    @Test("context hunks keep the changes with their context and merge overlaps")
    func contextHunks() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n")
        var newLines = (1...20).map { "line \($0)" }
        newLines[1] = "changed 2"
        newLines[17] = "changed 18"
        let rows = ZenToolCallFormatting.lineDiff(old: old, new: newLines.joined(separator: "\n"))
        let hunks = ZenToolCallFormatting.contextHunks(rows, context: 2)
        #expect(hunks.count == 2)
        #expect(hunks[0].first?.oldLineNumber == 1)
        #expect(hunks[0].filter { $0.kind != .context }.count == 2)
        #expect(hunks[1].last?.oldLineNumber == 20)
        let merged = ZenToolCallFormatting.contextHunks(rows, context: 10)
        #expect(merged.count == 1)
    }
}

// MARK: - File artifact diffs

@Suite("File artifact diffs")
struct ZenFileArtifactDiffTests {
    @Test("the language of an artifact follows the extension of its display path, else its absolute path")
    func sourceLanguage() {
        let swift = FileChangeArtifact(absolutePath: "/p/Sources/App.swift", displayPath: "Sources/App.swift", status: .modified)
        let blankDisplay = FileChangeArtifact(absolutePath: "/p/Sources/main.py", displayPath: "  ", status: .added)
        let markdown = FileChangeArtifact(absolutePath: "/p/README.md", displayPath: "README.md", status: .modified)
        #expect(ZenFileChangeFormatting.sourceLanguage(of: swift) == "swift")
        #expect(ZenFileChangeFormatting.sourceLanguage(of: blankDisplay) == "python")
        #expect(ZenFileChangeFormatting.sourceLanguage(of: markdown) == nil)
    }

    @Test("the source column numbers a deletion with its old line and the other rows with their new line")
    func sourceLineNumbers() {
        let rows = ZenToolCallFormatting.lineDiff(old: "a\nb\nc\n", new: "a\nx\nc\n")
        #expect(rows.map(ZenDiffRowsView.sourceLineNumber(of:)) == [1, 2, 2, 3])
    }

    @Test("the gutter is as wide as the widest number the rows show")
    func gutterWidth() {
        let rows = [
            ZenTranscriptDiffRow(kind: .deletion, oldLineNumber: 120, newLineNumber: nil, text: "old"),
            ZenTranscriptDiffRow(kind: .addition, oldLineNumber: nil, newLineNumber: 9, text: "new")
        ]
        #expect(ZenDiffRowsView.gutterWidth([rows], lineNumbers: .oldAndNew) == 3)
        #expect(ZenDiffRowsView.gutterWidth([rows], lineNumbers: .source) == 3)
        let added = [ZenTranscriptDiffRow(kind: .addition, oldLineNumber: nil, newLineNumber: 7, text: "x")]
        #expect(ZenDiffRowsView.gutterWidth([added], lineNumbers: .source) == 1)
        #expect(ZenDiffRowsView.gutterWidth([], lineNumbers: .source) == 1)
    }

    @Test("a patch line that carries source splits into its marker and its source")
    func patchSource() {
        let lines = ZenFileChangeFormatting.patchLines("@@ -1,2 +1,2 @@\n-let a = 1\n+let a = 2\n same\n\\ No newline at end of file")
        let parts = lines.map(ZenFileChangeFormatting.patchSource(of:))
        #expect(parts[0] == nil)
        #expect(parts[1]?.marker == "-" && parts[1]?.source == "let a = 1")
        #expect(parts[2]?.marker == "+" && parts[2]?.source == "let a = 2")
        #expect(parts[3]?.marker == " " && parts[3]?.source == "same")
        #expect(parts[4] == nil)
        // File headers and a context line without its space carry no source.
        #expect(ZenFileChangeFormatting.patchSource(of: ZenPatchLine(kind: .header, text: "+++ b/App.swift")) == nil)
        #expect(ZenFileChangeFormatting.patchSource(of: ZenPatchLine(kind: .context, text: "loose")) == nil)
    }

    @Test("a patch numbers its lines as the terminal's file artifacts do")
    func patchLineNumbers() {
        let lines = ZenFileChangeFormatting.patchLines("""
        diff --git a/App.swift b/App.swift
        index 1..2 100644
        --- a/App.swift
        +++ b/App.swift
        @@ -3,3 +3,4 @@
         let a = 1
        -let b = 2
        +let b = 3
        +let c = 4
         let d = 5
        @@ -40 +41 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """)
        let numbers = ZenFileChangeFormatting.patchLineNumbers(lines)
        // Headers and notes carry none; a removal its old line, the others their new line.
        #expect(numbers == [nil, nil, nil, nil, nil, 3, 4, 4, 5, 6, nil, 40, nil, 41, nil])
        #expect(numbers == TerminalChat.artifactDiffSourceLineNumbers(lines.map(\.text)))
        #expect(ZenFileChangeFormatting.patchLineNumbers([]) == [])
    }

    @Test("the patch gutter is as wide as the widest number it shows")
    func patchGutterWidth() {
        #expect(ZenPatchLinesView.gutterWidth([nil, 9, 120, nil]) == 3)
        #expect(ZenPatchLinesView.gutterWidth([nil, 7]) == 1)
        #expect(ZenPatchLinesView.gutterWidth([nil, nil]) == 1)
        #expect(ZenPatchLinesView.gutterWidth([]) == 1)
    }

    @Test("the default highlighter colors nothing")
    func plainHighlighter() {
        #expect(ZenCodeHighlighter.plain.highlight("let a = 1", language: "swift", palette: .dark) == nil)
    }
}

// MARK: - Bounding

@Suite("Output bounding")
struct ZenOutputBoundingTests {
    @Test("output is cut to the preview lines with the hidden count")
    func previewLines() {
        let output = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let bounded = ZenTranscriptText.boundedLines(output, maxLines: ZenToolCallFormatting.outputPreviewLineLimit)
        #expect(bounded.lines.count == 40)
        #expect(bounded.lines.first == "line 1")
        #expect(bounded.lines.last == "line 40")
        #expect(bounded.hiddenLineCount == 60)
        #expect(bounded.isTruncated)
    }

    @Test("a short output is kept whole; CRLF is one break")
    func shortOutput() {
        let bounded = ZenTranscriptText.boundedLines("a\r\nb\r\n", maxLines: 40)
        #expect(bounded.lines == ["a", "b"])
        #expect(!bounded.isTruncated)
        #expect(ZenTranscriptText.boundedLines("", maxLines: 40).lines.isEmpty)
    }

    @Test("a very long line is cut with an ellipsis")
    func longLine() {
        let bounded = ZenTranscriptText.boundedLines(String(repeating: "x", count: 5_000), maxLines: 40, maxLineLength: 100)
        #expect(bounded.lines.count == 1)
        #expect(bounded.lines[0].count == 101)
        #expect(bounded.lines[0].hasSuffix("…"))
    }

    @Test("a long text is cut with the count of the characters left out")
    func boundedText() {
        #expect(ZenTranscriptText.bounded("short", limit: 10) == "short")
        #expect(ZenTranscriptText.bounded("abcdefghij", limit: 4) == "abcd… (6 more characters)")
    }

    @Test("inline values lose controls and repeated whitespace")
    func inlineValues() {
        #expect(ZenTranscriptText.inline("  a\n\tb\u{1B}[31m  c ") == "a b [31m c")
        #expect(ZenTranscriptText.inline(" \n\t ") == nil)
        #expect(ZenTranscriptText.inline("abcdef", limit: 3) == "abc…")
    }
}

// MARK: - Status roles

@Suite("Status roles")
struct ZenStatusRoleTests {
    @Test("task statuses map to the brief's color roles")
    func taskStatusRoles() {
        #expect(ZenTranscriptStatus.role(for: TaskStatus.pending) == .queued)
        #expect(ZenTranscriptStatus.role(for: TaskStatus.inProgress) == .active)
        #expect(ZenTranscriptStatus.role(for: TaskStatus.completed) == .success)
        #expect(ZenTranscriptStatus.role(for: TaskStatus.failed) == .failure)
        #expect(ZenTranscriptStatus.role(for: TaskStatus.blocked) == .failure)
        #expect(ZenTranscriptStatus.role(for: TaskStatus.cancelled) == .inactive)
        #expect(ZenTranscriptStatus.role(for: TaskStatus.awaitingValidation) == .inactive)
    }

    @Test("task glyphs mirror the terminal overview")
    func taskGlyphs() {
        let glyphs = TaskStatus.allCases.map { ZenTranscriptStatus.glyph(for: $0) }
        #expect(glyphs == ["○", "▸", "◇", "✓", "⊘", "✗", "—"])
    }

    @Test("roles resolve to the palette's status colors")
    func roleColors() {
        for palette in [ZenPalette.dark, ZenPalette.light] {
            #expect(ZenStatusRole.queued.color(in: palette) == palette.statusQueued)
            #expect(ZenStatusRole.active.color(in: palette) == palette.statusActive)
            #expect(ZenStatusRole.success.color(in: palette) == palette.statusSuccess)
            #expect(ZenStatusRole.failure.color(in: palette) == palette.statusFailure)
            #expect(ZenStatusRole.inactive.color(in: palette) == palette.statusInactive)
        }
    }

    @Test("graph states map to roles")
    func graphStates() {
        #expect(ZenTranscriptStatus.role(for: TaskGraphState.active) == .active)
        #expect(ZenTranscriptStatus.role(for: TaskGraphState.completed) == .success)
        #expect(ZenTranscriptStatus.role(for: TaskGraphState.draft) == .queued)
        #expect(ZenTranscriptStatus.role(for: TaskGraphState.archived) == .inactive)
    }

    @Test("the task summary lists the total and the non-zero counts in order")
    func taskSummary() {
        let statuses: [TaskStatus] = [.completed, .completed, .inProgress, .pending, .failed]
        let views = statuses.enumerated().map { index, status in
            TaskRecordView(
                graphID: "g",
                graphRevision: 1,
                graphState: .active,
                task: TaskRecord(id: "t\(index)", title: "Task \(index)", order: index, status: status),
                isRunnable: true,
                blockedBy: [],
                blockedReason: nil,
                dependents: []
            )
        }
        let segments = ZenTranscriptStatus.taskSummarySegments(views)
        #expect(segments.map(\.text) == ["5 total", "▸ 1 running", "✓ 2 completed", "○ 1 waiting", "✗ 1 failed"])
        #expect(segments.map(\.role) == [nil, .active, .success, .queued, .failure])
    }

    @Test("sub-agents are colored and labeled like the terminal")
    func subAgents() {
        func snapshot(_ status: DirectSubAgentRuntime.Status, output: String? = nil) -> DirectSubAgentRuntime.AgentSnapshot {
            DirectSubAgentRuntime.AgentSnapshot(
                id: UUID().uuidString,
                name: "agent",
                role: "Developer",
                status: status,
                pending: status.isPending,
                latestOutput: output,
                latestError: nil,
                createdAt: .now,
                updatedAt: .now
            )
        }
        #expect(ZenTranscriptStatus.role(for: snapshot(.running)) == .active)
        #expect(ZenTranscriptStatus.role(for: snapshot(.queued)) == .queued)
        #expect(ZenTranscriptStatus.role(for: snapshot(.idle)) == .inactive)
        #expect(ZenTranscriptStatus.role(for: snapshot(.idle, output: "done")) == .success)
        #expect(ZenTranscriptStatus.role(for: snapshot(.failed)) == .failure)
        #expect(ZenTranscriptStatus.displayStatus(for: snapshot(.idle, output: "done")) == "completed")
        #expect(ZenTranscriptStatus.displayStatus(for: snapshot(.standby)) == "standby")

        let segments = ZenTranscriptStatus.subAgentSummarySegments([
            snapshot(.running), snapshot(.idle, output: "done"), snapshot(.failed)
        ])
        #expect(segments.map(\.text) == ["3 total", "▸ 1 active", "✓ 1 completed", "✗ 1 failed"])
    }

    @Test("token counts and elapsed times are abbreviated")
    func abbreviations() {
        #expect(ZenTranscriptStatus.tokenCountText(950) == "950")
        #expect(ZenTranscriptStatus.tokenCountText(12_345) == "12.3k")
        #expect(ZenTranscriptStatus.tokenCountText(1_250_000) == "1.2m")
        #expect(ZenTranscriptStatus.elapsedText(12.9) == "12s")
        #expect(ZenTranscriptStatus.elapsedText(185) == "3m 05s")
        #expect(ZenTranscriptStatus.elapsedText(3_720) == "1h 02m")
    }
}

// MARK: - Sub-agents card

@Suite("Sub-agents card")
struct ZenSubAgentsCardTests {
    private let palette = ZenPalette.dark

    private func snapshot(
        id: String = "agent",
        name: String = "agent",
        role: String = "Developer",
        profileName: String? = nil,
        taskID: String? = nil,
        taskAttemptOrdinal: Int? = nil,
        status: DirectSubAgentRuntime.Status = .running,
        configuredModelID: String? = nil,
        modelID: String? = nil,
        activity: String? = nil,
        activityKind: DirectSubAgentRuntime.ActivityKind? = nil,
        toolName: String? = nil,
        metrics: DirectAgentGenerationMetrics? = nil,
        output: String? = nil
    ) -> DirectSubAgentRuntime.AgentSnapshot {
        DirectSubAgentRuntime.AgentSnapshot(
            id: id,
            taskID: taskID,
            taskAttemptOrdinal: taskAttemptOrdinal,
            name: name,
            role: role,
            profileName: profileName,
            status: status,
            pending: status.isPending,
            configuredModelID: configuredModelID,
            modelID: modelID,
            currentActivity: activity,
            currentActivityKind: activityKind,
            currentToolName: toolName,
            latestMetrics: metrics,
            latestOutput: output,
            latestError: nil,
            createdAt: .now,
            updatedAt: .now
        )
    }

    /// The metadata lines as plain text.
    private func metadata(_ snapshot: DirectSubAgentRuntime.AgentSnapshot) -> [String] {
        ZenSubAgentRow.metadataLines(for: snapshot, palette: palette).map { $0.map(\.text).joined() }
    }

    @Test("only the agents in progress are shown, in the given order")
    func visibleSnapshotsKeepOnlyPending() {
        let snapshots = [
            snapshot(id: "a", status: .running),
            snapshot(id: "b", status: .idle, output: "done"),
            snapshot(id: "c", status: .queued),
            snapshot(id: "d", status: .failed),
            snapshot(id: "e", status: .standby),
            snapshot(id: "f", status: .closed),
            snapshot(id: "g", status: .running)
        ]
        #expect(ZenSubAgentsCard.visibleSnapshots(snapshots).map(\.id) == ["a", "c", "g"])
        #expect(ZenSubAgentsCard.visibleSnapshots([]).isEmpty)
        #expect(ZenSubAgentsCard.visibleSnapshots([snapshot(status: .idle)]).isEmpty)
    }

    @Test("the summary counts the agents in progress")
    func summaryCountsVisibleAgents() {
        let visible = ZenSubAgentsCard.visibleSnapshots([
            snapshot(id: "a", status: .running),
            snapshot(id: "b", status: .queued),
            snapshot(id: "c", status: .idle)
        ])
        let segments = ZenSubAgentsCard.summarySegments(visible)
        #expect(segments.map(\.text) == ["2 in progress"])
        #expect(segments.map(\.role) == [nil])
    }

    @Test("metadata shows role, agent, task, attempt, model, and tokens when present")
    func metadataWithEverything() {
        let lines = metadata(snapshot(
            role: "Developer",
            profileName: "Builder",
            taskID: "transcript-views",
            taskAttemptOrdinal: 2,
            configuredModelID: "claude-opus",
            modelID: "claude-opus-4",
            metrics: DirectAgentGenerationMetrics(
                promptTokenCount: 1_250,
                cachedPromptTokenCount: 48_000,
                completionTokenCount: 312
            )
        ))
        #expect(lines == [
            "role: Developer  ·  agent: Builder",
            "task: transcript-views  ·  attempt: 2",
            "model: claude-opus  ·  c:48.0k p:1.2k g:312"
        ])
        #expect(!lines.joined().contains("id:"))
    }

    @Test("metadata leaves out what the snapshot does not have")
    func metadataOmitsMissingValues() {
        // Role only.
        #expect(metadata(snapshot(role: "Reviewer")) == ["role: Reviewer"])
        // A blank role and no profile, task, model, or metrics: nothing.
        #expect(metadata(snapshot(role: "  ")).isEmpty)
        // An attempt without a task is not shown.
        #expect(metadata(snapshot(role: "", taskAttemptOrdinal: 3)).isEmpty)
        // A task without an attempt.
        #expect(metadata(snapshot(role: "", taskID: "t1")) == ["task: t1"])
        // Only the agent profile.
        #expect(metadata(snapshot(role: "", profileName: "Tester")) == ["agent: Tester"])
    }

    @Test("the model falls back to the reported one and the counters can stand alone")
    func metadataModelAndTokens() {
        #expect(metadata(snapshot(role: "", modelID: "gpt-5")) == ["model: gpt-5"])
        #expect(metadata(snapshot(role: "", configuredModelID: " ", modelID: "gpt-5")) == ["model: gpt-5"])
        // Only some of the counters.
        let partial = DirectAgentGenerationMetrics(promptTokenCount: 10, completionTokenCount: 5)
        #expect(metadata(snapshot(role: "", configuredModelID: "m", metrics: partial)) == ["model: m  ·  p:10 g:5"])
        // Counters without a model.
        #expect(metadata(snapshot(role: "", metrics: partial)) == ["p:10 g:5"])
        // Metrics without any counter.
        #expect(metadata(snapshot(
            role: "",
            metrics: DirectAgentGenerationMetrics(promptTokenCount: nil, completionTokenCount: nil)
        )).isEmpty)
    }

    @Test("metadata labels are muted and values use the inline-code color")
    func metadataColors() {
        let lines = ZenSubAgentRow.metadataLines(
            for: snapshot(
                role: "Developer",
                taskID: "t1",
                taskAttemptOrdinal: 1,
                configuredModelID: "m",
                metrics: DirectAgentGenerationMetrics(promptTokenCount: 10, completionTokenCount: nil)
            ),
            palette: palette
        )
        #expect(lines.count == 3)
        let labels: Set<String> = ["role: ", "task: ", "attempt: ", "model: ", "  ·  ", "p:"]
        for run in lines.flatMap(\.self) {
            if labels.contains(run.text) {
                #expect(run.color == palette.textMuted, "\(run.text)")
            } else {
                #expect(run.color == palette.inlineCodeForeground, "\(run.text)")
            }
        }
    }

    @Test("the activity follows the terminal: reasoning, message, tool, or the placeholder")
    func activityPhases() {
        let thinking = ZenSubAgentActivity(snapshot(
            activity: "Checking\nthe palette.", activityKind: .thinking
        ))
        #expect(thinking.phase == .thinking(paragraph: "Checking the palette."))
        #expect(!thinking.showsThinkingPlaceholder)

        // Reasoning without a paragraph yet is still the thinking row.
        let bare = ZenSubAgentActivity(snapshot(activityKind: .thinking))
        #expect(bare.phase == .thinking(paragraph: nil))
        #expect(!bare.showsThinkingPlaceholder)

        let message = ZenSubAgentActivity(snapshot(activity: "Writing the file.", activityKind: .content))
        #expect(message.phase == .message("Writing the file."))
        #expect(ZenSubAgentActivity(snapshot(activity: "No kind.")).phase == .message("No kind."))

        let tool = ZenSubAgentActivity(snapshot(toolName: "local.exec"))
        #expect(tool.phase == .none)
        #expect(tool.toolName == "local.exec")
        #expect(!tool.showsThinkingPlaceholder)

        // A pending agent with nothing to show holds the thinking placeholder.
        let idleWork = ZenSubAgentActivity(snapshot(status: .queued))
        #expect(idleWork.phase == .none)
        #expect(idleWork.toolName == nil)
        #expect(idleWork.showsThinkingPlaceholder)
    }

    @Test("a hidden tool is left out and does not stop the placeholder")
    func hiddenToolIsExcluded() {
        let hidden = ZenSubAgentActivity(snapshot(toolName: "agent.message"))
        #expect(hidden.toolName == nil)
        #expect(hidden.showsThinkingPlaceholder)

        let blank = ZenSubAgentActivity(snapshot(activity: "  \n ", toolName: "  "))
        #expect(blank.phase == .none)
        #expect(blank.toolName == nil)
        #expect(blank.showsThinkingPlaceholder)

        // A finished agent has no placeholder.
        #expect(!ZenSubAgentActivity(snapshot(status: .idle)).showsThinkingPlaceholder)
    }

    @Test("the live activity of a tab: never empty while pending, except while a tool runs")
    func liveActivity() {
        #expect(ZenSubAgentLiveActivity(snapshot(
            activity: "Checking\nthe palette.", activityKind: .thinking
        )) == .thought("Checking\nthe palette."))
        // Reasoning without a paragraph yet.
        #expect(ZenSubAgentLiveActivity(snapshot(activityKind: .thinking)) == .thinkingPlaceholder)
        #expect(ZenSubAgentLiveActivity(snapshot(activity: " \n", activityKind: .thinking)) == .thinkingPlaceholder)
        // The message phase shows the placeholder too, with its text or not.
        #expect(ZenSubAgentLiveActivity(snapshot(activity: "Writing.", activityKind: .content)) == .thinkingPlaceholder)
        #expect(ZenSubAgentLiveActivity(snapshot(activityKind: .content)) == .thinkingPlaceholder)
        // Nothing else to show: queued, or a tool the transcript hides.
        #expect(ZenSubAgentLiveActivity(snapshot(status: .queued)) == .thinkingPlaceholder)
        #expect(ZenSubAgentLiveActivity(snapshot(toolName: "agent.message")) == .thinkingPlaceholder)
        // A running tool has its row in the transcript: nothing, while
        // reasoning too.
        #expect(ZenSubAgentLiveActivity(snapshot(toolName: "local.exec")) == .none)
        #expect(ZenSubAgentLiveActivity(snapshot(
            activity: "Reading the output.", activityKind: .thinking, toolName: "local.exec"
        )) == .none)
        // Not pending, or no snapshot: nothing.
        #expect(ZenSubAgentLiveActivity(snapshot(
            status: .idle, activity: "Old thought", activityKind: .thinking, output: "Done."
        )) == .none)
        #expect(ZenSubAgentLiveActivity(snapshot(status: .failed)) == .none)
        #expect(ZenSubAgentLiveActivity(nil) == .none)
    }
}
