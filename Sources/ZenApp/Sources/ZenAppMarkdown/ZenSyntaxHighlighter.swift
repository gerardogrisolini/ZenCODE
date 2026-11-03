//
//  ZenSyntaxHighlighter.swift
//  ZenApp
//
//  A small, dependency-free syntax highlighter for fenced code blocks, with
//  the token classes of the terminal renderer's `TerminalCodeBlockRenderer`.
//

import Foundation
import SwiftUI
import ZenAppTheme

/// The class of a highlighted token; each maps to one `ZenPalette` syntax color.
public enum ZenSyntaxTokenKind: String, CaseIterable, Equatable, Sendable {
    case keyword
    case type
    case string
    case comment
    /// Numbers and literal constants (`true`, `nil`, `null`), as in the terminal UI.
    case number
    case attribute
    case function
    case property
    case plain
}

/// A run of source text with one token class.
public struct ZenSyntaxToken: Equatable, Sendable {
    /// The token class.
    public var kind: ZenSyntaxTokenKind
    /// The source text of the run (may contain newlines).
    public var text: String

    /// Creates a token.
    public init(_ kind: ZenSyntaxTokenKind, _ text: String) {
        self.kind = kind
        self.text = text
    }
}

/// Tokenizes source code and maps the tokens to the `ZenPalette` syntax colors.
///
/// Supported grammars: Swift, Python, JavaScript/TypeScript, JSON/JSONC,
/// YAML/TOML, shell (bash/sh/zsh), Go, Rust, C/C++/Objective-C,
/// Java/Kotlin/C#, Ruby, PHP, SQL, Dockerfile, CSS, HTML/XML, and a generic
/// fallback that colors only strings, numbers and comments. `text` fences are
/// left plain.
public enum ZenSyntaxHighlighter {
    /// Splits `code` into tokens. Concatenating the token texts reproduces
    /// `code` exactly; adjacent tokens of the same class are merged.
    public static func highlight(_ code: String, language: String?) -> [ZenSyntaxToken] {
        var scanner = ZenSyntaxScanner(code)
        switch grammar(for: normalizedLanguage(language)) {
        case let .profile(profile):
            scanner.scanProfile(profile)
        case let .data(lineComments, blockComments, commentsNeedSpace):
            scanner.scanData(
                lineComments: lineComments,
                blockComments: blockComments,
                commentsNeedSpace: commentsNeedSpace
            )
        case .markup:
            scanner.scanMarkup()
        case .css:
            scanner.scanCSS()
        case .plain:
            scanner.emit(.plain, to: scanner.count)
        }
        return scanner.finish()
    }

    /// The palette color of a token class; `.plain` is the code foreground.
    public static func color(for kind: ZenSyntaxTokenKind, palette: ZenPalette) -> Color {
        switch kind {
        case .keyword: palette.syntaxKeyword
        case .type: palette.syntaxType
        case .string: palette.syntaxString
        case .comment: palette.syntaxComment
        case .number: palette.syntaxNumber
        case .attribute: palette.syntaxAttribute
        case .function: palette.syntaxFunction
        case .property: palette.syntaxProperty
        case .plain: palette.codeForeground
        }
    }

    /// The tokens as an `AttributedString` colored with `palette`.
    public static func attributedString(for tokens: [ZenSyntaxToken], palette: ZenPalette) -> AttributedString {
        var result = AttributedString()
        for token in tokens {
            var run = AttributedString(token.text)
            run.swiftUI.foregroundColor = color(for: token.kind, palette: palette)
            result.append(run)
        }
        return result
    }

    /// `highlight(_:language:)` rendered with `palette`.
    public static func attributedString(_ code: String, language: String?, palette: ZenPalette) -> AttributedString {
        attributedString(for: highlight(code, language: language), palette: palette)
    }
}

// MARK: - Scanner

/// A cursor over the characters of a source string that accumulates tokens.
struct ZenSyntaxScanner {
    private let characters: [Character]
    private(set) var index = 0
    private var tokens: [ZenSyntaxToken] = []

    init(_ code: String) {
        characters = Array(code)
    }

    var count: Int { characters.count }

    /// The tokens, consuming any unscanned tail as plain text.
    mutating func finish() -> [ZenSyntaxToken] {
        if index < count {
            emit(.plain, to: count)
        }
        return tokens
    }

