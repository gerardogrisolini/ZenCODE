//
//  MemoryEntry.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//
//  ZenCODE no longer declares its own `MemoryEntry` / `MemoryScope` types.
//  The durable store is the vendored ZenMemory graph, so `ZenMemory`'s
//  `MemoryEntry` is the single entry model. This file adds only the
//  journal-shaped conveniences ZenCODE's presentation and tool layers need.
//
//  Note: the engine type could not be referred to as `ZenMemory.MemoryEntry`,
//  because the module name is shadowed by the `ZenMemory` actor. Keeping one
//  entry type is therefore also the only collision-free option.
//

import Foundation
import ZenMemory

/// Content normalization shared by the journal parser, the tools and the store.
public enum MemoryContent {
    public static func normalized(_ content: String) -> String {
        let normalizedLineEndings = content
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalizedLineEndings
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(
                of: #"[ \t]+"#,
                with: " ",
                options: .regularExpression
            )
    }
}

extension MemoryEntry {
    public static func normalizedContent(_ content: String) -> String {
        MemoryContent.normalized(content)
    }

    /// ZenCODE archives entries by deactivating the graph node; the engine has
    /// no separate archive flag.
    public var isArchived: Bool {
        !active
    }

    public var title: String {
        let firstLine = metadata.summary
            ?? content
                .components(separatedBy: .newlines)
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "Memory"
        guard firstLine.count > 80 else {
            return firstLine.isEmpty ? "Memory" : firstLine
        }
        return String(firstLine.prefix(77)).trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
