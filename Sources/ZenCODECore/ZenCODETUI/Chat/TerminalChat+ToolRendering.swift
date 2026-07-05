//
//  TerminalChat+ToolRendering.swift
//  ZenCODE
//

import Foundation

extension TerminalChat {
    public func writeToolCallStarted(_ toolCall: DirectAgentToolCall) {
        prepareForToolOutput()
        guard toolOutputDetailLevel != .compact else {
            writeCompactToolCallStarted(toolCall)
            return
        }

        writeDetailedToolCallStarted(toolCall)
    }

    func prepareForToolOutput() {
        flushChatOutput()
        if AgentOutput.standardErrorIsTerminal {
            writeChatError("\n")
        }
    }

    public func writeToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) {
        guard toolOutputDetailLevel != .compact,
              activeCompactToolCallID != toolCall.id else {
            writeCompactToolCallCompleted(toolCall, result: result)
            return
        }

        writeDetailedToolCallCompleted(toolCall, result: result)
    }

    func writeDetailedToolCallStarted(_ toolCall: DirectAgentToolCall) {
        let lines = Self.detailedToolCallStartedLines(
            for: toolCall,
            level: toolOutputDetailLevel
        )
        activeDetailedToolCallID = toolCall.id
        activeDetailedToolRenderedRowCount = Self.renderedTerminalRowCount(
            for: lines,
            contentInsetWidth: chatLineInsetPrefix.count
        )
        writeToolBlock(lines)
    }

    func writeDetailedToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) {
        let lines = Self.detailedToolCallCompletedLines(
            for: toolCall,
            result: result,
            level: toolOutputDetailLevel
        )
        let shouldRewriteActiveBlock = activeDetailedToolCallID == toolCall.id
            && AgentOutput.standardErrorIsTerminal
        let rewriteRowCount = activeDetailedToolRenderedRowCount
        activeDetailedToolCallID = nil
        activeDetailedToolRenderedRowCount = 0

        if shouldRewriteActiveBlock {
            AgentOutput.standardError.writeString("\u{1B}[\(max(1, rewriteRowCount))A\r\u{1B}[J")
        }
        writeToolBlock(lines)
        writeChatError("\n")
    }

    public func toggleToolDetailsOutput() {
        if activeCompactToolCallID != nil {
            writeChatError("\n")
            activeCompactToolCallID = nil
            activeCompactToolRenderedRowCount = 0
        }
        if activeDetailedToolCallID != nil {
            writeChatError("\n")
            activeDetailedToolCallID = nil
            activeDetailedToolRenderedRowCount = 0
        }
        toolOutputDetailLevel = toolOutputDetailLevel.next
        writeSystemMessage(
            "Tool details: \(toolOutputDetailLevel.label)\n"
        )
    }

    func writeCompactToolCallStarted(_ toolCall: DirectAgentToolCall) {
        let lines = Self.compactToolLines(
            for: toolCall,
            statusIcon: "⏳",
            contentInsetWidth: chatLineInsetPrefix.count
        )
        activeCompactToolCallID = toolCall.id
        activeCompactToolRenderedRowCount = Self.renderedTerminalRowCount(
            for: lines,
            contentInsetWidth: chatLineInsetPrefix.count
        )
        writeCompactToolLines(lines, newline: false)
    }

    func writeCompactToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) {
        let icon = result.isFailure ? "⚠️" : "✅"
        let lines = Self.compactToolLines(
            for: toolCall,
            statusIcon: icon,
            contentInsetWidth: chatLineInsetPrefix.count
        )
        let shouldRewriteActiveLine = activeCompactToolCallID == toolCall.id
            && AgentOutput.standardErrorIsTerminal
        let rewriteRowCount = activeCompactToolRenderedRowCount
        activeCompactToolCallID = nil
        activeCompactToolRenderedRowCount = 0

        if shouldRewriteActiveLine {
            AgentOutput.standardError.writeString("\u{1B}[\(max(1, rewriteRowCount))A\r\u{1B}[J")
        }
        writeCompactToolLines(
            lines,
            newline: true
        )
    }

    func writeCompactToolLines(
        _ lines: [String],
        newline: Bool = false,
        terminator: String = "\n"
    ) {
        let text = Self.compactToolTerminalText(
            lines,
            lineInset: chatLineInsetPrefix,
            newline: newline,
            terminator: terminator
        )
        writeRawChatError(text)
        isAtStartOfChatLine = terminator.hasSuffix("\n")
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
        let title = ZenCODEACPBridge.toolTitle(for: toolCall)
        let icon = ZenCODEACPBridge.toolIcon(for: toolCall.name)
        guard let target = ZenCODEACPBridge.displayToolTarget(for: toolCall),
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

    func writeToolBlock(_ lines: [String]) {
        let reset = "\u{1B}[0m"
        let lineInset = chatLineInsetPrefix
        let text = lines
            .map { "\(lineInset)\(Self.renderDetailedToolLine($0))\(reset)" }
            .joined(separator: "\n")
        writeRawChatError("\(text)\n")
        isAtStartOfChatLine = true
    }

        static func renderDetailedToolLine(_ line: String) -> String {
        if line.hasPrefix("  ") || line.hasPrefix("    ") {
            return TerminalCodeBlockRenderer.renderLine(line, language: nil)
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
    static let detailedSnippetLineLimit = 20
    static let detailedSnippetCharacterLimit = 2_000
    static let fullSnippetLineLimit = 100
    static let fullSnippetCharacterLimit = 10_000

    static func snippetLineLimit(for level: ToolOutputDetailLevel) -> Int {
        level == .detail ? fullSnippetLineLimit : detailedSnippetLineLimit
    }

    static func snippetCharacterLimit(for level: ToolOutputDetailLevel) -> Int {
        level == .detail ? fullSnippetCharacterLimit : detailedSnippetCharacterLimit
    }
}
