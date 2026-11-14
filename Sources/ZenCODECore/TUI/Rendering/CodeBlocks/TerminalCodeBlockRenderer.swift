//
//  TerminalCodeBlockRenderer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/05/26.
//

import Foundation

enum TerminalCodeBlockRenderer {
    static let reset = TerminalStyle.reset

    /// Optional data-language overrides used by presentation surfaces that need
    /// a quieter JSON hierarchy than normal source-code highlighting.
    struct DataSyntaxColors: Sendable, Equatable {
        let property: String
        let string: String
        let comment: String
        let number: String
    }

    struct SyntaxProfile {
        var keywords: Set<String>
        var types: Set<String>
        var constants: Set<String>
        var lineComments: [String]
        var attributePrefixes: Set<Character>
        var directivePrefixes: Set<Character>
        var stringDelimiters: Set<Character>
        var allowsSwiftRawStrings: Bool

        static let generic = SyntaxProfile(
            keywords: [
                "and", "as", "async", "await", "break", "case", "catch", "class",
                "const", "continue", "def", "default", "do", "else", "enum",
                "except", "false", "for", "func", "function", "if", "import",
                "in", "let", "nil", "null", "return", "static", "struct",
                "switch", "throw", "true", "try", "var", "while", "yield"
            ],
            types: [],
            constants: ["false", "nil", "none", "null", "true"],
            lineComments: ["//", "#"],
            attributePrefixes: ["@"],
            directivePrefixes: [],
            stringDelimiters: ["\"", "'", "`"],
            allowsSwiftRawStrings: false
        )
    }

    /// Renders a complete fenced-code presentation. The caller supplies the
    /// visible width of the code surface (or zero when no width is known). This
    /// is deliberately shared by the document visitor and the streaming
    /// formatter so a completed stream has the same code-block semantics as a
    /// complete Markdown document. `usesEraseToEndOfLine` extends the row
    /// background with `ESC[K` instead of padding spaces (see
    /// `renderBackgroundRow`).
    static func renderBlock(
        _ code: String,
        language: String?,
        width: Int = 0,
        palette: TerminalMarkdownPalette = .detected,
        usesEraseToEndOfLine: Bool = false
    ) -> String {
        let normalizedCode = code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var diffState = DiffState()
        let body = normalizedCode
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap { line in
                renderCodeLine(
                    String(line),
                    language: language,
                    width: width,
                    palette: palette,
                    diffKind: isDiffLanguage(language)
                        ? diffState.classify(diffSourceLine(String(line), language: language)) : nil,
                    usesEraseToEndOfLine: usesEraseToEndOfLine
                )
            }
        return ([
            renderHeader(
                language: language,
                width: width,
                palette: palette,
                usesEraseToEndOfLine: usesEraseToEndOfLine
            )
        ] + body)
            .joined(separator: "\n")
    }

    /// Renders the human-readable row that replaces a raw Markdown fence.
    static func renderHeader(
        language: String?,
        width: Int,
        palette: TerminalMarkdownPalette,
        usesEraseToEndOfLine: Bool = false
    ) -> String {
        let title: String
        if isDiffLanguage(language) {
            title = "Code · Diff" + (diffSourceLanguage(language).map {
                " · \($0.prefix(1).uppercased())\($0.dropFirst())"
            } ?? "")
        } else if let language = normalizedLanguage(language), !language.isEmpty {
            title = "Code · \(language.prefix(1).uppercased())\(language.dropFirst())"
        } else {
            title = "Code"
        }
        return renderBackgroundRow(
            "  \(title)",
            width: width,
            style: "\(palette.codeHeaderForeground)\(palette.codeHeaderBackground)",
            usesEraseToEndOfLine: usesEraseToEndOfLine
        )
    }