    /// Emits `index..<end` as one token of `kind` and moves past it.
    mutating func emit(_ kind: ZenSyntaxTokenKind, to end: Int) {
        let end = min(max(end, index), count)
        guard end > index else {
            return
        }
        let text = String(characters[index..<end])
        if let last = tokens.last, last.kind == kind {
            tokens[tokens.count - 1].text += text
        } else {
            tokens.append(ZenSyntaxToken(kind, text))
        }
        index = end
    }

    // MARK: Profile languages

    mutating func scanProfile(_ profile: ZenSyntaxProfile) {
        while index < count {
            let character = characters[index]
            if character.isWhitespace {
                emit(.plain, to: whitespaceEnd(from: index))
                continue
            }
            if lineComment(at: index, prefixes: profile.lineComments, needsSpace: profile.commentsNeedSpace) {
                emit(.comment, to: lineEnd(from: index))
                continue
            }
            if let end = blockCommentEnd(at: index, comments: profile.blockComments) {
                emit(.comment, to: end)
                continue
            }
            if let end = stringEnd(at: index, profile: profile) {
                emit(.string, to: end)
                continue
            }
            if profile.attributePrefixes.contains(character) {
                emit(.attribute, to: attributeEnd(from: index))
                continue
            }
            if profile.directivePrefixes.contains(character),
               index + 1 < count, characters[index + 1].isLetter {
                emit(.keyword, to: identifierEnd(from: index + 1))
                continue
            }
            if Self.isDigit(character) {
                emit(.number, to: numberEnd(from: index))
                continue
            }
            if Self.isIdentifierStart(character) {
                let end = identifierEnd(from: index)
                let word = String(characters[index..<end])
                let kind: ZenSyntaxTokenKind
                if Self.contains(word, in: profile.keywords) {
                    kind = .keyword
                } else if Self.contains(word, in: profile.types) {
                    kind = .type
                } else if Self.contains(word, in: profile.constants) {
                    kind = .number
                } else if isFollowed(by: "(", after: end) {
                    kind = .function
                } else {
                    kind = .plain
                }
                emit(kind, to: end)
                continue
            }
            emit(.plain, to: index + 1)
        }
    }

    // MARK: Data languages

    mutating func scanData(lineComments: [String], blockComments: Bool, commentsNeedSpace: Bool) {
        let blocks = blockComments ? [ZenSyntaxProfile.cBlockComment] : []
        while index < count {
            let character = characters[index]
            if character.isWhitespace {
                emit(.plain, to: whitespaceEnd(from: index))
                continue
            }
            if lineComment(at: index, prefixes: lineComments, needsSpace: commentsNeedSpace) {
                emit(.comment, to: lineEnd(from: index))
                continue
            }
            if let end = blockCommentEnd(at: index, comments: blocks) {
                emit(.comment, to: end)
                continue
            }
            if (character == "\"" || character == "'"), !followsWordCharacter(index) {
                let end = quotedEnd(from: index, delimiter: character, hashCount: 0, multiline: false)
                emit(isFollowed(byAnyOf: [":", "="], after: end) ? .property : .string, to: end)
                continue
            }
            if Self.isDigit(character)
                || ((character == "-" || character == "+") && index + 1 < count
                    && Self.isDigit(characters[index + 1]) && !followsWordCharacter(index)) {
                emit(.number, to: numberEnd(from: index + (Self.isDigit(character) ? 0 : 1)))
                continue
            }
            if Self.isIdentifierStart(character) {
                let end = keyEnd(from: index)
                let word = String(characters[index..<end]).lowercased()
                if word == "true" || word == "false" || word == "null" {
                    emit(.number, to: end)
                } else if isFollowed(byAnyOf: [":", "="], after: end) {
                    emit(.property, to: end)
                } else {
                    emit(.plain, to: end)
                }
                continue
            }
            emit(.plain, to: index + 1)
        }
    }

    // MARK: Markup

