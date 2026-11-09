//
//  TerminalInteractiveLineReader+History.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
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

    /// Oldest-first prompt input retained only for this execution of `zen`;
    /// conversation creation/loading never replaces it.
    var commandHistory: [String] {
        withPanelLock { $0.history }
    }

    func recordHistoryLocked(_ line: String, state: inout State) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLine.isEmpty else {
            return
        }
        // Retain every submission, including repeats, until the process exits.
        // Array's copy-on-write storage keeps editor context snapshots cheap.
        state.history.append(trimmedLine)
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
}
