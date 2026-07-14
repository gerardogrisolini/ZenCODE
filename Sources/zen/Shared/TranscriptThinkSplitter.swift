//
//  TranscriptThinkSplitter.swift
//  ZenCODE
//

import Foundation

/// Streaming splitter that separates assistant "thinking" spans (delimited by
/// `<think>…</think>` or `<|channel>thought…<channel|>`) from visible content.
///
/// Shared by the local MLX and DS4 backends: both models emit the same reasoning
/// tags, so the parsing state machine lives here once. The `visibleText`,
/// `historyVisibleText`, and `reasoningText` accumulators are populated during
/// streaming so callers that need them (MLX) avoid re-parsing the raw transcript
/// at end of turn; callers that don't (DS4) simply ignore them — they never
/// affect the emitted `Part` sequence.
struct TranscriptThinkSplitter {
    enum Part: Equatable {
        case content(String)
        case thought(String)
    }

    static let openTags = ["<think>", "<|channel>thought"]
    static let closeTags = ["</think>", "<channel|>"]

    private var isThinking: Bool
    private var pending = ""

    /// When set, leading newlines are stripped from the next visible-content
    /// chunk emitted after a thinking→content boundary. The model typically
    /// emits blank lines immediately after `</think>`; without this the TUI
    /// shows 3–4 blank lines instead of one.
    private var suppressLeadingNewlinesInNextContent = false

    // Accumulators built during streaming — avoids re-parsing rawText at end of turn.
    private(set) var visibleText = ""
    private(set) var historyVisibleText = ""
    private(set) var reasoningText = ""
    private var historyVisibleStarted: Bool

    init(startsInThinking: Bool) {
        self.isThinking = startsInThinking
        self.historyVisibleStarted = !startsInThinking
    }

    mutating func consume(_ chunk: String) -> [Part] {
        pending += chunk
        var parts: [Part] = []

        while !pending.isEmpty {
            if isThinking {
                let closeRange = pending.earliestRange(ofAny: Self.closeTags)
                let openRange = pending.earliestRange(ofAny: Self.openTags)

                if let openRange,
                   closeRange == nil || openRange.lowerBound < closeRange!.lowerBound {
                    let thought = String(pending[..<openRange.lowerBound])
                    if !thought.isEmpty {
                        parts.append(.thought(thought))
                        appendReasoning(thought)
                    }
                    pending.removeSubrange(pending.startIndex..<openRange.upperBound)
                    continue
                }

                if let closeRange {
                    let thought = String(pending[..<closeRange.lowerBound])
                    if !thought.isEmpty {
                        parts.append(.thought(thought))
                        appendReasoning(thought)
                    }
                    pending.removeSubrange(pending.startIndex..<closeRange.upperBound)
                    isThinking = false
                    historyVisibleStarted = true
                    suppressLeadingNewlinesInNextContent = true
                    continue
                }

                let safePrefix = pending.removingSuffixThatCanStartAny(
                    Self.closeTags + Self.openTags
                )
                guard !safePrefix.isEmpty else {
                    break
                }
                parts.append(.thought(safePrefix))
                appendReasoning(safePrefix)
                pending.removeFirst(safePrefix.count)
            } else {
                // Detect and remove stray close tags (e.g. `</think>`) that
                // leak into visible content — models occasionally emit them
                // outside a thinking span, and they should never appear on
                // screen. Only strip a close tag that appears before any open
                // tag so a well-formed `<think>…</think>` span is unaffected.
                let openRange = pending.earliestRange(ofAny: Self.openTags)
                let strayCloseRange = pending.earliestRange(ofAny: Self.closeTags)
                if let strayCloseRange,
                   openRange == nil || strayCloseRange.lowerBound < openRange!.lowerBound {
                    emitContent(
                        String(pending[..<strayCloseRange.lowerBound]),
                        into: &parts
                    )
                    pending.removeSubrange(pending.startIndex..<strayCloseRange.upperBound)
                    suppressLeadingNewlinesInNextContent = true
                    continue
                }

                if let openRange {
                    emitContent(
                        String(pending[..<openRange.lowerBound]),
                        into: &parts
                    )
                    pending.removeSubrange(pending.startIndex..<openRange.upperBound)
                    isThinking = true
                    continue
                }

                let safePrefix = pending.removingSuffixThatCanStartAny(
                    Self.openTags + Self.closeTags
                )
                guard !safePrefix.isEmpty else {
                    break
                }
                emitContent(safePrefix, into: &parts)
                pending.removeFirst(safePrefix.count)
            }
        }

        return parts
    }

    mutating func finish() -> [Part] {
        guard !pending.isEmpty else {
            return []
        }
        let value = pending
        pending = ""
        if isThinking {
            appendReasoning(value)
            return [.thought(value)]
        }
        var parts: [Part] = []
        emitContent(value, into: &parts)
        return parts
    }

    // MARK: - Accumulation

    /// Emits a visible-content chunk, stripping leading newlines when the
    /// splitter just crossed a thinking→content boundary. The suppression
    /// flag persists across chunks that contain only newlines so that blank
    /// lines split across stream boundaries are fully consumed.
    private mutating func emitContent(_ text: String, into parts: inout [Part]) {
        let content: String
        if suppressLeadingNewlinesInNextContent {
            let stripped = text.drop(while: \.isNewline)
            content = String(stripped)
            // Keep suppressing until non-newline content is actually emitted.
            suppressLeadingNewlinesInNextContent = content.isEmpty && !text.isEmpty
        } else {
            content = text
        }
        guard !content.isEmpty else {
            return
        }
        parts.append(.content(content))
        appendContent(content)
    }

    private mutating func appendContent(_ text: String) {
        visibleText.append(text)
        if historyVisibleStarted {
            historyVisibleText.append(text)
        }
    }

    private mutating func appendReasoning(_ text: String) {
        reasoningText.append(text)
    }
}

extension String {
    /// Drops a trailing partial run that could be the start of `marker`, so an
    /// incomplete tag straddling a stream boundary is not emitted prematurely.
    func removingSuffixThatCanStart(_ marker: String) -> String {
        var suffixLength = min(count, max(marker.count - 1, 0))
        while suffixLength > 0 {
            let suffix = String(suffix(suffixLength))
            if marker.hasPrefix(suffix) {
                return String(dropLast(suffixLength))
            }
            suffixLength -= 1
        }
        return self
    }

    func earliestRange(ofAny markers: [String]) -> Range<String.Index>? {
        markers
            .compactMap { range(of: $0) }
            .min { $0.lowerBound < $1.lowerBound }
    }

    func removingSuffixThatCanStartAny(_ markers: [String]) -> String {
        var shortest = self
        for marker in markers {
            let trimmed = removingSuffixThatCanStart(marker)
            if trimmed.count < shortest.count {
                shortest = trimmed
            }
        }
        return shortest
    }
}
