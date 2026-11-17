//
//  ZenSyntaxHighlighter+Profiles.swift
//  ZenApp
//
//  Language profiles of `ZenSyntaxHighlighter`. The keyword, type and
//  constant sets are the shared `CodeSyntaxVocabulary`, the ones the terminal
//  renderer's `TerminalCodeBlockRenderer.profile(for:)` uses.
//

import Foundation
import ZenCODECore

/// How a family of languages is scanned.
enum ZenSyntaxGrammar: Sendable {
    /// Keyword/type/string/comment scanning driven by a `ZenSyntaxProfile`.
    case profile(ZenSyntaxProfile)
    /// JSON, YAML and TOML: keys are properties, `true`/`false`/`null` numbers.
    case data(lineComments: [String], blockComments: Bool, commentsNeedSpace: Bool)
    /// HTML and XML: tag names are keywords, attributes attributes.
    case markup
    /// CSS: at-rules, properties, functions and hex colors.
    case css
    /// Plain text: a single plain token.
    case plain
}

/// A pair of block-comment delimiters.
struct ZenSyntaxBlockComment: Sendable {
    var open: String
    var close: String
}

/// The lexical description of a C-like or scripting language.
struct ZenSyntaxProfile: Sendable {
    var keywords: Set<String>
    var types: Set<String> = []
    /// Literals such as `true`/`nil`, colored as numbers like the terminal UI.
    var constants: Set<String> = []
    var lineComments: [String] = []
    var blockComments: [ZenSyntaxBlockComment] = []
    /// Characters starting an attribute (`@MainActor`, `#[derive]`).
    var attributePrefixes: Set<Character> = []
    /// Characters starting a directive keyword (`#if`, `#include`).
    var directivePrefixes: Set<Character> = []
    /// Single-line string delimiters.
    var stringDelimiters: Set<Character> = ["\""]
    /// Delimiters whose strings may span lines (JavaScript templates, Go raw strings).
    var multilineStringDelimiters: Set<Character> = []
    /// Delimiters that also open `"""`-style multi-line strings.
    var tripleQuoteDelimiters: Set<Character> = []
    var allowsSwiftRawStrings = false
    /// Line comments start only at the beginning of a line or after
    /// whitespace (`#` in shells, so `$#` and `${#a}` stay code).
    var commentsNeedSpace = false
    /// Quotes preceded by a letter or digit (apostrophes in prose) do not
    /// open strings.
    var quotesNeedBoundary = false

    static let cBlockComment = ZenSyntaxBlockComment(open: "/*", close: "*/")
}

extension ZenSyntaxHighlighter {
    /// Fence names mapped to the canonical language names, as in the terminal UI.
    public static func normalizedLanguage(_ language: String?) -> String? {
        guard let raw = language?.trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else {
            return nil
        }
        switch raw {
        case "bash", "sh", "shell", "zsh", "fish", "console", "shellsession":
            return "shell"
        case "c++", "cc", "cpp", "cxx", "hpp", "h++":
            return "cpp"
        case "h":
            return "c"
        case "c#", "cs", "csharp":
            return "csharp"
        case "dockerfile":
            return "docker"
        case "htm", "xhtml":
            return "html"
        case "plist", "svg", "xsd", "xslt":
            return "xml"
        case "javascript", "js", "jsx", "mjs", "cjs":
            return "javascript"
        case "kt", "kts":
            return "kotlin"
        case "md", "markdown":
            return "markdown"
        case "objective-c", "objc", "objective-c++", "objcpp", "m", "mm":
            return "objc"
        case "py", "python3":
            return "python"
        case "rb":
            return "ruby"
        case "rs":
            return "rust"
        case "golang":
            return "go"
        case "swift", "swiftui":
            return "swift"
        case "ts", "tsx":
            return "typescript"
        case "yml":
            return "yaml"
        case "json5":
            return "jsonc"
        case "txt", "plaintext", "plain", "output", "log":
            return "text"
        default:
            return raw
        }
    }

    /// Whether `language` has a dedicated grammar (rather than the generic
    /// strings-numbers-comments fallback).
    public static func supportsLanguage(_ language: String?) -> Bool {
        guard let language = normalizedLanguage(language) else {
            return false
        }
        return language == "text" || dedicatedGrammar(for: language) != nil
    }

    /// The grammar used for `language` (already normalized).
    static func grammar(for language: String?) -> ZenSyntaxGrammar {
        guard let language else {
            return .profile(genericProfile)
        }
        if language == "text" {
            return .plain
        }
        return dedicatedGrammar(for: language) ?? .profile(genericProfile)
    }

    private static func dedicatedGrammar(for language: String) -> ZenSyntaxGrammar? {
        switch language {
        case "json":
            return .data(lineComments: [], blockComments: false, commentsNeedSpace: false)
        case "jsonc":
            return .data(lineComments: ["//"], blockComments: true, commentsNeedSpace: false)
        case "yaml", "toml":
            return .data(lineComments: ["#"], blockComments: false, commentsNeedSpace: true)
        case "html", "xml":
            return .markup
        case "css", "scss", "less":
            return .css
        default:
            return profile(for: language).map(ZenSyntaxGrammar.profile)
        }
    }

