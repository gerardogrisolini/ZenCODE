//
//  MemoryTool.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

import Foundation
import ToolCore

public struct MemoryToolContext: Sendable {
    /// The workspace root of a `.workspace` target; `nil` for the global graph
    /// or when no workspace is available.
    public let workingDirectory: URL?
    /// The graph every memory tool addresses; `nil` when none is available, in
    /// which case the tools fail with `scopeUnavailable`.
    public let graphTarget: MemoryGraphTarget?
    public let currentDate: Date
    public let currentTimeZone: TimeZone

    public init(
        workingDirectory: URL? = nil,
        currentDate: Date = Date(),
        currentTimeZone: TimeZone = .current
    ) {
        self.workingDirectory = workingDirectory
        self.graphTarget = workingDirectory.map { .workspace($0.standardizedFileURL) }
        self.currentDate = currentDate
        self.currentTimeZone = currentTimeZone
    }

    public init(
        graphTarget: MemoryGraphTarget?,
        currentDate: Date = Date(),
        currentTimeZone: TimeZone = .current
    ) {
        if case .workspace(let workspaceRootURL)? = graphTarget {
            self.workingDirectory = workspaceRootURL
        } else {
            self.workingDirectory = nil
        }
        self.graphTarget = graphTarget
        self.currentDate = currentDate
        self.currentTimeZone = currentTimeZone
    }
}

public enum MemoryTool {
    enum RenderDetail: String {
        case full
        case index
    }

    public static func isMemoryToolName(_ toolName: String) -> Bool {
        toolDescriptors.contains { $0.name == toolName }
    }

    /// Modern, async memory-tool entry point.
    ///
    /// Renamed from `execute` so it does not collide with the 1.1.x
    /// synchronous `execute` wrapper (see ``MemoryLegacyCompatibility``).
    /// Swift always prefers the `async` overload inside an `async` context,
    /// so a same-named pair would force every legacy `try MemoryTool.execute(…)`
    /// call site to add `await` — breaking source compatibility.  Splitting the
    /// name keeps `execute` unambiguously synchronous and `executeAsync`
    /// unambiguously the tool-layer entry point.
    public static func executeAsync(
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
        case "memory.get":
            return try await get(
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
        case "memory.restore":
            return try await restore(
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
        let offset = parsedOffset(from: arguments)
        let detail = parsedDetail(from: arguments)
        let filter = parsedFilter(from: arguments)

        // One extra entry tells whether the journal continues past this page.
        let page = try await memoryService.readEntries(
            target: context.graphTarget,
            includeArchived: includeArchived,
            offset: offset,
            limit: limit + 1,
            filter: filter
        )
        let hasMore = page.count > limit
        let resolvedEntries = Array(page.prefix(limit))

        var text = renderEntries(resolvedEntries, detail: detail)
        if hasMore {
            text += "\nMore entries follow: call memory.read again with offset \(offset + limit)."
        }
        return ToolExecutionOutput(
            text: text,
            rawResult: .object([
                "count": .number(Double(resolvedEntries.count)),
                "offset": .number(Double(offset)),
                "hasMore": .bool(hasMore),
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
        let filter = parsedFilter(from: arguments)

        let entries = try await memoryService.searchEntries(
            query: query,
            target: context.graphTarget,
            includeArchived: includeArchived,
            limit: limit,
            filter: filter
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

    private static func get(
        arguments: [String: JSONValue],
        context: MemoryToolContext,
        memoryService: MemoryService
    ) async throws -> ToolExecutionOutput {
        guard let rawIdentifier = arguments["id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawIdentifier.isEmpty else {
            throw MemoryServiceError.missingField("id")
        }
        guard let entry = try await memoryService.entry(
            id: rawIdentifier,
            target: context.graphTarget
        ) else {
            throw MemoryServiceError.entryNotFound(rawIdentifier)
        }
        return ToolExecutionOutput(
            text: renderEntry(entry),
            rawResult: .object([
                "found": .bool(true),
                "entry": memoryJSONValue(entry)
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

        let stamped = contentWithTimestampIfNeeded(
            content,
            context: context
        )
        let outcome = try await memoryService.writeEntryOutcome(
            content: stamped.content,
            target: context.graphTarget,
            category: parsedCategory(from: arguments),
            tags: parsedTags(from: arguments) ?? [],
            // Only a stamp this call generated may be ignored by the duplicate
            // check; a `Timestamp:` the author supplied is content.
            generatedTimestamp: stamped.generatedTimestamp
        )

        // The store deduplicates against active entries, so "I saved it" is not
        // always true. Reporting a write that did not happen teaches the model
        // that duplicates are accepted; the honest result makes it reuse the id.
        let headline = outcome.created
            ? "Saved memory entry to project memory."
            : "Duplicate of an existing memory entry; nothing was written."

        var text = """
        \(headline)
        \(renderEntry(outcome.entry))
        """
        if !outcome.similar.isEmpty {
            let similarLines = outcome.similar.map { similar in
                "- \(similar.entry.title) (ID: \(similar.entry.id), overlap \(Int((similar.similarity * 100).rounded()))%)"
            }
            text += """

            Similar active entries already exist; if one covers the same fact, consolidate with memory.update and archive the other:
            \(similarLines.joined(separator: "\n"))
            """
        }
        if !outcome.tagHints.isEmpty {
            let hintLines = outcome.tagHints.map { hint in
                let existing = hint.existing.map { "\($0.name) (\($0.count))" }.joined(separator: ", ")
                return "- \(hint.tag) is new; existing related tags: \(existing)"
            }
            text += """

            Tag hints — prefer existing tags so related entries stay linked:
            \(hintLines.joined(separator: "\n"))
            """
        }

        return ToolExecutionOutput(
            text: text,
            rawResult: .object([
                "written": .bool(outcome.created),
                "deduplicated": .bool(outcome.deduplicated),
                "entry": memoryJSONValue(outcome.entry),
                "similar": .array(outcome.similar.map { similar in
                    .object([
                        "id": .string(similar.entry.id.uuidString),
                        "title": .string(similar.entry.title),
                        "similarity": .number(Double(similar.similarity))
                    ])
                }),
                "tagHints": .array(outcome.tagHints.map { hint in
                    .object([
                        "tag": .string(hint.tag),
                        "existing": .array(hint.existing.map { existing in
                            .object([
                                "name": .string(existing.name),
                                "count": .number(Double(existing.count))
                            ])
                        })
                    ])
                })
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
            target: context.graphTarget,
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

        let entry = try await memoryService.setArchived(
            true,
            id: entryID,
            target: context.graphTarget
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

    private static func restore(
        arguments: [String: JSONValue],
        context: MemoryToolContext,
        memoryService: MemoryService
    ) async throws -> ToolExecutionOutput {
        guard let entryID = arguments["id"]?.stringValue?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !entryID.isEmpty else {
            throw MemoryServiceError.missingField("id")
        }

        let entry = try await memoryService.setArchived(
            false,
            id: entryID,
            target: context.graphTarget
        )

        return ToolExecutionOutput(
            text: """
            Restored memory entry.
            \(renderEntry(entry))
            """,
            rawResult: .object([
                "restored": .bool(true),
                "entry": memoryJSONValue(entry)
            ])
        )
    }
}
