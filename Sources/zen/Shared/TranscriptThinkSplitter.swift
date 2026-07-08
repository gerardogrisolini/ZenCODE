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
                if let openRange = pending.earliestRange(ofAny: Self.openTags) {
                    let content = String(pending[..<openRange.lowerBound])
                    if !content.isEmpty {
                        parts.append(.content(content))
                        appendContent(content)
                    }
                    pending.removeSubrange(pending.startIndex..<openRange.upperBound)
                    isThinking = true
                    continue
                }

                let safePrefix = pending.removingSuffixThatCanStartAny(Self.openTags)
                guard !safePrefix.isEmpty else {
                    break
                }
                parts.append(.content(safePrefix))
                appendContent(safePrefix)
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
        let part: Part = isThinking ? .thought(value) : .content(value)
        switch part {
        case .content(let text):
            appendContent(text)
        case .thought(let text):
            appendReasoning(text)
        }
        return [part]
    }

    // MARK: - Accumulation

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
