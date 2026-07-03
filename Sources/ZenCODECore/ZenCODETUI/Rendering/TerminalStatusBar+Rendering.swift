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
        guard let output,
              let geometry = Self.currentTerminalGeometry(fileDescriptor: output.fileDescriptor),
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
        guard let output,
              let geometry = Self.currentTerminalGeometry(fileDescriptor: output.fileDescriptor),
              geometry.rows >= minimumRowsLocked(state: &state),
              geometry.columns >= 40 else {
            return false
        }
        guard geometry.rows != state.row || geometry.columns != state.columns else {
            return true
        }
        
        let oldColumns = state.columns
        let oldReservedRows = reservedBottomRowsLocked(state: &state)
        state.row = geometry.rows
        state.columns = geometry.columns
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
        
        let sequence = "\u{1B}[?25l" + inputPanelRenderSequenceLocked(state: &state) + statusRenderSequenceLocked(state: &state)
        writeLocked(sequence)
    }
    
    func inputPanelRenderSequenceLocked(state: inout State) -> String {
        guard let inputPanelState = state.inputPanelState else {
            return ""
        }
        
        let reservedRows = reservedBottomRowsLocked(state: &state)
        let topRow = max(1, state.row - reservedRows + 1)
        let startColumn = statusBoxStartColumnLocked(state: &state)
        let boxWidth = statusBoxWidthLocked(state: &state)
        let orange = "\u{1B}[38;5;208m"
        let dim = "\u{1B}[90m"
        let reset = "\u{1B}[0m"
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
            Self.fit(
                "\(inputPanelState.modeText) · \(inputPanelState.helpText)",
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
            "┌",
            horizontalRule,
            "┐",
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
    
    func statusRenderSequenceLocked(state: inout State) -> String {
        let startColumn = statusBoxStartColumnLocked(state: &state)
        let boxWidth = statusBoxWidthLocked(state: &state)
        let contentWidth = statusBoxContentWidthLocked(state: &state)
        let orange = "\u{1B}[38;5;208m"
        let reset = "\u{1B}[0m"
        let horizontalRule = String(repeating: "─", count: max(0, boxWidth - 2))
        let text = Self.fit(statusTextLocked(state: &state), width: contentWidth)
        let padding = max(0, contentWidth - Self.visibleCharacterCount(text))
        let isAttachedToInputPanel = state.inputPanelState != nil
        var sequence = "\u{1B}7"
        if !isAttachedToInputPanel {
            sequence += "\u{1B}[\(max(1, state.row - 2));\(startColumn)H"
            + "\u{1B}[2K"
            + orange
            + "┌"
            + horizontalRule
            + "┐"
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
        + "└"
        + horizontalRule
        + "┘"
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
        return Self.inputPanelChromeRows
        + inputPanelDisplayLineCountLocked(
            state: &state,
            text: inputPanelState.text,
            cursorIndex: inputPanelState.cursorIndex
        )
        + inputPanelState.suggestionLines.count
        + Self.attachedStatusRows
    }
    
    func minimumRowsLocked(state: inout State) -> Int {
        let minimumReservedRows: Int
        if state.inputPanelState == nil {
            minimumReservedRows = Self.standaloneStatusRows
        } else {
            minimumReservedRows = Self.inputPanelChromeRows + Self.attachedStatusRows + 1
        }
        return max(5, minimumReservedRows + Self.minimumScrollableRows)
    }
    
    func statusTextLocked(state: inout State) -> String {
        let tokensUsed = state.latestContextWindow?.usedTokens
        ?? state.latestMetrics?.totalTokenCount
        var fragments: [String] = []
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
        if let latestModelRuntime = state.latestModelRuntime {
            fragments.append(latestModelRuntime)
        }
        if tokensUsed != nil || state.latestContextWindow?.maxTokens != nil {
            let contextText = Self.tokenWindowText(
                usedTokens: state.latestContextWindow?.usedTokens,
                metricUsedTokens: tokensUsed,
                maxTokens: state.latestContextWindow?.maxTokens
            )
            fragments.append(contextText)
        }
        if let duration = state.latestMetrics?.responseDurationSeconds {
            fragments.append("time \(Self.durationText(duration))")
        }
        if let prefillRate = state.latestMetrics?.promptTokensPerSecond {
            fragments.append("pre \(Self.rateText(prefillRate)) tok/s")
        }
        if let generationRate = state.latestMetrics?.completionTokensPerSecond {
            fragments.append("gen \(Self.rateText(generationRate)) tok/s")
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
    
}
