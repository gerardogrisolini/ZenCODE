//
//  ToolSnippetRenderer.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

private struct DetailedToolSnippet {
    let lines: [String]
    /// Structural property of the payload: it carried no source line at all.
    /// Emptiness is deliberately *not* encoded as a sentinel line, so a payload
    /// whose literal text happens to be the empty marker stays distinguishable
    /// both in the numbering and in the diff.
    let isEmptyPayload: Bool
}

private struct DetailedToolDiffRow {
    let oldLineIndex: Int?
    let newLineIndex: Int?
}

/// Builds the source rows a mutation tool call shows under its compact rows:
/// numbered code for a written payload, a side-by-side or stacked diff for an
/// edit, with every line made safe to draw in a terminal cell.
enum ToolSnippetRenderer {
    /// Builds the source payload appended to the compact tool rows. It reuses
    /// the shared code/diff row constructors while omitting tool metadata,
    /// summaries, and raw read results.
    static func standardToolCallRows(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult? = nil,
        contentWidth: Int? = nil
    ) -> [TerminalChat.DetailedToolRow] {
        let presentation = ToolCallPresentation.resolved(
            for: toolCall,
            result: result,
            mode: .expanded
        )
        guard presentation.kind != .read else { return [] }
        let isMutation: Bool
        switch presentation.kind {
        case .create, .edit, .delete, .move:
            isMutation = true
        case .read:
            isMutation = false
        case .search, .execute, .inspect, .communicate, .manage, .other:
            isMutation = ToolMutationClassifier.isFileMutationTool(toolCall.name)
        }
        guard isMutation else { return [] }

        let arguments = toolCall.argumentsObject
        switch ToolMutationClassifier.normalizedMutationToolName(toolCall.name) {
        case "local.writeFile", "local.append":
            guard let content = ToolArgumentReader.rawStringArgument(arguments, keys: ["content", "text"]) else {
                return []
            }
            return numberedCodeSnippetRows(content)
        case "local.replace", "local.editFile":
            return sourceChangeRows(
                old: ToolArgumentReader.rawStringArgument(arguments, keys: ["old"]),
                new: ToolArgumentReader.rawStringArgument(arguments, keys: ["new"]),
                contentWidth: contentWidth
            )
        case "local.multiEdit":
            return ToolArgumentReader.arrayObjectArgument(arguments, keys: ["edits"]).flatMap { edit in
                sourceChangeRows(
                    old: ToolArgumentReader.rawStringArgument(edit, keys: ["old"]),
                    new: ToolArgumentReader.rawStringArgument(edit, keys: ["new"]),
                    contentWidth: contentWidth
                )
            }
        case "local.applyPatch":
            guard let patch = ToolArgumentReader.rawStringArgument(arguments, keys: ["patch", "diff"]) else {
                return []
            }
            return numberedCodeSnippetRows(patch)
        default:
            return presentation.elements.flatMap {
                standardSemanticElementRows($0, contentWidth: contentWidth)
            }
        }
    }

    private static func sourceChangeRows(
        old: String?,
        new: String?,
        contentWidth: Int?,
        indentation: String = ""
    ) -> [TerminalChat.DetailedToolRow] {
        if let old, let new {
            return numberedDiffSnippetRows(
                old: old,
                new: new,
                contentWidth: contentWidth,
                indentation: indentation
            )
        }
        if let old { return numberedCodeSnippetRows(old, indentation: indentation) }
        if let new { return numberedCodeSnippetRows(new, indentation: indentation) }
        return []
    }

    private static func standardSemanticElementRows(
        _ element: ToolPresentationElement,
        contentWidth: Int?
    ) -> [TerminalChat.DetailedToolRow] {
        switch element {
        case let .code(_, content, _):
            return numberedCodeSnippetRows(content)
        case let .diff(_, old, new, _):
            return numberedDiffSnippetRows(old: old, new: new, contentWidth: contentWidth)
        case .parameters, .list, .summary:
            return []
        }
    }

