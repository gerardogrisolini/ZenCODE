//
//  ToolLanguageHint.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// Chooses the syntax-highlighting language of the source a tool call shows.
/// The choice is made strictly from the extension of the target file; text,
/// documentation, configuration and unknown extensions stay neutral.
enum ToolLanguageHint {
    /// Selects syntax highlighting strictly from the target file extension of
    /// `toolCall`: the first patch target of `local.applyPatch`, the first
    /// path argument of any other tool.
    static func hint(for toolCall: DirectAgentToolCall) -> String? {
        let arguments = toolCall.argumentsObject
        let path = ToolMutationClassifier.normalizedMutationToolName(toolCall.name) == "local.applyPatch"
            ? ToolArgumentReader.patchTargetPath(arguments)
            : ToolArgumentReader.targetPath(arguments)
        guard let path else { return nil }
        return hint(forPath: path)
    }

    /// The syntax-highlighting language of a file, chosen strictly from its
    /// extension (`swift`, `python`, `typescript`, …). Text, documentation,
    /// configuration, and unknown extensions return `nil` and stay neutral.
    /// The terminal's tool calls and file artifacts use it directly; a host app
    /// reaches it through the public forwarding
    /// ``TerminalChat/codeLanguageHint(forPath:)`` to color a file as the
    /// terminal does.
    static func hint(forPath path: String) -> String? {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": return "swift"
        case "c", "h": return "c"
        case "cc", "cpp", "cxx", "hh", "hpp", "hxx": return "cpp"
        case "m": return "objc"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py": return "python"
        case "sh", "bash", "zsh": return "shell"
        case "rs": return "rust"
        case "go": return "go"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "cs": return "csharp"
        case "rb": return "ruby"
        case "php": return "php"
        case "json", "jsonl", "jsonc": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "toml"
        case "html", "htm": return "html"
        case "xml": return "xml"
        case "css": return "css"
        case "sql": return "sql"
        default: return nil
        }
    }
}
