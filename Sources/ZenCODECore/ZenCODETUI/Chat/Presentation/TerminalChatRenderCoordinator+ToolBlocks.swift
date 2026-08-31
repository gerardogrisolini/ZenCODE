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
        let isSubAgentTool = DirectSubAgentRuntime.isSubAgentToolName(toolCall.name)
        if isBottomOverlayTransitionActive {
            toolState.startInstants[toolCall.id] = toolNow()
            bottomOverlayDeferredToolRenders.append(
                DeferredToolRender(
                    toolCall: toolCall,
                    lifecycle: .started,
                    isSubAgentTool: isSubAgentTool,
                    preparesOutput: true,
                    requiredRows: nil
                )
            )
            return
        }
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        if isSubAgentTool {
            clearOwnedSubAgentOverviewBeforeInterleavedOutput(
                maximumInPlaceRows: maximumInPlaceRows
            )
        }
        prepareForToolOutput()
        toolState.startInstants[toolCall.id] = toolNow()
        toolState.activeBlockIsSubAgentTool = isSubAgentTool
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
        let isSubAgentTool = DirectSubAgentRuntime.isSubAgentToolName(toolCall.name)
        let elapsed = toolState.startInstants.removeValue(forKey: toolCall.id)
            .map { $0.duration(to: toolNow()) }
        let compactStatusDetail = TerminalChat.compactToolCompletionDetail(
            for: toolCall,
            result: result,
            elapsed: elapsed
        )
        let lifecycle = ToolBlockLifecycle.completed(
            result: result,
            compactStatusDetail: compactStatusDetail,
            elapsed: elapsed
        )
        if isBottomOverlayTransitionActive {
            bottomOverlayDeferredToolRenders.append(
                DeferredToolRender(
                    toolCall: toolCall,
                    lifecycle: lifecycle,
                    isSubAgentTool: isSubAgentTool,
                    preparesOutput: false,
                    requiredRows: nil
                )
            )
            return
        }
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        if isSubAgentTool {
            clearOwnedSubAgentOverviewBeforeInterleavedOutput(
                maximumInPlaceRows: maximumInPlaceRows
            )
        }

        // A stale completion must never take ownership from a newer active
        // block; it is rendered append-only below.
        renderToolBlock(
            toolCall,
            lifecycle: lifecycle,
            maximumInPlaceRows: maximumInPlaceRows
        )
    }

    /// Records the latest delegated call for each agent without writing a
    /// standalone transcript block. The next overview publication lays these
    /// calls out with the canonical tool rows inside its single rewrite slot.
    func recordSubAgentToolEvent(_ event: DirectSubAgentToolEvent) {
        let executionID = "\u{1E}sub-agent\u{1F}\(event.agentID)\u{1F}\(event.toolCall.id)"
        let lifecycle: ToolBlockLifecycle
        switch event.lifecycle {
        case .started:
            subAgentToolState.startInstants[executionID] = toolNow()
            lifecycle = .started
        case let .completed(result):
            let elapsed = subAgentToolState.startInstants
                .removeValue(forKey: executionID)
                .map { $0.duration(to: toolNow()) }
            lifecycle = .completed(
                result: result,
                compactStatusDetail: TerminalChat.compactToolCompletionDetail(
                    for: event.toolCall,
                    result: result,
                    elapsed: elapsed
                ),
                elapsed: elapsed
            )
        }
        subAgentToolState.presentationsByAgentID[event.agentID] =
            SubAgentToolPresentation(
                agentID: event.agentID,
                agentName: event.agentName,
                toolCall: event.toolCall,
                lifecycle: lifecycle
            )
        subAgentToolState.revision &+= 1
    }

    func subAgentToolPresentationSnapshot() -> SubAgentToolPresentationSnapshot {
        SubAgentToolPresentationSnapshot(
            revision: subAgentToolState.revision,
            presentationsByAgentID: subAgentToolState.presentationsByAgentID
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
        let renderRows = toolBlockRows(
            for: toolCall,
            lifecycle: lifecycle,
            contentInsetWidth: contentInsetWidth,
            columnWidth: columnWidth
        )
        let pendingOwnership: (rows: Int, cursorState: CursorState)?
        if lifecycle.isCompletion {
            pendingOwnership = nil
        } else {
            pendingOwnership = (
                rows: TerminalChat.renderedTerminalRowCount(
                    for: renderRows.allRows.map(\.plainText),
                    contentInsetWidth: contentInsetWidth,
                    columnWidth: columnWidth
                ),
                cursorState: currentCursorState(for: .standardError)
            )
        }

        switch lifecycle {
        case .started:
            break
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
                    && block.writeSequence == emittedWriteCount
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
                restoreCursorState(
                    activeBlock.cursorStateBeforeRender,
                    for: .standardError
                )
            }
        }

        writeToolBlockRows(
            renderRows,
            for: toolCall,
            lifecycle: lifecycle
        )
        if let pendingOwnership {
            toolState.activeBlock = ActiveToolBlock(
                toolCall: toolCall,
                id: toolCall.id,
                rows: pendingOwnership.rows,
                columnWidth: columnWidth,
                maximumInPlaceRows: maximumInPlaceRows,
                cursorStateBeforeRender: pendingOwnership.cursorState,
                writeSequence: emittedWriteCount
            )
        }
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
    ) -> TerminalChat.ToolPresentationRows {
        let result: DirectAgentToolResult?
        switch lifecycle {
        case .started:
            result = nil
        case let .completed(completedResult, _, _):
            result = completedResult
        }
        return TerminalChat.toolPresentationRows(
            for: toolCall,
            result: result,
            statusDetail: lifecycle.compactStatusDetail,
            contentInsetWidth: contentInsetWidth,
            columnWidth: columnWidth,
            // Pending blocks stay compact and therefore cursor-rewritable.
            // Source changes are emitted once, in full, by the completion.
            includesSourceChanges: lifecycle.isCompletion
        )
    }

    private func writeToolBlockRows(
        _ renderRows: TerminalChat.ToolPresentationRows,
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

    func detachActiveToolBeforeBottomOverlayTransition(
        maximumInPlaceRows: Int?
    ) {
        bottomOverlayDeferredToolRenders.removeAll(keepingCapacity: true)
        flushChatOutput()
        guard let block = toolState.activeBlock else { return }
        let isSubAgentTool = toolState.activeBlockIsSubAgentTool
        toolState.activeBlock = nil
        toolState.activeBlockIsSubAgentTool = false

        let columnWidth = freshColumnWidthProvider()
        let maximumReplaceableRows = min(
            replaceableToolRowCapacity(block.maximumInPlaceRows) ?? Int.max,
            replaceableToolRowCapacity(maximumInPlaceRows) ?? Int.max
        )
        guard standardErrorIsTerminal,
              block.writeSequence == emittedWriteCount,
              block.columnWidth == columnWidth,
              block.rows <= maximumReplaceableRows else {
            // The old block cannot be removed with certainty. Forget its relative
            // anchor so completion degrades to an append-only presentation.
            return
        }

        clearOwnedRows(block.rows)
        restoreCursorState(block.cursorStateBeforeRender, for: .standardError)
        bottomOverlayDeferredToolRenders.append(
            DeferredToolRender(
                toolCall: block.toolCall,
                lifecycle: .started,
                isSubAgentTool: isSubAgentTool,
                preparesOutput: false,
                requiredRows: block.rows
            )
        )
    }

    func republishToolAfterBottomOverlayTransition(
        maximumInPlaceRows: Int?
    ) {
        let deferredRenders = bottomOverlayDeferredToolRenders
        bottomOverlayDeferredToolRenders.removeAll(keepingCapacity: true)
        guard !deferredRenders.isEmpty else { return }
        let maximumReplaceableRows = replaceableToolRowCapacity(maximumInPlaceRows)
            ?? Int.max
        for deferred in deferredRenders {
            if let requiredRows = deferred.requiredRows,
               requiredRows > maximumReplaceableRows {
                // The newly reduced transcript cannot own every detached row.
                // Keep that tool append-only rather than drawing a block its
                // completion could not safely replace.
                continue
            }
            finishThoughtOutputIfNeeded()
            finishAssistantContentFormatting()
            if deferred.isSubAgentTool {
                clearOwnedSubAgentOverviewBeforeInterleavedOutput(
                    maximumInPlaceRows: maximumInPlaceRows
                )
            }
            if deferred.preparesOutput {
                prepareForToolOutput()
            }
            if !deferred.lifecycle.isCompletion {
                toolState.activeBlockIsSubAgentTool = deferred.isSubAgentTool
            }
            renderToolBlock(
                deferred.toolCall,
                lifecycle: deferred.lifecycle,
                maximumInPlaceRows: maximumInPlaceRows
            )
        }
    }

    /// Transfers the terminal's single live rewrite slot from a pending
    /// coordinator `agent.*` call to the Sub-Agents overview. Unlike a generic
    /// interleaved message, the overview is another transient presentation of
    /// the same delegated work, so retaining the hourglass block in transcript
    /// would make its later completion append a duplicate section.
    func replaceActiveSubAgentToolWithOverview(maximumInPlaceRows: Int?) {
        guard toolState.activeBlockIsSubAgentTool,
              let block = toolState.activeBlock else {
            return
        }
        toolState.activeBlock = nil
        toolState.activeBlockIsSubAgentTool = false

        let columnWidth = freshColumnWidthProvider()
        let maximumReplaceableRows = min(
            replaceableToolRowCapacity(block.maximumInPlaceRows) ?? Int.max,
            replaceableToolRowCapacity(maximumInPlaceRows) ?? Int.max
        )
        guard standardErrorIsTerminal,
              block.writeSequence == emittedWriteCount,
              block.columnWidth == columnWidth,
              block.rows <= maximumReplaceableRows else {
            // The pending rows are no longer cursor-reachable. Preserve them
            // append-safely rather than risking transcript erasure.
            writeChat("\n", to: .standardError)
            return
        }
        clearOwnedRows(block.rows)
        restoreCursorState(block.cursorStateBeforeRender, for: .standardError)
    }

}