    /// Prefixes each created/inserted source line with a stable, right-aligned
    /// local number. Layout inset belongs to the containing tool/agent section;
    /// source indentation stays unchanged in the content after the gutter.
    static func numberedCodeSnippetRows(
        _ text: String,
        indentation: String = ""
    ) -> [TerminalChat.DetailedToolRow] {
        let snippet = detailedToolSnippet(text)
        let numberWidth = String(max(1, snippet.lines.count)).count
        var rendered = snippet.lines.enumerated().map { index, line in
            TerminalChat.DetailedToolRow.code(TerminalChat.DetailedToolCodeLine(
                indentation: indentation,
                lineNumber: paddedLineNumber(index + 1, width: numberWidth),
                content: terminalSafeSnippetLine(line)
            ))
        }
        appendSnippetMarkers(
            to: &rendered,
            snippet: snippet,
            indentation: indentation,
            numberWidth: numberWidth
        )
        return rendered
    }




    /// Renders old and new edit payloads side by side when both columns can
    /// retain useful source context. Narrow terminals receive a unified,
    /// stacked `-` / `+` view. Each side-by-side row carries its two cells
    /// separately, so no content sequence can be mistaken for the divider.
    static func numberedDiffSnippetRows(
        old: String,
        new: String,
        contentWidth: Int?,
        indentation: String = ""
    ) -> [TerminalChat.DetailedToolRow] {
        let oldSnippet = detailedToolSnippet(old)
        let newSnippet = detailedToolSnippet(new)
        let availableWidth = max(1, contentWidth ?? TerminalTextMetrics.terminalColumnCount())
        let dividerWidth = TerminalTextMetrics.displayWidth(TerminalChat.DetailedToolDiffCells.divider)
        let columnWidth = max(
            0,
            (availableWidth - TerminalTextMetrics.displayWidth(indentation) - dividerWidth) / 2
        )

        guard columnWidth >= detailedToolSideBySideDiffMinimumCellWidth else {
            return numberedUnifiedDiffSnippetRows(
                old: oldSnippet,
                new: newSnippet,
                indentation: indentation
            )
        }

        let oldNumberWidth = String(max(1, oldSnippet.lines.count)).count
        let newNumberWidth = String(max(1, newSnippet.lines.count)).count
        var rows: [TerminalChat.DetailedToolRow] = [
            .diff(TerminalChat.DetailedToolDiffCells(
                indentation: indentation,
                oldCell: paddedToDisplayWidth("old", width: columnWidth),
                newCell: paddedToDisplayWidth("new", width: columnWidth)
            ))
        ]
        if oldSnippet.isEmptyPayload || newSnippet.isEmptyPayload {
            // Structural emptiness never enters the LCS input, so an empty side
            // cannot compare equal to — or be confused with — a source line whose
            // literal text is the marker. It is reported once, unnumbered.
            rows.append(.diff(TerminalChat.DetailedToolDiffCells(
                indentation: indentation,
                oldCell: detailedToolEmptyPayloadCell(
                    isEmpty: oldSnippet.isEmptyPayload,
                    numberWidth: oldNumberWidth,
                    width: columnWidth
                ),
                newCell: detailedToolEmptyPayloadCell(
                    isEmpty: newSnippet.isEmptyPayload,
                    numberWidth: newNumberWidth,
                    width: columnWidth
                )
            )))
        }
        for row in detailedToolDiffRows(old: oldSnippet.lines, new: newSnippet.lines) {
            let oldCell = detailedToolDiffCell(
                line: row.oldLineIndex.map { oldSnippet.lines[$0] },
                number: row.oldLineIndex.map { $0 + 1 },
                numberWidth: oldNumberWidth,
                width: columnWidth
            )
            let newCell = detailedToolDiffCell(
                line: row.newLineIndex.map { newSnippet.lines[$0] },
                number: row.newLineIndex.map { $0 + 1 },
                numberWidth: newNumberWidth,
                width: columnWidth
            )
            rows.append(.diff(TerminalChat.DetailedToolDiffCells(
                indentation: indentation,
                oldCell: oldCell,
                newCell: newCell
            )))
        }
        return rows
    }

