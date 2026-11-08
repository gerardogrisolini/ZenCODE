//
//  TerminalChat+SubAgentTranscriptRendering.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 06/11/26.
//

import Foundation
import ToolCore

extension TerminalChat {
    /// One conversation entry of a sub-agent transcript, as the detail view
    /// renders it. A tool call is a single entry for its whole lifecycle.
    private enum SubAgentTranscriptEntry {
        case prompt(String)
        case thought(String)
        case assistantText(String)
        case toolCall(DirectAgentToolCall, result: DirectAgentToolResult?, elapsed: Duration?)
    }

    /// Renders the conversation of one sub-agent (``ChatSubAgentTranscript/kinds``,
    /// oldest first) as the physical rows of the sub-agent detail view, with
    /// the renderers of the main chat:
    ///
    /// - a prompt as the submitted-prompt band (`> ` on its first row, two
    ///   spaces on the next ones), padded with the band background to `width`;
    /// - a reasoning block as the thinking title followed by its Markdown in
    ///   the thinking style;
    /// - an assistant block as Markdown;
    /// - a tool call as its canonical compact rows, once: the row stays where
    ///   the call started and shows its result once it completed (as the
    ///   ZenApp sub-agent tab merges them). A completed call shows its elapsed
    ///   time from `toolDurations` (``ChatSubAgentTranscript/toolDurations``,
    ///   by call id) as the main chat does; a running call, or one without a
    ///   duration, shows none. Tools without a terminal representation
    ///   (``shouldSuppressToolRendering(for:)``) have no row.
    ///
    /// File artifacts, notices, workflow notices, and turn phases are not
    /// part of the conversation and have no row. One blank row separates two
    /// rendered entries.
    ///
    /// No row exceeds `width` visible columns. With `standardErrorIsTerminal`
    /// every row is styled on its own: it re-opens the SGR style still active
    /// from the row before and resets a style it leaves open, so a caller can
    /// write each row independently. Without it the rows are plain text.
    nonisolated static func renderSubAgentTranscriptRows(
        _ kinds: [ChatTurnEntry.Kind],
        toolDurations: [String: Duration] = [:],
        width: Int,
        standardErrorIsTerminal: Bool
    ) -> [String] {
        let width = max(1, width)
        var rows: [String] = []
        for entry in subAgentTranscriptEntries(kinds, toolDurations: toolDurations) {
            let entryRows = subAgentTranscriptRows(
                for: entry,
                width: width,
                standardErrorIsTerminal: standardErrorIsTerminal
            )
            guard !entryRows.isEmpty else { continue }
            if !rows.isEmpty {
                rows.append("")
            }
            rows.append(contentsOf: entryRows)
        }
        return rows
    }

    /// The rows heading the sub-agent detail view: the status header (status
    /// marker, name, and badge) and the metadata of the full overview entry
    /// (id, role, agent, task and attempt, model with its token counters),
    /// then the latest error. Neither the activity nor the final response is
    /// included. No row exceeds `width` visible columns.
    nonisolated static func subAgentDetailHeaderRows(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        modelTitleResolver: (String) -> String,
        width: Int
    ) -> [String] {
        subAgentRowsTruncated(
            subAgentOverviewRows(
                subAgentEntryLines(
                    snapshot,
                    modelTitleResolver: modelTitleResolver,
                    toolPresentation: nil,
                    density: .full,
                    includesFinalResponse: false,
                    includesActivity: false
                ),
                columns: width,
                includesTitle: false
            ),
            to: width
        )
    }

    /// The live activity shown after the transcript of a sub-agent in
    /// progress, as the sub-agent tab of ZenApp shows it:
    ///
    /// - no row when the agent is not pending, or while it runs a tool
    ///   (``DirectSubAgentRuntime/AgentSnapshot/currentToolIsRunning``): the
    ///   transcript already has the row of that call. The runtime keeps the
    ///   name of a completed call until the next model state, so the name
    ///   alone does not mean a running tool. A tool without a terminal
    ///   representation (``shouldSuppressToolRendering(for:)``, as
    ///   `agent.message`) does not count as a running tool either;
    /// - while it reasons with reasoning to show, the rows the transcript
    ///   draws for a reasoning block: the thinking title followed by the
    ///   whole reasoning of the phase in the thinking style
    ///   (``DirectSubAgentRuntime/AgentSnapshot/currentThought``, growing
    ///   with every paragraph), at the full `width`;
    /// - in every other case (it reasons without reasoning to show yet, writes
    ///   a message without reasoning before it, also right after a completed
    ///   call, has no activity, or is queued) a single row with the thinking
    ///   title alone (``thinkingPlaceholder``).
    ///
    /// No row exceeds `width` visible columns. With `standardErrorIsTerminal`
    /// every row is styled on its own, as in
    /// ``renderSubAgentTranscriptRows(_:toolDurations:width:standardErrorIsTerminal:)``;
    /// without it the rows are plain text.
    nonisolated static func subAgentLiveActivityRows(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot,
        width: Int,
        standardErrorIsTerminal: Bool
    ) -> [String] {
        guard snapshot.pending else { return [] }
        if snapshot.currentToolIsRunning,
           let toolName = snapshot.currentToolName?.nilIfBlank,
           !shouldSuppressToolRendering(for: toolName) {
            return []
        }
        let width = max(1, width)
        if snapshot.currentActivityKind == .thinking,
           let thought = snapshot.currentThought?.nilIfBlank {
            // The rows of the transcript fit `width` unless one glyph is wider
            // than the view itself (a view of one column); only such a row is cut.
            return subAgentTranscriptRows(
                for: .thought(thought),
                width: width,
                standardErrorIsTerminal: standardErrorIsTerminal
            ).map { row in
                TerminalANSIText.visibleWidth(row) > width
                    ? TerminalANSIText.truncate(row, to: width)
                    : row
            }
        }
        return [
            TerminalANSIText.truncate(
                subAgentThinkingTitle(standardErrorIsTerminal: standardErrorIsTerminal),
                to: width
            )
        ]
    }

