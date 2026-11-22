//
//  MemoryTool+Rendering.swift
//  ZenCODE
//
//  Text and JSON rendering of memory entries for tool results.
//

import Foundation
import ToolCore

extension MemoryTool {
    static func renderEntries(
        _ entries: [MemoryEntry],
        detail: RenderDetail,
        workspaceRoot: URL? = nil,
        showsAuthor: Bool = false
    ) -> String {
        guard !entries.isEmpty else {
            return "No memory entries matched."
        }

        let renderedEntries = entries.enumerated().map { index, entry in
            let renderedEntry = detail == .index
                ? renderIndexEntry(entry)
                : renderEntry(entry, workspaceRoot: workspaceRoot, showsAuthor: showsAuthor)
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

    /// The workspace root whose checkout the cited paths of a rendered entry are
    /// verified against: only for `detail == .full` (the index shows titles, not
    /// content) and only for a workspace graph (the global graph is not tied to
    /// a checkout). `nil` renders no stale-path note.
    static func citedPathsRoot(
        for context: MemoryToolContext,
        detail: RenderDetail
    ) -> URL? {
        guard detail == .full,
              case let .workspace(root)? = context.graphTarget else {
            return nil
        }
        return root
    }

    /// Renders one entry as `[scope] content`, then, when `workspaceRoot` is set
    /// and the content cites paths missing from that checkout, the neutral note
    /// of ``MemoryCitedPaths`` on its own line, then `ID:` and the remaining
    /// metadata. The note sits right after the content it qualifies and before
    /// the `ID:` line, which stays the first line of the metadata. Callers that
    /// pass no root (write, update, archive, restore) render exactly as before.
    /// `showsAuthor` (get, and the full read and search) adds `Author:` after
    /// the tags for an entry that records one.
    static func renderEntry(
        _ entry: MemoryEntry,
        workspaceRoot: URL? = nil,
        showsAuthor: Bool = false
    ) -> String {
        var lines = ["[\(entry.scope.rawValue)] \(entry.content)"]
        if let workspaceRoot,
           let note = MemoryCitedPaths.note(
               forMissing: MemoryCitedPaths.missing(
                   in: entry.content,
                   workspaceRoot: workspaceRoot
               )
           ) {
            lines.append(note)
        }
        lines.append("ID: \(entry.id)")
        if !entry.tags.isEmpty {
            lines.append("Tags: \(entry.tags.joined(separator: ", "))")
        }
        if showsAuthor, let author = entry.author?.nilIfBlank {
            lines.append("Author: \(author)")
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

    static func memoryJSONValue(_ entry: MemoryEntry) -> JSONValue {
        memoryJSONValue(entry, detail: .full)
    }

    static func memoryJSONValue(
        _ entry: MemoryEntry,
        detail: RenderDetail
    ) -> JSONValue {
        var result: [String: JSONValue] = [
            "id": .string(entry.id.uuidString),
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
        if let author = entry.author?.nilIfBlank {
            result["author"] = .string(author)
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
