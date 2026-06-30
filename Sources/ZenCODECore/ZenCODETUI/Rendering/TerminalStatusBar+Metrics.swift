//
//  TerminalStatusBar+Metrics.swift
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
    static func modelStatusFragment(
        modelID: String,
        thinkingSelection: AgentThinkingSelection?
    ) -> String {
        let modelName = modelDisplayName(modelID)
        guard let thinkingSelection else {
            return modelName
        }
        return "\(modelName) · \(thinkingSelection.displayTitle)"
    }
    
    static func gitStatusFragment(summary: TerminalGitStatusSummary) -> String {
        let reset = "\u{1B}[0m"
        let count = "\u{1B}[38;5;81m"
        let addition = "\u{1B}[38;5;114m"
        let deletion = "\u{1B}[38;5;203m"
        return "\(count)\(summary.changedFileCount)\(reset) files "
        + "\(addition)+\(summary.additions)\(reset) "
        + "\(deletion)-\(summary.deletions)\(reset)"
    }
    
    static func modelDisplayName(_ modelID: String) -> String {
        modelID
            .split(separator: "/")
            .last
            .map(String.init) ?? modelID
    }
    
    static func runtimeDisplayName(_ runtime: String?) -> String? {
        guard let runtime = runtime?.trimmingCharacters(in: .whitespacesAndNewlines),
              !runtime.isEmpty else {
            return nil
        }
        return runtime.uppercased()
    }
    
    func mergedMetrics(
        current: DirectAgentGenerationMetrics?,
        update: DirectAgentGenerationMetrics
    ) -> DirectAgentGenerationMetrics {
        guard let current else {
            return update
        }
        return DirectAgentGenerationMetrics(
            promptTokenCount: update.clearsPromptMetrics
            ? update.promptTokenCount
            : update.promptTokenCount ?? current.promptTokenCount,
            cachedPromptTokenCount: update.clearsPromptMetrics
            ? update.cachedPromptTokenCount
            : update.cachedPromptTokenCount ?? current.cachedPromptTokenCount,
            promptTokensPerSecond: update.clearsPromptMetrics
            ? update.promptTokensPerSecond
            : update.promptTokensPerSecond ?? current.promptTokensPerSecond,
            completionTokenCount: update.completionTokenCount ?? current.completionTokenCount,
            completionTokensPerSecond: update.completionTokensPerSecond ?? current.completionTokensPerSecond,
            responseDurationSeconds: update.responseDurationSeconds ?? current.responseDurationSeconds,
            contextTokenCount: update.contextTokenCount ?? current.contextTokenCount,
            clearsPromptMetrics: update.clearsPromptMetrics
        )
    }
    
    static func tokenWindowText(
        usedTokens: Int?,
        metricUsedTokens: Int?,
        maxTokens: Int?
    ) -> String {
        let resolvedUsedTokens = usedTokens ?? metricUsedTokens
        let usedText = resolvedUsedTokens.map(contextTokenCountText) ?? "0.0k"
        guard let maxTokens, maxTokens > 0 else {
            return "\(usedText) / --"
        }
        return "\(usedText) / \(contextWindowLimitText(maxTokens))"
    }
    
    static func contextWindowLimitText(_ value: Int) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000)
        }
        if absoluteValue >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
    
    static func contextTokenCountText(_ value: Int) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000)
        }
        if absoluteValue >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
    
    static func tokenCountText(_ value: Int) -> String {
        let absoluteValue = abs(value)
        if absoluteValue >= 1_000_000 {
            return String(format: "%.1fm", Double(value) / 1_000_000)
        }
        if absoluteValue >= 10_000 {
            return "\(value / 1_000)k"
        }
        if absoluteValue >= 1_000 {
            return String(format: "%.1fk", Double(value) / 1_000)
        }
        return "\(value)"
    }
    
    static func subscriptionUsageFragment(
        _ status: DirectAgentSubscriptionUsageStatus
    ) -> String? {
        guard status.hasValues else {
            return nil
        }
        let daily = status.dailyUsedPercent.map(usagePercentText) ?? "--"
        let weekly = status.weeklyUsedPercent.map(usagePercentText) ?? "--"
        return "D:\(daily) W:\(weekly)"
    }
    
    static func usagePercentText(_ value: Double) -> String {
        guard value.isFinite else {
            return "--"
        }
        let clamped = min(max(value, 0), 100)
        if clamped >= 10 || clamped == 0 {
            return "\(Int(clamped.rounded()))%"
        }
        return String(format: "%.1f%%", clamped)
    }
    
    static func rateText(_ value: Double) -> String {
        guard value.isFinite else {
            return "--"
        }
        return String(format: "%.1f", value)
    }
    
    static func durationText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else {
            return "--"
        }
        if value < 60 {
            return String(format: "%.1fs", value)
        }
        let roundedSeconds = Int(value.rounded())
        let minutes = roundedSeconds / 60
        let seconds = roundedSeconds % 60
        if minutes < 60 {
            return String(format: "%d:%02d", minutes, seconds)
        }
        let hours = minutes / 60
        return String(format: "%d:%02d:%02d", hours, minutes % 60, seconds)
    }
    
    static func visibleCharacterCount(_ text: String) -> Int {
        var count = 0
        var index = text.startIndex
        while index < text.endIndex {
            if text[index] == "\u{1B}",
               let end = ansiEscapeSequenceEnd(in: text, from: index) {
                index = text.index(after: end)
                continue
            }
            count += 1
            index = text.index(after: index)
        }
        return count
    }
    
    static func ansiEscapeSequenceEnd(in text: String, from start: String.Index) -> String.Index? {
        guard start < text.endIndex,
              text[start] == "\u{1B}",
              text.index(after: start) < text.endIndex,
              text[text.index(after: start)] == "[" else {
            return nil
        }
        
        var index = text.index(start, offsetBy: 2)
        while index < text.endIndex {
            let character = text[index]
            if character.isLetter || character == "~" {
                return index
            }
            index = text.index(after: index)
        }
        return nil
    }
    
    static func fit(_ text: String, width: Int) -> String {
        guard width > 3, visibleCharacterCount(text) > width else {
            return text
        }
        
        var result = ""
        var visibleCount = 0
        var index = text.startIndex
        let visibleLimit = width - 3
        while index < text.endIndex, visibleCount < visibleLimit {
            if text[index] == "\u{1B}",
               let end = ansiEscapeSequenceEnd(in: text, from: index) {
                result += text[index...end]
                index = text.index(after: end)
                continue
            }
            result.append(text[index])
            visibleCount += 1
            index = text.index(after: index)
        }
        if result.contains("\u{1B}[") {
            result += "\u{1B}[0m"
        }
        return result + "..."
    }
    
    static func padded(_ text: String, width: Int) -> String {
        let visibleCount = visibleCharacterCount(text)
        guard visibleCount < width else {
            return text
        }
        return text + String(repeating: " ", count: width - visibleCount)
    }
    
    func inputPanelDisplayLineCountLocked(
        text: String,
        cursorIndex: Int
    ) -> Int {
        inputPanelDisplayRowsLocked(text: text, cursorIndex: cursorIndex).count
    }
    
    func inputPanelDisplayRowsLocked(
        text: String,
        cursorIndex: Int
    ) -> [String] {
        Self.inputPanelDisplayRows(
            text: text,
            cursorIndex: cursorIndex,
            contentWidth: statusBoxContentWidthLocked(),
            maxRows: maximumInputPanelTextRowsLocked()
        )
    }
    
    func inputPanelSuggestionRowsLocked(lines: [String]) -> [String] {
        let contentWidth = statusBoxContentWidthLocked()
        return lines.prefix(6).map { line in
            Self.padded(Self.fit(line, width: contentWidth), width: contentWidth)
        }
    }
    
    func statusBoxHorizontalInsetLocked() -> Int {
        0
    }
    
    func statusBoxStartColumnLocked() -> Int {
        statusBoxHorizontalInsetLocked() + 1
    }
    
    func statusBoxWidthLocked() -> Int {
        max(20, columns - statusBoxHorizontalInsetLocked() * 2)
    }
    
    func statusBoxContentWidthLocked() -> Int {
        max(1, statusBoxWidthLocked() - 4)
    }
    
    func maximumInputPanelTextRowsLocked() -> Int {
        let suggestionLineCount = inputPanelState?.suggestionLines.count ?? 0
        guard row > 0 else {
            return 1
        }
        
        return max(
            1,
            row
            - Self.inputPanelChromeRows
            - suggestionLineCount
            - Self.attachedStatusRows
            - Self.minimumScrollableRows
        )
    }
    
    static func inputPanelDisplayRows(
        text: String,
        cursorIndex: Int,
        contentWidth: Int,
        maxRows: Int
    ) -> [String] {
        let marker: Character = "▌"
        let promptPrefix = "> "
        let continuationPrefix = "  "
        let inputWidth = max(1, contentWidth - promptPrefix.count)
        var characters = Array(text)
        let boundedCursorIndex = min(max(0, cursorIndex), characters.count)
        characters.insert(marker, at: boundedCursorIndex)
        
        var logicalLines: [[Character]] = [[]]
        for character in characters {
            if character == "\n" {
                logicalLines.append([])
            } else {
                logicalLines[logicalLines.count - 1].append(character)
            }
        }
        
        var rows: [String] = []
        for (logicalLineIndex, logicalLine) in logicalLines.enumerated() {
            var remaining = logicalLine
            var isFirstVisualRow = true
            repeat {
                let chunkLength = min(inputWidth, remaining.count)
                let chunk = remaining.prefix(chunkLength)
                if chunkLength > 0 {
                    remaining.removeFirst(chunkLength)
                }
                let prefix: String
                if rows.isEmpty && logicalLineIndex == 0 && isFirstVisualRow {
                    prefix = promptPrefix
                } else {
                    prefix = continuationPrefix
                }
                rows.append(Self.padded(prefix + String(chunk), width: contentWidth))
                isFirstVisualRow = false
            } while !remaining.isEmpty
        }
        
        guard !rows.isEmpty else {
            return [Self.padded(promptPrefix + String(marker), width: contentWidth)]
        }
        return visibleInputRows(
            rows,
            maxRows: max(1, maxRows),
            marker: marker,
            contentWidth: contentWidth
        )
    }
    
    static func visibleInputRows(
        _ rows: [String],
        maxRows: Int,
        marker: Character,
        contentWidth: Int
    ) -> [String] {
        guard rows.count > maxRows else {
            return rows
        }
        
        let cursorRowIndex = rows.firstIndex { $0.contains(marker) } ?? max(0, rows.count - 1)
        let windowStart = min(
            max(0, cursorRowIndex - maxRows / 2),
            max(0, rows.count - maxRows)
        )
        let windowEnd = min(rows.count, windowStart + maxRows)
        var visibleRows = Array(rows[windowStart..<windowEnd])
        
        if maxRows >= 3, windowStart > 0, !visibleRows.isEmpty, cursorRowIndex != windowStart {
            visibleRows[0] = Self.padded("  ... earlier", width: contentWidth)
        }
        if maxRows >= 3,
           windowEnd < rows.count,
           !visibleRows.isEmpty,
           cursorRowIndex != windowEnd - 1 {
            visibleRows[visibleRows.count - 1] = Self.padded("  ... later", width: contentWidth)
        }
        return visibleRows
    }
    
}
