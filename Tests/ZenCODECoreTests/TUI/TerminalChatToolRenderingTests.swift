//
//  TerminalChatRenderingTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 29/05/26.
//

import Foundation
import Testing
import ToolCore
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

        // Anchored to the source constant so a deliberate palette change does
        // not silently drift from this expectation again.
        #expect(
            rendered.hasPrefix(
                "\n\(TerminalChatTextFormatting.fileChangeSummaryHeaderANSIColor)🪬 Summary:\u{1B}[0m "
            )
        )
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
    func compactToolLinesUseTheCanonicalName() {
        let toolCall = presentedToolCall(
            id: "call_1",
            name: "local.editFile",
            argumentsObject: [
                "file_path": "Sources/App.swift",
                "old": "old",
                "new": "new"
            ],
            argumentsJSON: #"{"file_path":"Sources/App.swift","old":"old","new":"new"}"#
        )

        let lines = TerminalChat.compactToolLines(for: toolCall, statusIcon: "⏳")

        #expect(lines == ["🛠️  local.editFile", "Sources/App.swift ⏳"])
    }

    @Test
    func compactToolTerminalTextDoesNotInsertBlankRows() {
        let rendered = TerminalChat.compactToolTerminalText(
            ["🛠️  Read", "Sources/App.swift ⏳"],
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
    func compactExecToolLinesUseTheCanonicalName() {
        let toolCall = presentedToolCall(
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
        #expect(lines[0] == "🛠️  local.exec")
        #expect(lines[1].hasSuffix("✅"))
    }

    func ansiStripped(_ text: String) -> String {
        TerminalANSIText.stripANSI(text)
    }
}
