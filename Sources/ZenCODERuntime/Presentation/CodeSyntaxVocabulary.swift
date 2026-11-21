//
//  CodeSyntaxVocabulary.swift
//  ZenCODE
//
//  The words the code-block highlighters color for each language family,
//  shared by the terminal renderer and the macOS app so the two color code
//  alike. How each one scans comments, strings, and attributes stays with it.
//

/// The keywords, type names, and literal constants of a language family.
public struct CodeSyntaxVocabulary: Sendable, Equatable {
    public let keywords: Set<String>
    public let types: Set<String>
    public let constants: Set<String>

    public init(keywords: Set<String>, types: Set<String>, constants: Set<String>) {
        self.keywords = keywords
        self.types = types
        self.constants = constants
    }

    /// Swift.
    public static let swift = CodeSyntaxVocabulary(
        keywords: [
            "actor", "any", "as", "associatedtype", "async", "await", "borrowing",
            "break", "case", "catch", "class", "consuming", "continue", "default",
            "defer", "deinit", "do", "else", "enum", "extension", "fallthrough",
            "false", "fileprivate", "for", "func", "guard", "if", "import", "in",
            "indirect", "init", "inout", "internal", "is", "isolated", "let",
            "nil", "nonisolated", "open", "operator", "private", "protocol",
            "public", "repeat", "rethrows", "return", "self", "some", "static",
            "struct", "subscript", "super", "switch", "throw", "throws", "true",
            "try", "typealias", "var", "where", "while"
        ],
        types: [
            "Array", "Bool", "Character", "Data", "Date", "Dictionary", "Double",
            "Error", "Float", "Int", "Int64", "Never", "Optional", "Result", "Set",
            "String", "UInt", "URL", "Void"
        ],
        constants: [
            "false", "nil", "true"
        ]
    )

    /// JavaScript and TypeScript.
    public static let javaScript = CodeSyntaxVocabulary(
        keywords: [
            "as", "async", "await", "break", "case", "catch", "class", "const",
            "continue", "debugger", "default", "delete", "do", "else", "export",
            "extends", "finally", "for", "from", "function", "if", "import", "in",
            "instanceof", "interface", "let", "new", "of", "private", "protected",
            "public", "return", "static", "super", "switch", "throw", "try",
            "type", "typeof", "var", "void", "while", "yield"
        ],
        types: [
            "Array", "Boolean", "Date", "Error", "Map", "Number", "Object",
            "Promise", "Record", "Set", "String", "boolean", "never", "number",
            "string", "unknown", "void"
        ],
        constants: [
            "false", "null", "true", "undefined"
        ]
    )

    /// Python.
    public static let python = CodeSyntaxVocabulary(
        keywords: [
            "False", "None", "True", "and", "as", "assert", "async", "await",
            "break", "class", "continue", "def", "del", "elif", "else", "except",
            "finally", "for", "from", "global", "if", "import", "in", "is",
            "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
            "while", "with", "yield"
        ],
        types: [
            "bool", "bytes", "dict", "float", "int", "list", "set", "str", "tuple"
        ],
        constants: [
            "False", "None", "True"
        ]
    )

    /// Shell scripts.
    public static let shell = CodeSyntaxVocabulary(
        keywords: [
            "case", "do", "done", "elif", "else", "esac", "fi", "for", "function",
            "if", "in", "select", "then", "until", "while"
        ],
        types: [],
        constants: [
            "false", "true"
        ]
    )

