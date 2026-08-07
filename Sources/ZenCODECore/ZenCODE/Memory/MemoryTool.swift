//
//  MemoryTool.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ZenMemory
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

    private static let readDescriptor = ToolDescriptor(
            name: "memory.read",
            title: "Memory Read",
            description: "Reads durable project memory entries, newest first. Use detail=index for compact Summary/timestamp/ID results before loading full content.",
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
        )

    private static let searchDescriptor = ToolDescriptor(
            name: "memory.search",
            title: "Memory Search",
            description: "Searches durable project memory with hybrid semantic and keyword retrieval, then follows graph links to related entries.",
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
        )

    private static let writeDescriptor = ToolDescriptor(
            name: "memory.write",
            title: "Memory Write",
            description: "Adds one new durable entry to project memory. Use concise entries with Summary, State, and Next; the current local Timestamp is added when missing. Writing content that already matches an active entry returns that entry instead of duplicating it.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "content": { "type": "string" },
                "tags": { "type": "array", "items": { "type": "string" } },
                "category": {
                  "type": "string",
                  "enum": ["fact", "preference", "entity", "correction"]
                }
              },
              "required": ["content"]
            }
            """,
            presentation: .standard(
                title: "Project memory",
                action: "Write",
                kind: .edit
            )
        )

    private static let updateDescriptor = ToolDescriptor(
            name: "memory.update",
            title: "Memory Update",
            description: "Rewrites one durable memory entry in place. The entry keeps its id, creation date and archive state, so the id stays valid afterwards. It preserves the original Timestamp and adds the current Updated timestamp when those fields are omitted.",
            inputSchema: """
            {
              "type": "object",
              "properties": {
                "id": { "type": "string" },
                "content": { "type": "string" },
                "tags": { "type": "array", "items": { "type": "string" } }
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
        )

    private static let archiveDescriptor = ToolDescriptor(
            name: "memory.archive",
            title: "Memory Archive",
            description: "Archives a durable memory entry by id so it no longer influences retrieval or future resume context. The entry is deactivated, not deleted.",
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

    /// Core memory descriptors that do not mutate durable project memory.
    public static let readOnlyToolDescriptors: [ToolDescriptor] = [
        readDescriptor,
        searchDescriptor
    ]

    /// Core memory descriptors that can mutate durable project memory.
    public static let mutatingToolDescriptors: [ToolDescriptor] = [
        writeDescriptor,
        updateDescriptor,
        archiveDescriptor
    ]

    public static let toolDescriptors: [ToolDescriptor] = [
        readDescriptor,
        searchDescriptor,
        writeDescriptor,
        updateDescriptor,
        archiveDescriptor
    ]

    public static func isMemoryToolName(_ toolName: String) -> Bool {
        toolDescriptors.contains { $0.name == toolName }
    }

    public static func execute(
        _ request: ToolRequest,
        context: MemoryToolContext,
        memoryService: MemoryService = MemoryService()
    ) async throws -> ToolExecutionOutput {
        switch request.name {
        case "memory.read":
            return try await read(
                arguments: request.arguments,
                context: context,
                memoryService: memoryService
            )
        case "memory.search":
            return try await search(
                arguments: request.arguments,
                context: context,
                memoryService: memoryService
            )
        case "memory.write":
            return try await write(
                arguments: request.arguments,
                context: context,
                memoryService: memoryService
            )
        case "memory.update":
            return try await update(
                arguments: request.arguments,
                context: context,
                memoryService: memoryService
            )
        case "memory.archive":
            return try await archive(
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
    ) async throws -> ToolExecutionOutput {
        let includeArchived = parsedIncludeArchived(from: arguments)
        let limit = parsedLimit(from: arguments)
        let detail = parsedDetail(from: arguments)

        let resolvedEntries = try await memoryService.readEntries(
            workspaceRootURL: context.workingDirectory,
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
    ) async throws -> ToolExecutionOutput {
        guard let query = arguments["query"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !query.isEmpty else {
            throw MemoryServiceError.missingField("query")
        }

        let includeArchived = parsedIncludeArchived(from: arguments)
        let limit = parsedLimit(from: arguments)
        let detail = parsedDetail(from: arguments)

        let entries = try await memoryService.searchEntries(
            query: query,
            workspaceRootURL: context.workingDirectory,
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
    ) async throws -> ToolExecutionOutput {
        guard let content = parsedContent(from: arguments) else {
            throw MemoryServiceError.missingField("content")
        }

        let contentToWrite = contentWithTimestampIfNeeded(
            content,
            context: context
        )
        let entry = try await memoryService.writeEntry(
            content: contentToWrite,
            workspaceRootURL: context.workingDirectory,
            category: parsedCategory(from: arguments),
            tags: parsedTags(from: arguments) ?? []
        )

        return ToolExecutionOutput(
            text: """
            Saved memory entry to project memory.
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
    ) async throws -> ToolExecutionOutput {
        guard let rawIdentifier = arguments["id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawIdentifier.isEmpty else {
            throw MemoryServiceError.missingField("id")
        }
        guard let content = parsedContent(from: arguments) else {
            throw MemoryServiceError.missingField("content")
        }

        let entry = try await memoryService.updateEntry(
            id: rawIdentifier,
            content: content,
            workspaceRootURL: context.workingDirectory,
            tags: parsedTags(from: arguments),
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
    ) async throws -> ToolExecutionOutput {
        guard let entryID = arguments["id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !entryID.isEmpty else {
            throw MemoryServiceError.missingField("id")
        }

        let entry = try await memoryService.archiveEntry(
            id: entryID,
            workspaceRootURL: context.workingDirectory
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
        return MemoryContent.normalized(content ?? "").isEmpty ? nil : content
    }

    private static func parsedTags(from arguments: [String: JSONValue]) -> [String]? {
        guard let rawTags = arguments["tags"]?.arrayValue else {
            return nil
        }
        var seen = Set<String>()
        return rawTags.compactMap { value -> String? in
            guard let tag = value.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased(),
                  !tag.isEmpty,
                  seen.insert(tag).inserted else {
                return nil
            }
            return tag
        }
    }

    private static func parsedCategory(from arguments: [String: JSONValue]) -> MemoryCategory {
        switch arguments["category"]?.stringValue?.lowercased() {
        case "preference": return .preference
        case "entity": return .entity
        case "correction": return .correction
        default: return .fact
        }
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
            ? "Project memory index:"
            : "Project memory:"
        return """
        \(heading)
        \(renderedEntries)
        """
    }

    private static func renderEntry(_ entry: MemoryEntry) -> String {
        var lines = [
            "[\(entry.scope.rawValue)] \(entry.content)",
            "ID: \(entry.id)"
        ]
        if !entry.tags.isEmpty {
            lines.append("Tags: \(entry.tags.joined(separator: ", "))")
        }
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
        lines.append("ID: \(entry.id)")
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
            "id": .string(entry.id),
            "scope": .string(entry.scope.rawValue),
            "category": .string(entry.category.rawValue),
            "tags": .array(entry.tags.map { .string($0) }),
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
