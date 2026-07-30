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
    }

    func previousHistory(currentBuffer: [Character]) -> [Character]? {
        withPanelLock { state in
            previousHistoryLocked(currentBuffer: currentBuffer, state: &state)
        }
    }

    func previousHistoryLocked(
        currentBuffer: [Character],
        state: inout State
    ) -> [Character]? {
        guard !state.history.isEmpty else {
            return nil
        }

        if let index = state.historyIndex {
            guard index > 0 else {
                return Array(state.history[0])
            }
            let previousIndex = index - 1
            state.historyIndex = previousIndex
            return Array(state.history[previousIndex])
        }

        state.draftBeforeHistory = currentBuffer
        let previousIndex = state.history.count - 1
        state.historyIndex = previousIndex
        return Array(state.history[previousIndex])
    }

    func nextHistory() -> [Character]? {
        withPanelLock { state in
            nextHistoryLocked(state: &state)
        }
    }

    func nextHistoryLocked(state: inout State) -> [Character]? {
        guard let index = state.historyIndex else {
            return nil
        }

        let nextIndex = index + 1
        guard nextIndex < state.history.count else {
            state.historyIndex = nil
            return state.draftBeforeHistory
        }

        state.historyIndex = nextIndex
        return Array(state.history[nextIndex])
    }

    /// Number of terminal rows the rendered prompt + buffer occupies, based
    /// solely on explicit newline characters. Line wrapping beyond the
    /// terminal width is intentionally ignored: the blocking line reader is
    /// used for short prompts, and the multi-line escape sequence below still
    /// clears past rows even when the estimate is conservative.
    static func lineCount(for buffer: [Character]) -> Int {
        buffer.reduce(into: 1) { count, character in
            if character == "\n" {
                count += 1
            }
        }
    }

    static func redrawSequence(
        prompt: String,
        buffer: [Character],
        cursorIndex: Int,
        previousLineCount: Int = 1
    ) -> String {
        let bufferString = String(buffer)
        let effectivePreviousLineCount = max(1, previousLineCount)
        var sequence = "\r"
        if effectivePreviousLineCount > 1 {
            // The previous render spanned several rows (the buffer contained
            // newlines). `[2K` only clears the cursor's row, so move up to the
            // first row of the previous render and erase to the end of the
            // display; otherwise every redraw reprints the whole buffer and
            // leaves the earlier rows behind, making the prompt appear to
            // duplicate itself across many lines.
            sequence += "\u{1B}[\(effectivePreviousLineCount - 1)A"
            sequence += "\u{1B}[0J"
        } else {
            sequence += "\u{1B}[2K"
        }
        sequence += "\(prompt)\(bufferString)"
        let boundedCursorIndex = min(max(cursorIndex, 0), buffer.count)
        let charactersAfterCursor = buffer.count - boundedCursorIndex
        if charactersAfterCursor > 0 {
            sequence += "\u{1B}[\(charactersAfterCursor)D"
        }
        return sequence
    }

    func redraw(
        prompt: String,
        buffer: [Character],
        cursorIndex: Int,
        previousLineCount: Int = 1
    ) {
        AgentOutput.standardError.writeString(
            Self.redrawSequence(
                prompt: prompt,
                buffer: buffer,
                cursorIndex: cursorIndex,
                previousLineCount: previousLineCount
            )
        )
    }

}
