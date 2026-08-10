//
//  TerminalStatusBar+Rendering.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 28/05/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation
#if canImport(os)
import os
#endif

extension TerminalStatusBar {
    func configureTerminalLocked(state: inout State, moveCursorToPrompt: Bool = true) -> Bool {
        let fileDescriptor = output?.fileDescriptor ?? 1
        guard let geometry = Self.currentTerminalGeometry(fileDescriptor: fileDescriptor),
              geometry.rows >= minimumRowsLocked(state: &state),
              geometry.columns >= 40 else {
            return false
        }
        
        state.row = geometry.rows
        state.columns = geometry.columns
        writeScrollRegionLocked(state: &state, moveCursorToPrompt: moveCursorToPrompt)
        return true
    }
    
    func refreshTerminalGeometryLocked(state: inout State) -> Bool {
        let fileDescriptor = output?.fileDescriptor ?? 1
        guard let geometry = Self.currentTerminalGeometry(fileDescriptor: fileDescriptor)
        else {
            invalidateTerminalGeometryLocked(state: &state)
            return false
        }
        guard geometry.rows >= minimumRowsLocked(state: &state),
              geometry.columns >= 40 else {
            invalidateTerminalGeometryLocked(state: &state)
            return false
        }
        guard geometry.rows != state.row || geometry.columns != state.columns else {
            return true
        }
        
        let oldColumns = state.columns
        let oldReservedRows = reservedBottomRowsLocked(state: &state)
        state.row = geometry.rows
        state.columns = geometry.columns
        // Geometry changed: invalidate the status cache so the next render is not suppressed.
        state.lastStatusRender = nil
        let newReservedRows = reservedBottomRowsLocked(state: &state)
        let oldRowWrapFactor = max(1, (oldColumns + geometry.columns - 1) / geometry.columns)
        let rowsToClear = min(
            state.row,
            max(newReservedRows, oldReservedRows * oldRowWrapFactor) + 2
        )
        clearReservedRowsLocked(
            state: &state,
            count: rowsToClear,
            bottomRow: state.row
        )
        writeScrollRegionLocked(state: &state, moveCursorToPrompt: true)
        return true
    }

    func invalidateTerminalGeometryLocked(state: inout State) {
        state.row = 0
        state.columns = 0
        state.lastStatusRender = nil
        writeLocked("\u{1B}[r\u{1B}[?25h")
    }
    
    func writeScrollRegionLocked(state: inout State, moveCursorToPrompt: Bool) {
        let reservedRows = reservedBottomRowsLocked(state: &state)
        let scrollBottom = max(1, state.row - reservedRows)
        let scrollTop = 1
        var sequence = "\u{1B}[\(scrollTop);\(scrollBottom)r"
        if moveCursorToPrompt {
            sequence += "\u{1B}[\(scrollBottom);1H"
        }
        writeLocked(sequence)
    }
    
    func scrollOutputRegionUpLocked(state: inout State, by count: Int, reservedRows: Int) {
        guard count > 0, state.row > reservedRows else {
            return
        }
        
        let scrollBottom = max(1, state.row - reservedRows)
        let scrollTop = 1
        let newlines = String(repeating: "\n", count: count)
        writeLocked(
            "\u{1B}[\(scrollTop);\(scrollBottom)r"
            + "\u{1B}[\(scrollBottom);1H"
            + newlines
        )
    }
    
    func renderLocked(state: inout State) {
        guard state.row > 0, state.columns > 0, !state.isResizePending else {
            return
        }
        
        let statusSequence = statusRenderSequenceLocked(state: &state)
        // The full render paints both input panel and status, so update the
        // status cache to the sequence just written. Subsequent status-only
        // renders with identical content will be suppressed.
        state.lastStatusRender = statusSequence
        let sequence = "\u{1B}[?25l" + sharedChatReaderRenderSequenceLocked(state: &state) + inputPanelRenderSequenceLocked(state: &state) + statusSequence
        writeLocked(sequence)
    }

    /// Status-only invalidation used by spinner and metrics updates. The input
    /// panel layout is unchanged, so rebuilding and repainting it would only add
    /// allocations and terminal traffic.
    func renderStatusLocked(state: inout State) {
        guard state.row > 0, state.columns > 0, !state.isResizePending else {
            return
        }
        let sequence = statusRenderSequenceLocked(state: &state)
        guard state.lastStatusRender != sequence else {
            return
        }
        state.lastStatusRender = sequence
        writeLocked(sequence)
    }
    
