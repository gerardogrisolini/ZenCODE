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

// MARK: - File changes

@Suite("File changes")
struct ZenFileChangeFormattingTests {
    private func entry(
        _ path: String,
        _ additions: Int,
        _ deletions: Int,
        binary: Bool = false,
        patch: String? = nil
    ) -> TurnFileChangeSummary.Entry {
        TurnFileChangeSummary.Entry(
            path: path,
            additions: additions,
            deletions: deletions,
            status: .modified,
            isBinary: binary,
            existedBefore: true,
            beforeDataBase64: nil,
            patch: patch
        )
    }

    @Test("the summary header carries the file count and the line totals")
    func summaryTotals() {
        let summary = TurnFileChangeSummary(entries: [
            entry("a.swift", 3, 1, patch: "@@ -1 +1 @@"),
            entry("b.swift", 2, 4, patch: "@@ -1 +1 @@"),
            entry("logo.png", 0, 0, binary: true)
        ])
        #expect(summary.totalAdditions == 5)
        #expect(summary.totalDeletions == 5)
        #expect(ZenFileChangeFormatting.summaryHeaderText(summary) == "3 files changed  +5 −5")
        let single = TurnFileChangeSummary(entries: [entry("a.swift", 1, 0, patch: "@@ -0,0 +1 @@")])
        #expect(ZenFileChangeFormatting.summaryHeaderText(single) == "1 file changed  +1 −0")
    }

    @Test("the hint offers /undo only when every file can be restored")
    func hint() {
        let undoable = TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "new.swift", additions: 1, deletions: 0, status: .added, isBinary: false,
                existedBefore: false, beforeDataBase64: nil, patch: "@@ -0,0 +1 @@\n+x"
            )
        ])
        #expect(ZenFileChangeFormatting.hintText(undoable) == "Use /undo to revert, /changes diff to show patches.")
        let stuck = TurnFileChangeSummary(entries: [
            TurnFileChangeSummary.Entry(
                path: "a.bin", additions: 0, deletions: 0, status: .modified, isBinary: true,
                existedBefore: true, beforeDataBase64: nil, patch: nil
            )
        ])
        #expect(ZenFileChangeFormatting.hintText(stuck) == "Undo is not available for this summary.")
    }

    @Test("patch lines are classified for coloring")
    func patchLines() {
        let lines = ZenFileChangeFormatting.patchLines(
            "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1,2 +1,2 @@\n keep\n-old\n+new\n\\ No newline at end of file\n"
        )
        #expect(lines.map(\.kind) == [.header, .header, .header, .hunk, .context, .deletion, .addition, .note])
    }

    @Test("an artifact diff comes from the full texts, else from the patch")
    func artifactDiff() {
        let modified = FileChangeArtifact(
            absolutePath: "/p/a.swift", displayPath: "a.swift", status: .modified,
            additions: 1, deletions: 1, oldText: "a\nb\n", newText: "a\nc\n"
        )
        guard case let .hunks(hunks) = ZenFileChangeFormatting.artifactDiff(modified) else {
            Issue.record("expected hunks")
            return
        }
        #expect(hunks.flatMap { $0 }.map(\.kind) == [.context, .deletion, .addition])

        let patched = FileChangeArtifact(
            absolutePath: "/p/b.swift", displayPath: "", status: .modified, patch: "@@ -1 +1 @@\n-x\n+y"
        )
        #expect(ZenFileChangeFormatting.artifactDiff(patched) == .patch([
            ZenPatchLine(kind: .hunk, text: "@@ -1 +1 @@"),
            ZenPatchLine(kind: .deletion, text: "-x"),
            ZenPatchLine(kind: .addition, text: "+y")
        ]))
        #expect(ZenFileChangeFormatting.displayPath(of: patched) == "/p/b.swift")

        // Missing evidence is not an empty file.
        let unknown = FileChangeArtifact(absolutePath: "/p/c", displayPath: "c", status: .modified, newText: "x")
        #expect(ZenFileChangeFormatting.artifactDiff(unknown) == nil)
        let binary = FileChangeArtifact(absolutePath: "/p/d", displayPath: "d", status: .added, isBinary: true, newText: "x")
        #expect(ZenFileChangeFormatting.artifactDiff(binary) == nil)
    }
}

// MARK: - Text helpers

@Suite("Transcript text")
struct ZenTranscriptTextTests {
    @Test("only prompts from other channels get a badge")
    func originBadges() {
        #expect(ZenTranscriptText.originBadge(for: .app) == nil)
        #expect(ZenTranscriptText.originBadge(for: .telegram)?.title == "Telegram")
        #expect(ZenTranscriptText.originBadge(for: .acp)?.title == "ACP")
        #expect(ZenTranscriptText.originBadge(for: .unknown)?.title == "Restored")
        #expect(ZenTranscriptText.originBadge(for: .local)?.title == "Terminal")
    }

    @Test("a command line splits into its token and its arguments")
    func commandToken() {
        #expect(ZenTranscriptText.commandToken(in: "/tasks show  build ") == ZenCommandToken(command: "/tasks", arguments: "show  build"))
        #expect(ZenTranscriptText.commandToken(in: "/help") == ZenCommandToken(command: "/help", arguments: ""))
        #expect(ZenTranscriptText.commandToken(in: "hello /tasks") == nil)
        #expect(ZenTranscriptText.commandToken(in: "/") == nil)
    }

    @Test("the home directory is abbreviated with a tilde")
    func abbreviatedPath() {
        #expect(ZenTranscriptText.abbreviatedPath("/Users/me/Projects/Zen", homeDirectory: "/Users/me") == "~/Projects/Zen")
        #expect(ZenTranscriptText.abbreviatedPath("/Users/me", homeDirectory: "/Users/me/") == "~")
        #expect(ZenTranscriptText.abbreviatedPath("/Users/meta/x", homeDirectory: "/Users/me") == "/Users/meta/x")
        #expect(ZenTranscriptText.abbreviatedPath("/tmp/x", homeDirectory: "/Users/me") == "/tmp/x")
    }

    @Test("parameters become sorted key/value rows")
    func parameterRows() {
        let rows = ZenToolCallFormatting.parameterRows(for: .object([
            "path": .string("a.swift"),
            "count": .number(3),
            "flags": .array([.bool(true), .null])
        ]))
        #expect(rows == [
            ZenToolParameterRow(key: "count", value: "3"),
            ZenToolParameterRow(key: "flags", value: "[true,null]"),
            ZenToolParameterRow(key: "path", value: "a.swift")
        ])
        #expect(ZenToolCallFormatting.parameterRows(for: .string("x"), label: "query") == [
            ZenToolParameterRow(key: "query", value: "x")
        ])
    }

    @Test("collapsed thoughts preview their first non-blank line")
    func firstLinePreview() {
        #expect(ZenTranscriptText.firstLinePreview("\n  \nFirst   idea\nsecond") == "First idea")
        #expect(ZenTranscriptText.firstLinePreview("   ") == nil)
    }

    @Test("the default Markdown renderer is installed in the environment")
    @MainActor
    func defaultRenderer() {
        let values = EnvironmentValues()
        _ = values.zenMarkdownRenderer.render("**bold**", isStreaming: false)
        var custom = EnvironmentValues()
        custom.zenMarkdownRenderer = ZenMarkdownRenderer { text, isStreaming in
            AnyView(Text(isStreaming ? text + "…" : text))
        }
        _ = custom.zenMarkdownRenderer.render("text", isStreaming: true)
    }
}
