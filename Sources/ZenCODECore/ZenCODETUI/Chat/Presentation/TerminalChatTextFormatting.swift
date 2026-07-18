//
//  TerminalChatTextFormatting.swift
//  ZenCODE
//

import Foundation

/// Stateless text-formatting helpers used by ``TerminalChatRenderCoordinator``.
enum TerminalChatTextFormatting {
    /// Cursor-adjacent spacing state for one physical output stream.
    ///
    /// A trailing carriage return is tracked so a `\n` delivered by the next
    /// streaming delta can complete a single CRLF line boundary instead of
    /// becoming a second boundary.
    struct ChatSpacingState: Sendable {
        var trailingNewlineCount: Int
        var hasTrailingCarriageReturn = false
        var newlineCountBeforeTrailingCarriageReturn = 0

        init(trailingNewlineCount: Int = 0) {
            self.trailingNewlineCount = trailingNewlineCount
        }
    }

    /// Tracks whether a prefix belongs before the next visible character.
    /// CR is tracked until its successor is known so only CRLF is considered a
    /// line boundary; a lone carriage return keeps its cursor-control meaning.
    struct ChatLineInsetState: Sendable {
        var isAtLineStart: Bool
        var hasTrailingCarriageReturn = false

        init(isAtLineStart: Bool = true) {
            self.isAtLineStart = isAtLineStart
        }
    }

    /// Inserts a paragraph break before an inline bold span (`**`) that is glued
    /// to the end of a sentence (e.g. `…done.**Next section**`). Streaming-safe:
    /// the `.`/`!`/`?` and the two `*` may arrive in separate deltas, so a single
    /// pending `*` is held back until the next delta confirms the `**` opener.
    static func normalizedBoldSectionBreak(
        _ delta: String,
        state: inout TerminalChatBoldBreakState
    ) -> String {
        var output = ""

        func appendCharacter(_ character: Character) {
            output.append(character)
            state.previousCharacter = character
        }

        for character in delta {
            if state.pendingAsterisk {
                state.pendingAsterisk = false
                if character == "*" {
                    // Confirmed `**`. Break only before an opener glued to a
                    // sentence end or directly to a previous closing `**`
                    // (back-to-back bold section titles).
                    let isOpener = !state.isBoldSpanOpen
                    if isOpener,
                       let previous = state.previousCharacter,
                       previous == "." || previous == "!" || previous == "?" || previous == "*" {
                        output.append("\n")
                    }
                    state.isBoldSpanOpen.toggle()
                    output.append("**")
                    state.previousCharacter = "*"
                    continue
                }
                // The earlier `*` was not part of a `**`; emit it as content.
                appendCharacter("*")
                // Fall through to process the current character below.
            }

            if character == "*" {
                state.pendingAsterisk = true
                continue
            }

            appendCharacter(character)
        }

        return output
    }

    /// Emits any single `*` held back across delta boundaries and resets state.
    static func flushBoldSectionBreak(state: inout TerminalChatBoldBreakState) -> String {
        let flushed = state.pendingAsterisk ? "*" : ""
        state = TerminalChatBoldBreakState()
        return flushed
    }

    static func removingLeadingLineBreaks(_ text: String) -> String {
        guard let firstContentIndex = text.firstIndex(where: { character in
            !character.unicodeScalars.allSatisfy(CharacterSet.newlines.contains)
        }) else {
            return ""
        }
        return String(text[firstContentIndex...])
    }

    static func chatSpacingNormalized(
        _ text: String,
        trailingNewlineCount: inout Int
    ) -> String {
        var state = ChatSpacingState(
            trailingNewlineCount: trailingNewlineCount
        )
        let normalized = chatSpacingNormalized(text, state: &state)
        trailingNewlineCount = state.trailingNewlineCount
        return normalized
    }

    static func chatSpacingNormalized(
        _ text: String,
        state: inout ChatSpacingState
    ) -> String {
        guard !text.isEmpty else {
            return text
        }

        var output = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]

            if state.hasTrailingCarriageReturn {
                state.hasTrailingCarriageReturn = false
                if character == "\n" {
                    if state.newlineCountBeforeTrailingCarriageReturn < 2 {
                        output.append(character)
                        state.trailingNewlineCount =
                            state.newlineCountBeforeTrailingCarriageReturn + 1
                    } else {
                        state.trailingNewlineCount = 2
                    }
                    index = text.index(after: index)
                    continue
                }
                // The previous CR was a standalone cursor movement, not a
                // CRLF boundary. Preserve the prior behavior: visible content
                // after it starts a fresh spacing run.
                state.trailingNewlineCount = 0
            }

