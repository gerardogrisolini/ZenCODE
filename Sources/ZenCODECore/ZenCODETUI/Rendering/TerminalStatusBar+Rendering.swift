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
    func configureTerminalLocked(moveCursorToPrompt: Bool = true) -> Bool {
        guard let output,
              let geometry = Self.currentTerminalGeometry(fileDescriptor: output.fileDescriptor),
              geometry.rows >= minimumRowsLocked(),
              geometry.columns >= 40 else {
            return false
        }
        
        row = geometry.rows
        columns = geometry.columns
        writeScrollRegionLocked(moveCursorToPrompt: moveCursorToPrompt)
        return true
    }
    
    func refreshTerminalGeometryLocked() -> Bool {
        guard let output,
              let geometry = Self.currentTerminalGeometry(fileDescriptor: output.fileDescriptor),
              geometry.rows >= minimumRowsLocked(),
              geometry.columns >= 40 else {
            return false
        }
        guard geometry.rows != row || geometry.columns != columns else {
            return true
        }
        
        let oldColumns = columns
        let oldReservedRows = reservedBottomRowsLocked()
        row = geometry.rows
        columns = geometry.columns
        let newReservedRows = reservedBottomRowsLocked()
        let oldRowWrapFactor = max(1, (oldColumns + geometry.columns - 1) / geometry.columns)
        let rowsToClear = min(
            row,
            max(newReservedRows, oldReservedRows * oldRowWrapFactor) + 2
        )
        clearReservedRowsLocked(
            count: rowsToClear,
            bottomRow: row
        )
        writeScrollRegionLocked(moveCursorToPrompt: true)
        return true
    }
    
    func writeScrollRegionLocked(moveCursorToPrompt: Bool) {
        let scrollBottom = max(1, row - reservedBottomRowsLocked())
        let scrollTop = 1
        var sequence = "\u{1B}[\(scrollTop);\(scrollBottom)r"
        if moveCursorToPrompt {
            sequence += "\u{1B}[\(scrollBottom);1H"
        }
        writeLocked(sequence)
    }
    
    func scrollOutputRegionUpLocked(by count: Int, reservedRows: Int) {
        guard count > 0, row > reservedRows else {
            return
        }
        
        let scrollBottom = max(1, row - reservedRows)
        let scrollTop = 1
        let newlines = String(repeating: "\n", count: count)
        writeLocked(
            "\u{1B}[\(scrollTop);\(scrollBottom)r"
            + "\u{1B}[\(scrollBottom);1H"
            + newlines
        )
    }
    
    func renderLocked() {
        guard row > 0, columns > 0, !isResizePending else {
            return
        }
        
        let sequence = "\u{1B}[?25l" + inputPanelRenderSequenceLocked() + statusRenderSequenceLocked()
        writeLocked(sequence)
    }
    
    func inputPanelRenderSequenceLocked() -> String {
        guard let inputPanelState else {
            return ""
        }
        
        let topRow = max(1, row - reservedBottomRowsLocked() + 1)
        let startColumn = statusBoxStartColumnLocked()
        let boxWidth = statusBoxWidthLocked()
        let orange = "\u{1B}[38;5;208m"
        let dim = "\u{1B}[90m"
        let reset = "\u{1B}[0m"
        let horizontalRule = String(repeating: "─", count: max(0, boxWidth - 2))
        let contentWidth = statusBoxContentWidthLocked()
        let inputRows = inputPanelDisplayRowsLocked(
            text: inputPanelState.text,
            cursorIndex: inputPanelState.cursorIndex
        )
        let suggestionRows = inputPanelSuggestionRowsLocked(
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
    
    func statusRenderSequenceLocked() -> String {
        let startColumn = statusBoxStartColumnLocked()
        let boxWidth = statusBoxWidthLocked()
        let contentWidth = statusBoxContentWidthLocked()
        let orange = "\u{1B}[38;5;208m"
        let reset = "\u{1B}[0m"
        let horizontalRule = String(repeating: "─", count: max(0, boxWidth - 2))
        let text = Self.fit(statusTextLocked(), width: contentWidth)
        let padding = max(0, contentWidth - Self.visibleCharacterCount(text))
        let isAttachedToInputPanel = inputPanelState != nil
        var sequence = "\u{1B}7"
        if !isAttachedToInputPanel {
            sequence += "\u{1B}[\(max(1, row - 2));\(startColumn)H"
            + "\u{1B}[2K"
            + orange
            + "┌"
            + horizontalRule
            + "┐"
            + reset
        }
        sequence += "\u{1B}[\(max(1, row - 1));\(startColumn)H"
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
        + "\u{1B}[\(row);\(startColumn)H"
        + "\u{1B}[2K"
        + orange
        + "└"
        + horizontalRule
        + "┘"
        + reset
        + "\u{1B}8"
        return sequence
    }
    
    func clearLocked() {
        clearLocked(row: row)
    }
    
    func clearLocked(row: Int) {
        guard row > 0 else {
            return
        }
        clearReservedRowsLocked(count: reservedBottomRowsLocked(), bottomRow: row)
    }
    
    func clearReservedRowsLocked(count: Int, bottomRow: Int? = nil) {
        let resolvedBottomRow = bottomRow ?? row
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
    
    func reservedBottomRowsLocked() -> Int {
        guard let inputPanelState else {
            return Self.standaloneStatusRows
        }
        return Self.inputPanelChromeRows
        + inputPanelDisplayLineCountLocked(
            text: inputPanelState.text,
            cursorIndex: inputPanelState.cursorIndex
        )
        + inputPanelState.suggestionLines.count
        + Self.attachedStatusRows
    }
    
    func minimumRowsLocked() -> Int {
        let minimumReservedRows: Int
        if inputPanelState == nil {
            minimumReservedRows = Self.standaloneStatusRows
        } else {
            minimumReservedRows = Self.inputPanelChromeRows + Self.attachedStatusRows + 1
        }
        return max(5, minimumReservedRows + Self.minimumScrollableRows)
    }
    
    func statusTextLocked() -> String {
        let tokensUsed = latestContextWindow?.usedTokens
        ?? latestMetrics?.totalTokenCount
        var fragments: [String] = []
        if let latestModelID {
            let model = Self.modelStatusFragment(
                modelID: latestModelID,
                thinkingSelection: latestThinkingSelection
            )
            if isProcessing {
                let loader = Self.spinnerFrames[spinnerIndex % Self.spinnerFrames.count]
                fragments.append(loader)
            }
            fragments.append(model)
        }
        if let latestModelRuntime {
            fragments.append(latestModelRuntime)
        }
        if tokensUsed != nil || latestContextWindow?.maxTokens != nil {
            let contextText = Self.tokenWindowText(
                usedTokens: latestContextWindow?.usedTokens,
                metricUsedTokens: tokensUsed,
                maxTokens: latestContextWindow?.maxTokens
            )
            fragments.append(contextText)
        }
        if let duration = latestMetrics?.responseDurationSeconds {
            fragments.append("time \(Self.durationText(duration))")
        }
        if let prefillRate = latestMetrics?.promptTokensPerSecond {
            fragments.append("pre \(Self.rateText(prefillRate)) tok/s")
        }
        if let generationRate = latestMetrics?.completionTokensPerSecond {
            fragments.append("gen \(Self.rateText(generationRate)) tok/s")
        }
        if let latestSubscriptionUsage,
           let usageText = Self.subscriptionUsageFragment(latestSubscriptionUsage) {
            fragments.append(usageText)
        }
        if let latestGitStatusSummary {
            fragments.append(Self.gitStatusFragment(summary: latestGitStatusSummary))
        }
        return fragments.joined(separator: " · ")
    }
    
}