    /// Renders one logical source line into one or more physical rows whose
    /// background reaches the right edge. Long tokens are split only at
    /// grapheme boundaries by `TerminalANSIText`, preserving ANSI state and
    /// display width. Continuation rows restart at the code column with no
    /// marker; artifact diffs keep their line-number gutter on every row.
    static func renderCodeLine(
        _ line: String,
        language: String?,
        width: Int,
        palette: TerminalMarkdownPalette,
        diffKind: DiffLineKind? = nil,
        usesEraseToEndOfLine: Bool = false
    ) -> [String] {
        let artifactRow = artifactDiffRow(line, language: language)
        let sourceLine = artifactRow?.source ?? line
        let highlighted: String
        let background: String
        if isDiffLanguage(language) {
            let kind = diffKind ?? diffLineKind(sourceLine)
            highlighted = renderDiffLine(
                sourceLine,
                sourceLanguage: diffSourceLanguage(language),
                kind: kind,
                palette: palette
            )
            switch kind {
            case .addition: background = palette.diffAdditionBackground
            case .removal: background = palette.diffRemovalBackground
            default: background = palette.codeBackground
            }
        } else {
            highlighted = renderLine(line, language: language, palette: palette)
            background = palette.codeBackground
        }
        let rowStyle = "\(palette.codeForeground)\(background)"
        // Keep the gutter outside syntax highlighting and wrapping. Tiny surfaces
        // that cannot fit a gutter plus a wide grapheme prioritize the source.
        let gutter = artifactRow?.gutter ?? ""
        let gutterWidth = TerminalANSIText.visibleWidth(gutter)
        let showsGutter = !gutter.isEmpty && (width == 0 || width >= gutterWidth + 2)
        let firstPrefix = showsGutter ? gutter : ""
        let continuationPrefix = showsGutter
            ? String(repeating: " ", count: gutterWidth - 3) + " │ " : ""
        func styledPrefix(_ prefix: String) -> String {
            prefix.isEmpty ? "" : "\(palette.syntaxComment)\(prefix)\(reset)"
        }
        guard width > 0 else {
            return [
                renderBackgroundRow(
                    styledPrefix(firstPrefix) + highlighted,
                    width: 0,
                    style: rowStyle,
                    usesEraseToEndOfLine: usesEraseToEndOfLine
                )
            ]
        }

        let sourceWidth = width - (showsGutter ? gutterWidth : 0)
        let rows = TerminalANSIText.wrapPreservingWhitespace(highlighted, width: sourceWidth)
        return rows.enumerated().map { index, row in
            renderBackgroundRow(
                styledPrefix(index == 0 ? firstPrefix : continuationPrefix) + row,
                width: width,
                style: rowStyle,
                usesEraseToEndOfLine: usesEraseToEndOfLine
            )
        }
    }

    static func renderLine(
        _ line: String,
        language: String?,
        palette: TerminalMarkdownPalette = .detected,
        dataSyntaxColors: DataSyntaxColors? = nil
    ) -> String {
        if isDiffLanguage(language) {
            return renderDiffLine(
                line,
                sourceLanguage: diffSourceLanguage(language),
                palette: palette
            )
        }
        let safeLine = terminalSafeSourceLine(line)
        let normalized = normalizedLanguage(language)
        switch normalized {
        case "css":
            return renderCSSLine(safeLine, palette: palette)
        case "html", "xml":
            return renderMarkupLine(safeLine, palette: palette)
        case "json", "jsonc", "toml", "yaml":
            return renderDataLine(
                safeLine,
                language: normalized,
                palette: palette,
                syntaxColors: dataSyntaxColors
            )
        default:
            return renderProfileLine(
                safeLine,
                profile: profile(for: normalized),
                palette: palette
            )
        }
    }

