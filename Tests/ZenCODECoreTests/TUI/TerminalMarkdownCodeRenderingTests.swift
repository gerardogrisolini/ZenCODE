//
//  TerminalMarkdownCodeRenderingTests.swift
//  ZenCODE
//

import Foundation
import Markdown
import Testing
@testable import ZenCODECore

@Suite
struct TerminalMarkdownCodeRenderingTests {
    @Test
    func completeAndStreamingCodeBlocksShareHeaderWrappingAndWidthSemantics() {
        let source = """
        ```swift
        let 名称 = \"a deliberately long value that must wrap safely\"
        let short = 1
        ```
        """
        let palette = TerminalMarkdownPalette.dark
        var documentRenderer = TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: false,
            renderWidth: 24,
            palette: palette
        )
        let complete = documentRenderer.visit(Document(parsing: source))

        var stream = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 25,
            supportsHyperlinks: false,
            palette: palette
        )
        let streamed = stream.consume(source) + stream.finish()

        // The streaming formatter reserves one column for the chat inset, so
        // its 25-column host width matches the direct renderer's 24 columns.
        #expect(complete == streamed.trimmingCharacters(in: .newlines))
        #expect(!streamed.contains("```"))
        #expect(TerminalANSIText.stripANSI(streamed).contains("Code · Swift"))
        #expect(TerminalANSIText.stripANSI(streamed).contains("↳"))

        let rows = streamed
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) == 24 })
    }

    @Test
    func streamingCodeBlocksCanPreserveLogicalLinesWithoutWidthBasedContinuationRows() {
        let longLine = "let explanation = \"a deliberately long value that must remain one logical line\""
        let fencedSource = "```swift\n\(longLine)\n```\n"
        let indentedSource = "    \(longLine)\n"

        for source in [fencedSource, indentedSource] {
            var stream = TerminalMarkdownStreamFormatter(
                isEnabled: true,
                renderWidth: 20,
                supportsHyperlinks: false,
                usesTerminalWidthForStructuredContent: false,
                palette: .dark
            )
            let rendered = stream.consume(source) + stream.finish()
            let visible = TerminalANSIText.stripANSI(rendered)

            #expect(visible.contains(longLine))
            #expect(!visible.contains("↳"))
        }
    }

    @Test
    func streamingBacktickFenceMatchesCompleteParserForLongRunsAndFalseClosers() {
        let source = """
        ````text
        before
        ```
        after
        ``` not a close
        ````
        tail
        """
        let palette = TerminalMarkdownPalette.dark
        var documentRenderer = TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: false,
            renderWidth: 40,
            palette: palette
        )
        let complete = documentRenderer.visit(Document(parsing: source))
        var stream = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 41,
            supportsHyperlinks: false,
            palette: palette
        )
        let streamed = stream.consume(source) + stream.finish()

        #expect(complete == streamed.trimmingCharacters(in: .newlines))
        let visible = TerminalANSIText.stripANSI(streamed)
        #expect(visible.contains("```"))
        #expect(visible.contains("``` not a close"))
        #expect(visible.contains("\n\ntail"))
    }

    @Test
    func streamingTildeFenceMatchesCompleteParser() {
        let source = """
        ~~~swift
        let value = 1
        ~~~
        after
        """
        let palette = TerminalMarkdownPalette.dark
        var documentRenderer = TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: false,
            renderWidth: 32,
            palette: palette
        )
        let complete = documentRenderer.visit(Document(parsing: source))
        var stream = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 33,
            supportsHyperlinks: false,
            palette: palette
        )
        let streamed = stream.consume(source) + stream.finish()

        #expect(complete == streamed.trimmingCharacters(in: .newlines))
        #expect(TerminalANSIText.stripANSI(streamed).contains("Code · Swift"))
        #expect(!streamed.contains("~~~"))
    }

    @Test
    func codePayloadControlsAndTabsAreVisibleSafeAndWidthStable() {
        let palette = TerminalMarkdownPalette.dark
        let payload = "a\tb\r\u{1B}[31mred\u{202E}x"
        let highlighted = TerminalCodeBlockRenderer.renderLine(
            payload,
            language: "text",
            palette: palette
        )

        #expect(TerminalANSIText.stripANSI(highlighted) == "a   b␍␛[31mred�x")
        #expect(!highlighted.contains("\t"))
        #expect(!highlighted.contains("\r"))
        #expect(!highlighted.contains("\u{1B}[31m"))

        let rows = TerminalCodeBlockRenderer.renderCodeLine(
            payload,
            language: "text",
            width: 12,
            palette: palette
        )
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) == 12 })
    }

    @Test
    func streamingCodeFenceNormalizesSplitCRLFAndExpandsTabs() {
        var stream = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: 41,
            supportsHyperlinks: false,
            palette: .dark
        )
        var rendered = ""
        for delta in ["```text\r", "\nleft\tright\r", "\n```\r", "\n"] {
            rendered += stream.consume(delta)
        }
        rendered += stream.finish()

        let visible = TerminalANSIText.stripANSI(rendered)
        #expect(visible.contains("left    right"))
        #expect(!visible.contains("␍"))
        #expect(!rendered.contains("\t"))
        #expect(!rendered.contains("\r"))
    }

    @Test
    func diffRowsUseDedicatedSemanticStyles() {
        let palette = TerminalMarkdownPalette.dark
        let rendered = TerminalCodeBlockRenderer.renderBlock(
            """
            diff --git a/File.swift b/File.swift
            --- a/File.swift
            +++ b/File.swift
            @@ -1,2 +1,2 @@
            -let old = 1
            +let new = 2
             let unchanged = true
            """,
            language: "diff",
            width: 60,
            palette: palette
        )

        #expect(rendered.contains("\(palette.diffHeader)--- a/File.swift"))
        #expect(rendered.contains("\(palette.diffHeader)+++ b/File.swift"))
        #expect(rendered.contains("\(palette.diffHunk)@@ -1,2 +1,2 @@"))
        #expect(rendered.contains("\(palette.diffRemoval)-let old = 1"))
        #expect(rendered.contains("\(palette.diffAddition)+let new = 2"))
    }

    @Test
    func headingOmitsSourceMarkersAndInlineCodeResetsItsBackground() {
        let palette = TerminalMarkdownPalette.dark
        var renderer = TerminalSwiftMarkdownRenderer(
            renderWidth: 80,
            palette: palette
        )
        let rendered = renderer.visit(Document(parsing: "## Heading `code` tail"))
        let visible = TerminalANSIText.stripANSI(rendered)

        #expect(visible == "Heading code tail")
        #expect(!visible.contains("#"))
        #expect(rendered.contains(
            "\(palette.inlineCodeBackground)\(palette.inlineCodeForeground)code\u{1B}[0m\(palette.headingStyles[1]) tail"
        ))
    }

    @Test
    func colorFGBGPaletteSelectionIsDeterministicAndLightPaletteIsInjectable() {
        #expect(TerminalMarkdownPalette.appearance(environment: [:]) == .dark)
        #expect(TerminalMarkdownPalette.appearance(environment: ["COLORFGBG": "15;0"]) == .dark)
        #expect(TerminalMarkdownPalette.appearance(environment: ["COLORFGBG": "0;15"]) == .light)
        #expect(TerminalMarkdownPalette.appearance(environment: ["COLORFGBG": "15;invalid"]) == .dark)
        #expect(TerminalMarkdownPalette.appearance(environment: ["COLORFGBG": "0;8"]) == .dark)
        #expect(TerminalMarkdownPalette.appearance(environment: ["COLORFGBG": "0;231"]) == .light)
        #expect(TerminalMarkdownPalette.appearance(environment: ["COLORFGBG": "15;232"]) == .dark)
        #expect(TerminalMarkdownPalette.appearance(environment: ["COLORFGBG": "0;255"]) == .light)

        let palette = TerminalMarkdownPalette.light
        var renderer = TerminalSwiftMarkdownRenderer(
            renderWidth: 80,
            palette: palette
        )
        let rendered = renderer.visit(Document(parsing: "Use `light code`"))

        #expect(rendered.contains(palette.inlineCodeForeground))
        #expect(rendered.contains(palette.inlineCodeBackground))
        #expect(!rendered.contains(TerminalMarkdownPalette.dark.inlineCodeBackground))

        let highlighted = TerminalCodeBlockRenderer.renderLine(
            "let value: String = \"light\" // note",
            language: "swift",
            palette: palette
        )
        #expect(highlighted.contains("\(palette.syntaxKeyword)let"))
        #expect(highlighted.contains("\(palette.syntaxType)String"))
        #expect(highlighted.contains("\(palette.syntaxString)\"light\""))
        #expect(highlighted.contains("\(palette.syntaxComment)// note"))
        #expect(!highlighted.contains(TerminalMarkdownPalette.dark.syntaxKeyword))
        #expect(!highlighted.contains(TerminalMarkdownPalette.dark.syntaxComment))
    }
}
