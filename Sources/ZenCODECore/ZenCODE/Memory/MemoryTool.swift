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
            description: "Reads durable entries from the project MEMORY.md journal for the current workspace.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "includeArchived": { "type": "boolean" },
                "limit": { "type": "number" }
              }
            }
            """
        ),
        ToolDescriptor(
            name: "memory.search",
            title: "Memory Search",
            description: "Searches durable entries in the project MEMORY.md journal for codebase history and resume points.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "query": { "type": "string" },
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
            description: "Appends one durable entry to the project MEMORY.md journal. Use concise end-of-turn entries with Timestamp, Summary, State, and Next. If the entry omits Timestamp, the tool adds the current local timestamp.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "content": { "type": "string" }
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
                "id": { "type": "string" }
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
        let includeArchived = parsedIncludeArchived(from: arguments)
        let limit = parsedLimit(from: arguments)

        let resolvedEntries: [MemoryEntry]
        if let workspaceContext = context.workspaceContext {
            resolvedEntries = memoryService.readEntries(
                scope: .project,
                for: workspaceContext,
                includeArchived: includeArchived,
                limit: limit
            )
        } else {
            resolvedEntries = memoryService.readEntries(
                scope: .project,
                workingDirectory: context.workingDirectory,
                includeArchived: includeArchived,
                limit: limit
            )
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

        let includeArchived = parsedIncludeArchived(from: arguments)
        let limit = parsedLimit(from: arguments)

        let entries: [MemoryEntry]
        if let workspaceContext = context.workspaceContext {
            entries = memoryService.searchEntries(
                query: query,
                scope: .project,
                for: workspaceContext,
                includeArchived: includeArchived,
                limit: limit
            )
        } else {
            entries = memoryService.searchEntries(
                query: query,
                scope: .project,
                workingDirectory: context.workingDirectory,
                includeArchived: includeArchived,
                limit: limit
            )
        }

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

        let scope = MemoryScope.project
        let contentToWrite = contentWithTimestampIfNeeded(
            content,
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
                scope: .project,
                for: workspaceContext
            )
        } else {
            entry = try memoryService.archiveEntry(
                id: entryID,
                scope: .project,
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
        context: MemoryToolContext
    ) -> String {
        guard !contentContainsTimestamp(content) else {
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

    private static func parsedIncludeArchived(from arguments: [String: JSONValue]) -> Bool {
        arguments["includeArchived"]?.boolValue
            ?? arguments["include_archived"]?.boolValue
            ?? false
    }

    private static func parsedLimit(from arguments: [String: JSONValue]) -> Int {
        min(max(Int(arguments["limit"]?.numberValue ?? 8), 1), 50)
    }

    private static func renderEntries(_ entries: [MemoryEntry]) -> String {
        guard !entries.isEmpty else {
            return "No memory entries matched."
        }

        let renderedEntries = entries.enumerated().map { index, entry in
            "\(index + 1). \(renderEntry(entry))"
        }
        .joined(separator: "\n\n")

        return """
        Project MEMORY.md:
        \(renderedEntries)
        """
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