            // Swift represents an in-buffer CRLF as one extended grapheme
            // cluster. Keep the split-delta path above for a CR followed by
            // an LF in a later call, while treating this cluster as one
            // physical line boundary.
            if character == "\r\n" {
                if state.trailingNewlineCount < 2 {
                    output.append(character)
                    state.trailingNewlineCount += 1
                }
                index = text.index(after: index)
                continue
            }

            if character == "\r" {
                let nextIndex = text.index(after: index)
                if nextIndex < text.endIndex, text[nextIndex] == "\n" {
                    if state.trailingNewlineCount < 2 {
                        output.append("\r")
                        output.append("\n")
                        state.trailingNewlineCount += 1
                    }
                    index = text.index(after: nextIndex)
                    continue
                }

                // Preserve a lone CR immediately. If the following delta
                // starts with LF, the LF is accounted for as the completion of
                // this same line boundary rather than a second one.
                output.append(character)
                state.hasTrailingCarriageReturn = true
                state.newlineCountBeforeTrailingCarriageReturn =
                    state.trailingNewlineCount
                index = nextIndex
                continue
            }

            if character == "\n" {
                if state.trailingNewlineCount < 2 {
                    output.append(character)
                    state.trailingNewlineCount += 1
                }
            } else {
                output.append(character)
                state.trailingNewlineCount = 0
            }
            index = text.index(after: index)
        }
        return output
    }

    static func updateTrailingNewlineCount(
        afterPreserving text: String,
        trailingNewlineCount: inout Int
    ) {
        var state = ChatSpacingState(
            trailingNewlineCount: trailingNewlineCount
        )
        updateChatSpacingState(afterPreserving: text, state: &state)
        trailingNewlineCount = state.trailingNewlineCount
    }

    static func updateChatSpacingState(
        afterPreserving text: String,
        state: inout ChatSpacingState
    ) {
        guard !text.isEmpty else {
            return
        }

        let visibleText = TerminalANSIText.stripANSI(text)
        guard !visibleText.isEmpty else {
            return
        }
        _ = chatSpacingNormalized(visibleText, state: &state)
    }

    static func chatLineInsetApplied(
        to text: String,
        prefix: String,
        isAtLineStart: inout Bool
    ) -> String {
        var state = ChatLineInsetState(isAtLineStart: isAtLineStart)
        let rendered = chatLineInsetApplied(to: text, prefix: prefix, state: &state)
        isAtLineStart = state.isAtLineStart
        return rendered
    }

    static func chatLineInsetApplied(
        to text: String,
        prefix: String,
        state: inout ChatLineInsetState
    ) -> String {
        guard !text.isEmpty else {
            return text
        }

        var output = ""
        for character in text {
            if state.hasTrailingCarriageReturn {
                state.hasTrailingCarriageReturn = false
                if character == "\n" {
                    output.append(character)
                    state.isAtLineStart = true
                    continue
                }
            }

            // As in spacing normalization, an in-buffer CRLF is one Swift
            // Character; recognize it before the individual CR/LF cases.
            if character == "\r\n" {
                output.append(character)
                state.isAtLineStart = true
                continue
            }

            if character == "\r" {
                output.append(character)
                state.hasTrailingCarriageReturn = true
                continue
            }
            if character == "\n" {
                output.append(character)
                state.isAtLineStart = true
                continue
            }
            if state.isAtLineStart {
                if !prefix.isEmpty {
                    output += prefix
                }
                state.isAtLineStart = false
            }
            output.append(character)
        }
        return output
    }

    static func updateChatLineInsetState(
        after text: String,
        state: inout ChatLineInsetState
    ) {
        _ = chatLineInsetApplied(to: text, prefix: "", state: &state)
    }

    static let chatLineInsetPrefix = " "

    static func systemMessageColorApplied(to text: String, isEnabled: Bool) -> String {
        guard isEnabled, !text.isEmpty else {
            return text
        }

        let color = systemMessageANSIColor
        let reset = "\u{1B}[0m"
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "" : "\(color)\(line)\(reset)"
            }
            .joined(separator: "\n")
    }

    static let systemMessageANSIColor = "\u{1B}[38;5;110m"

    static func fileChangeSummaryColorApplied(to text: String, isEnabled: Bool) -> String {
        guard isEnabled, !text.isEmpty else {
            return text
        }

        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                fileChangeSummaryLineColorApplied(String(line))
            }
            .joined(separator: "\n")
    }

    static func fileChangeSummaryLineColorApplied(_ line: String) -> String {
        guard !line.isEmpty else {
            return ""
        }

        if line.hasPrefix("Summary:") {
            return colorFileChangeSummaryHeader(line)
        }
        if line.hasPrefix("  ") {
            return colorFileChangeSummaryEntry(line)
        }
        return colorFileChangeSummaryHint(line)
    }

    // Compiled once: these headers/entries are colored per line of the
    // file-change summary, so recompiling the pattern each call is wasteful.
    private static let fileChangeSummaryHeaderRegex = try? NSRegularExpression(
        pattern: #"^(Summary:) (.+)  (\+\d+) ([-]\d+)$"#
    )
    private static let fileChangeSummaryEntryRegex = try? NSRegularExpression(
        pattern: #"^  (\S+) (.+?)(?:  (\+\d+) ([-]\d+)| (\(binary\)))$"#
    )

    static func colorFileChangeSummaryHeader(_ line: String) -> String {
        let reset = "\u{1B}[0m"
        let color = fileChangeSummaryHeaderANSIColor
        let count = "\u{1B}[38;5;81m"
        let white = "\u{1B}[97m"
        let addition = "\u{1B}[38;5;114m"
        let deletion = "\u{1B}[38;5;203m"
        guard let regex = fileChangeSummaryHeaderRegex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 5,
              let titleRange = Range(match.range(at: 1), in: line),
              let countRange = Range(match.range(at: 2), in: line),
              let additionsRange = Range(match.range(at: 3), in: line),
              let deletionsRange = Range(match.range(at: 4), in: line) else {
            return "\(color)\(line)\(reset)"
        }

        return "\(color)\(line[titleRange])\(reset) "
            + "\(coloredFileCount(String(line[countRange]), count: count, white: white, reset: reset))  "
            + "\(addition)\(line[additionsRange])\(reset) "
            + "\(deletion)\(line[deletionsRange])\(reset)"
    }

    /// Colors the file-count fragment so the leading number keeps the azure
    /// accent while the descriptive text (e.g. "modified file") stays white.
    static func coloredFileCount(
        _ text: String,
        count: String,
        white: String,
        reset: String
    ) -> String {
        let digits = text.prefix { $0.isNumber }
        guard !digits.isEmpty else {
            return "\(white)\(text)\(reset)"
        }
        let remainder = text[digits.endIndex...]
        return "\(count)\(digits)\(reset)\(white)\(remainder)\(reset)"
    }

    static func colorFileChangeSummaryEntry(_ line: String) -> String {
        let reset = "\u{1B}[0m"
        let status = "\u{1B}[38;5;244m"
        let path = "\u{1B}[97m"
        let addition = "\u{1B}[38;5;114m"
        let deletion = "\u{1B}[38;5;203m"
        let binary = "\u{1B}[38;5;244m"
        guard let regex = fileChangeSummaryEntryRegex,
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              match.numberOfRanges == 6,
              let statusRange = Range(match.range(at: 1), in: line),
              let pathRange = Range(match.range(at: 2), in: line) else {
            return "\(path)\(line)\(reset)"
        }

        var rendered = "  \(status)\(line[statusRange])\(reset) \(path)\(line[pathRange])\(reset)"
        if let additionsRange = Range(match.range(at: 3), in: line),
           let deletionsRange = Range(match.range(at: 4), in: line) {
            rendered += "  \(addition)\(line[additionsRange])\(reset) \(deletion)\(line[deletionsRange])\(reset)"
        } else if let binaryRange = Range(match.range(at: 5), in: line) {
            rendered += " \(binary)\(line[binaryRange])\(reset)"
        }
        return rendered
    }

    static func colorFileChangeSummaryHint(_ line: String) -> String {
        let reset = "\u{1B}[0m"
        let dim = "\u{1B}[38;5;250m"
        let count = "\u{1B}[38;5;81m"
        var rendered = "\(dim)\(line)\(reset)"
        for token in ["/undo", "/changes diff"] {
            rendered = rendered.replacingOccurrences(
                of: token,
                with: "\(count)\(token)\(reset)\(dim)"
            )
        }
        return rendered
    }

    static let fileChangeSummaryHeaderANSIColor = "\u{1B}[1;97m"

    static func failureMessageColorApplied(to text: String, isEnabled: Bool) -> String {
        guard isEnabled, !text.isEmpty else {
            return text
        }

        let color = failureMessageANSIColor
        let reset = "\u{1B}[0m"
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                line.isEmpty ? "" : "\(color)\(line)\(reset)"
            }
            .joined(separator: "\n")
    }

    static let failureMessageANSIColor = "\u{1B}[38;5;203m"

    static func operationalMessageColorApplied(to text: String, isEnabled: Bool) -> String {
        guard isEnabled, !text.isEmpty else {
            return text
        }

        return "\u{1B}[38;5;75m\(text)\u{1B}[0m"
    }

    static func renderThoughtMarkdown(
        _ renderedMarkdown: String,
        standardErrorIsTerminal: Bool = AgentOutput.standardErrorIsTerminal
    ) -> String {
        guard standardErrorIsTerminal,
              !renderedMarkdown.isEmpty else {
            return renderedMarkdown
        }

        let gray = "\u{1B}[90m"
        let reset = "\u{1B}[0m"
        var output = gray
        var cursor = renderedMarkdown.startIndex

        while cursor < renderedMarkdown.endIndex {
            guard renderedMarkdown[cursor] == "\u{1B}",
                  renderedMarkdown.index(after: cursor) < renderedMarkdown.endIndex,
                  renderedMarkdown[renderedMarkdown.index(after: cursor)] == "[" else {
                output.append(renderedMarkdown[cursor])
                cursor = renderedMarkdown.index(after: cursor)
                continue
            }

            guard let sequenceEnd = renderedMarkdown[cursor...].firstIndex(of: "m") else {
                output.append(renderedMarkdown[cursor])
                cursor = renderedMarkdown.index(after: cursor)
                continue
            }

            let sequence = String(renderedMarkdown[cursor...sequenceEnd])
            output += dimmedANSISequence(sequence, gray: gray, reset: reset)
            cursor = renderedMarkdown.index(after: sequenceEnd)
        }

        output += reset
        return output
    }

    static func dimmedANSISequence(
        _ sequence: String,
        gray: String,
        reset: String
    ) -> String {
        guard sequence.hasPrefix("\u{1B}["),
              sequence.hasSuffix("m") else {
            return sequence
        }

        let rawCodes = sequence
            .dropFirst(2)
            .dropLast()
            .split(separator: ";")
            .compactMap { Int(String($0)) }
        guard !rawCodes.isEmpty else {
            return gray
        }

        if rawCodes.contains(0) {
            return reset + gray
        }

        var preservedCodes: [Int] = []
        var mutedAccent: Int?
        var index = 0
        while index < rawCodes.count {
            let code = rawCodes[index]
            if code == 38,
               index + 2 < rawCodes.count,
               rawCodes[index + 1] == 5 {
                // Map renderer accent colors to a muted palette so headings,
                // inline code, and links stay distinguishable inside the dimmed
                // thinking stream instead of collapsing to flat gray.
                mutedAccent = mutedThoughtAccent(for: rawCodes[index + 2])
                index += 3
                continue
            }
            if code == 39 || (30...37).contains(code) || (90...97).contains(code) {
                index += 1
                continue
            }
            if [1, 2, 3, 4, 9].contains(code) {
                preservedCodes.append(code)
            }
            index += 1
        }

        if let mutedAccent {
            preservedCodes.append(contentsOf: [38, 5, mutedAccent])
        } else {
            preservedCodes.append(90)
        }
        let renderedCodes = preservedCodes
            .map(String.init)
            .joined(separator: ";")
        return "\u{1B}[\(renderedCodes)m"
    }

    /// Returns a desaturated 256-color index for a renderer accent so that
    /// emphasis survives the thinking dim pass without overpowering the muted
    /// gray body text. Returns nil for colors that should fall back to gray.
    static func mutedThoughtAccent(for color: Int) -> Int? {
        switch color {
        case 81, 75, 111, 110, 109, 117:
            // Heading / link / type accents -> muted steel-teal.
            return 109
        case 180, 222, 144:
            // Inline code -> muted tan.
            return 144
        case 108:
            // Blockquote bar -> muted sage.
            return 108
        default:
            return nil
        }
    }
}
