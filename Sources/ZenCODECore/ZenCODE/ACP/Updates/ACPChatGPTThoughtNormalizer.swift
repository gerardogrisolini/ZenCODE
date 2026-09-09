// ACP-only presentation of ChatGPT public reasoning summaries.
// This is deliberately not a Markdown parser and never changes runtime history.
struct ACPChatGPTThoughtNormalizer: Sendable {
    private enum BlockState: Sendable, Equatable {
        case plain, candidate, closed
    }

    private var state: BlockState = .plain
    private var pendingStar = false
    private var atLineStart = true
    private var candidateHasContent = false
    private var pendingSpace = false
    private var hasOutput = false
    private var pendingNewline = false

    mutating func consume(_ fragment: String) -> String {
        var output = ""
        // Scalars, not Characters: an asterisk followed by a combining mark must
        // be removed identically whether they arrive together or in two chunks.
        for scalar in fragment.unicodeScalars {
            if scalar == "*" {
                if pendingStar {
                    pendingStar = false
                    switch state {
                    case .plain:
                        if atLineStart {
                            state = .candidate
                            candidateHasContent = false
                        }
                    case .candidate:
                        state = candidateHasContent ? .closed : .plain
                    case .closed:
                        // A second bold block disambiguates the previous title.
                        pendingNewline = hasOutput
                        state = .candidate
                        candidateHasContent = false
                    }
                } else {
                    pendingStar = true
                }
                continue
            }
            // Single asterisks are removed too, but do not delimit blocks.
            pendingStar = false
            let isNewline = scalar == "\n" || scalar == "\r"
            if scalar.properties.isWhitespace {
                pendingSpace = true
                if isNewline {
                    if state == .closed { pendingNewline = hasOutput }
                    // An unmatched/inline marker cannot affect the next line.
                    state = .plain
                    atLineStart = true
                }
                continue
            }
            if state == .closed {
                // A closing pair alone does not prove a title: ordinary
                // text on the same line must remain in the same sentence.
                state = .plain
            }
            if state == .candidate { candidateHasContent = true }
            atLineStart = false
            if hasOutput {
                if pendingNewline { output += "\n" }
                else if pendingSpace { output += " " }
            }
            pendingSpace = false
            pendingNewline = false
            output.unicodeScalars.append(scalar)
            hasOutput = true
        }
        return output
    }

    /// Complete a reasoning segment without emitting trailing whitespace.
    /// Separators belong only inside a segment, never at the start of the next
    /// thinking card after a tool, response or turn boundary.
    mutating func finish() -> String {
        self = Self()
        return ""
    }
}
