import Foundation
import SwiftUI
import Testing
import ZenAppTheme

@testable import ZenAppMarkdown

// MARK: - Helpers

private func plain(_ inline: ZenMarkdownInline) -> String {
    String(inline.characters)
}

/// The attributes of the run whose text is exactly `text`.
private func run(
    _ text: String,
    in inline: ZenMarkdownInline
) -> AttributedString.Runs.Run? {
    inline.runs.first { String(inline[$0.range].characters) == text }
}

private func paragraph(_ markdown: String) -> ZenMarkdownInline? {
    guard case let .paragraph(content)? = ZenMarkdownParser.blocks(from: markdown).first else {
        return nil
    }
    return content
}

private func kind(of text: String, in tokens: [ZenSyntaxToken]) -> ZenSyntaxTokenKind? {
    tokens.first { $0.text == text }?.kind
}

// MARK: - Parser

@Suite("ZenMarkdownParser")
struct ZenMarkdownParserTests {
    @Test("headings keep their level and inline text")
    func headings() {
        let blocks = ZenMarkdownParser.blocks(from: "# Title\n\n## Sub *title*\n\n###### Six")
        #expect(blocks.count == 3)
        guard case let .heading(level1, title) = blocks[0],
              case let .heading(level2, sub) = blocks[1],
              case let .heading(level6, six) = blocks[2] else {
            Issue.record("expected three headings, got \(blocks)")
            return
        }
        #expect(level1 == 1 && plain(title) == "Title")
        #expect(level2 == 2 && plain(sub) == "Sub title")
        #expect(run("title", in: sub)?.inlinePresentationIntent == .emphasized)
        #expect(level6 == 6 && plain(six) == "Six")
    }

    @Test("emphasis, strong, strikethrough and inline code carry presentation intents")
    func inlineIntents() throws {
        let content = try #require(paragraph("**bold** *it* ~~del~~ `code` ***both***"))
        #expect(plain(content) == "bold it del code both")
        #expect(run("bold", in: content)?.inlinePresentationIntent == .stronglyEmphasized)
        #expect(run("it", in: content)?.inlinePresentationIntent == .emphasized)
        #expect(run("del", in: content)?.inlinePresentationIntent == .strikethrough)
        #expect(run("code", in: content)?.inlinePresentationIntent == .code)
        #expect(run("both", in: content)?.inlinePresentationIntent == [.emphasized, .stronglyEmphasized])
        #expect(run(" ", in: content)?.inlinePresentationIntent == nil)
    }

