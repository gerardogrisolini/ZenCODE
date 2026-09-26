//
//  Internal pipeline extracted from LocalExecCommandParser.
//

import Foundation

extension LocalExecCommandParser {
// MARK: - Tokenization

    /// A shell word with quote provenance.
    struct ShellWord: Equatable {
        /// The token value with surrounding quotes stripped.
        let value: String
        /// `true` when the token was fully enclosed in quotes (so it is a
        /// literal path, not a shell keyword).
        let wasQuoted: Bool
    }

    /// Tokenizes a segment into shell words, respecting quotes and escapes.
    static func shellWords(in segment: String) -> [ShellWord] {
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
    static func cleanedExecutableName(from token: String) -> String {
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
    static let skippableBuiltins: Set<String> = [
        // Result built-ins.
        "true", "false", ":",
        // Directory/state built-ins.
        "cd", "pwd", "pushd", "popd", "dirs",
        // Conditional built-ins.
        "test", "[", "[["
    ]

    /// Shell control-flow keywords. When they appear as a leading token, the
    /// parser consumes them and continues scanning for the real executable.
    static let controlFlowKeywords: Set<String> = [
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
    static let headerKeywords: Set<String> = [
        "for", "select"
    ]

    static func isControlFlowKeyword(_ token: String) -> Bool {
        Self.controlFlowKeywords.contains(token)
    }

    /// Matches leading environment assignments: `NAME=value`, where NAME is
    /// `[A-Za-z_][A-Za-z0-9_]*` and an `=` is present.
    static func isEnvironmentAssignment(_ token: String) -> Bool {
        guard token.contains("=") else { return false }
        let name = token.split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
        guard let first = name.first else { return false }
        guard first.isLetter || first == "_" else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// Command wrappers that precede the real command and should be unwrapped.
    /// `sudo` and `xargs` are intentionally NOT unwrapped: they are themselves
    /// risk gates.
    static func isUnwrappableWrapper(_ token: String) -> Bool {
        Self.wrappers.contains(token)
    }

    static let wrappers: Set<String> = [
        "env", "command", "exec", "nohup", "time"
    ]

    /// Returns `true` for standalone grouping delimiters `(`, `)`, `{`, `}`.
    static func isStandaloneGroupingDelimiter(_ token: String) -> Bool {
        token == "(" || token == ")" || token == "{" || token == "}"
    }

    /// Classifies a redirection token. Returns `nil` when the token is not a
    /// redirection. `hasAttachedTarget` indicates whether the redirection
    /// already carries its target within this token.
    static func redirectionInfo(for token: String) -> (isRedirection: Bool, hasAttachedTarget: Bool)? {
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
    static func redirectionOperatorBody(of token: String) -> String? {
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

        // Optional second arrow/ampersand: `>>`, `<<`, `>&`, `<&`, `>|`.
        if prefix < chars.count, chars[prefix] == arrow {
            prefix += 1
        } else if prefix < chars.count, chars[prefix] == "&" {
            prefix += 1
        } else if arrow == ">", prefix < chars.count, chars[prefix] == "|" {
            prefix += 1
        }

        return String(chars.prefix(prefix))
    }

    // MARK: - Wrapper option classification

    /// How a wrapper option interacts with following tokens.
    enum WrapperOptionKind {
        /// Option that does not consume an operand (e.g. `env -i`).
        case none
        /// Option that consumes the next token as its argument (e.g. `env -u NAME`).
        case consumesOperand
        /// Option that indicates introspection, not execution (e.g. `command -v`).
        case introspection
    }

    /// Classifies a wrapper option to determine how many additional tokens it
    /// consumes or whether it indicates non-execution.
    static func wrapperOptionInfo(
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
}
