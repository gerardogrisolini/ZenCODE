//
//  LocalExecCommandParserLocationTests.swift
//  ZenCODE
//
//  The located parser variants: the positions of the executables a
//  `local.exec` consent covers, and the origins of the located segments,
//  words, and substitutions.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct LocalExecCommandParserLocationTests {
    private typealias Parser = LocalExecCommandParser

    /// The located executables as text: runs of contiguous positions.
    private func highlights(in command: String) -> [String] {
        let characters = Array(command)
        var groups: [String] = []
        var previous: Int?
        for position in Parser.executablePositions(in: command) {
            if let previous, position == previous + 1 {
                groups[groups.count - 1].append(characters[position])
            } else {
                groups.append(String(characters[position]))
            }
            previous = position
        }
        return groups
    }

    // MARK: - Positions

    static let positionCases: [(String, [String])] = [
        // The commands of the operator's screenshot.
        (
            #"cd /x && grep -rn -i "invalid\|rewrite" Setup/A.swift | head -30; grep -rn "agents.json" Setup | head"#,
            ["grep", "head", "grep", "head"]
        ),
        (
            #"cd /x && grep -rnIE "a|b" Tests | grep -v "^T" ; echo ====; grep -rnIE "c" T1 T2 | head -30"#,
            ["grep", "grep", "grep", "head"]
        ),
        (
            """
            cd /x && python3 - <<'EOF'
            import subprocess
            subprocess.run(["grep", "-rn", "x"])
            rm -rf y
            EOF
            """,
            ["python3"]
        ),
        ("sed -n 1,12p a; sed -n 8,13p b", ["sed", "sed"]),
        // A shell `-c` payload: its commands, not the shell.
        ("bash -c 'rm -rf x'", ["rm"]),
        // A command substitution: the outer and the nested executable.
        (#"cat "$(git rev-parse HEAD)""#, ["cat", "git"]),
        // Assignments, wrappers, and wrapper options are not executables.
        ("FOO=1 env -i make", ["make"]),
        // A path is located whole.
        ("/usr/bin/grep x", ["/usr/bin/grep"]),
        // Quotes and grouping delimiters are not part of the name.
        (#"'swift' build && (make)"#, ["swift", "make"]),
        // A compound command with trailing syntax is located by its opening.
        ("[[ left > right ]] > result.txt", ["[["]),
        // Unquoted heredoc bodies: their substitutions only.
        ("cat <<EOF\nvalue=$(rm -rf /tmp/x)\ngrep body\nEOF", ["cat", "rm"]),
        // Later case branch patterns: the synthetic header locates nothing.
        (
            """
            case "$value" in
              first) true ;;
              $(rm -f marker)|other) cat input ;;
            esac
            """,
            ["rm", "cat"]
        ),
        // Arithmetic expansions are traversed with their offset.
        ("echo $((1 + $(wc -l < f)))", ["wc"]),
        // Nothing to authorize, nothing located.
        ("cd /tmp && echo done", []),
        ("", []),
    ]

    @Test(arguments: LocalExecCommandParserLocationTests.positionCases)
    func executablePositionsLocateEveryCoveredOccurrence(command: String, expected: [String]) {
        #expect(highlights(in: command) == expected)
    }

    @Test
    func executablePositionsStopAtTheAnalysisLimits() {
        // Beyond the depth limit nothing is located.
        var nested = "rm -rf /tmp/x"
        for _ in 0..<12 {
            nested = "cat \"$(\(nested))\""
        }
        let nestedHighlights = highlights(in: nested)
        #expect(nestedHighlights == Array(repeating: "cat", count: Parser.maxCandidateDepth))

        // Only the substitutions the analysis inspects are located.
        let substitutions = (1...20).map { "$(tool\($0))" }.joined(separator: " ")
        #expect(highlights(in: "echo \(substitutions)")
            == (1...Parser.maxSubstitutionCount).map { "tool\($0)" })

        // Only the candidates the analysis inventories are located.
        let commands = (1...70).map { "tool\($0)" }.joined(separator: "; ")
        #expect(highlights(in: commands)
            == (1...Parser.maxCandidateCount).map { "tool\($0)" })
    }

    // MARK: - Invariance

    /// The commands of the parser tests, plus the limits and an unresolved
    /// segment.
    static var corpus: [String] {
        var commands = LocalExecCommandParserTests.segmentationCases.map(\.0)
        commands += LocalExecCommandParserTests.identityCases.map(\.0)
        commands += LocalExecCommandParserTests.candidateIdentityCases.map(\.0)
        commands += LocalExecCommandParserTests.candidateInvocationCases.map(\.0)
        commands += LocalExecCommandParserTests.nestedCandidateCases.map(\.0)
        commands += positionCases.map(\.0)
        var nested = "rm -rf /tmp/x"
        for _ in 0..<12 {
            nested = "cat \"$(\(nested))\""
        }
        commands.append(nested)
        commands.append("echo " + (1...20).map { "$(tool\($0))" }.joined(separator: " "))
        commands.append((1...70).map { "tool\($0)" }.joined(separator: "; "))
        commands.append("'' && make")
        commands.append(#"bash -c "echo $(rm -rf x)" && env -u NAME swift build"#)
        return commands
    }

    /// The raw identities of unresolved segments, which are authorized by
    /// their text and locate nothing.
    private func unresolvedIdentities(in command: String, depth: Int = 0) -> Set<String> {
        guard depth < Parser.maxCandidateDepth else { return [] }
        var identities = Set<String>()
        func inspect(_ content: String) {
            identities.formUnion(unresolvedIdentities(in: content, depth: depth + 1))
        }
        for segment in Parser.commandSegments(in: command) {
            if case .unresolved(let raw) = Parser.executableIdentity(for: segment) {
                identities.insert(raw)
            }
            Parser.commandSubstitutionContents(in: segment).forEach(inspect)
            Parser.shellDashCPayload(for: segment).map(inspect)
        }
        for body in Parser.unquotedHeredocBodies(in: command) {
            Parser.commandSubstitutionContents(in: body).forEach(inspect)
        }
        return identities
    }

    @Test(arguments: LocalExecCommandParserLocationTests.corpus)
    func locatedTextsAreTheAuthorizationIdentities(command: String) {
        let candidates = Parser.authorizationCandidates(in: command)
        // The located walk inventories the same candidates, in order.
        #expect(
            Parser.collectLocatedCandidates(in: .init(root: command), depth: 0).map(\.identity)
                == candidates.map(\.identity)
        )
        let identities = Set(candidates.map(\.identity))
            .filter { !Parser.isNonPersistableIdentity($0) }
            .subtracting(unresolvedIdentities(in: command))
        #expect(Set(highlights(in: command)) == identities)
    }

    @Test
    func anUnresolvedSegmentLocatesNothing() {
        #expect(Parser.authorizationCandidates(in: "''").map(\.identity) == ["''"])
        #expect(Parser.executablePositions(in: "''").isEmpty)
    }

    // MARK: - Located variants

    @Test
    func plainVariantsKeepTheirValues() {
        #expect(
            Parser.shellWords(in: #"git commit -m "a \"b\" c" 'x y' z\ w"#) == [
                .init(value: "git", wasQuoted: false),
                .init(value: "commit", wasQuoted: false),
                .init(value: "-m", wasQuoted: false),
                .init(value: #"a \"b\" c"#, wasQuoted: true),
                .init(value: "x y", wasQuoted: true),
                // Outside quotes a backslash is literal and does not join words.
                .init(value: #"z\"#, wasQuoted: false),
                .init(value: "w", wasQuoted: false),
            ]
        )
        #expect(
            Parser.commandSubstitutionContents(
                in: #"echo $(git rev-parse HEAD) "$(date)" `who\ami` <(ls) $((1 + $(wc -l < f)))"#
            ) == ["git rev-parse HEAD", "date", "whoami", "ls", "wc -l < f"]
        )
        #expect(
            Parser.commandSegments(in: "case x in x) :;; y) true;; esac")
                == ["case x in x)", ":", "case _ in  y)", "true", "esac"]
        )
        #expect(
            Parser.unquotedHeredocBodies(in: "cat <<EOF\n$(rm x)\nEOF\ncat <<'Q'\nq\nQ")
                == ["$(rm x)\nEOF"]
        )
        #expect(Parser.shellDashCPayload(for: "env -i bash -lc 'git status' x") == "git status")
    }

    @Test(arguments: LocalExecCommandParserLocationTests.corpus)
    func locatedVariantsMatchThePlainOnesAndPointAtTheirCharacters(command: String) {
        let characters = Array(command)

        func expectOrigins(of located: Parser.LocatedText) {
            #expect(located.origins.count == located.text.count)
            for (character, origin) in zip(located.text, located.origins) {
                guard let origin else { continue }
                #expect(characters.indices.contains(origin) && characters[origin] == character)
            }
        }

        let segments = Parser.locatedCommandSegments(in: command)
        #expect(segments.map(\.text) == Parser.commandSegments(in: command))
        for segment in segments {
            expectOrigins(of: segment)

            let words = Parser.locatedShellWords(in: segment.text)
            #expect(words.map(\.word) == Parser.shellWords(in: segment.text))
            for word in words {
                expectOrigins(of: word.locatedValue.mapped(through: segment.origins))
            }

            let contents = Parser.locatedCommandSubstitutionContents(in: segment.text)
            #expect(contents.map(\.text) == Parser.commandSubstitutionContents(in: segment.text))
            for content in contents {
                expectOrigins(of: content.mapped(through: segment.origins))
            }

            let payload = Parser.locatedShellDashCPayload(for: segment.text)
            #expect(payload?.text == Parser.shellDashCPayload(for: segment.text))
            if let payload {
                expectOrigins(of: payload.mapped(through: segment.origins))
            }

            let match = Parser.executableIdentityMatch(for: segment.text)
            #expect(match.identity == Parser.executableIdentity(for: segment.text))
        }

        let bodies = Parser.locatedUnquotedHeredocBodies(in: command)
        #expect(bodies.map(\.text) == Parser.unquotedHeredocBodies(in: command))
        bodies.forEach(expectOrigins(of:))
    }

    @Test
    func locatedTextFailsSoftAndTrimsLikeFoundation() {
        // A mismatched origin count yields no origins.
        let mismatched = Parser.LocatedText(text: "abc", origins: [0, 1])
        #expect(mismatched.origins == [nil, nil, nil])

        let located = Parser.LocatedText(root: " \n\tgrep x \r\n")
        let trimmed = located.trimmingWhitespacesAndNewlines()
        #expect(trimmed.text == " \n\tgrep x \r\n".trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(trimmed.origins == [3, 4, 5, 6, 7, 8])

        // Composition goes through the parent's origins.
        let child = Parser.LocatedText(text: "re", origins: [1, nil])
        #expect(child.mapped(through: [10, 11, 12]).origins == [11, nil])
        #expect(Parser.LocatedText(text: "x", origins: [7]).mapped(through: [1]).origins == [nil])
    }
}
