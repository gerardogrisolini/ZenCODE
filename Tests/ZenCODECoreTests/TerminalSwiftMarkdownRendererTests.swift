//
//  TerminalSwiftMarkdownRendererTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 20/06/26.
//

import Markdown
import Testing
@testable import ZenCODECore

@Suite
struct TerminalSwiftMarkdownRendererTests {
    @Test
    func separatesTopLevelParagraphsWithBlankLine() {
        var renderer = TerminalSwiftMarkdownRenderer()
        let document = Document(parsing: "First paragraph.\n\nSecond paragraph.")

        #expect(renderer.visit(document) == "First paragraph.\n\nSecond paragraph.")
    }

    @Test
    func nestedListIndentationDoesNotLeakPrivateMarkers() {
        var renderer = TerminalSwiftMarkdownRenderer()
        let document = Document(parsing: """
        - Parent
          - Child
        - Sibling
        """)

        let rendered = renderer.visit(document)
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines.count == 3)
        #expect(lines[1].hasPrefix("  \u{1B}[38;5;244m◦"))
        #expect(!rendered.contains("\u{E000}"))
    }

    @Test
    func tableHeaderStyleIsRestoredAfterInlineReset() {
        var renderer = TerminalSwiftMarkdownRenderer()
        let document = Document(parsing: """
        | Header `code` after |
        | --- |
        | value |
        """)

        let rendered = renderer.visit(document)

        #expect(rendered.contains("\u{1B}[38;5;180mcode\u{1B}[0m\u{1B}[1;38;5;81m after"))
    }

    @Test
    func headingStyleIsRestoredAfterInlineCodeReset() {
        var renderer = TerminalSwiftMarkdownRenderer()
        let document = Document(parsing: "## Title with `code` after")

        let rendered = renderer.visit(document)

        #expect(rendered.contains("\u{1B}[38;5;180mcode\u{1B}[0m\u{1B}[1;38;5;75m after"))
    }

    @Test
    func strongStyleIsRestoredAfterInlineCodeReset() {
        var renderer = TerminalSwiftMarkdownRenderer()
        let document = Document(parsing: "This is **bold `code` after** text")

        let rendered = renderer.visit(document)

        #expect(rendered.contains("\u{1B}[38;5;180mcode\u{1B}[0m\u{1B}[1m after"))
    }

    @Test
    func inlineHTMLIsRenderedInsteadOfDropped() {
        var renderer = TerminalSwiftMarkdownRenderer()
        let document = Document(parsing: "Hello <span>raw</span>")

        let rendered = renderer.visit(document)

        #expect(rendered.contains("<span>"))
        #expect(rendered.contains("</span>"))
    }

    @Test
    func htmlBlockIsRenderedInsteadOfDropped() {
        var renderer = TerminalSwiftMarkdownRenderer()
        let document = Document(parsing: """
        <div>
        raw
        </div>
        """)

        let rendered = renderer.visit(document)

        #expect(rendered.contains("<div>"))
        #expect(rendered.contains("raw"))
        #expect(rendered.contains("</div>"))
    }

    @Test
    func visibleWidthCountsEmojiAndWideCharactersAsTerminalColumns() {
        #expect(TerminalANSIText.visibleWidth("🔴 Alta") == 7)
        #expect(TerminalANSIText.visibleWidth("🛠️ Tool") == 7)
        #expect(TerminalANSIText.visibleWidth("表") == 2)
        #expect(TerminalANSIText.visibleWidth("\u{1B}[31m🔴 Alta\u{1B}[0m") == 7)
    }

    @Test
    func tableRowsWithEmojiHaveConsistentVisibleWidths() {
        var renderer = TerminalSwiftMarkdownRenderer()
        let document = Document(parsing: """
        | Priorità | Issue |
        | --- | --- |
        | 🔴 Alta | Paragrafi senza separazione |
        | 🟡 Media | Tabelle non allineate |
        | 🟢 Bassa | Unicode senza fallback |
        """)

        let rendered = renderer.visit(document)
        let lineWidths = rendered
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { TerminalANSIText.visibleWidth(String($0)) }

        #expect(Set(lineWidths).count == 1)
    }

    // MARK: - Item 2: stripANSI handles OSC sequences

    @Test
    func stripANIRemovesCSIEscape() {
        #expect(TerminalANSIText.stripANSI("\u{1B}[1mbold\u{1B}[0m") == "bold")
    }

    @Test
    func stripANSIRemovesOSCHyperlink() {
        let oscOpen = "\u{1B}]8;;https://example.com\u{1B}\\"
        let oscClose = "\u{1B}]8;;\u{1B}\\"
        #expect(TerminalANSIText.stripANSI("\(oscOpen)link\(oscClose)") == "link")
    }

    // MARK: - Item 3: Table truncation with narrow renderWidth

    @Test
    func tableTruncatesWhenRenderWidthIsNarrow() {
        var renderer = TerminalSwiftMarkdownRenderer(renderWidth: 20)
        let document = Document(parsing: """
        | Short | A Very Long Column Header |
        | --- | --- |
        | x | Another very long cell value |
        """)

        let rendered = renderer.visit(document)

        // The rendered table must fit within the renderWidth.
        for line in rendered.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(TerminalANSIText.visibleWidth(String(line)) <= 20)
        }
    }

    // MARK: - Item 4: Explicit initializer

    @Test
    func initSetsPropertiesCorrectly() {
        var renderer = TerminalSwiftMarkdownRenderer(supportsHyperlinks: true, renderWidth: 80)
        let document = Document(parsing: "[text](https://example.com)")

        let rendered = renderer.visit(document)

        // With supportsHyperlinks = true, OSC 8 sequences should be present.
        #expect(rendered.contains("\u{1B}]8;;https://example.com\u{1B}\\"))
    }

    // MARK: - Item 7: PUA marker fallback

    @Test
    func puaMarkerIsStrippedFromOutput() {
        var renderer = TerminalSwiftMarkdownRenderer()
        let document = Document(parsing: """
        - Parent
          - Child
            - Grandchild
        """)

        let rendered = renderer.visit(document)

        #expect(!rendered.contains("\u{E000}"))
    }

    // MARK: - Item 8: Block quote with nested list

    @Test
    func blockQuoteWithNestedListHasAlignedIndentation() {
        var renderer = TerminalSwiftMarkdownRenderer()
        let document = Document(parsing: """
        > - First item
        > - Second item
        """)

        let rendered = renderer.visit(document)
        let lines = rendered.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        #expect(lines.count == 2)
        // Every line should start with the quote bar.
        for line in lines {
            #expect(line.contains("▌"))
        }
    }

    // MARK: - Item 9: URL truncation in fallback

    @Test
    func longURLIsTruncatedInFallback() {
        var renderer = TerminalSwiftMarkdownRenderer(supportsHyperlinks: false)
        let longURL = "https://example.com/" + String(repeating: "a", count: 60)
        let document = Document(parsing: "[label](\(longURL))")

        let rendered = renderer.visit(document)

        #expect(rendered.contains("…"))
        #expect(!rendered.contains(String(repeating: "a", count: 60)))
    }

    @Test
    func shortURLIsNotTruncatedInFallback() {
        var renderer = TerminalSwiftMarkdownRenderer(supportsHyperlinks: false)
        let document = Document(parsing: "[label](https://example.com)")

        let rendered = renderer.visit(document)

        #expect(rendered.contains("<https://example.com>"))
        #expect(!rendered.contains("…"))
    }

}
