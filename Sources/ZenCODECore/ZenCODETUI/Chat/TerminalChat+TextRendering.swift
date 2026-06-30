//
//  TerminalChat+TextRendering.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    public func writeDiagnostic(_ message: String) {
        if message.hasPrefix("Generation done:") {
            if !didReceiveMetricsForCurrentPrompt {
                writeChatError("\n\n[ZenCODE] \(compactGenerationSummary(message))\n")
            }
            return
        }

        guard !message.hasPrefix("Remote request:") else {
            return
        }

        writeChatError("\u{1B}[90m[ZenCODE] \(message)\u{1B}[0m\n")
    }

    public func writeThought(_ delta: String) {
        guard !delta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        finishAssistantContentFormatting()
        if !isStreamingThoughtOutput {
            isStreamingThoughtOutput = true
            let title = AgentOutput.standardErrorIsTerminal
                ? "\u{1B}[90m🤔 Thinking:\u{1B}[0m"
                : "🤔 Thinking:"
            writeChatError("\(title)\n")
        }
        let normalizedDelta = normalizedThoughtDelta(delta)
        guard !normalizedDelta.isEmpty else {
            return
        }
        let renderedThought = thoughtMarkdownFormatter.consume(normalizedDelta)
        writeChatError(
            Self.renderThoughtMarkdown(renderedThought)
        )
    }

    public func writeAssistantContent(_ delta: String) {
        guard !delta.isEmpty else {
            return
        }
        let normalizedDelta = normalizedAssistantDelta(delta)
        guard !normalizedDelta.isEmpty else {
            return
        }
        let renderedContent = assistantMarkdownFormatter.consume(normalizedDelta)
        if !renderedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            writeChatOutput(renderedContent)
        }
    }

        public func finishAssistantContentFormatting() {
        let flushed = Self.flushBoldSectionBreak(state: &assistantBoldBreakState)
        if !flushed.isEmpty {
            _ = assistantMarkdownFormatter.consume(flushed)
        }
        let renderedContent = assistantMarkdownFormatter.finish()
        if !renderedContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            writeChatOutput("\(renderedContent)\n")
            flushChatOutput()
        }
    }

        public func writeSubmittedPrompt(_ prompt: String) {
        let background = "\u{1B}[48;5;236m"
        let clearToEnd = "\u{1B}[K"
        let reset = "\u{1B}[0m"
        let renderedLines = prompt
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, line in
                let prefix = index == 0 ? "> " : "  "
                return "\(background)\(prefix)\(line)\(clearToEnd)\(reset)"
            }
            .joined(separator: "\n")
        writeChatError("\n\(renderedLines)\n\n")
    }

    public func finishThoughtOutputIfNeeded() {
        guard isStreamingThoughtOutput else {
            return
        }
        let flushed = Self.flushBoldSectionBreak(state: &thoughtBoldBreakState)
        if !flushed.isEmpty {
            _ = thoughtMarkdownFormatter.consume(flushed)
        }

                let renderedThought = thoughtMarkdownFormatter.finish()
        let markdown = Self.renderThoughtMarkdown(renderedThought)
        if !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            writeChatError(markdown)
        }
        // Always emit a blank separator after the thinking block so the answer
        // never starts glued to the reasoning. chatSpacingNormalized collapses
        // these to at most two consecutive newlines, yielding exactly one blank
        // line whether or not the formatter had buffered trailing content.
        writeChatError("\n\n")
        isStreamingThoughtOutput = false
    }

    func normalizedAssistantDelta(_ delta: String) -> String {
        Self.normalizedBoldSectionBreak(delta, state: &assistantBoldBreakState)
    }

    func normalizedThoughtDelta(_ delta: String) -> String {
        Self.normalizedBoldSectionBreak(
            delta,
            state: &thoughtBoldBreakState
        )
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
                    // Confirmed `**`. Break only when glued to a sentence end.
                    if let previous = state.previousCharacter,
                       previous == "." || previous == "!" || previous == "?" {
                        output.append("\n\n")
                    }
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

    func writeChatOutput(_ text: String) {
        let normalizedText = chatSpacingNormalized(text)
        AgentOutput.standardOutput.writeString(chatLineInsetApplied(to: normalizedText))
    }

    func flushChatOutput() {
        guard AgentOutput.standardOutputIsTerminal else {
            return
        }
        AgentOutput.standardOutput.synchronizeFile()
    }

    func writeChatError(_ text: String) {
        let normalizedText = chatSpacingNormalized(text)
        AgentOutput.standardError.writeString(chatLineInsetApplied(to: normalizedText))
    }

    func writeRawChatError(_ text: String) {
        let normalizedText = chatSpacingNormalized(text)
        AgentOutput.standardError.writeString(normalizedText)
    }

    func chatSpacingNormalized(_ text: String) -> String {
        Self.chatSpacingNormalized(
            text,
            trailingNewlineCount: &trailingChatNewlineCount
        )
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

    func writeFailureMessage(_ text: String) {
        writeChatError(
            Self.failureMessageColorApplied(
                to: text,
                isEnabled: AgentOutput.standardErrorIsTerminal
            )
        )
    }

    func writeSystemMessage(_ text: String) {
        writeChatError(
            Self.systemMessageColorApplied(
                to: text,
                isEnabled: AgentOutput.standardErrorIsTerminal
            )
        )
    }

    func writeFileChangeSummaryMessage(_ text: String) {
        writeChatError(
            Self.fileChangeSummaryColorApplied(
                to: text,
                isEnabled: AgentOutput.standardErrorIsTerminal
            )
        )
    }

    func writeOperationalMessage(_ text: String) {
        writeChatError(
            Self.operationalMessageColorApplied(
                to: text,
                isEnabled: AgentOutput.standardErrorIsTerminal
            )
        )
    }

    func chatLineInsetApplied(to text: String) -> String {
        Self.chatLineInsetApplied(
            to: text,
            prefix: chatLineInsetPrefix,
            isAtLineStart: &isAtStartOfChatLine
        )
    }

    var chatLineInsetPrefix: String {
        stdinIsTerminal ? Self.chatLineInsetPrefix : ""
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
            if character == "\n" || character == "\n" {
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

    static func colorFileChangeSummaryHeader(_ line: String) -> String {
                let reset = "\u{1B}[0m"
        let color = fileChangeSummaryHeaderANSIColor
        let count = "\u{1B}[38;5;81m"
        let white = "\u{1B}[97m"
        let addition = "\u{1B}[38;5;114m"
        let deletion = "\u{1B}[38;5;203m"
        let pattern = #"^(Summary:) (.+)  (\+\d+) ([-]\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
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
        let pattern = #"^  (\S+) (.+?)(?:  (\+\d+) ([-]\d+)| (\(binary\)))$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
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

    static func renderThoughtMarkdown(_ renderedMarkdown: String) -> String {
        guard AgentOutput.standardErrorIsTerminal,
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
