//
//  LocalExecCommandParser.swift
//  ZenCODE
//
//  Parses `local.exec` command strings to extract authorization-relevant
//  information: pipeline/sequence segmentation and per-segment executable
//  identity. Pure (no side effects).
//

import Foundation

/// Pure helper that segments `local.exec` command strings into individual
/// commands and extracts the executable identity that should be authorized,
/// stripping shell noise (redirections, environment assignments, built-ins,
/// control keywords, grouping delimiters) so prompts surface the real
/// executable instead of tokens like `true` or `FOO=bar`.
enum LocalExecCommandParser {
    /// Result of identifying the executable for an authorization segment.
    enum Identity: Equatable, Sendable {
        /// A concrete executable name worth prompting for (e.g. `swift`).
        case executable(String)
        /// A harmless shell built-in or control keyword that should not be
        /// prompted for (e.g. `true`, `cd`).
        case skip
        /// The parser could not confidently resolve the executable; fall back
        /// to the first raw token (legacy behaviour) for safety.
        case unresolved(String)
    }

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
        var segments: [String] = []
        var current = ""
        var quote = Quote.none
        var isEscaping = false
        var inBacktick = false
        // Depth of opaque substitution contexts: $( ), <( ), >( ).
        // A plain grouping `( ... )` is NOT opaque: its inner separators still
        // split (e.g. `(cd x && make)` yields segments).
        var substitutionDepth = 0
        var index = 0