    mutating func scanMarkup() {
        var insideTag = false
        while index < count {
            let character = characters[index]
            if !insideTag {
                if hasPrefix("<!--", at: index) {
                    emit(.comment, to: delimitedEnd(from: index + 4, closing: "-->"))
                    continue
                }
                if character == "<", index + 1 < count {
                    let next = characters[index + 1]
                    if next == "/" {
                        emit(.plain, to: index + 2)
                    } else if next.isLetter || next == "!" || next == "?" {
                        emit(.plain, to: index + 1)
                    } else {
                        emit(.plain, to: index + 1)
                        continue
                    }
                    var end = index
                    while end < count, Self.isMarkupNameCharacter(characters[end]) || (end == index && "!?".contains(characters[end])) {
                        end += 1
                    }
                    emit(.keyword, to: end)
                    insideTag = true
                    continue
                }
                var end = index + 1
                while end < count, characters[end] != "<" {
                    end += 1
                }
                emit(.plain, to: end)
                continue
            }
            if character == ">" {
                emit(.plain, to: index + 1)
                insideTag = false
            } else if (character == "/" || character == "?"), index + 1 < count, characters[index + 1] == ">" {
                emit(.plain, to: index + 2)
                insideTag = false
            } else if character == "\"" || character == "'" {
                emit(.string, to: quotedEnd(from: index, delimiter: character, hashCount: 0, multiline: true))
            } else if Self.isIdentifierStart(character) {
                var end = index
                while end < count, Self.isMarkupNameCharacter(characters[end]) {
                    end += 1
                }
                emit(.attribute, to: end)
            } else {
                emit(.plain, to: index + 1)
            }
        }
    }

    // MARK: CSS

    mutating func scanCSS() {
        while index < count {
            let character = characters[index]
            if character.isWhitespace {
                emit(.plain, to: whitespaceEnd(from: index))
                continue
            }
            if let end = blockCommentEnd(at: index, comments: [ZenSyntaxProfile.cBlockComment]) {
                emit(.comment, to: end)
                continue
            }
            if character == "\"" || character == "'" {
                emit(.string, to: quotedEnd(from: index, delimiter: character, hashCount: 0, multiline: false))
                continue
            }
            if character == "@" {
                emit(.attribute, to: identifierEnd(from: index + 1))
                continue
            }
            if character == "#", let end = hexColorEnd(from: index) {
                emit(.number, to: end)
                continue
            }
            if Self.isDigit(character) {
                emit(.number, to: numberEnd(from: index))
                continue
            }
            let startsCustomProperty = character == "-" && index + 1 < count
                && (characters[index + 1] == "-" || characters[index + 1].isLetter)
            if Self.isIdentifierStart(character) || startsCustomProperty {
                let end = keyEnd(from: index)
                if isFollowed(byAnyOf: [":"], after: end) {
                    emit(.property, to: end)
                } else if isFollowed(by: "(", after: end) {
                    emit(.function, to: end)
                } else {
                    emit(.type, to: end)
                }
                continue
            }
            emit(.plain, to: index + 1)
        }
    }

    // MARK: Lexical helpers

    private func hasPrefix(_ prefix: String, at position: Int) -> Bool {
        var cursor = position
        for character in prefix {
            guard cursor < count, characters[cursor] == character else {
                return false
            }
            cursor += 1
        }
        return true
    }

    private func whitespaceEnd(from start: Int) -> Int {
        var end = start
        while end < count, characters[end].isWhitespace {
            end += 1
        }
        return end
    }

    /// The index of the next newline (exclusive end of the current line).
    private func lineEnd(from start: Int) -> Int {
        var end = start
        while end < count, !characters[end].isNewline {
            end += 1
        }
        return end
    }

    /// The end just past `closing`, or the end of the input.
    private func delimitedEnd(from start: Int, closing: String) -> Int {
        var cursor = start
        let length = closing.count
        while cursor < count {
            if hasPrefix(closing, at: cursor) {
                return cursor + length
            }
            cursor += 1
        }
        return count
    }

    private func lineComment(at position: Int, prefixes: [String], needsSpace: Bool) -> Bool {
        guard prefixes.contains(where: { hasPrefix($0, at: position) }) else {
            return false
        }
        return !needsSpace || position == 0 || characters[position - 1].isWhitespace
    }

    private func blockCommentEnd(at position: Int, comments: [ZenSyntaxBlockComment]) -> Int? {
        guard let comment = comments.first(where: { hasPrefix($0.open, at: position) }) else {
            return nil
        }
        return delimitedEnd(from: position + comment.open.count, closing: comment.close)
    }

    private func followsWordCharacter(_ position: Int) -> Bool {
        guard position > 0 else {
            return false
        }
        let previous = characters[position - 1]
        return previous.isLetter || previous.isNumber
    }

