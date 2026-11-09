//
//  ToolAllowlist.swift
//  ZenCODE
//

/// The base matching rule of a tool allowlist: an entry grants the tool with
/// exactly its name, and an entry ending in "." grants every tool whose name
/// starts with it (`local.` grants `local.readFile`; `local` and `loc.` do
/// not). Matching is case-sensitive.
///
/// MCP discovery and the system prompt apply only this rule.
/// `DirectToolExecutor.isAllowed(_:allowedToolNames:)` adds the nil and empty
/// allowlist policy before it and the coordination-alias resolution after it.
enum ToolAllowlist {
    static func matches(_ toolName: String, in allowedToolNames: Set<String>) -> Bool {
        if allowedToolNames.contains(toolName) {
            return true
        }
        return allowedToolNames.contains { allowedToolName in
            allowedToolName.hasSuffix(".") && toolName.hasPrefix(allowedToolName)
        }
    }
}
