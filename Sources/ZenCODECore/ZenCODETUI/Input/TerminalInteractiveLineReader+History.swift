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

    static func redrawSequence(prompt: String, buffer: [Character], cursorIndex: Int) -> String {
        var sequence = "\r\u{1B}[2K\(prompt)\(String(buffer))"
        let boundedCursorIndex = min(max(cursorIndex, 0), buffer.count)
        let charactersAfterCursor = buffer.count - boundedCursorIndex
        if charactersAfterCursor > 0 {
            sequence += "\u{1B}[\(charactersAfterCursor)D"
        }
        return sequence
    }

    func redraw(prompt: String, buffer: [Character], cursorIndex: Int) {
        AgentOutput.standardError.writeString(
            Self.redrawSequence(prompt: prompt, buffer: buffer, cursorIndex: cursorIndex)
        )
    }

}
