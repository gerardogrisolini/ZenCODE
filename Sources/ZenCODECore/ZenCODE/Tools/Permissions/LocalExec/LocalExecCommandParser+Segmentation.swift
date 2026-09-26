//
//  Internal pipeline extracted from LocalExecCommandParser.
//

import Foundation

extension LocalExecCommandParser {
// MARK: - Segmentation

    /// Splits a command string into authorization segments at shell separators
    /// (`|`, `|&`, `||`, `&&`, `;`, `&`, and newlines), respecting single and
    /// double quotes, `\` escapes, and treating `$(...)`, backticks, and
    /// process substitution `<(...)`/`>(...)` as opaque (no split inside).
    ///
    /// Quote tracking operates at all nesting levels so that quoted delimiters
    /// (e.g. `'('` inside `$()`) do not corrupt depth tracking.
    static func commandSegments(in command: String) -> [String] {
        let characters = Array(command)
        let heredocScan = scanHeredocs(in: characters)
        return commandSegments(
            characters: characters,
            heredocSkipMask: heredocScan.mask
        )
    }

    /// Segments already-scanned input so candidate extraction can reuse the
    /// heredoc scan when it also needs the expandable bodies.
    static func commandSegments(
        characters: [Character],
        heredocSkipMask: [Bool]
    ) -> [String] {
        var segments: [String] = []
        var current = ""
        var quote = Quote.none
        var isEscaping = false
        var inBacktick = false
        // Shell compound expressions can legally contain unquoted `|`, `||`,
        // `&&`, and newlines that are operators inside the expression rather
        // than command separators. Keep those regions opaque while segmenting.
        var doubleBracketDepth = 0
        var arithmeticCommandDepth = 0
        var casePatternContexts: [CasePatternContext] = []
        // Depth of opaque substitution contexts: $( ), <( ), >( ).
        // A plain grouping `( ... )` is NOT opaque: its inner separators still
        // split (e.g. `(cd x && make)` yields segments).
        var substitutionDepth = 0
        // Records the command-substitution depth at which each `${...}` opened.
        // A `}` inside a nested `$()` must not close an outer parameter expansion.
        var parameterExpansionSubstitutionDepths: [Int] = []
        var index = 0

        func currentCasePatternState() -> CasePatternState? {
            casePatternContexts.last?.state
        }

        func ensureCasePatternContext(for segment: String) {
            guard Self.segmentContainsCaseHeader(segment),
                  currentCasePatternState() != .awaitingPatternEnd else {
                return
            }
            casePatternContexts.append(
                CasePatternContext(state: .awaitingPatternEnd)
            )
        }

        func setCurrentCasePatternState(_ state: CasePatternState) {
            guard !casePatternContexts.isEmpty else {
                casePatternContexts.append(CasePatternContext(state: state))
                return
            }
            let contextIndex = casePatternContexts.count - 1
            casePatternContexts[contextIndex].state = state
            if state == .awaitingPatternEnd {
                casePatternContexts[contextIndex].patternBracketDepth = 0
                casePatternContexts[contextIndex].patternBracketHasMember = false
            }
        }

        func appendCurrentSegment() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(trimmed)
                if Self.segmentContainsCaseTerminator(trimmed) {
                    if !casePatternContexts.isEmpty {
                        casePatternContexts.removeLast()
                    }
                } else {
                    ensureCasePatternContext(for: trimmed)
                }
            }
            current = ""
        }

        while index < characters.count {
            let character = characters[index]

            if index < heredocSkipMask.count, heredocSkipMask[index] {
                index += 1
                continue
            }

            switch quote {
            case .single:
                current.append(character)
                if character == "'" {
                    quote = .none
                }
            case .double:
                current.append(character)
                if isEscaping {
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    quote = .none
                }
            case .none:
                if isEscaping {
                    current.append(character)
                    isEscaping = false
                } else if inBacktick {
                    current.append(character)
                    if character == "`" {
                        inBacktick = false
                    } else if character == "\\" {
                        isEscaping = true
                    }
                } else {
                    if let contextIndex = casePatternContexts.indices.last,
                       casePatternContexts[contextIndex].state == .awaitingPatternEnd,
                       casePatternContexts[contextIndex].patternBracketDepth == 1,
                       character != "[",
                       character != "]",
                       !((character == "!" || character == "^")
                           && !casePatternContexts[contextIndex].patternBracketHasMember) {
                        casePatternContexts[contextIndex].patternBracketHasMember = true
                    }
                    switch character {
                    case "\\":
                        current.append(character)
                        isEscaping = true
                    case "'":
                        current.append(character)
                        quote = .single
                    case "\"":
                        current.append(character)
                        quote = .double
                    case "`":
                        current.append(character)
                        inBacktick = true
                    case "[":
                        ensureCasePatternContext(for: current)
                        if let contextIndex = casePatternContexts.indices.last,
                           casePatternContexts[contextIndex].state == .awaitingPatternEnd,
                           substitutionDepth == 0,
                           parameterExpansionSubstitutionDepths.isEmpty,
                           arithmeticCommandDepth == 0,
                           doubleBracketDepth == 0 {
                            if casePatternContexts[contextIndex].patternBracketDepth == 0 {
                                casePatternContexts[contextIndex].patternBracketDepth = 1
                                casePatternContexts[contextIndex].patternBracketHasMember = false
                            } else if index + 1 < characters.count,
                                      characters[index + 1] == ":"
                                        || characters[index + 1] == "."
                                        || characters[index + 1] == "=" {
                                casePatternContexts[contextIndex].patternBracketDepth += 1
                                casePatternContexts[contextIndex].patternBracketHasMember = true
                            } else if casePatternContexts[contextIndex].patternBracketDepth == 1 {
                                casePatternContexts[contextIndex].patternBracketHasMember = true
                            }
                            current.append(character)
                        } else if substitutionDepth == 0,
                           arithmeticCommandDepth == 0,
                           doubleBracketDepth == 0,
                           index + 1 < characters.count,
                           characters[index + 1] == "[",
                           Self.isCompoundCommandBoundary(current.last),
                           Self.isCompoundCommandBoundary(
                               index + 2 < characters.count ? characters[index + 2] : nil
                           ) {
                            current.append("[[")
                            doubleBracketDepth = 1
                            index += 1
                        } else {
                            current.append(character)
                        }
                    case "]":
                        current.append(character)
                        if let contextIndex = casePatternContexts.indices.last,
                           casePatternContexts[contextIndex].state == .awaitingPatternEnd,
                           substitutionDepth == 0,
                           parameterExpansionSubstitutionDepths.isEmpty,
                           arithmeticCommandDepth == 0,
                           doubleBracketDepth == 0,
                           casePatternContexts[contextIndex].patternBracketDepth > 0 {
                            if casePatternContexts[contextIndex].patternBracketDepth > 1 {
                                casePatternContexts[contextIndex].patternBracketDepth -= 1
                            } else if casePatternContexts[contextIndex].patternBracketHasMember {
                                casePatternContexts[contextIndex].patternBracketDepth = 0
                            } else {
                                // `]` in the first member position is literal.
                                casePatternContexts[contextIndex].patternBracketHasMember = true
                            }
                        } else if substitutionDepth == 0,
                           doubleBracketDepth > 0,
                           index + 1 < characters.count,
                           characters[index + 1] == "]" {
                            current.append("]")
                            doubleBracketDepth -= 1
                            index += 1
                        }
                    case "$":
                        // `$( ... )` opens an opaque substitution context.
                        if index + 1 < characters.count, characters[index + 1] == "(" {
                            current.append("$(")
                            substitutionDepth += 1
                            index += 1
                        } else if index + 1 < characters.count,
                                  characters[index + 1] == "{" {
                            current.append("${")
                            parameterExpansionSubstitutionDepths.append(substitutionDepth)
                            index += 1
                        } else {
                            current.append(character)
                        }
                    case "}":
                        current.append(character)
                        if parameterExpansionSubstitutionDepths.last == substitutionDepth {
                            parameterExpansionSubstitutionDepths.removeLast()
                        }
                    case "<", ">":
                        // Process substitution: `<(...)` or `>(...)`.
                        if index + 1 < characters.count, characters[index + 1] == "(" {
                            current.append(String(character))
                            current.append("(")
                            substitutionDepth += 1
                            index += 1
                        } else {
                            // Plain redirection operator: never a separator.
                            current.append(character)
                        }
                    case "(":
                        // Nested `(` inside a substitution increments depth.
                        // Outside a substitution, plain grouping parentheses
                        // do not open an opaque context.
                        if substitutionDepth > 0 {
                            current.append(character)
                            substitutionDepth += 1
                        } else if arithmeticCommandDepth > 0 {
                            current.append(character)
                            arithmeticCommandDepth += 1
                        } else if doubleBracketDepth == 0,
                                  index + 1 < characters.count,
                                  characters[index + 1] == "(",
                                  Self.isCompoundCommandBoundary(current.last) {
                            current.append("((")
                            arithmeticCommandDepth = 2
                            index += 1
                        } else {
                            current.append(character)
                        }
                    case ")":
                        let currentContainsCaseHeader = Self
                            .segmentContainsCaseHeader(current)
                        if currentContainsCaseHeader {
                            ensureCasePatternContext(for: current)
                        }
                        let closesCasePattern = substitutionDepth == 0
                            && parameterExpansionSubstitutionDepths.isEmpty
                            && arithmeticCommandDepth == 0
                            && doubleBracketDepth == 0
                            && (casePatternContexts.last?.patternBracketDepth ?? 0) == 0
                            && (currentCasePatternState() == .awaitingPatternEnd
                                || currentContainsCaseHeader)
                        current.append(character)
                        if substitutionDepth > 0 {
                            substitutionDepth -= 1
                            if substitutionDepth < 0 { substitutionDepth = 0 }
                        } else if arithmeticCommandDepth > 0 {
                            arithmeticCommandDepth -= 1
                        }
                        if closesCasePattern {
                            if currentContainsCaseHeader {
                                // Keep the `case` header as a harmless segment;
                                // the identity parser knows how to skip it.
                                appendCurrentSegment()
                            } else {
                                // Later branch patterns are syntax, not
                                // commands, but may contain command
                                // substitutions. Wrap them in a synthetic case
                                // header so identity parsing skips the pattern
                                // while nested extraction still sees its input.
                                current = "case _ in \(current)"
                                appendCurrentSegment()
                            }
                            setCurrentCasePatternState(.inBranchBody)
                        }
                    default:
                        if substitutionDepth > 0
                            || !parameterExpansionSubstitutionDepths.isEmpty
                            || doubleBracketDepth > 0
                            || arithmeticCommandDepth > 0 {
                            // Inside an opaque shell expression: never split.
                            current.append(character)
                        } else {
                            switch character {
                            case "|":
                                if current.last == ">" {
                                    // POSIX clobber redirection (`>|`) is one
                                    // operator, not a pipeline. Whitespace keeps
                                    // `> |` intentionally distinct.
                                    current.append(character)
                                } else if Self.segmentContainsCaseTerminator(current) {
                                    appendCurrentSegment()
                                } else {
                                    ensureCasePatternContext(for: current)
                                    if currentCasePatternState() == .awaitingPatternEnd {
                                        // `case ... in foo|bar)` uses `|` as a
                                        // pattern alternative, not a pipeline.
                                        current.append(character)
                                    } else {
                                        appendCurrentSegment()
                                        if index + 1 < characters.count {
                                            let next = characters[index + 1]
                                            if next == "|" || next == "&" {
                                                index += 1
                                            }
                                        }
                                    }
                                }
                            case "&":
                                if index + 1 < characters.count, characters[index + 1] == "&" {
                                    appendCurrentSegment()
                                    index += 1
                                } else if index + 1 < characters.count, characters[index + 1] == ">" {
                                    // `&>` / `&>>` redirection operator, not a separator.
                                    current.append(character)
                                } else if current.last == ">" || current.last == "<" {
                                    // `>&` / `<&` fd redirection (e.g. `2>&1`).
                                    current.append(character)
                                } else {
                                    // Background `&` separator.
                                    appendCurrentSegment()
                                }
                            case ";":
                                appendCurrentSegment()
                                if currentCasePatternState() == .inBranchBody,
                                   index + 1 < characters.count {
                                    let next = characters[index + 1]
                                    if next == ";" {
                                        index += 1
                                        if index + 1 < characters.count,
                                           characters[index + 1] == "&" {
                                            index += 1
                                        }
                                        setCurrentCasePatternState(.awaitingPatternEnd)
                                    } else if next == "&" {
                                        index += 1
                                        setCurrentCasePatternState(.awaitingPatternEnd)
                                    }
                                }
                            case "\n", "\r":
                                if Self.segmentContainsCaseTerminator(current) {
                                    appendCurrentSegment()
                                } else {
                                    ensureCasePatternContext(for: current)
                                    if currentCasePatternState() == .awaitingPatternEnd {
                                        current.append(character)
                                    } else {
                                        appendCurrentSegment()
                                    }
                                }
                            case "#":
                                // Shell comment: only at a word boundary
                                // (preceded by whitespace or segment start).
                                if let last = current.last, !last.isWhitespace {
                                    current.append(character)
                                } else {
                                    while index < characters.count, characters[index] != "\n" {
                                        index += 1
                                    }
                                    // Flush the current segment when the
                                    // comment ends at a newline separator.
                                    if index < characters.count, characters[index] == "\n" {
                                        appendCurrentSegment()
                                    }
                                }
                            default:
                                current.append(character)
                            }
                        }
                    }
                }
            }

            index += 1
        }

        appendCurrentSegment()
        return segments
    }

    enum Quote {
        case none
        case single
        case double
    }

    enum CasePatternState {
        case awaitingPatternEnd
        case inBranchBody
    }

    struct CasePatternContext {
        var state: CasePatternState
        var patternBracketDepth = 0
        var patternBracketHasMember = false
    }

    static func isCompoundCommandBoundary(_ character: Character?) -> Bool {
        guard let character else {
            return true
        }
        return character.isWhitespace || ";|&({".contains(character)
    }

    static func segmentContainsCaseHeader(_ segment: String) -> Bool {
        let words = shellWords(in: segment)
        guard let caseIndex = words.firstIndex(where: {
            !$0.wasQuoted && $0.value == "case"
        }),
        words[..<caseIndex].allSatisfy({
            !$0.wasQuoted && isControlFlowKeyword($0.value)
        }),
        words[(caseIndex + 1)...].contains(where: {
            !$0.wasQuoted && $0.value == "in"
        }) else {
            return false
        }
        return true
    }

    static func segmentContainsCaseTerminator(_ segment: String) -> Bool {
        let words = shellWords(in: segment)
        guard let esacIndex = words.firstIndex(where: {
            !$0.wasQuoted && $0.value == "esac"
        }) else {
            return false
        }
        return words[..<esacIndex].allSatisfy {
            !$0.wasQuoted && caseTerminatorPrefixKeywords.contains($0.value)
        }
    }

    static let caseTerminatorPrefixKeywords: Set<String> = [
        "if", "then", "else", "elif", "while", "until", "do", "!", "{", "}"
    ]
}
