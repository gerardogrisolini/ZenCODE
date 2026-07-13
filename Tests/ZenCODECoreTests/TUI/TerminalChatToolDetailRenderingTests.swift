//
//  TerminalChatRenderingTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/05/26.
//

import Foundation
import Testing
@testable import ZenCODECore

extension TerminalChatRenderingTests {
    @Test
    func fileChangeSummaryRenderingUsesDistinctHeaderAndSpacing() {
        let summary = TurnFileChangeSummary(
            entries: [
                TurnFileChangeSummary.Entry(
                    path: "Sources/App.swift",
                    additions: 12,
                    deletions: 2,
                    status: .modified,
                    isBinary: false,
                    existedBefore: true,
                    beforeDataBase64: Data("before".utf8).base64EncodedString(),
                    patch: nil
                )
            ]
        )

        let rendered = TerminalChat.renderFileChangeSummary(summary)

        #expect(rendered.hasPrefix("\nSummary: 1 file  +12 -2\n"))
        #expect(rendered.contains("  modified Sources/App.swift  +12 -2\n"))
        #expect(rendered.contains("Use /undo to revert, /changes diff to show patches.\n"))
    }

    @Test
    func fileChangeSummaryColoringHighlightsNonBlankLines() {
        let rendered = TerminalChat.fileChangeSummaryColorApplied(
            to: "\nChanged files: 1 modified file  +12 -2\n  modified Sources/App.swift  +12 -2\nUse /undo to revert, /changes diff to show patches.\n",
            isEnabled: true
        )

        #expect(rendered.hasPrefix("\n\u{1B}[38;5;250mChanged files: 1 modified file  +12 -2\u{1B}[0m"))
        #expect(rendered.contains("1 modified file"))
        #expect(rendered.contains("\u{1B}[38;5;114m+12\u{1B}[0m"))
        #expect(rendered.contains("\u{1B}[38;5;203m-2\u{1B}[0m"))
        #expect(rendered.contains("\u{1B}[38;5;244mmodified\u{1B}[0m \u{1B}[97mSources/App.swift\u{1B}[0m"))
        #expect(rendered.contains("\u{1B}[38;5;81m/undo\u{1B}[0m\u{1B}[38;5;250m"))
        #expect(rendered.contains("\u{1B}[38;5;81m/changes diff\u{1B}[0m\u{1B}[38;5;250m"))
        #expect(rendered.hasSuffix("\n"))
    }

    @Test
    func fileChangeDiffPatchRenderingColorsUnifiedDiffLines() {
        let patch = """
        diff --git a/Sources/App.swift b/Sources/App.swift
        index 1111111..2222222 100644
        --- a/Sources/App.swift
        +++ b/Sources/App.swift
        @@ -1,2 +1,2 @@
         context
        -old
        +new
        """

        let rendered = TerminalChat.renderFileChangeDiffPatch(patch, isEnabled: true)

        #expect(rendered.contains("\u{1B}[38;5;244mdiff --git a/Sources/App.swift b/Sources/App.swift\u{1B}[0m"))
        #expect(rendered.contains("\u{1B}[38;5;141m@@ -1,2 +1,2 @@\u{1B}[0m"))
        #expect(rendered.contains("\u{1B}[38;5;203m-old\u{1B}[0m"))
        #expect(rendered.contains("\u{1B}[38;5;114m+new\u{1B}[0m"))
        #expect(rendered.contains(" context"))
    }

    @Test
    func fileChangeDiffPatchRenderingKeepsAllLines() {
        let patch = (0..<520)
            .map { "+line \($0)" }
            .joined(separator: "\n")

        let rendered = TerminalChat.renderFileChangeDiffPatch(patch, isEnabled: false)
        let renderedLines = rendered.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(renderedLines.count == 520)
        #expect(renderedLines.last == "+line 519")
    }

    @Test
    func compactEditToolLinesIncludeFileTarget() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.editFile",
            argumentsObject: [
                "file_path": "Sources/App.swift",
                "oldString": "old",
                "newString": "new"
            ],
            argumentsJSON: #"{"file_path":"Sources/App.swift","oldString":"old","newString":"new"}"#
        )

        let lines = TerminalChat.compactToolLines(for: toolCall, statusIcon: "⏳")

        #expect(lines.contains("🛠️  local.editFile:"))
        #expect(lines.contains { $0.contains("Sources/App.swift") })
    }