    /// Applies a background to every column of a physical code row. Syntax
    /// highlighting resets are immediately followed by the base code style, so
    /// foreground resets cannot punch holes in the background before EOL.
    ///
    /// With `usesEraseToEndOfLine` the right edge is reached by `ESC[K` emitted
    /// while the row style is active instead of by padding spaces: rows that end
    /// in scrollback are not redrawn on a resize, and the terminal would wrap
    /// padding spaces into background-only rows. Erasing writes no cell, so
    /// there is nothing to wrap. A row that already fills `width` needs no
    /// erase (and `ESC[K` in the delayed-wrap column would erase its last cell).
    private static func renderBackgroundRow(
        _ content: String,
        width: Int,
        style: String,
        usesEraseToEndOfLine: Bool = false
    ) -> String {
        let fitted: String
        if width > 0, TerminalANSIText.visibleWidth(content) > width {
            fitted = TerminalANSIText.truncate(content, to: width)
        } else {
            fitted = content
        }
        let restored = fitted.replacingOccurrences(
            of: reset,
            with: "\(reset)\(style)"
        )
        guard width > 0, usesEraseToEndOfLine else {
            let padding = width > 0
                ? String(repeating: " ", count: max(0, width - TerminalANSIText.visibleWidth(fitted)))
                : ""
            return "\(style)\(restored)\(padding)\(reset)"
        }
        var visibleWidth = TerminalANSIText.visibleWidth(fitted)
        // The chat margin is placed in front of the first visible cell of a
        // line, so an empty row needs one to carry it.
        var spacer = ""
        if visibleWidth == 0 {
            spacer = " "
            visibleWidth = 1
        }
        let erase = visibleWidth < width ? "\u{1B}[K" : ""
        return "\(style)\(restored)\(spacer)\(erase)\(reset)"
    }

    /// Converts caller-controlled source into terminal-safe, width-stable text
    /// before syntax highlighting. Renderer-owned ANSI is added only after this
    /// pass, so an ESC from a fenced payload can never become an executable
    /// terminal sequence or disappear from width accounting.
    static func terminalSafeSourceLine(_ line: String) -> String {
        let tabWidth = 4
        var rendered = ""
        var currentWidth = 0
        for character in line {
            if character == "\t" {
                let spaces = tabWidth - (currentWidth % tabWidth)
                rendered += String(repeating: " ", count: spaces)
                currentWidth += spaces
                continue
            }

            let safeCharacter: Character
            if let controlPicture = controlPicture(for: character) {
                safeCharacter = controlPicture
            } else if character.unicodeScalars.contains(where: {
                $0.properties.isBidiControl || $0.properties.isJoinControl
            }) {
                safeCharacter = "�"
            } else {
                safeCharacter = character
            }
            rendered.append(safeCharacter)
            currentWidth += TerminalANSIText.visibleWidth(of: safeCharacter)
        }
        return rendered
    }

    private static func controlPicture(for character: Character) -> Character? {
        guard character.unicodeScalars.count == 1,
              let scalar = character.unicodeScalars.first,
              CharacterSet.controlCharacters.contains(scalar) else {
            return nil
        }
        if scalar.value < 0x20,
           let picture = Unicode.Scalar(0x2400 + scalar.value) {
            return Character(picture)
        }
        if scalar.value == 0x7F,
           let picture = Unicode.Scalar(0x2421) {
            return Character(picture)
        }
        // C1 controls have no matching Control Pictures glyph.
        return "�"
    }

    static func normalizedLanguage(_ language: String?) -> String? {
        guard let language = language.map(terminalSafeSourceLine)?.lowercased() else {
            return nil
        }
        switch language {
        case "bash", "sh", "shell", "zsh":
            return "shell"
        case "c++", "cc", "cpp", "cxx":
            return "cpp"
        case "c#", "csharp":
            return "csharp"
        case "dockerfile":
            return "docker"
        case "htm", "xhtml":
            return "html"
        case "javascript", "js", "jsx", "mjs":
            return "javascript"
        case "kt", "kts":
            return "kotlin"
        case "md", "markdown":
            return "markdown"
        case "objective-c", "objc":
            return "objc"
        case "py":
            return "python"
        case "rb":
            return "ruby"
        case "rs":
            return "rust"
        case "swift", "swiftui":
            return "swift"
        case "ts", "tsx":
            return "typescript"
        case "yml":
            return "yaml"
        default:
            return language
        }
    }

