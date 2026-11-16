//
//  LocalExecCommandParser+NestedCommands.swift
//  ZenCODE
//
//  Extraction of nested commands from shell -c payloads and from command,
//  backtick, and process substitutions.
//

import Foundation

extension LocalExecCommandParser {
    /// Extracts the static payload from a shell `-c` invocation
    /// (e.g. `bash -lc 'git status'`) by unwrapping leading prefixes and
    /// looking for a short option group containing `c` (`-c`, `-lc`, `-ec`,
    /// `-cl`) followed by a string argument. Long options (`--norc`,
    /// `--rcfile`, `--restricted`, ...) are never `-c`: they are skipped as
    /// options without an argument.
    /// Returns `nil` when the command is not a shell `-c` invocation.
    ///
    /// Option arguments are not modeled: the argument of `--rcfile FILE`,
    /// `--init-file FILE`, `-o OPTION`, or `-O OPTION`, like a wrapper operand
    /// (`env -u NAME`), reads as a non-option word and ends the search. The
    /// segment then falls back to the shell as a normal candidate, which is
    /// conservative: running it requires the shell's own authorization.
    static func shellDashCPayload(for segment: String) -> String? {
        locatedShellDashCPayload(for: segment)?.text
    }

    /// ``shellDashCPayload(for:)`` with, for each payload character, its index
    /// in `segment`.
    static func locatedShellDashCPayload(for segment: String) -> LocatedText? {
        let words = locatedShellWords(in: segment)

        // Unwrap leading prefixes to find the real command.
        var start = 0
        while start < words.count {
            let word = words[start].word
            if isEnvironmentAssignment(word.value) {
                start += 1; continue
            }
            if !word.wasQuoted && isUnwrappableWrapper(word.value) {
                start += 1
                while start < words.count {
                    if words[start].word.value.hasPrefix("-") && words[start].word.value != "-" {
                        start += 1; continue
                    }
                    if isEnvironmentAssignment(words[start].word.value) {
                        start += 1; continue
                    }
                    break
                }
                continue
            }
            if !word.wasQuoted && isControlFlowKeyword(word.value) {
                start += 1; continue
            }
            if isStandaloneGroupingDelimiter(word.value) {
                start += 1; continue
            }
            if let r = redirectionInfo(for: word.value) {
                if !r.hasAttachedTarget { start += 1 }
                start += 1; continue
            }
            break
        }

        guard start < words.count else { return nil }
        let name = cleanedExecutableName(from: words[start].word.value)
        let basename = (name as NSString).lastPathComponent
        guard ["sh", "bash", "zsh", "dash", "ksh"].contains(basename) else { return nil }

        // Look for a -c option in the remaining words.
        var i = start + 1
        while i < words.count {
            let value = words[i].word.value
            let isOption = value.hasPrefix("-") && value != "-"
            // Only a short option group can carry `c`; `--norc` is not `-c`.
            if isOption && !value.hasPrefix("--") && value.contains("c") {
                if i + 1 < words.count {
                    return words[i + 1].locatedValue
                }
                return nil
            }
            if isOption {
                i += 1; continue
            }
            // Non-option argument before -c: not a -c invocation.
            return nil
        }
        return nil
    }

    /// Extracts the content strings of all `$(...)`, backtick, and process
    /// substitution `<(...)`/`>(...)` in a segment, respecting quotes and
    /// nesting. Inside double quotes, `$(...)` and backticks are still expanded
    /// by the shell and are therefore detected here.
    ///
    /// Arithmetic expansions are traversed too: while `$((...))` is not by
    /// itself a command substitution, shells permit `$(...)` within it.
    static func commandSubstitutionContents(in segment: String) -> [String] {
        locatedCommandSubstitutionContents(in: segment).map(\.text)
    }

