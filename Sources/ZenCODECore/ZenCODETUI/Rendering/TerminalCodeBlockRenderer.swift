//
//  TerminalCodeBlockRenderer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/05/26.
//

import Foundation

enum TerminalCodeBlockRenderer {
    static let reset = "\u{1B}[0m"

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
    /// complete Markdown document.
    static func renderBlock(
        _ code: String,
        language: String?,
        width: Int = 0,
        palette: TerminalMarkdownPalette = .detected
    ) -> String {
        let normalizedCode = code
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let body = normalizedCode
            .split(separator: "\n", omittingEmptySubsequences: false)
            .flatMap {
                renderCodeLine(
                    String($0),
                    language: language,
                    width: width,
                    palette: palette
                )
            }
        return ([renderHeader(language: language, width: width, palette: palette)] + body)
            .joined(separator: "\n")
    }

    /// Renders the human-readable row that replaces a raw Markdown fence.
    static func renderHeader(
        language: String?,
        width: Int,
        palette: TerminalMarkdownPalette
    ) -> String {
        let title: String
        if let language = normalizedLanguage(language), !language.isEmpty {
            title = "Code · \(language.prefix(1).uppercased())\(language.dropFirst())"
        } else {
            title = "Code"
        }
        return renderBackgroundRow(
            "  \(title)",
            width: width,
            style: "\(palette.codeHeaderForeground)\(palette.codeHeaderBackground)"
        )
    }

    /// Renders one logical source line into one or more padded physical rows.
    /// Long tokens are split only at grapheme boundaries by `TerminalANSIText`,
    /// preserving ANSI state and display width. Continuation rows carry a
    /// visible marker rather than silently looking like independent code lines.
    static func renderCodeLine(
        _ line: String,
        language: String?,
        width: Int,
        palette: TerminalMarkdownPalette
    ) -> [String] {
        let highlighted = renderLine(line, language: language, palette: palette)
        guard width > 0 else {
            return [
                renderBackgroundRow(
                    highlighted,
                    width: 0,
                    style: "\(palette.codeForeground)\(palette.codeBackground)"
                )
            ]
        }

        let continuation = width >= 4 ? "↳ " : "›"
        let rows = TerminalANSIText.wrapPreservingWhitespace(
            highlighted,
            width: width,
            hangingIndent: continuation
        )
        return rows.map {
            renderBackgroundRow(
                $0,
                width: width,
                style: "\(palette.codeForeground)\(palette.codeBackground)"
            )
        }
    }

    static func renderLine(
        _ line: String,
        language: String?,
        palette: TerminalMarkdownPalette = .detected,
        dataSyntaxColors: DataSyntaxColors? = nil
    ) -> String {
        let safeLine = terminalSafeSourceLine(line)
        switch normalizedLanguage(language) {
        case "diff", "patch":
            return renderDiffLine(safeLine, palette: palette)
        case "css":
            return renderCSSLine(safeLine, palette: palette)
        case "html", "xml":
            return renderMarkupLine(safeLine, palette: palette)
        case "json", "jsonc", "toml", "yaml":
            return renderDataLine(
                safeLine,
                language: normalizedLanguage(language),
                palette: palette,
                syntaxColors: dataSyntaxColors
            )
        default:
            return renderProfileLine(
                safeLine,
                profile: profile(for: normalizedLanguage(language)),
                palette: palette
            )
        }
    }

    /// Semantic presentation for unified diffs. File metadata is checked
    /// before +/- rows so `+++ b/file` and `--- a/file` do not look like source
    /// additions/removals.
    static func renderDiffLine(
        _ line: String,
        palette: TerminalMarkdownPalette
    ) -> String {
        let style: String
        if line.hasPrefix("+++ ") || line.hasPrefix("--- ")
            || line.hasPrefix("diff ") || line.hasPrefix("index ")
            || line.hasPrefix("new file") || line.hasPrefix("deleted file") {
            style = palette.diffHeader
        } else if line.hasPrefix("@@") {
            style = palette.diffHunk
        } else if line.hasPrefix("+") {
            style = palette.diffAddition
        } else if line.hasPrefix("-") {
            style = palette.diffRemoval
        } else {
            return line
        }
        return "\(style)\(line)\(reset)"
    }

    /// Applies a background to every column of a physical code row. Syntax
    /// highlighting resets are immediately followed by the base code style, so
    /// foreground resets cannot punch holes in the background before EOL.
    private static func renderBackgroundRow(
        _ content: String,
        width: Int,
        style: String
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
        let padding = width > 0
            ? String(repeating: " ", count: max(0, width - TerminalANSIText.visibleWidth(fitted)))
            : ""
        return "\(style)\(restored)\(padding)\(reset)"
    }

    /// Converts caller-controlled source into terminal-safe, width-stable text
    /// before syntax highlighting. Renderer-owned ANSI is added only after this
    /// pass, so an ESC from a fenced payload can never become an executable
    /// terminal sequence or disappear from width accounting.
    private static func terminalSafeSourceLine(_ line: String) -> String {
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
