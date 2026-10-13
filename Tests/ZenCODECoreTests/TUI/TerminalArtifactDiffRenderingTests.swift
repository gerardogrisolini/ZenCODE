import Foundation
import Markdown
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct TerminalArtifactDiffRenderingTests {
    @Test
    func sourceSnapshotsProduceOneDiffWithUnchangedLinesOnlyOnce() {
        let artifact = FileChangeArtifact(
            absolutePath: "/tmp/File.swift", displayPath: "File.swift", status: .modified,
            additions: 1, deletions: 1,
            oldText: "struct File {\n\tlet value = 1\n\n}\n",
            newText: "struct File {\n\tlet value = 2\n\n}\n"
        )
        let markdown = render(artifact)
        #expect(markdown.contains("```diff-swift\n@@ -1,4 +1,4 @@\n struct File {\n-\tlet value = 1\n+\tlet value = 2\n \n }\n```"))
        #expect(markdown.components(separatedBy: "struct File {").count - 1 == 1)
        #expect(!markdown.contains("Before"))
        #expect(!markdown.contains("After"))
    }

    @Test
    func additionsDeletionsAndFinalNewlineChangesKeepExplicitMarkers() {
        let added = render(.init(
            absolutePath: "/tmp/a.txt", displayPath: "a.txt", status: .added,
            newText: "first\n\nlast\n"
        ))
        #expect(added.contains("@@ -0,0 +1,3 @@\n+first\n+\n+last"))
        let deleted = render(.init(
            absolutePath: "/tmp/a.txt", displayPath: "a.txt", status: .deleted,
            oldText: "first\nlast"
        ))
        #expect(deleted.contains("@@ -1,2 +0,0 @@\n-first\n-last\n\\ No newline at end of file"))
        let newlineOnly = render(.init(
            absolutePath: "/tmp/a.txt", displayPath: "a.txt", status: .modified,
            oldText: "value", newText: "value\n"
        ))
        #expect(newlineOnly.contains("-value\n\\ No newline at end of file\n+value"))
        let empty = render(.init(
            absolutePath: "/tmp/empty.txt", displayPath: "empty.txt", status: .added,
            newText: ""
        ))
        #expect(empty.contains("**added `empty.txt`**"))
        #expect(!empty.contains("```"))
    }

    @Test
    func incompleteEvidenceUsesPatchInsteadOfInventingAnAbsentSide() {
        let markdown = render(.init(
            absolutePath: "/tmp/File.swift", displayPath: "File.swift", status: .modified,
            oldText: "unrelated old snapshot\n",
            patch: "--- a/File.swift\n+++ b/File.swift\n@@ -2 +2 @@\n-old\n+new\n"
        ))
        #expect(!markdown.contains("unrelated old snapshot"))
        #expect(markdown.contains("```diff-swift\n--- a/File.swift\n+++ b/File.swift"))
        #expect(markdown.contains("-old\n+new"))
    }

    @Test
    func patchAndSourceBackticksRemainInsideOneDiffFence() {
        let markdown = render(.init(
            absolutePath: "/tmp/README.md", displayPath: "README.md", status: .modified,
            oldText: "```swift\nlet value = 1\n```\n",
            newText: "```swift\nlet value = 2\n```\n"
        ))
        #expect(markdown.contains("````diff\n"))
        #expect(markdown.contains(" ```swift\n-let value = 1\n+let value = 2\n ```\n````"))
        var formatter = TerminalMarkdownStreamFormatter(isEnabled: false)
        let plain = formatter.consume(markdown) + formatter.finish()
        #expect(plain.contains("-let value = 1\n+let value = 2"))
        #expect(!plain.contains("\u{1B}"))
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func changedRowsKeepSyntaxAndBackgroundThroughEveryReset(palette: TerminalMarkdownPalette) {
        for (marker, background) in [("+", palette.diffAdditionBackground), ("-", palette.diffRemovalBackground)] {
            let rows = TerminalCodeBlockRenderer.renderCodeLine(
                "\(marker)\tlet value: String = \"text\" // comment",
                language: "diff-swift", width: 64, palette: palette
            )
            #expect(rows.count == 1)
            for row in rows {
                expectBackground(row, background: background, width: 64, palette: palette)
                #expect(TerminalANSIText.stripANSI(row).hasPrefix("\(marker)    let value: String = \"text\" // comment"))
                #expect(row.contains("\(palette.syntaxKeyword)let"))
                #expect(row.contains("\(palette.syntaxType)String"))
                #expect(row.contains("\(palette.syntaxString)\"text\""))
                #expect(row.contains("\(palette.syntaxComment)// comment"))
            }
            let blank = TerminalCodeBlockRenderer.renderCodeLine(
                marker, language: "diff-swift", width: 64, palette: palette
            )
            #expect(TerminalANSIText.stripANSI(blank[0]) == marker + String(repeating: " ", count: 63))
            expectBackground(blank[0], background: background, width: 64, palette: palette)
        }
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func longUnicodeLinesWrapWithoutDroppingSyntaxOrRowBackground(palette: TerminalMarkdownPalette) {
        let payload = "\"" + String(repeating: "界e\u{301}🚀", count: 18) + "\""
        for (marker, background) in [("+", palette.diffAdditionBackground), ("-", palette.diffRemovalBackground)] {
            let rows = TerminalCodeBlockRenderer.renderCodeLine(
                marker + payload, language: "diff-swift", width: 19, palette: palette
            )
            #expect(rows.count > 2)
            for row in rows {
                expectBackground(row, background: background, width: 19, palette: palette)
                #expect(row.contains(palette.syntaxString))
            }
            let reassembled = rows.enumerated().map { index, row in
                let visible = TerminalANSIText.stripANSI(row)
                let source = index == 0 ? visible : String(visible.dropFirst(2))
                if index > 0 { #expect(visible.hasPrefix("↳ ")) }
                return source.trimmingCharacters(in: .whitespaces)
            }.joined()
            #expect(reassembled == marker + payload)
        }
    }

    @Test
    func diffPrefixDoesNotConfuseJSONPropertyHighlighting() {
        let palette = TerminalMarkdownPalette.dark
        let row = TerminalCodeBlockRenderer.renderCodeLine(
            "+  \"name\": \"value\",", language: "diff-json", width: 40, palette: palette
        )[0]
        #expect(row.contains("\(palette.syntaxProperty)\"name\""))
        #expect(row.contains("\(palette.syntaxString)\"value\""))
        expectBackground(row, background: palette.diffAdditionBackground, width: 40, palette: palette)
    }

    @Test
    func unknownSourceStaysNeutralAndControlSequencesCannotResetItsBackground() throws {
        let palette = TerminalMarkdownPalette.dark
        let row = TerminalCodeBlockRenderer.renderCodeLine(
            "+let value = \"text\"\u{1B}[0m", language: "diff", width: 40, palette: palette
        )[0]
        #expect(TerminalANSIText.stripANSI(row).contains("+let value = \"text\"␛[0m"))
        // The addition marker shares syntaxString's color; only the source
        // segment after its reset must remain free of syntax highlighting.
        let marker = try #require(row.range(of: "\(palette.diffAddition)+\(TerminalStyle.reset)"))
        let source = row[marker.upperBound...]
        #expect(!source.contains(palette.syntaxKeyword))
        #expect(!source.contains(palette.syntaxString))
        expectBackground(row, background: palette.diffAdditionBackground, width: 40, palette: palette)
    }

    @Test
    func hunkStateDistinguishesHeaderLikeSourceAndDoesNotLeakToNextFileOrProse() {
        let palette = TerminalMarkdownPalette.dark
        let source = """
        ```diff-swift
        --- a/First.swift
        +++ b/First.swift
        @@ -1,2 +1,2 @@
        --- oldSource
        +++ newSource
         let context = true
        --- a/Second.swift
        +++ b/Second.swift
        @@ -1 +1 @@
        -let old = 1
        +let new = 2
        ```

        Tail prose
        """
        var renderer = TerminalSwiftMarkdownRenderer(supportsHyperlinks: false, renderWidth: 48, palette: palette)
        let complete = renderer.visit(Document(parsing: source))
        var stream = TerminalMarkdownStreamFormatter(
            isEnabled: true, renderWidth: 49, supportsHyperlinks: false, palette: palette
        )
        // Exercise split fences, prefixes and hunk ranges rather than supplying
        // one complete Markdown delta to the streaming implementation.
        var streamed = ""
        for character in source { streamed += stream.consume(String(character)) }
        streamed += stream.finish()
        let completeRows = complete.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        let rows = streamed.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        #expect(completeRows.last == rows.last)
        #expect(TerminalANSIText.stripANSI(rows.last ?? "") == "Tail prose")
        // Ignore only empty separators between the block and final prose;
        // retain every ANSI sequence, code-space and internal block row.
        let completeBlockRows = completeRows.dropLast().reversed()
            .drop(while: { $0.isEmpty }).reversed()
        let streamedBlockRows = rows.dropLast().reversed()
            .drop(while: { $0.isEmpty }).reversed()
        #expect(Array(completeBlockRows) == Array(streamedBlockRows))
        for row in rows {
            let visible = TerminalANSIText.stripANSI(row)
            if visible.hasPrefix("--- oldSource") {
                expectBackground(row, background: palette.diffRemovalBackground, width: 48, palette: palette)
            } else if visible.hasPrefix("+++ newSource") {
                expectBackground(row, background: palette.diffAdditionBackground, width: 48, palette: palette)
            } else if visible.hasPrefix("--- a/") || visible.hasPrefix("+++ b/")
                        || visible.hasPrefix("@@") || visible.hasPrefix(" let context") {
                #expect(!row.contains(palette.diffAdditionBackground))
                #expect(!row.contains(palette.diffRemovalBackground))
                #expect(row.hasSuffix(TerminalStyle.reset))
            } else if visible.contains("Tail prose") {
                #expect(!row.contains(palette.diffAdditionBackground))
                #expect(!row.contains(palette.diffRemovalBackground))
            }
        }
        #expect(streamed.contains("\(palette.syntaxKeyword)let"))
    }

    private func render(_ artifact: FileChangeArtifact) -> String {
        TerminalChat.renderFileArtifacts([.init(number: 1, artifacts: [artifact])])
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
        // Every reset inside a physical row must restore the same base style
        // before another visible character or padding space is emitted.
        #expect(resets.dropFirst().dropLast().allSatisfy { $0.hasPrefix(style) })
        #expect(resets.last == "")
    }
}