    @Test("links, autolinks and images carry their destination")
    func links() throws {
        let content = try #require(paragraph(
            "See [the docs](https://example.com/docs), <https://zen.dev> and ![logo](https://example.com/logo.png)."
        ))
        #expect(plain(content) == "See the docs, https://zen.dev and logo.")
        #expect(run("the docs", in: content)?.link == URL(string: "https://example.com/docs"))
        #expect(run("https://zen.dev", in: content)?.link == URL(string: "https://zen.dev"))
        #expect(run("logo", in: content)?.link == URL(string: "https://example.com/logo.png"))
        #expect(run("See ", in: content)?.link == nil)
    }

    @Test("soft breaks become spaces and hard breaks newlines")
    func breaks() throws {
        let soft = try #require(paragraph("one\ntwo"))
        #expect(plain(soft) == "one two")
        let hard = try #require(paragraph("one  \ntwo\\\nthree"))
        #expect(plain(hard) == "one\ntwo\nthree")
    }

    @Test("nested lists and task items")
    func nestedListsAndTasks() {
        let markdown = """
        - first
          - nested
            1. deep
        - [x] done
        - [ ] todo
        """
        let blocks = ZenMarkdownParser.blocks(from: markdown)
        guard case let .list(ordered, start, items)? = blocks.first, blocks.count == 1 else {
            Issue.record("expected one list, got \(blocks)")
            return
        }
        #expect(!ordered)
        #expect(start == 1)
        #expect(items.count == 3)
        #expect(items[0].checkbox == nil)
        #expect(items[1].checkbox == .checked)
        #expect(items[2].checkbox == .unchecked)
        guard items[0].blocks.count == 2,
              case let .paragraph(first) = items[0].blocks[0],
              case let .list(false, _, nested) = items[0].blocks[1],
              case let .list(true, deepStart, deep)? = nested.first?.blocks.last else {
            Issue.record("unexpected nesting: \(items[0].blocks)")
            return
        }
        #expect(plain(first) == "first")
        #expect(nested.count == 1)
        #expect(deepStart == 1 && deep.count == 1)
        guard case let .paragraph(done)? = items[1].blocks.first else {
            Issue.record("task item without paragraph")
            return
        }
        #expect(plain(done) == "done")
    }

    @Test("ordered lists keep their start number")
    func orderedStart() {
        let blocks = ZenMarkdownParser.blocks(from: "3. three\n4. four")
        guard case let .list(true, start, items)? = blocks.first else {
            Issue.record("expected an ordered list, got \(blocks)")
            return
        }
        #expect(start == 3)
        #expect(items.count == 2)
    }

    @Test("block quotes hold nested blocks")
    func quotes() {
        let blocks = ZenMarkdownParser.blocks(from: "> quoted **text**\n>\n> - item\n>\n> > inner")
        guard case let .quote(inner)? = blocks.first, blocks.count == 1 else {
            Issue.record("expected one quote, got \(blocks)")
            return
        }
        #expect(inner.count == 3)
        guard case let .paragraph(text) = inner[0],
              case .list = inner[1],
              case let .quote(nested) = inner[2] else {
            Issue.record("unexpected quote content: \(inner)")
            return
        }
        #expect(plain(text) == "quoted text")
        #expect(nested.count == 1)
    }

    @Test("tables keep header, alignments and rows")
    func tables() {
        let markdown = """
        | Name | Count | Price |
        |:-----|:-----:|------:|
        | **a** | 1 | `2` |
        | b | 3 | 4 |
        """
        guard case let .table(header, alignments, rows)? = ZenMarkdownParser.blocks(from: markdown).first else {
            Issue.record("expected a table")
            return
        }
        #expect(header.map(plain) == ["Name", "Count", "Price"])
        #expect(alignments == [.left, .center, .right])
        #expect(rows.count == 2)
        #expect(rows.map { $0.map(plain) } == [["a", "1", "2"], ["b", "3", "4"]])
        #expect(run("a", in: rows[0][0])?.inlinePresentationIntent == .stronglyEmphasized)
        #expect(run("2", in: rows[0][2])?.inlinePresentationIntent == .code)

        guard case let .table(_, unaligned, _)? = ZenMarkdownParser.blocks(from: "| a | b |\n|---|---|\n| 1 | 2 |").first else {
            Issue.record("expected a table")
            return
        }
        #expect(unaligned == [.none, .none])
    }

    @Test("fenced code keeps its language and drops the trailing newline")
    func fencedCode() {
        let blocks = ZenMarkdownParser.blocks(from: "```swift\nlet x = 1\nprint(x)\n```\n\n```\nplain\n```")
        #expect(blocks == [
            .code(language: "swift", code: "let x = 1\nprint(x)"),
            .code(language: nil, code: "plain")
        ])
    }

    @Test("an unterminated fence still renders as code")
    func unterminatedFence() {
        let blocks = ZenMarkdownParser.blocks(from: "Intro\n\n```python\nprint(1)\nif x:")
        #expect(blocks.count == 2)
        #expect(blocks.last == .code(language: "python", code: "print(1)\nif x:"))
        #expect(ZenMarkdownParser.blocks(from: "```js\n").last == .code(language: "js", code: ""))
    }

    @Test("every prefix of a document parses without crashing")
    func streamingPrefixes() {
        let document = """
        # Title
        Some **bold *nested* text** with `code` and a [link](https://example.com).
        - [x] task
          1. nested
        > quote
        | a | b |
        |:-:|--:|
        | 1 | 2 |
        ```diff
        @@ -1 +1 @@
        -old
        +new
        ```
        ---
        <div>html</div>
        """
        var prefix = ""
        for character in document {
            prefix.append(character)
            let blocks = ZenMarkdownParser.blocks(from: prefix)
            #expect(!blocks.isEmpty)
            #expect(ZenMarkdownParser.cachedBlocks(from: prefix, isStreaming: true) == blocks)
        }
    }

    @Test("thematic breaks separate paragraphs")
    func thematicBreak() {
        let blocks = ZenMarkdownParser.blocks(from: "above\n\n---\n\nbelow\n\n***")
        #expect(blocks.count == 4)
        #expect(blocks[1] == .thematicBreak)
        #expect(blocks[3] == .thematicBreak)
    }

    @Test("HTML blocks are kept verbatim and comments dropped")
    func htmlBlocks() {
        let blocks = ZenMarkdownParser.blocks(from: "<div class=\"x\">\nhi\n</div>\n\n<!-- hidden -->\n\ntext")
        #expect(blocks.count == 2)
        #expect(blocks.first == .html("<div class=\"x\">\nhi\n</div>"))
    }

    @Test("the cache returns the same blocks as a fresh parse")
    func cache() {
        let markdown = "# Cached\n\n- a\n- b"
        let fresh = ZenMarkdownParser.blocks(from: markdown)
        #expect(ZenMarkdownParser.cachedBlocks(from: markdown, isStreaming: false) == fresh)
        #expect(ZenMarkdownParser.cachedBlocks(from: markdown, isStreaming: false) == fresh)

        let cache = ZenMarkdownCache<Int, Int>(capacity: 2)
        cache.insert(1, for: 1)
        cache.insert(2, for: 2)
        _ = cache.value(for: 1)
        cache.insert(3, for: 3)
        #expect(cache.count == 2)
        #expect(cache.value(for: 1) == 1)
        #expect(cache.value(for: 2) == nil)
        #expect(cache.value(for: 3) == 3)
    }
}

