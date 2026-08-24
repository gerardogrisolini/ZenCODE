//
//  TerminalChatRenderCoordinator+ToolBlocks.swift
//  ZenCODE
//

import Foundation

/// Tool block lifecycle rendering (minimal, standard, detailed), including in-place row ownership, redraw safety fuses, and bounded pending rows.
extension TerminalChatRenderCoordinator {
    // MARK: - Tool blocks

    func writeToolCallStarted(
        _ toolCall: DirectAgentToolCall,
        maximumInPlaceRows: Int? = nil
    ) {
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        let style = toolBlockStyle(for: toolState.detailLevel)
        guard !shouldSuppressDetailedRead(toolCall, style: style) else {
            return
        }
        prepareForToolOutput()
        toolState.startInstants[toolCall.id] = toolNow()
        toolState.activeBlockIsSubAgentTool = DirectSubAgentRuntime
            .isSubAgentToolName(toolCall.name)
        renderToolBlock(
            toolCall,
            lifecycle: .started,
            style: style,
            maximumInPlaceRows: maximumInPlaceRows
        )
    }

    func writeToolCallCompleted(
        _ toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult,
        maximumInPlaceRows: Int? = nil
    ) {
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        let style = toolState.activeBlock.flatMap { block in
            block.id == toolCall.id ? block.style : nil
        } ?? toolBlockStyle(for: toolState.detailLevel)
        guard !shouldSuppressDetailedRead(toolCall, style: style) else {
            return
        }
        let elapsed = toolState.startInstants.removeValue(forKey: toolCall.id)
            .map { $0.duration(to: toolNow()) }
        let compactStatusDetail = TerminalChat.compactToolCompletionDetail(
            for: toolCall,
            result: result,
            elapsed: elapsed
        )

        // A completion redraws in the style of the block it owns, even if the
        // user toggled details while the tool was running. A stale completion
        // uses the current preference but never takes ownership from a newer
        // active block.
        renderToolBlock(
            toolCall,
            lifecycle: .completed(
                result: result,
                compactStatusDetail: compactStatusDetail,
                elapsed: elapsed
            ),
            style: style,
            maximumInPlaceRows: maximumInPlaceRows
        )
    }

    func toggleToolDetailsOutput() {
        finishActiveToolOutputBeforeInterleavedMessage()
        toolState.detailLevel = toolState.detailLevel.next
        writeSystemMessageWithoutInterrupt(
            "Tool details: \(toolState.detailLevel)\n\n"
        )
        renderPendingOverviewsIfIdle()
    }

    func writeAccessModeChangeMessage(_ accessMode: AgentLocalExecAccessMode) {
        finishActiveToolOutputBeforeInterleavedMessage()
        switch accessMode {
        case .standard:
            writeSystemMessageWithoutInterrupt(
                "Mode: default — local.exec approvals restored.\n"
            )
        case .fullAccess:
            writeSystemMessageWithoutInterrupt(
                "Mode: full access — local.exec commands run without approval.\n"
            )
        }
        renderPendingOverviewsIfIdle()
    }

    private func shouldSuppressDetailedRead(
        _ toolCall: DirectAgentToolCall,
        style: ToolBlockStyle
    ) -> Bool {
        style == .detailed && TerminalChat.isFileReadTool(toolCall)
    }

    private func prepareForToolOutput() {
        flushChatOutput()
        if standardErrorIsTerminal {
            writeChat("\n\n", to: .standardError)
        }
    }

