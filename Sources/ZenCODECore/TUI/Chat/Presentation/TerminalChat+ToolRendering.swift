//
//  TerminalChat+ToolRendering.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

extension TerminalChat {
    /// Tool executions that remain observable to the runtime but have no terminal
    /// representation. Keep this presentation-only: authorization, dispatch,
    /// transcript persistence and shared-chat delivery must still see the call.
    nonisolated static func shouldSuppressToolRendering(for toolName: String) -> Bool {
        toolName == "agent.message"
    }
    /// Builds the canonical compact and detailed rows for a tool lifecycle.
    /// Callers provide only their available geometry and placement; coordinator
    /// calls and delegated calls therefore cannot drift in status or diff output.
    nonisolated static func toolPresentationRows(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult?,
        statusDetail: String?,
        contentInsetWidth: Int,
        columnWidth: Int,
        includesSourceChanges: Bool = true
    ) -> ToolPresentationRows {
        let safeContentWidth = max(1, columnWidth - contentInsetWidth - 1)
        let statusIcon = result.map { result in
            let hasFailedProcessExit = compactLocalExecExitCode(for: toolCall, result: result)
                .map { $0 != 0 } ?? false
            return result.isFailure || hasFailedProcessExit ? "⚠️" : "✅"
        } ?? "⏳"

        return ToolPresentationRows(
            compactRows: compactToolLines(
                for: toolCall,
                statusIcon: statusIcon,
                statusDetail: statusDetail,
                contentInsetWidth: contentInsetWidth,
                columnWidth: columnWidth
            ).map(DetailedToolRow.text),
            detailRows: includesSourceChanges
                ? safelyWrappedDetailedToolRows(
                    standardToolCallRows(
                        for: toolCall,
                        result: result,
                        contentWidth: safeContentWidth
                    ),
                    contentInsetWidth: contentInsetWidth,
                    columnWidth: columnWidth,
                    codeLanguage: codeLanguageHint(for: toolCall)
                )
                : [],
            detailContentWidth: safeContentWidth
        )
    }

    public func writeToolCallStarted(_ toolCall: DirectAgentToolCall) async {
        let maximumInPlaceRows = await statusBar.scrollableOutputRowCapacity()
        await renderCoordinator.writeToolCallStarted(
            toolCall,
            maximumInPlaceRows: maximumInPlaceRows
        )
    }

