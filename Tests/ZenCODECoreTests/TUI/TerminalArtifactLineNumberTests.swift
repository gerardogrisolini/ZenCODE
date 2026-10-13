import Foundation
import Markdown
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct TerminalArtifactLineNumberTests {
    @Test
    func hunkOffsetsChooseOldForRemovalAndNewForAdditionAndContext() {
        let patch = """
        diff --git a/File.swift b/File.swift
        index 123..456 100644
        --- a/File.swift
        +++ b/File.swift
        @@ -10,3 +20,4 @@ function
         shared
        -old
        +new
        +extra
         tail
        @@ -90 +200 @@
        -last old
        \\ No newline at end of file
        +last new
        \\ No newline at end of file
        """
        let numbered = TerminalCodeBlockRenderer.numberedArtifactDiff(patch)
        #expect(numbered == """
            │ diff --git a/File.swift b/File.swift
            │ index 123..456 100644
            │ --- a/File.swift
            │ +++ b/File.swift
            │ @@ -10,3 +20,4 @@ function
         20 │  shared
         11 │ -old
         21 │ +new
         22 │ +extra
         23 │  tail
            │ @@ -90 +200 @@
         90 │ -last old
            │ \\ No newline at end of file
        200 │ +last new
            │ \\ No newline at end of file
        """)
    }

    @Test(arguments: ["context", "\u{0301}context"])
    func combiningSourceScalarsDoNotHideASCIIMarkersOrGutters(context: String) {
        let patch = "@@ -10,2 +20,2 @@\n-\u{0301}old\n+\u{0301}new\n \(context)"
        let numbered = TerminalCodeBlockRenderer.numberedArtifactDiff(patch)
        let expected = "   │ @@ -10,2 +20,2 @@\n10 │ -\u{0301}old\n20 │ +\u{0301}new\n21 │  \(context)"
        #expect(Array(numbered.unicodeScalars) == Array(expected.unicodeScalars))
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func renderingKeepsCombiningScalarsInSourceRatherThanMarker(palette: TerminalMarkdownPalette) {
        let source = "\u{0301}let value = \"e\u{0301}界\""
        let markers: [(String, TerminalCodeBlockRenderer.DiffLineKind, String)] = [
            ("+", .addition, palette.diffAddition),
            ("-", .removal, palette.diffRemoval),
            (" ", .context, ""),
        ]
        for (marker, kind, style) in markers {
            let line = marker + source
            #expect(TerminalCodeBlockRenderer.diffLineKind(line) == kind)
            for sourceLanguage in [nil, "swift"] as [String?] {
                let highlighted = sourceLanguage.map {
                    TerminalCodeBlockRenderer.renderLine(source, language: $0, palette: palette)
                } ?? TerminalCodeBlockRenderer.terminalSafeSourceLine(source)
                let expected = style.isEmpty ? marker + highlighted
                    : style + marker + TerminalStyle.reset + highlighted
                let rendered = TerminalCodeBlockRenderer.renderDiffLine(
                    line, sourceLanguage: sourceLanguage, palette: palette
                )
                #expect(Array(rendered.unicodeScalars) == Array(expected.unicodeScalars))
                #expect(Array(TerminalANSIText.stripANSI(rendered).unicodeScalars) == Array(line.unicodeScalars))
            }
        }
    }

    @Test
    func zeroCountsAndHeaderLikeSourceKeepCorrectNumbersAcrossFiles() {
        let patch = """
        --- /dev/null
        +++ b/added.txt
        @@ -0,0 +8,2 @@
        +
        +++ added source
        --- a/deleted.txt
        +++ /dev/null
        @@ -51,2 +0,0 @@
        -
        --- removed source
        --- a/last.txt
        +++ b/last.txt
        @@ -4 +9 @@
        -old
        +new
        """
        let numbered = TerminalCodeBlockRenderer.numberedArtifactDiff(patch)
        #expect(numbered.contains(" 8 │ +\n 9 │ +++ added source"))
        #expect(numbered.contains("51 │ -\n52 │ --- removed source"))
        #expect(numbered.contains(" 4 │ -old\n 9 │ +new"))
        for line in numbered.components(separatedBy: "\n") where
            line.contains("@@") || line.contains("/dev/null") || line.contains("a/") || line.contains("b/") {
            #expect(line.hasPrefix("   │ "))
        }
    }

    @Test
    func missingMalformedExhaustedAndOverflowingHunksDoNotInventPositions() {
        var state = TerminalCodeBlockRenderer.DiffState()
        let rows: [(String, Int?)] = [
            ("+without a hunk", nil),
            ("@@ -3 +7 @@", nil),
            ("-old", 3),
            ("\\ No newline at end of file", nil),
            ("+new", 7),
            ("+outside declared count", nil),
            ("@@ -3,wat +7 @@", nil),
            ("+malformed", nil),
            ("@@ -0 +1 @@", nil),
            ("+zero start with nonzero count", nil),
            ("@@ -1 +1", nil),
            ("+missing hunk closer", nil),
            ("@@@ -1,1 -1,1 +1,1 @@@", nil),
            ("+combined diff is not a unified hunk", nil),
            ("@@ -1,0 +\(Int.max),2 @@", nil),
            ("+overflowing range", nil),
            ("@@ -0,0 +\(Int.max) @@", nil),
            ("+last representable line", Int.max),
            ("+exhausted", nil),
            ("@@ -3,2 +7,2 @@", nil),
            (" context", 7),
            ("unexpected metadata", nil),
            ("+after unknown evidence", nil),
        ]
        for (line, expected) in rows {
            _ = state.classify(line)
            #expect(state.sourceLineNumber == expected, "Unexpected position for \(line)")
        }
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func numberedUnicodeWrapsKeepOneNumberSyntaxAndBackground(palette: TerminalMarkdownPalette) {
        let payload = "\"" + String(repeating: "界e\u{301}🚀", count: 18) + "\""
        for (marker, background) in [("+", palette.diffAdditionBackground), ("-", palette.diffRemovalBackground)] {
            let rows = TerminalCodeBlockRenderer.renderCodeLine(
                "42 │ " + marker + payload, language: "artifact-diff-swift", width: 19, palette: palette
            )
            #expect(rows.count > 2)
            let reassembled = rows.enumerated().map { index, row in
                expectBackground(row, background: background, width: 19, palette: palette)
                #expect(row.contains(palette.syntaxString))
                let visible = TerminalANSIText.stripANSI(row)
                #expect(visible.hasPrefix(index == 0 ? "42 │ " : "   │ ↳ "))
                return String(visible.dropFirst(index == 0 ? 5 : 7))
                    .trimmingCharacters(in: .whitespaces)
            }.joined()
            #expect(reassembled == marker + payload)

            let blank = TerminalCodeBlockRenderer.renderCodeLine(
                "42 │ " + marker, language: "artifact-diff-swift", width: 19, palette: palette
            )[0]
            #expect(TerminalANSIText.stripANSI(blank).hasPrefix("42 │ " + marker))
            expectBackground(blank, background: background, width: 19, palette: palette)
        }
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func gutterDoesNotShiftTabStopsOrAllowPayloadResetSequences(palette: TerminalMarkdownPalette) {
        let row = TerminalCodeBlockRenderer.renderCodeLine(
            "42 │ +\tlet value: String = \"text\"\u{1B}[0m",
            language: "artifact-diff-swift", width: 64, palette: palette
        )[0]
        #expect(TerminalANSIText.stripANSI(row).hasPrefix("42 │ +    let value: String = \"text\"␛[0m"))
        #expect(row.contains("\(palette.syntaxKeyword)let"))
        #expect(row.contains("\(palette.syntaxType)String"))
        expectBackground(row, background: palette.diffAdditionBackground, width: 64, palette: palette)
    }

    @Test
    func narrowNumberedRowsDoNotSplitOrLoseWideGraphemes() {
        let payload = "+界e\u{301}🚀"
        let rows = TerminalCodeBlockRenderer.renderCodeLine(
            "123 │ " + payload, language: "artifact-diff", width: 8, palette: .dark
        )
        let reassembled = rows.enumerated().map { index, row in
            #expect(TerminalANSIText.visibleWidth(row) == 8)
            let visible = TerminalANSIText.stripANSI(row)
            #expect(visible.hasPrefix(index == 0 ? "123 │ " : "    │ "))
            var content = String(visible.dropFirst(6))
            if index > 0, content.hasPrefix("›") { content.removeFirst() }
            return content.trimmingCharacters(in: .whitespaces)
        }.joined()
        #expect(reassembled == payload)
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func completeAndScalarStreamingArtifactsShareNumberedRowsAndResetBeforeProse(palette: TerminalMarkdownPalette) {
        let diff = """
        --- a/First.swift
        +++ b/First.swift
        @@ -9,2 +99,3 @@
        --- oldSource
        +++ newSource
        +let value = "界e\u{301}🚀 and a long string that wraps"
         let context = true
        --- a/Second.swift
        +++ b/Second.swift
        @@ -30 +70 @@
        -let old = 1
        +let new = 2
        """
        let numbered = TerminalCodeBlockRenderer.numberedArtifactDiff(diff)
        let source = "```artifact-diff-swift\n\(numbered)\n```\n\nTail prose"
        var renderer = TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: false, renderWidth: 36, palette: palette
        )
        let complete = renderer.visit(Document(parsing: source))
        var stream = TerminalMarkdownStreamFormatter(
            isEnabled: true, renderWidth: 37, supportsHyperlinks: false, palette: palette
        )
        var streamed = ""
        for scalar in source.unicodeScalars { streamed += stream.consume(String(scalar)) }
        streamed += stream.finish()
        let completeRows = complete.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        let streamRows = streamed.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        #expect(completeRows.filter { !$0.isEmpty } == streamRows.filter { !$0.isEmpty })
        #expect(TerminalANSIText.stripANSI(streamRows.last ?? "") == "Tail prose")
        #expect(!(streamRows.last ?? "").contains(palette.diffAdditionBackground))
        #expect(!(streamRows.last ?? "").contains(palette.diffRemovalBackground))
        let visible = TerminalANSIText.stripANSI(streamed)
        for row in ["  9 │ --- oldSource", " 99 │ +++ newSource", "101 │  let context = true", " 30 │ -let old = 1", " 70 │ +let new = 2"] {
            #expect(visible.contains(row))
        }
        for row in streamRows {
            let plain = TerminalANSIText.stripANSI(row)
            if plain.hasPrefix("  9 │ --- oldSource") {
                expectBackground(row, background: palette.diffRemovalBackground, width: 36, palette: palette)
            } else if plain.hasPrefix(" 99 │ +++ newSource") {
                expectBackground(row, background: palette.diffAdditionBackground, width: 36, palette: palette)
            }
        }
    }

    @Test
    func artifactMarkdownCarriesNumbersInPlainOutputWithoutDependingOnCapabilities() {
        let artifact = FileChangeArtifact(
            absolutePath: "/tmp/File.swift", displayPath: "File.swift", status: .modified,
            patch: "@@ -8,2 +30,2 @@\r\n-old\r\n+new\r\n context\r\n"
        )
        let turns = [SessionFileArtifactHistory.Turn(number: 1, artifacts: [artifact])]
        let markdown = TerminalChat.renderFileArtifacts(turns, columnWidth: 12, isEnabled: false)
        #expect(markdown == TerminalChat.renderFileArtifacts(turns, columnWidth: 120, isEnabled: true))
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: false)
        var plain = ""
        for character in markdown { plain += formatter.consume(String(character)) }
        plain += formatter.finish()
        #expect(plain == markdown)
        #expect(plain.contains(" 8 │ -old\n30 │ +new\n31 │  context\n```"))
        #expect(!plain.contains("\u{1B}"))
        #expect(!plain.contains("\r"))
    }

    @Test
    func ordinaryDiffAndSourceFencesDoNotAcquireArtifactGutters() {
        let diff = "@@ -8 +30 @@\n-old\n+new"
        for language in ["diff", "patch", "diff-swift", "swift", "text"] {
            let rendered = TerminalCodeBlockRenderer.renderBlock(diff, language: language, palette: .dark)
            let visible = TerminalANSIText.stripANSI(rendered)
            #expect(visible.contains("@@ -8 +30 @@\n-old\n+new"))
            #expect(!visible.contains("│"))
            let markdown = "```\(language)\n\(diff)\n```"
            var plain = TerminalMarkdownStreamFormatter(isEnabled: false)
            #expect(plain.consume(markdown) + plain.finish() == markdown)
        }
    }

    private func expectBackground(
        _ row: String, background: String, width: Int, palette: TerminalMarkdownPalette
    ) {
        let style = palette.codeForeground + background
        #expect(row.hasPrefix(style))
        #expect(row.hasSuffix(TerminalStyle.reset))
        #expect(TerminalANSIText.visibleWidth(row) == width)
        #expect(!row.contains(palette.codeBackground))
        let resets = row.components(separatedBy: TerminalStyle.reset)
        #expect(resets.dropFirst().dropLast().allSatisfy { $0.hasPrefix(style) })
        #expect(resets.last == "")
    }
}
