//
//  MemoryAuthorScope.swift
//  ZenCODE
//
//  Which entries of a memory graph one agent profile owns.
//

import Foundation

/// The entries of one memory graph that an agent profile sees and may change:
/// the single ownership rule of durable memory.
///
/// Every entry records its author, the `name` of the profile that wrote it
/// (`EngineMemoryEntry.author`), and a profile sees only its own entries. Names
/// are compared without regard to case or surrounding whitespace, so renaming
/// a profile detaches the entries it wrote. A session without a profile reads
/// and writes as ``fallbackAuthor``.
///
/// Entries without an author (written before authors existed) are attributed
/// on read and never rewritten: in a workspace graph they belong to
/// ``fallbackAuthor``; in the global graph they stay visible to every profile
/// that uses it, while what those profiles write carries their name and is
/// private.
///
/// Retrieval runs on the graph restricted by ``MemoryGraph/restricted(to:)``,
/// so its lexical statistics are those of the visible entries; every other
/// read or mutation checks ``allows(_:)``. Both apply the same predicate.
package struct MemoryAuthorScope: Sendable, Equatable {
    /// The author of a session without a profile, and the owner of the
    /// entries without an author in a workspace graph.
    package static let fallbackAuthor = "Developer"

    /// The author stamped on the entries written in this scope: the trimmed
    /// profile name, or ``fallbackAuthor`` without one.
    package let author: String
    /// `author` as compared: lowercased.
    private let key: String
    /// Whether entries without an author belong to this scope.
    private let ownsUnattributedEntries: Bool

    /// The scope of the profile named `profileName` (`nil` or blank: no
    /// profile) in the graph addressed by `graphTarget`.
    package init(profileName: String?, graphTarget: MemoryGraphTarget) {
        let trimmed = profileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let author = trimmed.isEmpty ? Self.fallbackAuthor : trimmed
        self.author = author
        key = author.lowercased()
        switch graphTarget {
        case .workspace:
            ownsUnattributedEntries = key == Self.fallbackAuthor.lowercased()
        case .global:
            ownsUnattributedEntries = true
        }
    }

    /// Whether `entry` belongs to this scope.
    package func allows(_ entry: EngineMemoryEntry) -> Bool {
        guard let entryKey = Self.key(for: entry.author) else {
            return ownsUnattributedEntries
        }
        return entryKey == key
    }

    /// `name` trimmed and lowercased; `nil` when nothing is left, which counts
    /// as no author.
    private static func key(for name: String?) -> String? {
        guard let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }
}

extension MemoryGraph {
    /// This graph with only the entries `scope` allows and the tag counts
    /// recounted over them; `nil` returns the whole graph. Edges that lead to a
    /// removed entry are kept: every traversal checks that its target exists.
    func restricted(to scope: MemoryAuthorScope?) -> MemoryGraph {
        guard let scope else { return self }
        var restricted = self
        restricted.memories = memories.filter { scope.allows($0.value) }
        // A tag counts every entry that carries it, active or not, the way
        // `addMemory` counts it.
        var usage: [String: UInt32] = [:]
        for entry in restricted.memories.values {
            for name in entry.tags {
                usage["tag:\(name)", default: 0] += 1
            }
        }
        restricted.tags = tags.reduce(into: [:]) { result, item in
            guard let count = usage[item.key] else { return }
            var tag = item.value
            tag.count = count
            result[item.key] = tag
        }
        return restricted
    }
}
