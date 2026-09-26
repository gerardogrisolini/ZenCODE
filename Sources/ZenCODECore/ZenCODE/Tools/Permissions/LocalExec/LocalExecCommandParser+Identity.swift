//
//  Internal pipeline extracted from LocalExecCommandParser.
//

import Foundation

extension LocalExecCommandParser {
// MARK: - Executable identity

    /// Extracts the authorization identity for a single command segment by
    /// stripping environment assignments, redirections, grouping delimiters,
    /// control-flow keywords, wrapper commands, and quote characters, then
    /// classifying the first remaining token.
    static func executableIdentity(for segment: String) -> Identity {
        let trimmedSegment = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        if Self.isStandaloneGroupingDelimiter(trimmedSegment) {
            return .skip
        }
        let compoundSegment = strippingLeadingCompoundExpressionKeywords(from: trimmedSegment)
        if compoundSegment.hasPrefix("(("),
           let trailingText = arithmeticCommandTrailingText(in: compoundSegment) {
            // Arithmetic evaluation is a shell construct, not an executable.
            // Nested command substitutions are extracted separately. Anything
            // after the balanced expression is retained conservatively.
            return trailingText.isEmpty ? .skip : .executable("((")
        }
        if startsExtendedTest(compoundSegment),
           let trailingText = extendedTestTrailingText(in: compoundSegment) {
            // Operators such as `>`, `<`, `&&`, and `||` inside `[[ ... ]]`
            // belong to the conditional expression. Only syntax following the
            // balanced closing token can turn the builtin into a side effect.
            return trailingText.isEmpty ? .skip : .executable("[[")
        }

        let words = shellWords(in: segment)
        guard !words.isEmpty else {
            return .unresolved(segment.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        var index = 0
        var skipNextAsRedirectTarget = false
        // Environment assignments are only meaningful as a leading prefix
        // (before the actual command). Once we consume a non-assignment token,
        // we stop treating subsequent tokens as assignments.
        var skippingLeadingAssignments = true
        var sawAnyAssignment = false
        var sawAnyKeyword = false

        while index < words.count {
            let word = words[index]

            if skipNextAsRedirectTarget {
                skipNextAsRedirectTarget = false
                index += 1
                continue
            }

            // Redirection operators (with or without an attached target).
            if let redirect = redirectionInfo(for: word.value) {
                if !redirect.hasAttachedTarget {
                    skipNextAsRedirectTarget = true
                }
                index += 1
                continue
            }

            // Standalone grouping delimiters: `(`, `)`, `{`, `}`.
            if isStandaloneGroupingDelimiter(word.value) {
                index += 1
                continue
            }

            // Leading environment assignments: `NAME=value`.
            if skippingLeadingAssignments && isEnvironmentAssignment(word.value) {
                sawAnyAssignment = true
                index += 1
                continue
            }

            // Command wrappers: unwrap `env`, `command`, `exec`, `nohup`,
            // `time` and keep scanning for the real command. Following
            // assignments (e.g. `env A=1 swift`) and options (e.g. `env -i`)
            // are still skipped.
            if !word.wasQuoted && isUnwrappableWrapper(word.value) {
                let wrapperName = word.value
                skippingLeadingAssignments = true
                index += 1
                // After a wrapper, also skip leading options (`-i`, `--`, `-p`).
                while index < words.count {
                    let nextWord = words[index]
                    if nextWord.value == "--" {
                        index += 1
                        break
                    }
                    if nextWord.value.hasPrefix("-") && nextWord.value != "-" {
                        let info = wrapperOptionInfo(wrapper: wrapperName, option: nextWord.value)
                        if info == .introspection {
                            return .skip
                        }
                        index += 1
                        if info == .consumesOperand {
                            index += 1
                        }
                        continue
                    }
                    if isEnvironmentAssignment(nextWord.value) {
                        index += 1
                        continue
                    }
                    break
                }
                continue
            }

            // Control-flow keywords: consume them as syntactic prefixes and
            // keep scanning for the real executable. `if true; then rm; fi`
            // yields segments like `then rm`, and `then` is consumed so `rm`
            // surfaces for authorization.
            if !word.wasQuoted && isControlFlowKeyword(word.value) {
                // Header keywords (`for`, `select`) introduce a non-executable
                // header (`for x in a b`) whose body lives in a separate `do`
                // segment, so skip the whole header segment to avoid surfacing
                // the loop variable as a false executable.
                if Self.headerKeywords.contains(word.value) {
                    return .skip
                }
                // `case` shares its segment with the first branch body
                // (`case x in x) rm ...`). Consume `case`, the subject, `in`,
                // and the pattern up to and including its terminating `)`, then
                // keep scanning so the branch command surfaces.
                if word.value == "case" {
                    index += 1
                    // Skip the subject token.
                    if index < words.count { index += 1 }
                    // Skip an optional `in`.
                    if index < words.count, words[index].value == "in" { index += 1 }
                    // Skip pattern tokens until one contains the terminating `)`.
                    while index < words.count {
                        let patternWord = words[index]
                        index += 1
                        if patternWord.value.contains(")") { break }
                    }
                    sawAnyKeyword = true
                    continue
                }
                sawAnyKeyword = true
                index += 1
                continue
            }

            // First real token reached: classify it.
            skippingLeadingAssignments = false
            let cleaned = cleanedExecutableName(from: word.value)
            if cleaned.isEmpty {
                index += 1
                continue
            }
            // A quoted token was explicitly quoted by the user, so it is a
            // literal path, not a shell keyword. Only apply skip-list logic to
            // unquoted tokens.
            if !word.wasQuoted {
                if skippableBuiltins.contains(cleaned) {
                    // C2: a built-in is only harmless if the segment has no
                    // redirections that could read or modify files (e.g.
                    // `: > victim`, `true < input`). Commands inside
                    // substitutions are extracted independently below.
                    if segmentHasRedirection(segment) {
                        return .executable(cleaned)
                    }
                    return .skip
                }
            }
            return .executable(cleaned)
        }

        // All tokens were consumed without finding a command (e.g. pure
        // redirections, only environment assignments, or only control-flow
        // keywords). Assignments and keyword-only segments are harmless.
        if sawAnyAssignment || sawAnyKeyword {
            return .skip
        }
        // Pure redirections or unknown constructs: fall back conservatively.
        let firstRaw = words.first?.value ?? segment.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleaned = cleanedExecutableName(from: firstRaw)
        if cleaned.isEmpty {
            return .unresolved(segment.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return .executable(cleaned)
    }

    static let compoundExpressionPrefixKeywords: Set<String> = [
        "if", "then", "else", "elif", "while", "until", "do", "!", "{"
    ]

    static func strippingLeadingCompoundExpressionKeywords(
        from segment: String
    ) -> String {
        var remainder = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        while true {
            let words = shellWords(in: remainder)
            guard let first = words.first,
                  !first.wasQuoted,
                  compoundExpressionPrefixKeywords.contains(first.value),
                  remainder.hasPrefix(first.value) else {
                return remainder
            }
            let endIndex = remainder.index(remainder.startIndex, offsetBy: first.value.count)
            if endIndex < remainder.endIndex,
               !remainder[endIndex].isWhitespace {
                return remainder
            }
            remainder = String(remainder[endIndex...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    static func startsExtendedTest(_ segment: String) -> Bool {
        let characters = Array(segment)
        guard characters.count >= 2,
              characters[0] == "[",
              characters[1] == "[" else {
            return false
        }
        return characters.count == 2 || isCompoundCommandBoundary(characters[2])
    }

    /// Returns text following a balanced top-level `(( ... ))` arithmetic
    /// command. Nil means the construct is unbalanced and must fall through to
    /// conservative executable parsing rather than being silently skipped.
    static func arithmeticCommandTrailingText(in segment: String) -> String? {
        let characters = Array(segment)
        guard characters.count >= 4, characters[0] == "(", characters[1] == "(" else {
            return nil
        }

        var depth = 0
        var quote = Quote.none
        var escaping = false
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch quote {
            case .single:
                if character == "'" { quote = .none }
            case .double:
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    quote = .none
                }
            case .none:
                if escaping {
                    escaping = false
                } else {
                    switch character {
                    case "\\": escaping = true
                    case "'": quote = .single
                    case "\"": quote = .double
                    case "(": depth += 1
                    case ")":
                        depth -= 1
                        if depth == 0 {
                            return String(characters.dropFirst(index + 1))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    default: break
                    }
                }
            }
            index += 1
        }
        return nil
    }

    /// Returns text following a balanced top-level `[[ ... ]]` expression.
    /// Quoted and substitution-contained `]]` text does not close the command.
    static func extendedTestTrailingText(in segment: String) -> String? {
        let characters = Array(segment)
        guard characters.count >= 4, characters[0] == "[", characters[1] == "[" else {
            return nil
        }

        var quote = Quote.none
        var escaping = false
        var inBacktick = false
        var substitutionDepth = 0
        var index = 2
        while index < characters.count {
            let character = characters[index]
            switch quote {
            case .single:
                if character == "'" { quote = .none }
            case .double:
                if escaping {
                    escaping = false
                } else if character == "\\" {
                    escaping = true
                } else if character == "\"" {
                    quote = .none
                }
            case .none:
                if escaping {
                    escaping = false
                } else if inBacktick {
                    if character == "`" {
                        inBacktick = false
                    } else if character == "\\" {
                        escaping = true
                    }
                } else {
                    switch character {
                    case "\\": escaping = true
                    case "'": quote = .single
                    case "\"": quote = .double
                    case "`": inBacktick = true
                    case "$":
                        if index + 1 < characters.count, characters[index + 1] == "(" {
                            substitutionDepth += 1
                            index += 1
                        }
                    case "(":
                        if substitutionDepth > 0 { substitutionDepth += 1 }
                    case ")":
                        if substitutionDepth > 0 { substitutionDepth -= 1 }
                    case "]":
                        if substitutionDepth == 0,
                           index + 1 < characters.count,
                           characters[index + 1] == "]" {
                            return String(characters.dropFirst(index + 2))
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                        }
                    default: break
                    }
                }
            }
            index += 1
        }
        return nil
    }

    /// Returns `true` when the segment contains a shell redirection operator
    /// (`>`, `>>`, `<`, `2>&1`, `&>`, etc.). Process substitutions are excluded:
    /// their nested commands are extracted independently.
    static func segmentHasRedirection(_ segment: String) -> Bool {
        let chars = Array(segment)
        var i = 0
        var inSingle = false
        var inDouble = false
        var escaping = false

        while i < chars.count {
            let c = chars[i]

            if escaping {
                escaping = false
                i += 1
                continue
            }
            if inSingle {
                if c == "'" { inSingle = false }
                i += 1
                continue
            }
            if inDouble {
                if c == "\\" { escaping = true }
                else if c == "\"" { inDouble = false }
                i += 1
                continue
            }

            switch c {
            case "\\":
                escaping = true
            case "'":
                inSingle = true
            case "\"":
                inDouble = true
            case ">":
                if i + 1 >= chars.count || chars[i + 1] != "(" {
                    return true
                }
            case "<":
                if i + 1 >= chars.count || chars[i + 1] != "(" {
                    return true
                }
            case "&":
                if i + 1 < chars.count, chars[i + 1] == ">" { return true }
            default:
                break
            }
            i += 1
        }
        return false
    }
}
