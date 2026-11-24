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
    func artifactsRenderingGroupsEveryTurnAndIncludesTextEvidence() {
        let turns = [
            SessionFileArtifactHistory.Turn(
                number: 1,
                artifacts: [
                    FileChangeArtifact(
                        absolutePath: "/tmp/one.swift",
                        displayPath: "Sources/One.swift",
                        status: .added,
                        additions: 1,
                        newText: "let one = 1\n"
                    )
                ]
            ),
            SessionFileArtifactHistory.Turn(
                number: 2,
                artifacts: [
                    FileChangeArtifact(
                        absolutePath: "/tmp/two.swift",
                        displayPath: "Sources/Two.swift",
                        status: .modified,
                        additions: 1,
                        deletions: 1,
                        oldText: "let value = 1\n",
                        newText: "let value = 2\n"
                    )
                ]
            )
        ]

        let rendered = TerminalANSIText.stripANSI(TerminalChat.renderFileArtifacts(turns, includeHistoryHeadings: true))

        #expect(rendered.hasPrefix("\n🪬 Artifacts\n"))
        #expect(rendered.contains("Turn 1 — 1 file"))
        #expect(rendered.contains("Turn 2 — 1 file"))
        #expect(rendered.contains("Sources/One.swift"))
        #expect(rendered.contains("Sources/Two.swift"))
        #expect(rendered.contains("let value = 1"))
        #expect(rendered.contains("let value = 2"))
    }

    @Test
    func sideBySideDiffWrapsLongSourceLinesWithoutTruncatingEitherCell() {
        let old = String(repeating: "oldPayload", count: 12)
        let new = String(repeating: "newPayload", count: 12)
        let rows = TerminalChat.safelyWrappedDetailedToolRows(
            ToolSnippetRenderer.numberedDiffSnippetRows(
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
        #expect(rows.allSatisfy { TerminalTextMetrics.displayWidth($0.plainText) <= 79 })
    }

    @Test
    func newFileWriteWrapsLongSourceLinesWithoutTruncatingContent() {
        let content = String(repeating: "newFilePayload", count: 12)
        let toolCall = presentedToolCall(
            id: "call_write_long_line",
            name: "local.write",
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
        #expect(rows.allSatisfy { TerminalTextMetrics.displayWidth($0.plainText) <= 79 })
    }

    @Test(arguments: ["local.write", "local.append", "local.edit", "local.replace", "local.multiEdit"], [40, 52, 80])
    func mutationPreviewsUseNoExtraInsetAndPreserveSourceIndentation(
        toolName: String,
        columns: Int
    ) throws {
        let old = "    let value = 1\n        value()"
        let new = "    let value = 2\n        value()"
        var arguments: [String: Any] = ["path": "Sources/Example.swift"]
        switch toolName {
        case "local.write", "local.append":
            arguments["content"] = new
        case "local.multiEdit":
            arguments["edits"] = [["old": old, "new": new]]
        default:
            arguments["old"] = old
            arguments["new"] = new
        }
        let toolCall = presentedToolCall(
            id: "aligned-preview",
            name: toolName,
            argumentsObject: arguments,
            argumentsJSON: "{}"
        )
        let rows = TerminalChat.toolPresentationRows(
            for: toolCall,
            result: nil,
            statusDetail: nil,
            contentInsetWidth: 0,
            columnWidth: columns
        ).detailRows

        #expect(!rows.isEmpty)
        for row in rows {
            switch row {
            case let .code(line):
                #expect(line.indentation.isEmpty)
            case let .diff(cells):
                #expect(cells.indentation.isEmpty)
            case let .unifiedDiff(line):
                #expect(line.indentation.isEmpty)
            default:
                Issue.record("Expected a structured source row")
            }
            #expect(TerminalTextMetrics.displayWidth(row.plainText) <= columns - 1)
            #expect(TerminalANSIText.stripANSI(
                TerminalChat.renderDetailedToolRow(row, codeLanguage: "swift")
            ) == row.plainText)
        }
        let text = rows.map(\.plainText).joined(separator: "\n")
        #expect(text.contains("2 │         value()"))
        #expect(text.contains("1 │     let value = 2"))
        if toolName == "local.edit" || toolName == "local.replace" || toolName == "local.multiEdit" {
            #expect(text.contains("1 │     let value = 1"))
            if columns >= 52 {
                #expect(try #require(rows.first).plainText.hasPrefix("old"))
                #expect(rows.count == 3)
            } else {
                #expect(try #require(rows.first).plainText.hasPrefix("- 1 │ "))
            }
        } else {
            #expect(try #require(rows.first).plainText.hasPrefix("1 │ "))
        }
    }

    @Test(arguments: ["local.write", "local.multiEdit"], [40, 80, 81])
    func filePreviewBackgroundStopsAtTheSafeContentWidth(toolName: String, columns: Int) {
        // Exercise blank/short rows, wrapped comments, wide glyphs, empty old
        // payloads, and both unified and side-by-side diffs on the same surface.
        let content = "    // " + String(repeating: "界🙂 source ", count: 10)
            + "\n\n    let value = 1"
        for inset in [0, 1, 6] {
            for fileExtension in ["swift", "txt"] {
                var arguments: [String: Any] = ["path": "Example.\(fileExtension)"]
                if toolName == "local.write" {
                    arguments["content"] = content
                } else {
                    arguments["edits"] = [["old": "", "new": content]]
                }
                let toolCall = presentedToolCall(
                    id: "bounded-background",
                    name: toolName,
                    argumentsObject: arguments,
                    argumentsJSON: "{}"
                )
                let presentation = TerminalChat.toolPresentationRows(
                    for: toolCall,
                    result: nil,
                    statusDetail: nil,
                    contentInsetWidth: inset,
                    columnWidth: columns
                )
                let width = columns - inset - 1
                #expect(presentation.detailContentWidth == width)
                #expect(!presentation.detailRows.isEmpty)
                for row in presentation.detailRows {
                    let rendered = TerminalChat.renderDetailedToolRow(
                        row,
                        codeLanguage: ToolLanguageHint.hint(for: toolCall),
                        contentWidth: presentation.detailContentWidth
                    )
                    let padding = String(
                        repeating: " ",
                        count: max(0, width - TerminalTextMetrics.displayWidth(row.plainText))
                    )
                    #expect(TerminalANSIText.stripANSI(rendered) == row.plainText + padding)
                    #expect(TerminalTextMetrics.displayWidth(rendered) == width)
                    #expect(rendered.hasSuffix(
                        TerminalChat.codeAreaBackgroundColor + padding + TerminalStyle.reset + "\u{1B}[K"
                    ))
                    // No earlier erase may fill the rest of the physical line
                    // with the code background before the reset at the boundary.
                    #expect(rendered.components(separatedBy: "\u{1B}[K").count == 2)
                }
            }
        }
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
        #expect(TerminalTextMetrics.displayWidth(rendered) == 5)

        let statusOnly = TerminalChat.compactToolStatusLine(
            target: "abcdef",
            statusIcon: "✅",
            contentInsetWidth: 0,
            columnWidth: 3
        )
        #expect(statusOnly == "✅")
        #expect(TerminalTextMetrics.displayWidth(statusOnly) == 2)
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
        let rows = TerminalChat.safelyWrappedDetailedToolRows(
            [.text("    a😀")],
            contentInsetWidth: 0,
            columnWidth: 6
        )
        .map(\.plainText)

        #expect(rows == ["    a", "   😀"])
        #expect(rows.allSatisfy { TerminalTextMetrics.displayWidth($0) <= 5 })
    }

    @Test
    func sourceChangesKeepEveryLineWithoutTruncationMarkers() {
        let old = (0..<150).map { "let old\($0) = \($0)" }.joined(separator: "\n")
        let new = (0..<150).map { "let new\($0) = \($0)" }.joined(separator: "\n")

        let rows = ToolSnippetRenderer.numberedDiffSnippetRows(
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
                name: "local.write",
                argumentsObject: ["path": path, "content": "let value = true"],
                argumentsJSON: "{}"
            )
        }

        let swift = tool(path: "Sources/App.swift")
        let c = tool(path: "Sources/main.c")
        let text = tool(path: "Notes/readme.txt")
        let markdown = tool(path: "Docs/readme.md")
        let unknown = tool(path: "Data/readme.custom")

        #expect(ToolLanguageHint.hint(for: swift) == "swift")
        #expect(ToolLanguageHint.hint(for: c) == "c")
        #expect(ToolLanguageHint.hint(for: text) == nil)
        #expect(ToolLanguageHint.hint(for: markdown) == nil)
        #expect(ToolLanguageHint.hint(for: unknown) == nil)

        // The public form takes the path itself; the extension is case-insensitive.
        #expect(TerminalChat.codeLanguageHint(forPath: "/tmp/project/Sources/App.swift") == "swift")
        #expect(TerminalChat.codeLanguageHint(forPath: "Scripts/build.SH") == "shell")
        #expect(TerminalChat.codeLanguageHint(forPath: "README.md") == nil)
        #expect(TerminalChat.codeLanguageHint(forPath: "Makefile") == nil)

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

    @Test
    func aCompactBlockWhoseHeaderThePreviewShowedKeepsTheTargetAndItsStatus() {
        let toolCall = presentedToolCall(
            id: "call_1",
            name: "local.write",
            argumentsObject: ["path": "/tmp/Example.swift", "content": "let x = 1\n"],
            argumentsJSON: "{}"
        )

        let withHeader = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            statusDetail: "1.38ms",
            columnWidth: 80
        )
        let merged = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            statusDetail: "1.38ms",
            columnWidth: 80,
            previewMerge: .header
        )

        #expect(withHeader == ["🛠️  local.write", "/tmp/Example.swift ✅ 1.38ms"])
        // The preview header named the tool: only the header is left out, and
        // the status row keeps the target before the status, as always.
        #expect(merged == ["/tmp/Example.swift ✅ 1.38ms"])

        // Every status the block shows keeps the target and its status.
        for icon in ["⏳", "⚠️"] {
            #expect(TerminalChat.compactToolLines(
                for: toolCall,
                statusIcon: icon,
                columnWidth: 80,
                previewMerge: .header
            ) == ["/tmp/Example.swift \(icon)"])
        }
        let warning = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "⚠️",
            statusDetail: "1.38ms",
            columnWidth: 80,
            previewMerge: .header
        )
        #expect(warning == ["/tmp/Example.swift ⚠️  1.38ms"])

        // On a narrow terminal the status row still fits one row: the detail
        // that does not fit is dropped, the icon stays, and the target is cut
        // to the columns left.
        #expect(TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            statusDetail: "1.38ms",
            contentInsetWidth: 1,
            columnWidth: 8,
            previewMerge: .header
        ) == ["/tm ✅"])

        // A call without a target shows its header on its only row: the merge
        // is ignored and the block stays complete.
        let untargeted = DirectAgentToolCall(
            id: "call_2",
            name: "local.write",
            argumentsObject: ["path": "/tmp/Example.swift", "content": "let x = 1\n"],
            argumentsJSON: "{}"
        )
        let complete = TerminalChat.compactToolLines(
            for: untargeted,
            statusIcon: "✅",
            statusDetail: "1.38ms",
            columnWidth: 80
        )
        #expect(complete == ["🛠️  local.write ✅ 1.38ms"])
        #expect(TerminalChat.compactToolLines(
            for: untargeted,
            statusIcon: "✅",
            statusDetail: "1.38ms",
            columnWidth: 80,
            previewMerge: .header
        ) == complete)
    }

    @Test
    func multiReadListsEveryTargetOnItsOwnRowAndKeepsTheStatusLast() {
        let toolCall = presentedToolCall(
            id: "call_multi_read",
            name: "local.multiRead",
            argumentsObject: [
                "paths": ["Sources/A.swift", "Sources/B.swift"]
            ],
            argumentsJSON: "{}"
        )

        #expect(
            ToolCallPresentation.displayToolTargets(for: toolCall)
                == ["Sources/A.swift", "Sources/B.swift"]
        )
        #expect(
            TerminalChat.compactToolLines(
                for: toolCall,
                statusIcon: "✅",
                statusDetail: "3.83ms",
                columnWidth: 80
            ) == [
                "🛠️  local.multiRead",
                "Sources/A.swift",
                "Sources/B.swift",
                "✅ 3.83ms"
            ]
        )

        // The started block lists the same rows, so the completion can rewrite
        // it in place: only the status row changes.
        #expect(
            TerminalChat.compactToolLines(
                for: toolCall,
                statusIcon: "⏳",
                columnWidth: 80
            ) == [
                "🛠️  local.multiRead",
                "Sources/A.swift",
                "Sources/B.swift",
                "⏳"
            ]
        )

        // A repeated path is listed once.
        let repeated = presentedToolCall(
            id: "call_multi_read_repeated",
            name: "local.multiRead",
            argumentsObject: [
                "paths": ["Sources/A.swift", "Sources/A.swift"]
            ],
            argumentsJSON: "{}"
        )
        #expect(
            TerminalChat.compactToolLines(
                for: repeated,
                statusIcon: "✅",
                statusDetail: "1ms",
                columnWidth: 80
            ) == ["🛠️  local.multiRead", "Sources/A.swift", "✅ 1ms"]
        )

        // Each path is fitted to the same safe width as a status row, so a
        // long path never wraps the in-place block.
        let narrow = TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: "✅",
            statusDetail: "3.83ms",
            contentInsetWidth: 0,
            columnWidth: 12
        )
        #expect(narrow.count == 4)
        #expect(narrow.dropFirst().allSatisfy {
            TerminalTextMetrics.displayWidth($0) <= 11
        })
        #expect(narrow.last == "✅ 3.83ms")

        // A call that presents no list keeps its single target row.
        let single = presentedToolCall(
            id: "call_read",
            name: "local.read",
            argumentsObject: ["path": "Sources/A.swift"],
            argumentsJSON: "{}"
        )
        #expect(ToolCallPresentation.displayToolTargets(for: single).isEmpty)
        #expect(
            TerminalChat.compactToolLines(
                for: single,
                statusIcon: "✅",
                statusDetail: "1ms",
                columnWidth: 80
            ) == ["🛠️  local.read", "Sources/A.swift ✅ 1ms"]
        )
    }

    @Test
    func multiReadTargetsPreferNonBlankPathsBeforeFallback() {
        let cases: [(arguments: [String: Any], expected: [String])] = [
            (
                ["paths": [" B.swift ", "", "A.swift", "B.swift"],
                 "file_paths": ["Fallback.swift", "A.swift"]],
                ["B.swift", "A.swift"]
            ),
            (
                ["file_paths": [" B.swift ", "A.swift", "B.swift", "\n"]],
                ["B.swift", "A.swift"]
            ),
            (
                ["paths": [String](), "file_paths": ["Fallback.swift"]],
                ["Fallback.swift"]
            ),
            (
                ["paths": [" ", "\n\t"], "file_paths": ["Fallback.swift", " Fallback.swift "]],
                ["Fallback.swift"]
            ),
            (
                ["paths": [" ", "Primary.swift"], "file_paths": ["Fallback.swift"]],
                ["Primary.swift"]
            ),
            (["paths": [" "], "file_paths": ["\n"]], []),
            ([:], [])
        ]

        for (index, testCase) in cases.enumerated() {
            let call = presentedToolCall(
                id: "call_multi_read_alias_\(index)",
                name: "local.multiRead",
                argumentsObject: testCase.arguments,
                argumentsJSON: "{}"
            )
            #expect(ToolCallPresentation.displayToolTargets(for: call) == testCase.expected)
        }

        let call = presentedToolCall(
            id: "call_multi_read_alias_render",
            name: "local.multiRead",
            argumentsObject: [
                "paths": ["B.swift", "A.swift", "B.swift"],
                "file_paths": ["Fallback.swift"]
            ],
            argumentsJSON: "{}"
        )
        #expect(
            TerminalChat.compactToolLines(
                for: call,
                statusIcon: "✅",
                statusDetail: "1ms",
                columnWidth: 80
            ) == ["🛠️  local.multiRead", "B.swift", "A.swift", "✅ 1ms"]
        )
    }

    func ansiStripped(_ text: String) -> String {
        TerminalANSIText.stripANSI(text)
    }
}
