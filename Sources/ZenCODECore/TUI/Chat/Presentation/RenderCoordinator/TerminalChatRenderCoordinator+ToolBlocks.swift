//
//  TerminalChatRenderCoordinator+ToolBlocks.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ZenCODERuntime

/// Tool block lifecycle rendering, including in-place row ownership, redraw safety fuses, and bounded pending rows.
extension TerminalChatRenderCoordinator {
    private static let maximumPendingToolAdjacentSystemMessages = 16

    // MARK: - Tool blocks

    func writeToolCallStarted(
        _ toolCall: DirectAgentToolCall,
        maximumInPlaceRows: Int? = nil
    ) {
        guard !ToolRenderingPolicy.shouldSuppressToolRendering(for: toolCall.name) else {
            return
        }
        guard externalTerminalPromptDepth == 0 else {
            externalTerminalPromptDeferredToolStarts.append(
                DeferredToolStart(toolCall: toolCall, maximumInPlaceRows: maximumInPlaceRows)
            )
            return
        }
        drawToolCallStarted(toolCall, maximumInPlaceRows: maximumInPlaceRows)
    }

    private func drawToolCallStarted(
        _ toolCall: DirectAgentToolCall,
        maximumInPlaceRows: Int?
    ) {
        let isSubAgentTool = DirectSubAgentRuntime.isSubAgentToolName(toolCall.name)
        if isBottomOverlayTransitionActive {
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
        clearOwnedSubAgentOverviewBeforeInterleavedOutput(
            maximumInPlaceRows: maximumInPlaceRows
        )
        if previewAlreadyShowedHeader(for: toolCall) {
            // The preview header already showed the canonical tool name (never
            // the path): the status row, which carries the target, follows the
            // source rows without a separator.
            flushChatOutput()
        } else {
            prepareForToolOutput()
        }
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
        guard !ToolRenderingPolicy.shouldSuppressToolRendering(for: toolCall.name) else {
            return
        }
        let isSubAgentTool = DirectSubAgentRuntime.isSubAgentToolName(toolCall.name)
        let lifecycle = ToolBlockLifecycle.completed(for: toolCall, result: result)
        // A start held behind an external prompt was never drawn: this
        // completion is the call's only block and opens it as the start would.
        let startWasDeferred = takeExternalTerminalPromptDeferredToolStart(id: toolCall.id)
        if isBottomOverlayTransitionActive {
            bottomOverlayDeferredToolRenders.append(
                DeferredToolRender(
                    toolCall: toolCall,
                    lifecycle: lifecycle,
                    isSubAgentTool: isSubAgentTool,
                    preparesOutput: startWasDeferred,
                    requiredRows: nil
                )
            )
            return
        }
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        clearOwnedSubAgentOverviewBeforeInterleavedOutput(
            maximumInPlaceRows: maximumInPlaceRows
        )
        if startWasDeferred {
            prepareForToolOutput()
        }

        // A stale completion must never take ownership from a newer active
        // block; it is rendered append-only below.
        renderToolBlock(
            toolCall,
            lifecycle: lifecycle,
            maximumInPlaceRows: maximumInPlaceRows
        )
        flushToolAdjacentSystemMessagesIfPossible()
    }

    private func takeExternalTerminalPromptDeferredToolStart(id: String) -> Bool {
        guard let index = externalTerminalPromptDeferredToolStarts.firstIndex(where: {
            $0.toolCall.id == id
        }) else {
            return false
        }
        externalTerminalPromptDeferredToolStarts.remove(at: index)
        return true
    }

    /// Draws the starts held behind an external prompt whose calls are still
    /// running, in arrival order, now that the prompt gives the transcript
    /// back: the newest owns the rewrite slot, as if it had just started.
    func drawToolStartsDeferredByExternalTerminalPrompt() {
        let starts = externalTerminalPromptDeferredToolStarts
        externalTerminalPromptDeferredToolStarts.removeAll(keepingCapacity: true)
        for start in starts {
            drawToolCallStarted(start.toolCall, maximumInPlaceRows: start.maximumInPlaceRows)
        }
    }

    /// Records the latest delegated call for each agent without writing a
    /// standalone transcript block. The next overview publication lays these
    /// calls out with the canonical tool rows inside its single rewrite slot.
    func recordSubAgentToolEvent(_ event: DirectSubAgentToolEvent) {
        guard !ToolRenderingPolicy.shouldSuppressToolRendering(for: event.toolCall.name) else {
            return
        }
        let lifecycle: ToolBlockLifecycle
        switch event.lifecycle {
        case .started:
            lifecycle = .started
        case let .completed(result):
            lifecycle = .completed(for: event.toolCall, result: result)
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
        interruptToolCallPreviewIfNeeded()
        finishActiveToolOutputBeforeInterleavedMessage()
        writeSystemMessageWithoutInterrupt(
            ChatSessionNoticeText.localExecAccessModeChangeText(accessMode)
        )
        renderPendingOverviewsIfIdle()
    }

    /// Receives a diagnostic that was produced inside tool execution but outside
    /// the TUI callback stream. While a pending tool owns rows, publishing it
    /// directly would invalidate that relative anchor. Keep it adjacent to the
    /// tool and publish it only after the completion has replaced those rows.
    func writeToolAdjacentSystemMessage(_ text: String) {
        guard !text.isEmpty else { return }
        guard toolState.activeBlock == nil,
              externalTerminalPromptDeferredToolStarts.isEmpty,
              !isBottomOverlayTransitionActive else {
            if pendingToolAdjacentSystemMessages.count
                == Self.maximumPendingToolAdjacentSystemMessages {
                pendingToolAdjacentSystemMessages.removeFirst()
            }
            pendingToolAdjacentSystemMessages.append(text)
            return
        }
        writeStandaloneToolAdjacentSystemMessage(text)
    }

    private func writeStandaloneToolAdjacentSystemMessage(_ text: String) {
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        parkSubAgentOverviewForReplay(maximumInPlaceRows: nil)
        writeSystemMessageWithoutInterrupt(text)
        renderPendingOverviewsIfIdle()
    }

    private func flushToolAdjacentSystemMessagesIfPossible() {
        guard toolState.activeBlock == nil,
              externalTerminalPromptDeferredToolStarts.isEmpty,
              !isBottomOverlayTransitionActive,
              !pendingToolAdjacentSystemMessages.isEmpty else {
            return
        }
        let messages = pendingToolAdjacentSystemMessages
        pendingToolAdjacentSystemMessages.removeAll(keepingCapacity: true)
        for message in messages {
            writeStandaloneToolAdjacentSystemMessage(message)
        }
    }

    func prepareForToolOutput() {
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
        let contentInsetWidth = TerminalTextMetrics.displayWidth(lineInset)
        let activeBlock = toolState.activeBlock
        let ownsActiveBlock = activeBlock?.id == toolCall.id
        let shouldRewriteActiveBlock = lifecycle.isCompletion && (activeBlock.map { block in
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
                && ownsScreenReceipt(block.screenAnchor)
                && block.columnWidth == columnWidth
                && block.rows <= maximumReplaceableRows
        } ?? false)
        // A completion omits the header only when it rewrites the merged start
        // in place; an append-only completion is drawn in full.
        let mergesIntoPreview = lifecycle.isCompletion
            ? (previewMergedToolCallID == toolCall.id && shouldRewriteActiveBlock)
            : previewMergedToolCallID == toolCall.id
        let previewMerge: TerminalChat.CompactToolPreviewMerge = mergesIntoPreview
            ? .header
            : .none
        var summaryIsStatusOnly = false
        var renderRows = toolBlockRows(
            for: toolCall,
            lifecycle: lifecycle,
            contentInsetWidth: contentInsetWidth,
            columnWidth: columnWidth,
            previewMerge: previewMerge
        )
        if !lifecycle.isCompletion, standardErrorIsTerminal,
           toolCall.name == "local.multiRead",
           !ToolCallPresentation.displayToolTargets(for: toolCall).isEmpty,
           let capacity = replaceableToolRowCapacity(maximumInPlaceRows) {
            func rowCount(_ rows: [TerminalChat.DetailedToolRow]) -> Int {
                TerminalTextMetrics.renderedTerminalRowCount(
                    for: rows.map(\.plainText),
                    contentInsetWidth: contentInsetWidth,
                    columnWidth: columnWidth
                )
            }
            if rowCount(renderRows.allRows) > capacity, let status = renderRows.compactRows.last {
                guard capacity > 0, rowCount([status]) <= capacity else {
                    // No pending row can remain reachable after its newline.
                    // Render only the complete block once the call finishes.
                    toolState.activeBlock = nil
                    toolState.activeBlockIsSubAgentTool = false
                    if previewMergedToolCallID == toolCall.id {
                        previewMergedToolCallID = nil
                    }
                    return
                }
                // Keep a recognizable header when it fits, otherwise keep only
                // the status. The full list is always rendered at completion.
                let summary = previewMerge == .none && renderRows.compactRows.count > 1
                    ? [renderRows.compactRows[0], status] : [status]
                renderRows.compactRows = rowCount(summary) <= capacity ? summary : [status]
                summaryIsStatusOnly = renderRows.compactRows.count == 1
                renderRows.detailRows = []
            }
        }
        let pendingOwnership: (rows: Int, cursorState: CursorState)?
        if lifecycle.isCompletion {
            pendingOwnership = nil
        } else {
            pendingOwnership = (
                rows: TerminalTextMetrics.renderedTerminalRowCount(
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

            if shouldRewriteActiveBlock, let activeBlock,
               clearOwnedRows(activeBlock.rows, expectedAnchor: activeBlock.screenAnchor) {
                restoreCursorState(
                    activeBlock.cursorStateBeforeRender,
                    for: .standardError
                )
            }
            if previewMergedToolCallID == toolCall.id {
                previewMergedToolCallID = nil
            }
        }

        writeToolBlockRows(
            renderRows,
            for: toolCall,
            lifecycle: lifecycle,
            titleRowCount: (previewMerge != .none
                && ToolCallPresentation.displayToolTarget(for: toolCall) != nil)
                || summaryIsStatusOnly ? 0 : 1
        )
        if let pendingOwnership {
            toolState.activeBlock = ActiveToolBlock(
                toolCall: toolCall,
                id: toolCall.id,
                rows: pendingOwnership.rows,
                columnWidth: columnWidth,
                maximumInPlaceRows: maximumInPlaceRows,
                cursorStateBeforeRender: pendingOwnership.cursorState,
                writeSequence: emittedWriteCount,
                screenAnchor: lastScreenReceipt
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
        columnWidth: Int,
        previewMerge: TerminalChat.CompactToolPreviewMerge
    ) -> TerminalChat.ToolPresentationRows {
        let result: DirectAgentToolResult?
        switch lifecycle {
        case .started:
            result = nil
        case let .completed(completedResult, _):
            result = completedResult
        }
        return TerminalChat.toolPresentationRows(
            for: toolCall,
            result: result,
            statusDetail: lifecycle.compactStatusDetail,
            contentInsetWidth: contentInsetWidth,
            columnWidth: columnWidth,
            // Both lifecycles stay compact. Captured source evidence is shown
            // only on demand by /artifacts, never from mutation arguments.
            includesSourceChanges: false,
            previewMerge: previewMerge
        )
    }

    private func writeToolBlockRows(
        _ renderRows: TerminalChat.ToolPresentationRows,
        for toolCall: DirectAgentToolCall,
        lifecycle: ToolBlockLifecycle,
        titleRowCount: Int
    ) {
        TerminalOutputSynchronization.withTransaction {
            writeCompactToolLines(
                renderRows.compactRows.map(\.plainText),
                newline: lifecycle.isCompletion && renderRows.detailRows.isEmpty,
                titleRowCount: titleRowCount
            )
            guard !renderRows.detailRows.isEmpty else { return }
            writeToolBlock(
                renderRows.detailRows,
                contentWidth: renderRows.detailContentWidth,
                codeLanguage: ToolLanguageHint.hint(for: toolCall)
            )
            if lifecycle.isCompletion { writeChat("\n", to: .standardError) }
        }
    }

    private func writeCompactToolLines(
        _ lines: [String],
        newline: Bool = false,
        terminator: String = "\n",
        titleRowCount: Int = 1
    ) {
        let text = TerminalChat.compactToolTerminalText(
            lines,
            lineInset: lineInset,
            newline: newline,
            terminator: terminator,
            titleRowCount: titleRowCount
        )
        writeRawChatError(text)
    }

    private func writeToolBlock(
        _ rows: [TerminalChat.DetailedToolRow],
        contentWidth: Int,
        codeLanguage: String? = nil
    ) {
        let reset = TerminalStyle.reset
        let text = rows
            .map {
                let rendered = TerminalChat.renderDetailedToolRow(
                    $0,
                    codeLanguage: codeLanguage,
                    contentWidth: contentWidth
                )
                return "\(lineInset)\(rendered)\(reset)"
            }
            .joined(separator: "\n")
        writeRawChatError("\(text)\n")
    }

    /// Removes only the rows occupied by a block this coordinator owns before
    /// redrawing it. `CSI J` would erase from the transcript into the reserved
    /// input panel.
    @discardableResult
    func clearOwnedRows(_ rowCount: Int, expectedAnchor: TerminalPrimaryScreen.Anchor? = nil) -> Bool {
        let count = max(1, rowCount)
        if let screen = primaryScreen(for: .standardError) {
            flushPendingStreamingWrites()
            emittedWriteCount &+= 1
            let removed = screen.removeOwnedTail(rows: count + ownedTailGapRows, expectedAnchor: expectedAnchor)
            ownedTailGapRows = 0
            return removed
        }
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
        return true
    }

    func interruptActiveToolForInterleavedOutputIfNeeded() {
        guard toolState.activeBlock != nil else {
            return
        }
        finishActiveToolOutputBeforeInterleavedMessage()
    }

    func finishActiveToolOutputBeforeInterleavedMessage() {
        if toolState.activeBlock != nil {
            toolState.activeBlock = nil
            toolState.activeBlockIsSubAgentTool = false
            writeChat("\n", to: .standardError)
        }
        flushToolAdjacentSystemMessagesIfPossible()
    }

    /// Removes a pending tool before an external authorization card takes the
    /// terminal cursor. Unlike an ordinary interleaved message, the card itself
    /// replaces the pending presentation while consent is outstanding; the
    /// eventual completion will therefore be the tool's single visible block.
    func clearActiveToolBeforeExternalTerminalPrompt(
        maximumInPlaceRows: Int?
    ) {
        flushChatOutput()
        guard let block = toolState.activeBlock else {
            flushToolAdjacentSystemMessagesIfPossible()
            return
        }
        toolState.activeBlock = nil
        toolState.activeBlockIsSubAgentTool = false
        defer { flushToolAdjacentSystemMessagesIfPossible() }

        let columnWidth = freshColumnWidthProvider()
        let maximumReplaceableRows = min(
            replaceableToolRowCapacity(block.maximumInPlaceRows) ?? Int.max,
            replaceableToolRowCapacity(maximumInPlaceRows) ?? Int.max
        )
        guard standardErrorIsTerminal,
              ownsScreenReceipt(block.screenAnchor),
              block.writeSequence == emittedWriteCount,
              block.columnWidth == columnWidth,
              block.rows <= maximumReplaceableRows else {
            // Geometry is no longer trustworthy. Forget the relative anchor;
            // retaining the old rows is safer than erasing transcript or card
            // content with a speculative cursor movement.
            return
        }
        guard clearOwnedRows(block.rows, expectedAnchor: block.screenAnchor) else { return }
        restoreCursorState(block.cursorStateBeforeRender, for: .standardError)
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
              ownsScreenReceipt(block.screenAnchor),
              block.writeSequence == emittedWriteCount,
              block.columnWidth == columnWidth,
              block.rows <= maximumReplaceableRows else {
            // The old block cannot be removed with certainty. Forget its relative
            // anchor so completion degrades to an append-only presentation.
            return
        }

        guard clearOwnedRows(block.rows, expectedAnchor: block.screenAnchor) else { return }
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
        let maximumReplaceableRows = replaceableToolRowCapacity(maximumInPlaceRows)
            ?? Int.max
        for deferred in deferredRenders {
            if let requiredRows = deferred.requiredRows,
               requiredRows > maximumReplaceableRows {
                guard deferred.toolCall.name == "local.multiRead",
                      !ToolCallPresentation.displayToolTargets(for: deferred.toolCall).isEmpty,
                      maximumReplaceableRows > 0 else {
                    continue
                }
                let insetWidth = TerminalTextMetrics.displayWidth(lineInset)
                let columnWidth = columnWidthProvider()
                let status = TerminalChat.compactToolStatusOnlyLine(
                    statusIcon: "⏳", contentInsetWidth: insetWidth, columnWidth: columnWidth
                )
                let summaryRows = TerminalTextMetrics.renderedTerminalRowCount(
                    for: [status], contentInsetWidth: insetWidth, columnWidth: columnWidth
                )
                guard summaryRows <= maximumReplaceableRows else {
                    // The new region cannot own this detached block, or even a
                    // multi-read status. Leave completion append-only instead.
                    continue
                }
            }
            finishThoughtOutputIfNeeded()
            finishAssistantContentFormatting()
            clearOwnedSubAgentOverviewBeforeInterleavedOutput(
                maximumInPlaceRows: maximumInPlaceRows
            )
            if deferred.preparesOutput {
                if previewAlreadyShowedHeader(for: deferred.toolCall) {
                    flushChatOutput()
                } else {
                    prepareForToolOutput()
                }
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
        flushToolAdjacentSystemMessagesIfPossible()
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
              ownsScreenReceipt(block.screenAnchor),
              block.writeSequence == emittedWriteCount,
              block.columnWidth == columnWidth,
              block.rows <= maximumReplaceableRows else {
            // The pending rows are no longer cursor-reachable. Preserve them
            // append-safely rather than risking transcript erasure.
            writeChat("\n", to: .standardError)
            return
        }
        guard clearOwnedRows(block.rows, expectedAnchor: block.screenAnchor) else { return }
        restoreCursorState(block.cursorStateBeforeRender, for: .standardError)
    }

}
