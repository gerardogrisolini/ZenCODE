//
//  Internal pipeline extracted from LocalExecCommandParser.
//

import Foundation

extension LocalExecCommandParser {
// MARK: - Authorization candidate extraction

    /// Maximum recursion depth for nested shell `-c` payloads and command
    /// substitutions. Prevents pathological deep nesting.
    static let maxCandidateDepth = 8

    /// Maximum number of candidates extracted from a single command. Prevents
    /// excessive work on pathological input.
    static let maxCandidateCount = 64

    /// Bound recursive substitution processing independently from executable
    /// candidates. A command can contain many substitutions which all resolve
    /// to harmless built-ins, so the candidate count alone cannot prove that
    /// every expansion was inspected.
    static let maxSubstitutionCount = 16

    /// Sentinel proving that part of a command was not inventoried. It may gate
    /// one exact command in memory, but must never become a reusable or
    /// persisted executable permission.
    static let tooManyCommandsIdentity = "<too-many-commands>"
    static let analysisDepthLimitIdentity = "<command-analysis-depth-limit>"

    static func isNonPersistableIdentity(_ identity: String) -> Bool {
        identity == tooManyCommandsIdentity || identity == analysisDepthLimitIdentity
    }

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

    /// Performs a fail-closed inventory for the local-exec consent gate.
    /// Keep `authorizationCandidates(in:)` for existing callers that need the
    /// legacy list API; new authorization decisions must use this result.
    static func authorizationAnalysis(in command: String) -> AuthorizationAnalysis {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return .safe
        }

        let candidates = collectAuthorizationCandidates(in: command, depth: 0)
        if candidates.contains(where: { isNonPersistableIdentity($0.identity) }) {
            return .incomplete(reason: "The command analysis reached a safety limit.")
        }
        guard !candidates.isEmpty else {
            // A non-empty shell program can still execute through syntax the
            // lightweight parser does not model. Never make this fail open.
            return .incomplete(reason: "No executable could be determined with confidence.")
        }
        return .candidates(candidates)
    }

    static func collectAuthorizationCandidates(
        in command: String,
        depth: Int
    ) -> [AuthorizationCandidate] {
        guard depth < Self.maxCandidateDepth else {
            // Depth limit exceeded: fail-closed by emitting a conservative
            // fallback candidate so the gate still prompts.
            let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            return [AuthorizationCandidate(
                identity: Self.analysisDepthLimitIdentity,
                invocation: trimmed
            )]
        }

        let characters = Array(command)
        let heredocScan = scanHeredocs(in: characters)
        let segments = commandSegments(
            characters: characters,
            heredocSkipMask: heredocScan.mask
        )
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
        for body in heredocScan.unquotedBodies {
            if candidates.count >= Self.maxCandidateCount {
                hitLimit = true
                break
            }
            let substitutions = commandSubstitutionContents(in: body)
            if substitutions.count > Self.maxSubstitutionCount {
                add(Self.tooManyCommandsIdentity, invocation: command)
            }
            for content in substitutions.prefix(Self.maxSubstitutionCount) {
                for candidate in collectAuthorizationCandidates(in: content, depth: depth + 1) {
                    add(candidate.identity, invocation: candidate.invocation)
                }
            }
        }

        // Fail-closed: if we hit the candidate count limit, there may be
        // unanalyzed commands. Add a conservative fallback so the gate prompts.
        if hitLimit {
            let fallback = Self.tooManyCommandsIdentity
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
    static func collectCandidates(
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
                // `-c` only consumes its payload. Arguments after it can still
                // contain expansions evaluated by the outer shell before the
                // child shell is launched, so inventory the complete segment as
                // well instead of returning early.
                extractNestedCandidates(from: segment, depth: depth, into: add)
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
    static func extractNestedCandidates(
        from segment: String,
        depth: Int,
        into add: (String, String) -> Void
    ) {
        let substitutions = commandSubstitutionContents(in: segment)
        if substitutions.count > Self.maxSubstitutionCount {
            add(Self.tooManyCommandsIdentity, segment.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for content in substitutions.prefix(Self.maxSubstitutionCount) {
            for candidate in collectAuthorizationCandidates(in: content, depth: depth + 1) {
                add(candidate.identity, candidate.invocation)
            }
        }
    }

    // MARK: - Candidate helpers

    /// Returns `true` when the segment's executable is `echo` or `printf` and
    /// the segment has no output redirections (which could write to files).
    /// Command substitutions are allowed — they will be extracted separately.
    static func isDecorativeEchoPrintf(identity: String, segment: String) -> Bool {
        guard identity == "echo" || identity == "printf" else { return false }
        return !segmentHasOutputRedirection(segment)
    }

    /// Returns `true` when the segment contains an output redirection operator
    /// (`>`, `>>`, `&>`, `N>`) outside quotes. Excludes fd duplication (`2>&1`)
    /// which does not write to files.
    static func segmentHasOutputRedirection(_ segment: String) -> Bool {
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
    static func shellDashCPayload(for segment: String) -> String? {
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
    /// Arithmetic expansions are traversed too: while `$((...))` is not by
    /// itself a command substitution, shells permit `$(...)` within it.
    static func commandSubstitutionContents(in segment: String) -> [String] {
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
            if c == "$", i + 1 < chars.count, chars[i + 1] == "(" {
                // Inspect command substitutions nested inside `$((...))`.
                if i + 2 < chars.count, chars[i + 2] == "(" {
                    let arithmeticEnd = skipBalancedParenContent(chars, from: i + 2)
                    let contentEnd = max(i + 3, arithmeticEnd - 1)
                    if i + 3 <= contentEnd, contentEnd <= chars.count {
                        let arithmeticBody = String(chars[(i + 3)..<contentEnd])
                        contents.append(contentsOf: commandSubstitutionContents(in: arithmeticBody))
                    }
                    // `skipBalancedParenContent` consumes the inner closing
                    // parenthesis; consume the outer arithmetic delimiter too.
                    i = min(arithmeticEnd + 1, chars.count)
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

    /// Produces the cleaned invocation for a segment by stripping leading
    /// environment assignments, wrapper commands, wrapper options, control-flow
    /// keywords, and grouping delimiters, then joining the remaining words.
    static func cleanedInvocation(for segment: String) -> String {
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