    private func renderToolBlock(
        _ toolCall: DirectAgentToolCall,
        lifecycle: ToolBlockLifecycle,
        style: ToolBlockStyle,
        maximumInPlaceRows: Int?
    ) {
        let columnWidth = lifecycle.isCompletion
            ? freshColumnWidthProvider()
            : columnWidthProvider()
        let contentInsetWidth = TerminalChat.displayWidth(lineInset)
        var renderRows = toolBlockRows(
            for: toolCall,
            lifecycle: lifecycle,
            style: style,
            contentInsetWidth: contentInsetWidth,
            columnWidth: columnWidth
        )
        if !lifecycle.isCompletion, style != .minimal {
            if style == .standard {
                // Keep the compact prefix intact. It must remain renderable by
                // the same path as minimal, even when the source appendix is
                // constrained by the in-place redraw budget.
                renderRows.detailRows = boundedStartedStandardToolRows(
                    renderRows.detailRows,
                    compactRows: renderRows.compactRows,
                    contentInsetWidth: contentInsetWidth,
                    columnWidth: columnWidth,
                    maximumInPlaceRows: maximumInPlaceRows
                )
            } else {
                renderRows.detailRows = boundedStartedToolRows(
                    renderRows.detailRows,
                    maximumInPlaceRows: maximumInPlaceRows,
                    includeCompletionMarker: true
                )
            }
        }

        switch lifecycle {
        case .started:
            toolState.activeBlock = ActiveToolBlock(
                id: toolCall.id,
                style: style,
                rows: TerminalChat.renderedTerminalRowCount(
                    for: renderRows.allRows.map(\.plainText),
                    contentInsetWidth: contentInsetWidth,
                    columnWidth: columnWidth
                ),
                columnWidth: columnWidth,
                maximumInPlaceRows: maximumInPlaceRows
            )
        case .completed:
            let activeBlock = toolState.activeBlock
            let ownsActiveBlock = activeBlock?.id == toolCall.id
            let shouldRewriteActiveBlock = activeBlock.map { block in
                // Safety fuse: if the terminal width changed between tool start
                // and completion, the saved row count is stale. Emitting
                // cursor-up / erase sequences based on a stale count can erase
                // transcript rows or leave orphaned rows. Instead, degrade
                // fail-safe: skip the destructive clear and append the
                // completed block.
                //
                // A block that exceeded the scrolling region has already
                // lost its earliest rows to scrollback. The same is true when
                // its content consumes the whole region: the terminating
                // newline needs one physical cursor row and scrolls the title
                // beyond the top margin. Cursor-up / erase can no longer reach
                // that title, leaving it above the completed redraw.
                //
                // A completion may be taller than the region. That does not make
                // clearing unsafe when the pending block itself is still fully
                // owned: normal output then scrolls inside the terminal's active
                // scrolling region. Bounding detailed pending blocks at start
                // keeps them rewritable and avoids leaving the hourglass copy in
                // the transcript beside a long completed result.
                let maximumReplaceableRows = min(
                    replaceableToolRowCapacity(
                        block.maximumInPlaceRows
                    ) ?? Int.max,
                    replaceableToolRowCapacity(maximumInPlaceRows) ?? Int.max
                )
                return block.id == toolCall.id
                    && block.style == style
                    && standardErrorIsTerminal
                    && block.columnWidth == columnWidth
                    && block.rows <= maximumReplaceableRows
            } ?? false

            // Starts transfer the one physical rewrite slot to the newest
            // block. A completion for an older or otherwise unowned tool is
            // append-only: it must not erase the newer block. It *does*,
            // however, write transcript rows after it, so that newer block no
            // longer physically owns the cursor region and must not later
            // cursor-up through this completion.
            if ownsActiveBlock {
                toolState.activeBlock = nil
                toolState.activeBlockIsSubAgentTool = false
            } else if activeBlock != nil {
                toolState.activeBlock = nil
                toolState.activeBlockIsSubAgentTool = false
            }

            if shouldRewriteActiveBlock, let activeBlock {
                clearOwnedRows(activeBlock.rows)
            }
        }

        writeToolBlockRows(
            renderRows,
            for: toolCall,
            lifecycle: lifecycle,
            style: style
        )
    }

    /// Keeps a detailed pending block inside the rewriteable scrolling region.
    /// One row is reserved for the cursor after the block's terminating newline;
    /// otherwise a block that exactly fills the region scrolls its title beyond
    /// the top margin before completion can replace it.
    ///
    /// Large edit/write payloads are shown in full by the completion. Detailed
    /// pending blocks retain a bounded prefix plus status so completion can
    /// replace rather than duplicate the pending block; standard blocks include
    /// the minimal status rows and as many source-change rows as fit.
    private func boundedStartedToolRows(
        _ rows: [TerminalChat.DetailedToolRow],
        maximumInPlaceRows: Int?,
        includeCompletionMarker: Bool
    ) -> [TerminalChat.DetailedToolRow] {
        guard let maximumReplaceableRows = replaceableToolRowCapacity(
            maximumInPlaceRows
        ), rows.count > maximumReplaceableRows else {
            return rows
        }
        guard maximumReplaceableRows > 0 else {
            return rows.last.map { [$0] } ?? []
        }
        guard maximumReplaceableRows > 1 else {
            return rows.last.map { [$0] } ?? []
        }
        guard maximumReplaceableRows > 2 else {
            return [rows[0], rows[rows.count - 1]]
        }

        guard includeCompletionMarker else {
            return Array(rows.prefix(maximumReplaceableRows - 1)) + [
                rows[rows.count - 1]
            ]
        }

        return Array(rows.prefix(maximumReplaceableRows - 2)) + [
            .text("... details shown on completion"),
            rows[rows.count - 1]
        ]
    }

