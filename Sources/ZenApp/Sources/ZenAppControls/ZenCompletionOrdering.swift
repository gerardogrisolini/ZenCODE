//
//  ZenCompletionOrdering.swift
//  ZenApp
//
//  The order the composer's completion menus share: the candidates whose
//  command starts with the typed prefix, the exact matches first, as the
//  terminal UI's `TerminalPromptCompletion.ordered`.
//

import Foundation

/// The candidates whose `command` starts with `prefix`, in their order, with
/// the exact matches first.
func zenOrderedCompletions<Candidate>(
    _ candidates: [Candidate],
    prefix: String,
    command: (Candidate) -> String
) -> [Candidate] {
    let matches = candidates.filter { command($0).hasPrefix(prefix) }
    let exactMatches = matches.filter { command($0) == prefix }
    guard !exactMatches.isEmpty else {
        return matches
    }
    return exactMatches + matches.filter { command($0) != prefix }
}
