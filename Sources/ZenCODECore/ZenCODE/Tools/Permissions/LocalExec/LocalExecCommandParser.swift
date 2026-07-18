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

    /// A structured authorization candidate extracted from a command string.
    /// Carries the canonical executable identity (for dedup/cache/persistence)
    /// and a cleaned significant invocation (for display/authorization).
    struct AuthorizationCandidate: Equatable, Sendable {
        let identity: String
        let invocation: String
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
        let heredocSkipMask = Self.heredocBodySkipMask(in: characters)
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

    /// Keywords that introduce a multi-token header whose remaining tokens are
    /// not executables and whose body lives in a separate segment (e.g.
    /// `for x in a b; do CMD; done`, `select x in a b; do CMD; done`). When
    /// encountered as a leading unquoted keyword, the entire segment is treated
    /// as `.skip`. `case` is NOT here: its branch body shares the segment with
    /// the pattern, so it needs dedicated handling.
    private static let headerKeywords: Set<String> = [
        "for", "select"
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

    // MARK: - Wrapper option classification

    /// How a wrapper option interacts with following tokens.
    private enum WrapperOptionKind {
        /// Option that does not consume an operand (e.g. `env -i`).
        case none
        /// Option that consumes the next token as its argument (e.g. `env -u NAME`).
        case consumesOperand
        /// Option that indicates introspection, not execution (e.g. `command -v`).
        case introspection
    }

    /// Classifies a wrapper option to determine how many additional tokens it
    /// consumes or whether it indicates non-execution.
    private static func wrapperOptionInfo(
        wrapper: String,
        option: String
    ) -> WrapperOptionKind {
        // Strip leading dashes.
        let opt = option.drop(while: { $0 == "-" })
        switch wrapper {
        case "command":
            // `command -v` / `command -V` perform path lookup, not execution.
            if opt.contains("v") || opt.contains("V") { return .introspection }
            return .none
        case "env":
            // `env -u NAME` unsets a variable; `-C DIR` changes directory.
            // `-S` consumes the rest as a string; `-P` consumes a path.
            if opt.contains("u") || opt.contains("C") || opt.contains("P") {
                return .consumesOperand
            }
            return .none
        case "time":
            // `time -o FILE` redirects timing output.
            if opt.contains("o") { return .consumesOperand }
            return .none
        default:
            return .none
        }
    }

    // MARK: - Heredoc body detection

    /// Result of scanning a command for heredoc bodies.
    private struct HeredocScan {
        /// Character indices that belong to heredoc bodies (masked during
        /// segmentation).
        var mask: [Bool]
        /// Body text of heredocs whose delimiter is unquoted. The shell expands
        /// `$(...)` and backticks in these bodies, so their command
        /// substitutions must still be authorized.
        var unquotedBodies: [String]
    }

    /// Returns a boolean mask marking character indices that belong to heredoc
    /// bodies. These characters are skipped during segmentation so that heredoc
    /// content is not mistaken for executable commands.
    private static func heredocBodySkipMask(in characters: [Character]) -> [Bool] {
        scanHeredocs(in: characters).mask
    }

    /// Returns the bodies of unquoted heredocs, whose command substitutions the
    /// shell still expands.
    private static func unquotedHeredocBodies(in command: String) -> [String] {
        scanHeredocs(in: Array(command)).unquotedBodies
    }

    private static func scanHeredocs(in characters: [Character]) -> HeredocScan {
        var mask = Array(repeating: false, count: characters.count)
        var unquotedBodies: [String] = []
        var i = 0
        var inSingle = false
        var inDouble = false
        var escaping = false
        var inBacktick = false
        var substDepth = 0

        while i < characters.count {
            let c = characters[i]

            if escaping { escaping = false; i += 1; continue }
            if inSingle {
                if c == "'" { inSingle = false }
                i += 1; continue
            }
            if inDouble {
                if c == "\\" { escaping = true }
                else if c == "\"" { inDouble = false }
                i += 1; continue
            }
            if inBacktick {
                if c == "`" { inBacktick = false }
                else if c == "\\" { escaping = true }
                i += 1; continue
            }
            if substDepth > 0 {
                if c == "'" { inSingle = true }
                else if c == "\"" { inDouble = true }
                else if c == "`" { inBacktick = true }
                else if c == "$", i + 1 < characters.count, characters[i + 1] == "(" {
                    substDepth += 1; i += 1
                } else if c == "(" {
                    substDepth += 1
                } else if c == ")" {
                    substDepth -= 1
                }
                i += 1; continue
            }

            switch c {
            case "\\": escaping = true; i += 1
            case "'": inSingle = true; i += 1
            case "\"": inDouble = true; i += 1
            case "`": inBacktick = true; i += 1
            case "$":
                if i + 1 < characters.count, characters[i + 1] == "(" {
                    substDepth = 1; i += 1
                }
                i += 1
            case "<":
                // Heredoc: << (but not <<< here-string).
                if i + 1 < characters.count, characters[i + 1] == "<",
                   !(i + 2 < characters.count && characters[i + 2] == "<") {
                    var j = i + 2
                    // Optional <<-
                    if j < characters.count, characters[j] == "-" { j += 1 }
                    // Skip whitespace before delimiter.
                    while j < characters.count,
                          characters[j] == " " || characters[j] == "\t" {
                        j += 1
                    }

                    var delimiter = ""
                    // A quoted delimiter (e.g. <<'EOF' or <<"EOF") makes the
                    // body fully literal — no expansion occurs.
                    var delimiterQuoted = false
                    if j < characters.count {
                        if characters[j] == "'" || characters[j] == "\"" {
                            delimiterQuoted = true
                            let close = characters[j]; j += 1
                            while j < characters.count, characters[j] != close {
                                delimiter.append(characters[j]); j += 1
                            }
                            if j < characters.count { j += 1 }
                        } else {
                            while j < characters.count, !characters[j].isWhitespace {
                                // A backslash before the delimiter also quotes
                                // it (e.g. <<\EOF).
                                if characters[j] == "\\" {
                                    delimiterQuoted = true
                                    j += 1
                                    continue
                                }
                                delimiter.append(characters[j]); j += 1
                            }
                        }
                    }

                    guard !delimiter.isEmpty else { i += 1; continue }

                    // Find end of current line (heredoc body starts on next line).
                    while j < characters.count, characters[j] != "\n" { j += 1 }
                    let bodyStart = j + 1

                    // Scan body lines for the delimiter.
                    var k = bodyStart
                    var found = false
                    while k < characters.count {
                        var lineEnd = k
                        while lineEnd < characters.count, characters[lineEnd] != "\n" {
                            lineEnd += 1
                        }
                        let line = String(characters[k..<lineEnd])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if line == delimiter {
                            if bodyStart < lineEnd {
                                for idx in bodyStart..<lineEnd where idx < mask.count {
                                    mask[idx] = true
                                }
                                if !delimiterQuoted {
                                    unquotedBodies.append(
                                        String(characters[bodyStart..<lineEnd])
                                    )
                                }
                            }
                            found = true
                            i = lineEnd
                            break
                        }
                        k = lineEnd + 1
                    }

                    if !found {
                        if bodyStart < characters.count {
                            for idx in bodyStart..<characters.count {
                                mask[idx] = true
                            }
                            if !delimiterQuoted {
                                unquotedBodies.append(
                                    String(characters[bodyStart..<characters.count])
                                )
                            }
                        }
                        i = characters.count
                    }
                } else {
                    i += 1
                }
            default:
                i += 1
            }
        }

        return HeredocScan(mask: mask, unquotedBodies: unquotedBodies)
    }

    // MARK: - Authorization candidate extraction

    /// Maximum recursion depth for nested shell `-c` payloads and command
    /// substitutions. Prevents pathological deep nesting.
    private static let maxCandidateDepth = 8

    /// Maximum number of candidates extracted from a single command. Prevents
    /// excessive work on pathological input.
    private static let maxCandidateCount = 64

    /// Extracts ordered, deduplicated authorization candidates from a command
    /// string. Each candidate carries the canonical executable identity (for
    /// cache/persistence) and a cleaned invocation (for display).
    ///
    /// Noise — comments, decorative `echo`/`printf`, harmless built-ins,
    /// environment assignments, wrappers, and control-flow keywords — is
    /// filtered out. Nested commands inside shell `-c` payloads and command
    /// substitutions are recursively extracted.
    static func authorizationCandidates(in command: String) -> [AuthorizationCandidate] {
        collectAuthorizationCandidates(in: command, depth: 0)
    }

    private static func collectAuthorizationCandidates(
        in command: String,
        depth: Int
    ) -> [AuthorizationCandidate] {
        guard depth < Self.maxCandidateDepth else {
            // Depth limit exceeded: fail-closed by emitting a conservative
            // fallback candidate so the gate still prompts.
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [AuthorizationCandidate(identity: trimmed, invocation: trimmed)]
        }

        let segments = commandSegments(in: command)
        guard !segments.isEmpty else {
            return []
        }

        var seen = Set<String>()
        var candidates: [AuthorizationCandidate] = []
        var hitLimit = false

        func add(_ identity: String, invocation: String) {
            if candidates.count >= Self.maxCandidateCount {
                hitLimit = true
                return
            }
            if seen.insert(identity).inserted {
                candidates.append(AuthorizationCandidate(identity: identity, invocation: invocation))
            }
        }

        for segment in segments {
            if candidates.count >= Self.maxCandidateCount {
                hitLimit = true
                break
            }
            collectCandidates(from: segment, depth: depth, into: add)
        }

        // Unquoted heredoc bodies are expanded by the shell, so extract command
        // substitutions from them as well (e.g. `cat <<EOF ... $(rm) ... EOF`).
        for body in unquotedHeredocBodies(in: command) {
            if candidates.count >= Self.maxCandidateCount {
                hitLimit = true
                break
            }
            for content in commandSubstitutionContents(in: body).prefix(16) {
                for candidate in collectAuthorizationCandidates(in: content, depth: depth + 1) {
                    add(candidate.identity, invocation: candidate.invocation)
                }
            }
        }

        // Fail-closed: if we hit the candidate count limit, there may be
        // unanalyzed commands. Add a conservative fallback so the gate prompts.
        if hitLimit {
            let fallback = "<too-many-commands>"
            if seen.insert(fallback).inserted {
                candidates.append(AuthorizationCandidate(
                    identity: fallback,
                    invocation: command.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }

        return candidates
    }

    /// Collects candidates from a single segment, handling shell `-c`
    /// recursion, decorative echo/printf, and nested substitutions.
    private static func collectCandidates(
        from segment: String,
        depth: Int,
        into add: (String, String) -> Void
    ) {
        switch executableIdentity(for: segment) {
        case .skip:
            // Even skip segments may contain command substitutions whose
            // nested commands should be authorized (e.g. `true $(rm -rf /)`).
            extractNestedCandidates(from: segment, depth: depth, into: add)

        case .executable(let name):
            // Shell -c recursive parsing: unwrap the static payload and
            // recurse to extract the real commands inside.
            if let payload = shellDashCPayload(for: segment) {
                for candidate in collectAuthorizationCandidates(in: payload, depth: depth + 1) {
                    add(candidate.identity, candidate.invocation)
                }
                return
            }

            // Decorative echo/printf: skip the echo itself but extract any
            // nested commands from substitutions (e.g. `echo $(git rev-parse HEAD)`).
            if isDecorativeEchoPrintf(identity: name, segment: segment) {
                extractNestedCandidates(from: segment, depth: depth, into: add)
                return
            }

            // Normal executable: add the outer candidate AND extract any
            // nested commands from substitutions (e.g. `cat "$(rm -rf /)"`
            // yields both `cat` and `rm`).
            add(name, cleanedInvocation(for: segment))
            extractNestedCandidates(from: segment, depth: depth, into: add)

        case .unresolved(let raw):
            add(raw, segment.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Recursively extracts candidates from `$(...)` and backtick substitutions
    /// embedded in a segment.
    private static func extractNestedCandidates(
        from segment: String,
        depth: Int,
        into add: (String, String) -> Void
    ) {
        for content in commandSubstitutionContents(in: segment).prefix(16) {
            for candidate in collectAuthorizationCandidates(in: content, depth: depth + 1) {
                add(candidate.identity, candidate.invocation)
            }
        }
    }

    // MARK: - Candidate helpers

    /// Returns `true` when the segment's executable is `echo` or `printf` and
    /// the segment has no output redirections (which could write to files).
    /// Command substitutions are allowed — they will be extracted separately.
    private static func isDecorativeEchoPrintf(identity: String, segment: String) -> Bool {
        guard identity == "echo" || identity == "printf" else { return false }
        return !segmentHasOutputRedirection(segment)
    }

    /// Returns `true` when the segment contains an output redirection operator
    /// (`>`, `>>`, `&>`, `N>`) outside quotes. Excludes fd duplication (`2>&1`)
    /// which does not write to files.
    private static func segmentHasOutputRedirection(_ segment: String) -> Bool {
        let chars = Array(segment)
        var i = 0
        var inSingle = false
        var inDouble = false
        var escaping = false

        while i < chars.count {
            let c = chars[i]
            if escaping { escaping = false; i += 1; continue }
            if inSingle { if c == "'" { inSingle = false }; i += 1; continue }
            if inDouble {
                if c == "\\" { escaping = true }
                else if c == "\"" { inDouble = false }
                i += 1; continue
            }
            switch c {
            case "\\": escaping = true
            case "'": inSingle = true
            case "\"": inDouble = true
            case ">":
                // Not fd duplication (>&).
                if i == 0 || chars[i - 1] != "&" {
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

    /// Extracts the static payload from a shell `-c` invocation
    /// (e.g. `bash -lc 'git status'`) by unwrapping leading prefixes and
    /// looking for a `-c`-containing option followed by a string argument.
    /// Returns `nil` when the command is not a shell `-c` invocation.
    private static func shellDashCPayload(for segment: String) -> String? {
        let words = shellWords(in: segment)

        // Unwrap leading prefixes to find the real command.
        var start = 0
        let skipAssignments = true
        while start < words.count {
            let word = words[start]
            if skipAssignments && isEnvironmentAssignment(word.value) {
                start += 1; continue
            }
            if !word.wasQuoted && isUnwrappableWrapper(word.value) {
                start += 1
                while start < words.count {
                    if words[start].value.hasPrefix("-") && words[start].value != "-" {
                        start += 1; continue
                    }
                    if isEnvironmentAssignment(words[start].value) {
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
        let name = cleanedExecutableName(from: words[start].value)
        let basename = (name as NSString).lastPathComponent
        guard ["sh", "bash", "zsh", "dash", "ksh"].contains(basename) else { return nil }

        // Look for a -c option in the remaining words.
        var i = start + 1
        while i < words.count {
            let word = words[i]
            if word.value.hasPrefix("-") && word.value != "-" && word.value.contains("c") {
                if i + 1 < words.count {
                    return words[i + 1].value
                }
                return nil
            }
            if word.value.hasPrefix("-") && word.value != "-" {
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
    /// `$((...))` arithmetic expansion is explicitly excluded: it is not a
    /// command substitution.
    private static func commandSubstitutionContents(in segment: String) -> [String] {
        let chars = Array(segment)
        var contents: [String] = []
        var i = 0
        var inSingle = false
        var inDouble = false
        var escaping = false

        while i < chars.count {
            let c = chars[i]

            if escaping { escaping = false; i += 1; continue }
            if inSingle { if c == "'" { inSingle = false }; i += 1; continue }

            // Detect $(...) command substitution outside single quotes.
            // Explicitly exclude $((...)) arithmetic expansion.
            if c == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                // Check for $(( arithmetic expansion — skip it entirely.
                if i + 2 < chars.count, chars[i + 2] == "(" {
                    // Skip to matching )) of the arithmetic expansion.
                    i = skipBalancedParenContent(chars, from: i + 2)
                    continue
                }

                // Extract $(...) content with nesting.
                var depth = 1
                var j = i + 2
                var content = ""
                var s = SubstitutionScanner()
                while j < chars.count, depth > 0 {
                    let sc = chars[j]
                    if s.escaping { s.escaping = false; content.append(sc); j += 1; continue }
                    if s.inSingle {
                        if sc == "'" { s.inSingle = false }
                        content.append(sc); j += 1; continue
                    }
                    if s.inDouble {
                        if sc == "\\" { s.escaping = true }
                        else if sc == "\"" { s.inDouble = false }
                        content.append(sc); j += 1; continue
                    }
                    switch sc {
                    case "\\": s.escaping = true; content.append(sc)
                    case "'": s.inSingle = true; content.append(sc)
                    case "\"": s.inDouble = true; content.append(sc)
                    case "(": depth += 1; content.append(sc)
                    case ")":
                        depth -= 1
                        if depth > 0 { content.append(sc) }
                    default:
                        content.append(sc)
                    }
                    j += 1
                }
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    contents.append(content)
                }
                i = j
                continue
            }

            // Detect process substitution <(...) or >(...).
            if (c == "<" || c == ">"), i + 1 < chars.count, chars[i + 1] == "(" {
                // Extract process substitution content with nesting.
                var depth = 1
                var j = i + 2
                var content = ""
                var s = SubstitutionScanner()
                while j < chars.count, depth > 0 {
                    let sc = chars[j]
                    if s.escaping { s.escaping = false; content.append(sc); j += 1; continue }
                    if s.inSingle {
                        if sc == "'" { s.inSingle = false }
                        content.append(sc); j += 1; continue
                    }
                    if s.inDouble {
                        if sc == "\\" { s.escaping = true }
                        else if sc == "\"" { s.inDouble = false }
                        content.append(sc); j += 1; continue
                    }
                    switch sc {
                    case "\\": s.escaping = true; content.append(sc)
                    case "'": s.inSingle = true; content.append(sc)
                    case "\"": s.inDouble = true; content.append(sc)
                    case "(": depth += 1; content.append(sc)
                    case ")":
                        depth -= 1
                        if depth > 0 { content.append(sc) }
                    default:
                        content.append(sc)
                    }
                    j += 1
                }
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    contents.append(content)
                }
                i = j
                continue
            }

            if c == "`" {
                // Extract backtick content.
                var j = i + 1
                var content = ""
                var btEscaping = false
                while j < chars.count {
                    let bc = chars[j]
                    if btEscaping { btEscaping = false; content.append(bc); j += 1; continue }
                    if bc == "\\" { btEscaping = true }
                    else if bc == "`" { break }
                    else { content.append(bc) }
                    j += 1
                }
                if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    contents.append(content)
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
    private struct SubstitutionScanner {
        var inSingle = false
        var inDouble = false
        var escaping = false
    }

    /// Skips a balanced parenthesised content starting at `start` (which must
    /// point at an opening `(`), respecting quotes. Returns the index just past
    /// the matching `)`. Used to skip `$((...))` arithmetic expansions.
    private static func skipBalancedParenContent(_ chars: [Character], from start: Int) -> Int {
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

    /// Produces the cleaned invocation for a segment by stripping leading
    /// environment assignments, wrapper commands, wrapper options, control-flow
    /// keywords, and grouping delimiters, then joining the remaining words.
    private static func cleanedInvocation(for segment: String) -> String {
        let words = shellWords(in: segment)
        guard !words.isEmpty else {
            return segment.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var index = 0
        var skipNextAsRedirectTarget = false
        var skippingLeadingAssignments = true
        // Leading redirections have side effects (they can truncate files), so
        // preserve them in the displayed invocation instead of stripping them.
        var leadingRedirections: [String] = []

        while index < words.count {
            let word = words[index]

            if skipNextAsRedirectTarget {
                skipNextAsRedirectTarget = false
                leadingRedirections.append(word.value)
                index += 1; continue
            }
            if let redirect = redirectionInfo(for: word.value) {
                if !redirect.hasAttachedTarget { skipNextAsRedirectTarget = true }
                leadingRedirections.append(word.value)
                index += 1; continue
            }
            if isStandaloneGroupingDelimiter(word.value) { index += 1; continue }
            if skippingLeadingAssignments && isEnvironmentAssignment(word.value) {
                index += 1; continue
            }
            if !word.wasQuoted && isUnwrappableWrapper(word.value) {
                let wrapperName = word.value
                skippingLeadingAssignments = true
                index += 1
                while index < words.count {
                    let w = words[index]
                    if w.value == "--" {
                        index += 1
                        break
                    }
                    if w.value.hasPrefix("-") && w.value != "-" {
                        let info = wrapperOptionInfo(wrapper: wrapperName, option: w.value)
                        index += 1
                        if info == .consumesOperand {
                            index += 1
                        }
                        continue
                    }
                    if isEnvironmentAssignment(w.value) {
                        index += 1; continue
                    }
                    break
                }
                continue
            }
            if !word.wasQuoted && isControlFlowKeyword(word.value) {
                index += 1; continue
            }
            // First real token reached.
            break
        }

        guard index < words.count else {
            return segment.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let remaining = words[index...].map(\.value)
        let combined = leadingRedirections + remaining
        let result = combined.joined(separator: " ")
        return result.isEmpty
            ? segment.trimmingCharacters(in: .whitespacesAndNewlines)
            : result
    }
}
