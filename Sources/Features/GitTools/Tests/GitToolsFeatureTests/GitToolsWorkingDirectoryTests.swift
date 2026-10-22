import Foundation
import FeatureKit
import Testing
@testable import GitToolsFeature

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(T.self, from: Data(json.utf8))
}

/// The process environment with the developer's git configuration masked out:
/// `~/.gitconfig` and the system config (`grep.column`, `status.branch`,
/// `core.quotePath`, commit signing, ...) must not change the asserted strings,
/// and commits must work without a global identity.
private let hermeticGitEnvironment: [String: String] = {
    var environment = ProcessInfo.processInfo.environment
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_NOSYSTEM"] = "1"
    environment["GIT_TERMINAL_PROMPT"] = "0"
    environment["GIT_AUTHOR_NAME"] = "GitTools Tests"
    environment["GIT_AUTHOR_EMAIL"] = "git-tools@example.invalid"
    environment["GIT_COMMITTER_NAME"] = "GitTools Tests"
    environment["GIT_COMMITTER_EMAIL"] = "git-tools@example.invalid"
    return environment
}()

private func makeContext(workingDirectory: URL) -> FeatureContext {
    FeatureContext(workingDirectory: workingDirectory, environment: hermeticGitEnvironment)
}

/// A throwaway git repository under a UUID-named temporary directory with one
/// commit, so the tools never touch the ZenCODE checkout.
private struct TemporaryRepository {
    let root: URL
    let file: URL

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-tools-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        file = root.appendingPathComponent("tracked.txt")
        try "one\ntwo\nthree\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["init", "-q"])
        // Portable branch naming (`git init -b` needs git 2.28+).
        try await git(["symbolic-ref", "HEAD", "refs/heads/main"])
        try await git(["add", "--", "tracked.txt"])
        try await git(["commit", "-q", "-m", "initial commit"])
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    func git(_ arguments: [String]) async throws -> FeatureProcessResult {
        let result = try await FeatureProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git", "-c", "user.name=GitTools Tests", "-c", "user.email=git-tools@example.invalid",
                        "-c", "commit.gpgsign=false"] + arguments,
            workingDirectory: root,
            environment: GitToolsSupport.gitEnvironment(hermeticGitEnvironment),
            timeout: 60
        )
        try #require(result.exitCode == 0, "git \(arguments) failed: \(result.stderr)")
        return result
    }

    /// A context whose session working directory is an unrelated temp dir, so
    /// a tool that ignores the requested directory cannot accidentally succeed.
    func unrelatedContext() throws -> FeatureContext {
        let other = FileManager.default.temporaryDirectory
            .appendingPathComponent("git-tools-tests-other-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        return makeContext(workingDirectory: other)
    }
}