    /// Standard output is the compact block plus an optional source appendix.
    /// Unlike detailed output, its bounded pending form must never promote an
    /// appendix row into the compact prefix: that would change its ANSI style
    /// and could drop the compact status row.
    private func boundedStartedStandardToolRows(
        _ sourceRows: [TerminalChat.DetailedToolRow],
        compactRows: [TerminalChat.DetailedToolRow],
        contentInsetWidth: Int,
        columnWidth: Int,
        maximumInPlaceRows: Int?
    ) -> [TerminalChat.DetailedToolRow] {
        guard let maximumReplaceableRows = replaceableToolRowCapacity(
            maximumInPlaceRows
        ) else {
            return sourceRows
        }
        let compactRowCount = TerminalChat.renderedTerminalRowCount(
            for: compactRows.map(\.plainText),
            contentInsetWidth: contentInsetWidth,
            columnWidth: columnWidth
        )
        let sourceCapacity = maximumReplaceableRows - compactRowCount
        guard sourceCapacity > 0 else {
            // The compact prefix is never truncated merely to make room for
            // standard's optional source appendix.
            return []
        }
        let sourceRowCount = TerminalChat.renderedTerminalRowCount(
            for: sourceRows.map(\.plainText),
            contentInsetWidth: contentInsetWidth,
            columnWidth: columnWidth
        )
        guard sourceRowCount > sourceCapacity else {
            return sourceRows
        }
        guard sourceCapacity > 1 else {
            return [sourceRows[sourceRows.count - 1]]
        }
        return Array(sourceRows.prefix(sourceCapacity - 1))
            + [sourceRows[sourceRows.count - 1]]
    }

    /// Converts the scrolling-region height into the number of content rows
    /// that remain cursor-reachable after `writeToolBlock` appends its newline.
    private func replaceableToolRowCapacity(
        _ maximumInPlaceRows: Int?
    ) -> Int? {
        guard let maximumInPlaceRows else {
            return nil
        }
        return maximumInPlaceRows > 0 ? maximumInPlaceRows - 1 : 0
    }

    private func toolBlockStyle(
        for detailLevel: ToolOutputDetailLevel
    ) -> ToolBlockStyle {
        switch detailLevel {
        case .minimal: return .minimal
        case .standard: return .standard
        case .detailed: return .detailed
        }
    }

    private func toolBlockRows(
        for toolCall: DirectAgentToolCall,
        lifecycle: ToolBlockLifecycle,
        style: ToolBlockStyle,
        contentInsetWidth: Int,
        columnWidth: Int
    ) -> ToolBlockRenderRows {
        switch style {
        case .minimal, .standard:
            let detailRows: [TerminalChat.DetailedToolRow]
            if style == .standard {
                let safeContentWidth = max(1, columnWidth - contentInsetWidth - 1)
                let result: DirectAgentToolResult?
                switch lifecycle {
                case .started:
                    result = nil
                case let .completed(completedResult, _, _):
                    result = completedResult
                }
                detailRows = TerminalChat.safelyWrappedDetailedToolRows(
                    TerminalChat.standardToolCallRows(
                        for: toolCall,
                        result: result,
                        contentWidth: safeContentWidth
                    ),
                    contentInsetWidth: contentInsetWidth,
                    columnWidth: columnWidth
                )
            } else {
                detailRows = []
            }
            return ToolBlockRenderRows(
                compactRows: compactToolRows(
                    for: toolCall,
                    lifecycle: lifecycle,
                    contentInsetWidth: contentInsetWidth,
                    columnWidth: columnWidth
                ),
                detailRows: detailRows
            )
        case .detailed:
            switch lifecycle {
            case .started:
                return ToolBlockRenderRows(
                    compactRows: [],
                    detailRows: TerminalChat.safelyWrappedDetailedToolRows(
                        TerminalChat.detailedToolCallStartedRows(for: toolCall),
                        contentInsetWidth: contentInsetWidth,
                        columnWidth: columnWidth
                    )
                )
            case let .completed(result, _, elapsed):
                let safeContentWidth = max(1, columnWidth - contentInsetWidth - 1)
                return ToolBlockRenderRows(
                    compactRows: [],
                    detailRows: TerminalChat.safelyWrappedDetailedToolRows(
                        TerminalChat.detailedToolCallCompletedRows(
                            for: toolCall,
                            result: result,
                            contentWidth: safeContentWidth,
                            elapsed: elapsed
                        ),
                        contentInsetWidth: contentInsetWidth,
                        columnWidth: columnWidth
                    )
                )
            }
        }
    }