    /// The fallback for unknown languages: strings, numbers and comments only.
    static let genericProfile = ZenSyntaxProfile(
        keywords: [],
        lineComments: ["//", "#"],
        stringDelimiters: ["\"", "'", "`"],
        commentsNeedSpace: true,
        quotesNeedBoundary: true
    )

    private static func profile(for language: String) -> ZenSyntaxProfile? {
        switch language {
        case "swift":
            return ZenSyntaxProfile(
                keywords: CodeSyntaxVocabulary.swift.keywords,
                types: CodeSyntaxVocabulary.swift.types,
                constants: CodeSyntaxVocabulary.swift.constants,
                lineComments: ["//"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                attributePrefixes: ["@"],
                directivePrefixes: ["#"],
                tripleQuoteDelimiters: ["\""],
                allowsSwiftRawStrings: true
            )
        case "javascript", "typescript":
            return ZenSyntaxProfile(
                keywords: CodeSyntaxVocabulary.javaScript.keywords,
                types: CodeSyntaxVocabulary.javaScript.types,
                constants: CodeSyntaxVocabulary.javaScript.constants,
                lineComments: ["//"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                attributePrefixes: ["@"],
                stringDelimiters: ["\"", "'", "`"],
                multilineStringDelimiters: ["`"]
            )
        case "python":
            return ZenSyntaxProfile(
                keywords: CodeSyntaxVocabulary.python.keywords,
                types: CodeSyntaxVocabulary.python.types,
                constants: CodeSyntaxVocabulary.python.constants,
                lineComments: ["#"],
                attributePrefixes: ["@"],
                stringDelimiters: ["\"", "'"],
                tripleQuoteDelimiters: ["\"", "'"]
            )
        case "shell":
            return ZenSyntaxProfile(
                keywords: CodeSyntaxVocabulary.shell.keywords,
                types: CodeSyntaxVocabulary.shell.types,
                constants: CodeSyntaxVocabulary.shell.constants,
                lineComments: ["#"],
                stringDelimiters: ["\"", "'", "`"],
                commentsNeedSpace: true,
                quotesNeedBoundary: true
            )
        case "rust":
            return ZenSyntaxProfile(
                keywords: CodeSyntaxVocabulary.rust.keywords,
                types: CodeSyntaxVocabulary.rust.types,
                constants: CodeSyntaxVocabulary.rust.constants,
                lineComments: ["//"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                attributePrefixes: ["#"]
            )
        case "go":
            return ZenSyntaxProfile(
                keywords: CodeSyntaxVocabulary.go.keywords,
                types: CodeSyntaxVocabulary.go.types,
                constants: CodeSyntaxVocabulary.go.constants,
                lineComments: ["//"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                stringDelimiters: ["\"", "'", "`"],
                multilineStringDelimiters: ["`"]
            )
        case "c", "cpp", "objc":
            return ZenSyntaxProfile(
                keywords: CodeSyntaxVocabulary.c.keywords,
                types: CodeSyntaxVocabulary.c.types,
                constants: CodeSyntaxVocabulary.c.constants,
                lineComments: ["//"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                attributePrefixes: ["@"],
                directivePrefixes: ["#"],
                stringDelimiters: ["\"", "'"]
            )
        case "java", "kotlin", "csharp":
            return ZenSyntaxProfile(
                keywords: CodeSyntaxVocabulary.java.keywords,
                types: CodeSyntaxVocabulary.java.types,
                constants: CodeSyntaxVocabulary.java.constants,
                lineComments: ["//"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                attributePrefixes: ["@"],
                directivePrefixes: ["#"],
                stringDelimiters: ["\"", "'"],
                tripleQuoteDelimiters: ["\""]
            )
        case "php":
            return ZenSyntaxProfile(
                keywords: CodeSyntaxVocabulary.php.keywords,
                types: CodeSyntaxVocabulary.php.types,
                constants: CodeSyntaxVocabulary.php.constants,
                lineComments: ["//", "#"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                attributePrefixes: ["@"],
                stringDelimiters: ["\"", "'"]
            )
        case "ruby":
            return ZenSyntaxProfile(
                keywords: CodeSyntaxVocabulary.ruby.keywords,
                types: CodeSyntaxVocabulary.ruby.types,
                constants: CodeSyntaxVocabulary.ruby.constants,
                lineComments: ["#"],
                attributePrefixes: ["@"],
                stringDelimiters: ["\"", "'", "`"]
            )
        case "sql":
            return ZenSyntaxProfile(
                keywords: CodeSyntaxVocabulary.sql.keywords,
                types: CodeSyntaxVocabulary.sql.types,
                constants: CodeSyntaxVocabulary.sql.constants,
                lineComments: ["--"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                stringDelimiters: ["\"", "'"]
            )
        case "docker":
            return ZenSyntaxProfile(
                keywords: CodeSyntaxVocabulary.docker.keywords,
                types: CodeSyntaxVocabulary.docker.types,
                constants: CodeSyntaxVocabulary.docker.constants,
                lineComments: ["#"],
                stringDelimiters: ["\"", "'"],
                commentsNeedSpace: true
            )
        default:
            return nil
        }
    }
}
