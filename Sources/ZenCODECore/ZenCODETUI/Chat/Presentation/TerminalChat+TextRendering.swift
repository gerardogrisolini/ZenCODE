//
//  TerminalChat+TextRendering.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    public func writeDiagnostic(_ message: String) async {
        if message.hasPrefix("Generation done:") {
            if !didReceiveMetricsForCurrentPrompt {
                await writeChatError("\n\n[ZenCODE] \(compactGenerationSummary(message))\n")
            }
            return
        }

        guard !message.hasPrefix("Remote request:") else {
            return
        }

        await writeChatError("\u{1B}[90m[ZenCODE] \(message)\u{1B}[0m\n")
    }

    public func writeThought(_ delta: String) async {
        await renderCoordinator.writeThought(delta)
    }

    public func writeAssistantContent(_ delta: String) async {
        await renderCoordinator.writeAssistantContent(delta)
    }

    public func finishAssistantContentFormatting() async {
        await renderCoordinator.finishAssistantContent()
    }

    public func writeSubmittedPrompt(_ prompt: String) async {
        await renderCoordinator.writeSubmittedPrompt(prompt)
    }

    public func finishThoughtOutputIfNeeded() async {
        await renderCoordinator.finishThoughtOutput()
    }

    func finishStreamingOutput() async {
        await renderCoordinator.finishStreamingOutput()
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

    func writeChatOutput(_ text: String, preservesSpacing: Bool = false) async {
        await renderCoordinator.writeOutput(text, preservesSpacing: preservesSpacing)
    }

    func flushChatOutput() async {
        await renderCoordinator.flushOutput()
    }

    func writeChatError(_ text: String, preservesSpacing: Bool = false) async {
        await renderCoordinator.writeError(text, preservesSpacing: preservesSpacing)
    }

    static func chatSpacingNormalized(
        _ text: String,
        trailingNewlineCount: inout Int
    ) -> String {
        guard !text.isEmpty else {
            return text
        }

        var output = ""
        for character in text {
            if character == "\n" {
                guard trailingNewlineCount < 2 else {
                    continue
                }
                output.append(character)
                trailingNewlineCount += 1
                continue
            }

            output.append(character)
            trailingNewlineCount = 0
        }
        return output
    }

    static func updateTrailingNewlineCount(
        afterPreserving text: String,
        trailingNewlineCount: inout Int
    ) {
        guard !text.isEmpty else {
            return
        }

        let info = TerminalANSIText.trailingVisibleNewlineInfo(text)
        guard info.hasVisible else {
            return
        }

        trailingNewlineCount = info.trailingNewlines
    }

    func writeFailureMessage(_ text: String) async {
        await renderCoordinator.writeFailureMessage(text)
    }

    func writeSystemMessage(_ text: String) async {
        await renderCoordinator.writeSystemMessage(text)
    }

    /// Renders a complete, non-streaming Markdown block through the same
    /// terminal formatter used for assistant responses. A dedicated formatter
    /// keeps command output from sharing buffered streaming state.
    func writeMarkdownMessage(_ markdown: String) async {
        await renderCoordinator.writeMarkdownMessage(markdown)
    }

    func writeFileChangeSummaryMessage(_ text: String) async {
        await renderCoordinator.writeFileChangeSummaryMessage(text)
    }

    func writeOperationalMessage(_ text: String) async {
        await renderCoordinator.writeOperationalMessage(text)
    }

    static func chatLineInsetApplied(
        to text: String,
        prefix: String,
        isAtLineStart: inout Bool
    ) -> String {
        guard !text.isEmpty else {
            return text
        }

        var output = ""
        for character in text {
            if character == "\n" || character == "\r" {
                output.append(character)
                isAtLineStart = true
                continue
            }
            if isAtLineStart {
                if !prefix.isEmpty {
                    output += prefix
                }
                isAtLineStart = false
            }
            output.append(character)
        }
        return output
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
