//
//  TerminalChat+ToolRendering.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    public func writeToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        await renderCoordinator.writeToolCallStarted(toolCall)
    }

    public func writeToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) async {
        await renderCoordinator.writeToolCallCompleted(toolCall, result: result)
    }

    public func toggleToolDetailsOutput() async {
        await renderCoordinator.toggleToolDetailsOutput()
    }

    func writeAccessModeChangeMessage(_ accessMode: AgentLocalExecAccessMode) async {
        await renderCoordinator.writeAccessModeChangeMessage(accessMode)
    }

    static func compactToolTerminalText(
        _ lines: [String],
        lineInset: String,
        newline: Bool = false,
        terminator: String = "\n"
    ) -> String {
        let reset = "\u{1B}[0m"
        let suffix = newline ? "\n" : ""
        let text = lines
            .enumerated()
            .map { index, line in
                "\r\u{1B}[2K\(lineInset)\(Self.renderCompactToolLine(line, isTitle: index == 0))\(reset)"
            }
            .joined(separator: "\n")
        return "\(text)\(terminator)\(suffix)"
    }

        /// Colors a compact tool line within the orange family: the title row keeps
    /// the full orange identity color, while the target/status row drops to a
    /// lighter peach-orange so the block stays readable instead of flat
    /// monochromatic orange.
    static func renderCompactToolLine(
        _ line: String,
        isTitle: Bool
    ) -> String {
        if isTitle {
            return "\(toolTitleColor)\(line)"
        }
        return "\(toolValueColor)\(line)"
    }

    static func compactToolLines(
        for toolCall: DirectAgentToolCall,
        statusIcon: String,
        contentInsetWidth: Int = 0
    ) -> [String] {
        let title = ToolCallPresentation.toolTitle(for: toolCall)
        let icon = ToolCallPresentation.toolIcon(for: toolCall.name)
        guard let target = ToolCallPresentation.displayToolTarget(for: toolCall),
              title.hasSuffix(target) else {
            return ["\(icon)  \(title) \(statusIcon)"]
        }

        let action = title
            .dropLast(target.count)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !action.isEmpty else {
            return ["\(icon)  \(title) \(statusIcon)"]
        }
        return [
            "\(icon)  \(action):",
            compactToolStatusLine(
                target: target,
                statusIcon: statusIcon,
                contentInsetWidth: contentInsetWidth
            )
        ]
    }

    static func compactToolStatusLine(
        target: String,
        statusIcon: String,
        contentInsetWidth: Int = 0
    ) -> String {
        let columns = max(20, terminalColumnCount() - contentInsetWidth)
        let suffixWidth = displayWidth(statusIcon)
        // Reserve one extra trailing column so the rendered line (inset + target
        // + " " + status icon) never occupies the full terminal width. A line
        // that is exactly terminal-width triggers ambiguous auto-wrap behavior:
        // terminals without deferred wrap advance the cursor an extra row, so
        // the in-place rewrite on completion moves up one row too few and leaves
        // the previous title line behind, duplicating the tool header.
        let textWidthLimit = max(1, columns - suffixWidth - 2)
        let fittedTarget = fitDisplayWidth(
            compactToolInlineTarget(target),
            width: textWidthLimit
        )
        return "\(fittedTarget) \(statusIcon)"
    }

    static func renderedTerminalRowCount(
        for lines: [String],
        contentInsetWidth: Int = 0
    ) -> Int {
        let columns = max(1, terminalColumnCount() - contentInsetWidth)
        return lines.reduce(0) { result, line in
            let segments = line.split(
                omittingEmptySubsequences: false,
                whereSeparator: \.isNewline
            )
            return result + segments.reduce(0) { segmentResult, segment in
                let width = max(1, displayWidth(String(segment)))
                return segmentResult + max(1, (width + columns - 1) / columns)
            }
        }
    }

    static func compactToolInlineTarget(_ target: String) -> String {
        target
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func fitDisplayWidth(_ text: String, width: Int) -> String {
        guard displayWidth(text) > width else {
            return text
        }
        guard width > 3 else {
            return String(text.prefix(max(0, width)))
        }

        var output = ""
        var currentWidth = 0
        let ellipsisWidth = 3
        for character in text {
            let characterWidth = displayWidth(String(character))
            guard currentWidth + characterWidth <= width - ellipsisWidth else {
                break
            }
            output.append(character)
            currentWidth += characterWidth
        }
        return output + "..."
    }

    static func displayWidth(_ text: String) -> Int {
        TerminalANSIText.visibleWidth(text)
    }

    static func renderDetailedToolLine(
        _ line: String,
        codeLanguage: String? = nil
    ) -> String {
        if line.hasPrefix("  ") || line.hasPrefix("    ") {
            return renderCodeAreaLine(line, language: codeLanguage)
        }
        // Split labeled metadata rows ("label: value") so the label keeps a
        // muted orange while the value drops to gray, keeping the block within
        // the orange family without being flat monochromatic. The title row
        // (icon + tool name, no leading label colon) stays full orange.
        if let colonIndex = line.firstIndex(of: ":"),
           isDetailedToolLabel(line[..<colonIndex]) {
            let label = line[...colonIndex]
            let value = line[line.index(after: colonIndex)...]
            return "\(toolLabelColor)\(label)\(toolValueColor)\(value)"
        }
        return "\(toolTitleColor)\(line)"
    }

    /// Renders a code snippet row of the expanded tool block: the line is
    /// syntax-highlighted for the target file's language and painted over a
    /// dark background that extends to the right edge of the terminal, so the
    /// whole code area reads as one framed block. Highlight resets emitted by
    /// the code renderer are re-anchored to the background color so token
    /// colors never punch holes in the frame.
    static func renderCodeAreaLine(
        _ line: String,
        language: String?
    ) -> String {
        let reset = "\u{1B}[0m"
        let clearToEnd = "\u{1B}[K"
        let highlighted = TerminalCodeBlockRenderer
            .renderLine(line, language: language)
            .replacingOccurrences(of: reset, with: "\(reset)\(codeAreaBackgroundColor)")
        return "\(codeAreaBackgroundColor)\(highlighted)\(clearToEnd)"
    }

    /// Returns whether the text before the first colon looks like a metadata
    /// label (single lowercase word) rather than part of the tool title.
    static func isDetailedToolLabel(_ candidate: Substring) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return false
        }
        return trimmed.allSatisfy { $0.isLowercase || $0.isLetter }
    }

                // Orange-family palette: full identity orange for titles, a muted
    // terracotta for labels, and a light peach-orange for values so the whole
    // tool block stays within the orange family while keeping a readable
    // hierarchy.
    static let toolTitleColor = "\u{1B}[38;5;208m"
    static let toolLabelColor = "\u{1B}[38;5;173m"
    static let toolValueColor = "\u{1B}[38;5;215m"
    // Dark gray background framing the code areas of expanded tool blocks,
    // matching the background used for submitted prompts.
    static let codeAreaBackgroundColor = "\u{1B}[48;5;236m"
    static let expandedSnippetLineLimit = 100
    static let expandedSnippetCharacterLimit = 10_000
}