@Suite("GitTools working directory resolution")
struct GitToolsWorkingDirectoryTests {
    @Test func pathAloneSelectsRepositoryForStatusAndLog() async throws {
        let repository = try await TemporaryRepository()
        defer { repository.remove() }
        let context = try repository.unrelatedContext()
        defer { try? FileManager.default.removeItem(at: context.workingDirectory) }

        let status = try decode(GitStatusTool.Input.self, #"{"path":"\#(repository.root.path)"}"#)
        let statusOutput = try await GitStatusTool().run(status, context: context)
        #expect(statusOutput.hasPrefix("exit_code: 0"))
        #expect(statusOutput.contains("## main"))

        let log = try decode(GitLogTool.Input.self, #"{"path":"\#(repository.root.path)","limit":5}"#)
        let logOutput = try await GitLogTool().run(log, context: context)
        #expect(logOutput.hasPrefix("exit_code: 0"))
        #expect(logOutput.contains("initial commit"))
    }

    @Test func relativePathResolvesAgainstSessionWorkingDirectory() async throws {
        let repository = try await TemporaryRepository()
        defer { repository.remove() }
        let context = FeatureContext(
            workingDirectory: repository.root.deletingLastPathComponent(),
            environment: hermeticGitEnvironment
        )
        let input = try decode(GitStatusTool.Input.self, #"{"path":"\#(repository.root.lastPathComponent)"}"#)
        let resolved = try GitToolsSupport.gitWorkingDirectory(input: input, context: context)
        #expect(resolved.standardizedFileURL.path == repository.root.standardizedFileURL.path)
    }

    @Test func workingDirectoryWinsOverPath() async throws {
        let repository = try await TemporaryRepository()
        defer { repository.remove() }
        let context = try repository.unrelatedContext()
        defer { try? FileManager.default.removeItem(at: context.workingDirectory) }

        let input = try decode(
            GitStatusTool.Input.self,
            #"{"path":"\#(context.workingDirectory.path)","workingDirectory":"\#(repository.root.path)"}"#
        )
        let resolved = try GitToolsSupport.gitWorkingDirectory(input: input, context: context)
        #expect(resolved.standardizedFileURL.path == repository.root.standardizedFileURL.path)
        let output = try await GitStatusTool().run(input, context: context)
        #expect(output.contains("## main"))
    }

    @Test func filePassedAsPathToStatusFailsClearly() async throws {
        let repository = try await TemporaryRepository()
        defer { repository.remove() }
        let context = makeContext(workingDirectory: repository.root)
        let input = try decode(GitStatusTool.Input.self, #"{"path":"\#(repository.file.path)"}"#)
        await #expect {
            try await GitStatusTool().run(input, context: context)
        } throws: { error in
            guard case let GitToolsFeatureError.invalidWorkingDirectory(message)? = error as? GitToolsFeatureError else {
                return false
            }
            return message.contains("'path'") && message.contains("must be a directory") && message.contains("workingDirectory")
        }
    }

    @Test func nonexistentWorkingDirectoryFailsInsteadOfRunningInHostDirectory() throws {
        let context = FeatureContext(workingDirectory: FileManager.default.temporaryDirectory)
        let missing = "git-tools-missing-\(UUID().uuidString)"
        let viaWorkingDirectory = try decode(GitLogTool.Input.self, #"{"workingDirectory":"\#(missing)"}"#)
        #expect(throws: GitToolsFeatureError.self) {
            try GitToolsSupport.gitWorkingDirectory(input: viaWorkingDirectory, context: context)
        }
        let viaPath = try decode(GitLogTool.Input.self, #"{"path":"\#(missing)"}"#)
        #expect(throws: GitToolsFeatureError.self) {
            try GitToolsSupport.gitWorkingDirectory(input: viaPath, context: context)
        }
    }

    @Test func pathspecToolsKeepPathAsFileTarget() async throws {
        let repository = try await TemporaryRepository()
        defer { repository.remove() }
        let context = makeContext(workingDirectory: repository.root)

        // `path` names the file, not the directory: the repository still comes from the session.
        let diff = try decode(GitDiffTool.Input.self, #"{"path":"tracked.txt"}"#)
        #expect(try GitDiffTool.arguments(for: diff) == ["diff", "--", "tracked.txt"])
        let resolved = try GitToolsSupport.gitWorkingDirectory(input: diff, context: context)
        #expect(resolved.standardizedFileURL.path == repository.root.standardizedFileURL.path)

        let blame = try decode(GitBlameTool.Input.self, #"{"path":"tracked.txt","startLine":2,"endLine":3}"#)
        let output = try await GitBlameTool().run(blame, context: context)
        #expect(output.hasPrefix("exit_code: 0"))
        #expect(output.contains("two"))
        #expect(output.contains("three"))
        #expect(!output.contains("one"))
    }

    @Test func gitEnvironmentDisablesTerminalPromptsWithoutOverridingCaller() {
        #expect(GitToolsSupport.gitEnvironment(["PATH": "/usr/bin"])["GIT_TERMINAL_PROMPT"] == "0")
        #expect(GitToolsSupport.gitEnvironment(["GIT_TERMINAL_PROMPT": "1"])["GIT_TERMINAL_PROMPT"] == "1")
    }

    @Test func grepCapsTotalMatchesAcrossFilesAndReportsTruncation() async throws {
        let repository = try await TemporaryRepository()
        defer { repository.remove() }
        // Three files with two matches each: a per-file limit of 2 would keep all
        // six lines, the total cap must keep only the first two.
        for name in ["a.txt", "b.txt", "c.txt"] {
            try "needle 1\nhay\nneedle 2\n".write(to: repository.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await repository.git(["add", "--", "a.txt", "b.txt", "c.txt"])
        let context = makeContext(workingDirectory: repository.root)

        let capped = try decode(GitGrepTool.Input.self, #"{"pattern":"needle","maxResults":2}"#)
        let output = try await GitGrepTool().run(capped, context: context)
        #expect(output.hasPrefix("exit_code: 0\nstdout:\na.txt:1:needle 1\na.txt:3:needle 2\n"))
        #expect(output.contains("[output truncated to the first 2 of 6 matches"))
        #expect(!output.contains("b.txt"))

        let complete = try decode(GitGrepTool.Input.self, #"{"pattern":"needle","paths":["b.txt","c.txt"]}"#)
        let completeOutput = try await GitGrepTool().run(complete, context: context)
        #expect(completeOutput == "exit_code: 0\nstdout:\nb.txt:1:needle 1\nb.txt:3:needle 2\nc.txt:1:needle 1\nc.txt:3:needle 2")

        let optionLikePattern = try decode(GitGrepTool.Input.self, #"{"pattern":"-e","filesOnly":true}"#)
        let noMatch = try await GitGrepTool().run(optionLikePattern, context: context)
        #expect(noMatch.hasPrefix("exit_code: 1"))
    }

    @Test func grepCountsOnlyMatchLinesAgainstMaxResultsWithContext() async throws {
        let repository = try await TemporaryRepository()
        defer { repository.remove() }
        // Each file: a match at line 2 and one at line 8, far enough apart for
        // context 2 to produce separate groups (`--` separators).
        let body = "h1\nneedle 1\nh3\nh4\nh5\nh6\nh7\nneedle 2\nh9\n"
        for name in ["a.txt", "b.txt"] {
            try body.write(to: repository.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await repository.git(["add", "--", "a.txt", "b.txt"])
        let context = makeContext(workingDirectory: repository.root)

        // 4 matches in total; with the old line-based cap, context 2 + maxResults 3
        // would have kept a single match.
        let input = try decode(GitGrepTool.Input.self, #"{"pattern":"needle","maxResults":3,"context":2}"#)
        let output = try await GitGrepTool().run(input, context: context)
        let expectedStdout = """
        a.txt-1-h1
        a.txt:2:needle 1
        a.txt-3-h3
        a.txt-4-h4
        --
        a.txt-6-h6
        a.txt-7-h7
        a.txt:8:needle 2
        a.txt-9-h9
        --
        b.txt-1-h1
        b.txt:2:needle 1
        b.txt-3-h3
        b.txt-4-h4
        """
        #expect(output == "exit_code: 0\nstdout:\n\(expectedStdout)\n[output truncated to the first 3 of 4 matches; raise maxResults or narrow the request]")

        // Without a cap the full grouped output comes back in the standard form.
        let complete = try decode(GitGrepTool.Input.self, #"{"pattern":"needle","context":2,"paths":["b.txt"]}"#)
        let completeOutput = try await GitGrepTool().run(complete, context: context)
        #expect(completeOutput == "exit_code: 0\nstdout:\nb.txt-1-h1\nb.txt:2:needle 1\nb.txt-3-h3\nb.txt-4-h4\n--\nb.txt-6-h6\nb.txt-7-h7\nb.txt:8:needle 2\nb.txt-9-h9")
    }

    @Test func grepClassifiesLinesCorrectlyForPathsContainingSeparators() async throws {
        let repository = try await TemporaryRepository()
        defer { repository.remove() }
        // A path with `:` and `-` and a context line that looks like `path:LINE:`
        // would fool a textual parser; the NUL-delimited output is unambiguous.
        let name = "a:1-b.txt"
        try "x:1:needle 1\nneedle 2\na:1-b.txt:3:decoy\nneedle 3\n"
            .write(to: repository.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        try await repository.git(["add", "--", name])
        let context = makeContext(workingDirectory: repository.root)

        let input = try decode(GitGrepTool.Input.self, #"{"pattern":"needle","maxResults":2,"context":1,"paths":["\#(name)"]}"#)
        let output = try await GitGrepTool().run(input, context: context)
        #expect(output == "exit_code: 0\nstdout:\na:1-b.txt:1:x:1:needle 1\na:1-b.txt:2:needle 2\na:1-b.txt-3-a:1-b.txt:3:decoy\n[output truncated to the first 2 of 3 matches; raise maxResults or narrow the request]")

        let filesOnly = try decode(GitGrepTool.Input.self, #"{"pattern":"needle","filesOnly":true,"maxResults":1}"#)
        let filesOnlyOutput = try await GitGrepTool().run(filesOnly, context: context)
        #expect(filesOnlyOutput == "exit_code: 0\nstdout:\na:1-b.txt")
    }

    @Test func lsFilesLimitsStdoutLinesAndReportsTruncation() async throws {
        let repository = try await TemporaryRepository()
        defer { repository.remove() }
        for name in ["a.txt", "b.txt", "c.txt"] {
            try "x\n".write(to: repository.root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try await repository.git(["add", "--", "a.txt", "b.txt", "c.txt"])
        let context = makeContext(workingDirectory: repository.root)

        let limited = try decode(GitLsFilesTool.Input.self, #"{"maxResults":2}"#)
        let output = try await GitLsFilesTool().run(limited, context: context)
        #expect(output.hasPrefix("exit_code: 0\nstdout:\na.txt\nb.txt\n"))
        #expect(output.contains("[output truncated to the first 2 of 4 lines"))

        let complete = try decode(GitLsFilesTool.Input.self, #"{"maxResults":10}"#)
        let completeOutput = try await GitLsFilesTool().run(complete, context: context)
        #expect(completeOutput == "exit_code: 0\nstdout:\na.txt\nb.txt\nc.txt\ntracked.txt")
    }
}

@Suite("GitTools rendering helpers")
struct GitToolsRenderingTests {
    @Test func limitedStdoutKeepsExitCodeAndStderr() {
        let result = FeatureProcessResult(
            exitCode: 128,
            stdoutData: Data("one\ntwo\nthree\n".utf8),
            stderrData: Data("fatal: boom\n".utf8),
            timedOut: false,
            stdoutWasTruncated: false
        )
        let rendered = GitToolsSupport.renderLimitedStdout(result, maxLines: 1)
        #expect(rendered.hasPrefix("exit_code: 128\nstdout:\none\n[output truncated to the first 1 of 3 lines"))
        #expect(rendered.hasSuffix("stderr:\nfatal: boom\n"))
    }

    @Test func limitedStdoutWithoutOutputRendersPlaceholder() {
        let result = FeatureProcessResult(
            exitCode: 0,
            stdoutData: Data(),
            stderrData: Data(),
            timedOut: false,
            stdoutWasTruncated: false
        )
        #expect(GitToolsSupport.renderLimitedStdout(result, maxLines: 5) == "exit_code: 0\n<no output>")
    }

    @Test func limitedGrepCountsMatchesOnlyAndDropsDanglingSeparator() {
        // `git grep -n -z --column -C 1` output: path "p:q-r" with `:` and `-`,
        // two groups; the second group's match is beyond the cap.
        let stdout = "p:q-r\u{0}1\u{0}x\np:q-r\u{0}2\u{0}5\u{0}m1\np:q-r\u{0}3\u{0}y\n--\np:q-r\u{0}8\u{0}z\np:q-r\u{0}9\u{0}1\u{0}m2\np:q-r\u{0}10\u{0}w\n"
        let result = FeatureProcessResult(
            exitCode: 0,
            stdoutData: Data(stdout.utf8),
            stderrData: Data(),
            timedOut: false,
            stdoutWasTruncated: false
        )
        #expect(GitToolsSupport.renderLimitedGrep(result, maxMatches: 1) == "exit_code: 0\nstdout:\np:q-r-1-x\np:q-r:2:m1\np:q-r-3-y\n[output truncated to the first 1 of 2 matches; raise maxResults or narrow the request]")
        #expect(GitToolsSupport.renderLimitedGrep(result, maxMatches: 2) == "exit_code: 0\nstdout:\np:q-r-1-x\np:q-r:2:m1\np:q-r-3-y\n--\np:q-r-8-z\np:q-r:9:m2\np:q-r-10-w")
    }
}