    /// Converts a mutation payload into its complete sequence of source lines.
    /// Writes and both sides of an edit use this shared basis so line numbers
    /// stay consistent. It deliberately does not trim or
    /// de-indent source: empty files, trailing newlines and whitespace-only
    /// changes are semantically meaningful mutation payloads.
    private static func detailedToolSnippet(_ text: String) -> DetailedToolSnippet {
        let snippet = normalizedTerminalLineEndings(text)

        // `String.split(..., omittingEmptySubsequences: false)` represents an
        // empty string as one blank element. Keep an actually empty payload
        // distinct from a source line that is intentionally blank.
        let lines = snippet.isEmpty
            ? []
            : snippet
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)

        return DetailedToolSnippet(
            lines: lines,
            isEmptyPayload: lines.isEmpty
        )
    }

    /// Visible marker for a payload that carries no source line. It is rendered
    /// in the line-number gutter position *without* a number, so it can never
    /// coincide with a numbered source line whose literal text is `<empty>`.
    private static let detailedToolEmptyPayloadMarker = "<empty>"

    /// Plain-text projection of the same flush-aligned, numbered source rows.
    static func numberedCodeSnippetLines(
        _ text: String,
        indentation: String = ""
    ) -> [String] {
        numberedCodeSnippetRows(text, indentation: indentation).map(\.plainText)
    }

    /// Minimum useful width for each source cell in a side-by-side expanded
    /// diff. With no additional inset and a three-cell divider, the default
    /// content-width threshold is 51 cells (3 + 24 * 2).
    /// At or below a smaller budget the renderer uses stacked unified `-` / `+`
    /// rows rather than squeezing source code into unusably narrow columns.
    static let detailedToolSideBySideDiffMinimumCellWidth = 24

    /// Renders old and new edit payloads side by side when both columns can
    /// retain useful source context. Narrow terminals receive a unified,
    /// stacked `-` / `+` view, which the detailed wrapper safely reflows without
    /// horizontal scrolling.
    static func numberedDiffSnippetLines(
        old: String,
        new: String,
        contentWidth: Int?,
        indentation: String = ""
    ) -> [String] {
        numberedDiffSnippetRows(
            old: old,
            new: new,
            contentWidth: contentWidth,
            indentation: indentation
        )
        .map(\.plainText)
    }

    /// Builds the narrow presentation from the same LCS row model as the wide
    /// view. Changed source lines become adjacent `-` / `+` rows; unchanged
    /// lines are emitted once as context. This preserves source numbering and
    /// structural empty markers without relying on in-band text sentinels or a
    /// side-by-side divider.
    private static func numberedUnifiedDiffSnippetRows(
        old: DetailedToolSnippet,
        new: DetailedToolSnippet,
        indentation: String
    ) -> [TerminalChat.DetailedToolRow] {
        let numberWidth = String(max(1, old.lines.count, new.lines.count)).count
        let blankLineNumber = String(repeating: " ", count: numberWidth)

        func lineNumber(_ index: Int?) -> String {
            guard let index else {
                return blankLineNumber
            }
            return paddedLineNumber(index + 1, width: numberWidth)
        }

        func unifiedRow(
            marker: String,
            lineIndex: Int?,
            content: String
        ) -> TerminalChat.DetailedToolRow {
            .unifiedDiff(TerminalChat.DetailedToolUnifiedDiffLine(
                indentation: indentation,
                marker: marker,
                lineNumber: lineNumber(lineIndex),
                content: terminalSafeSnippetLine(content)
            ))
        }

        var rows: [TerminalChat.DetailedToolRow] = []
        if old.isEmptyPayload {
            rows.append(unifiedRow(
                marker: "-",
                lineIndex: nil,
                content: detailedToolEmptyPayloadMarker
            ))
        }
        if new.isEmptyPayload {
            rows.append(unifiedRow(
                marker: "+",
                lineIndex: nil,
                content: detailedToolEmptyPayloadMarker
            ))
        }

        for row in detailedToolDiffRows(old: old.lines, new: new.lines) {
            if let oldIndex = row.oldLineIndex,
               let newIndex = row.newLineIndex,
               old.lines[oldIndex] == new.lines[newIndex] {
                rows.append(unifiedRow(
                    marker: " ",
                    lineIndex: newIndex,
                    content: new.lines[newIndex]
                ))
                continue
            }
            if let oldIndex = row.oldLineIndex {
                rows.append(unifiedRow(
                    marker: "-",
                    lineIndex: oldIndex,
                    content: old.lines[oldIndex]
                ))
            }
            if let newIndex = row.newLineIndex {
                rows.append(unifiedRow(
                    marker: "+",
                    lineIndex: newIndex,
                    content: new.lines[newIndex]
                ))
            }
        }

        return rows
    }

    /// Retains unchanged lines on the same visual row and pairs intervening
    /// removals/insertions as replacements. `CollectionDifference` avoids the
    /// old `old.count × new.count` LCS matrix, which was incompatible with
    /// rendering complete, unbounded file changes.
    private static func detailedToolDiffRows(
        old: [String],
        new: [String]
    ) -> [DetailedToolDiffRow] {
        var removedOffsets = Set<Int>()
        var insertedOffsets = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case let .remove(offset, _, _):
                removedOffsets.insert(offset)
            case let .insert(offset, _, _):
                insertedOffsets.insert(offset)
            }
        }

        var rows: [DetailedToolDiffRow] = []
        var pendingOld: [Int] = []
        var pendingNew: [Int] = []
        func flushPending() {
            let count = max(pendingOld.count, pendingNew.count)
            for index in 0..<count {
                rows.append(DetailedToolDiffRow(
                    oldLineIndex: index < pendingOld.count ? pendingOld[index] : nil,
                    newLineIndex: index < pendingNew.count ? pendingNew[index] : nil
                ))
            }
            pendingOld.removeAll(keepingCapacity: true)
            pendingNew.removeAll(keepingCapacity: true)
        }

        var oldIndex = 0
        var newIndex = 0
        while oldIndex < old.count || newIndex < new.count {
            if oldIndex < old.count,
               newIndex < new.count,
               !removedOffsets.contains(oldIndex),
               !insertedOffsets.contains(newIndex),
               old[oldIndex] == new[newIndex] {
                flushPending()
                rows.append(DetailedToolDiffRow(
                    oldLineIndex: oldIndex,
                    newLineIndex: newIndex
                ))
                oldIndex += 1
                newIndex += 1
            } else {
                while oldIndex < old.count, removedOffsets.contains(oldIndex) {
                    pendingOld.append(oldIndex)
                    oldIndex += 1
                }
                while newIndex < new.count, insertedOffsets.contains(newIndex) {
                    pendingNew.append(newIndex)
                    newIndex += 1
                }

                // Defensive progress for an unexpected unassociated change.
                // Normal `CollectionDifference` output is consumed by the two
                // loops above, but malformed alignment must never spin forever.
                if pendingOld.isEmpty, pendingNew.isEmpty {
                    if oldIndex < old.count {
                        pendingOld.append(oldIndex)
                        oldIndex += 1
                    }
                    if newIndex < new.count {
                        pendingNew.append(newIndex)
                        newIndex += 1
                    }
                }
                flushPending()
            }
        }
        flushPending()
        return rows
    }

    private static func detailedToolDiffCell(
        line: String?,
        number: Int?,
        numberWidth: Int,
        width: Int
    ) -> String {
        guard let line, let number else {
            return String(repeating: " ", count: width)
        }
        let prefix = "\(paddedLineNumber(number, width: numberWidth)) │ "
        let terminalSafeLine = terminalSafeSnippetLine(line)
        // Leave overlong source content intact: `safelyWrappedDetailedToolRows`
        // reflows each diff cell independently after this layout pass, retaining
        // the gutter, divider and syntax-coloring boundaries on continuations.
        return paddedToDisplayWidth("\(prefix)\(terminalSafeLine)", width: width)
    }

    /// Cell for a structurally empty side. The line-number gutter stays blank,
    /// which is what keeps it distinct from a numbered line whose content is
    /// literally the marker text.
    private static func detailedToolEmptyPayloadCell(
        isEmpty: Bool,
        numberWidth: Int,
        width: Int
    ) -> String {
        guard isEmpty else {
            return String(repeating: " ", count: width)
        }
        let prefix = "\(String(repeating: " ", count: numberWidth)) │ "
        return paddedToDisplayWidth(
            "\(prefix)\(detailedToolEmptyPayloadMarker)",
            width: width
        )
    }

    /// CRLF is a line ending rather than a source character in this terminal
    /// presentation. Normalize it (and a lone carriage return) before splitting
    /// so no payload can reposition the terminal cursor inside a code cell.
    private static func normalizedTerminalLineEndings(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Emits spaces instead of literal tabs and replaces control characters
    /// with visible, single-column pictures. A literal tab is terminal- and
    /// cursor-position-dependent, so it defeats the width budget used by the
    /// side-by-side layout; an ESC in the payload would additionally inject an
    /// arbitrary escape sequence into the rendered row. Expansion happens only
    /// for presentation; LCS keeps comparing the original source lines,
    /// preserving a tab-vs-space edit.
    static func terminalSafeSnippetLine(_ line: String) -> String {
        let tabWidth = 4
        var rendered = ""
        var currentWidth = 0
        for character in line {
            if character == "\t" {
                let spaces = tabWidth - (currentWidth % tabWidth)
                rendered += String(repeating: " ", count: spaces)
                currentWidth += spaces
                continue
            }
            let safeCharacter = controlPicture(for: character) ?? character
            rendered.append(safeCharacter)
            currentWidth += TerminalANSIText.visibleWidth(of: safeCharacter)
        }
        return rendered
    }

    /// Maps a control character to its single-column Unicode "Control Pictures"
    /// glyph so the payload stays visible and measurable instead of steering
    /// the terminal.
    private static func controlPicture(for character: Character) -> Character? {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count == 1,
              CharacterSet.controlCharacters.contains(scalar) else {
            return nil
        }
        if scalar.value < 0x20, let picture = Unicode.Scalar(0x2400 + scalar.value) {
            return Character(picture)
        }
        if scalar.value == 0x7F, let picture = Unicode.Scalar(0x2421) {
            return Character(picture)
        }
        return " "
    }

    private static func paddedLineNumber(_ number: Int, width: Int) -> String {
        let text = String(number)
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }

    private static func paddedToDisplayWidth(_ text: String, width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - TerminalTextMetrics.displayWidth(text)))
    }

    private static func appendSnippetMarkers(
        to rows: inout [TerminalChat.DetailedToolRow],
        snippet: DetailedToolSnippet,
        indentation: String,
        numberWidth: Int
    ) {
        let blankLineNumber = String(repeating: " ", count: numberWidth)
        if snippet.isEmptyPayload {
            // Structural emptiness: no line number is assigned, so this row is
            // distinct from a numbered line whose content is literally the
            // marker text.
            rows.append(.code(TerminalChat.DetailedToolCodeLine(
                indentation: indentation,
                lineNumber: blankLineNumber,
                content: detailedToolEmptyPayloadMarker
            )))
        }
    }
}