    public func writeToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) async {
        let maximumInPlaceRows = await statusBar.scrollableOutputRowCapacity()
        await renderCoordinator.writeToolCallCompleted(
            toolCall,
            result: result,
            maximumInPlaceRows: maximumInPlaceRows
        )
    }

    func writeSubAgentToolEvent(
        _ event: DirectSubAgentToolEvent,
        sessionID expectedSessionID: String? = nil,
        history expectedHistory: SessionFileArtifactHistory? = nil
    ) async {
        let observedSessionID = expectedSessionID ?? sessionID
        let history = expectedHistory ?? fileArtifactHistory
        guard sessionID == observedSessionID, fileArtifactHistory === history else { return }
        let artifactTurn = activeFileArtifactTurn
        if case .started = event.lifecycle {
            await artifactTurn?.coordinator?.captureBaselineIfNeeded(forAgentToolCall: event.toolCall)
        }
        await renderCoordinator.recordSubAgentToolEvent(event)
        if case let .completed(result) = event.lifecycle {
            await publishLiveFileArtifacts(
                result, callID: event.toolCall.id, agentID: event.agentID,
                context: artifactTurn
            )
        }
        if Self.shouldRefreshGitStatus(for: event) {
            await refreshStatusBarGitStatusSummaryForFileMutation()
        }
        await publishSubAgentOverviewIfChanged()
    }

    func writeAccessModeChangeMessage(_ accessMode: AgentLocalExecAccessMode) async {
        await renderCoordinator.writeAccessModeChangeMessage(accessMode)
    }

    nonisolated static func compactToolTerminalText(
        _ lines: [String],
        lineInset: String,
        newline: Bool = false,
        terminator: String = "\n"
    ) -> String {
        let text = lines
            .enumerated()
            .map { index, line in
                "\r\u{1B}[2K\(lineInset)\(renderCompactToolLine(line, isTitle: index == 0))\(TerminalStyle.reset)"
            }
            .joined(separator: "\n")
        return "\(text)\(terminator)\(newline ? "\n" : "")"
    }

    /// Colors a compact tool line within the orange family: the title row keeps
    /// the full orange identity color, while the target/status row drops to a
    /// lighter peach-orange so the block stays readable instead of flat
    /// monochromatic orange.
    nonisolated static func renderCompactToolLine(
        _ line: String,
        isTitle: Bool
    ) -> String {
        let baseColor = isTitle ? toolTitleColor : toolValueColor
        return "\(baseColor)\(renderCompactToolDuration(in: line, restoring: baseColor))"
    }

    nonisolated static func compactToolLines(
        for toolCall: DirectAgentToolCall,
        statusIcon: String,
        statusDetail: String? = nil,
        contentInsetWidth: Int = 0,
        columnWidth: Int? = nil
    ) -> [String] {
        let title = sanitizedMetadataText(toolCall.name) ?? "tool"
        let header = "\(ToolCallPresentation.toolIcon(for: toolCall.name))  \(title)"
        let target = ToolCallPresentation.displayToolTarget(for: toolCall).flatMap(sanitizedMetadataText)
        let statusLine = compactToolStatusLine(
            target: target ?? header,
            statusIcon: statusIcon,
            statusDetail: statusDetail,
            collapsesTargetWhitespace: target != nil,
            contentInsetWidth: contentInsetWidth,
            columnWidth: columnWidth
        )
        return target == nil ? [statusLine] : [header, statusLine]
    }

    /// Compact completion metadata is intentionally assembled independently
    /// from layout. The coordinator measures elapsed time at lifecycle edges;
    /// this helper merely makes the stable, human-readable status fragment.
    nonisolated static func compactToolCompletionDetail(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult,
        elapsed: Duration?
    ) -> String? {
        var components: [String] = []
        if let elapsed {
            components.append(toolElapsedTimeText(elapsed))
        }
        if let exitCode = compactLocalExecExitCode(
            for: toolCall,
            result: result
        ), exitCode != 0 {
            components.append("exit \(exitCode)")
        }
        return components.isEmpty ? nil : components.joined(separator: " ")
    }

    /// Reads only the leading, complete canonical process-result line. In
    /// particular, an arbitrary phrase or a later stdout line containing
    /// `exit_code:` is not treated as structured process metadata, avoiding
    /// false failures from tool output text.
    nonisolated static func compactLocalExecExitCode(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult
    ) -> Int? {
        guard toolCall.name == "local.exec" else {
            return nil
        }
        for payload in [result.summary, result.output] {
            guard let line = payload.split(
                omittingEmptySubsequences: false,
                whereSeparator: \.isNewline
            ).first else {
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("exit_code: "),
               case let value = trimmed.dropFirst("exit_code: ".count),
               isCanonicalExitCode(value),
               let exitCode = Int(value) {
                return exitCode
            }
        }
        return nil
    }

    nonisolated static func compactToolStatusLine(
        target: String,
        statusIcon: String,
        statusDetail: String? = nil,
        collapsesTargetWhitespace: Bool = true,
        contentInsetWidth: Int = 0,
        columnWidth: Int? = nil
    ) -> String {
        let resolvedColumns = columnWidth ?? terminalColumnCount()
        let columns = max(0, resolvedColumns - contentInsetWidth)
        // Reserve one trailing column: a line exactly terminal-width wraps
        // ambiguously, so the in-place rewrite on completion would move up one
        // row too few and leave the previous title line behind.
        let safeLineWidth = max(0, columns - 1)
        let statusText = compactToolStatusText(
            icon: statusIcon,
            detail: statusDetail,
            maximumWidth: safeLineWidth
        )
        let suffixWidth = displayWidth(statusText)
        let textWidthLimit = safeLineWidth - suffixWidth - 1
        guard textWidthLimit > 0 else {
            return suffixWidth <= safeLineWidth ? statusText : ""
        }
        let fittedTarget = fitDisplayWidth(
            collapsesTargetWhitespace ? compactToolInlineTarget(target) : target,
            width: textWidthLimit
        )
        guard !fittedTarget.isEmpty else {
            return suffixWidth <= safeLineWidth ? statusText : ""
        }
        return "\(fittedTarget) \(statusText)"
    }

    /// A narrow terminal must never wrap an in-place compact row. Keep the
    /// status icon in that case and omit all-or-nothing metadata rather than
    /// slicing a duration or an `exit N` token into an ambiguous fragment.
    private nonisolated static func compactToolStatusText(
        icon: String,
        detail: String?,
        maximumWidth: Int
    ) -> String {
        guard let detail, !detail.isEmpty else {
            return icon
        }
        // ⚠️ carries a variation selector that most terminals render as a
        // double-width emoji, visually consuming one trailing space. Add an
        // extra separator so the icon stays visually separated from the detail.
        let separator = icon == "⚠️" ? "  " : " "
        let expanded = "\(icon)\(separator)\(detail)"
        return displayWidth(expanded) <= maximumWidth ? expanded : icon
    }

    nonisolated static func toolElapsedTimeText(_ duration: Duration) -> String {
        let seconds = max(
            0,
            Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        )
        let locale = Locale(identifier: "en_US_POSIX")
        guard seconds < 1 else {
            return String(format: "%.2fs", locale: locale, seconds)
        }

        let milliseconds = seconds * 1_000
        guard milliseconds > 0 else {
            return "0ms"
        }
        guard milliseconds >= 0.01 else {
            return "<0.01ms"
        }

        let format = milliseconds < 10 ? "%.2fms" : milliseconds < 100 ? "%.1fms" : "%.0fms"
        return String(format: format, locale: locale, milliseconds)
    }

    /// Compact status rows have no font-size control, so elapsed time uses the
    /// same gray as thinking to reduce its visual weight without adding cells or
    /// changing the in-place redraw width budget.
    private nonisolated static func renderCompactToolDuration(
        in line: String,
        restoring baseColor: String
    ) -> String {
        guard let range = compactToolDurationRange(in: line) else {
            return line
        }
        return "\(line[..<range.lowerBound])\(toolDurationColor)\(line[range])\(baseColor)\(line[range.upperBound...])"
    }

    private nonisolated static func compactToolDurationRange(
        in line: String
    ) -> Range<String.Index>? {
        guard let markerRange = ["✅ ", "⚠️ "]
            .compactMap({ line.range(of: $0, options: .backwards) })
            .max(by: { $0.lowerBound < $1.lowerBound }) else {
            return nil
        }
        let start = markerRange.upperBound
        // Skip any extra padding whitespace between the status icon and the
        // duration token (the ⚠️ emoji renders as double-width and carries an
        // extra separator space to compensate).
        let tokenStart = line[start...].drop(while: \.isWhitespace).startIndex
        let end = line[tokenStart...].firstIndex(where: \.isWhitespace) ?? line.endIndex
        let token = line[tokenStart..<end]
        guard isCanonicalToolDurationToken(token) else {
            return nil
        }
        let suffix = line[end...]
        if !suffix.isEmpty {
            let exitPrefix = " exit "
            guard suffix.hasPrefix(exitPrefix),
                  isCanonicalExitCode(suffix.dropFirst(exitPrefix.count)) else {
                return nil
            }
        }
        return tokenStart..<end
    }

    private nonisolated static func isCanonicalToolDurationToken(
        _ token: Substring
    ) -> Bool {
        let numeric: Substring
        if token.hasSuffix("ms") {
            numeric = token.dropLast(2)
        } else if token.hasSuffix("s") {
            numeric = token.dropLast()
        } else {
            return false
        }

        let components = (numeric.first == "<" ? numeric.dropFirst() : numeric).split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        return (components.count == 1 || components.count == 2)
            && components.allSatisfy { component in
                !component.isEmpty && component.allSatisfy(\.isWholeNumber)
            }
    }

    private nonisolated static func isCanonicalExitCode(
        _ value: Substring
    ) -> Bool {
        let digits = value.first == "-" ? value.dropFirst() : value
        return !digits.isEmpty && digits.allSatisfy(\.isWholeNumber)
    }

    nonisolated static func renderedTerminalRowCount(
        for lines: [String],
        contentInsetWidth: Int = 0,
        columnWidth: Int? = nil
    ) -> Int {
        let resolvedColumns = columnWidth ?? terminalColumnCount()
        let columns = max(1, resolvedColumns - contentInsetWidth)
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

    nonisolated static func compactToolInlineTarget(_ target: String) -> String {
        target
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    nonisolated static func fitDisplayWidth(_ text: String, width: Int) -> String {
        guard displayWidth(text) > width else {
            return text
        }
        guard width > 0 else {
            return ""
        }
        guard width > 3 else {
            // There is no room for the three-column ellipsis. Keep the prior
            // no-ellipsis fallback, but make it genuinely width-aware: a wide
            // grapheme cannot be copied into a one-cell budget.
            var output = ""
            var outputWidth = 0
            for character in text {
                let characterWidth = TerminalANSIText.visibleWidth(of: character)
                guard outputWidth + characterWidth <= width else {
                    break
                }
                output.append(character)
                outputWidth += characterWidth
            }
            return output
        }
        // Inputs carry no ANSI, so the shared grapheme-safe core is exact here.
        return TerminalANSIText.truncate(
            text,
            to: width,
            ellipsis: "...",
            ellipsisWidth: 3
        )
    }

    nonisolated static func displayWidth(_ text: String) -> Int {
        TerminalANSIText.visibleWidth(text)
    }

    /// Renders a structured detailed row. A side-by-side row draws its two
    /// cells from separate fields, so each is tokenized independently and no
    /// payload sequence can be mistaken for the divider.
    nonisolated static func renderDetailedToolRow(
        _ row: DetailedToolRow,
        codeLanguage: String? = nil,
        contentWidth: Int? = nil
    ) -> String {
        let rendered: String
        switch row {
        case let .text(line):
            let text = renderDetailedToolLine(line, codeLanguage: codeLanguage)
            guard line.hasPrefix("  ") else { return text }
            rendered = text
        case let .parameter(line, highlightsJSON):
            return renderDetailedToolParameterLine(line, highlightsJSON: highlightsJSON)
        case let .code(line):
            rendered = renderCodeAreaLine(
                indentation: line.indentation,
                lineNumber: line.lineNumber,
                content: line.content,
                language: line.contentIsPreHighlighted ? nil : codeLanguage
            )
        case let .diff(cells):
            rendered = renderDiffCodeAreaLine(
                indentation: cells.indentation,
                oldCell: cells.oldCell,
                newCell: cells.newCell,
                language: cells.cellsArePreHighlighted ? nil : codeLanguage
            )
        case let .unifiedDiff(line):
            rendered = renderUnifiedDiffCodeAreaLine(
                indentation: line.indentation,
                marker: line.marker,
                lineNumber: line.lineNumber,
                content: line.content,
                language: line.contentIsPreHighlighted ? nil : codeLanguage
            )
        }
        // Paint only the source viewport, including short rows and the spare
        // cell from an odd side-by-side budget. Reset before EL so the reserved
        // right margin (and any stale background there) uses the host surface.
        let padding = max(0, (contentWidth ?? 0) - displayWidth(rendered))
        return rendered + codeAreaBackgroundColor + String(repeating: " ", count: padding)
            + TerminalStyle.reset + "\u{1B}[K"
    }

    /// Renders a source row with a neutral gutter and independently highlighted
    /// content. Keeping the number out of the tokenizer prevents source-language
    /// palettes from coloring it orange.
    nonisolated static func renderCodeAreaLine(
        indentation: String,
        lineNumber: String,
        content: String,
        language: String?
    ) -> String {
        let codeStyle = "\(codeAreaBackgroundColor)\(TerminalMarkdownPalette.dark.codeForeground)"
        return "\(codeAreaBackgroundColor)\(indentation)"
            + "\(toolCodeGutterColor)\(lineNumber)\(DetailedToolCodeLine.gutter)"
            + "\(codeStyle)\(renderCodeAreaFragment(content, language: language))"
    }

    nonisolated static func renderDetailedToolLine(
        _ line: String,
        codeLanguage: String? = nil
    ) -> String {
        if line.hasPrefix("  ") {
            return renderCodeAreaLine(line, language: codeLanguage)
        }
        // Split labeled metadata rows ("label: value") so the label keeps a
        // muted orange while the value uses the peach-orange of compact tool
        // values. The title row (icon + tool name, no leading label colon)
        // stays full orange.
        if let colonIndex = line.firstIndex(of: ":"),
           isDetailedToolLabel(line[..<colonIndex]) {
            let label = line[...colonIndex]
            let value = line[line.index(after: colonIndex)...]
            return "\(toolLabelColor)\(label)\(toolValueColor)\(value)"
        }
        return "\(toolTitleColor)\(line)"
    }

    /// Parameter payloads are highlighted with the shared JSON tokenizer and the
    /// fenced-code palette; punctuation and untokenized text keep the neutral
    /// gray base color, to which token resets are re-anchored so none leaks the
    /// terminal's default foreground. There is no code-area background.
    ///
    /// Rows inside a `"""` block are raw multi-line strings, rendered flat so
    /// prose is never tokenized as data.
    nonisolated static func renderDetailedToolParameterLine(
        _ line: String,
        highlightsJSON: Bool = true
    ) -> String {
        guard highlightsJSON else {
            return "\(toolParameterBaseColor)\(line)"
        }
        let reset = TerminalStyle.reset
        return toolParameterBaseColor + TerminalCodeBlockRenderer
            .renderLine(line, language: "json")
            .replacingOccurrences(of: reset, with: "\(reset)\(toolParameterBaseColor)")
    }

    /// Renders a code snippet fragment over the code background. The enclosing
    /// row renderer owns bounded padding and resets before clearing the margin.
    /// Highlight resets are re-anchored to the background so token colors never
    /// punch holes in the frame.
    nonisolated static func renderCodeAreaLine(
        _ line: String,
        language: String?
    ) -> String {
        "\(codeAreaBackgroundColor)\(renderCodeAreaFragment(line, language: language))"
    }

    /// Renders a single side-by-side diff cell. When the cell carries a
    /// line-number gutter (``<number> │ <content>``), the gutter is painted
    /// with the neutral gray gutter color so the syntax highlighter never
    /// recolors the number — matching the regular code-area rendering.
    nonisolated static func renderDiffCellFragment(
        _ cell: String,
        language: String?
    ) -> String {
        let gutterSeparator = " │ "
        guard let range = cell.range(of: gutterSeparator) else {
            return renderCodeAreaFragment(cell, language: language)
        }
        let numberPart = String(cell[..<range.lowerBound])
        let contentPart = String(cell[range.upperBound...])
        // Only treat the prefix as a line-number gutter when it is entirely
        // numeric or whitespace; otherwise the " │ " belongs to the content.
        let trimmed = numberPart.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty || trimmed.allSatisfy(\.isWholeNumber) else {
            return renderCodeAreaFragment(cell, language: language)
        }
        return "\(toolCodeGutterColor)\(numberPart)\(codeAreaBackgroundColor)\(gutterSeparator)"
            + renderCodeAreaFragment(contentPart, language: language)
    }

    /// The old and new cells of a side-by-side diff must be tokenized as two
    /// independent source lines. In particular, a line comment or an unterminated
    /// string on the old side must not color the divider and hide highlighting on
    /// the new side.
    nonisolated static func renderDiffCodeAreaLine(
        indentation: String,
        oldCell: String,
        newCell: String,
        language: String?
    ) -> String {
        let divider = DetailedToolDiffCells.divider
        return "\(codeAreaBackgroundColor)\(indentation)"
            + renderDiffCellFragment(oldCell, language: language)
            + "\(codeAreaBackgroundColor)\(divider)"
            + renderDiffCellFragment(newCell, language: language)
    }

    /// Renders one stacked unified-diff line inside the same framed code area
    /// used by side-by-side cells. Only the marker is colored as a deletion or
    /// addition; source content is still highlighted independently and every
    /// syntax-renderer reset is re-anchored to the code background.
    nonisolated static func renderUnifiedDiffCodeAreaLine(
        indentation: String,
        marker: String,
        lineNumber: String,
        content: String,
        language: String?
    ) -> String {
        let markerColor = switch marker {
        case "-": TerminalStyle.FileChange.deletion
        case "+": TerminalStyle.FileChange.addition
        default: codeAreaBackgroundColor
        }
        let background = codeAreaBackgroundColor
        return "\(background)\(indentation)\(markerColor)\(marker)\(background) \(toolCodeGutterColor)\(lineNumber)\(background)\(DetailedToolUnifiedDiffLine.gutter)\(renderCodeAreaFragment(content, language: language))"
    }

    nonisolated static func renderCodeAreaFragment(
        _ line: String,
        language: String?
    ) -> String {
        guard let language else {
            // Documentation, plain-text and unknown file types deliberately skip
            // syntax highlighting. Set their foreground explicitly so diff cells
            // cannot inherit the muted gutter color, including after wrapping.
            return "\(TerminalMarkdownPalette.dark.codeForeground)\(line)"
        }
        let reset = TerminalStyle.reset
        return TerminalCodeBlockRenderer
            // Expanded tool snippets always paint their own dark code surface,
            // regardless of the host terminal theme. Keep token colors paired
            // with that surface instead of using the host light-theme palette.
            .renderLine(line, language: language, palette: .dark)
            .replacingOccurrences(of: reset, with: "\(reset)\(codeAreaBackgroundColor)")
    }

    /// Returns whether the text before the first colon looks like a metadata
    /// label (single lowercase word) rather than part of the tool title.
    nonisolated static func isDetailedToolLabel(_ candidate: Substring) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.allSatisfy { $0.isLowercase || $0.isLetter }
    }

    // Orange-family palette: full identity orange for titles, muted terracotta
    // for labels, and peach-orange for compact and expanded metadata values.
    // Parameter JSON keeps the neutral gray base for punctuation while keys,
    // strings and literals use the shared code-block syntax palette.
    nonisolated static let toolTitleColor = TerminalStyle.Tool.title
    nonisolated static let toolLabelColor = TerminalStyle.Tool.label
    nonisolated static let toolValueColor = TerminalStyle.Tool.value
    nonisolated static let toolDurationColor = TerminalStyle.Tool.duration
    nonisolated static let toolParameterBaseColor = TerminalStyle.Tool.parameter
    nonisolated static let toolCodeGutterColor = TerminalStyle.Tool.codeGutter
    // Dark gray background framing the code areas of expanded tool blocks,
    // matching the background used for submitted prompts.
    nonisolated static let codeAreaBackgroundColor = TerminalStyle.Tool.codeBackground
}
