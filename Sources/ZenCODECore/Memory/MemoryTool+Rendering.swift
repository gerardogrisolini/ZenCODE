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

    static func renderEntry(_ entry: MemoryEntry) -> String {
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
