//
//  MemoryTool.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation

public struct MemoryToolContext: Sendable {
    public let workspaceContext: XcodeWorkspaceContext?
    public let workingDirectory: URL?
    public let currentDate: Date
    public let currentTimeZone: TimeZone

    public init(
        workspaceContext: XcodeWorkspaceContext? = nil,
        workingDirectory: URL? = nil,
        currentDate: Date = Date(),
        currentTimeZone: TimeZone = .current
    ) {
        self.workspaceContext = workspaceContext
        self.workingDirectory = workingDirectory
        self.currentDate = currentDate
        self.currentTimeZone = currentTimeZone
    }
}

public enum MemoryTool {
    public static let toolDescriptors: [ToolDescriptor] = [
        ToolDescriptor(
            name: "memory.read",
            title: "Memory Read",
            description: "Reads durable entries from global and project MEMORY.md files. Project memory is the codebase journal; global memory is only a lightweight per-project saved-session index for sessions without a clear workspace.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "scope": { "type": "string", "enum": ["global", "project", "all"] },
                "includeArchived": { "type": "boolean" },
                "limit": { "type": "number" }
              }
            }
            """
        ),
        ToolDescriptor(
            name: "memory.search",
            title: "Memory Search",
            description: "Searches durable entries from global and project MEMORY.md files. Search project memory for codebase history and resume points; use global memory only to find the relevant project/session pointer when no workspace is clear.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "query": { "type": "string" },
                "scope": { "type": "string", "enum": ["global", "project", "all"] },
                "includeArchived": { "type": "boolean" },
                "limit": { "type": "number" }
              },
              "required": ["query"]
            }
            """
        ),
        ToolDescriptor(
            name: "memory.write",
            title: "Memory Write",
            description: "Appends one durable entry to the right MEMORY.md scope. Use project for concise end-of-turn journal entries with Timestamp, Summary, State, and Next. If a project entry omits Timestamp, the tool adds the current local timestamp. Global saved-session pointers are maintained programmatically per project when sessions are saved.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "content": { "type": "string" },
                "scope": {
                  "type": "string",
                  "enum": ["global", "project"],
                  "description": "Use project for the codebase journal when the current workspace is clear. Global is only for lightweight project/session routing and saved-session pointers are maintained programmatically."
                }
              },
              "required": ["content"]
            }
            """
        ),
        ToolDescriptor(
            name: "memory.archive",
            title: "Memory Archive",
            description: "Archives a durable memory or journal entry by id so it no longer influences future resume context.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "id": { "type": "string" },
                "scope": { "type": "string", "enum": ["global", "project", "all"] }
              },
              "required": ["id"]
            }
            """
        )
    ]

    public static func isMemoryToolName(_ toolName: String) -> Bool {
        toolDescriptors.contains { $0.name == toolName }
    }

    public static func execute(
        _ request: ToolRequest,
        context: MemoryToolContext,
        memoryService: MemoryService = MemoryService()
    ) throws -> ToolExecutionOutput {
        switch request.name {
        case "memory.read":
            return try read(
                arguments: request.arguments,
                context: context,
                memoryService: memoryService
            )
        case "memory.search":
            return try search(
                arguments: request.arguments,
                context: context,
                memoryService: memoryService
            )
        case "memory.write":
            return try write(
                arguments: request.arguments,
                context: context,
                memoryService: memoryService
            )
        case "memory.archive":
            return try archive(
                arguments: request.arguments,
                context: context,
                memoryService: memoryService
            )
        default:
            throw ToolExecutionError.toolNotAvailable(request.name)
        }
    }

    private static func read(
        arguments: [String: JSONValue],
        context: MemoryToolContext,
        memoryService: MemoryService
    ) throws -> ToolExecutionOutput {
        let scope = parsedScope(from: arguments)
        let includeArchived = parsedIncludeArchived(from: arguments)
        let limit = parsedLimit(from: arguments)

        func readEntries(for scope: MemoryScope?) -> [MemoryEntry] {
            if let workspaceContext = context.workspaceContext {
                return memoryService.readEntries(
                    scope: scope,
                    for: workspaceContext,
                    includeArchived: includeArchived,
                    limit: limit
                )
            }

            return memoryService.readEntries(
                scope: scope,
                workingDirectory: context.workingDirectory,
                includeArchived: includeArchived,
                limit: limit
            )
        }

        let resolvedEntries: [MemoryEntry]
        if let scope {
            resolvedEntries = readEntries(for: scope)
        } else {
            resolvedEntries = readEntries(for: .global) + readEntries(for: .project)
        }

        return ToolExecutionOutput(
            text: renderEntries(resolvedEntries),
            rawResult: .object([
                "count": .number(Double(resolvedEntries.count)),
                "entries": .array(resolvedEntries.map(memoryJSONValue))
            ])
        )
    }

    private static func search(
        arguments: [String: JSONValue],
        context: MemoryToolContext,
        memoryService: MemoryService
    ) throws -> ToolExecutionOutput {
        guard let query = arguments["query"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            throw MemoryServiceError.missingField("query")
        }

        let scope = parsedScope(from: arguments)
        let includeArchived = parsedIncludeArchived(from: arguments)
        let limit = parsedLimit(from: arguments)

        func searchEntries(for scope: MemoryScope?) -> [MemoryEntry] {
            if let workspaceContext = context.workspaceContext {
                return memoryService.searchEntries(
                    query: query,
                    scope: scope,
                    for: workspaceContext,
                    includeArchived: includeArchived,
                    limit: limit
                )
            }

            return memoryService.searchEntries(
                query: query,
                scope: scope,
                workingDirectory: context.workingDirectory,
                includeArchived: includeArchived,
                limit: limit
            )
        }

        let entries = searchEntries(for: scope)

        return ToolExecutionOutput(
            text: """
            Query: \(query)
            \(renderEntries(entries))
            """,
            rawResult: .object([
                "query": .string(query),
                "count": .number(Double(entries.count)),
                "entries": .array(entries.map(memoryJSONValue))
            ])
        )
    }

    private static func write(
        arguments: [String: JSONValue],
        context: MemoryToolContext,
        memoryService: MemoryService
    ) throws -> ToolExecutionOutput {
        guard let content = parsedContent(from: arguments) else {
            throw MemoryServiceError.missingField("content")
        }

        let scope = parsedWriteScope(from: arguments)
            ?? defaultWriteScope(context: context)
        let contentToWrite = contentWithTimestampIfNeeded(
            content,
            scope: scope,
            context: context
        )
        let entry: MemoryEntry
        if let workspaceContext = context.workspaceContext {
            entry = try memoryService.writeEntry(
                content: contentToWrite,
                scope: scope,
                workspaceContext: workspaceContext
            )
        } else {
            entry = try memoryService.writeEntry(
                content: contentToWrite,
                scope: scope,
                workingDirectory: context.workingDirectory
            )
        }

        return ToolExecutionOutput(
            text: """
            Saved memory entry to \(scope.rawValue) MEMORY.md.
            \(renderEntry(entry))
            """,
            rawResult: .object([
                "written": .bool(true),
                "entry": memoryJSONValue(entry)
            ])
        )
    }

    private static func archive(
        arguments: [String: JSONValue],
        context: MemoryToolContext,
        memoryService: MemoryService
    ) throws -> ToolExecutionOutput {
        guard let entryID = arguments["id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !entryID.isEmpty else {
            throw MemoryServiceError.missingField("id")
        }

        let entry: MemoryEntry
        if let workspaceContext = context.workspaceContext {
            entry = try memoryService.archiveEntry(
                id: entryID,
                scope: parsedScope(from: arguments),
                for: workspaceContext
            )
        } else {
            entry = try memoryService.archiveEntry(
                id: entryID,
                scope: parsedScope(from: arguments),
                workingDirectory: context.workingDirectory
            )
        }

        return ToolExecutionOutput(
            text: """
            Archived memory entry.
            \(renderEntry(entry))
            """,
            rawResult: .object([
                "archived": .bool(true),
                "entry": memoryJSONValue(entry)
            ])
        )
    }

    private static func parsedContent(from arguments: [String: JSONValue]) -> String? {
        let content = arguments["content"]?.stringValue
            ?? arguments["text"]?.stringValue
            ?? arguments["note"]?.stringValue
        return MemoryEntry.normalizedContent(content ?? "").isEmpty ? nil : content
    }

    private static func contentWithTimestampIfNeeded(
        _ content: String,
        scope: MemoryScope,
        context: MemoryToolContext
    ) -> String {
        guard scope == .project,
              !contentContainsTimestamp(content) else {
            return content
        }

        return """
        Timestamp: \(MemoryService.timestampString(context.currentDate, timeZone: context.currentTimeZone))
        \(content)
        """
    }

    private static func contentContainsTimestamp(_ content: String) -> Bool {
        content
            .components(separatedBy: .newlines)
            .contains { line in
                line.trimmingCharacters(in: .whitespaces)
                    .lowercased()
                    .hasPrefix("timestamp:")
            }
    }

    private static func parsedScope(from arguments: [String: JSONValue]) -> MemoryScope? {
        guard let rawValue = arguments["scope"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
              rawValue != "all" else {
            return nil
        }
        switch rawValue {
        case "workspace", "task":
            return .project
        case "pattern", "preference":
            return .global
        default:
            break
        }
        return MemoryScope(rawValue: rawValue)
    }

    private static func parsedWriteScope(from arguments: [String: JSONValue]) -> MemoryScope? {
        guard let rawValue = arguments["scope"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else {
            return nil
        }
        switch rawValue {
        case "workspace", "task":
            return .project
        case "pattern", "preference":
            return .global
        default:
            break
        }
        return MemoryScope(rawValue: rawValue)
    }

    private static func parsedIncludeArchived(from arguments: [String: JSONValue]) -> Bool {
        arguments["includeArchived"]?.boolValue
            ?? arguments["include_archived"]?.boolValue
            ?? false
    }

    private static func parsedLimit(from arguments: [String: JSONValue]) -> Int {
        min(max(Int(arguments["limit"]?.numberValue ?? 8), 1), 50)
    }

    private static func defaultWriteScope(
        context: MemoryToolContext
    ) -> MemoryScope {
        if context.workspaceContext != nil || context.workingDirectory != nil {
            return .project
        }
        return .global
    }

    private static func renderEntries(_ entries: [MemoryEntry]) -> String {
        guard !entries.isEmpty else {
            return "No memory entries matched."
        }

        return [MemoryScope.global, .project]
            .compactMap { scope -> String? in
                let scopedEntries = entries.filter { $0.scope == scope }
                guard !scopedEntries.isEmpty else {
                    return nil
                }

                let title = scope == .global
                    ? "Global MEMORY.md"
                    : "Project MEMORY.md"
                let renderedEntries = scopedEntries.enumerated().map { index, entry in
                    "\(index + 1). \(renderEntry(entry))"
                }
                .joined(separator: "\n\n")

                return """
                \(title):
                \(renderedEntries)
                """
            }
            .joined(separator: "\n\n")
    }

    private static func renderEntry(_ entry: MemoryEntry) -> String {
        var lines = [
            "[\(entry.scope.rawValue)] \(entry.content)",
            "ID: \(entry.id.uuidString)"
        ]
        if entry.isArchived {
            lines.append("Archived: true")
        }
        return lines.joined(separator: "\n")
    }

    private static func memoryJSONValue(_ entry: MemoryEntry) -> JSONValue {
        .object([
            "id": .string(entry.id.uuidString),
            "scope": .string(entry.scope.rawValue),
            "content": .string(entry.content),
            "archived": .bool(entry.isArchived)
        ])
    }
}