//    @Test
//    func toolIconsFollowConfiguredFamilies() {
//        #expect(ZenCODEACPBridge.toolIcon(for: "local.exec") == "💻")
//        #expect(ZenCODEACPBridge.toolIcon(for: "local.readFile") == "📄")
//        #expect(ZenCODEACPBridge.toolIcon(for: "local.editFile") == "✏️")
//        #expect(ZenCODEACPBridge.toolIcon(for: "local.delete") == "🗑️")
//        #expect(ZenCODEACPBridge.toolIcon(for: "local.move") == "↔️")
//        #expect(ZenCODEACPBridge.toolIcon(for: "memory.read") == "🧠")
//        #expect(ZenCODEACPBridge.toolIcon(for: "agent.create") == "👥")
//        #expect(ZenCODEACPBridge.toolIcon(for: "tasks.create") == "👥")
//        #expect(ZenCODEACPBridge.toolIcon(for: "git.diff") == "🔀")
//        #expect(ZenCODEACPBridge.toolIcon(for: "web.fetch") == "🌐")
//        #expect(ZenCODEACPBridge.toolIcon(for: "search.grep") == "🔎")
//        #expect(ZenCODEACPBridge.toolIcon(for: "xcode.BuildProject") == "🛠️")
//        #expect(ZenCODEACPBridge.toolIcon(for: "figma.get") == "🎨")
//        #expect(ZenCODEACPBridge.toolIcon(for: "jira.search") == "📋")
//        #expect(ZenCODEACPBridge.toolIcon(for: "unknown.tool") == "🔨")
//    }

    @Test
    func compactToolTerminalTextDoesNotInsertBlankRows() {
        let rendered = TerminalChat.compactToolTerminalText(
            ["🛠️  Read:", "Sources/App.swift ⏳"],
            lineInset: " "
        )

        #expect(rendered.hasPrefix("\r\u{1B}[2K "))
        #expect(!rendered.hasPrefix("\n"))
        #expect(!rendered.contains("\n\n"))
        #expect(rendered.contains("\n\r\u{1B}[2K "))
        #expect(rendered.hasSuffix("\u{1B}[0m\n"))
    }

    @Test
    func compactToolStatusIconStaysImmediatelyAfterText() {
        let rendered = TerminalChat.compactToolStatusLine(
            target: "/tmp/generated-feature/Sources/Feature/main.swift",
            statusIcon: "✅",
            contentInsetWidth: 0
        )

        #expect(rendered.hasSuffix(" ✅"))
        #expect(!rendered.contains("  ✅"))
    }

    @Test
    func compactExecToolLinesCollapseMultilineCommand() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.exec",
            argumentsObject: [
                "command": """
                python3 - <<'PY'
                from pathlib import Path
                path = Path('Tests/ZenCODECoreTests/RemoteSessionSnapshotTests.swift')
                print(path)
                PY
                """
            ],
            argumentsJSON: "{}"
        )

        let lines = TerminalChat.compactToolLines(for: toolCall, statusIcon: "✅")

        #expect(lines.count == 2)
        #expect(lines[0] == "🛠️  local.exec:")
        #expect(lines[1].contains("python3 - <<'PY' from pathlib import Path"))
        #expect(!lines[1].contains("\n"))
        #expect(lines[1].hasSuffix(" ✅"))
    }

    @Test
    func detailedReplaceCompletionShowsSnippetsAsCodeLines() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.editFile",
            argumentsObject: [
                "path": "Sources/App.swift",
                "oldString": "let oldValue = 1",
                "newString": "let newValue = 2"
            ],
            argumentsJSON: #"{"path":"Sources/App.swift","oldString":"let oldValue = 1","newString":"let newValue = 2"}"#
        )

        let lines = TerminalChat.detailedToolCallCompletedLines(
            for: toolCall,
            result: DirectAgentToolResult(output: "", summary: "ok")
        )

        #expect(lines.contains("old:"))
        #expect(lines.contains("  let oldValue = 1"))
        #expect(lines.contains("new:"))
        #expect(lines.contains("  let newValue = 2"))
    }

    @Test
    func detailedToolStartOmitsRawInputButKeepsDetails() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.readFile",
            argumentsObject: [
                "path": "/tmp/project/Sources/App.swift"
            ],
            argumentsJSON: #"{"path":"/tmp/project/Sources/App.swift"}"#
        )

        let lines = TerminalChat.detailedToolCallStartedLines(for: toolCall)

        #expect(lines.contains("🛠️  local.readFile /tmp/project/Sources/App.swift"))
        #expect(lines.contains("status: ⏳"))
        #expect(lines.last == "status: ⏳")
        #expect(lines.contains("kind: read"))
        #expect(lines.contains("location: /tmp/project/Sources/App.swift"))
        #expect(!lines.contains("rawInput:"))
        #expect(!lines.contains { $0.contains("call_1") })
    }

    @Test
    func detailedReadCompletionOmitsRawOutputButKeepsSummaryDetail() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.readFile",
            argumentsObject: [
                "path": "/tmp/project/Sources/App.swift"
            ],
            argumentsJSON: #"{"path":"/tmp/project/Sources/App.swift"}"#
        )
        let result = DirectAgentToolResult(
            output: "1\tlet value = 1\n2\tlet second = 2",
            summary: "1\tlet value = 1"
        )

        let lines = TerminalChat.detailedToolCallCompletedLines(
            for: toolCall,
            result: result
        )

        #expect(lines.contains("status: ✅"))
        #expect(lines.last == "status: ✅")
        #expect(lines.contains("kind: read"))
        #expect(lines.contains("summary: read 2 lines"))
        #expect(!lines.contains("rawOutput.output:"))
        #expect(!lines.contains("let value = 1"))
    }

    @Test
    func detailedReadFilesCompletionCountsPayloadLinesAcrossFiles() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.readFiles",
            argumentsObject: [
                "paths": ["/tmp/project/First.swift", "/tmp/project/Second.swift"]
            ],
            argumentsJSON: #"{"paths":["/tmp/project/First.swift","/tmp/project/Second.swift"]}"#
        )
        let result = DirectAgentToolResult(
            output: """
            ===== /tmp/project/First.swift =====
            1\tlet first = 1
            2\tlet second = 2

            ===== /tmp/project/Second.swift =====
            1\tlet third = 3

            ===== /tmp/project/Missing.swift =====
            <error: file not found>
            """,
            summary: "===== /tmp/project/First.swift ====="
        )

        let lines = TerminalChat.detailedToolCallCompletedLines(
            for: toolCall,
            result: result
        )

        #expect(lines.contains("summary: read 3 lines"))
    }

    @Test
    func detailedHeadCompletionUsesSingularLineCount() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "text.head",
            argumentsObject: ["path": "/tmp/project/README.md", "lines": 1],
            argumentsJSON: #"{"path":"/tmp/project/README.md","lines":1}"#
        )
        let result = DirectAgentToolResult(
            output: "File: /tmp/project/README.md\n1\t# Project",
            summary: "File: /tmp/project/README.md"
        )

        let lines = TerminalChat.detailedToolCallCompletedLines(
            for: toolCall,
            result: result
        )

        #expect(lines.contains("summary: read 1 line"))
    }

    @Test
    func detailedCompletionUsesPermissionDeniedStatusForErrors() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "xcode.BuildProject",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(
            output: "Consent denied",
            summary: "Consent denied",
            status: .permissionDenied
        )

        let lines = TerminalChat.detailedToolCallCompletedLines(
            for: toolCall,
            result: result
        )

        #expect(lines.contains("error:"))
        #expect(lines.contains("  Consent denied"))
        #expect(lines.last == "status: ⚠️")
    }

    @Test
    func detailedWriteCompletionShowsAppliedChangeSnippet() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.writeFile",
            argumentsObject: [
                "file_path": "/tmp/project/Sources/App.swift",
                "content": "struct App {\n    let value = 1\n}"
            ],
            argumentsJSON: "{}"
        )
        let result = DirectAgentToolResult(
            output: "Wrote /tmp/project/Sources/App.swift",
            summary: "Wrote file"
        )

        let lines = TerminalChat.detailedToolCallCompletedLines(
            for: toolCall,
            result: result
        )

        #expect(lines.contains("change: write /tmp/project/Sources/App.swift"))
        #expect(lines.contains("content:"))
        #expect(lines.contains("  struct App {"))
        #expect(lines.contains("      let value = 1"))
        #expect(!lines.contains("rawOutput.summary: Wrote file"))
    }

    func ansiStripped(_ text: String) -> String {
        var output = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            if text[cursor] == "\u{1B}",
               text.index(after: cursor) < text.endIndex,
               text[text.index(after: cursor)] == "[",
               let sequenceEnd = text[cursor...].firstIndex(of: "m") {
                cursor = text.index(after: sequenceEnd)
                continue
            }
            output.append(text[cursor])
            cursor = text.index(after: cursor)
        }
        return output
    }

    @Test
    func detailedReplaceCompletionShowsOldAndNewSnippets() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.replace",
            argumentsObject: [
                "path": "/tmp/project/Sources/App.swift",
                "oldString": "let value = 1",
                "newString": "let value = 2",
                "replaceAll": true
            ],
            argumentsJSON: "{}"
        )

        let lines = TerminalChat.appliedChangeDetailLines(for: toolCall)

        #expect(lines.contains("change: replace /tmp/project/Sources/App.swift"))
        #expect(lines.contains("mode: replace all"))
        #expect(lines.contains("old:"))
        #expect(lines.contains("  let value = 1"))
        #expect(lines.contains("new:"))
        #expect(lines.contains("  let value = 2"))
    }

    @Test
    func expandedLevelAddsCallParameters() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.readFile",
            argumentsObject: [
                "path": "/tmp/project/Sources/App.swift"
            ],
            argumentsJSON: #"{"path":"/tmp/project/Sources/App.swift"}"#
        )

        let expandedLines = TerminalChat.detailedToolCallStartedLines(
            for: toolCall
        )

        #expect(expandedLines.contains("parameters:"))
        #expect(expandedLines.contains { $0.contains("\"path\"") })
        #expect(expandedLines.contains { $0.contains("/tmp/project/Sources/App.swift") })
    }

    @Test
    func expandedCodeAreaLinesUseBackgroundFrameAndLanguageHighlighting() {
        let rendered = TerminalChat.renderDetailedToolLine(
            "  let value = 1",
            codeLanguage: "swift"
        )

        #expect(rendered.hasPrefix("\u{1B}[48;5;236m"))
        #expect(rendered.hasSuffix("\u{1B}[K"))
        // Swift keyword highlighting stays active inside the framed area.
        #expect(rendered.contains("\u{1B}[38;5;141mlet"))
        // Every renderer reset re-anchors the background so token colors do
        // not punch holes in the frame.
        #expect(!rendered.contains("\u{1B}[0m "))
        #expect(ansiStripped(rendered).hasPrefix("  let value = 1"))
    }

    @Test
    func codeLanguageHintUsesTargetFileExtension() {
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.writeFile",
            argumentsObject: [
                "file_path": "/tmp/project/Sources/App.swift",
                "content": "let value = 1"
            ],
            argumentsJSON: "{}"
        )

        #expect(TerminalChat.codeLanguageHint(for: toolCall) == "swift")
    }

    @Test
    func applyPatchParametersRenderPatchAsMultilineBlock() {
        let patch = """
        *** Begin Patch
        *** Update File: Sources/App.swift
        @@
        -old
        +new
        *** End Patch
        """
        let toolCall = DirectAgentToolCall(
            id: "call_1",
            name: "local.applyPatch",
            argumentsObject: [
                "patch": patch
            ],
            argumentsJSON: "{}"
        )

        let lines = TerminalChat.detailedToolCallStartedLines(
            for: toolCall
        )

        #expect(lines.contains("parameters:"))
        #expect(lines.contains { $0.contains("\"patch\": \"\"\"") })
        #expect(lines.contains { $0.contains("*** Begin Patch") })
        #expect(lines.contains { $0.contains("*** End Patch") })
        #expect(!lines.contains { $0.contains(#"\n"#) })
    }
}