    /// Rust.
    public static let rust = CodeSyntaxVocabulary(
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn",
            "else", "enum", "extern", "false", "fn", "for", "if", "impl", "in",
            "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return",
            "self", "static", "struct", "super", "trait", "true", "type", "unsafe",
            "use", "where", "while"
        ],
        types: [
            "Box", "Option", "Result", "Self", "String", "Vec", "bool", "char",
            "f32", "f64", "i32", "i64", "isize", "str", "u32", "u64", "usize"
        ],
        constants: [
            "false", "None", "Some", "true"
        ]
    )

    /// Go.
    public static let go = CodeSyntaxVocabulary(
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer",
            "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
            "interface", "map", "package", "range", "return", "select", "struct",
            "switch", "type", "var"
        ],
        types: [
            "any", "bool", "byte", "complex64", "complex128", "error", "float32",
            "float64", "int", "int32", "int64", "rune", "string", "uint", "uint64"
        ],
        constants: [
            "false", "nil", "true"
        ]
    )

    /// C, C++, and Objective-C.
    public static let c = CodeSyntaxVocabulary(
        keywords: [
            "auto", "break", "case", "catch", "class", "const", "constexpr",
            "continue", "default", "delete", "do", "else", "enum", "extern", "for",
            "friend", "goto", "if", "inline", "namespace", "new", "operator",
            "private", "protected", "public", "return", "sizeof", "static",
            "struct", "switch", "template", "this", "throw", "try", "typedef",
            "typename", "union", "using", "virtual", "void", "while"
        ],
        types: [
            "BOOL", "bool", "char", "double", "float", "int", "int32_t", "int64_t",
            "long", "short", "size_t", "std", "string", "uint32_t", "uint64_t"
        ],
        constants: [
            "false", "NULL", "nullptr", "true"
        ]
    )

    /// Java, Kotlin, and C#.
    public static let java = CodeSyntaxVocabulary(
        keywords: [
            "abstract", "as", "break", "case", "catch", "class", "const",
            "continue", "default", "do", "else", "enum", "extends", "final",
            "finally", "for", "fun", "if", "implements", "import", "in",
            "interface", "internal", "is", "new", "object", "override", "package",
            "private", "protected", "public", "return", "sealed", "static",
            "switch", "this", "throw", "throws", "try", "val", "var", "void",
            "when", "while"
        ],
        types: [
            "Boolean", "Char", "Double", "Exception", "Float", "Int", "Integer",
            "List", "Long", "Map", "String", "boolean", "char", "double", "float",
            "int", "long", "string"
        ],
        constants: [
            "false", "null", "true"
        ]
    )

    /// PHP.
    public static let php = CodeSyntaxVocabulary(
        keywords: [
            "abstract", "and", "array", "as", "break", "case", "catch", "class",
            "clone", "const", "continue", "declare", "default", "do", "echo",
            "else", "elseif", "extends", "final", "finally", "for", "foreach",
            "function", "global", "if", "implements", "interface", "namespace",
            "new", "or", "private", "protected", "public", "return", "static",
            "switch", "throw", "trait", "try", "use", "var", "while", "xor"
        ],
        types: [
            "bool", "float", "int", "mixed", "string", "void"
        ],
        constants: [
            "false", "null", "true"
        ]
    )

    /// Ruby.
    public static let ruby = CodeSyntaxVocabulary(
        keywords: [
            "BEGIN", "END", "alias", "and", "begin", "break", "case", "class",
            "def", "defined", "do", "else", "elsif", "end", "ensure", "false",
            "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
            "rescue", "retry", "return", "self", "super", "then", "true", "undef",
            "unless", "until", "when", "while", "yield"
        ],
        types: [
            "Array", "Class", "Hash", "Integer", "Module", "String", "Symbol"
        ],
        constants: [
            "false", "nil", "true"
        ]
    )

    /// SQL.
    public static let sql = CodeSyntaxVocabulary(
        keywords: [
            "ALTER", "AND", "AS", "ASC", "BETWEEN", "BY", "CASE", "CREATE",
            "DELETE", "DESC", "DISTINCT", "DROP", "ELSE", "END", "FROM", "GROUP",
            "HAVING", "IN", "INSERT", "INTO", "IS", "JOIN", "LEFT", "LIKE",
            "LIMIT", "NOT", "NULL", "ON", "OR", "ORDER", "RIGHT", "SELECT", "SET",
            "TABLE", "THEN", "UPDATE", "VALUES", "WHEN", "WHERE"
        ],
        types: [
            "BIGINT", "BOOLEAN", "DATE", "FLOAT", "INT", "INTEGER", "TEXT",
            "VARCHAR"
        ],
        constants: [
            "FALSE", "NULL", "TRUE"
        ]
    )

    /// Dockerfiles.
    public static let docker = CodeSyntaxVocabulary(
        keywords: [
            "ADD", "ARG", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE", "FROM",
            "HEALTHCHECK", "LABEL", "MAINTAINER", "ONBUILD", "RUN", "SHELL",
            "STOPSIGNAL", "USER", "VOLUME", "WORKDIR"
        ],
        types: [],
        constants: []
    )
}
