//
//  TerminalChat+ToolRenderingDetails.swift
//  ZenCODE
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

extension TerminalChat {






    /// Builds the source payload appended to the compact tool rows. It reuses
    /// the shared code/diff row constructors while omitting tool metadata,
    /// summaries, and raw read results.
    nonisolated static func standardToolCallRows(
        for toolCall: DirectAgentToolCall,
        result: DirectAgentToolResult? = nil,
        contentWidth: Int? = nil
    ) -> [DetailedToolRow] {
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
            isMutation = isFileMutationTool(toolCall.name)
        }
        guard isMutation else { return [] }

        let arguments = toolCall.argumentsObject
        switch normalizedMutationToolName(toolCall.name) {
        case "local.writeFile", "local.append":
            guard let content = rawStringArgument(arguments, keys: ["content", "text"]) else {
                return []
            }
            return numberedCodeSnippetRows(content)
        case "local.replace", "local.editFile":
            return sourceChangeRows(
                old: rawStringArgument(arguments, keys: ["old"]),
                new: rawStringArgument(arguments, keys: ["new"]),
                contentWidth: contentWidth
            )
        case "local.multiEdit":
            return arrayObjectArgument(arguments, keys: ["edits"]).flatMap { edit in
                sourceChangeRows(
                    old: rawStringArgument(edit, keys: ["old"]),
                    new: rawStringArgument(edit, keys: ["new"]),
                    contentWidth: contentWidth,
                    indentation: "    "
                )
            }
        case "local.applyPatch":
            guard let patch = rawStringArgument(arguments, keys: ["patch", "diff"]) else {
                return []
            }
            return numberedCodeSnippetRows(patch)
        default:
            return presentation.elements.flatMap {
                standardSemanticElementRows($0, contentWidth: contentWidth)
            }
        }
    }

    nonisolated private static func sourceChangeRows(
        old: String?,
        new: String?,
        contentWidth: Int?,
        indentation: String = ""
    ) -> [DetailedToolRow] {
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

    nonisolated private static func standardSemanticElementRows(
        _ element: ToolPresentationElement,
        contentWidth: Int?
    ) -> [DetailedToolRow] {
        switch element {
        case let .code(_, content, _):
            return numberedCodeSnippetRows(content)
        case let .diff(_, old, new, _):
            return numberedDiffSnippetRows(old: old, new: new, contentWidth: contentWidth)
        case .parameters, .list, .summary:
            return []
        }
    }













    nonisolated static func multiEditHasSourceChanges(
        _ arguments: [String: Any]
    ) -> Bool {
        arrayObjectArgument(arguments, keys: ["edits"]).contains { edit in
            rawStringArgument(edit, keys: ["old"]) != nil
                || rawStringArgument(edit, keys: ["new"]) != nil
        }
    }

    nonisolated static func editFileHasSourceChanges(
        _ arguments: [String: Any]
    ) -> Bool {
        rawStringArgument(arguments, keys: ["old"]) != nil
            || rawStringArgument(arguments, keys: ["new"]) != nil
    }



    nonisolated static func isFileMutationTool(_ toolName: String) -> Bool {
        switch normalizedMutationToolName(toolName) {
        case "local.writeFile", "local.append", "local.replace",
             "local.editFile", "local.multiEdit", "local.applyPatch",
             "local.delete", "local.move", "local.mkdir":
            return true
        default:
            return false
        }
    }

    nonisolated static func normalizedMutationToolName(_ toolName: String) -> String {
        toolName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Path-shaped metadata. Blank or whitespace-only values must fall through
    /// to the next alias key (and ultimately to the caller's fallback), and
    /// control characters must never reach a rendered metadata row or the
    /// language hint.
    nonisolated static func metadataArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            guard let value = rawStringArgument(arguments, keys: [key]) else {
                continue
            }
            if let sanitized = sanitizedMetadataText(value) {
                return sanitized
            }
        }
        return nil
    }

    /// Single neutralization point for every caller-controllable value rendered
    /// as metadata: titles, locations, change rows, patch targets and the
    /// language hint. Every control scalar — C0, DEL, C1 and the format
    /// characters that carry bidi/zero-width behavior — becomes a space, so no
    /// payload can emit ESC, CR, LF or a tab into a rendered metadata row.
    /// Returns `nil` for values that are blank once neutralized, so the caller
    /// falls through to the next alias or to its own fallback.
    nonisolated static func sanitizedMetadataText(_ value: String) -> String? {
        // CRLF is one line ending rather than two controls, so it collapses to a
        // single space before the per-scalar neutralization below.
        let lineEndingNormalized = value.replacingOccurrences(of: "\r\n", with: " ")
        var sanitized = ""
        sanitized.reserveCapacity(lineEndingNormalized.count)
        for character in lineEndingNormalized {
            let isControl = character.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    || scalar.properties.isBidiControl
                    || scalar.properties.isJoinControl
            }
            sanitized.append(isControl ? " " : character)
        }
        let normalized = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    /// Sanitized patch target. `patchDisplayTarget` derives its value from the
    /// patch body, which is fully caller-controlled, so it must not reach the
    /// change row or the language hint unneutralized.
    nonisolated static func patchTargetPath(_ arguments: [String: Any]) -> String? {
        guard let target = ToolCallPresentation.patchDisplayTarget(from: arguments) else {
            return nil
        }
        return sanitizedMetadataText(target)
    }

    nonisolated static func targetPath(_ arguments: [String: Any]) -> String? {
        metadataArgument(
            arguments,
            keys: [
                "file_path",
                "filePath",
                "file",
                "path",
                "directoryPath",
                "directory_path"
            ]
        )
    }

    /// Verbatim payload accessor. Source content is reproduced exactly: empty
    /// strings, whitespace-only edits and trailing newlines are all meaningful
    /// mutation payloads, so nothing is trimmed or skipped here.
    nonisolated static func rawStringArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> String? {
        for key in keys {
            if let value = arguments[key] as? String {
                return value
            }
            if let value = arguments[key] as? JSONValue,
               let stringValue = value.stringValue {
                return stringValue
            }
        }
        return nil
    }

    nonisolated static func stringArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> String? {
        rawStringArgument(arguments, keys: keys)
    }

    nonisolated static func boolArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> Bool? {
        for key in keys {
            if let value = arguments[key] as? Bool {
                return value
            }
            if let value = arguments[key] as? JSONValue {
                return value.boolValue
            }
        }
        return nil
    }

    nonisolated static func arrayObjectArgument(
        _ arguments: [String: Any],
        keys: [String]
    ) -> [[String: Any]] {
        for key in keys {
            if let value = arguments[key] as? [[String: Any]] {
                return value
            }
            if let value = arguments[key] as? [Any] {
                return value.compactMap { $0 as? [String: Any] }
            }
            if let value = arguments[key] as? JSONValue,
               case let .array(items) = value {
                return items.compactMap { item in
                    guard case let .object(object) = item else {
                        return nil
                    }
                    return object.mapValues(\.jsonObject)
                }
            }
        }
        return []
    }

    nonisolated static func compactSummaryLine(_ text: String) -> String? {
        let summary = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)
            .first?
            .nilIfBlank
        guard let summary else {
            return nil
        }
        // Count-based inline truncation (see `truncatedByCount`): the 160 budget
        // is a grapheme-cluster count, matching `truncatedInline` rather than the
        // visible-width `fitDisplayWidth` family.
        return truncatedByCount(summary, limit: 160)
    }



    /// Prefixes each created/inserted source line with a stable, right-aligned
    /// local number. The indentation keeps it on the existing highlighted code
    /// area path rather than the metadata-label path.
    nonisolated static func numberedCodeSnippetRows(
        _ text: String,
        indentation: String = "  "
    ) -> [DetailedToolRow] {
        let snippet = detailedToolSnippet(text)
        let numberWidth = String(max(1, snippet.lines.count)).count
        var rendered = snippet.lines.enumerated().map { index, line in
            DetailedToolRow.code(DetailedToolCodeLine(
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
    nonisolated static func numberedDiffSnippetRows(
        old: String,
        new: String,
        contentWidth: Int?,
        indentation: String = "  "
    ) -> [DetailedToolRow] {
        let oldSnippet = detailedToolSnippet(old)
        let newSnippet = detailedToolSnippet(new)
        let availableWidth = max(1, contentWidth ?? terminalColumnCount())
        let dividerWidth = displayWidth(DetailedToolDiffCells.divider)
        let columnWidth = max(
            0,
            (availableWidth - displayWidth(indentation) - dividerWidth) / 2
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
        var rows: [DetailedToolRow] = [
            .diff(DetailedToolDiffCells(
                indentation: indentation,
                oldCell: paddedToDisplayWidth("old", width: columnWidth),
                newCell: paddedToDisplayWidth("new", width: columnWidth)
            ))
        ]
        if oldSnippet.isEmptyPayload || newSnippet.isEmptyPayload {
            // Structural emptiness never enters the LCS input, so an empty side
            // cannot compare equal to — or be confused with — a source line whose
            // literal text is the marker. It is reported once, unnumbered.
            rows.append(.diff(DetailedToolDiffCells(
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
            rows.append(.diff(DetailedToolDiffCells(
                indentation: indentation,
                oldCell: oldCell,
                newCell: newCell
            )))
        }
        return rows
    }










    /// Selects syntax highlighting strictly from the target file extension.
    /// Text, documentation, configuration and unknown extensions stay neutral.
    nonisolated static func codeLanguageHint(for toolCall: DirectAgentToolCall) -> String? {
        let arguments = toolCall.argumentsObject
        let path = normalizedMutationToolName(toolCall.name) == "local.applyPatch"
            ? patchTargetPath(arguments)
            : targetPath(arguments)
        guard let path else { return nil }
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "swift": return "swift"
        case "c", "h": return "c"
        case "cc", "cpp", "cxx", "hh", "hpp", "hxx": return "cpp"
        case "m": return "objc"
        case "js", "jsx", "mjs", "cjs": return "javascript"
        case "ts", "tsx": return "typescript"
        case "py": return "python"
        case "sh", "bash", "zsh": return "shell"
        case "rs": return "rust"
        case "go": return "go"
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "cs": return "csharp"
        case "rb": return "ruby"
        case "php": return "php"
        case "json", "jsonl", "jsonc": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "toml"
        case "html", "htm": return "html"
        case "xml": return "xml"
        case "css": return "css"
        case "sql": return "sql"
        default: return nil
        }
    }

    /// Converts a mutation payload into its complete sequence of source lines.
    /// Writes and both sides of an edit use this shared basis so line numbers
    /// stay consistent. It deliberately does not trim or
    /// de-indent source: empty files, trailing newlines and whitespace-only
    /// changes are semantically meaningful mutation payloads.
    private nonisolated static func detailedToolSnippet(_ text: String) -> DetailedToolSnippet {
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
    private nonisolated static let detailedToolEmptyPayloadMarker = "<empty>"

    /// Prefixes each created/inserted source line with a stable, right-aligned
    /// local number. The indentation keeps it on the existing highlighted code
    /// area path rather than the metadata-label path.
    nonisolated static func numberedCodeSnippetLines(
        _ text: String,
        indentation: String = "  "
    ) -> [String] {
        numberedCodeSnippetRows(text, indentation: indentation).map(\.plainText)
    }

    /// Minimum useful width for each source cell in a side-by-side expanded
    /// diff. With the standard two-cell indentation and three-cell divider,
    /// this documents a 53-cell content-width threshold (2 + 3 + 24 * 2).
    /// At or below a smaller budget the renderer uses stacked unified `-` / `+`
    /// rows rather than squeezing source code into unusably narrow columns.
    nonisolated static let detailedToolSideBySideDiffMinimumCellWidth = 24

    /// Renders old and new edit payloads side by side when both columns can
    /// retain useful source context. Narrow terminals receive a unified,
    /// stacked `-` / `+` view, which the detailed wrapper safely reflows without
    /// horizontal scrolling.
    nonisolated static func numberedDiffSnippetLines(
        old: String,
        new: String,
        contentWidth: Int?,
        indentation: String = "  "
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
    private nonisolated static func numberedUnifiedDiffSnippetRows(
        old: DetailedToolSnippet,
        new: DetailedToolSnippet,
        indentation: String
    ) -> [DetailedToolRow] {
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
        ) -> DetailedToolRow {
            .unifiedDiff(DetailedToolUnifiedDiffLine(
                indentation: indentation,
                marker: marker,
                lineNumber: lineNumber(lineIndex),
                content: terminalSafeSnippetLine(content)
            ))
        }

        var rows: [DetailedToolRow] = []
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
    private nonisolated static func detailedToolDiffRows(
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

    private nonisolated static func detailedToolDiffCell(
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
    private nonisolated static func detailedToolEmptyPayloadCell(
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
    private nonisolated static func normalizedTerminalLineEndings(_ text: String) -> String {
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
    private nonisolated static func terminalSafeSnippetLine(_ line: String) -> String {
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
    private nonisolated static func controlPicture(for character: Character) -> Character? {
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

    private nonisolated static func paddedLineNumber(_ number: Int, width: Int) -> String {
        let text = String(number)
        return String(repeating: " ", count: max(0, width - text.count)) + text
    }

    private nonisolated static func paddedToDisplayWidth(_ text: String, width: Int) -> String {
        text + String(repeating: " ", count: max(0, width - displayWidth(text)))
    }

    private nonisolated static func appendSnippetMarkers(
        to rows: inout [DetailedToolRow],
        snippet: DetailedToolSnippet,
        indentation: String,
        numberWidth: Int
    ) {
        let blankLineNumber = String(repeating: " ", count: numberWidth)
        if snippet.isEmptyPayload {
            // Structural emptiness: no line number is assigned, so this row is
            // distinct from a numbered line whose content is literally the
            // marker text.
            rows.append(.code(DetailedToolCodeLine(
                indentation: indentation,
                lineNumber: blankLineNumber,
                content: detailedToolEmptyPayloadMarker
            )))
        }
    }
}