        func appendCurrentSegment() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                segments.append(trimmed)
            }
            current = ""
        }

        while index < characters.count {
            let character = characters[index]

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
                    case "$":
                        // `$( ... )` opens an opaque substitution context.
                        if index + 1 < characters.count, characters[index + 1] == "(" {
                            current.append("$(")
                            substitutionDepth += 1
                            index += 1
                        } else {
                            current.append(character)
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
                        current.append(character)
                        if substitutionDepth > 0 {
                            substitutionDepth += 1
                        }
                    case ")":
                        current.append(character)
                        if substitutionDepth > 0 {
                            substitutionDepth -= 1
                            if substitutionDepth < 0 { substitutionDepth = 0 }
                        }
                    default:
                        if substitutionDepth > 0 {
                            // Inside a substitution: never split.
                            current.append(character)
                        } else {
                            switch character {
                            case "|":
                                appendCurrentSegment()
                                if index + 1 < characters.count {
                                    let next = characters[index + 1]
                                    if next == "|" || next == "&" {
                                        index += 1
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
                            case ";", "\n", "\r":
                                appendCurrentSegment()
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
        if segments.isEmpty {
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        return segments
    }

    private enum Quote {
        case none
        case single
        case double
    }

    // MARK: - Executable identity

    /// Extracts the authorization identity for a single command segment by
    /// stripping environment assignments, redirections, grouping delimiters,
    /// control-flow keywords, wrapper commands, and quote characters, then
    /// classifying the first remaining token.
    static func executableIdentity(for segment: String) -> Identity {
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
                skippingLeadingAssignments = true
                index += 1
                // After a wrapper, also skip leading options (`-i`, `--`, `-p`).
                while index < words.count {
                    let nextWord = words[index]
                    if nextWord.value.hasPrefix("-") {
                        index += 1
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
                    // redirections or substitutions that could have side
                    // effects (e.g. `: > victim`, `true > file`).
                    if segmentHasRedirectionOrSubstitution(segment) {
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

    /// Returns `true` when the segment contains a shell redirection operator
    /// (`>`, `>>`, `<`, `2>&1`, `&>`, etc.) or a command/ process substitution
    /// (`$(...)`, backtick, `<(...)`) that could have side effects.
    private static func segmentHasRedirectionOrSubstitution(_ segment: String) -> Bool {
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
            case "$":
                if i + 1 < chars.count, chars[i + 1] == "(" { return true }
            case "`":
                return true
            case ">":
                // `>&` or `>` or `>>` etc.
                return true
            case "<":
                // `<<<`, `<<`, `<(` etc.
                return true
            case "&":
                if i + 1 < chars.count, chars[i + 1] == ">" { return true }
            default:
                break
            }
            i += 1
        }
        return false
    }

    // MARK: - Tokenization

    /// A shell word with quote provenance.
    private struct ShellWord: Equatable {
        /// The token value with surrounding quotes stripped.
        let value: String
        /// `true` when the token was fully enclosed in quotes (so it is a
        /// literal path, not a shell keyword).
        let wasQuoted: Bool
    }

    /// Tokenizes a segment into shell words, respecting quotes and escapes.
    private static func shellWords(in segment: String) -> [ShellWord] {
        let characters = Array(segment)
        var words: [ShellWord] = []
        var current = ""
        var quote = Quote.none
        var isEscaping = false
        var hadQuoteChar = false
        var index = 0

        func flushWord() {
            if !current.isEmpty {
                words.append(ShellWord(value: current, wasQuoted: hadQuoteChar))
            }
            current = ""
            hadQuoteChar = false
        }

        while index < characters.count {
            let character = characters[index]

            switch quote {
            case .single:
                if character == "'" {
                    quote = .none
                } else {
                    current.append(character)
                }
            case .double:
                if isEscaping {
                    current.append("\\")
                    current.append(character)
                    isEscaping = false
                } else if character == "\\" {
                    isEscaping = true
                } else if character == "\"" {
                    quote = .none
                } else {
                    current.append(character)
                }
            case .none:
                if isEscaping {
                    current.append("\\")
                    current.append(character)
                    isEscaping = false
                } else if character.isWhitespace {
                    flushWord()
                } else if character == "'" {
                    quote = .single
                    hadQuoteChar = true
                } else if character == "\"" {
                    quote = .double
                    hadQuoteChar = true
                } else {
                    current.append(character)
                }
            }

            index += 1
        }

        flushWord()
        return words
    }

    /// Removes leading/trailing grouping delimiters from a raw token to recover
    /// the bare executable name.
    private static func cleanedExecutableName(from token: String) -> String {
        var name = token

        // Strip leading grouping delimiters: `(cd` -> `cd`, `{make` -> `make`.
        while let first = name.first, first == "(" || first == "{" {
            name.removeFirst()
        }
        // Strip trailing grouping delimiters: `make)` -> `make`.
        while let last = name.last, last == ")" || last == "}" {
            name.removeLast()
        }

        return name
    }

    // MARK: - Classifiers

    /// Conservative skip-list of harmless shell built-ins that never trigger an
    /// authorization prompt (when they appear unquoted and without
    /// redirections). Control-flow keywords are NOT here: they are handled as
    /// syntactic prefixes in `executableIdentity`.
    private static let skippableBuiltins: Set<String> = [
        // Result built-ins.
        "true", "false", ":",
        // Directory/state built-ins.
        "cd", "pwd", "pushd", "popd", "dirs",
        // Conditional built-ins.
        "test", "[", "[["
    ]

    /// Shell control-flow keywords. When they appear as a leading token, the
    /// parser consumes them and continues scanning for the real executable.
    private static let controlFlowKeywords: Set<String> = [
        "if", "then", "else", "elif", "fi",
        "for", "while", "until", "do", "done",
        "case", "esac", "in",
        "function", "select",
        "!", "{", "}"
    ]

    private static func isControlFlowKeyword(_ token: String) -> Bool {
        Self.controlFlowKeywords.contains(token)
    }

    /// Matches leading environment assignments: `NAME=value`, where NAME is
    /// `[A-Za-z_][A-Za-z0-9_]*` and an `=` is present.
    private static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard token.contains("=") else { return false }
        let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
        guard let first = name.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Command wrappers that precede the real command and should be unwrapped.
    /// `sudo` and `xargs` are intentionally NOT unwrapped: they are themselves
    /// risk gates.
    private static func isUnwrappableWrapper(_ token: String) -> Bool {
        Self.wrappers.contains(token)
    }

    private static let wrappers: Set<String> = [
        "env", "command", "exec", "nohup", "time"
    ]

    /// Returns `true` for standalone grouping delimiters `(`, `)`, `{`, `}`.
    private static func isStandaloneGroupingDelimiter(_ token: String) -> Bool {
        token == "(" || token == ")" || token == "{" || token == "}"
    }

    /// Classifies a redirection token. Returns `nil` when the token is not a
    /// redirection. `hasAttachedTarget` indicates whether the redirection
    /// already carries its target within this token.
    private static func redirectionInfo(for token: String) -> (isRedirection: Bool, hasAttachedTarget: Bool)? {
        guard let body = redirectionOperatorBody(of: token) else {
            return nil
        }
        let remainder = String(token.dropFirst(body.count))
        let hasAttachedTarget = !remainder.isEmpty
        return (true, hasAttachedTarget)
    }

    /// Returns the leading redirection operator portion of a token, if any.
    /// Recognizes: `>`, `>>`, `<`, `<<`, `>&`, `<&`, `&>`, `&>>`, optional fd
    /// prefix (`2>`, `2>>`, `2>&1`, `1>&2`).
    private static func redirectionOperatorBody(of token: String) -> String? {
        let chars = Array(token)
        guard !chars.isEmpty else { return nil }

        var prefix = 0
        // Optional leading `&` (e.g. `&>`).
        if chars[prefix] == "&" {
            prefix += 1
        } else {
            // Optional leading file-descriptor digits (e.g. `2` in `2>`).
            while prefix < chars.count, chars[prefix].isNumber {
                prefix += 1
            }
        }

        guard prefix < chars.count else { return nil }
        let arrow = chars[prefix]
        guard arrow == ">" || arrow == "<" else { return nil }
        prefix += 1

        // Optional second arrow/ampersand: `>>`, `<<`, `>&`, `<&`.
        if prefix < chars.count, chars[prefix] == arrow {
            prefix += 1
        } else if prefix < chars.count, chars[prefix] == "&" {
            prefix += 1
        }

        return String(chars.prefix(prefix))
    }
}