    func sharedChatReaderViewportRowsLocked(state: inout State) -> Int {
        max(0, sharedChatReaderReservedRowsLocked(state: &state) - 2)
    }

    func sharedChatReaderReservedRowsLocked(state: inout State) -> Int {
        guard let dock = state.sharedChatReaderDock, state.inputPanelState != nil else { return 0 }

        // Reserve the minimum usable editor (one text row) before allocating
        // the dock.  A dock gets header/body/footer together; when that does
        // not fit it degrades to its header only, never stealing scroll rows.
        let available = state.row
            - Self.minimumScrollableRows
            - Self.inputPanelChromeRows
            - Self.attachedStatusRows
            - inputPanelSuggestionRowCountLocked(state: &state)
            - 1
        guard available > 0 else { return 0 }
        let fullDockRows = min(
            8,
            dock.rows(width: statusBoxContentWidthLocked(state: &state)).count + 2,
            available
        )
        return fullDockRows >= 3 ? fullDockRows : 1
    }

    func sharedChatReaderRenderSequenceLocked(state: inout State) -> String {
        guard var dock = state.sharedChatReaderDock else { return "" }
        let width = statusBoxContentWidthLocked(state: &state)
        let viewport = sharedChatReaderViewportRowsLocked(state: &state)
        dock.clamp(viewportRows: viewport, width: width)
        state.sharedChatReaderDock = dock
        let top = max(1, state.row - reservedBottomRowsLocked(state: &state) + 1)
        let start = statusBoxStartColumnLocked(state: &state)
        let rows = dock.rows(width: width)
        let visible = Array(rows.dropFirst(dock.scrollOffset).prefix(viewport))
        let headerText: String
        if dock.entries.isEmpty {
            headerText = "Shared chat · 0 messages · Ctrl+Y close"
        } else {
            headerText = "Shared chat · \(dock.selectedIndex + 1)/\(dock.entries.count) · \(dock.unreadCount) unread · Ctrl+Y close"
        }
        guard sharedChatReaderReservedRowsLocked(state: &state) > 0 else { return "" }
        // Match the transient shared-chat message card: it deliberately uses
        // the light-blue shared-chat palette rather than the orange input
        // chrome, so the dock and transcript are one visual surface.
        let palette = TerminalStyle.SharedChat.palette(for: TerminalMarkdownPalette.detected.appearance)
        let boxWidth = statusBoxWidthLocked(state: &state)
        let topTitle = Self.fit(headerText, width: max(1, boxWidth - 5))
        let topRule = String(repeating: "─", count: max(0, boxWidth - TerminalChat.displayWidth(topTitle) - 5))
        let header = "\(palette.border)╭─ \(palette.title)\(topTitle)\(palette.border) \(topRule)╮\(TerminalStyle.reset)"
        let footerText = Self.fit("↑/↓ scroll · ←/→ message · Home/End first/last", width: max(1, boxWidth - 5))
        let footerRule = String(repeating: "─", count: max(0, boxWidth - TerminalChat.displayWidth(footerText) - 5))
        let footer = "\(palette.border)╰─ \(palette.body)\(footerText)\(palette.border) \(footerRule)╯\(TerminalStyle.reset)"
        var sequence = "\u{1B}7"
        let lines = viewport > 0
            ? [header] + visible.map {
                "\(palette.border)│\(TerminalStyle.reset) \(palette.body)\(Self.padded(Self.fit($0, width: width), width: width))\(TerminalStyle.reset) \(palette.border)│\(TerminalStyle.reset)"
            } + [footer]
            : [header]
        for (offset, line) in lines.enumerated() {
            sequence += "\u{1B}[\(top + offset);\(start)H\u{1B}[2K" + line
        }
        sequence += "\u{1B}8"
        return sequence
    }

