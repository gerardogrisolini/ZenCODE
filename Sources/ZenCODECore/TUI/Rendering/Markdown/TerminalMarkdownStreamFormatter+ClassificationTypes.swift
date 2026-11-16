//
//  TerminalMarkdownStreamFormatter+ClassificationTypes.swift
//  ZenCODE
//
//  Value types shared by the line classification of the stream formatter:
//  block kinds, code fences, ordered-list markers and the pending line-start
//  state.
//

import Foundation
import Markdown

extension TerminalMarkdownStreamFormatter {
    /// One policy shared by classification and streamed renumbering. CommonMark
    /// accepts at most nine digits in an ordered-list marker.
    enum OrderedListMarkerPolicy {
        static let maximumDigitCount = 9
        static let maximumValue = 999_999_999
    }

    /// Multi-line markdown constructs that must be parsed as a whole block
    /// rather than one isolated line at a time. Buffering these lets the
    /// renderer handle nested lists, multi-line blockquotes, and GFM tables.
    enum BlockKind {
        case list
        case blockQuote
        case tableCandidate
        case table
    }

    /// The exact marker that opened a fenced code block. CommonMark requires a
    /// matching marker and a closing run at least as long as the opening run;
    /// retaining both prevents an inner shorter run from terminating the block.
    struct CodeFence {
        let marker: Character
        let length: Int
        let language: String?
        var diffState = TerminalCodeBlockRenderer.DiffState()
    }

    struct CodeFenceRun {
        let marker: Character
        let length: Int
        let remainder: String
    }

    /// Shared lexical scan of an ordered-list-like prefix. Callers retain their
    /// distinct policy for an empty body and the CommonMark nine-digit limit.
    struct OrderedListMarkerScan {
        let digits: Substring
        let afterDot: String.Index
        let hasWhitespaceBody: Bool

        var digitCount: Int { digits.count }
    }

    /// Incremental classification of the still-unemitted line start. A line
    /// can only move from an unresolved marker candidate to either a known
    /// block marker or a known-safe prose prefix. Once it is known safe, later
    /// deltas cannot turn that already-observed prefix into a block marker.
    enum PendingLineStartState {
        case leadingWhitespace
        case hashRun(Int)
        case dashRun(Int)
        case plus
        case digitRun(Int)
        case orderedListDot
        case deferredWhitespace
        case ambiguousBlockMarker
        case resolved
    }
}
