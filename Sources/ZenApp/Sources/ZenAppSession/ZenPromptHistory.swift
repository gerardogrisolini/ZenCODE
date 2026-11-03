//
//  ZenPromptHistory.swift
//  ZenApp
//
//  The in-memory history of the lines a window submitted, navigated like the
//  terminal's ↑/↓.
//

import Foundation

/// The lines a window submitted, oldest first, and the position of a recall
/// in progress. Kept in memory for the life of the window.
public struct ZenPromptHistory: Equatable, Sendable {
    /// The submitted lines, oldest first, without two equal lines in a row.
    public private(set) var entries: [String]
    /// The entry the recall shows, `nil` while no recall is in progress.
    public private(set) var index: Int?
    /// The draft before the recall started, given back past the newest entry.
    private var draftBeforeRecall = ""
    /// The text the recall put in the draft: a draft that differs was edited,
    /// which ends the recall.
    private var recalledText: String?

    public init(entries: [String] = []) {
        self.entries = entries
    }

    /// Records a submitted line, trimmed; a blank line or a repeat of the
    /// newest entry is not recorded. Ends any recall in progress.
    public mutating func record(_ line: String) {
        endRecall()
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, entries.last != trimmed else { return }
        entries.append(trimmed)
    }

    /// The entry before the one shown (the newest one when no recall is in
    /// progress, remembering `draft`), or `nil` when there is nothing older.
    public mutating func recallPrevious(currentDraft draft: String) -> String? {
        guard !entries.isEmpty else { return nil }
        if index != nil, draft != recalledText {
            endRecall()
        }
        let target: Int
        if let index {
            guard index > 0 else { return nil }
            target = index - 1
        } else {
            draftBeforeRecall = draft
            target = entries.count - 1
        }
        index = target
        recalledText = entries[target]
        return entries[target]
    }

    /// The entry after the one shown, or the draft from before the recall
    /// past the newest one; `nil` when no recall is in progress (or the
    /// recalled text was edited, which ends it).
    public mutating func recallNext(currentDraft draft: String) -> String? {
        guard let index else { return nil }
        guard draft == recalledText else {
            endRecall()
            return nil
        }
        let next = index + 1
        if next < entries.count {
            self.index = next
            recalledText = entries[next]
            return entries[next]
        }
        let restored = draftBeforeRecall
        endRecall()
        return restored
    }

    private mutating func endRecall() {
        index = nil
        recalledText = nil
        draftBeforeRecall = ""
    }
}