    /// The title of a reasoning block: ``thinkingPlaceholder`` in the thinking
    /// title style, reset after it, when `standardErrorIsTerminal`.
    private nonisolated static func subAgentThinkingTitle(
        standardErrorIsTerminal: Bool
    ) -> String {
        standardErrorIsTerminal
            ? "\(TerminalStyle.Thinking.title)\(thinkingPlaceholder)\(TerminalStyle.reset)"
            : thinkingPlaceholder
    }

    /// The overview rows never narrow below the section's minimum content
    /// width; a narrower detail view cuts them at `width`.
    private nonisolated static func subAgentRowsTruncated(
        _ rows: [String],
        to width: Int
    ) -> [String] {
        let width = max(1, width)
        return rows.map { TerminalANSIText.truncate($0, to: width) }
    }

    /// The conversation entries of `kinds`, oldest first. A completed tool
    /// call fills the entry of its start (by ID, the latest one still open;
    /// without ID, the oldest one still open), with its duration in
    /// `toolDurations` when it has an ID; a completion without a start is an
    /// entry of its own. Calls of suppressed tools are dropped.
    private nonisolated static func subAgentTranscriptEntries(
        _ kinds: [ChatTurnEntry.Kind],
        toolDurations: [String: Duration]
    ) -> [SubAgentTranscriptEntry] {
        var entries: [SubAgentTranscriptEntry] = []
        var openCalls: [String: Int] = [:]
        var openCallsWithoutID: [Int] = []
        for kind in kinds {
            switch kind {
            case let .userPrompt(text, _, _):
                entries.append(.prompt(text))
            case let .thought(text):
                entries.append(.thought(text))
            case let .assistantText(text):
                entries.append(.assistantText(text))
            case let .toolCallStarted(call):
                guard !shouldSuppressToolRendering(for: call.name) else { continue }
                if call.id.isEmpty {
                    openCallsWithoutID.append(entries.count)
                } else {
                    openCalls[call.id] = entries.count
                }
                entries.append(.toolCall(call, result: nil, elapsed: nil))
            case let .toolCallCompleted(call, result):
                guard !shouldSuppressToolRendering(for: call.name) else { continue }
                let startIndex: Int?
                if call.id.isEmpty {
                    startIndex = openCallsWithoutID.isEmpty ? nil : openCallsWithoutID.removeFirst()
                } else {
                    startIndex = openCalls.removeValue(forKey: call.id)
                }
                let elapsed = call.id.isEmpty ? nil : toolDurations[call.id]
                if let startIndex {
                    entries[startIndex] = .toolCall(call, result: result, elapsed: elapsed)
                } else {
                    entries.append(.toolCall(call, result: result, elapsed: elapsed))
                }
            case .fileArtifacts, .notice, .workflowNotice, .turnPhase:
                continue
            }
        }
        return entries
    }