    func inputPanelRenderSequenceLocked(state: inout State) -> String {
        guard let inputPanelState = state.inputPanelState else {
            return ""
        }
        
        let reservedRows = reservedBottomRowsLocked(state: &state)
        let topRow = max(1, state.row - reservedRows + 1) + sharedChatReaderReservedRowsLocked(state: &state)
        let startColumn = statusBoxStartColumnLocked(state: &state)
        let boxWidth = statusBoxWidthLocked(state: &state)
        let orange = TerminalStyle.Chrome.border
        let dim = TerminalStyle.Chrome.suggestion
        let reset = TerminalStyle.reset
        let horizontalRule = String(repeating: "─", count: max(0, boxWidth - 2))
        let contentWidth = statusBoxContentWidthLocked(state: &state)
        let inputRows = inputPanelDisplayRowsLocked(
            state: &state,
            text: inputPanelState.text,
            cursorIndex: inputPanelState.cursorIndex
        )
        let suggestionRows = inputPanelSuggestionRowsLocked(
            state: &state,
            lines: inputPanelState.suggestionLines
        )
        let modeLine = Self.padded(
            Self.inputPanelModeLineText(
                modeText: inputPanelState.modeText,
                helpText: inputPanelState.helpText,
                compactHelpText: inputPanelState.compactHelpText,
                width: contentWidth
            ),
            width: contentWidth
        )
        
        let inputSequence = inputRows.enumerated().map { offset, inputRow in
            [
                "\u{1B}[\(topRow + offset + 1);\(startColumn)H",
                "\u{1B}[2K",
                orange,
                "│",
                reset,
                " ",
                inputRow,
                " ",
                orange,
                "│",
                reset
            ].joined()
        }.joined()
        let suggestionSequence = suggestionRows.enumerated().map { offset, suggestionRow in
            [
                "\u{1B}[\(topRow + inputRows.count + offset + 1);\(startColumn)H",
                "\u{1B}[2K",
                orange,
                "│",
                reset,
                " ",
                dim,
                suggestionRow,
                reset,
                " ",
                orange,
                "│",
                reset
            ].joined()
        }.joined()
        let modeRow = topRow + inputRows.count + suggestionRows.count + 1
        let parts = [
            "\u{1B}7",
            "\u{1B}[\(topRow);\(startColumn)H",
            "\u{1B}[2K",
            orange,
            "╭",
            horizontalRule,
            "╮",
            reset,
            inputSequence,
            suggestionSequence,
            "\u{1B}[\(modeRow);\(startColumn)H",
            "\u{1B}[2K",
            orange,
            "│",
            reset,
            " ",
            dim,
            modeLine,
            reset,
            " ",
            orange,
            "│",
            reset,
            "\u{1B}[\(modeRow + 1);\(startColumn)H",
            "\u{1B}[2K",
            orange,
            "├",
            horizontalRule,
            "┤",
            reset,
            "\u{1B}8"
        ]
        return parts.joined()
    }

    static func inputPanelModeLineText(
        modeText: String,
        helpText: String,
        compactHelpText: String?,
        width: Int
    ) -> String {
        let fullText = "\(modeText) · \(helpText)"
        guard visibleCharacterCount(fullText) > width,
              let compactHelpText else {
            return fit(fullText, width: width)
        }
        return fit("\(modeText) · \(compactHelpText)", width: width)
    }
    
    func statusRenderSequenceLocked(state: inout State) -> String {
        let startColumn = statusBoxStartColumnLocked(state: &state)
        let boxWidth = statusBoxWidthLocked(state: &state)
        let contentWidth = statusBoxContentWidthLocked(state: &state)
        let orange = TerminalStyle.Chrome.border
        let reset = TerminalStyle.reset
        let horizontalRule = String(repeating: "─", count: max(0, boxWidth - 2))
        let text = Self.fit(statusTextLocked(state: &state), width: contentWidth)
        let padding = max(0, contentWidth - Self.visibleCharacterCount(text))
        let isAttachedToInputPanel = state.inputPanelState != nil
        var sequence = "\u{1B}7"
        if !isAttachedToInputPanel {
            sequence += "\u{1B}[\(max(1, state.row - 2));\(startColumn)H"
            + "\u{1B}[2K"
            + orange
            + "╭"
            + horizontalRule
            + "╮"
            + reset
        }
        sequence += "\u{1B}[\(max(1, state.row - 1));\(startColumn)H"
        + "\u{1B}[2K"
        + orange
        + "│"
        + reset
        + " "
        + text
        + String(repeating: " ", count: padding)
        + " "
        + orange
        + "│"
        + reset
        + "\u{1B}[\(state.row);\(startColumn)H"
        + "\u{1B}[2K"
        + orange
        + "╰"
        + horizontalRule
        + "╯"
        + reset
        + "\u{1B}8"
        return sequence
    }
    
    func clearLocked(state: inout State) {
        clearLocked(state: &state, row: state.row)
    }
    
    func clearLocked(state: inout State, row: Int) {
        guard row > 0 else {
            return
        }
        let reservedRows = reservedBottomRowsLocked(state: &state)
        clearReservedRowsLocked(state: &state, count: reservedRows, bottomRow: row)
    }
    
