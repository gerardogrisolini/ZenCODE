//
//  MemoryEntryFilter.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 19/10/26.
//
//  Optional narrowing of a read or search over durable project memory.
//

import Foundation

/// Narrows `memory.read` / `memory.search` results by tags and category.
///
/// Tags are matched case-insensitively and all listed tags must be present on
/// an entry (an empty list matches everything); `category` must match exactly
/// when set.
public nonisolated struct MemoryEntryFilter: Sendable, Equatable {
    public var tags: [String]
    public var category: MemoryCategory?

    public init(tags: [String] = [], category: MemoryCategory? = nil) {
        self.tags = tags
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        self.category = category
    }

    public static let none = MemoryEntryFilter()

    public var isEmpty: Bool {
        tags.isEmpty && category == nil
    }

    public func matches(_ entry: MemoryEntry) -> Bool {
        matches(tags: entry.tags, category: entry.category)
    }

    func matches(tags entryTags: [String], category entryCategory: MemoryCategory) -> Bool {
        if let category, category != entryCategory {
            return false
        }
        guard !tags.isEmpty else { return true }
        let lowered = Set(entryTags.map { $0.lowercased() })
        return tags.allSatisfy { lowered.contains($0) }
    }
}

extension MemoryEntryFilter {
    /// Engine-side evaluation, without converting the node to the public DTO.
    func matches(_ entry: GraphEntry) -> Bool {
        matches(
            tags: entry.tags,
            category: MemoryCategory(rawValue: entry.category.rawValue) ?? .fact
        )
    }
}
