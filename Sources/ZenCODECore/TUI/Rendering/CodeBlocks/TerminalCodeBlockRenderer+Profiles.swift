//
//  TerminalCodeBlockRenderer+Profiles.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/05/26.
//

import Foundation

extension TerminalCodeBlockRenderer {
    static func profile(for language: String?) -> SyntaxProfile {
        switch language {
        case "swift":
            return swiftProfile
        case "javascript", "typescript":
            return javaScriptProfile
        case "python":
            return pythonProfile
        case "shell":
            return shellProfile
        case "rust":
            return rustProfile
        case "go":
            return goProfile
        case "c", "cpp", "objc":
            return cProfile
        case "java", "kotlin", "csharp":
            return javaProfile
        case "php":
            return phpProfile
        case "ruby":
            return rubyProfile
        case "sql":
            return sqlProfile
        case "docker":
            return dockerProfile
        default:
            return .generic
        }
    }

    private static let swiftProfile = SyntaxProfile(
        keywords: CodeSyntaxVocabulary.swift.keywords,
        types: CodeSyntaxVocabulary.swift.types,
        constants: CodeSyntaxVocabulary.swift.constants,
        lineComments: ["//"],
        attributePrefixes: ["@"],
        directivePrefixes: ["#"],
        stringDelimiters: ["\""],
        allowsSwiftRawStrings: true
    )

    private static let javaScriptProfile = SyntaxProfile(
        keywords: CodeSyntaxVocabulary.javaScript.keywords,
        types: CodeSyntaxVocabulary.javaScript.types,
        constants: CodeSyntaxVocabulary.javaScript.constants,
        lineComments: ["//"],
        attributePrefixes: ["@"],
        directivePrefixes: [],
        stringDelimiters: ["\"", "'", "`"],
        allowsSwiftRawStrings: false
    )

    private static let pythonProfile = SyntaxProfile(
        keywords: CodeSyntaxVocabulary.python.keywords,
        types: CodeSyntaxVocabulary.python.types,
        constants: CodeSyntaxVocabulary.python.constants,
        lineComments: ["#"],
        attributePrefixes: ["@"],
        directivePrefixes: [],
        stringDelimiters: ["\"", "'"],
        allowsSwiftRawStrings: false
    )

    private static let shellProfile = SyntaxProfile(
        keywords: CodeSyntaxVocabulary.shell.keywords,
        types: CodeSyntaxVocabulary.shell.types,
        constants: CodeSyntaxVocabulary.shell.constants,
        lineComments: ["#"],
        attributePrefixes: [],
        directivePrefixes: [],
        stringDelimiters: ["\"", "'", "`"],
        allowsSwiftRawStrings: false
    )

    private static let rustProfile = SyntaxProfile(
        keywords: CodeSyntaxVocabulary.rust.keywords,
        types: CodeSyntaxVocabulary.rust.types,
        constants: CodeSyntaxVocabulary.rust.constants,
        lineComments: ["//"],
        attributePrefixes: ["#"],
        directivePrefixes: [],
        stringDelimiters: ["\""],
        allowsSwiftRawStrings: false
    )

    private static let goProfile = SyntaxProfile(
        keywords: CodeSyntaxVocabulary.go.keywords,
        types: CodeSyntaxVocabulary.go.types,
        constants: CodeSyntaxVocabulary.go.constants,
        lineComments: ["//"],
        attributePrefixes: [],
        directivePrefixes: [],
        stringDelimiters: ["\"", "'", "`"],
        allowsSwiftRawStrings: false
    )

    private static let cProfile = SyntaxProfile(
        keywords: CodeSyntaxVocabulary.c.keywords,
        types: CodeSyntaxVocabulary.c.types,
        constants: CodeSyntaxVocabulary.c.constants,
        lineComments: ["//"],
        attributePrefixes: ["@"],
        directivePrefixes: ["#"],
        stringDelimiters: ["\"", "'"],
        allowsSwiftRawStrings: false
    )

    private static let javaProfile = SyntaxProfile(
        keywords: CodeSyntaxVocabulary.java.keywords,
        types: CodeSyntaxVocabulary.java.types,
        constants: CodeSyntaxVocabulary.java.constants,
        lineComments: ["//"],
        attributePrefixes: ["@"],
        directivePrefixes: ["#"],
        stringDelimiters: ["\"", "'"],
        allowsSwiftRawStrings: false
    )

    private static let phpProfile = SyntaxProfile(
        keywords: CodeSyntaxVocabulary.php.keywords,
        types: CodeSyntaxVocabulary.php.types,
        constants: CodeSyntaxVocabulary.php.constants,
        lineComments: ["//", "#"],
        attributePrefixes: ["@"],
        directivePrefixes: [],
        stringDelimiters: ["\"", "'"],
        allowsSwiftRawStrings: false
    )

    private static let rubyProfile = SyntaxProfile(
        keywords: CodeSyntaxVocabulary.ruby.keywords,
        types: CodeSyntaxVocabulary.ruby.types,
        constants: CodeSyntaxVocabulary.ruby.constants,
        lineComments: ["#"],
        attributePrefixes: ["@"],
        directivePrefixes: [],
        stringDelimiters: ["\"", "'", "`"],
        allowsSwiftRawStrings: false
    )

    private static let sqlProfile = SyntaxProfile(
        keywords: CodeSyntaxVocabulary.sql.keywords,
        types: CodeSyntaxVocabulary.sql.types,
        constants: CodeSyntaxVocabulary.sql.constants,
        lineComments: ["--"],
        attributePrefixes: [],
        directivePrefixes: [],
        stringDelimiters: ["\"", "'"],
        allowsSwiftRawStrings: false
    )

    private static let dockerProfile = SyntaxProfile(
        keywords: CodeSyntaxVocabulary.docker.keywords,
        types: CodeSyntaxVocabulary.docker.types,
        constants: CodeSyntaxVocabulary.docker.constants,
        lineComments: ["#"],
        attributePrefixes: [],
        directivePrefixes: [],
        stringDelimiters: ["\"", "'"],
        allowsSwiftRawStrings: false
    )
}
