//
//  TerminalChatRenderCoordinator+ToolBlocks.swift
//  ZenCODE
//

import Foundation

/// Tool block lifecycle rendering, including in-place row ownership, redraw safety fuses, and bounded pending rows.
extension TerminalChatRenderCoordinator {
    // MARK: - Tool blocks

    func writeToolCallStarted(
        _ toolCall: DirectAgentToolCall,
        maximumInPlaceRows: Int? = nil
    ) {
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        prepareForToolOutput()
        toolState.startInstants[toolCall.id] = toolNow()
        toolState.activeBlockIsSubAgentTool = DirectSubAgentRuntime
            .isSubAgentToolName(toolCall.name)
        renderToolBlock(
            toolCall,
            lifecycle: .started,
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
        let elapsed = toolState.startInstants.removeValue(forKey: toolCall.id)
            .map { $0.duration(to: toolNow()) }
        let compactStatusDetail = TerminalChat.compactToolCompletionDetail(
            for: toolCall,
            result: result,
            elapsed: elapsed
        )

        // A stale completion must never take ownership from a newer active
        // block; it is rendered append-only below.
        renderToolBlock(
            toolCall,
            lifecycle: .completed(
                result: result,
                compactStatusDetail: compactStatusDetail,
                elapsed: elapsed
            ),
            maximumInPlaceRows: maximumInPlaceRows
        )
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

    private func prepareForToolOutput() {
        flushChatOutput()
        if standardErrorIsTerminal {
            writeChat("\n\n", to: .standardError)
        }
    }

    private func renderToolBlock(
        _ toolCall: DirectAgentToolCall,
        lifecycle: ToolBlockLifecycle,
        maximumInPlaceRows: Int?
    ) {
        let columnWidth = lifecycle.isCompletion
            ? freshColumnWidthProvider()
            : columnWidthProvider()
        let contentInsetWidth = TerminalChat.displayWidth(lineInset)
        var renderRows = toolBlockRows(
            for: toolCall,
            lifecycle: lifecycle,
            contentInsetWidth: contentInsetWidth,
            columnWidth: columnWidth
        )
        if !lifecycle.isCompletion {
            // Keep the compact prefix intact. It must remain renderable by the
            // same path as the completed block, even when the source appendix
            // is constrained by the in-place redraw budget.
            renderRows.detailRows = boundedStartedStandardToolRows(
                renderRows.detailRows,
                compactRows: renderRows.compactRows,
                contentInsetWidth: contentInsetWidth,
                columnWidth: columnWidth,
                maximumInPlaceRows: maximumInPlaceRows
            )
        }

        switch lifecycle {
        case .started:
            toolState.activeBlock = ActiveToolBlock(
                id: toolCall.id,
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
                // scrolling region. Bounding pending blocks at start keeps them
                // rewritable and avoids leaving the hourglass copy in the
                // transcript beside a long completed result.
                let maximumReplaceableRows = min(
                    replaceableToolRowCapacity(
                        block.maximumInPlaceRows
                    ) ?? Int.max,
                    replaceableToolRowCapacity(maximumInPlaceRows) ?? Int.max
                )
                return block.id == toolCall.id
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
            lifecycle: lifecycle
        )
    }

    /// Standard output is the compact block plus an optional source appendix.
    /// Its bounded pending form must never promote an appendix row into the
    /// compact prefix: that would change its ANSI style and could drop the
    /// compact status row.
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

    private func toolBlockRows(
        for toolCall: DirectAgentToolCall,
        lifecycle: ToolBlockLifecycle,
        contentInsetWidth: Int,
        columnWidth: Int
    ) -> ToolBlockRenderRows {
        let safeContentWidth = max(1, columnWidth - contentInsetWidth - 1)
        let result: DirectAgentToolResult?
        switch lifecycle {
        case .started:
            result = nil
        case let .completed(completedResult, _, _):
            result = completedResult
        }
        return ToolBlockRenderRows(
            compactRows: compactToolRows(
                for: toolCall,
                lifecycle: lifecycle,
                contentInsetWidth: contentInsetWidth,
                columnWidth: columnWidth
            ),
            detailRows: TerminalChat.safelyWrappedDetailedToolRows(
                TerminalChat.standardToolCallRows(
                    for: toolCall,
                    result: result,
                    contentWidth: safeContentWidth
                ),
                contentInsetWidth: contentInsetWidth,
                columnWidth: columnWidth
            )
        )
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
        lifecycle: ToolBlockLifecycle
    ) {
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
    /// source rows. The prefix is written byte-for-byte by the compact writer
    /// and only the source appendix goes through the detailed row renderer.
    private struct ToolBlockRenderRows {
        var compactRows: [TerminalChat.DetailedToolRow]
        var detailRows: [TerminalChat.DetailedToolRow]

        var allRows: [TerminalChat.DetailedToolRow] {
            compactRows + detailRows
        }
    }
}
