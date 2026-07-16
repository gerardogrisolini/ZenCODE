//
//  SessionCheckpointTree.swift
//  ZenCODE
//
//  Session checkpoint tree inspired by Pi's tree-structured sessions.
//  Each entry (message, checkpoint, model change, branch summary) forms a node
//  linked via `parentID`, enabling branching and resumption from any point.
//

import Foundation

// MARK: - SessionCheckpointEntry

/// A single node in the session checkpoint tree.
///
/// Entries form a tree via `parentID`.  The first entry of any branch has
/// `parentID == nil` (or points to an ancestor when branching).  Walking from
/// the active leaf to the root produces the linear message context.
public struct SessionCheckpointEntry: Codable, Equatable, Sendable, Identifiable {
    /// Eight-character hex identifier, unique within a tree.
    public let id: String
    /// Parent entry identifier. `nil` only for the root entry.
    public let parentID: String?
    public let timestamp: Date
    public let kind: Kind

    public init(
        id: String,
        parentID: String?,
        timestamp: Date,
        kind: Kind
    ) {
        self.id = id
        self.parentID = parentID
        self.timestamp = timestamp
        self.kind = kind
    }

    public enum Kind: Codable, Equatable, Sendable {
        /// A conversation message (user, assistant, tool, system).
        case message(AgentRuntimeMessage)
        /// A user-defined bookmark or an auto-generated checkpoint.
        case checkpoint(label: String?)
        /// Summary of an abandoned branch, attached at the branch point.
        case branchSummary(summary: String, fromEntryID: String)
        /// Records a model switch that took effect from this entry onward.
        case modelChange(modelID: String)
    }

    /// Returns the wrapped message when this entry's kind is `.message`.
    public var message: AgentRuntimeMessage? {
        guard case let .message(msg) = kind else { return nil }
        return msg
    }

    /// Whether this entry participates in LLM context building.
    public var participatesInContext: Bool {
        switch kind {
        case .message, .branchSummary:
            return true
        case .checkpoint, .modelChange:
            return false
        }
    }
}

// MARK: - SessionCheckpointTree