    static func renderProfileLine(
        _ line: String,
        profile: SyntaxProfile,
        palette: TerminalMarkdownPalette
    ) -> String {
        var rendered = ""
        var index = line.startIndex

        while index < line.endIndex {
            if matchingPrefix(
                in: line,
                at: index,
                prefixes: profile.lineComments
            ) != nil {
                rendered += "\(palette.syntaxComment)\(line[index...])\(reset)"
                break
            }

            if let blockCommentEnd = blockCommentEnd(in: line, at: index) {
                rendered += "\(palette.syntaxComment)\(line[index..<blockCommentEnd])\(reset)"
                index = blockCommentEnd
                continue
            }

            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: profile.stringDelimiters,
                allowsSwiftRawStrings: profile.allowsSwiftRawStrings
            ) {
                rendered += "\(palette.syntaxString)\(line[index..<stringEnd])\(reset)"
                index = stringEnd
                continue
            }

            if profile.attributePrefixes.contains(line[index]) {
                let end = consumeIdentifier(in: line, from: line.index(after: index))
                rendered += "\(palette.syntaxAttribute)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if profile.directivePrefixes.contains(line[index]),
               line.index(after: index) < line.endIndex,
               line[line.index(after: index)].isLetter {
                let end = consumeIdentifier(in: line, from: line.index(after: index))
                rendered += "\(palette.syntaxKeyword)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if line[index].isNumber {
                let end = consumeNumber(in: line, from: index)
                rendered += "\(palette.syntaxNumber)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if isIdentifierStart(line[index]) {
                let end = consumeIdentifier(in: line, from: index)
                let token = String(line[index..<end])
                if containsToken(token, in: profile.keywords) {
                    rendered += "\(palette.syntaxKeyword)\(token)\(reset)"
                } else if containsToken(token, in: profile.types) {
                    rendered += "\(palette.syntaxType)\(token)\(reset)"
                } else if containsToken(token, in: profile.constants) {
                    rendered += "\(palette.syntaxNumber)\(token)\(reset)"
                } else if isFunctionCall(in: line, after: end) {
                    rendered += "\(palette.syntaxFunction)\(token)\(reset)"
                } else {
                    rendered += token
                }
                index = end
                continue
            }

            rendered.append(line[index])
            index = line.index(after: index)
        }

        return rendered
    }

    static func renderDataLine(
        _ line: String,
        language: String?,
        palette: TerminalMarkdownPalette,
        syntaxColors: DataSyntaxColors? = nil
    ) -> String {
        let propertyColor = syntaxColors?.property ?? palette.syntaxProperty
        let stringColor = syntaxColors?.string ?? palette.syntaxString
        let commentColor = syntaxColors?.comment ?? palette.syntaxComment
        let numberColor = syntaxColors?.number ?? palette.syntaxNumber
        let comments: [String] = {
            switch language {
            case "json":
                return []
            case "jsonc":
                return ["//"]
            default:
                return ["#"]
            }
        }()

        var rendered = ""
        var index = line.startIndex

        while index < line.endIndex {
            if matchingPrefix(in: line, at: index, prefixes: comments) != nil {
                rendered += "\(commentColor)\(line[index...])\(reset)"
                break
            }

            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            ) {
                let token = String(line[index..<stringEnd])
                if isObjectKey(in: line, after: stringEnd) {
                    rendered += "\(propertyColor)\(token)\(reset)"
                } else {
                    rendered += "\(stringColor)\(token)\(reset)"
                }
                index = stringEnd
                continue
            }

            if line[index].isNumber || line[index] == "-" {
                let end = consumeNumber(in: line, from: index)
                if end > index {
                    rendered += "\(numberColor)\(line[index..<end])\(reset)"
                    index = end
                    continue
                }
            }

            if isIdentifierStart(line[index]) {
                let end = consumeIdentifier(in: line, from: index)
                let token = String(line[index..<end])
                if ["false", "null", "true"].contains(token.lowercased()) {
                    rendered += "\(numberColor)\(token)\(reset)"
                } else if isObjectKey(in: line, after: end) {
                    rendered += "\(propertyColor)\(token)\(reset)"
                } else {
                    rendered += token
                }
                index = end
                continue
            }

            rendered.append(line[index])
            index = line.index(after: index)
        }

