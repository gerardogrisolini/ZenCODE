//
//  TerminalChatRenderCoordinator+ToolBlocks.swift
//  ZenCODE
//

import Foundation

/// Tool lifecycle rendering. Pending rows belong to `TerminalStatusBar`; this
/// coordinator retains timing and appends immutable completion/source rows.
extension TerminalChatRenderCoordinator {
    // MARK: - Tool blocks

    func writeToolCallStarted(
        _ toolCall: DirectAgentToolCall,
        maximumInPlaceRows: Int? = nil
    ) {
        finishThoughtOutputIfNeeded()
        finishAssistantContentFormatting()
        toolState.startInstants[toolCall.id] = toolNow()
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

        // Every completion is permanent and append-only; pending presentation
        // has already been removed from the status overlay by call identity.
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

    /// Non-TTY/status-disabled fallback for pending tool activity. It is
    /// deliberately append-only and acquires no mutable row ownership.
    func writeToolCallStartedFallback(_ toolCall: DirectAgentToolCall) {
        prepareForToolOutput()
        let rows = toolBlockRows(
            for: toolCall,
            lifecycle: .started,
            contentInsetWidth: TerminalChat.displayWidth(lineInset),
            columnWidth: columnWidthProvider()
        )
        writeToolBlockRows(rows, for: toolCall, lifecycle: .started)
    }

    /// Records the latest delegated call for each agent without writing a
    /// standalone transcript block. The next live overview publication lays
    /// these calls out with the same canonical tool rows.
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
        maximumInPlaceRows _: Int?
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
        writeToolBlockRows(
            renderRows,
            for: toolCall,
            lifecycle: lifecycle
        )
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

}