// MARK: - Inline style

@Suite("ZenMarkdownInlineStyle")
struct ZenMarkdownInlineStyleTests {
    @Test("inline code and links get the palette colors")
    func colors() throws {
        let content = try #require(paragraph("a `code` and [link](https://example.com) ~~x~~"))
        for palette in [ZenPalette.dark, ZenPalette.light] {
            let styled = ZenMarkdownInlineStyle.styled(content, font: .body, palette: palette)
            #expect(String(styled.characters) == plain(content))
            let code = try #require(run("code", in: styled))
            #expect(code.swiftUI.foregroundColor == palette.inlineCodeForeground)
            #expect(code.swiftUI.backgroundColor == palette.inlineCodeBackground)
            let link = try #require(run("link", in: styled))
            #expect(link.swiftUI.foregroundColor == palette.markdownLink)
            #expect(link.link == URL(string: "https://example.com"))
            #expect(run("x", in: styled)?.swiftUI.strikethroughStyle == .single)
            #expect(run("a ", in: styled)?.swiftUI.foregroundColor == nil)
        }
    }
}

// MARK: - Syntax highlighting

@Suite("ZenSyntaxHighlighter")
struct ZenSyntaxHighlighterTests {
    @Test("Swift token kinds")
    func swiftTokens() {
        let code = """
        @MainActor
        func greet(name: String) -> Int {
            /* block */ let count = 42 // answer
            #if DEBUG
            return name.isEmpty ? 0 : greet(name: "zen \\(name)")
            #endif
        }
        """
        let tokens = ZenSyntaxHighlighter.highlight(code, language: "swift")
        #expect(tokens.map(\.text).joined() == code)
        #expect(kind(of: "@MainActor", in: tokens) == .attribute)
        #expect(kind(of: "func", in: tokens) == .keyword)
        #expect(kind(of: "greet", in: tokens) == .function)
        #expect(kind(of: "String", in: tokens) == .type)
        #expect(kind(of: "Int", in: tokens) == .type)
        #expect(kind(of: "/* block */", in: tokens) == .comment)
        #expect(kind(of: "let", in: tokens) == .keyword)
        #expect(kind(of: "42", in: tokens) == .number)
        #expect(kind(of: "// answer", in: tokens) == .comment)
        #expect(kind(of: "#if", in: tokens) == .keyword)
        #expect(kind(of: "\"zen \\(name)\"", in: tokens) == .string)
        #expect(kind(of: "0", in: tokens) == .number)
    }