        return rendered
    }

    static func renderMarkupLine(
        _ line: String,
        palette: TerminalMarkdownPalette
    ) -> String {
        var rendered = ""
        var index = line.startIndex

        while index < line.endIndex {
            if hasPrefix("<!--", in: line, at: index) {
                let end = endOfDelimitedSegment(
                    in: line,
                    from: index,
                    closing: "-->"
                )
                rendered += "\(palette.syntaxComment)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if line[index] == "<" {
                rendered.append("<")
                index = line.index(after: index)

                if index < line.endIndex, line[index] == "/" {
                    rendered.append("/")
                    index = line.index(after: index)
                }

                let tagEnd = consumeIdentifier(in: line, from: index)
                if tagEnd > index {
                    rendered += "\(palette.syntaxKeyword)\(line[index..<tagEnd])\(reset)"
                    index = tagEnd
                    continue
                }
            }

            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            ) {
                rendered += "\(palette.syntaxString)\(line[index..<stringEnd])\(reset)"
                index = stringEnd
                continue
            }

            if isIdentifierStart(line[index]), isMarkupAttribute(in: line, after: index) {
                let end = consumeIdentifier(in: line, from: index)
                rendered += "\(palette.syntaxAttribute)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            rendered.append(line[index])
            index = line.index(after: index)
        }

        return rendered
    }

    static func renderCSSLine(
        _ line: String,
        palette: TerminalMarkdownPalette
    ) -> String {
        var rendered = ""
        var index = line.startIndex

        while index < line.endIndex {
            if let blockCommentEnd = blockCommentEnd(in: line, at: index) {
                rendered += "\(palette.syntaxComment)\(line[index..<blockCommentEnd])\(reset)"
                index = blockCommentEnd
                continue
            }

            if let stringEnd = stringEnd(
                in: line,
                at: index,
                delimiters: ["\"", "'"],
                allowsSwiftRawStrings: false
            ) {
                rendered += "\(palette.syntaxString)\(line[index..<stringEnd])\(reset)"
                index = stringEnd
                continue
            }

            if line[index] == "@" {
                let end = consumeIdentifier(in: line, from: line.index(after: index))
                rendered += "\(palette.syntaxAttribute)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if line[index] == "#",
               let end = cssColorEnd(in: line, from: index) {
                rendered += "\(palette.syntaxNumber)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if line[index].isNumber {
                let end = consumeNumber(in: line, from: index)
                rendered += "\(palette.syntaxNumber)\(line[index..<end])\(reset)"
                index = end
                continue
            }

            if isIdentifierStart(line[index]) {
                let end = consumeCSSIdentifier(in: line, from: index)
                if isObjectKey(in: line, after: end) {
                    rendered += "\(palette.syntaxProperty)\(line[index..<end])\(reset)"
                } else if isFunctionCall(in: line, after: end) {
                    rendered += "\(palette.syntaxFunction)\(line[index..<end])\(reset)"
                } else {
                    rendered += "\(palette.syntaxType)\(line[index..<end])\(reset)"
                }
                index = end
                continue
            }

            rendered.append(line[index])
            index = line.index(after: index)
        }

        return rendered
    }

}
