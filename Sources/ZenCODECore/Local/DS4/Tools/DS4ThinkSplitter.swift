//
//  DS4ThinkSplitter.swift
//  ZenCODE
//
//  Streaming splitter that separates reasoning spans (`<think>…</think>`) from
//  visible content. Ported from TranscriptThinkSplitter (abd128942,
//  Sources/zen/Shared/TranscriptThinkSplitter.swift) and adapted for DS4:
//  - it works on UTF-8 bytes, like ds4-agent's agent_stream_text, so a tag is
//    matched byte-exactly and never merged into a grapheme cluster;
//  - the tags are configurable (DS4 models use `<think>`/`</think>` only, the
//    `<|channel>thought`/`<channel|>` pair of the original is opt-in);
//  - after a closing tag it drops leading ASCII whitespace (space, tab, CR,
//    LF), like ds4-agent's post-think gap, instead of newlines only;
//  - a byte-level event API reports consumed tags so DS4GeneratedOutputParser
//    can stop feeding it once a tool-call block owns the stream.
//

import Foundation

struct DS4ThinkSplitter: Sendable {
    enum Part: Equatable, Sendable {
        case content(String)
        case thought(String)
    }

    /// Byte-level output: text routed to a channel, or a consumed tag.
    enum Event: Equatable, Sendable {
        case text(thought: Bool, bytes: [UInt8])
        case tag(bytes: [UInt8], opensThinking: Bool)
    }

    static let defaultOpenTags = ["<think>"]
    static let defaultCloseTags = ["</think>"]

    private let openTags: [[UInt8]]
    private let closeTags: [[UInt8]]
    private let allTags: [[UInt8]]

    private(set) var isThinking: Bool
    private var pending: [UInt8] = []

    /// Set after a thinking→content boundary: leading whitespace of the next
    /// visible content is dropped. The model typically emits blank lines right
    /// after `</think>`. The flag persists across whitespace-only chunks.
    private var suppressLeadingWhitespace = false

    /// Accumulators of the String API (`consume(_:)`/`finish()`).
    private(set) var visibleText = ""
    private(set) var reasoningText = ""

    init(
        startsInThinking: Bool,
        openTags: [String] = Self.defaultOpenTags,
        closeTags: [String] = Self.defaultCloseTags
    ) {
        self.isThinking = startsInThinking
        self.openTags = openTags.map { Array($0.utf8) }.filter { !$0.isEmpty }
        self.closeTags = closeTags.map { Array($0.utf8) }.filter { !$0.isEmpty }
        self.allTags = self.closeTags + self.openTags
    }

    /// Bytes held back because they may start a tag.
    var hasPendingText: Bool {
        !pending.isEmpty
    }

    // MARK: - String API

    mutating func consume(_ chunk: String) -> [Part] {
        parts(from: consumeBytes(chunk.utf8))
    }

    mutating func finish() -> [Part] {
        parts(from: finishBytes())
    }

    private mutating func parts(from events: [Event]) -> [Part] {
        var parts: [Part] = []
        for event in events {
            guard case let .text(thought, bytes) = event else {
                continue
            }
            let text = DS4Bytes.string(bytes)
            if thought {
                reasoningText += text
                if case let .thought(previous) = parts.last {
                    parts[parts.count - 1] = .thought(previous + text)
                } else {
                    parts.append(.thought(text))
                }
            } else {
                visibleText += text
                if case let .content(previous) = parts.last {
                    parts[parts.count - 1] = .content(previous + text)
                } else {
                    parts.append(.content(text))
                }
            }
        }
        return parts
    }

    // MARK: - Byte API

    mutating func consumeBytes(_ bytes: some Sequence<UInt8>) -> [Event] {
        pending.append(contentsOf: bytes)
        var events: [Event] = []

        while !pending.isEmpty {
            if isThinking {
                let close = earliest(closeTags)
                let open = earliest(openTags)
                if let open, close.map({ open.lowerBound < $0.lowerBound }) ?? true {
                    emitThought(0..<open.lowerBound, into: &events)
                    takeTag(open, opensThinking: true, into: &events)
                    continue
                }
                if let close {
                    emitThought(0..<close.lowerBound, into: &events)
                    takeTag(close, opensThinking: false, into: &events)
                    isThinking = false
                    suppressLeadingWhitespace = true
                    continue
                }
                let safe = pending.count - heldSuffixLength()
                guard safe > 0 else {
                    break
                }
                emitThought(0..<safe, into: &events)
                pending.removeFirst(safe)
            } else {
                // Stray close tags (e.g. `</think>`) that leak into visible
                // content are removed. Only a close tag before any open tag is
                // stray, so a well-formed `<think>…</think>` span is unaffected.
                let open = earliest(openTags)
                let strayClose = earliest(closeTags)
                if let strayClose, open.map({ strayClose.lowerBound < $0.lowerBound }) ?? true {
                    emitContent(0..<strayClose.lowerBound, into: &events)
                    takeTag(strayClose, opensThinking: false, into: &events)
                    suppressLeadingWhitespace = true
                    continue
                }
                if let open {
                    emitContent(0..<open.lowerBound, into: &events)
                    takeTag(open, opensThinking: true, into: &events)
                    isThinking = true
                    continue
                }
                let safe = pending.count - heldSuffixLength()
                guard safe > 0 else {
                    break
                }
                emitContent(0..<safe, into: &events)
                pending.removeFirst(safe)
            }
        }
        return events
    }

    /// Releases the held bytes as text of the current span.
    mutating func finishBytes() -> [Event] {
        guard !pending.isEmpty else {
            return []
        }
        var events: [Event] = []
        if isThinking {
            emitThought(0..<pending.count, into: &events)
        } else {
            emitContent(0..<pending.count, into: &events)
        }
        pending.removeAll()
        return events
    }

    // MARK: - Helpers

    private func earliest(_ tags: [[UInt8]]) -> Range<Int>? {
        var best: Range<Int>?
        for tag in tags {
            if let start = DS4Bytes.firstIndex(of: tag, in: pending, from: 0),
               best.map({ start < $0.lowerBound }) ?? true {
                best = start..<(start + tag.count)
            }
        }
        return best
    }

    /// Length of the longest suffix of `pending` that is a proper prefix of a
    /// tag, so an incomplete tag straddling a stream boundary is held back.
    private func heldSuffixLength() -> Int {
        DS4Bytes.longestSuffixStartingAny(pending, markers: allTags)
    }

    private mutating func takeTag(_ range: Range<Int>, opensThinking: Bool, into events: inout [Event]) {
        events.append(.tag(bytes: Array(pending[range]), opensThinking: opensThinking))
        pending.removeFirst(range.upperBound)
    }

    private func emitThought(_ range: Range<Int>, into events: inout [Event]) {
        guard !range.isEmpty else {
            return
        }
        events.append(.text(thought: true, bytes: Array(pending[range])))
    }

    private mutating func emitContent(_ range: Range<Int>, into events: inout [Event]) {
        var lower = range.lowerBound
        if suppressLeadingWhitespace {
            while lower < range.upperBound, DS4Bytes.isWhitespace(pending[lower]) {
                lower += 1
            }
            if lower < range.upperBound {
                suppressLeadingWhitespace = false
            }
        }
        guard lower < range.upperBound else {
            return
        }
        events.append(.text(thought: false, bytes: Array(pending[lower..<range.upperBound])))
    }
}