    @Test("JSON token kinds")
    func jsonTokens() {
        let code = "{\n  \"name\": \"zen\",\n  \"count\": -3.5,\n  \"ok\": true,\n  \"none\": null\n}"
        let tokens = ZenSyntaxHighlighter.highlight(code, language: "json")
        #expect(tokens.map(\.text).joined() == code)
        #expect(kind(of: "\"name\"", in: tokens) == .property)
        #expect(kind(of: "\"zen\"", in: tokens) == .string)
        #expect(kind(of: "\"count\"", in: tokens) == .property)
        #expect(kind(of: "-3.5", in: tokens) == .number)
        #expect(kind(of: "true", in: tokens) == .number)
        #expect(kind(of: "null", in: tokens) == .number)
    }

    @Test("other grammars classify their main constructs")
    func otherLanguages() {
        let python = ZenSyntaxHighlighter.highlight("def f(x):\n    \"\"\"doc\nmore\"\"\"\n    return None # done", language: "py")
        #expect(kind(of: "def", in: python) == .keyword)
        #expect(kind(of: "\"\"\"doc\nmore\"\"\"", in: python) == .string)
        #expect(kind(of: "None", in: python) == .keyword)
        #expect(kind(of: "# done", in: python) == .comment)

        let shell = ZenSyntaxHighlighter.highlight("if [ $# -gt 0 ]; then echo \"hi\"; fi # end", language: "zsh")
        #expect(kind(of: "if", in: shell) == .keyword)
        #expect(kind(of: "\"hi\"", in: shell) == .string)
        #expect(kind(of: "# end", in: shell) == .comment)
        #expect(!shell.contains { $0.kind == .comment && $0.text.hasPrefix("# -gt") })

        let html = ZenSyntaxHighlighter.highlight("<a href=\"x\">don't</a><!-- c -->", language: "html")
        #expect(kind(of: "a", in: html) == .keyword)
        #expect(kind(of: "href", in: html) == .attribute)
        #expect(kind(of: "\"x\"", in: html) == .string)
        #expect(kind(of: "<!-- c -->", in: html) == .comment)
        #expect(!html.contains { $0.kind == .string && $0.text.hasPrefix("'") })

        let yaml = ZenSyntaxHighlighter.highlight("name: zen # c\nlist:\n  - 3", language: "yml")
        #expect(kind(of: "name", in: yaml) == .property)
        #expect(kind(of: "# c", in: yaml) == .comment)
        #expect(kind(of: "3", in: yaml) == .number)

        let rust = ZenSyntaxHighlighter.highlight("#[derive(Debug)]\nfn main() { let v: Vec<i32> = vec![1]; }", language: "rs")
        #expect(kind(of: "#[derive(Debug)]", in: rust) == .attribute)
        #expect(kind(of: "fn", in: rust) == .keyword)
        #expect(kind(of: "Vec", in: rust) == .type)

        let javascript = ZenSyntaxHighlighter.highlight("const s = `a\nb`; await f(1)", language: "ts")
        #expect(kind(of: "const", in: javascript) == .keyword)
        #expect(kind(of: "`a\nb`", in: javascript) == .string)
        #expect(kind(of: "f", in: javascript) == .function)
    }

    @Test("the generic fallback colors only strings, numbers and comments")
    func genericFallback() {
        let code = "for x in 'abc' 12 // note\nit's fine"
        let tokens = ZenSyntaxHighlighter.highlight(code, language: "unknown-lang")
        #expect(tokens.map(\.text).joined() == code)
        #expect(kind(of: "'abc'", in: tokens) == .string)
        #expect(kind(of: "12", in: tokens) == .number)
        #expect(kind(of: "// note", in: tokens) == .comment)
        #expect(!tokens.contains { $0.kind == .keyword })
        #expect(!tokens.contains { $0.kind == .string && $0.text.hasPrefix("'s") })
        #expect(ZenSyntaxHighlighter.highlight("a 1 \"b\"", language: "text") == [ZenSyntaxToken(.plain, "a 1 \"b\"")])
    }

    @Test("language aliases normalize as in the terminal UI")
    func aliases() {
        #expect(ZenSyntaxHighlighter.normalizedLanguage("bash") == "shell")
        #expect(ZenSyntaxHighlighter.normalizedLanguage("SH") == "shell")
        #expect(ZenSyntaxHighlighter.normalizedLanguage("c++") == "cpp")
        #expect(ZenSyntaxHighlighter.normalizedLanguage("kt") == "kotlin")
        #expect(ZenSyntaxHighlighter.normalizedLanguage("") == nil)
        #expect(ZenSyntaxHighlighter.supportsLanguage("swift"))
        #expect(!ZenSyntaxHighlighter.supportsLanguage("brainfuck"))
        #expect(!ZenSyntaxHighlighter.supportsLanguage(nil))
    }

