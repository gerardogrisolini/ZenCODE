import Foundation
import Markdown
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct TerminalArtifactColorTests {
    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func canonicalMetadataColorsOnlyCountsAndPreservesPlainMarkdown(palette: TerminalMarkdownPalette) {
        let path = "dir/+12 -345 e\u{301}界.swift"
        let explanation = "Explanation: Prose keeps +12 -345 neutral."
        for status in [FileChangeArtifact.Status.added, .modified, .deleted, .unknown] {
            for isBinary in [false, true] {
                for (additions, deletions) in [(0, 0), (12, 345)] {
                    let artifact = FileChangeArtifact(
                        absolutePath: "/tmp/\(path)", displayPath: path, status: status,
                        additions: additions, deletions: deletions, isBinary: isBinary,
                        explanation: "Prose keeps +12 -345 neutral."
                    )
                    let turns = [SessionFileArtifactHistory.Turn(number: 1, artifacts: [artifact])]
                    let markdown = TerminalChat.renderFileArtifacts(
                        turns, includeHistoryHeadings: false, columnWidth: 12, isEnabled: false
                    )
                    let suffix = isBinary ? " (binary)" : ""
                    #expect(markdown == "\n**\(status.rawValue) `\(path)`**  +\(additions) -\(deletions)\(suffix)\n\(explanation)\n")
                    #expect(markdown == TerminalChat.renderFileArtifacts(
                        turns, includeHistoryHeadings: false, columnWidth: 120, isEnabled: true
                    ))
                    #expect(!markdown.contains("\u{1B}"))

                    var disabled = TerminalMarkdownStreamFormatter(isEnabled: false, renderWidth: 0, supportsHyperlinks: false, palette: palette)
                    var plain = ""
                    for scalar in markdown.unicodeScalars { plain += disabled.consume(String(scalar)) }
                    plain += disabled.finish()
                    #expect(plain == markdown)

                    var renderer = TerminalSwiftMarkdownRenderer(
                        supportsHyperlinks: false, renderWidth: 0, palette: palette
                    )
                    let complete = renderer.visit(Document(parsing: markdown))
                    var stream = TerminalMarkdownStreamFormatter(
                        isEnabled: true, renderWidth: 0, supportsHyperlinks: false, palette: palette
                    )
                    var streamed = ""
                    for scalar in markdown.unicodeScalars { streamed += stream.consume(String(scalar)) }
                    streamed += stream.finish()
                    let rows = nonemptyRows(complete)
                    #expect(rows == nonemptyRows(streamed))
                    #expect(rows.count == 2)
                    let header = rows.first ?? ""
                    let coloredCounts = "  \(palette.diffAddition)+\(additions)\(TerminalStyle.reset) "
                        + "\(palette.diffRemoval)-\(deletions)\(TerminalStyle.reset)\(suffix)"
                    #expect(header.hasSuffix(coloredCounts))
                    #expect(TerminalANSIText.stripANSI(header) == "\(status.rawValue) \(path)  +\(additions) -\(deletions)\(suffix)")
                    #expect(header.contains("\(palette.inlineCodeBackground)\(palette.inlineCodeForeground)\(path)"))
                    #expect(rows.last == explanation)
                }
            }
        }
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func fullArtifactsShareHeaderAndGrayGutterColorsAndResetBeforeProse(palette: TerminalMarkdownPalette) throws {
        let artifact = FileChangeArtifact(
            absolutePath: "/tmp/File.swift", displayPath: "File.swift", status: .modified,
            additions: 1, deletions: 1,
            oldText: "let unchanged = 0\nlet value: String = \"old\"\n",
            newText: "let unchanged = 0\nlet value: String = \"new\"\n"
        )
        let turns = [SessionFileArtifactHistory.Turn(number: 1, artifacts: [artifact])]
        let source = TerminalChat.renderFileArtifacts(turns, includeHistoryHeadings: false)
            + "\nTail prose\n"
        var renderer = TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: false, renderWidth: 40, palette: palette
        )
        let complete = renderer.visit(Document(parsing: source))
        var stream = TerminalMarkdownStreamFormatter(
            isEnabled: true, renderWidth: 41, supportsHyperlinks: false, palette: palette
        )
        var streamed = ""
        for scalar in source.unicodeScalars { streamed += stream.consume(String(scalar)) }
        streamed += stream.finish()
        let rows = nonemptyRows(complete)
        #expect(rows == nonemptyRows(streamed))
        #expect(rows.last == "Tail prose")
        let header = try #require(rows.first)
        #expect(header.hasSuffix("\(palette.diffAddition)+1\(TerminalStyle.reset) \(palette.diffRemoval)-1\(TerminalStyle.reset)"))
        var gutters = 0
        for row in rows {
            let visible = TerminalANSIText.stripANSI(row)
            guard let separator = visible.range(of: " │ ") else { continue }
            gutters += 1
            let gutter = String(visible[..<separator.upperBound])
            let source = visible[separator.upperBound...]
            let background: String
            switch source.first {
            case "+": background = palette.diffAdditionBackground
            case "-": background = palette.diffRemovalBackground
            default: background = palette.codeBackground
            }
            let style = palette.codeForeground + background
            #expect(row.hasPrefix(style + palette.syntaxComment + gutter + TerminalStyle.reset + style))
            expectRowResets(row, style: style, width: 40)
            if source.contains("let") { #expect(row.contains("\(palette.syntaxKeyword)let")) }
            if source.contains("String") { #expect(row.contains("\(palette.syntaxType)String")) }
            if source.first == "+" {
                #expect(row.contains("\(palette.diffAddition)+\(TerminalStyle.reset)\(style)"))
                #expect(row.contains("\(palette.syntaxString)\"new\""))
            } else if source.first == "-" {
                #expect(row.contains("\(palette.diffRemoval)-\(TerminalStyle.reset)\(style)"))
                #expect(row.contains("\(palette.syntaxString)\"old\""))
            }
        }
        #expect(gutters == 4)
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func grayGuttersDoNotChangeAnyDiffSourceANSIOrWrapping(palette: TerminalMarkdownPalette) {
        let payload = "let value: String = \"" + String(repeating: "界e\u{301}🚀", count: 8) + "\"\u{1B}[0m"
        let changes: [(String, TerminalCodeBlockRenderer.DiffLineKind, String)] = [
            ("+", .addition, palette.diffAdditionBackground),
            ("-", .removal, palette.diffRemovalBackground),
            (" ", .context, palette.codeBackground),
        ]
        for (marker, kind, background) in changes {
            for width in [0, 19, 64] {
                for source in [payload, ""] {
                    let rows = TerminalCodeBlockRenderer.renderCodeLine(
                        "42 │ " + marker + source, language: "artifact-diff-swift",
                        width: width, palette: palette, diffKind: kind
                    )
                    let ordinaryRows = TerminalCodeBlockRenderer.renderCodeLine(
                        marker + source, language: "diff-swift",
                        width: width == 0 ? 0 : width - 5, palette: palette, diffKind: kind
                    )
                    #expect(rows.count == ordinaryRows.count)
                    let style = palette.codeForeground + background
                    for (index, pair) in zip(rows, ordinaryRows).enumerated() {
                        let gutter = index == 0 ? "42 │ " : "   │ "
                        // Removing only the muted gutter leaves the original diff row
                        // byte-for-byte, including syntax, background, padding and resets.
                        #expect(pair.0 == style + palette.syntaxComment + gutter + TerminalStyle.reset + pair.1)
                        #expect(TerminalANSIText.stripANSI(pair.0) == gutter + TerminalANSIText.stripANSI(pair.1))
                        expectRowResets(pair.0, style: style, width: width)
                    }
                }
            }
        }
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func nonArtifactProseAndOtherMarkdownBlocksDoNotAcquireCountColors(palette: TerminalMarkdownPalette) {
        let samples = [
            "+12 -345",
            "Statistics **modified** +12 -345",
            "**modified File.swift**  +12 -345",
            "**reviewed `File.swift`**  +12 -345",
            "**modified `File.swift`** +12 -345",
            "**modified `File.swift`**  +oops -345",
            "**modified `File.swift`**  +12 -345.0",
            "**modified `File.swift`**  +12 -345 trailing prose",
            "**modified `File.swift`**  +12 -345 **after**",
            "- **modified `File.swift`**  +12 -345",
            "> **modified `File.swift`**  +12 -345",
            "## **modified `File.swift`**  +12 -345",
            "`+12 -345`",
            "```text\n**modified `File.swift`**  +12 -345\n```",
            "```diff\n+12 -345\n```",
        ]
        for source in samples {
            var renderer = TerminalSwiftMarkdownRenderer(
                supportsHyperlinks: false, renderWidth: 0, palette: palette
            )
            let complete = renderer.visit(Document(parsing: source))
            var stream = TerminalMarkdownStreamFormatter(
                isEnabled: true, renderWidth: 0, supportsHyperlinks: false, palette: palette
            )
            var streamed = ""
            for scalar in source.unicodeScalars { streamed += stream.consume(String(scalar)) }
            streamed += stream.finish()
            for rendered in [complete, streamed] {
                #expect(!rendered.contains("\(palette.diffAddition)+12\(TerminalStyle.reset)"))
                #expect(!rendered.contains("\(palette.diffRemoval)-345\(TerminalStyle.reset)"))
            }
        }
        for language in ["diff", "patch", "diff-swift", "swift", "text"] {
            let row = TerminalCodeBlockRenderer.renderCodeLine(
                "42 │ +let value = 1", language: language, width: 40, palette: palette
            )[0]
            #expect(!row.contains("\(palette.syntaxComment)42 │ \(TerminalStyle.reset)"))
            #expect(TerminalANSIText.stripANSI(row).hasPrefix("42 │ +let value = 1"))
        }
    }

    private func nonemptyRows(_ text: String) -> [String] {
        text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    private func expectRowResets(_ row: String, style: String, width: Int) {
        #expect(row.hasPrefix(style))
        #expect(row.hasSuffix(TerminalStyle.reset))
        if width > 0 { #expect(TerminalANSIText.visibleWidth(row) == width) }
        let resets = row.components(separatedBy: TerminalStyle.reset)
        #expect(resets.dropFirst().dropLast().allSatisfy { $0.hasPrefix(style) })
        #expect(resets.last == "")
    }
}