/// The full checkpoint tree for a single session.
///
/// Entries are stored in chronological insertion order.  Tree topology is
/// defined entirely by `parentID` links.  The `activeLeafID` marks the current
/// position; walking from it to the root yields the active context.
public struct SessionCheckpointTree: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let sessionID: String
    public private(set) var entries: [SessionCheckpointEntry]
    /// The current position in the tree (deepest node of the active branch).
    public private(set) var activeLeafID: String

    public init(
        version: Int = Self.currentVersion,
        sessionID: String,
        entries: [SessionCheckpointEntry] = [],
        activeLeafID: String
    ) {
        self.version = version
        self.sessionID = sessionID
        self.entries = entries
        self.activeLeafID = activeLeafID
    }

    // MARK: - Lookup

    /// Returns the entry with the given id, or `nil`.
    public func entry(id: String) -> SessionCheckpointEntry? {
        entries.first { $0.id == id }
    }

    /// All entries whose `parentID` equals `entryID`, in insertion order.
    public func children(of entryID: String) -> [SessionCheckpointEntry] {
        entries.filter { $0.parentID == entryID }
    }

    /// Returns `true` when the entry has at least one child.
    public func hasChildren(_ entryID: String) -> Bool {
        entries.contains { $0.parentID == entryID }
    }

    /// The root entry (the first entry with `parentID == nil`).
    public var rootEntry: SessionCheckpointEntry? {
        entries.first { $0.parentID == nil }
    }

    // MARK: - Path walking

    /// Walks from `leafID` (inclusive) toward the root, returning entries in
    /// chronological order (root → leaf).
    public func path(from leafID: String) -> [SessionCheckpointEntry] {
        var reversed: [SessionCheckpointEntry] = []
        var currentID: String? = leafID
        var visited = Set<String>()
        while let id = currentID, !visited.contains(id) {
            visited.insert(id)
            guard let entry = entry(id: id) else { break }
            reversed.append(entry)
            currentID = entry.parentID
        }
        return reversed.reversed()
    }

    /// Convenience: path from the active leaf.
    public var activePath: [SessionCheckpointEntry] {
        path(from: activeLeafID)
    }

    /// Extracts the ordered list of conversation messages from the path
    /// starting at `leafID`.  Non-message entries are skipped, and
    /// `branchSummary` entries are converted into assistant messages.
    public func messages(from leafID: String) -> [AgentRuntimeMessage] {
        path(from: leafID).compactMap { entry -> AgentRuntimeMessage? in
            switch entry.kind {
            case let .message(msg):
                return msg
            case let .branchSummary(summary, _):
                return AgentRuntimeMessage(role: .assistant, content: summary)
            case .checkpoint, .modelChange:
                return nil
            }
        }
    }

    /// Convenience: messages from the active leaf.
    public var activeMessages: [AgentRuntimeMessage] {
        messages(from: activeLeafID)
    }

    // MARK: - Mutating operations

    /// Appends a new entry as a child of the active leaf and advances the leaf.
    @discardableResult
    public mutating func append(_ kind: SessionCheckpointEntry.Kind) -> SessionCheckpointEntry {
        let entry = SessionCheckpointEntry(
            id: Self.generateEntryID(),
            parentID: activeLeafID,
            timestamp: Date(),
            kind: kind
        )
        entries.append(entry)
        activeLeafID = entry.id
        return entry
    }

    /// Creates a new branch starting from `ancestorID`.
    /// The active leaf is moved to the new entry.
    @discardableResult
    public mutating func branch(
        from ancestorID: String,
        kind: SessionCheckpointEntry.Kind
    ) -> SessionCheckpointEntry {
        guard entry(id: ancestorID) != nil else {
            // If the ancestor doesn't exist, fall back to the root.
            return append(kind)
        }
        let entry = SessionCheckpointEntry(
            id: Self.generateEntryID(),
            parentID: ancestorID,
            timestamp: Date(),
            kind: kind
        )
        entries.append(entry)
        activeLeafID = entry.id
        return entry
    }

    /// Attaches a branch summary at `ancestorID` and then moves the active leaf
    /// to that ancestor so a new branch can continue from there.
    @discardableResult
    public mutating func attachBranchSummary(
        at ancestorID: String,
        summary: String,
        fromEntryID: String
    ) -> SessionCheckpointEntry {
        let summaryEntry = SessionCheckpointEntry(
            id: Self.generateEntryID(),
            parentID: ancestorID,
            timestamp: Date(),
            kind: .branchSummary(summary: summary, fromEntryID: fromEntryID)
        )
        entries.append(summaryEntry)
        // The summary entry itself becomes the branching point.
        activeLeafID = summaryEntry.id
        return summaryEntry
    }

    /// Sets the active leaf to an existing entry, enabling navigation.
    public mutating func navigate(to entryID: String) {
        guard entry(id: entryID) != nil else { return }
        activeLeafID = entryID
    }

    // MARK: - History merge and bootstrap

    /// Returns a new tree with `newMessages` appended after the messages
    /// already present on the active-leaf path.  Messages that match the
    /// existing path (compared by role + content prefix) are skipped so the
    /// merge is idempotent across repeated saves.
    public func mergingHistory(_ newMessages: [AgentRuntimeMessage]) -> SessionCheckpointTree {
        let existingMessages = activeMessages
        let matchCount = Self.commonPrefixCount(existingMessages, newMessages)
        guard matchCount < newMessages.count else { return self }
        var updated = self
        for message in newMessages.dropFirst(matchCount) {
            updated.append(.message(message))
        }
        return updated
    }

    private static func commonPrefixCount(
        _ a: [AgentRuntimeMessage],
        _ b: [AgentRuntimeMessage]
    ) -> Int {
        let limit = min(a.count, b.count)
        var i = 0
        while i < limit, a[i].role == b[i].role, a[i].content == b[i].content {
            i += 1
        }
        return i
    }

    // MARK: - Linear history migration

    /// Builds a linear tree from a flat array of messages, creating a linear chain.
    /// Used to bootstrap a checkpoint tree from a current live transcript when
    /// no tree has been persisted yet (e.g. first save, or session start).
    public static func fromLinearHistory(
        _ messages: [AgentRuntimeMessage],
        sessionID: String
    ) -> SessionCheckpointTree {
        guard !messages.isEmpty else {
            let root = SessionCheckpointEntry(
                id: generateEntryID(),
                parentID: nil,
                timestamp: Date(),
                kind: .message(AgentRuntimeMessage(role: .system, content: ""))
            )
            return SessionCheckpointTree(
                sessionID: sessionID,
                entries: [root],
                activeLeafID: root.id
            )
        }
        var entries: [SessionCheckpointEntry] = []
        var parentID: String? = nil
        for message in messages {
            let entry = SessionCheckpointEntry(
                id: generateEntryID(),
                parentID: parentID,
                timestamp: Date(),
                kind: .message(message)
            )
            entries.append(entry)
            parentID = entry.id
        }
        return SessionCheckpointTree(
            sessionID: sessionID,
            entries: entries,
            activeLeafID: parentID ?? entries[0].id
        )
    }

    // MARK: - Tree visualization

    /// A compact indented description of the tree topology for debugging / TUI.
    public func treeDescription(maxDepth: Int = 50) -> String {
        guard let root = rootEntry else { return "(empty tree)" }
        var lines: [String] = []
        appendTreeLines(
            entry: root,
            prefix: "",
            isLastChild: true,
            depth: 0,
            maxDepth: maxDepth,
            into: &lines
        )
        return lines.joined(separator: "\n")
    }

    private func appendTreeLines(
        entry: SessionCheckpointEntry,
        prefix: String,
        isLastChild: Bool,
        depth: Int,
        maxDepth: Int,
        into lines: inout [String]
    ) {
        guard depth <= maxDepth else { return }
        let connector = depth == 0 ? "" : (isLastChild ? "└─ " : "├─ ")
        let marker = entry.id == activeLeafID ? " ← active" : ""
        lines.append("\(prefix)\(connector)\(entry.id) \(entryLabel(entry))\(marker)")
        let kids = children(of: entry.id)
        let childPrefix = depth == 0 ? "" : prefix + (isLastChild ? "   " : "│  ")
        for (index, child) in kids.enumerated() {
            appendTreeLines(
                entry: child,
                prefix: childPrefix,
                isLastChild: index == kids.count - 1,
                depth: depth + 1,
                maxDepth: maxDepth,
                into: &lines
            )
        }
    }

    private func entryLabel(_ entry: SessionCheckpointEntry) -> String {
        switch entry.kind {
        case let .message(msg):
            let preview = msg.content.prefix(60).replacingOccurrences(of: "\n", with: " ")
            return "[\(msg.role.rawValue)] \(preview)"
        case let .checkpoint(label):
            return "[checkpoint] \(label ?? "unnamed")"
        case let .branchSummary(summary, _):
            let preview = summary.prefix(40).replacingOccurrences(of: "\n", with: " ")
            return "[branch-summary] \(preview)…"
        case let .modelChange(modelID):
            return "[model] \(modelID)"
        }
    }

    // MARK: - ID generation

    /// Generates a short, unique eight-character hex identifier.
    public static func generateEntryID() -> String {
        let bytes = (0..<4).map { _ in UInt8.random(in: 0...255) }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - SessionCheckpointBranch

/// Describes a branch (path from root to a leaf) for listing and selection.
public struct SessionCheckpointBranch: Equatable, Sendable {
    public let leafID: String
    public let label: String?
    public let messageCount: Int
    public let lastTimestamp: Date
    public let preview: String

    public init(
        leafID: String,
        label: String?,
        messageCount: Int,
        lastTimestamp: Date,
        preview: String
    ) {
        self.leafID = leafID
        self.label = label
        self.messageCount = messageCount
        self.lastTimestamp = lastTimestamp
        self.preview = preview
    }
}

extension SessionCheckpointTree {
    /// Enumerates all leaf entries (nodes with no children) as branches.
    public var branches: [SessionCheckpointBranch] {
        entries
            .filter { !hasChildren($0.id) }
            .map { leaf in
                let path = self.path(from: leaf.id)
                let messages = path.compactMap(\.message)
                let label = path
                    .compactMap { entry -> String? in
                        if case let .checkpoint(label) = entry.kind { return label }
                        return nil
                    }
                    .last
                let preview = messages
                    .first { $0.role == .user }?
                    .content
                    .prefix(60)
                    .replacingOccurrences(of: "\n", with: " ") ?? "(no user message)"
                return SessionCheckpointBranch(
                    leafID: leaf.id,
                    label: label,
                    messageCount: messages.filter { $0.role != .system }.count,
                    lastTimestamp: leaf.timestamp,
                    preview: preview
                )
            }
    }
}