    /// The end of a string starting at `position`, or `nil` when none starts there.
    private func stringEnd(at position: Int, profile: ZenSyntaxProfile) -> Int? {
        var hashCount = 0
        var quote = position
        while profile.allowsSwiftRawStrings, quote < count, characters[quote] == "#" {
            hashCount += 1
            quote += 1
        }
        guard quote < count, profile.stringDelimiters.contains(characters[quote]) else {
            return nil
        }
        if hashCount == 0, profile.quotesNeedBoundary, followsWordCharacter(position) {
            return nil
        }
        let delimiter = characters[quote]
        if profile.tripleQuoteDelimiters.contains(delimiter),
           hasPrefix(String(repeating: String(delimiter), count: 3), at: quote) {
            let closing = String(repeating: String(delimiter), count: 3) + String(repeating: "#", count: hashCount)
            return delimitedEnd(from: quote + 3, closing: closing)
        }
        return quotedEnd(
            from: quote,
            delimiter: delimiter,
            hashCount: hashCount,
            multiline: profile.multilineStringDelimiters.contains(delimiter)
        )
    }

    /// The end of a quoted string whose opening `delimiter` is at `quote`.
    /// Single-line strings left open stop at the end of their line.
    private func quotedEnd(from quote: Int, delimiter: Character, hashCount: Int, multiline: Bool) -> Int {
        var cursor = quote + 1
        while cursor < count {
            let character = characters[cursor]
            if character.isNewline, !multiline {
                return cursor
            }
            if character == "\\", hashCount == 0 {
                cursor += 2
                continue
            }
            if character == delimiter, closingHashesMatch(after: cursor, hashCount: hashCount) {
                return cursor + 1 + hashCount
            }
            cursor += 1
        }
        return count
    }

    private func closingHashesMatch(after quote: Int, hashCount: Int) -> Bool {
        guard hashCount > 0 else {
            return true
        }
        return hasPrefix(String(repeating: "#", count: hashCount), at: quote + 1)
    }

    /// `@name`, `#name`, or a bracketed attribute such as Rust's `#[derive(Debug)]`.
    private func attributeEnd(from start: Int) -> Int {
        var cursor = start + 1
        if cursor < count, characters[cursor] == "!" {
            cursor += 1
        }
        if cursor < count, characters[cursor] == "[" {
            var depth = 0
            while cursor < count, !characters[cursor].isNewline {
                if characters[cursor] == "[" {
                    depth += 1
                } else if characters[cursor] == "]" {
                    depth -= 1
                    if depth == 0 {
                        return cursor + 1
                    }
                }
                cursor += 1
            }
            return cursor
        }
        return identifierEnd(from: start + 1)
    }

    private func identifierEnd(from start: Int) -> Int {
        var end = start
        while end < count, Self.isIdentifierPart(characters[end]) {
            end += 1
        }
        return end
    }

    /// An identifier that may also contain `-` and `.` (YAML/TOML keys, CSS names).
    private func keyEnd(from start: Int) -> Int {
        var end = start
        while end < count {
            let character = characters[end]
            guard Self.isIdentifierPart(character) || character == "-" || character == "." else {
                break
            }
            end += 1
        }
        return end
    }

    /// Digits, letters (hex digits, suffixes, units) and `_`; a `.` only
    /// before a digit, so `1..<5` and `a.0.b` split sensibly.
    private func numberEnd(from start: Int) -> Int {
        var end = start
        while end < count {
            let character = characters[end]
            if Self.isDigit(character) || character.isLetter || character == "_" {
                end += 1
            } else if character == ".", end + 1 < count, Self.isDigit(characters[end + 1]) {
                end += 1
            } else {
                break
            }
        }
        return end
    }

    private func hexColorEnd(from start: Int) -> Int? {
        var end = start + 1
        while end < count, end - start <= 8, characters[end].isHexDigit {
            end += 1
        }
        let digits = end - start - 1
        guard [3, 4, 6, 8].contains(digits) else {
            return nil
        }
        if end < count, Self.isIdentifierPart(characters[end]) {
            return nil
        }
        return end
    }

    /// Whether the next non-blank character on the line after `end` is `character`.
    private func isFollowed(by character: Character, after end: Int) -> Bool {
        isFollowed(byAnyOf: [character], after: end)
    }

    private func isFollowed(byAnyOf candidates: Set<Character>, after end: Int) -> Bool {
        var cursor = end
        while cursor < count, characters[cursor] == " " || characters[cursor] == "\t" {
            cursor += 1
        }
        return cursor < count && candidates.contains(characters[cursor])
    }

    private static func contains(_ word: String, in words: Set<String>) -> Bool {
        words.contains(word) || words.contains(word.lowercased()) || words.contains(word.uppercased())
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func isIdentifierStart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter
    }

    private static func isIdentifierPart(_ character: Character) -> Bool {
        character == "_" || character == "$" || character.isLetter || character.isNumber
    }

    private static func isMarkupNameCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || "-_:.".contains(character)
    }
}
