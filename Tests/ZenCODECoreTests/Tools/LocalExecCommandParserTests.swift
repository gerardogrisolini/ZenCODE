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
    // MARK: - Segmentation

    static let segmentationCases: [(String, [String])] = [
        // Pipes and logical operators.
        ("printf one | grep one|sort", ["printf one", "grep one", "sort"]),
        ("producer |& consumer", ["producer", "consumer"]),
        ("primary || fallback", ["primary", "fallback"]),
        ("cmd1 && cmd2", ["cmd1", "cmd2"]),
        ("cmd1; cmd2", ["cmd1", "cmd2"]),
        ("cmd &", ["cmd"]),
        ("cmd1\ncmd2\n", ["cmd1", "cmd2"]),
        ("false || make && install", ["false", "make", "install"]),
        // Quoting and escaping preserved.
        (#"printf 'a|b' | grep a"#, [#"printf 'a|b'"#, "grep a"]),
        (#"printf "a|b" | grep a"#, [#"printf "a|b""#, "grep a"]),
        (#"printf a\|b | grep a"#, [#"printf a\|b"#, "grep a"]),
        // Conditional/arithmetic/case pipes are not pipelines.
        (
            #"[[ "$value" =~ ^(foo|bar)$ ]] && rm -f marker"#,
            [#"[[ "$value" =~ ^(foo|bar)$ ]]"#, "rm -f marker"]
        ),
        ("(( mask = 1 | 2 )) && rm -f marker", ["(( mask = 1 | 2 ))", "rm -f marker"]),
        (
            "case x in foo|bar) rm -rf target;; esac",
            ["case x in foo|bar)", "rm -rf target", "esac"]
        ),
        // Substitutions are opaque.
        ("echo $(ls | wc -l)", ["echo $(ls | wc -l)"]),
        (
            "echo $(cat $(find . -name '*.txt') | wc -l)",
            ["echo $(cat $(find . -name '*.txt') | wc -l)"]
        ),
        ("echo `ls | wc -l`", ["echo `ls | wc -l`"]),
        ("diff <(ls a) <(ls b) | cat", ["diff <(ls a) <(ls b)", "cat"]),
        // C5: quoted `(` inside `$()` must not alter substitution depth.
        (
            #"true $(printf '('); /bin/touch /tmp/x"#,
            [#"true $(printf '(')"#, "/bin/touch /tmp/x"]
        ),
        // C1: control-flow keywords split into their own segments.
        (
            "if /bin/touch /tmp/pwn; then true; fi",
            ["if /bin/touch /tmp/pwn", "then true", "fi"]
        ),
        // Edge cases.
        ("", []),
        ("   ", []),
        ("  cmd   ", ["cmd"]),
        // Comments.
        ("# this is a comment", []),
        ("   # comment", []),
        ("swift build # debug build", ["swift build"]),
        ("echo hi # comment\ngit status", ["echo hi", "git status"]),
        ("echo hi#world", ["echo hi#world"]),
        ("echo \"# not comment\"", ["echo \"# not comment\""]),
        // Heredoc bodies do not produce segments.
        ("cat <<EOF\nnot a command\nnor this\nEOF\necho done", ["cat <<EOF", "echo done"]),
        ("cat <<'EOF'\nrm -rf /\nEOF", ["cat <<'EOF'"]),
    ]

    @Test(arguments: LocalExecCommandParserTests.segmentationCases)
    func commandSegmentsSplitAtShellSeparatorsOnly(command: String, segments: [String]) {
        #expect(LocalExecCommandParser.commandSegments(in: command) == segments)
    }

    // MARK: - Identity

    static let identityCases: [(String, LocalExecCommandParser.Identity)] = [
        // Plain executables.
        ("swift build", .executable("swift")),
        ("git status --short", .executable("git")),
        // Skip-list built-ins and keywords.
        ("true", .skip),
        ("false", .skip),
        (":", .skip),
        ("cd /tmp", .skip),
        ("pwd", .skip),
        ("test -f x", .skip),
        ("[ -f x ]", .skip),
        // C2: a built-in with a redirection has side effects and is prompted.
        (": > victim.txt", .executable(":")),
        ("true > out.txt", .executable("true")),
        ("pwd > file", .executable("pwd")),
        // C1: control-flow keywords are consumed and the executable surfaces.
        ("if /bin/touch /tmp/pwn", .executable("/bin/touch")),
        ("then true", .skip),
        ("fi", .skip),
        ("do echo $x", .executable("echo")),
        // F7: a for header does not surface the loop variable.
        ("for x in a b", .skip),
        // Environment assignments and wrappers.
        ("FOO=bar swift build", .executable("swift")),
        ("A=1 B=2 make all", .executable("make")),
        ("env CI=1 swift test", .executable("swift")),
        ("env", .executable("env")),
        ("command swift build", .executable("swift")),
        ("exec /bin/sh -c run", .executable("/bin/sh")),
        ("nohup server --port 8080", .executable("server")),
        ("time swift test", .executable("swift")),
        ("sudo rm -rf /tmp/x", .executable("sudo")),
        // C3: wrapper options are consumed before the real command.
        ("env -i swift build", .executable("swift")),
        ("env -- rm /tmp", .executable("rm")),
        ("command -p swift test", .executable("swift")),
        ("time -p swift test", .executable("swift")),
        // F4: wrapper option arity.
        ("command -v swift", .skip),
        ("env -u NAME swift build", .executable("swift")),
        ("env -C /tmp swift build", .executable("swift")),
        // C4: assignment-only segments are harmless.
        ("FOO=bar", .skip),
        ("A=1 B=2", .skip),
        // M4: a quoted keyword is a literal path, not a shell keyword.
        (#"'if'"#, .executable("if")),
        (#""true""#, .executable("true")),
        // Redirections.
        ("ls -la > out.txt", .executable("ls")),
        (">out.txt echo hi", .executable("echo")),
        ("> out.txt echo hi", .executable("echo")),
        ("2>&1 swift build", .executable("swift")),
        ("echo hi >> log.txt", .executable("echo")),
        ("swift build 2>errors.log", .executable("swift")),
        ("make &>build.log", .executable("make")),
        (">| out.txt echo hi", .executable("echo")),
        // Grouping delimiters.
        ("(cd /tmp", .skip),
        ("make)", .executable("make")),
        // Quoted executables.
        (#"'swift' build"#, .executable("swift")),
        (#""swift" build"#, .executable("swift")),
        // Fallback for empty segments.
        ("", .unresolved("")),
        ("   ", .unresolved("")),
    ]

    @Test(arguments: LocalExecCommandParserTests.identityCases)
    func executableIdentityStripsShellNoise(
        segment: String,
        identity: LocalExecCommandParser.Identity
    ) {
        #expect(LocalExecCommandParser.executableIdentity(for: segment) == identity)
    }

    // MARK: - authorizationCandidates

    static let candidateIdentityCases: [(String, [String])] = [
        // Noise filtered.
        ("", []),
        ("   ", []),
        ("\n\n", []),
        ("# build comment", []),
        ("# line 1\n# line 2", []),
        ("echo hello world", []),
        ("printf 'build step'", []),
        ("true", []),
        ("false", []),
        ("cd /tmp", []),
        ("FOO=bar", []),
        ("A=1 B=2", []),
        ("echo $((1 + 2))", []),
        ("command -v swift", []),
        (#"sh -c 'echo hi'"#, []),
        // Redirections make built-ins and decorative commands prompt-worthy.
        (#"echo "secret" > /tmp/file"#, ["echo"]),
        (": > victim.txt", [":"]),
        ("echo hi >| out.txt", ["echo"]),
        ("echo hi > | cat", ["echo", "cat"]),
        // Real executables.
        ("swift build", ["swift"]),
        ("FOO=bar swift build", ["swift"]),
        ("env CI=1 swift test", ["swift"]),
        ("env CI=1 command swift test", ["swift"]),
        ("env -u NAME swift build", ["swift"]),
        ("swift build 2>&1", ["swift"]),
        ("grep foo | sort | grep bar", ["grep", "sort"]),
        ("bash -lc 'echo separator; git status'", ["git"]),
        // Shell `-c`: only a short option group carries `c`; long options such
        // as `--norc` or `--restricted` are skipped, never taken for `-c`.
        ("bash --norc -c 'rm -rf x'", ["rm"]),
        ("sh --restricted -c 'rm x'", ["rm"]),
        ("bash -lc 'git status'", ["git"]),
        ("bash -ec 'rm x'", ["rm"]),
        ("bash -xc 'rm x'", ["rm"]),
        ("bash -cl 'rm x'", ["rm"]),
        // A long option before a script is not `-c`: the shell itself runs.
        ("bash --norc script.sh", ["bash"]),
        // Option arguments (`--rcfile FILE`) are not modeled: the argument
        // ends the `-c` search and the segment conservatively falls back to
        // the shell, which requires its own authorization (like `-o OPTION`).
        ("bash --rcfile f -c 'rm x'", ["bash"]),
        // Wrapper operands (`env -u NAME`) are not modeled by the `-c` search
        // either: the same conservative fallback to the shell, until it is
        // aligned with `wrapperOptionInfo(wrapper:option:)`.
        ("env -u X bash -c 'rm x'", ["bash"]),
        (#"echo "$(git rev-parse HEAD)""#, ["git"]),
        (
            """
            # build
            echo "== Build =="
            true && env CI=1 command swift test
            """,
            ["swift"]
        ),
        ("cat <<EOF\nrm -rf /\nEOF\necho done", ["cat"]),
        // Conservative fallback and privilege wrappers.
        ("my CustomTool --flag", ["my"]),
        ("sudo rm -rf /tmp/x", ["sudo"]),
        ("doas rm -rf /tmp/x", ["doas"]),
        // Control flow and compound expressions.
        ("if /bin/touch /tmp/x; then true; fi", ["/bin/touch"]),
        (#"[[ "$value" =~ ^(foo|bar)$ ]] && rm -f marker"#, ["rm"]),
        ("[[evil]] | rm -f marker", ["[[evil]]", "rm"]),
        ("(( mask = 1 | 2 )) && rm -f marker", ["rm"]),
        ("if (( mask = 1 | 2 )); then :; fi", []),
        ("if [[ left > right ]]; then rm -f marker; fi", ["rm"]),
        ("{ [[ left > right ]]; (( harmless = 1 )); }", []),
        ("{ [[ left > right ]]; rm -rf target; }", ["rm"]),
        // F1: nested substitutions surface their executables.
        ("cat \"$(rm -rf /tmp/x)\"", ["cat", "rm"]),
        ("true $(rm -f marker)", ["rm"]),
        (#"[[ "$(rm -f marker)" =~ foo|bar ]]"#, ["rm"]),
        (#"[[ left > right && right < limit ]]"#, []),
        (#"[[ left > right ]] > result.txt"#, ["[["]),
        // F7: case statements.
        ("case x in foo|bar) rm -rf target;; esac", ["rm"]),
        ("case x in x) :;; esac\ntrue | rm -rf target", ["rm"]),
        ("case esac in\nfoo|bar) rm -rf target;;\nesac", ["rm"]),
        ("X=; case 'foo)bar' in ${X:-foo)bar}) rm -rf target;; esac", ["rm"]),
        ("X=; case '}foo)true' in ${X:-$(printf %s })foo)true}) touch marker;; esac", ["touch"]),
        ("case ')' in [)]) rm -rf target;; esac", ["rm"]),
        (#"case true in "x)"|true) rm -rf target;; esac"#, ["rm"]),
        (
            """
            case "$value" in
              foo|bar) cat input | grep needle ;;
              baz|qux) rm -f marker ;;
            esac
            """,
            ["cat", "grep", "rm"]
        ),
        (
            """
            case "$value" in
              first) true ;;
              $(rm -f marker)|other) true ;;
            esac
            """,
            ["rm"]
        ),
        (
            """
            case "$outer" in
              first)
                case "$inner" in
                  x|y) cat input ;;
                esac
                ;;
              second|third) rm -f marker ;;
            esac
            """,
            ["cat", "rm"]
        ),
        ("case x in first) echo esac;; second|third) rm marker;; esac", ["rm"]),
    ]

    @Test(arguments: LocalExecCommandParserTests.candidateIdentityCases)
    func authorizationCandidatesSurfaceOnlyPromptWorthyExecutables(
        command: String,
        identities: [String]
    ) {
        #expect(
            LocalExecCommandParser.authorizationCandidates(in: command).map(\.identity)
            == identities
        )
    }

    static let candidateInvocationCases: [(String, String, String)] = [
        ("swift build", "swift", "swift build"),
        ("FOO=bar swift build", "swift", "swift build"),
        ("env CI=1 swift test", "swift", "swift test"),
        ("env CI=1 command swift test", "swift", "swift test"),
        ("env -u NAME swift build", "swift", "swift build"),
        ("swift build 2>&1", "swift", "swift build 2>&1"),
        ("bash -lc 'echo separator; git status'", "git", "git status"),
        ("bash --norc -c 'rm -rf x'", "rm", "rm -rf x"),
        // The conservative shell fallback still shows the inner command.
        ("bash --rcfile f -c 'rm x'", "bash", "bash --rcfile f -c rm x"),
        ("env -u X bash -c 'rm x'", "bash", "bash -c rm x"),
        (#"echo "$(git rev-parse HEAD)""#, "git", "git rev-parse HEAD"),
        (
            """
            # build
            echo "== Build =="
            true && env CI=1 command swift test
            """,
            "swift",
            "swift test"
        ),
        ("cat \"$(rm -rf /tmp/x)\"", "rm", "rm -rf /tmp/x"),
    ]

    @Test(arguments: LocalExecCommandParserTests.candidateInvocationCases)
    func authorizationCandidatesCarryTheCleanedInvocation(
        command: String,
        identity: String,
        invocation: String
    ) {
        let candidates = LocalExecCommandParser.authorizationCandidates(in: command)
        #expect(candidates.first { $0.identity == identity }?.invocation == invocation)
    }

    // MARK: - Shell -c payload

    static let shellDashCPayloadCases: [(String, String?)] = [
        ("bash -c 'rm -rf x'", "rm -rf x"),
        // Short option groups carrying `c`.
        ("bash -lc 'git status'", "git status"),
        ("bash -ec 'rm x'", "rm x"),
        ("bash -cl 'rm x'", "rm x"),
        // Long options are skipped and never taken for `-c`.
        ("bash --norc -c 'rm -rf x'", "rm -rf x"),
        ("sh --restricted -c 'rm x'", "rm x"),
        ("bash --posix --norc -lc 'git status'", "git status"),
        ("bash --norc script.sh", nil),
        ("bash --norc", nil),
        // Option arguments and wrapper operands end the search (conservative).
        ("bash --rcfile f -c 'rm x'", nil),
        ("env -u X bash -c 'rm x'", nil),
    ]

    @Test(arguments: LocalExecCommandParserTests.shellDashCPayloadCases)
    func shellDashCPayloadRecognizesOnlyShortCOptions(command: String, payload: String?) {
        #expect(LocalExecCommandParser.shellDashCPayload(for: command) == payload)
    }

    /// Nested and process substitutions, heredoc bodies, and loop/case
    /// headers: the nested executables must surface (never silently run)
    /// while syntactic words must not.
    static let nestedCandidateCases: [(String, Set<String>, Set<String>)] = [
        ("FOO=$(rm -rf x) make", ["rm"], []),
        ("diff <(rm -rf /tmp/x) expected", ["diff", "rm"], []),
        ("tee >(rm -rf /tmp/x)", ["tee", "rm"], []),
        (#"cat "$((1+2))" "$(rm x)""#, ["cat", "rm"], ["1"]),
        ("for x in a b; do rm -rf target; done", ["rm"], ["x", "a"]),
        ("case x in x) rm -rf target;; esac", ["rm"], ["x"]),
        ("cat <<EOF\nvalue=$(rm -rf /tmp/x)\nEOF", ["cat", "rm"], []),
        ("cat <<'EOF'\nvalue=$(rm -rf /tmp/x)\nEOF", ["cat"], ["rm"]),
    ]

    @Test(arguments: LocalExecCommandParserTests.nestedCandidateCases)
    func authorizationCandidatesSurfaceNestedExecutables(
        command: String,
        required: Set<String>,
        forbidden: Set<String>
    ) {
        let identities = Set(
            LocalExecCommandParser.authorizationCandidates(in: command).map(\.identity)
        )
        #expect(required.isSubset(of: identities))
        #expect(identities.isDisjoint(with: forbidden))
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
        #expect(candidates.contains { $0.identity == LocalExecCommandParser.analysisDepthLimitIdentity })
    }
}
