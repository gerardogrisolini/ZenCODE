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

        #expect(rendered.hasPrefix("\n🪬 Summary: 1 file  +12 -2\n"))
        #expect(rendered.contains("  modified Sources/App.swift  +12 -2\n"))
        #expect(rendered.contains("Use /undo to revert, /changes diff to show patches.\n"))
    }

    @Test
    func fileChangeSummaryColoringHighlightsNonBlankLines() {
        let rendered = TerminalChatTextFormatting.fileChangeSummaryColorApplied(
            to: "\n🪬 Summary: 1 modified file  +12 -2\n  modified Sources/App.swift  +12 -2\nUse /undo to revert, /changes diff to show patches.\n",
            isEnabled: true
        )

        #expect(rendered.hasPrefix("\n\u{1B}[1;38;5;220m🪬 Summary:\u{1B}[0m "))
        #expect(rendered.contains("\u{1B}[38;5;81m1\u{1B}[0m\u{1B}[97m modified file\u{1B}[0m"))
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
    func compactToolStatusLineHonorsNarrowActualColumnBudget() {
        let rendered = TerminalChat.compactToolStatusLine(
            target: "abcdef",
            statusIcon: "✅",
            contentInsetWidth: 0,
            columnWidth: 6
        )

        // One trailing cell remains deliberately unused for safe in-place
        // rewrites, so the content budget is five columns rather than six.
        #expect(rendered == "ab ✅")
        #expect(TerminalChat.displayWidth(rendered) == 5)

        let statusOnly = TerminalChat.compactToolStatusLine(
            target: "abcdef",
            statusIcon: "✅",
            contentInsetWidth: 0,
            columnWidth: 3
        )
        #expect(statusOnly == "✅")
        #expect(TerminalChat.displayWidth(statusOnly) == 2)
    }

    @Test
    func fitDisplayWidthUsesWidthAwareFallbackWhenEllipsisCannotFit() {
        #expect(TerminalChat.fitDisplayWidth("abcdef", width: 3) == "abc")
        #expect(TerminalChat.fitDisplayWidth("😀abcdef", width: 2) == "😀")
        #expect(TerminalChat.fitDisplayWidth("😀abcdef", width: 1).isEmpty)
        #expect(TerminalChat.fitDisplayWidth("abcdef", width: 0).isEmpty)
        #expect(TerminalChat.fitDisplayWidth("abcdef", width: -1).isEmpty)
    }

    @Test
    func detailedToolWrappingCapsWideGlyphAfterHangingIndent() {
        let rows = TerminalChat.safelyWrappedDetailedToolLines(
            ["    a😀"],
            contentInsetWidth: 0,
            columnWidth: 6
        )

        #expect(rows == ["    a", "   😀"])
        #expect(rows.allSatisfy { TerminalChat.displayWidth($0) <= 5 })
    }

    @Test
    func indentedSnippetsDoNotMarkTrimmedTerminalNewlineAsTruncated() {
        let normal = TerminalChat.indentedSnippet("line\n")
        let preservingIndentation = TerminalChat.indentedSnippetPreservingIndentation("  line\n")

        #expect(normal == ["  line"])
        #expect(preservingIndentation == ["    line"])
        #expect(!normal.contains("  ... truncated"))
        #expect(!preservingIndentation.contains("  ... truncated"))
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
    func detailedReplaceCompletionShowsNumberedSideBySideCodeLines() {
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
            result: DirectAgentToolResult(output: "", summary: "ok"),
            contentWidth: 88
        )

        #expect(lines.contains { $0.contains("old") && $0.contains("new") })
        #expect(lines.contains { $0.contains("1 │ let oldValue = 1") && $0.contains("1 │ let newValue = 2") })
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
        #expect(lines.contains("  1 │ struct App {"))
        #expect(lines.contains("  2 │     let value = 1"))
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
    func detailedReplaceCompletionShowsOldAndNewNumberedSnippets() {
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

        let lines = TerminalChat.appliedChangeDetailLines(for: toolCall, contentWidth: 88)

        #expect(lines.contains("change: replace /tmp/project/Sources/App.swift"))
        #expect(lines.contains("mode: replace all"))
        #expect(lines.contains { $0.contains("old") && $0.contains("new") })
        #expect(lines.contains { $0.contains("1 │ let value = 1") && $0.contains("1 │ let value = 2") })
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
    func applyPatchDetailsHideRawParametersUntilNumberedChangeIsAvailable() {
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

        #expect(lines.contains("change: pending"))
        #expect(!lines.contains("parameters:"))
        #expect(!lines.contains { $0.contains("*** Begin Patch") })
    }

    @Test
    func expandedWriteNumbersEveryContentLineAndKeepsSwiftHighlighting() throws {
        let toolCall = DirectAgentToolCall(
            id: "write",
            name: "local.writeFile",
            argumentsObject: [
                "file_path": "Sources/Feature.swift",
                "content": "let first = 1\nlet second = 2"
            ],
            argumentsJSON: "{}"
        )

        let lines = TerminalChat.appliedChangeDetailLines(for: toolCall, contentWidth: 80)
        let firstCodeLine = try #require(lines.first { $0.contains("1 │ let first = 1") })
        let secondCodeLine = try #require(lines.first { $0.contains("2 │ let second = 2") })
        let rendered = TerminalChat.renderDetailedToolLine(
            firstCodeLine,
            codeLanguage: TerminalChat.codeLanguageHint(for: toolCall)
        )

        #expect(firstCodeLine.hasPrefix("  1 │"))
        #expect(secondCodeLine.hasPrefix("  2 │"))
        #expect(rendered.hasPrefix("\u{1B}[48;5;236m"))
        #expect(rendered.contains("\u{1B}[38;5;141mlet"))
        #expect(rendered.hasSuffix("\u{1B}[K"))
    }

    @Test
    func expandedReplacePairsDiffRowsWithinWideTerminalBudget() {
        let lines = TerminalChat.numberedDiffSnippetLines(
            old: "let stable = 0\nlet previous = 1",
            new: "let stable = 0\nlet replacement = 2",
            contentWidth: 80
        )

        #expect(lines.first?.contains("old") == true)
        #expect(lines.first?.contains("new") == true)
        #expect(lines.contains {
            $0.contains("2 │ let previous = 1")
                && $0.contains("2 │ let replacement = 2")
        })
        #expect(lines.allSatisfy { TerminalChat.displayWidth($0) <= 80 })
    }

    @Test
    func expandedReplaceFallsBackToWrappedVerticalDiffOnNarrowTerminal() {
        let lines = TerminalChat.numberedDiffSnippetLines(
            old: "let previousValue = aVeryLongIdentifier",
            new: "let replacementValue = anotherLongIdentifier",
            contentWidth: 40
        )
        let wrapped = TerminalChat.safelyWrappedDetailedToolLines(
            lines,
            contentInsetWidth: 0,
            columnWidth: 41
        )

        #expect(lines.contains("old:"))
        #expect(lines.contains("new:"))
        #expect(!lines.contains { $0.contains("old") && $0.contains("new") })
        #expect(wrapped.contains { $0.contains("1 │ let previousValue") })
        #expect(wrapped.contains { $0.contains("1 │ let replacementValue") })
        #expect(wrapped.allSatisfy { TerminalChat.displayWidth($0) <= 40 })
    }

    @Test
    func expandedMutationSnippetsPreserveEmptyWhitespaceAndTrailingNewlines() {
        #expect(
            TerminalChat.stringArgument(["content": ""], keys: ["content"])
                == ""
        )
        #expect(
            TerminalChat.stringArgument(["content": "   "], keys: ["content"])
                == "   "
        )
        // Emptiness is structural: the marker occupies the gutter position
        // without a line number, so it cannot collide with a numbered source
        // line whose literal content is the marker text.
        #expect(TerminalChat.numberedCodeSnippetLines("") == ["    │ <empty>"])
        #expect(TerminalChat.numberedCodeSnippetLines("<empty>") == ["  1 │ <empty>"])
        #expect(
            TerminalChat.numberedCodeSnippetLines("")
                != TerminalChat.numberedCodeSnippetLines("<empty>")
        )
        #expect(TerminalChat.numberedCodeSnippetLines("line\n") == [
            "  1 │ line",
            "  2 │ "
        ])

        let deletion = TerminalChat.numberedDiffSnippetLines(
            old: "  retained whitespace",
            new: "",
            contentWidth: 80
        )
        let whitespaceOnly = TerminalChat.numberedDiffSnippetLines(
            old: "  ",
            new: " ",
            contentWidth: 80
        )

        #expect(deletion.contains { $0.contains("1 │   retained whitespace") })
        #expect(deletion.contains { $0.contains("│ <empty>") && !$0.contains("1 │ <empty>") })
        // The distinct source strings survive the LCS input and remain paired
        // as a change rather than being de-indented into equality.
        #expect(whitespaceOnly.contains { $0.contains("1 │   ") })
        #expect(whitespaceOnly.count == 2)
    }

    @Test
    func expandedEmptyPayloadStaysDistinctFromLiteralEmptyMarker() {
        // A payload whose literal text is the marker must not be represented
        // like an actually empty payload, and a diff between the two must show
        // a change rather than appearing unmodified.
        let emptyToLiteral = TerminalChat.numberedDiffSnippetLines(
            old: "",
            new: "<empty>",
            contentWidth: 80
        )
        let literalToEmpty = TerminalChat.numberedDiffSnippetLines(
            old: "<empty>",
            new: "",
            contentWidth: 80
        )

        // The empty side is reported in the unnumbered structural row; the
        // literal side keeps its line number.
        #expect(emptyToLiteral.contains { $0.contains("1 │ <empty>") })
        #expect(emptyToLiteral.contains { row in
            guard let markerIndex = row.range(of: "│ <empty>") else {
                return false
            }
            return !row[..<markerIndex.lowerBound].contains("1")
        })
        #expect(emptyToLiteral != literalToEmpty)

        // Both directions render a change: no row pairs the two sides as equal.
        let unchangedPairing = emptyToLiteral.contains { row in
            row.components(separatedBy: "<empty>").count == 3
        }
        #expect(!unchangedPairing)

        // An empty-to-empty payload has no numbered line at all.
        let emptyToEmpty = TerminalChat.numberedDiffSnippetLines(
            old: "",
            new: "",
            contentWidth: 80
        )
        #expect(!emptyToEmpty.contains { $0.contains("1 │") })
        #expect(emptyToEmpty.contains { $0.contains("<empty>") })
    }

    @Test
    func expandedSnippetsNormalizeCRLFAndExpandTabsWithinWidthBudget() {
        let codeLines = TerminalChat.numberedCodeSnippetLines(
            "let first = 1\r\n\tlet second = 2\r\n"
        )
        let diffLines = TerminalChat.numberedDiffSnippetLines(
            old: "\tlet old = 1\r\nlet stable = \"東京\"",
            new: "\tlet new = 2\r\nlet stable = \"東京\"",
            contentWidth: 80
        )

        #expect(codeLines == [
            "  1 │ let first = 1",
            "  2 │     let second = 2",
            "  3 │ "
        ])
        #expect((codeLines + diffLines).allSatisfy { !$0.contains("\r") && !$0.contains("\t") })
        #expect(diffLines.allSatisfy { TerminalChat.displayWidth($0) <= 80 })
    }

    @Test
    func expandedDiffTruncatesUnicodeAtCellBoundaries() {
        let lines = TerminalChat.numberedDiffSnippetLines(
            old: "let old = \(String(repeating: "😀", count: 24))",
            new: "let new = \(String(repeating: "東京", count: 24))",
            contentWidth: 80
        )

        #expect(lines.contains { $0.contains("…") })
        #expect(lines.allSatisfy { TerminalChat.displayWidth($0) <= 80 })
    }

    @Test
    func expandedDiffHighlightsEachColumnIndependently() throws {
        let rows = TerminalChat.numberedDiffSnippetRows(
            old: "// removed comment",
            new: "let addedValue = 1",
            contentWidth: 80
        )
        let diffRow = try #require(rows.first {
            $0.plainText.contains("// removed comment")
                && $0.plainText.contains("let addedValue = 1")
        })
        let rendered = TerminalChat.renderDetailedToolRow(
            diffRow,
            codeLanguage: "swift"
        )

        #expect(TerminalANSIText.stripANSI(rendered).contains("// removed comment"))
        #expect(TerminalANSIText.stripANSI(rendered).contains("let addedValue = 1"))
        // This keyword appears after an old-side comment. Its syntax color
        // proves the new cell was tokenized independently.
        #expect(rendered.contains("\u{1B}[38;5;141mlet"))
    }

    @Test
    func expandedAppendAndApplyPatchUseNumberedTerminalSafeSnippets() {
        let append = DirectAgentToolCall(
            id: "append",
            name: "local.append",
            argumentsObject: [
                "path": "Sources/Feature.swift",
                "content": "\tlet appended = true"
            ],
            argumentsJSON: "{}"
        )
        let patch = DirectAgentToolCall(
            id: "patch",
            name: "local.applyPatch",
            argumentsObject: [
                "patch": "*** Begin Patch\r\n+\tlet patched = true\r\n*** End Patch"
            ],
            argumentsJSON: "{}"
        )

        let appendLines = TerminalChat.appliedChangeDetailLines(for: append, contentWidth: 80)
        let patchLines = TerminalChat.appliedChangeDetailLines(for: patch, contentWidth: 80)

        #expect(appendLines.contains("appended:"))
        #expect(appendLines.contains("  1 │     let appended = true"))
        #expect(patchLines.contains { $0.contains("1 │ *** Begin Patch") })
        #expect(patchLines.contains { $0.contains("2 │ +   let patched = true") })
        #expect((appendLines + patchLines).allSatisfy { !$0.contains("\r") && !$0.contains("\t") })
        #expect(TerminalChat.shouldHideParameterLines(for: append.name))
        #expect(TerminalChat.shouldHideParameterLines(for: patch.name))
    }

    @Test
    func expandedMultiEditAndXcodeAliasesUseNumberedDiffPreparation() {
        let multiEdit = DirectAgentToolCall(
            id: "multi",
            name: "local.multiEdit",
            argumentsObject: [
                "path": "Sources/Feature.swift",
                "edits": [[
                    "oldString": "let old = 1",
                    "newString": "let new = 2"
                ]]
            ],
            argumentsJSON: "{}"
        )

        let multiLines = TerminalChat.appliedChangeDetailLines(for: multiEdit, contentWidth: 80)

        #expect(multiLines.contains("edit 1:"))
        #expect(multiLines.contains { $0.contains("1 │ let old = 1") && $0.contains("1 │ let new = 2") })

        for name in ["XcodeWrite", "xcode.XcodeWrite", "xcode.write"] {
            let toolCall = DirectAgentToolCall(
                id: "write-\(name)",
                name: name,
                argumentsObject: [
                    "filePath": "Sources/Feature.swift",
                    "content": "let written = true"
                ],
                argumentsJSON: "{}"
            )
            let lines = TerminalChat.appliedChangeDetailLines(for: toolCall, contentWidth: 80)
            #expect(TerminalChat.shouldHideParameterLines(for: name))
            #expect(lines.contains("  1 │ let written = true"))
        }

        for name in ["XcodeUpdate", "xcode.XcodeUpdate", "xcode.update", "xcode.edit"] {
            let toolCall = DirectAgentToolCall(
                id: "update-\(name)",
                name: name,
                argumentsObject: [
                    "filePath": "Sources/Feature.swift",
                    "oldString": "let before = false",
                    "newString": "let after = true"
                ],
                argumentsJSON: "{}"
            )
            let lines = TerminalChat.appliedChangeDetailLines(for: toolCall, contentWidth: 80)
            #expect(TerminalChat.shouldHideParameterLines(for: name))
            #expect(lines.contains { $0.contains("1 │ let before = false") && $0.contains("1 │ let after = true") })
        }
    }

    // MARK: - Robustness regressions

    @Test
    func expandedMetadataNeutralizesControlSequencesEndToEnd() {
        // Every caller-controllable path reaches the terminal through the same
        // sanitization point: title, location, change rows and language hint.
        let hostilePath = "Sources/\u{1B}[2J\u{9B}31m\u{200B}App\u{7F}.swift"
        let toolCall = DirectAgentToolCall(
            id: "hostile-path",
            name: "local.writeFile",
            argumentsObject: [
                "path": hostilePath,
                "content": "let value = 1"
            ],
            argumentsJSON: "{}"
        )

        let startedLines = TerminalChat.detailedToolCallStartedLines(for: toolCall)
        let completedLines = TerminalChat.detailedToolCallCompletedLines(
            for: toolCall,
            result: DirectAgentToolResult(output: "", summary: "written"),
            contentWidth: 80
        )
        let metadataLines = startedLines + completedLines.filter { !$0.hasPrefix("  ") }

        for line in metadataLines {
            #expect(!line.contains("\u{1B}"))
            #expect(!line.contains("\u{9B}"))
            #expect(!line.contains("\r"))
            #expect(!line.contains("\n"))
            #expect(!line.contains("\t"))
            #expect(!line.contains("\u{7F}"))
            #expect(!line.contains("\u{200B}"))
        }
        #expect(startedLines.contains { $0.hasPrefix("location: ") })
        #expect(completedLines.contains { $0.hasPrefix("change: write ") })
        #expect(TerminalChat.codeLanguageHint(for: toolCall) == "swift")
    }

    @Test
    func expandedPatchTargetIsSanitizedInChangeRowAndLanguageHint() {
        // The patch target is derived from the fully caller-controlled patch
        // body, so it must be neutralized like any other metadata.
        let toolCall = DirectAgentToolCall(
            id: "hostile-patch",
            name: "local.applyPatch",
            argumentsObject: [
                "patch": "*** Update File: Sources/\u{1B}[2JInjected\u{200E}.swift\n@@\n-a\n+b\n"
            ],
            argumentsJSON: "{}"
        )

        let changeRow = TerminalChat
            .appliedChangeDetailLines(for: toolCall, contentWidth: 80)
            .first
        let sanitizedTarget = TerminalChat.patchTargetPath(toolCall.argumentsObject)

        #expect(changeRow?.hasPrefix("change: patch ") == true)
        #expect(changeRow?.contains("\u{1B}") == false)
        #expect(changeRow?.contains("\u{200E}") == false)
        #expect(sanitizedTarget?.contains("\u{1B}") == false)
        #expect(TerminalChat.codeLanguageHint(for: toolCall) == "swift")

        // A patch whose only target neutralizes to blank falls back rather than
        // rendering an empty or hostile target.
        let blankTarget = DirectAgentToolCall(
            id: "blank-patch",
            name: "local.applyPatch",
            argumentsObject: ["patch": "*** Update File: \u{1B}\n"],
            argumentsJSON: "{}"
        )
        #expect(
            TerminalChat.appliedChangeDetailLines(for: blankTarget, contentWidth: 80).first
                == "change: patch file"
        )
        #expect(TerminalChat.codeLanguageHint(for: blankTarget) == nil)
    }

    @Test
    func xcodeRemoveAndMoveAliasesMatchRuntimeRoutingWithoutClassifyingBareNames() {
        for name in ["XcodeRM", "xcode.XcodeRM", "xcode.rm", "xcode_rm", "xcodeRM"] {
            let toolCall = DirectAgentToolCall(
                id: "rm-\(name)",
                name: name,
                argumentsObject: ["path": "Sources/Legacy.swift"],
                argumentsJSON: "{}"
            )
            #expect(TerminalChat.normalizedMutationToolName(name) == "XcodeRM")
            #expect(TerminalChat.isFileMutationTool(name))
            #expect(
                TerminalChat.appliedChangeDetailLines(for: toolCall, contentWidth: 80)
                    == ["change: delete Sources/Legacy.swift"]
            )
        }

        for name in ["XcodeMV", "xcode.XcodeMV", "xcode.mv", "xcode_mv", "xcodeMV"] {
            let toolCall = DirectAgentToolCall(
                id: "mv-\(name)",
                name: name,
                argumentsObject: [
                    "sourcePath": "Sources/Old.swift",
                    "destinationPath": "Sources/New.swift"
                ],
                argumentsJSON: "{}"
            )
            #expect(TerminalChat.normalizedMutationToolName(name) == "XcodeMV")
            #expect(TerminalChat.isFileMutationTool(name))
            #expect(
                TerminalChat.appliedChangeDetailLines(for: toolCall, contentWidth: 80)
                    == [
                        "change: move",
                        "from: Sources/Old.swift",
                        "to: Sources/New.swift"
                    ]
            )
        }

        // Bare names from unrelated MCP servers must stay unclassified.
        for name in ["rm", "mv", "write", "update", "edit"] {
            #expect(TerminalChat.normalizedMutationToolName(name) == name)
            #expect(!TerminalChat.isFileMutationTool(name))
        }
    }

    @Test
    func xcodeMoveMetadataIsSanitizedInBothDirections() {
        let toolCall = DirectAgentToolCall(
            id: "mv-hostile",
            name: "xcode.mv",
            argumentsObject: [
                "from": "Sources/\u{1B}[2JOld.swift",
                "to": "Sources/New\r\n.swift"
            ],
            argumentsJSON: "{}"
        )
        let lines = TerminalChat.appliedChangeDetailLines(for: toolCall, contentWidth: 80)

        #expect(lines.count == 3)
        #expect(lines.allSatisfy { !$0.contains("\u{1B}") && !$0.contains("\r") && !$0.contains("\n") })
        #expect(lines.contains { $0.hasPrefix("from: Sources/") })
        #expect(lines.contains { $0.hasPrefix("to: Sources/New") })
    }

    @Test
    func metadataOnlyMutationToolsHideRawParameters() {
        // Metadata-only operations have terminal-safe `change:` rows just like
        // source-bearing mutations have numbered snippets. Neither form should
        // repeat the raw argument object in the expanded block.
        for name in [
            "local.delete", "local.move", "local.mkdir",
            "XcodeRM", "xcode.rm", "XcodeMV", "xcode.mv"
        ] {
            #expect(TerminalChat.shouldHideParameterLines(for: name))
        }

        let toolCall = DirectAgentToolCall(
            id: "metadata-only-move",
            name: "xcode.mv",
            argumentsObject: [
                "sourcePath": "Sources/Old.swift",
                "destinationPath": "Sources/New.swift"
            ],
            argumentsJSON: "{}"
        )

        let lines = TerminalChat.detailedToolBaseLines(for: toolCall)

        #expect(!lines.contains("parameters:"))
        #expect(lines.contains { $0.hasPrefix("location: ") })
    }

    @Test
    func blankPathAliasFallsThroughWithoutContaminatingMetadataOrLanguage() {
        // A blank alias key must not shadow the valid one that follows, and
        // control characters must never reach a metadata row or the language
        // hint deduced from the path.
        let arguments: [String: Any] = [
            "file_path": "   ",
            "filePath": "\tSources/App\r\n.swift  "
        ]

        #expect(TerminalChat.targetPath(arguments) == "Sources/App .swift")
        #expect(TerminalChat.metadataArgument(["from": " \n "], keys: ["from"]) == nil)

        let toolCall = DirectAgentToolCall(
            id: "blank-path",
            name: "local.writeFile",
            argumentsObject: arguments.merging(["content": "let value = 1"]) { first, _ in first },
            argumentsJSON: "{}"
        )
        let lines = TerminalChat.appliedChangeDetailLines(for: toolCall, contentWidth: 80)

        #expect(lines.allSatisfy { !$0.contains("\r") && !$0.contains("\t") })
        #expect(TerminalChat.codeLanguageHint(for: toolCall) == "swift")

        let blankOnly = DirectAgentToolCall(
            id: "blank-only",
            name: "local.delete",
            argumentsObject: ["path": "  "],
            argumentsJSON: "{}"
        )

        // A whitespace-only path must still reach the caller's fallback.
        #expect(
            TerminalChat.appliedChangeDetailLines(for: blankOnly, contentWidth: 80)
                == ["change: delete file"]
        )
        #expect(TerminalChat.codeLanguageHint(for: blankOnly) == nil)
    }

    @Test
    func rawPayloadAccessorKeepsBlankAndControlCharactersVerbatim() {
        // The raw payload accessor is distinct from the metadata one: source
        // content is reproduced exactly, including empty and blank strings.
        #expect(TerminalChat.rawStringArgument(["content": ""], keys: ["content"]) == "")
        #expect(TerminalChat.rawStringArgument(["content": "  "], keys: ["content"]) == "  ")
        #expect(
            TerminalChat.rawStringArgument(["content": "a\tb"], keys: ["content"]) == "a\tb"
        )
        // A blank first key wins for payloads (it is a real payload) but not
        // for metadata (where it means "absent").
        #expect(
            TerminalChat.rawStringArgument(
                ["content": "", "text": "fallback"],
                keys: ["content", "text"]
            ) == ""
        )
        #expect(
            TerminalChat.metadataArgument(
                ["path": "", "file": "Sources/App.swift"],
                keys: ["path", "file"]
            ) == "Sources/App.swift"
        )
    }

    @Test
    func bareToolNamesAreNotCanonicalizedAsXcodeMutations() {
        // Only the spellings the runtime router actually accepts are mapped.
        for name in ["xcode.write", "XcodeWrite", "xcode_write", "xcodewrite"] {
            #expect(TerminalChat.normalizedMutationToolName(name) == "XcodeWrite")
        }
        for name in ["xcode.update", "xcode.edit", "XcodeUpdate", "xcodeedit"] {
            #expect(TerminalChat.normalizedMutationToolName(name) == "XcodeUpdate")
        }

        // Homonymous bare names from an unrelated MCP server stay untouched:
        // no false mutation rendering and no hidden parameters.
        for name in ["write", "update", "edit", "other.write"] {
            #expect(TerminalChat.normalizedMutationToolName(name) == name)
            #expect(!TerminalChat.shouldHideParameterLines(for: name))
            #expect(!TerminalChat.isFileMutationTool(name))

            let toolCall = DirectAgentToolCall(
                id: "bare-\(name)",
                name: name,
                argumentsObject: [
                    "filePath": "Sources/Feature.swift",
                    "content": "let written = true"
                ],
                argumentsJSON: "{}"
            )
            #expect(TerminalChat.appliedChangeDetailLines(for: toolCall, contentWidth: 80).isEmpty)
        }
    }

    @Test
    func diffCellBoundaryIsCollisionFreeAgainstAnsiAndUnicodePayloads() throws {
        // A payload containing the exact former in-band sentinel (and other
        // ANSI/box-drawing sequences) must not be able to relocate the column
        // boundary: the cells are structural fields, not parsed text.
        let hostilePayload = "\u{1B}[0m │ let injected = 1"
        let rows = TerminalChat.numberedDiffSnippetRows(
            old: hostilePayload,
            new: "let replacement = 2",
            contentWidth: 120
        )
        let contentRow = try #require(rows.first {
            $0.plainText.contains("injected")
        })
        guard case let .diff(cells) = contentRow else {
            Issue.record("Expected a structured side-by-side row")
            return
        }

        #expect(cells.oldCell.contains("let injected = 1"))
        #expect(!cells.newCell.contains("injected"))
        #expect(cells.newCell.contains("let replacement = 2"))
        // The raw ESC is neutralized into a visible control picture, so the
        // payload can neither steer the terminal nor break the width budget.
        #expect(!cells.oldCell.contains("\u{1B}"))
        #expect(cells.oldCell.contains("\u{241B}"))

        let rendered = TerminalChat.renderDetailedToolRow(contentRow, codeLanguage: "swift")
        let stripped = TerminalANSIText.stripANSI(rendered)

        #expect(stripped.contains("let injected = 1"))
        #expect(stripped.contains("let replacement = 2"))
    }

    @Test
    func wrappedSideBySideRowsStayWithinBudgetAndKeepCellsSeparate() {
        let rows = TerminalChat.numberedDiffSnippetRows(
            old: "let previousValueWithAVeryLongName = computeSomething(from: input)",
            new: "let replacementValueWithAnotherLongName = computeOther(from: input)",
            contentWidth: 120
        )
        let wrapped = TerminalChat.safelyWrappedDetailedToolRows(
            rows,
            contentInsetWidth: 0,
            columnWidth: 60
        )

        #expect(wrapped.allSatisfy { TerminalChat.displayWidth($0.plainText) <= 59 })
        // Wrapping keeps producing structured rows, so per-cell highlighting
        // survives the reflow instead of degrading to a single opaque string.
        #expect(wrapped.contains { row in
            if case .diff = row { return true }
            return false
        })

        let renderedRows = wrapped.map {
            TerminalChat.renderDetailedToolRow($0, codeLanguage: "swift")
        }
        #expect(renderedRows.allSatisfy { !$0.isEmpty })
    }
}
