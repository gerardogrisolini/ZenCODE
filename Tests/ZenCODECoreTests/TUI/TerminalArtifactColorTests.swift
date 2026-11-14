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
                    let markdown = TerminalChat.renderFileArtifacts(turns, includeHistoryHeadings: false)
                    let suffix = isBinary ? " (binary)" : ""
                    #expect(markdown == "\n**\(status.rawValue) `\(path)`**  +\(additions) -\(deletions)\(suffix)\n\(explanation)\n")
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
