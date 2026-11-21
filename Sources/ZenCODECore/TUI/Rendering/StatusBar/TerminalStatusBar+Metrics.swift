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
import ZenCODERuntime

extension TerminalStatusBar {
    /// The widest agent name the status row shows, in visible columns.
    /// ``fit(_:width:)`` cuts the row from its end, so an unbounded name would
    /// push the model, the context and the tokens out of a narrow terminal.
    static let maximumAgentNameColumns = 24

    /// The agent name of the status row, cut to ``maximumAgentNameColumns``
    /// with a trailing `…`.
    static func agentNameStatusFragment(_ agentName: String) -> String {
        TerminalANSIText.truncate(agentName, to: maximumAgentNameColumns)
    }

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

    /// Status-bar presentation of the token counters (`c:<cached> p:<prompt>
    /// g:<generated>`, only the known ones): the `c:` / `p:` / `g:` labels are
    /// muted so only their values keep the default foreground.
    static func styledGenerationTokenCountsFragment(
        _ metrics: DirectAgentGenerationMetrics
    ) -> String? {
        let fragments = [
            metrics.cachedPromptTokenCount.map { mutedLabel("c:") + StatusMetricsFormatting.tokenCountText($0) },
            metrics.promptTokenCount.map { mutedLabel("p:") + StatusMetricsFormatting.tokenCountText($0) },
            metrics.completionTokenCount.map { mutedLabel("g:") + StatusMetricsFormatting.tokenCountText($0) }
        ].compactMap(\.self)

        guard !fragments.isEmpty else {
            return nil
        }
        return fragments.joined(separator: " ")
    }

    /// Status-bar throughput label, a single one with the `tok/s` unit at the
    /// end. While the prompt is evaluated it shows the progress relative to the
    /// sync and the prefill rate once measurable (`p:1.2k/8.0k 512.0 tok/s`,
    /// `p:0/8.0k` before the first measure). Otherwise it shows the speeds that
    /// are known: `p:512.0 g:42.1 tok/s`, `p:512.0 tok/s` or `g:42.1 tok/s`.
    /// `nil` without a throughput or with nothing usable to show. `p:` / `g:`
    /// are muted so only the values and the unit keep the default foreground.
    static func styledGenerationThroughputFragment(
        _ metrics: DirectAgentGenerationMetrics
    ) -> String? {
        generationThroughputText(metrics, styleLabel: mutedLabel)
    }

    /// The implementation behind the styled label: `styleLabel` decorates the
    /// `p:` / `g:` prefixes only.
    private static func generationThroughputText(
        _ metrics: DirectAgentGenerationMetrics,
        styleLabel: (String) -> String
    ) -> String? {
        guard let throughput = metrics.throughput else {
            return nil
        }
        let prefillRate = throughput.prefillTokensPerSecond.flatMap(StatusMetricsFormatting.throughputRateText)
        let unit = "tok/s"

        if let processed = throughput.processedTokens,
           let target = throughput.targetTokens {
            let progress = styleLabel("p:") + "\(StatusMetricsFormatting.tokenCountText(processed))/\(StatusMetricsFormatting.tokenCountText(target))"
            guard let prefillRate else {
                return progress
            }
            return "\(progress) \(prefillRate) \(unit)"
        }

        let segments = [
            prefillRate.map { styleLabel("p:") + $0 },
            throughput.generationTokensPerSecond
                .flatMap(StatusMetricsFormatting.throughputRateText)
                .map { styleLabel("g:") + $0 }
        ].compactMap(\.self)
        guard !segments.isEmpty else {
            return nil
        }
        return "\(segments.joined(separator: " ")) \(unit)"
    }

    /// Status-bar presentation of the subscription usage counters
    /// (`d:<daily> w:<weekly>`, only the known windows; `nil` without values):
    /// the `d:` / `w:` labels are muted so their values keep the default
    /// foreground.
    static func styledSubscriptionUsageFragment(
        _ status: DirectAgentSubscriptionUsageStatus
    ) -> String? {
        guard status.hasValues else {
            return nil
        }
        let fragments = [
            status.dailyUsedPercent.map { mutedLabel("d:") + StatusMetricsFormatting.usagePercentText($0) },
            status.weeklyUsedPercent.map { mutedLabel("w:") + StatusMetricsFormatting.usagePercentText($0) }
        ].compactMap(\.self)
        return fragments.joined(separator: " ")
    }

    private static func mutedLabel(_ label: String) -> String {
        "\(TerminalStyle.Text.muted)\(label)\(TerminalStyle.reset)"
    }

    static func visibleCharacterCount(_ text: String) -> Int {
        TerminalANSIText.visibleWidth(text)
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

    func inputPanelSuggestionRowsLocked(
        state: inout State,
        lines: [String],
        selectedIndex: Int?
    ) -> [String] {
        let contentWidth = statusBoxContentWidthLocked(state: &state)
        let window = Self.inputPanelSuggestionWindow(
            lines: lines,
            selectedIndex: selectedIndex,
            maximumLineCount: inputPanelSuggestionRowCountLocked(state: &state)
        )
        return window.lines.map { line in
            Self.padded(Self.fit(line, width: contentWidth), width: contentWidth)
        }
    }

    /// Returns a contiguous window which contains the selected row. A nil
    /// selection intentionally retains the command completion menu's historical
    /// prefix clipping behaviour.
    static func inputPanelSuggestionWindow(
        lines: [String],
        selectedIndex: Int?,
        maximumLineCount: Int
    ) -> (lines: [String], selectedIndex: Int?) {
        guard maximumLineCount > 0, !lines.isEmpty else {
            return ([], nil)
        }
        let visibleCount = min(maximumLineCount, lines.count)
        guard let selectedIndex else {
            return (Array(lines.prefix(visibleCount)), nil)
        }
        let boundedSelection = min(max(0, selectedIndex), lines.count - 1)
        let minimumStart = max(0, boundedSelection - visibleCount + 1)
        let maximumStart = max(0, lines.count - visibleCount)
        let start = min(minimumStart, maximumStart)
        let end = start + visibleCount
        return (
            lines: Array(lines[start..<end]),
            selectedIndex: boundedSelection - start
        )
    }

    func statusBoxWidthLocked(state: inout State) -> Int {
        // Footer surfaces are painted with autowrap disabled by the primary
        // screen compositor, so their right border can own the final column.
        return max(20, state.columns)
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