    private func compactToolRows(
        for toolCall: DirectAgentToolCall,
        lifecycle: ToolBlockLifecycle,
        contentInsetWidth: Int,
        columnWidth: Int
    ) -> [TerminalChat.DetailedToolRow] {
        let statusIcon: String
        let statusDetail: String?
        switch lifecycle {
        case .started:
            statusIcon = "⏳"
            statusDetail = nil
        case let .completed(result, compactStatusDetail, _):
            let hasFailedProcessExit = TerminalChat.compactLocalExecExitCode(
                for: toolCall,
                result: result
            ).map { $0 != 0 } ?? false
            statusIcon = result.isFailure || hasFailedProcessExit ? "⚠️" : "✅"
            statusDetail = compactStatusDetail
        }
        return TerminalChat.compactToolLines(
            for: toolCall,
            statusIcon: statusIcon,
            statusDetail: statusDetail,
            contentInsetWidth: contentInsetWidth,
            columnWidth: columnWidth
        ).map(TerminalChat.DetailedToolRow.text)
    }

    private func writeToolBlockRows(
        _ renderRows: ToolBlockRenderRows,
        for toolCall: DirectAgentToolCall,
        lifecycle: ToolBlockLifecycle,
        style: ToolBlockStyle
    ) {
        switch style {
        case .minimal, .standard:
            writeCompactToolLines(
                renderRows.compactRows.map(\.plainText),
                newline: lifecycle.isCompletion && renderRows.detailRows.isEmpty
            )
            guard !renderRows.detailRows.isEmpty else {
                return
            }
            writeToolBlock(
                renderRows.detailRows,
                codeLanguage: TerminalChat.codeLanguageHint(for: toolCall)
            )
            if lifecycle.isCompletion {
                writeChat("\n", to: .standardError)
            }
        case .detailed:
            writeToolBlock(
                renderRows.detailRows,
                codeLanguage: TerminalChat.codeLanguageHint(for: toolCall)
            )
            if lifecycle.isCompletion {
                writeChat("\n", to: .standardError)
            }
        }
    }

    private func writeCompactToolLines(
        _ lines: [String],
        newline: Bool = false,
        terminator: String = "\n"
    ) {
        let text = TerminalChat.compactToolTerminalText(
            lines,
            lineInset: lineInset,
            newline: newline,
            terminator: terminator
        )
        writeRawChatError(text)
    }

    private func writeToolBlock(
        _ rows: [TerminalChat.DetailedToolRow],
        codeLanguage: String? = nil
    ) {
        let reset = TerminalStyle.reset
        let text = rows
            .map {
                "\(lineInset)\(TerminalChat.renderDetailedToolRow($0, codeLanguage: codeLanguage))\(reset)"
            }
            .joined(separator: "\n")
        writeRawChatError("\(text)\n")
    }

    /// Removes only the rows occupied by a block this coordinator owns before
    /// redrawing it. `CSI J` would erase from the transcript into the reserved
    /// input panel.
    func clearOwnedRows(_ rowCount: Int) {
        let count = max(1, rowCount)
        var sequence = "\u{1B}[\(count)A\r"

        for row in 0..<count {
            sequence += "\u{1B}[2K"
            if row < count - 1 {
                sequence += "\u{1B}[1B\r"
            }
        }
        if count > 1 {
            sequence += "\u{1B}[\(count - 1)A\r"
        }

        writeDirect(sequence, to: .standardError)
    }

    func interruptActiveToolForInterleavedOutputIfNeeded() {
        guard toolState.activeBlock != nil else {
            return
        }
        finishActiveToolOutputBeforeInterleavedMessage()
    }

    func finishActiveToolOutputBeforeInterleavedMessage() {
        guard toolState.activeBlock != nil else {
            return
        }
        toolState.activeBlock = nil
        toolState.activeBlockIsSubAgentTool = false
        writeChat("\n", to: .standardError)
    }

    /// A tool block separates the compact lifecycle prefix from optional
    /// detailed/source rows. Standard output shares the former byte-for-byte
    /// with minimal output and renders only the latter through the detailed
    /// renderer.
    private struct ToolBlockRenderRows {
        var compactRows: [TerminalChat.DetailedToolRow]
        var detailRows: [TerminalChat.DetailedToolRow]

        var allRows: [TerminalChat.DetailedToolRow] {
            compactRows + detailRows
        }
    }
}
