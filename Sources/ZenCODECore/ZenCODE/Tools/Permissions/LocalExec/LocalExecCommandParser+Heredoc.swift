//
//  Internal pipeline extracted from LocalExecCommandParser.
//

import Foundation

extension LocalExecCommandParser {
// MARK: - Heredoc body detection

    /// Result of scanning a command for heredoc bodies.
    struct HeredocScan {
        /// Character indices that belong to heredoc bodies (masked during
        /// segmentation).
        var mask: [Bool]
        /// Body text of heredocs whose delimiter is unquoted. The shell expands
        /// `$(...)` and backticks in these bodies, so their command
        /// substitutions must still be authorized.
        var unquotedBodies: [String]
    }

    static func scanHeredocs(in characters: [Character]) -> HeredocScan {
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
}