    /// The physical rows of one entry, bounded by `width`; empty when the
    /// entry renders nothing visible.
    private nonisolated static func subAgentTranscriptRows(
        for entry: SubAgentTranscriptEntry,
        width: Int,
        standardErrorIsTerminal: Bool
    ) -> [String] {
        let logicalRows: [String]
        switch entry {
        case let .prompt(text):
            // The band is padded inside its background rather than extended
            // with an erase to the end of the line, which would paint past
            // `width` over whatever the caller draws beside the rows.
            return subAgentTranscriptPromptRows(
                text,
                width: width,
                standardErrorIsTerminal: standardErrorIsTerminal
            )
        case let .thought(text):
            let title = subAgentThinkingTitle(standardErrorIsTerminal: standardErrorIsTerminal)
            let body = renderSubAgentThinkingMarkdown(
                text,
                standardErrorIsTerminal: standardErrorIsTerminal,
                renderWidth: width
            )
            logicalRows = [title] + (body.map(subAgentTranscriptLogicalRows) ?? [])
        case let .assistantText(text):
            var formatter = TerminalMarkdownStreamFormatter(
                isEnabled: standardErrorIsTerminal,
                renderWidth: width,
                // Only renderer-owned SGR may reach the detail view, never OSC.
                supportsHyperlinks: false,
                removesUnbalancedStrongMarkers: true
            )
            logicalRows = subAgentTranscriptLogicalRows(
                formatter.consume(text) + formatter.finish()
            )
        case let .toolCall(call, result, elapsed):
            logicalRows = subAgentTranscriptToolRows(
                call,
                result: result,
                elapsed: elapsed,
                width: width,
                standardErrorIsTerminal: standardErrorIsTerminal
            )
        }
        let rows = standardErrorIsTerminal
            ? subAgentTranscriptSelfStyledRows(logicalRows)
            : logicalRows
        return rows.flatMap { TerminalANSIText.wrapPreservingWhitespace($0, width: width) }
    }

    /// The submitted-prompt band of `writeSubmittedPrompt`, wrapped at
    /// `width` with continuation rows aligned after `> `. On a terminal each
    /// physical row is padded to `width` inside the band background, then
    /// reset.
    private nonisolated static func subAgentTranscriptPromptRows(
        _ text: String,
        width: Int,
        standardErrorIsTerminal: Bool
    ) -> [String] {
        let rows = text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .flatMap { index, line in
                TerminalANSIText.wrapPreservingWhitespace(
                    "\(index == 0 ? "> " : "  ")\(line)",
                    width: width,
                    hangingIndent: "  "
                )
            }
        guard standardErrorIsTerminal else {
            return rows
        }
        let background = TerminalStyle.Prompt.background
        let reset = TerminalStyle.reset
        return rows.map { row in
            let padding = String(repeating: " ", count: max(0, width - TerminalANSIText.visibleWidth(row)))
            return "\(background)\(row)\(padding)\(reset)"
        }
    }

    /// The canonical compact rows of a tool call, as the full sub-agent
    /// overview renders them (``renderSubAgentToolLines(_:density:standardErrorIsTerminal:)``),
    /// with the completion detail of the result as the main chat makes it:
    /// the elapsed time the tool executor measured, as the transcript's
    /// durations keep it (`elapsed`, `nil` when it has none), then the exit
    /// code of a failed process.
    private nonisolated static func subAgentTranscriptToolRows(
        _ call: DirectAgentToolCall,
        result: DirectAgentToolResult?,
        elapsed: Duration?,
        width: Int,
        standardErrorIsTerminal: Bool
    ) -> [String] {
        let rows = toolPresentationRows(
            for: call,
            result: result,
            statusDetail: result.flatMap {
                compactToolCompletionDetail(for: call, result: $0, elapsed: elapsed)
            },
            contentInsetWidth: 0,
            // The canonical renderer reserves its own final safety column.
            columnWidth: width + 1,
            includesSourceChanges: false
        )
        let reset = TerminalStyle.reset
        let compactRows = rows.compactRows.enumerated().map { index, row in
            standardErrorIsTerminal
                ? "\(renderCompactToolLine(row.plainText, isTitle: index == 0))\(reset)"
                : row.plainText
        }
        let codeLanguage = codeLanguageHint(for: call)
        let detailRows = rows.detailRows.map { row in
            standardErrorIsTerminal
                ? renderDetailedToolRow(
                    row,
                    codeLanguage: codeLanguage,
                    contentWidth: rows.detailContentWidth
                ) + reset
                : row.plainText
        }
        return compactRows + detailRows
    }

    /// The lines of rendered text, without the blank lines (blank once the
    /// escape sequences are ignored) that open or close it: entries are
    /// separated by exactly one blank row.
    private nonisolated static func subAgentTranscriptLogicalRows(
        _ rendered: String
    ) -> [String] {
        var rows = rendered.components(separatedBy: "\n")
        func isBlank(_ row: String) -> Bool {
            TerminalANSIText.stripANSI(row).trimmingCharacters(in: .whitespaces).isEmpty
        }
        while let first = rows.first, isBlank(first) {
            rows.removeFirst()
        }
        while let last = rows.last, isBlank(last) {
            rows.removeLast()
        }
        return rows
    }

    /// Makes every row carry its own styling: a row starts with the SGR style
    /// still active at the end of the row before it, and resets the style it
    /// leaves open. Rows dropped around a block cannot leak a style either.
    private nonisolated static func subAgentTranscriptSelfStyledRows(
        _ rows: [String]
    ) -> [String] {
        var activeStyle = ""
        return rows.map { row in
            let styledRow = activeStyle + row
            activeStyle = TerminalANSIText.updatedActiveStyle(activeStyle, scanning: row)
            return activeStyle.isEmpty ? styledRow : styledRow + TerminalStyle.reset
        }
    }
}
