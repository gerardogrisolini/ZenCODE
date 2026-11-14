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
    func tablesReservePresentationIndentationInTheirLayoutWidth() {
        let terminalWidth = 24
        let prefix = "   "
        var stream = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: terminalWidth,
            supportsHyperlinks: false,
            presentationPrefixWidth: TerminalANSIText.visibleWidth(prefix),
            palette: .dark
        )
        let source = """
        | Name | Description |
        | --- | --- |
        | item | A deliberately long table value |
        """

        let rendered = stream.consume(source) + stream.finish()
        let nested = TerminalChatRenderCoordinator.indentedMarkdown(
            rendered,
            with: prefix
        )
        var isAtLineStart = true
        let chatInsetRows = TerminalANSIText.stripANSI(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: nested,
                prefix: TerminalChatTextFormatting.chatLineInsetPrefix,
                isAtLineStart: &isAtLineStart
            )
        )
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        #expect(!chatInsetRows.isEmpty)
        #expect(chatInsetRows.allSatisfy {
            TerminalANSIText.visibleWidth($0) <= terminalWidth
        })
    }

    @Test
    func fencedCodeBlocksReservePresentationIndentationAndChatInsetInTheirLayoutWidth() {
        let terminalWidth = 24
        let prefix = "   "
        var stream = TerminalMarkdownStreamFormatter(
            isEnabled: true,
            renderWidth: terminalWidth,
            supportsHyperlinks: false,
            presentationPrefixWidth: TerminalANSIText.visibleWidth(prefix),
            palette: .dark
        )
        let source = """
        ```swift
        let value = "a deliberately long code value"
        ```
        """

        let rendered = stream.consume(source) + stream.finish()
        let nested = TerminalChatRenderCoordinator.indentedMarkdown(
            rendered,
            with: prefix
        )
        var isAtLineStart = true
        let chatInsetRows = TerminalANSIText.stripANSI(
            TerminalChatTextFormatting.chatLineInsetApplied(
                to: nested,
                prefix: TerminalChatTextFormatting.chatLineInsetPrefix,
                isAtLineStart: &isAtLineStart
            )
        )
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)

        #expect(!chatInsetRows.isEmpty)
        #expect(chatInsetRows.allSatisfy {
            TerminalANSIText.visibleWidth($0) <= terminalWidth
        })
    }

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

        let rows = streamed
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        #expect(!rows.isEmpty)
        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) == 24 })
        // The long line still wraps, but its continuation rows carry no marker:
        // header + wrapped line (at least two rows) + short line.
        #expect(rows.count >= 4)
        #expect(!TerminalANSIText.stripANSI(streamed).contains("↳"))
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

    // MARK: - Erase to end of line

    private static let erase = "\u{1B}[K"
    private static let reset = TerminalStyle.reset
    private static let sampleLines = [
        "let a = 1",
        "",
        "\tlet 名称 = \"a deliberately long value that must wrap safely\"",
        "    indented with trailing spaces   ",
        "let exactlyfits = \"abcd\"",
    ]

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func shortRowEndsWithEraseToEndOfLineInsteadOfPadding(palette: TerminalMarkdownPalette) {
        let line = "let a = 1"
        let rows = TerminalCodeBlockRenderer.renderCodeLine(
            line, language: "swift", width: 40, palette: palette, usesEraseToEndOfLine: true
        )
        let style = palette.codeForeground + palette.codeBackground
        let content = TerminalCodeBlockRenderer.renderLine(line, language: "swift", palette: palette)
            .replacingOccurrences(of: Self.reset, with: Self.reset + style)

        #expect(rows == [style + content + Self.erase + Self.reset])
        #expect(TerminalANSIText.stripANSI(rows[0]) == line)
        #expect(TerminalANSIText.visibleWidth(rows[0]) == line.count)
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func diffRowsKeepTheirAdditionAndRemovalBackgroundWithEraseToEndOfLine(
        palette: TerminalMarkdownPalette
    ) {
        for (marker, background) in [("+", palette.diffAdditionBackground), ("-", palette.diffRemovalBackground)] {
            let rows = TerminalCodeBlockRenderer.renderCodeLine(
                marker + "let a = 1", language: "diff-swift", width: 40, palette: palette,
                usesEraseToEndOfLine: true
            )
            #expect(rows.count == 1)
            let row = rows[0]
            #expect(row.hasPrefix(palette.codeForeground + background))
            #expect(row.hasSuffix(Self.erase + Self.reset))
            #expect(TerminalANSIText.stripANSI(row) == marker + "let a = 1")
            #expect(!row.contains(palette.codeBackground))
        }
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func numberedArtifactRowsKeepTheGutterWithEraseToEndOfLine(palette: TerminalMarkdownPalette) {
        let rows = TerminalCodeBlockRenderer.renderCodeLine(
            "42 │ +let a = 1", language: "artifact-diff-swift", width: 40, palette: palette,
            usesEraseToEndOfLine: true
        )
        #expect(rows.count == 1)
        #expect(rows[0].hasPrefix(palette.codeForeground + palette.diffAdditionBackground))
        #expect(rows[0].hasSuffix(Self.erase + Self.reset))
        #expect(rows[0].contains("\(palette.syntaxComment)42 │ \(Self.reset)"))
        #expect(TerminalANSIText.stripANSI(rows[0]) == "42 │ +let a = 1")
    }

    @Test
    func emptySourceRowCarriesOneVisibleCellBeforeTheErase() {
        let palette = TerminalMarkdownPalette.dark
        let style = palette.codeForeground + palette.codeBackground
        let rows = TerminalCodeBlockRenderer.renderCodeLine(
            "", language: "swift", width: 20, palette: palette, usesEraseToEndOfLine: true
        )
        #expect(rows == [style + " " + Self.erase + Self.reset])
    }

    @Test
    func aRowThatAlreadyFillsTheSurfaceHasNoErase() {
        let palette = TerminalMarkdownPalette.dark
        let line = String(repeating: "a", count: 20)
        let rows = TerminalCodeBlockRenderer.renderCodeLine(
            line, language: "text", width: 20, palette: palette, usesEraseToEndOfLine: true
        )
        #expect(rows.count == 1)
        #expect(!rows[0].contains(Self.erase))
        #expect(rows[0].hasSuffix(Self.reset))
        #expect(TerminalANSIText.stripANSI(rows[0]) == line)

        // One column wider wraps: the full row stays erase-free, the rest erases.
        let wrapped = TerminalCodeBlockRenderer.renderCodeLine(
            line + "b", language: "text", width: 20, palette: palette, usesEraseToEndOfLine: true
        )
        #expect(wrapped.count == 2)
        #expect(!wrapped[0].contains(Self.erase))
        #expect(wrapped[1].hasSuffix(Self.erase + Self.reset))
        #expect(TerminalANSIText.stripANSI(wrapped[1]) == "b")
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func longRowsWrapWithoutMarkerOrIndentAndKeepEveryRowWithinTheWidth(palette: TerminalMarkdownPalette) {
        let line = "let explanation = \"a deliberately long value that must wrap safely\""
        let rows = TerminalCodeBlockRenderer.renderCodeLine(
            line, language: "swift", width: 24, palette: palette, usesEraseToEndOfLine: true
        )
        #expect(rows.count > 2)
        for row in rows {
            #expect(TerminalANSIText.visibleWidth(row) <= 24)
            #expect(row.hasSuffix(Self.reset))
        }
        let visible = rows.map(TerminalANSIText.stripANSI)
        #expect(visible.joined() == line)
        #expect(visible.allSatisfy { !$0.contains("↳") && !$0.contains("›") })
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func eraseRowsMatchTheFilledRowsExceptForTheirTail(palette: TerminalMarkdownPalette) {
        let width = 24
        let languages = ["swift", "diff-swift", "artifact-diff-swift"]
        for language in languages {
            for sample in Self.sampleLines {
                let line: String
                switch language {
                case "diff-swift": line = "+" + sample
                case "artifact-diff-swift": line = "42 │ +" + sample
                default: line = sample
                }
                let filled = TerminalCodeBlockRenderer.renderCodeLine(
                    line, language: language, width: width, palette: palette
                )
                let erased = TerminalCodeBlockRenderer.renderCodeLine(
                    line, language: language, width: width, palette: palette,
                    usesEraseToEndOfLine: true
                )
                #expect(filled.count == erased.count, "\(language): \(line)")
                for (fill, erase) in zip(filled, erased) {
                    #expect(TerminalANSIText.visibleWidth(fill) == width)
                    let tail = erase.hasSuffix(Self.erase + Self.reset)
                        ? Self.erase + Self.reset : Self.reset
                    let body = String(erase.dropLast(tail.count))
                    let padding = String(
                        repeating: " ", count: width - TerminalANSIText.visibleWidth(erase)
                    )
                    let expected: String = body + padding + Self.reset
                    #expect(fill == expected, "\(language): \(line)")
                }
            }
        }
    }

    @Test(arguments: [TerminalMarkdownPalette.dark, .light])
    func headerEndsWithEraseToEndOfLineInsteadOfPadding(palette: TerminalMarkdownPalette) {
        let header = TerminalCodeBlockRenderer.renderHeader(
            language: "swift", width: 24, palette: palette, usesEraseToEndOfLine: true
        )
        let style = palette.codeHeaderForeground + palette.codeHeaderBackground
        #expect(header == style + "  Code · Swift" + Self.erase + Self.reset)
        #expect(TerminalANSIText.stripANSI(header) == "  Code · Swift")

        // The defaults keep the filled header.
        let filled = TerminalCodeBlockRenderer.renderHeader(language: "swift", width: 24, palette: palette)
        #expect(TerminalANSIText.visibleWidth(filled) == 24)
        #expect(!filled.contains(Self.erase))
    }

    @Test
    func zeroWidthSurfacesNeverUseTheErase() {
        let palette = TerminalMarkdownPalette.dark
        let erased = TerminalCodeBlockRenderer.renderBlock(
            "let a = 1\n\nlet b = 2", language: "swift", width: 0, palette: palette,
            usesEraseToEndOfLine: true
        )
        let plain = TerminalCodeBlockRenderer.renderBlock(
            "let a = 1\n\nlet b = 2", language: "swift", width: 0, palette: palette
        )
        #expect(erased == plain)
        #expect(!erased.contains(Self.erase))
    }

    @Test
    func defaultsKeepFillingRowsToTheFullWidth() {
        let palette = TerminalMarkdownPalette.dark
        let block = TerminalCodeBlockRenderer.renderBlock(
            "let a = 1\n\nlet b = 2", language: "swift", width: 24, palette: palette
        )
        let rows = block.components(separatedBy: "\n")
        #expect(rows.count == 4)
        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) == 24 })
        #expect(!block.contains(Self.erase))
    }

    // MARK: - Markdown surfaces

    private static let fencedSource = """
    ```swift
    let a = 1

    let longer = "a deliberately long value that must wrap safely"
    ```
    """

    @Test
    func streamingFencedCodeUsesEraseToEndOfLineAndMatchesTheDocumentRenderer() {
        let palette = TerminalMarkdownPalette.dark
        var stream = TerminalMarkdownStreamFormatter(
            isEnabled: true, renderWidth: 25, supportsHyperlinks: false, palette: palette,
            codeBlocksUseEraseToEndOfLine: true
        )
        let streamed = stream.consume(Self.fencedSource) + stream.finish()
        var renderer = TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: false, renderWidth: 24, palette: palette,
            codeBlocksUseEraseToEndOfLine: true
        )
        let complete = renderer.visit(Document(parsing: Self.fencedSource))

        #expect(complete == streamed.trimmingCharacters(in: .newlines))
        let rows = streamed.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(rows.count > 4) // header, short, blank, and a wrapped line
        for row in rows {
            #expect(row.hasSuffix(Self.reset))
            #expect(TerminalANSIText.visibleWidth(row) <= 24)
        }
        // Rows shorter than the surface end with the erase; none is padded.
        let short = rows.filter { TerminalANSIText.visibleWidth($0) < 24 }
        #expect(!short.isEmpty)
        #expect(short.allSatisfy { $0.hasSuffix(Self.erase + Self.reset) })
        #expect(TerminalANSIText.stripANSI(streamed).contains("Code · Swift"))
        #expect(!TerminalANSIText.stripANSI(streamed).contains("↳"))
    }

    @Test
    func streamingFencedCodeWithDefaultsStaysFilledToTheFullWidth() {
        let palette = TerminalMarkdownPalette.dark
        var stream = TerminalMarkdownStreamFormatter(
            isEnabled: true, renderWidth: 25, supportsHyperlinks: false, palette: palette
        )
        let streamed = stream.consume(Self.fencedSource) + stream.finish()
        #expect(!streamed.contains(Self.erase))
        let rows = streamed.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) == 24 })
    }

    @Test
    func codeBlockNestedInAListUsesEraseToEndOfLineThroughTheDocumentRenderer() {
        // A fence inside a list item is flushed through `makeRenderer()` and
        // `visitCodeBlock`, not through the stream's own fence handling.
        let source = "- ```swift\n  let a = 1\n  let b = \"a deliberately long value that wraps around\""
        let palette = TerminalMarkdownPalette.dark
        var stream = TerminalMarkdownStreamFormatter(
            isEnabled: true, renderWidth: 41, supportsHyperlinks: false, palette: palette,
            codeBlocksUseEraseToEndOfLine: true
        )
        let streamed = stream.consume(source) + stream.finish()
        var renderer = TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: false, renderWidth: 40, palette: palette,
            codeBlocksUseEraseToEndOfLine: true
        )
        let complete = renderer.visit(Document(parsing: source))

        #expect(streamed.contains(Self.erase))
        #expect(complete == streamed.trimmingCharacters(in: .newlines))
        let visible = TerminalANSIText.stripANSI(streamed)
        #expect(visible.contains("Code · Swift"))
        #expect(visible.contains("let a = 1"))
        #expect(!visible.contains("↳"))
        // The short rows end with the erase instead of padding spaces.
        let rows = streamed.components(separatedBy: "\n").filter { $0.contains(palette.codeBackground) }
        #expect(rows.count == 3)
        #expect(rows.filter { $0.hasSuffix(Self.erase + Self.reset) }.count == 2)

        var filled = TerminalMarkdownStreamFormatter(
            isEnabled: true, renderWidth: 41, supportsHyperlinks: false, palette: palette
        )
        let filledOutput = filled.consume(source) + filled.finish()
        #expect(!filledOutput.contains(Self.erase))
        var filledRenderer = TerminalSwiftMarkdownRenderer(
            supportsHyperlinks: false, renderWidth: 40, palette: palette
        )
        #expect(
            filledRenderer.visit(Document(parsing: source))
                == filledOutput.trimmingCharacters(in: .newlines)
        )
    }

    @Test
    func theChatMarginPrecedesTheStyleOfEveryEraseRowIncludingTheBlankOne() {
        let palette = TerminalMarkdownPalette.dark
        let block = TerminalCodeBlockRenderer.renderBlock(
            "let a = 1\n\nlet b = 2", language: "swift", width: 24, palette: palette,
            usesEraseToEndOfLine: true
        )
        var state = TerminalChatTextFormatting.ChatLineInsetState()
        let inset = TerminalChatTextFormatting.chatLineInsetApplied(
            to: block + "\n", prefix: " ", state: &state
        )
        let rows = inset.components(separatedBy: "\n").dropLast()
        #expect(rows.count == 4)
        let headerStyle = palette.codeHeaderForeground + palette.codeHeaderBackground
        let codeStyle = palette.codeForeground + palette.codeBackground
        #expect(rows.first?.hasPrefix(" " + headerStyle) == true)
        for row in rows.dropFirst() {
            #expect(row.hasPrefix(" " + codeStyle))
        }
        // The blank source row owes its margin to the visible cell it carries.
        #expect(rows[2] == " " + codeStyle + " " + Self.erase + Self.reset)
    }

    // Every keyword below belongs to its language profile and is absent from the
    // generic one, so a language that falls back to `.generic` (or lands on the
    // wrong profile) renders the bare word instead of a highlighted keyword.
    @Test(arguments: [
        ("swift", "guard"),
        ("javascript", "instanceof"),
        ("typescript", "instanceof"),
        ("python", "lambda"),
        ("shell", "esac"),
        ("rust", "impl"),
        ("go", "chan"),
        ("c", "typedef"),
        ("cpp", "typedef"),
        ("objc", "typedef"),
        ("java", "sealed"),
        ("kotlin", "sealed"),
        ("csharp", "sealed"),
        ("php", "foreach"),
        ("ruby", "elsif"),
        ("sql", "SELECT"),
        ("docker", "ENTRYPOINT"),
    ])
    func everyProfileLanguageHighlightsItsOwnKeyword(language: String, keyword: String) {
        let palette = TerminalMarkdownPalette.dark

        #expect(
            TerminalCodeBlockRenderer.renderLine(keyword, language: language, palette: palette)
                == "\(palette.syntaxKeyword)\(keyword)\(TerminalStyle.reset)"
        )
    }
}
