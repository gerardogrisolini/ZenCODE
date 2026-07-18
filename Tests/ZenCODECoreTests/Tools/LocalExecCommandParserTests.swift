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

    // MARK: - commandSegments: comment handling

    @Test
    func commentOnlySegmentYieldsNoSegments() {
        #expect(LocalExecCommandParser.commandSegments(in: "# this is a comment").isEmpty)
        #expect(LocalExecCommandParser.commandSegments(in: "   # comment").isEmpty)
    }

    @Test
    func inlineCommentIsStrippedFromSegment() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "swift build # debug build")
            == ["swift build"]
        )
        #expect(
            LocalExecCommandParser.commandSegments(in: "echo hi # comment\ngit status")
            == ["echo hi", "git status"]
        )
    }

    @Test
    func hashInsideWordIsNotComment() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "echo hi#world")
            == ["echo hi#world"]
        )
    }

    @Test
    func quotedHashIsNotComment() {
        #expect(
            LocalExecCommandParser.commandSegments(in: "echo \"# not comment\"")
            == ["echo \"# not comment\""]
        )
    }

    // MARK: - commandSegments: heredoc body

    @Test
    func heredocBodyDoesNotProduceSegments() {
        let command = "cat <<EOF\nnot a command\nnor this\nEOF\necho done"
        #expect(
            LocalExecCommandParser.commandSegments(in: command)
            == ["cat <<EOF", "echo done"]
        )
    }

    @Test
    func quotedHeredocDelimiterBodyDoesNotProduceSegments() {
        let command = "cat <<'EOF'\nrm -rf /\nEOF"
        #expect(
            LocalExecCommandParser.commandSegments(in: command)
            == ["cat <<'EOF'"]
        )
    }

    // MARK: - authorizationCandidates: noise filtered

    @Test
    func authorizationCandidatesEmptyCommandYieldsNothing() {
        #expect(LocalExecCommandParser.authorizationCandidates(in: "").isEmpty)
        #expect(LocalExecCommandParser.authorizationCandidates(in: "   ").isEmpty)
        #expect(LocalExecCommandParser.authorizationCandidates(in: "\n\n").isEmpty)
    }

    @Test
    func authorizationCandidatesCommentOnlyYieldsNothing() {
        #expect(LocalExecCommandParser.authorizationCandidates(in: "# build comment").isEmpty)
        #expect(LocalExecCommandParser.authorizationCandidates(in: "# line 1\n# line 2").isEmpty)
    }

    @Test
    func authorizationCandidatesDecorativeEchoIsFiltered() {
        #expect(LocalExecCommandParser.authorizationCandidates(in: "echo hello world").isEmpty)
        #expect(LocalExecCommandParser.authorizationCandidates(in: "printf 'build step'").isEmpty)
    }

    @Test
    func authorizationCandidatesEchoWithRedirectionIsPrompted() {
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: #"echo "secret" > /tmp/file"#
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "echo")
    }

    @Test
    func authorizationCandidatesBuiltinOnlyYieldsNothing() {
        #expect(LocalExecCommandParser.authorizationCandidates(in: "true").isEmpty)
        #expect(LocalExecCommandParser.authorizationCandidates(in: "false").isEmpty)
        #expect(LocalExecCommandParser.authorizationCandidates(in: "cd /tmp").isEmpty)
    }

    @Test
    func authorizationCandidatesAssignmentOnlyYieldsNothing() {
        #expect(LocalExecCommandParser.authorizationCandidates(in: "FOO=bar").isEmpty)
        #expect(LocalExecCommandParser.authorizationCandidates(in: "A=1 B=2").isEmpty)
    }

    @Test
    func authorizationCandidatesBuiltinWithRedirectionIsPrompted() {
        let candidates = LocalExecCommandParser.authorizationCandidates(in: ": > victim.txt")
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == ":")
    }

    // MARK: - authorizationCandidates: real executables

    @Test
    func authorizationCandidatesPlainExecutable() {
        let candidates = LocalExecCommandParser.authorizationCandidates(in: "swift build")
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "swift")
        #expect(candidates.first?.invocation == "swift build")
    }

    @Test
    func authorizationCandidatesStripsEnvironmentAssignments() {
        let candidates = LocalExecCommandParser.authorizationCandidates(in: "FOO=bar swift build")
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "swift")
        #expect(candidates.first?.invocation == "swift build")
    }

    @Test
    func authorizationCandidatesUnwrapsEnvWrapper() {
        let candidates = LocalExecCommandParser.authorizationCandidates(in: "env CI=1 swift test")
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "swift")
        #expect(candidates.first?.invocation == "swift test")
    }

    @Test
    func authorizationCandidatesUnwrapsNestedWrappers() {
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "env CI=1 command swift test"
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "swift")
        #expect(candidates.first?.invocation == "swift test")
    }

    @Test
    func authorizationCandidatesDeduplicatesByIdentity() {
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "grep foo | sort | grep bar"
        )
        #expect(candidates.count == 2)
        #expect(candidates[0].identity == "grep")
        #expect(candidates[1].identity == "sort")
    }

    @Test
    func authorizationCandidatesKeepsRedirectionsInInvocation() {
        let candidates = LocalExecCommandParser.authorizationCandidates(in: "swift build 2>&1")
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "swift")
        #expect(candidates.first?.invocation == "swift build 2>&1")
    }

    // MARK: - authorizationCandidates: shell -c recursion

    @Test
    func authorizationCandidatesShellDashCExtractsNestedCommands() {
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "bash -lc 'echo separator; git status'"
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "git")
        #expect(candidates.first?.invocation == "git status")
    }

    @Test
    func authorizationCandidatesShellDashCWithDecorativeEchoOnly() {
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: #"sh -c 'echo hi'"#
        )
        #expect(candidates.isEmpty)
    }

    // MARK: - authorizationCandidates: command substitution extraction

    @Test
    func authorizationCandidatesEchoWithSubstitutionExtractsNested() {
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: #"echo "$(git rev-parse HEAD)""#
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "git")
        #expect(candidates.first?.invocation == "git rev-parse HEAD")
    }

    // MARK: - authorizationCandidates: composite fixture

    @Test
    func authorizationCandidatesCompositeFixture() {
        let command = """
        # build
        echo "== Build =="
        true && env CI=1 command swift test
        """
        let candidates = LocalExecCommandParser.authorizationCandidates(in: command)
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "swift")
        #expect(candidates.first?.invocation == "swift test")
    }

    @Test
    func authorizationCandidatesHeredocBodyFiltered() {
        let command = "cat <<EOF\nrm -rf /\nEOF\necho done"
        let candidates = LocalExecCommandParser.authorizationCandidates(in: command)
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "cat")
    }

    // MARK: - authorizationCandidates: conservative fallback

    @Test
    func authorizationCandidatesUnknownExecutableProducesCandidate() {
        let candidates = LocalExecCommandParser.authorizationCandidates(in: "my CustomTool --flag")
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "my")
    }

    @Test
    func authorizationCandidatesSudoNotUnwrapped() {
        let candidates = LocalExecCommandParser.authorizationCandidates(in: "sudo rm -rf /tmp/x")
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "sudo")
    }

    @Test
    func authorizationCandidatesControlFlowSurfacesExecutable() {
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "if /bin/touch /tmp/x; then true; fi"
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "/bin/touch")
    }

    // MARK: - Review fixes: nested substitution extraction (F1)

    @Test
    func normalExecutableWithNestedSubstitutionExtractsBoth() {
        // cat "$(rm -rf /tmp/x)" must surface BOTH cat and rm.
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "cat \"$(rm -rf /tmp/x)\""
        )
        #expect(candidates.count == 2)
        #expect(candidates[0].identity == "cat")
        #expect(candidates[1].identity == "rm")
        #expect(candidates[1].invocation == "rm -rf /tmp/x")
    }

    @Test
    func nestedSubstitutionInAssignmentPrefix() {
        // FOO=$(rm -rf x) outer: the security-critical requirement is that the
        // nested `rm` is surfaced for authorization (never silently executed).
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "FOO=$(rm -rf x) make"
        )
        let identities = Set(candidates.map(\.identity))
        #expect(identities.contains("rm"))
    }

    // MARK: - Review fixes: process substitution extraction (F2)

    @Test
    func processSubstitutionExtractsNestedCommand() {
        // diff <(rm -rf /tmp/x) expected must surface diff and rm.
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "diff <(rm -rf /tmp/x) expected"
        )
        let identities = Set(candidates.map(\.identity))
        #expect(identities.contains("diff"))
        #expect(identities.contains("rm"))
    }

    @Test
    func outputProcessSubstitutionExtractsNestedCommand() {
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "tee >(rm -rf /tmp/x)"
        )
        let identities = Set(candidates.map(\.identity))
        #expect(identities.contains("tee"))
        #expect(identities.contains("rm"))
    }

    // MARK: - Review fixes: arithmetic expansion (F5)

    @Test
    func arithmeticExpansionIsNotCommandSubstitution() {
        // $((swift)) is arithmetic, not a command; must not surface swift.
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "echo $((1 + 2))"
        )
        #expect(candidates.isEmpty)
    }

    @Test
    func arithmeticExpansionAlongsideRealCommandSubstitution() {
        // Mixed: $((...)) is ignored, $(rm) is extracted.
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "cat \"$((1+2))\" \"$(rm x)\""
        )
        let identities = Set(candidates.map(\.identity))
        #expect(identities.contains("cat"))
        #expect(identities.contains("rm"))
        #expect(!identities.contains("1"))
    }

    // MARK: - Review fixes: wrapper option arity (F4)

    @Test
    func commandDashVIsIntrospectionNotExecution() {
        // command -v swift looks up swift, does not execute it.
        #expect(
            LocalExecCommandParser.executableIdentity(for: "command -v swift") == .skip
        )
        #expect(
            LocalExecCommandParser.authorizationCandidates(in: "command -v swift").isEmpty
        )
    }

    @Test
    func envUnsetOptionConsumesOperand() {
        // env -u NAME swift build must surface swift, not NAME.
        #expect(
            LocalExecCommandParser.executableIdentity(for: "env -u NAME swift build")
            == .executable("swift")
        )
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "env -u NAME swift build"
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "swift")
        #expect(candidates.first?.invocation == "swift build")
    }

    @Test
    func envChdirOptionConsumesOperand() {
        #expect(
            LocalExecCommandParser.executableIdentity(for: "env -C /tmp swift build")
            == .executable("swift")
        )
    }

    // MARK: - Review fixes: for/case headers (F7)

    @Test
    func forLoopHeaderDoesNotSurfaceLoopVariable() {
        // `for x in a b` header must not produce a candidate `x`, `a`, or `b`.
        #expect(
            LocalExecCommandParser.executableIdentity(for: "for x in a b")
            == .skip
        )
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "for x in a b; do rm -rf target; done"
        )
        let identities = Set(candidates.map(\.identity))
        #expect(identities.contains("rm"))
        #expect(!identities.contains("x"))
        #expect(!identities.contains("a"))
    }

    @Test
    func caseStatementSurfacesBranchCommandNotSubject() {
        // `case x in x) rm ...` must surface rm, not x.
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "case x in x) rm -rf target;; esac"
        )
        let identities = Set(candidates.map(\.identity))
        #expect(identities.contains("rm"))
        #expect(!identities.contains("x"))
    }

    // MARK: - Review fixes: unquoted heredoc expansion (F6)

    @Test
    func unquotedHeredocBodyExtractsCommandSubstitution() {
        // An unquoted heredoc delimiter expands $(...) in the body.
        let command = "cat <<EOF\nvalue=$(rm -rf /tmp/x)\nEOF"
        let candidates = LocalExecCommandParser.authorizationCandidates(in: command)
        let identities = Set(candidates.map(\.identity))
        #expect(identities.contains("cat"))
        #expect(identities.contains("rm"))
    }

    @Test
    func quotedHeredocBodyDoesNotExpand() {
        // A quoted heredoc delimiter keeps the body literal.
        let command = "cat <<'EOF'\nvalue=$(rm -rf /tmp/x)\nEOF"
        let candidates = LocalExecCommandParser.authorizationCandidates(in: command)
        let identities = Set(candidates.map(\.identity))
        #expect(identities.contains("cat"))
        #expect(!identities.contains("rm"))
    }

    // MARK: - Review fixes: leading redirection preserved (F9)

    @Test
    func leadingRedirectionPreservedInInvocation() {
        // > victim.txt echo ok: the redirection must remain visible.
        let candidates = LocalExecCommandParser.authorizationCandidates(
            in: "> victim.txt cat file"
        )
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "cat")
        #expect(candidates.first?.invocation.contains("victim.txt") == true)
    }

    // MARK: - Review fixes: privilege wrappers and dynamic builtins

    @Test
    func doasIsNotUnwrapped() {
        let candidates = LocalExecCommandParser.authorizationCandidates(in: "doas rm -rf /tmp/x")
        #expect(candidates.count == 1)
        #expect(candidates.first?.identity == "doas")
    }

    @Test
    func evalSourceTrapRemainPromptWorthy() {
        // Dynamic builtins are not in the skip list, so they surface.
        #expect(
            LocalExecCommandParser.authorizationCandidates(in: "eval \"$CMD\"").first?.identity == "eval"
        )
        #expect(
            LocalExecCommandParser.authorizationCandidates(in: "source script.sh").first?.identity == "source"
        )
        #expect(
            LocalExecCommandParser.authorizationCandidates(in: "trap cleanup EXIT").first?.identity == "trap"
        )
    }

    // MARK: - Review fixes: fail-closed limits (F3)

    @Test
    func deeplyNestedSubstitutionStaysFailClosed() {
        // Build a command nested deeper than maxCandidateDepth (8). The parser
        // must still produce at least one candidate (fail-closed), never empty.
        var command = "rm -rf /tmp/x"
        for _ in 0..<12 {
            command = "cat \"$(\(command))\""
        }
        let candidates = LocalExecCommandParser.authorizationCandidates(in: command)
        #expect(!candidates.isEmpty)
    }
}
