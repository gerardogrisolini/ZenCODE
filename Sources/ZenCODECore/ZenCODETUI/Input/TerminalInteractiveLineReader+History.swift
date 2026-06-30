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
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty,
              history.last != trimmedLine else {
            return
        }
        history.append(trimmedLine)
    }

    func previousHistory(currentBuffer: [Character]) -> [Character]? {
        guard !history.isEmpty else {
            return nil
        }

        if let index = historyIndex {
            guard index > 0 else {
                return Array(history[0])
            }
            let previousIndex = index - 1
            historyIndex = previousIndex
            return Array(history[previousIndex])
        }

        draftBeforeHistory = currentBuffer
        let previousIndex = history.count - 1
        historyIndex = previousIndex
        return Array(history[previousIndex])
    }

    func nextHistory() -> [Character]? {
        guard let index = historyIndex else {
            return nil
        }

        let nextIndex = index + 1
        guard nextIndex < history.count else {
            historyIndex = nil
            return draftBeforeHistory
        }

        historyIndex = nextIndex
        return Array(history[nextIndex])
    }

    func redraw(prompt: String, buffer: [Character], cursorIndex: Int) {
        AgentOutput.standardError.writeString("\n\u{1B}[2K\(prompt)\(String(buffer))")
        let charactersAfterCursor = buffer.count - cursorIndex
        if charactersAfterCursor > 0 {
            AgentOutput.standardError.writeString("\u{1B}[\(charactersAfterCursor)D")
        }
    }

}
