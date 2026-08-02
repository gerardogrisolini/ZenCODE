//
//  TerminalInteractiveLineReader+History.swift
//  ZenCODE
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

extension TerminalInteractiveLineReader {
    func recordHistory(_ line: String) {
        withPanelLock { state in
            recordHistoryLocked(line, state: &state)
        }
    }

    func recordHistoryLocked(_ line: String, state: inout State) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty,
              state.history.last != trimmedLine else {
            return
        }
        state.history.append(trimmedLine)
        // The history outlives every prompt and is copied into the editor
        // context on each keystroke, so it is bounded rather than allowed to
        // grow for the lifetime of the process.
        if state.history.count > Self.maximumHistoryEntryCount {
            let overflow = state.history.count - Self.maximumHistoryEntryCount
            state.history.removeFirst(overflow)
            if let index = state.historyIndex {
                state.historyIndex = index >= overflow ? index - overflow : nil
            }
        }
    }

    /// Line-scoped `Home`/`End` targets, shared with the reducer's geometry so
    /// both agree on what a logical line is.
    static func homeCursorIndex(in buffer: [Character], cursorIndex: Int) -> Int {
        var editor = TerminalPromptEditor()
        editor.buffer = buffer
        return editor.lineRange(containing: cursorIndex).lowerBound
    }

    static func endCursorIndex(in buffer: [Character], cursorIndex: Int) -> Int {
        var editor = TerminalPromptEditor()
        editor.buffer = buffer
        return editor.lineRange(containing: cursorIndex).upperBound
    }

    struct RenderLayout: Equatable {
        let text: String
        let lineCount: Int
        let cursorRow: Int
        let cursorColumn: Int
    }

    /// Terminal tab stops conventionally occur every eight cells. Expanding
    /// tabs ourselves, rather than emitting a literal tab, makes the layout
    /// independent of a terminal's configurable tab-stop table.
    static let renderTabStopWidth = 8

    /// Builds a deterministic, terminal-safe representation of the prompt and
    /// buffer. Keeping one column free prevents the terminal-dependent
    /// auto-wrap behaviour at its final column; all wraps are instead explicit
    /// CRLFs that can be counted and revisited on the next redraw.
    static func renderLayout(
        prompt: String,
        buffer: [Character],
        cursorIndex: Int,
        terminalColumns: Int
    ) -> RenderLayout {
        let safeLineWidth = max(1, terminalColumns - 1)
        let boundedCursorIndex = min(max(cursorIndex, 0), buffer.count)
        var text = ""
        var row = 0
        var column = 0
        var cursorRow = 0
        var cursorColumn = 0

        func appendCell(_ character: Character) {
            let width = TerminalANSIText.visibleWidth(of: character)
            if width > 0, column > 0, column + width > safeLineWidth {
                text += "\r\n"
                row += 1
                column = 0
            }
            text.append(character)
            column += width
        }

        func appendTab() {
            let spacesToNextTabStop = Self.renderTabStopWidth
                - (column % Self.renderTabStopWidth)
            for _ in 0..<spacesToNextTabStop {
                appendCell(" ")
            }
        }

        func append(_ character: Character) {
            switch character {
            case "\n":
                // Raw input keeps output processing enabled, but using CRLF
                // explicitly also makes the column reset independent of the
                // terminal's ONLCR setting.
                text += "\r\n"
                row += 1
                column = 0
            case "\t":
                appendTab()
            default:
                appendCell(character)
            }
        }

        func appendEscapeSequence(
            in characters: [Character],
            from start: Int,
            to end: Int
        ) {
            // ANSI control sequences affect rendition or terminal state but
            // never the cursor column. Append their complete range at once so
            // no renderer-inserted CRLF can appear inside CSI or OSC data.
            text += String(characters[start..<end])
        }

        func appendCharacters(_ characters: [Character]) {
            var index = 0
            while index < characters.count {
                let escapeEnd = ansiEscapeEnd(in: characters, from: index)
                if escapeEnd > index + 1 {
                    appendEscapeSequence(
                        in: characters,
                        from: index,
                        to: escapeEnd
                    )
                    index = escapeEnd
                } else {
                    append(characters[index])
                    index += 1
                }
            }
        }

        appendCharacters(Array(prompt))

        var index = 0
        while index < buffer.count {
            let escapeEnd = ansiEscapeEnd(in: buffer, from: index)
            if boundedCursorIndex >= index, boundedCursorIndex < escapeEnd {
                cursorRow = row
                cursorColumn = column
            }
            if escapeEnd > index + 1 {
                appendEscapeSequence(in: buffer, from: index, to: escapeEnd)
                index = escapeEnd
            } else {
                append(buffer[index])
                index += 1
            }
        }
        if boundedCursorIndex == buffer.count {
            cursorRow = row
            cursorColumn = column
        }

        return RenderLayout(
            text: text,
            lineCount: row + 1,
            cursorRow: cursorRow,
            cursorColumn: cursorColumn
        )
    }

    /// Returns the first index after a CSI or OSC sequence beginning at
    /// `start`. Matching `TerminalANSIText`'s visibility rules here lets the
    /// renderer preserve the sequence as a single zero-width token while it
    /// decides where to introduce explicit physical line breaks.
    private static func ansiEscapeEnd(
        in characters: [Character],
        from start: Int
    ) -> Int {
        guard characters.indices.contains(start), characters[start] == "\u{1B}" else {
            return start + 1
        }
        let markerIndex = start + 1
        guard characters.indices.contains(markerIndex) else {
            return markerIndex
        }

        switch characters[markerIndex] {
        case "[":
            var index = markerIndex + 1
            while characters.indices.contains(index) {
                let scalars = characters[index].unicodeScalars
                if scalars.count == 1,
                   let scalar = scalars.first,
                   (0x40...0x7E).contains(scalar.value) {
                    return index + 1
                }
                index += 1
            }
            return index
        case "]":
            var index = markerIndex + 1
            while characters.indices.contains(index) {
                if characters[index] == "\u{07}" {
                    return index + 1
                }
                if characters[index] == "\u{1B}",
                   characters.indices.contains(index + 1),
                   characters[index + 1] == "\\" {
                    return index + 2
                }
                index += 1
            }
            return index
        default:
            // Unknown ESC sequences still occupy no cells; follow the shared
            // ANSI helper and consume their marker with the ESC byte.
            return markerIndex + 1
        }
    }

    static func lineCount(
        for buffer: [Character],
        prompt: String = "",
        terminalColumns: Int = TerminalChat.terminalColumnCount(forceRefresh: true)
    ) -> Int {
        renderLayout(
            prompt: prompt,
            buffer: buffer,
            cursorIndex: buffer.count,
            terminalColumns: terminalColumns
        ).lineCount
    }

    static func redrawSequence(
        prompt: String,
        buffer: [Character],
        cursorIndex: Int,
        previousLineCount: Int = 1,
        previousCursorRow: Int = 0,
        terminalColumns: Int = TerminalChat.terminalColumnCount(forceRefresh: true)
    ) -> String {
        let layout = renderLayout(
            prompt: prompt,
            buffer: buffer,
            cursorIndex: cursorIndex,
            terminalColumns: terminalColumns
        )
        let effectivePreviousLineCount = max(1, previousLineCount)
        let effectivePreviousCursorRow = min(
            max(previousCursorRow, 0),
            effectivePreviousLineCount - 1
        )
        var sequence = "\r"
        if effectivePreviousLineCount > 1 || effectivePreviousCursorRow > 0 {
            // The cursor can be on any row of the old render, not necessarily
            // the final row. Return to its first row before clearing its full
            // footprint, including rows occupied by a previous wider buffer.
            if effectivePreviousCursorRow > 0 {
                sequence += "\u{1B}[\(effectivePreviousCursorRow)A"
            }
            sequence += "\u{1B}[0J"
        } else {
            sequence += "\u{1B}[2K"
        }
        sequence += layout.text
        let boundedCursorIndex = min(max(cursorIndex, 0), buffer.count)
        guard boundedCursorIndex < buffer.count else {
            return sequence
        }

        let rowsToMoveUp = layout.lineCount - 1 - layout.cursorRow
        if rowsToMoveUp > 0 {
            sequence += "\u{1B}[\(rowsToMoveUp)A"
        }
        sequence += "\r"
        if layout.cursorColumn > 0 {
            sequence += "\u{1B}[\(layout.cursorColumn)C"
        }
        return sequence
    }

    func redraw(
        prompt: String,
        buffer: [Character],
        cursorIndex: Int,
        previousLineCount: Int = 1,
        previousCursorRow: Int = 0,
        terminalColumns: Int = TerminalChat.terminalColumnCount(forceRefresh: true)
    ) {
        AgentOutput.standardError.writeString(
            Self.redrawSequence(
                prompt: prompt,
                buffer: buffer,
                cursorIndex: cursorIndex,
                previousLineCount: previousLineCount,
                previousCursorRow: previousCursorRow,
                terminalColumns: terminalColumns
            )
        )
    }

}
