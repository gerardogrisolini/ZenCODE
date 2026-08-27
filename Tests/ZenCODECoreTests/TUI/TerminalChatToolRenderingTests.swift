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
    func sideBySideDiffWrapsLongSourceLinesWithoutTruncatingEitherCell() {
        let old = String(repeating: "oldPayload", count: 12)
        let new = String(repeating: "newPayload", count: 12)
        let rows = TerminalChat.safelyWrappedDetailedToolRows(
            TerminalChat.numberedDiffSnippetRows(
                old: old,
                new: new,
                contentWidth: 80
            ),
            contentInsetWidth: 0,
            columnWidth: 80
        )

        let diffCells = rows.compactMap { row -> TerminalChat.DetailedToolDiffCells? in
            guard case let .diff(cells) = row else { return nil }
            return cells
        }
        let oldRendered = diffCells.dropFirst().map(\.oldCell).joined()
        let newRendered = diffCells.dropFirst().map(\.newCell).joined()

        #expect(oldRendered.contains(old))
        #expect(newRendered.contains(new))
        #expect(!rows.map(\.plainText).joined().contains("…"))
        #expect(rows.allSatisfy { TerminalChat.displayWidth($0.plainText) <= 79 })
    }

    @Test
    func wrappedPlainTextDiffUsesWhiteForegroundForEveryFragment() {
        let prose = String(repeating: "plain text payload ", count: 12)
        let rows = TerminalChat.safelyWrappedDetailedToolRows(
            TerminalChat.numberedDiffSnippetRows(
                old: prose,
                new: prose + "changed",
                contentWidth: 80
            ),
            contentInsetWidth: 0,
            columnWidth: 80,
            codeLanguage: nil
        )
        let renderedPayloadRows = rows
            .dropFirst()
            .map { TerminalChat.renderDetailedToolRow($0, codeLanguage: nil) }
            .filter { TerminalANSIText.stripANSI($0).contains("plain text payload") }

        #expect(renderedPayloadRows.count > 1)
        #expect(
            renderedPayloadRows.allSatisfy {
                $0.contains(TerminalMarkdownPalette.dark.codeForeground)
            }
        )
    }

    @Test
    func wrappedSideBySideDiffPreservesSwiftCommentColorOnContinuations() {
        let comment = "// " + String(repeating: "comment payload ", count: 12)
        let rows = TerminalChat.safelyWrappedDetailedToolRows(
            TerminalChat.numberedDiffSnippetRows(
                old: "",
                new: comment,
                contentWidth: 80
            ),
            contentInsetWidth: 0,
            columnWidth: 80,
            codeLanguage: "swift"
        )
        let renderedContinuations = rows
            .dropFirst(2)
            .map { TerminalChat.renderDetailedToolRow($0, codeLanguage: "swift") }
            .filter { TerminalANSIText.stripANSI($0).contains("comment payload") }

        #expect(!renderedContinuations.isEmpty)
        #expect(
            renderedContinuations.allSatisfy {
                $0.contains(TerminalMarkdownPalette.dark.syntaxComment)
            }
        )
        #expect(
            TerminalANSIText.stripANSI(renderedContinuations.joined())
                .contains("comment payload")
        )
    }

    @Test
    func wrappedSideBySideAddedCellKeepsCodeBackgroundThroughPadding() {
        let comment = "// " + String(repeating: "added payload ", count: 12)
        let rows = TerminalChat.safelyWrappedDetailedToolRows(
            TerminalChat.numberedDiffSnippetRows(
                old: "",
                new: comment,
                contentWidth: 80
            ),
            contentInsetWidth: 0,
            columnWidth: 80,
            codeLanguage: "swift"
        )
        let renderedContinuation = try! #require(
            rows
                .dropFirst(2)
                .map { TerminalChat.renderDetailedToolRow($0, codeLanguage: "swift") }
                .last { TerminalANSIText.stripANSI($0).contains("added payload") }
        )

        #expect(
            renderedContinuation.contains(
                "\u{1B}[0m\(TerminalChat.codeAreaBackgroundColor)\(TerminalChat.codeAreaBackgroundColor) "
            )
        )
        #expect(renderedContinuation.hasSuffix("\(TerminalChat.codeAreaBackgroundColor)\u{1B}[K"))
    }

    @Test
    func newFileWriteWrapsLongSourceLinesWithoutTruncatingContent() {
        let content = String(repeating: "newFilePayload", count: 12)
        let toolCall = presentedToolCall(
            id: "call_write_long_line",
            name: "local.writeFile",
            argumentsObject: [
                "path": "Sources/Generated.swift",
                "content": content
            ],
            argumentsJSON: ""
        )

        let rows = TerminalChat.toolPresentationRows(
            for: toolCall,
            result: nil,
            statusDetail: nil,
            contentInsetWidth: 0,
            columnWidth: 80
        ).detailRows
        let codeLines = rows.compactMap { row -> TerminalChat.DetailedToolCodeLine? in
            guard case let .code(line) = row else { return nil }
            return line
        }

        #expect(codeLines.count > 1)
        #expect(codeLines.map(\.content).joined() == content)
        #expect(codeLines.dropFirst().allSatisfy { $0.lineNumber.trimmingCharacters(in: .whitespaces).isEmpty })
        #expect(!rows.map(\.plainText).joined().contains("…"))
        #expect(rows.allSatisfy { TerminalChat.displayWidth($0.plainText) <= 79 })
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
    func sourceChangesKeepEveryLineWithoutTruncationMarkers() {
        let old = (0..<150).map { "let old\($0) = \($0)" }.joined(separator: "\n")
        let new = (0..<150).map { "let new\($0) = \($0)" }.joined(separator: "\n")

        let rows = TerminalChat.numberedDiffSnippetRows(
            old: old,
            new: new,
            contentWidth: 120
        )
        let text = rows.map(\.plainText).joined(separator: "\n")

        #expect(text.contains("old149"))
        #expect(text.contains("new149"))
        #expect(!text.contains("truncated"))
    }

    @Test
    func sourceSyntaxLanguageComesFromKnownCodeExtensionsOnly() {
        func tool(path: String) -> DirectAgentToolCall {
            presentedToolCall(
                id: path,
                name: "local.writeFile",
                argumentsObject: ["path": path, "content": "let value = true"],
                argumentsJSON: "{}"
            )
        }

        let swift = tool(path: "Sources/App.swift")
        let c = tool(path: "Sources/main.c")
        let text = tool(path: "Notes/readme.txt")
        let markdown = tool(path: "Docs/readme.md")
        let unknown = tool(path: "Data/readme.custom")

        #expect(TerminalChat.codeLanguageHint(for: swift) == "swift")
        #expect(TerminalChat.codeLanguageHint(for: c) == "c")
        #expect(TerminalChat.codeLanguageHint(for: text) == nil)
        #expect(TerminalChat.codeLanguageHint(for: markdown) == nil)
        #expect(TerminalChat.codeLanguageHint(for: unknown) == nil)

        let row = TerminalChat.DetailedToolRow.code(
            TerminalChat.DetailedToolCodeLine(
                indentation: "  ",
                lineNumber: "1",
                content: "let value = true"
            )
        )
        let highlighted = TerminalChat.renderDetailedToolRow(row, codeLanguage: "swift")
        let neutral = TerminalChat.renderDetailedToolRow(row, codeLanguage: nil)
        #expect(highlighted.contains(TerminalMarkdownPalette.dark.syntaxKeyword))
        #expect(!neutral.contains(TerminalMarkdownPalette.dark.syntaxKeyword))
        #expect(neutral.contains(TerminalMarkdownPalette.dark.codeForeground))
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
