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
        let reset = TerminalStyle.reset
        let count = TerminalStyle.FileChange.count
        let addition = TerminalStyle.FileChange.addition
        let deletion = TerminalStyle.FileChange.deletion
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
    
    /// Merges a metrics event into the status bar's running metrics.
    ///
    /// The semantics live on `DirectAgentGenerationMetrics` so the sub-agent
    /// overview folds provider updates exactly the same way.
    nonisolated func mergedMetrics(
        current: DirectAgentGenerationMetrics?,
        update: DirectAgentGenerationMetrics
    ) -> DirectAgentGenerationMetrics {
        DirectAgentGenerationMetrics.merging(current: current, update: update)
    }

    static func tokenWindowText(
        usedTokens: Int?,
        metricUsedTokens: Int?,
        maxTokens: Int?
    ) -> String {
        let resolvedUsedTokens = usedTokens ?? metricUsedTokens
        let usedText = resolvedUsedTokens.map(contextTokenCountText) ?? "0.0k"
        guard let maxTokens, maxTokens > 0 else {
            return "\(usedText)/--"
        }
        return "\(usedText)/\(contextWindowLimitText(maxTokens))"
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
    
    static func generationTokenCountsFragment(
        _ metrics: DirectAgentGenerationMetrics
    ) -> String? {
        let fragments = [
            metrics.cachedPromptTokenCount.map { "c:\(tokenCountText($0))" },
            metrics.promptTokenCount.map { "p:\(tokenCountText($0))" },
            metrics.completionTokenCount.map { "g:\(tokenCountText($0))" }
        ].compactMap(\.self)
        
        guard !fragments.isEmpty else {
            return nil
        }
        return fragments.joined(separator: " ")
    }

    /// Status-bar presentation of the token counters: the `c:` / `p:` / `g:`
    /// labels are muted so only their values keep the default foreground.
    static func styledGenerationTokenCountsFragment(
        _ metrics: DirectAgentGenerationMetrics
    ) -> String? {
        let fragments = [
            metrics.cachedPromptTokenCount.map { mutedLabel("c:") + tokenCountText($0) },
            metrics.promptTokenCount.map { mutedLabel("p:") + tokenCountText($0) },
            metrics.completionTokenCount.map { mutedLabel("g:") + tokenCountText($0) }
        ].compactMap(\.self)

        guard !fragments.isEmpty else {
            return nil
        }
        return fragments.joined(separator: " ")
    }

    static func subscriptionUsageFragment(
        _ status: DirectAgentSubscriptionUsageStatus
    ) -> String? {
        guard status.hasValues else {
            return nil
        }
        let fragments = [
            status.dailyUsedPercent.map { "d:\(usagePercentText($0))" },
            status.weeklyUsedPercent.map { "w:\(usagePercentText($0))" }
        ].compactMap(\.self)
        return fragments.joined(separator: " ")
    }

    /// Status-bar presentation of the subscription usage counters: the `d:` /
    /// `w:` labels are muted so their values keep the default foreground.
    static func styledSubscriptionUsageFragment(
        _ status: DirectAgentSubscriptionUsageStatus
    ) -> String? {
        guard status.hasValues else {
            return nil
        }
        let fragments = [
            status.dailyUsedPercent.map { mutedLabel("d:") + usagePercentText($0) },
            status.weeklyUsedPercent.map { mutedLabel("w:") + usagePercentText($0) }
        ].compactMap(\.self)
        return fragments.joined(separator: " ")
    }

    private static func mutedLabel(_ label: String) -> String {
        "\(TerminalStyle.Text.muted)\(label)\(TerminalStyle.reset)"
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
    
    static func durationText(_ value: Double) -> String {
        guard value.isFinite, value >= 0 else {
            return "--"
        }
        let style = Duration.TimeFormatStyle(pattern: .hourMinuteSecond)
        return Duration
            .seconds(value)
            .formatted(style)
    }
    
    static func visibleCharacterCount(_ text: String) -> Int {
        TerminalANSIText.visibleWidth(text)
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

        return TerminalANSIText.truncate(text, to: width)
    }
    
    static func padded(_ text: String, width: Int) -> String {
        let visibleCount = visibleCharacterCount(text)
        guard visibleCount < width else {
            return text
        }
        return text + String(repeating: " ", count: width - visibleCount)
    }
    
    func inputPanelDisplayLineCountLocked(
        state: inout State,
        text: String,
        cursorIndex: Int
    ) -> Int {
        inputPanelDisplayRowsLocked(state: &state, text: text, cursorIndex: cursorIndex).count
    }
    
    func inputPanelDisplayRowsLocked(
        state: inout State,
        text: String,
        cursorIndex: Int
    ) -> [String] {
        let contentWidth = statusBoxContentWidthLocked(state: &state)
        let maxRows = maximumInputPanelTextRowsLocked(state: &state)
        return Self.inputPanelDisplayRows(
            text: text,
            cursorIndex: cursorIndex,
            contentWidth: contentWidth,
            maxRows: maxRows
        )
    }
    
    func inputPanelSuggestionRowsLocked(state: inout State, lines: [String]) -> [String] {
        let contentWidth = statusBoxContentWidthLocked(state: &state)
        return lines.prefix(inputPanelSuggestionRowCountLocked(state: &state)).map { line in
            Self.padded(Self.fit(line, width: contentWidth), width: contentWidth)
        }
    }
    
    func statusBoxHorizontalInsetLocked(state: inout State) -> Int {
        0
    }
    
    func statusBoxStartColumnLocked(state: inout State) -> Int {
        statusBoxHorizontalInsetLocked(state: &state) + 1
    }
    
    func statusBoxWidthLocked(state: inout State) -> Int {
        let horizontalInset = statusBoxHorizontalInsetLocked(state: &state)
        return max(20, state.columns - horizontalInset * 2)
    }
    
    func statusBoxContentWidthLocked(state: inout State) -> Int {
        max(1, statusBoxWidthLocked(state: &state) - 4)
    }
    
    func maximumInputPanelTextRowsLocked(state: inout State) -> Int {
        guard state.row > 0 else {
            return 1
        }

        // The dock is part of the same bottom-panel budget as the editor.  Do
        // not let a tall draft consume the rows needed for the active reader,
        // nor consume the scrolling region while calculating the draft limit.
        return max(
            1,
            state.row
            - Self.inputPanelChromeRows
            - inputPanelSuggestionRowCountLocked(state: &state)
            - Self.attachedStatusRows
            - Self.minimumScrollableRows
            - sharedChatReaderReservedRowsLocked(state: &state)
        )
    }

    func inputPanelSuggestionRowCountLocked(state: inout State) -> Int {
        let requested = min(6, state.inputPanelState?.suggestionLines.count ?? 0)
        guard state.row > 0 else { return requested }
        // Suggestions share the bottom-panel budget with the editor and dock.
        // Always retain one input row plus the minimum scrollable transcript.
        let available = max(
            0,
            state.row
                - Self.minimumScrollableRows
                - Self.inputPanelChromeRows
                - Self.attachedStatusRows
                // An active observation owns one compact row before optional
                // suggestions. This keeps its unread counter discoverable on
                // the smallest supported panel.
                - (state.sharedChatReaderDock == nil ? 0 : 1)
                - 1
        )
        return min(requested, available)
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
                let split = inputPanelChunk(remaining, maxWidth: inputWidth)
                let chunk = split.chunk
                remaining = split.remaining
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
    
    static func inputPanelChunk(
        _ characters: [Character],
        maxWidth: Int
    ) -> (chunk: [Character], remaining: [Character]) {
        guard !characters.isEmpty else {
            return ([], [])
        }

        let widthLimit = max(1, maxWidth)
        var width = 0
        var endIndex = 0

        for character in characters {
            let characterWidth = TerminalANSIText.visibleWidth(String(character))
            if endIndex > 0, width + characterWidth > widthLimit {
                break
            }
            endIndex += 1
            width += characterWidth
            if width >= widthLimit {
                break
            }
        }

        let splitIndex = max(1, endIndex)
        return (
            Array(characters.prefix(splitIndex)),
            Array(characters.dropFirst(splitIndex))
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
