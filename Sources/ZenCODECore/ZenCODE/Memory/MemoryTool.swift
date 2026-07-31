//
//  MemoryTool.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public struct MemoryToolContext: Sendable {
    public let workingDirectory: URL?
    public let currentDate: Date
    public let currentTimeZone: TimeZone

    public init(
        workingDirectory: URL? = nil,
        currentDate: Date = Date(),
        currentTimeZone: TimeZone = .current
    ) {
        self.workingDirectory = workingDirectory
        self.currentDate = currentDate
        self.currentTimeZone = currentTimeZone
    }
}

public enum MemoryTool {
    private enum RenderDetail: String {
        case full
        case index
    }

    public static let toolDescriptors: [ToolDescriptor] = [
        ToolDescriptor(
            name: "memory.read",
            title: "Memory Read",
            description: "Reads durable project MEMORY.md entries. Use detail=index for compact Summary/timestamp/ID results before loading full content.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "includeArchived": { "type": "boolean" },
                "limit": { "type": "number" },
                "detail": { "type": "string", "enum": ["full", "index"] }
              }
            }
            """,
            presentation: .standard(
                title: "Project memory",
                action: "Read",
                kind: .read
            )
        ),
        ToolDescriptor(
            name: "memory.search",
            title: "Memory Search",
            description: "Searches durable project memory with weighted exact phrase, Summary, State, and term coverage ranking.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "query": { "type": "string" },
                "includeArchived": { "type": "boolean" },
                "limit": { "type": "number" },
                "detail": { "type": "string", "enum": ["full", "index"] }
              },
              "required": ["query"]
            }
            """,
            presentation: .standard(
                title: "Project memory",
                action: "Search",
                kind: .search,
                targetKeyPaths: ["query"]
            )
        ),
        ToolDescriptor(
            name: "memory.write",
            title: "Memory Write",
            description: "Appends one new durable entry to the project MEMORY.md journal. Use concise entries with Timestamp, Summary, State, and Next; the current local Timestamp is added when missing.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "content": { "type": "string" }
              },
              "required": ["content"]
            }
            """,
            presentation: .standard(
                title: "Project memory",
                action: "Write",
                kind: .edit
            )
        ),
        ToolDescriptor(
            name: "memory.update",
            title: "Memory Update",
            description: "Replaces the full content of one durable memory entry while preserving its id and archive state. It preserves the original Timestamp and adds the current Updated timestamp when those fields are omitted.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "id": { "type": "string" },
                "content": { "type": "string" }
              },
              "required": ["id", "content"]
            }
            """,
            presentation: .standard(
                title: "Memory entry",
                action: "Update",
                kind: .edit,
                targetKeyPaths: ["id"]
            )
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
            """,
            presentation: .standard(
                title: "Memory entry",
                action: "Archive",
                kind: .delete,
                targetKeyPaths: ["id"]
            )
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
        case "memory.update":
            return try update(
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
        let detail = parsedDetail(from: arguments)

        let resolvedEntries = try memoryService.readEntriesChecked(
            scope: .project,
            workingDirectory: context.workingDirectory,
            includeArchived: includeArchived,
            limit: limit
        )

        return ToolExecutionOutput(
            text: renderEntries(resolvedEntries, detail: detail),
            rawResult: .object([
                "count": .number(Double(resolvedEntries.count)),
                "detail": .string(detail.rawValue),
                "entries": .array(resolvedEntries.map { memoryJSONValue($0, detail: detail) })
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
        let detail = parsedDetail(from: arguments)

        let entries = try memoryService.searchEntriesChecked(
            query: query,
            scope: .project,
            workingDirectory: context.workingDirectory,
            includeArchived: includeArchived,
            limit: limit
        )

        return ToolExecutionOutput(
            text: """
            Query: \(query)
            \(renderEntries(entries, detail: detail))
            """,
            rawResult: .object([
                "query": .string(query),
                "count": .number(Double(entries.count)),
                "detail": .string(detail.rawValue),
                "entries": .array(entries.map { memoryJSONValue($0, detail: detail) })
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
        let entry = try memoryService.writeEntry(
            content: contentToWrite,
            scope: scope,
            workingDirectory: context.workingDirectory
        )

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

    private static func update(
        arguments: [String: JSONValue],
        context: MemoryToolContext,
        memoryService: MemoryService
    ) throws -> ToolExecutionOutput {
        guard let rawIdentifier = arguments["id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawIdentifier.isEmpty else {
            throw MemoryServiceError.missingField("id")
        }
        guard let id = UUID(uuidString: rawIdentifier) else {
            throw MemoryServiceError.invalidIdentifier(rawIdentifier)
        }
        guard let content = parsedContent(from: arguments) else {
            throw MemoryServiceError.missingField("content")
        }

        let entry = try memoryService.updateEntry(
            id: id,
            content: content,
            scope: .project,
            workspaceRootURL: context.workingDirectory?.standardizedFileURL,
            updatedAt: context.currentDate,
            timeZone: context.currentTimeZone
        )

        return ToolExecutionOutput(
            text: """
            Updated memory entry.
            \(renderEntry(entry))
            """,
            rawResult: .object([
                "updated": .bool(true),
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

        let entry = try memoryService.archiveEntry(
            id: entryID,
            scope: .project,
            workingDirectory: context.workingDirectory
        )

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
        MemoryEntryMetadata(content: content).timestamp != nil
    }

    private static func parsedIncludeArchived(from arguments: [String: JSONValue]) -> Bool {
        arguments["includeArchived"]?.boolValue
            ?? arguments["include_archived"]?.boolValue
            ?? false
    }

    private static func parsedDetail(from arguments: [String: JSONValue]) -> RenderDetail {
        let rawValue = arguments["detail"]?.stringValue
            ?? arguments["mode"]?.stringValue
            ?? RenderDetail.full.rawValue
        return RenderDetail(rawValue: rawValue.lowercased()) ?? .full
    }

    private static func parsedLimit(from arguments: [String: JSONValue]) -> Int {
        let rawLimit = arguments["limit"]?.numberValue ?? 8
        guard rawLimit.isFinite else {
            return 8
        }
        let clampedLimit = min(max(rawLimit, 1), 50)
        return Int(exactly: clampedLimit.rounded(.towardZero)) ?? 8
    }

    private static func renderEntries(
        _ entries: [MemoryEntry],
        detail: RenderDetail
    ) -> String {
        guard !entries.isEmpty else {
            return "No memory entries matched."
        }

        let renderedEntries = entries.enumerated().map { index, entry in
            let renderedEntry = detail == .index
                ? renderIndexEntry(entry)
                : renderEntry(entry)
            return "\(index + 1). \(renderedEntry)"
        }
        .joined(separator: "\n\n")

        let heading = detail == .index
            ? "Project MEMORY.md index:"
            : "Project MEMORY.md:"
        return """
        \(heading)
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

    private static func renderIndexEntry(_ entry: MemoryEntry) -> String {
        let metadata = entry.metadata
        var lines = ["[\(entry.scope.rawValue)] \(entry.title)"]
        if let timestamp = metadata.timestamp {
            lines.append("Timestamp: \(timestamp)")
        }
        if let updated = metadata.updated {
            lines.append("Updated: \(updated)")
        }
        lines.append("ID: \(entry.id.uuidString)")
        if entry.isArchived {
            lines.append("Archived: true")
        }
        return lines.joined(separator: "\n")
    }

    private static func memoryJSONValue(_ entry: MemoryEntry) -> JSONValue {
        memoryJSONValue(entry, detail: .full)
    }

    private static func memoryJSONValue(
        _ entry: MemoryEntry,
        detail: RenderDetail
    ) -> JSONValue {
        var result: [String: JSONValue] = [
            "id": .string(entry.id.uuidString),
            "scope": .string(entry.scope.rawValue),
            "title": .string(entry.title),
            "archived": .bool(entry.isArchived),
            "metadata": metadataJSONValue(entry.metadata, detail: detail),
        ]
        if detail == .full {
            result["content"] = .string(entry.content)
        }
        return .object(result)
    }

    private static func metadataJSONValue(
        _ metadata: MemoryEntryMetadata,
        detail: RenderDetail
    ) -> JSONValue {
        var result: [String: JSONValue] = [:]
        if let timestamp = metadata.timestamp {
            result["timestamp"] = .string(timestamp)
        }
        if let updated = metadata.updated {
            result["updated"] = .string(updated)
        }
        if let summary = metadata.summary {
            result["summary"] = .string(summary)
        }
        if detail == .full {
            if let state = metadata.state {
                result["state"] = .string(state)
            }
            if let next = metadata.next {
                result["next"] = .string(next)
            }
        }
        return .object(result)
    }
}