    /// ``commandSubstitutionContents(in:)`` with, for each content character,
    /// its index in `segment`. Backtick contents skip the escaping backslashes.
    static func locatedCommandSubstitutionContents(in segment: String) -> [LocatedText] {
        let chars = Array(segment)
        var contents: [LocatedText] = []
        var i = 0
        var inSingle = false
        var inDouble = false
        var escaping = false

        while i < chars.count {
            let c = chars[i]

            if escaping { escaping = false; i += 1; continue }
            if inSingle { if c == "'" { inSingle = false }; i += 1; continue }

            // Detect $(...) command substitution outside single quotes.
            if c == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                // Inspect command substitutions nested inside `$((...))`.
                if i + 2 < chars.count, chars[i + 2] == "(" {
                    let arithmeticEnd = skipBalancedParenContent(chars, from: i + 2)
                    let contentEnd = max(i + 3, arithmeticEnd - 1)
                    if i + 3 <= contentEnd, contentEnd <= chars.count {
                        let arithmeticBody = LocatedText(
                            text: String(chars[(i + 3)..<contentEnd]),
                            origins: ((i + 3)..<contentEnd).map(Optional.some)
                        )
                        contents.append(contentsOf: locatedCommandSubstitutionContents(
                            in: arithmeticBody.text
                        ).map { $0.mapped(through: arithmeticBody.origins) })
                    }
                    // `skipBalancedParenContent` consumes the inner closing
                    // parenthesis; consume the outer arithmetic delimiter too.
                    i = min(arithmeticEnd + 1, chars.count)
                    continue
                }

                // Extract $(...) content with nesting.
                var depth = 1
                var j = i + 2
                var content = LocatedTextBuilder()
                var s = SubstitutionScanner()
                while j < chars.count, depth > 0 {
                    let sc = chars[j]
                    if s.escaping { s.escaping = false; content.append(sc, origin: j); j += 1; continue }
                    if s.inSingle {
                        if sc == "'" { s.inSingle = false }
                        content.append(sc, origin: j); j += 1; continue
                    }
                    if s.inDouble {
                        if sc == "\\" { s.escaping = true }
                        else if sc == "\"" { s.inDouble = false }
                        content.append(sc, origin: j); j += 1; continue
                    }
                    switch sc {
                    case "\\": s.escaping = true; content.append(sc, origin: j)
                    case "'": s.inSingle = true; content.append(sc, origin: j)
                    case "\"": s.inDouble = true; content.append(sc, origin: j)
                    case "(": depth += 1; content.append(sc, origin: j)
                    case ")":
                        depth -= 1
                        if depth > 0 { content.append(sc, origin: j) }
                    default:
                        content.append(sc, origin: j)
                    }
                    j += 1
                }
                if !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    contents.append(content.located)
                }
                i = j
                continue
            }

            // Detect process substitution <(...) or >(...).
            if (c == "<" || c == ">"), i + 1 < chars.count, chars[i + 1] == "(" {
                // Extract process substitution content with nesting.
                var depth = 1
                var j = i + 2
                var content = LocatedTextBuilder()
                var s = SubstitutionScanner()
                while j < chars.count, depth > 0 {
                    let sc = chars[j]
                    if s.escaping { s.escaping = false; content.append(sc, origin: j); j += 1; continue }
                    if s.inSingle {
                        if sc == "'" { s.inSingle = false }
                        content.append(sc, origin: j); j += 1; continue
                    }
                    if s.inDouble {
                        if sc == "\\" { s.escaping = true }
                        else if sc == "\"" { s.inDouble = false }
                        content.append(sc, origin: j); j += 1; continue
                    }
                    switch sc {
                    case "\\": s.escaping = true; content.append(sc, origin: j)
                    case "'": s.inSingle = true; content.append(sc, origin: j)
                    case "\"": s.inDouble = true; content.append(sc, origin: j)
                    case "(": depth += 1; content.append(sc, origin: j)
                    case ")":
                        depth -= 1
                        if depth > 0 { content.append(sc, origin: j) }
                    default:
                        content.append(sc, origin: j)
                    }
                    j += 1
                }
                if !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    contents.append(content.located)
                }
                i = j
                continue
            }

            if c == "`" {
                // Extract backtick content.
                var j = i + 1
                var content = LocatedTextBuilder()
                var btEscaping = false
                while j < chars.count {
                    let bc = chars[j]
                    if btEscaping { btEscaping = false; content.append(bc, origin: j); j += 1; continue }
                    if bc == "\\" { btEscaping = true }
                    else if bc == "`" { break }
                    else { content.append(bc, origin: j) }
                    j += 1
                }
                if !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    contents.append(content.located)
                }
                i = j + 1
                continue
            }

            // Quote tracking.
            if inDouble {
                if c == "\\" { escaping = true }
                else if c == "\"" { inDouble = false }
                i += 1; continue
            }

            switch c {
            case "\\": escaping = true
            case "'": inSingle = true
            case "\"": inDouble = true
            default: break
            }
            i += 1
        }
        return contents
    }

    /// Mutable state for scanning inside a `$(...)` substitution.
    struct SubstitutionScanner {
        var inSingle = false
        var inDouble = false
        var escaping = false
    }

    /// Skips a balanced parenthesised content starting at `start` (which must
    /// point at an opening `(`), respecting quotes. Returns the index just past
    /// the matching `)`. Used to skip `$((...))` arithmetic expansions.
    static func skipBalancedParenContent(_ chars: [Character], from start: Int) -> Int {
        var depth = 0
        var j = start
        var inSingle = false
        var inDouble = false
        var escaping = false

        while j < chars.count {
            let c = chars[j]
            if escaping { escaping = false; j += 1; continue }
            if inSingle { if c == "'" { inSingle = false }; j += 1; continue }
            if inDouble {
                if c == "\\" { escaping = true }
                else if c == "\"" { inDouble = false }
                j += 1; continue
            }
            switch c {
            case "\\": escaping = true
            case "'": inSingle = true
            case "\"": inDouble = true
            case "(": depth += 1
            case ")":
                depth -= 1
                if depth == 0 { return j + 1 }
            default: break
            }
            j += 1
        }
        return j
    }
}