    @Test("tokens map to the palette syntax colors")
    func colors() {
        let palette = ZenPalette.light
        let tokens = ZenSyntaxHighlighter.highlight("let x = 1", language: "swift")
        let attributed = ZenSyntaxHighlighter.attributedString(for: tokens, palette: palette)
        #expect(String(attributed.characters) == "let x = 1")
        #expect(run("let", in: attributed)?.swiftUI.foregroundColor == palette.syntaxKeyword)
        #expect(run("1", in: attributed)?.swiftUI.foregroundColor == palette.syntaxNumber)
        #expect(run(" x = ", in: attributed)?.swiftUI.foregroundColor == palette.codeForeground)
    }
}

// MARK: - Diff

@Suite("ZenDiff")
struct ZenDiffTests {
    @Test("unified diff lines are classified")
    func classification() {
        let diff = """
        diff --git a/f.swift b/f.swift
        index 1111111..2222222 100644
        --- a/f.swift
        +++ b/f.swift
        @@ -1,3 +1,3 @@
         context
        -old
        +new
        +++ still an addition
        \\ No newline at end of file
        trailing
        """
        let kinds = ZenDiff.classify(diff).map(\.kind)
        #expect(kinds == [
            .header, .header, .header, .header, .hunk,
            .context, .removal, .addition, .addition, .plain, .plain
        ])
        #expect(ZenDiff.classify(diff).map(\.text).joined(separator: "\n") == diff)
    }

    @Test("diff detection by language and by content")
    func detection() {
        #expect(ZenDiff.isDiffLanguage("diff"))
        #expect(ZenDiff.isDiffLanguage("Patch"))
        #expect(ZenDiff.isDiffLanguage("diff-swift"))
        #expect(!ZenDiff.isDiffLanguage("swift"))
        #expect(!ZenDiff.isDiffLanguage(nil))

        #expect(ZenDiff.looksLikeUnifiedDiff("@@ -1,2 +1,2 @@\n-a\n+b"))
        #expect(ZenDiff.looksLikeUnifiedDiff("diff --git a/x b/x"))
        #expect(ZenDiff.looksLikeUnifiedDiff("--- a/x\n+++ b/x"))
        #expect(!ZenDiff.looksLikeUnifiedDiff("- item\n+ other\n@@ not a hunk"))

        let untagged = "@@ -1 +1 @@\n-a\n+b"
        #expect(ZenMarkdownCodePresentation.make(language: nil, code: untagged).isDiff)
        #expect(ZenMarkdownCodePresentation.make(language: "patch", code: "-a\n+b").isDiff)
        #expect(!ZenMarkdownCodePresentation.make(language: "swift", code: untagged).isDiff)
        #expect(ZenMarkdownCodePresentation.title(language: "diff", isDiff: true) == "Code · Diff")
        #expect(ZenMarkdownCodePresentation.title(language: "bash", isDiff: false) == "Code · Shell")
        #expect(ZenMarkdownCodePresentation.title(language: nil, isDiff: false) == "Code")
    }
}

// MARK: - View

@Suite("ZenMarkdownView")
@MainActor
struct ZenMarkdownViewTests {
    @Test("views build for every block kind in both palettes")
    func viewsBuild() {
        let markdown = """
        # H1
        Text with `code`.
        - [x] task
        > quote
        | a | b |
        |---|--:|
        | 1 | 2 |
        ```diff
        +a
        ```
        ---
        """
        let view = ZenMarkdownView(markdown, isStreaming: true)
        for scheme in [ColorScheme.light, .dark] {
            let renderer = ImageRenderer(content: view.frame(width: 480).environment(\.colorScheme, scheme))
            #expect(renderer.cgImage != nil)
        }
        #expect(ZenMarkdownBlockView.headingFont(level: 1) == .title.bold())
        #expect(ZenMarkdownTableView.horizontalAlignment(.right) == .trailing)
        #expect(ZenMarkdownTableView.textAlignment(.center) == .center)
    }
}