    func clearReservedRowsLocked(state: inout State, count: Int, bottomRow: Int? = nil) {
        let resolvedBottomRow = bottomRow ?? state.row
        guard resolvedBottomRow > 0, count > 0 else {
            return
        }
        let firstRow = max(1, resolvedBottomRow - count + 1)
        var sequence = "\u{1B}7"
        for rowIndex in firstRow...resolvedBottomRow {
            sequence += "\u{1B}[\(rowIndex);1H\u{1B}[2K"
        }
        sequence += "\u{1B}8"
        writeLocked(sequence)
    }
    
    func reservedBottomRowsLocked(state: inout State) -> Int {
        guard let inputPanelState = state.inputPanelState else {
            return Self.standaloneStatusRows
        }
        return sharedChatReaderReservedRowsLocked(state: &state)
        + Self.inputPanelChromeRows
        + inputPanelDisplayLineCountLocked(
            state: &state,
            text: inputPanelState.text,
            cursorIndex: inputPanelState.cursorIndex
        )
        + inputPanelSuggestionRowCountLocked(state: &state)
        + Self.attachedStatusRows
    }
    
    func minimumRowsLocked(state: inout State) -> Int {
        let minimumReservedRows: Int
        if state.inputPanelState == nil {
            minimumReservedRows = Self.standaloneStatusRows
        } else {
            // Geometry must remain valid for short (8-row) terminals even
            // when a dock is open: the dock can be omitted/header-only.
            minimumReservedRows = Self.inputPanelChromeRows + Self.attachedStatusRows + 1
        }
        return max(5, minimumReservedRows + Self.minimumScrollableRows)
    }
    
    nonisolated func statusTextLocked(state: inout State) -> String {
        let tokensUsed = state.latestContextWindow?.usedTokens
        ?? state.latestMetrics?.totalTokenCount
        var fragments: [String] = []
        if let accessModeFragment = Self.accessModeStatusFragment(state.localExecAccessMode) {
            fragments.append(accessModeFragment)
        }
        if let latestModelID = state.latestModelID {
            let model = Self.modelStatusFragment(
                modelID: latestModelID,
                thinkingSelection: state.latestThinkingSelection
            )
            if state.isProcessing {
                let loader = Self.spinnerFrames[state.spinnerIndex % Self.spinnerFrames.count]
                fragments.append(loader)
            }
            fragments.append(model)
        }
        if tokensUsed != nil || state.latestContextWindow?.maxTokens != nil {
            let contextText = Self.tokenWindowText(
                usedTokens: state.latestContextWindow?.usedTokens,
                metricUsedTokens: tokensUsed,
                maxTokens: state.latestContextWindow?.maxTokens
            )
            fragments.append(contextText)
        }
        if state.isProcessing, let startInstant = state.processingStartInstant {
            // Live elapsed time while the request is running. Whole seconds keep
            // the fragment stable between ticks so only the spinner-driven
            // redraws (already happening) carry the once-per-second change.
            let elapsedSeconds = Double(
                startInstant.duration(to: ContinuousClock.now).components.seconds
            )
            fragments.append(Self.durationText(elapsedSeconds))
        } else if let duration = state.latestMetrics?.responseDurationSeconds {
            fragments.append(Self.durationText(duration))
        }
        if let latestMetrics = state.latestMetrics,
           let tokenCountsText = Self.generationTokenCountsFragment(latestMetrics) {
            fragments.append(tokenCountsText)
        }
        if let prefillRate = state.latestMetrics?.promptTokensPerSecond {
            fragments.append("p:\(Self.rateText(prefillRate)) t/s")
        }
        if let generationRate = state.latestMetrics?.completionTokensPerSecond {
            fragments.append("g:\(Self.rateText(generationRate)) t/s")
        }
        if let latestSubscriptionUsage = state.latestSubscriptionUsage,
           let usageText = Self.subscriptionUsageFragment(latestSubscriptionUsage) {
            fragments.append(usageText)
        }
        if let latestGitStatusSummary = state.latestGitStatusSummary {
            fragments.append(Self.gitStatusFragment(summary: latestGitStatusSummary))
        }
        return fragments.joined(separator: " · ")
    }

    static func accessModeStatusFragment(_ accessMode: AgentLocalExecAccessMode) -> String? {
        switch accessMode {
        case .standard:
            return nil
        case .fullAccess:
            return "\(TerminalStyle.Status.failure)●\(TerminalStyle.reset)"
        }
    }
    
}
