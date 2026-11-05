//
//  ZenSyntaxHighlighter+Profiles.swift
//  ZenApp
//
//  Language profiles of `ZenSyntaxHighlighter`. Keyword, type and constant
//  sets mirror the terminal renderer's `TerminalCodeBlockRenderer.profile(for:)`.
//

import Foundation

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
                keywords: [
                    "actor", "any", "as", "associatedtype", "async", "await", "borrowing",
                    "break", "case", "catch", "class", "consuming", "continue", "default",
                    "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
                    "false", "fileprivate", "for", "func", "guard", "if", "import", "in",
                    "indirect", "init", "inout", "internal", "is", "isolated", "let", "nil",
                    "nonisolated", "open", "operator", "private", "protocol", "public",
                    "repeat", "rethrows", "return", "self", "some", "static", "struct",
                    "subscript", "super", "switch", "throw", "throws", "true", "try",
                    "typealias", "var", "where", "while"
                ],
                types: [
                    "Array", "Bool", "Character", "Data", "Date", "Dictionary", "Double",
                    "Error", "Float", "Int", "Int64", "Never", "Optional", "Result",
                    "Set", "String", "UInt", "URL", "Void"
                ],
                constants: ["false", "nil", "true"],
                lineComments: ["//"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                attributePrefixes: ["@"],
                directivePrefixes: ["#"],
                tripleQuoteDelimiters: ["\""],
                allowsSwiftRawStrings: true
            )
        case "javascript", "typescript":
            return ZenSyntaxProfile(
                keywords: [
                    "as", "async", "await", "break", "case", "catch", "class", "const",
                    "continue", "debugger", "default", "delete", "do", "else", "export",
                    "extends", "finally", "for", "from", "function", "if", "import",
                    "in", "instanceof", "interface", "let", "new", "of", "private",
                    "protected", "public", "return", "static", "super", "switch",
                    "throw", "try", "type", "typeof", "var", "void", "while", "yield"
                ],
                types: [
                    "Array", "Boolean", "Date", "Error", "Map", "Number", "Object",
                    "Promise", "Record", "Set", "String", "boolean", "never", "number",
                    "string", "unknown", "void"
                ],
                constants: ["false", "null", "true", "undefined"],
                lineComments: ["//"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                attributePrefixes: ["@"],
                stringDelimiters: ["\"", "'", "`"],
                multilineStringDelimiters: ["`"]
            )
        case "python":
            return ZenSyntaxProfile(
                keywords: [
                    "False", "None", "True", "and", "as", "assert", "async", "await",
                    "break", "class", "continue", "def", "del", "elif", "else",
                    "except", "finally", "for", "from", "global", "if", "import",
                    "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise",
                    "return", "try", "while", "with", "yield"
                ],
                types: ["bool", "bytes", "dict", "float", "int", "list", "set", "str", "tuple"],
                constants: ["False", "None", "True"],
                lineComments: ["#"],
                attributePrefixes: ["@"],
                stringDelimiters: ["\"", "'"],
                tripleQuoteDelimiters: ["\"", "'"]
            )
        case "shell":
            return ZenSyntaxProfile(
                keywords: [
                    "case", "do", "done", "elif", "else", "esac", "fi", "for",
                    "function", "if", "in", "select", "then", "until", "while"
                ],
                constants: ["false", "true"],
                lineComments: ["#"],
                stringDelimiters: ["\"", "'", "`"],
                commentsNeedSpace: true,
                quotesNeedBoundary: true
            )
        case "rust":
            return ZenSyntaxProfile(
                keywords: [
                    "as", "async", "await", "break", "const", "continue", "crate",
                    "dyn", "else", "enum", "extern", "false", "fn", "for", "if",
                    "impl", "in", "let", "loop", "match", "mod", "move", "mut",
                    "pub", "ref", "return", "self", "static", "struct", "super",
                    "trait", "true", "type", "unsafe", "use", "where", "while"
                ],
                types: [
                    "Box", "Option", "Result", "Self", "String", "Vec", "bool", "char",
                    "f32", "f64", "i32", "i64", "isize", "str", "u32", "u64", "usize"
                ],
                constants: ["false", "None", "Some", "true"],
                lineComments: ["//"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                attributePrefixes: ["#"]
            )
        case "go":
            return ZenSyntaxProfile(
                keywords: [
                    "break", "case", "chan", "const", "continue", "default", "defer",
                    "else", "fallthrough", "for", "func", "go", "goto", "if",
                    "import", "interface", "map", "package", "range", "return",
                    "select", "struct", "switch", "type", "var"
                ],
                types: [
                    "any", "bool", "byte", "complex64", "complex128", "error", "float32",
                    "float64", "int", "int32", "int64", "rune", "string", "uint", "uint64"
                ],
                constants: ["false", "nil", "true"],
                lineComments: ["//"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                stringDelimiters: ["\"", "'", "`"],
                multilineStringDelimiters: ["`"]
            )
        case "c", "cpp", "objc":
            return ZenSyntaxProfile(
                keywords: [
                    "auto", "break", "case", "catch", "class", "const", "constexpr",
                    "continue", "default", "delete", "do", "else", "enum", "extern",
                    "for", "friend", "goto", "if", "inline", "namespace", "new",
                    "operator", "private", "protected", "public", "return", "sizeof",
                    "static", "struct", "switch", "template", "this", "throw", "try",
                    "typedef", "typename", "union", "using", "virtual", "void", "while"
                ],
                types: [
                    "BOOL", "bool", "char", "double", "float", "int", "int32_t",
                    "int64_t", "long", "short", "size_t", "std", "string", "uint32_t",
                    "uint64_t"
                ],
                constants: ["false", "NULL", "nullptr", "true"],
                lineComments: ["//"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                attributePrefixes: ["@"],
                directivePrefixes: ["#"],
                stringDelimiters: ["\"", "'"]
            )
        case "java", "kotlin", "csharp":
            return ZenSyntaxProfile(
                keywords: [
                    "abstract", "as", "break", "case", "catch", "class", "const",
                    "continue", "default", "do", "else", "enum", "extends", "final",
                    "finally", "for", "fun", "if", "implements", "import", "in",
                    "interface", "internal", "is", "new", "object", "override",
                    "package", "private", "protected", "public", "return", "sealed",
                    "static", "switch", "this", "throw", "throws", "try", "val",
                    "var", "void", "when", "while"
                ],
                types: [
                    "Boolean", "Char", "Double", "Exception", "Float", "Int",
                    "Integer", "List", "Long", "Map", "String", "boolean", "char",
                    "double", "float", "int", "long", "string"
                ],
                constants: ["false", "null", "true"],
                lineComments: ["//"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                attributePrefixes: ["@"],
                directivePrefixes: ["#"],
                stringDelimiters: ["\"", "'"],
                tripleQuoteDelimiters: ["\""]
            )
        case "php":
            return ZenSyntaxProfile(
                keywords: [
                    "abstract", "and", "array", "as", "break", "case", "catch",
                    "class", "clone", "const", "continue", "declare", "default",
                    "do", "echo", "else", "elseif", "extends", "final", "finally",
                    "for", "foreach", "function", "global", "if", "implements",
                    "interface", "namespace", "new", "or", "private", "protected",
                    "public", "return", "static", "switch", "throw", "trait", "try",
                    "use", "var", "while", "xor"
                ],
                types: ["bool", "float", "int", "mixed", "string", "void"],
                constants: ["false", "null", "true"],
                lineComments: ["//", "#"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                attributePrefixes: ["@"],
                stringDelimiters: ["\"", "'"]
            )
        case "ruby":
            return ZenSyntaxProfile(
                keywords: [
                    "BEGIN", "END", "alias", "and", "begin", "break", "case", "class",
                    "def", "defined", "do", "else", "elsif", "end", "ensure", "false",
                    "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
                    "rescue", "retry", "return", "self", "super", "then", "true",
                    "undef", "unless", "until", "when", "while", "yield"
                ],
                types: ["Array", "Class", "Hash", "Integer", "Module", "String", "Symbol"],
                constants: ["false", "nil", "true"],
                lineComments: ["#"],
                attributePrefixes: ["@"],
                stringDelimiters: ["\"", "'", "`"]
            )
        case "sql":
            return ZenSyntaxProfile(
                keywords: [
                    "ALTER", "AND", "AS", "ASC", "BETWEEN", "BY", "CASE", "CREATE",
                    "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "FROM",
                    "GROUP", "HAVING", "IN", "INSERT", "INTO", "IS", "JOIN", "LEFT",
                    "LIKE", "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "RIGHT",
                    "SELECT", "SET", "TABLE", "THEN", "UPDATE", "VALUES", "WHEN",
                    "WHERE"
                ],
                types: ["BIGINT", "BOOLEAN", "DATE", "FLOAT", "INT", "INTEGER", "TEXT", "VARCHAR"],
                constants: ["FALSE", "NULL", "TRUE"],
                lineComments: ["--"],
                blockComments: [ZenSyntaxProfile.cBlockComment],
                stringDelimiters: ["\"", "'"]
            )
        case "docker":
            return ZenSyntaxProfile(
                keywords: [
                    "ADD", "ARG", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE",
                    "FROM", "HEALTHCHECK", "LABEL", "MAINTAINER", "ONBUILD", "RUN",
                    "SHELL", "STOPSIGNAL", "USER", "VOLUME", "WORKDIR"
                ],
                lineComments: ["#"],
                stringDelimiters: ["\"", "'"],
                commentsNeedSpace: true
            )
        default:
            return nil
        }
    }
}
