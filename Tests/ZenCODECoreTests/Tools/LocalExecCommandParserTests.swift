//
//  LocalExecCommandParserTests.swift
//  ZenCODE
//
//  Isolated unit tests for LocalExecCommandParser segmentation and identity.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct LocalExecCommandParserTests {
    // MARK: - Segmentation: pipes and logical operators

    @Test
    func segmentsSplitOnPipe() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "printf one | grep one|sort")
            == ["printf one", "grep one", "sort"]
        )
    }

    @Test
    func segmentsSplitOnPipeAmpersand() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "producer |& consumer")
            == ["producer", "consumer"]
        )
    }

    @Test
    func segmentsSplitOnOrOr() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "primary || fallback")
            == ["primary", "fallback"]
        )
    }

    @Test
    func segmentsSplitOnAndAnd() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "cmd1 && cmd2")
            == ["cmd1", "cmd2"]
        )
    }

    @Test
    func segmentsSplitOnSemicolon() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "cmd1; cmd2")
            == ["cmd1", "cmd2"]
        )
    }

    @Test
    func segmentsSplitOnBackgroundAmpersand() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "cmd &")
            == ["cmd"]
        )
    }

    @Test
    func segmentsSplitOnNewlines() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "cmd1\ncmd2\n")
            == ["cmd1", "cmd2"]
        )
    }

    @Test
    func segmentsSplitOnMixedOperators() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "false || make && install")
            == ["false", "make", "install"]
        )
    }

    // MARK: - Segmentation: quoting and escaping preserved

    @Test
    func segmentsPreserveSingleQuotedPipes() {
        #expect(
            LocalExecCommandParser.commandSegments(in: #"printf 'a|b' | grep a"#)
            == [#"printf 'a|b'"#, "grep a"]
        )
    }

    @Test
    func segmentsPreserveDoubleQuotedPipes() {
        #expect(
            LocalExecCommandParser.commandSegments(in: #"printf "a|b" | grep a"#)
            == [#"printf "a|b""#, "grep a"]
        )
    }

    @Test
    func segmentsPreserveEscapedPipes() {
        #expect(
            LocalExecCommandParser.commandSegments(in: #"printf a\|b | grep a"#)
            == [#"printf a\|b"#, "grep a"]
        )
    }

    // MARK: - Segmentation: substitutions are opaque

    @Test
    func commandSubstitutionDoesNotSplit() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "echo $(ls | wc -l)")
            == ["echo $(ls | wc -l)"]
        )
    }

    @Test
    func nestedCommandSubstitutionDoesNotSplit() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "echo $(cat $(find . -name '*.txt') | wc -l)")
            == ["echo $(cat $(find . -name '*.txt') | wc -l)"]
        )
    }

    @Test
    func backtickSubstitutionDoesNotSplit() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "echo `ls | wc -l`")
            == ["echo `ls | wc -l`"]
        )
    }

    @Test
    func processSubstitutionDoesNotSplit() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "diff <(ls a) <(ls b) | cat")
            == ["diff <(ls a) <(ls b)", "cat"]
        )
    }

    // MARK: - Segmentation: edge cases

    @Test
    func emptyCommandYieldsNoSegments() {
        #expect(LocalExecCommandParser.commandSegments(in: "").isEmpty)
        #expect(LocalExecCommandParser.commandSegments(in: "   ").isEmpty)
    }

    @Test
    func whitespaceOnlySegmentCollapses() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "  cmd   ")
            == ["cmd"]
        )
    }

    // MARK: - Identity: plain executables

    @Test
    func plainExecutableIdentity() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "swift build")
            == .executable("swift")
        )
        #expect(
            LocalExecCommandParser.executableIdentity(for: "git status --short")
            == .executable("git")
        )
    }

    // MARK: - Identity: skip-list (built-ins and keywords)

    @Test
    func skipListBuiltins() {
        #expect(LocalExecCommandParser.executableIdentity(for: "true") == .skip)
        #expect(LocalExecCommandParser.executableIdentity(for: "false") == .skip)
        #expect(LocalExecCommandParser.executableIdentity(for: ":") == .skip)
        #expect(LocalExecCommandParser.executableIdentity(for: "cd /tmp") == .skip)
        #expect(LocalExecCommandParser.executableIdentity(for: "pwd") == .skip)
        #expect(LocalExecCommandParser.executableIdentity(for: "test -f x") == .skip)
        #expect(LocalExecCommandParser.executableIdentity(for: "[ -f x ]") == .skip)
    }

    @Test
    func builtinWithRedirectionIsPrompted() {
        // C2: a built-in with a redirection has side effects and must be
        // prompted, not skipped.
        #expect(LocalExecCommandParser.executableIdentity(for: ": > victim.txt") == .executable(":"))
        #expect(LocalExecCommandParser.executableIdentity(for: "true > out.txt") == .executable("true"))
        #expect(LocalExecCommandParser.executableIdentity(for: "pwd > file") == .executable("pwd"))
    }

    @Test
    func controlFlowKeywordsAreConsumedAndExecutableSurfaces() {
        // C1: after segmentation, control-flow keywords are consumed as
        // syntactic prefixes and the real executable surfaces.
        let segments = LocalExecCommandParser.commandSegments(
            in: "if /bin/touch /tmp/pwn; then true; fi"
        )
        #expect(segments == ["if /bin/touch /tmp/pwn", "then true", "fi"])

        // `if` consumed → `/bin/touch` is the executable.
        #expect(
            LocalExecCommandParser.executableIdentity(for: "if /bin/touch /tmp/pwn")
            == .executable("/bin/touch")
        )
        // `then` consumed → `true` is skip.
        #expect(
            LocalExecCommandParser.executableIdentity(for: "then true") == .skip
        )
        // `fi` consumed → nothing left → skip.
        #expect(
            LocalExecCommandParser.executableIdentity(for: "fi") == .skip
        )
    }

    @Test
    func controlFlowForLoopConsumesKeyword() {
        let segments = LocalExecCommandParser.commandSegments(
            in: "for x in a; do echo $x; done"
        )
        #expect(segments.contains("do echo $x"))
        #expect(
            LocalExecCommandParser.executableIdentity(for: "do echo $x")
            == .executable("echo")
        )
    }

    // MARK: - Identity: environment assignments

    @Test
    func leadingEnvironmentAssignmentIsSkipped() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "FOO=bar swift build")
            == .executable("swift")
        )
    }

    @Test
    func multipleLeadingEnvironmentAssignmentsAreSkipped() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "A=1 B=2 make all")
            == .executable("make")
        )
    }

    @Test
    func envWrapperIsUnwrapped() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "env CI=1 swift test")
            == .executable("swift")
        )
    }

    @Test
    func bareEnvWrapperFallsBack() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "env")
            == .executable("env")
        )
    }

    @Test
    func otherWrappersAreUnwrapped() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "command swift build")
            == .executable("swift")
        )
        #expect(
            LocalExecCommandParser.executableIdentity(for: "exec /bin/sh -c run")
            == .executable("/bin/sh")
        )
        #expect(
            LocalExecCommandParser.executableIdentity(for: "nohup server --port 8080")
            == .executable("server")
        )
        #expect(
            LocalExecCommandParser.executableIdentity(for: "time swift test")
            == .executable("swift")
        )
    }

    @Test
    func sudoIsNotUnwrapped() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "sudo rm -rf /tmp/x")
            == .executable("sudo")
        )
    }

    @Test
    func wrappersConsumeOptions() {
        // C3: wrapper options (starting with `-`) must be consumed before the
        // real command.
        #expect(
            LocalExecCommandParser.executableIdentity(for: "env -i swift build")
            == .executable("swift")
        )
        #expect(
            LocalExecCommandParser.executableIdentity(for: "env -- rm /tmp")
            == .executable("rm")
        )
        #expect(
            LocalExecCommandParser.executableIdentity(for: "command -p swift test")
            == .executable("swift")
        )
        #expect(
            LocalExecCommandParser.executableIdentity(for: "time -p swift test")
            == .executable("swift")
        )
    }

    @Test
    func assignmentOnlyYieldsSkip() {
        // C4: a segment with only environment assignments is harmless.
        #expect(LocalExecCommandParser.executableIdentity(for: "FOO=bar") == .skip)
        #expect(LocalExecCommandParser.executableIdentity(for: "A=1 B=2") == .skip)
    }

    @Test
    func quotedParenInsideSubstitutionDoesNotCorruptDepth() {
        // C5: quoted `(` inside `$()` must not alter substitution depth.
        #expect(
            LocalExecCommandParser.commandSegments(
                in: #"true $(printf '('); /bin/touch /tmp/x"#
            ) == [#"true $(printf '(')"#, "/bin/touch /tmp/x"]
        )
    }

    @Test
    func quotedKeywordIsNotSkipped() {
        // M4: a quoted keyword is a literal path, not a shell keyword.
        #expect(
            LocalExecCommandParser.executableIdentity(for: #"'if'"#)
            == .executable("if")
        )
        #expect(
            LocalExecCommandParser.executableIdentity(for: #""true""#)
            == .executable("true")
        )
    }

    // MARK: - Identity: redirections

    @Test
    func trailingRedirectionIsSkipped() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "ls -la > out.txt")
            == .executable("ls")
        )
    }

    @Test
    func leadingRedirectionIsSkipped() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: ">out.txt echo hi")
            == .executable("echo")
        )
    }

    @Test
    func leadingRedirectWithSeparatedTargetIsSkipped() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "> out.txt echo hi")
            == .executable("echo")
        )
    }

    @Test
    func fdRedirectionWithAttachedTarget() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "2>&1 swift build")
            == .executable("swift")
        )
    }

    @Test
    func appendRedirectionIsSkipped() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "echo hi >> log.txt")
            == .executable("echo")
        )
    }

    @Test
    func fdRedirectionToFile() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "swift build 2>errors.log")
            == .executable("swift")
        )
    }

    @Test
    func combinedStdoutStderrRedirection() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "make &>build.log")
            == .executable("make")
        )
    }

    // MARK: - Identity: grouping delimiters

    @Test
    func leadingParenStripped() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "(cd /tmp")
            == .skip
        )
    }

    @Test
    func trailingParenStripped() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "make)")
            == .executable("make")
        )
    }

    // MARK: - Identity: quoting

    @Test
    func quotedExecutableIsUnwrapped() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: #"'swift' build"#)
            == .executable("swift")
        )
        #expect(
            LocalExecCommandParser.executableIdentity(for: #""swift" build"#)
            == .executable("swift")
        )
    }

    // MARK: - Identity: fallback

    @Test
    func unresolvedFallbackForEmptySegment() {
        // An empty or whitespace-only segment yields unresolved.
        #expect(
            LocalExecCommandParser.executableIdentity(for: "")
            == .unresolved("")
        )
        #expect(
            LocalExecCommandParser.executableIdentity(for: "   ")
            == .unresolved("   ".trimmingCharacters(in: .whitespacesAndNewlines))
        )
    }
}
