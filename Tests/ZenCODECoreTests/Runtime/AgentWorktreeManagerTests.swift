//
//  AgentWorktreeManagerTests.swift
//  ZenCODE
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct AgentWorktreeManagerTests {
    @Test
    func prepareCreatesTheWorktreeAndItsBranchUnderTheProjectKey() async throws {
        try await withRepository { repository, support in
            // Uncommitted changes of the repository stay out of the worktree.
            try Data("dirty\n".utf8).write(to: repository.appendingPathComponent("file.txt"))

            let directory = try await AgentWorktreeManager.prepare(name: "feature", launchDirectory: repository)

            let expected = AgentWorktreeManager.directory(name: "feature", repositoryRoot: repository)
            #expect(sameFile(directory, expected))
            #expect(directory.lastPathComponent == repository.lastPathComponent)
            #expect(directory.deletingLastPathComponent().lastPathComponent == "feature")
            #expect(sameFile(
                directory,
                support.appendingPathComponent("worktrees")
                    .appendingPathComponent(ProjectStorageKey.key(for: repository))
                    .appendingPathComponent("feature")
                    .appendingPathComponent(repository.lastPathComponent)
            ))
            #expect(ProjectStorageKey.key(for: directory) == ProjectStorageKey.key(for: repository))
            #expect(try await git(["rev-parse", "--abbrev-ref", "HEAD"], in: directory) == "feature")
            #expect(try await gitSucceeds(["rev-parse", "--verify", "--quiet", "refs/heads/feature"], in: repository))
            #expect(try String(contentsOf: directory.appendingPathComponent("file.txt"), encoding: .utf8) == "initial\n")
        }
    }

    @Test
    func prepareReusesTheWorktreeAndRecreatesItFromAnExistingBranch() async throws {
        try await withRepository { repository, _ in
            let first = try await AgentWorktreeManager.prepare(name: "feature", launchDirectory: repository)
            try Data("work in progress\n".utf8).write(to: first.appendingPathComponent("notes.txt"))

            // A subdirectory of the repository resolves to the same worktree.
            let subdirectory = repository.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            let second = try await AgentWorktreeManager.prepare(name: "feature", launchDirectory: subdirectory)
            #expect(second == first)
            #expect(FileManager.default.fileExists(atPath: second.appendingPathComponent("notes.txt").path))
            #expect(try await worktreeCount(of: repository) == 2)

            // Once removed, the worktree is recreated from its existing branch.
            try await git(["add", "-A"], in: first)
            try await commit("notes", in: first)
            try await git(["worktree", "remove", "--force", first.path], in: repository)
            let recreated = try await AgentWorktreeManager.prepare(name: "feature", launchDirectory: repository)
            #expect(recreated == first)
            #expect(try await git(["log", "-1", "--format=%s"], in: recreated) == "notes")
            #expect(try await git(["rev-parse", "--abbrev-ref", "HEAD"], in: recreated) == "feature")
        }
    }

    @Test
    func prepareRefusesADestinationThatIsNotThatWorktree() async throws {
        try await withRepository { repository, _ in
            let occupied = AgentWorktreeManager.directory(name: "occupied", repositoryRoot: repository)
            try FileManager.default.createDirectory(at: occupied, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: occupied.appendingPathComponent("file.txt"))
            await #expect(throws: AgentWorktreeError.destinationInUse(name: "occupied", path: occupied.path)) {
                try await AgentWorktreeManager.prepare(name: "occupied", launchDirectory: repository)
            }

            // Another repository with the same folder name maps to the same
            // destination, but its worktree is not reused.
            let shared = try await AgentWorktreeManager.prepare(name: "shared", launchDirectory: repository)
            let other = try await makeRepository(
                at: repository.deletingLastPathComponent()
                    .appendingPathComponent("other", isDirectory: true)
                    .appendingPathComponent(repository.lastPathComponent, isDirectory: true)
            )
            await #expect(throws: AgentWorktreeError.destinationInUse(name: "shared", path: shared.path)) {
                try await AgentWorktreeManager.prepare(name: "shared", launchDirectory: other)
            }
        }
    }

    @Test
    func prepareReportsGitFailuresAndLeavesNoEmptyFolder() async throws {
        try await withRepository { repository, _ in
            // `main` is already checked out by the repository itself.
            let error = await #expect(throws: AgentWorktreeError.self) {
                try await AgentWorktreeManager.prepare(name: "main", launchDirectory: repository)
            }
            guard case let .gitFailed(message)? = error else {
                Issue.record("Expected a Git failure, got \(String(describing: error))")
                return
            }
            #expect(message.contains("main"))
            let destination = AgentWorktreeManager.directory(name: "main", repositoryRoot: repository)
            #expect(!FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
        }
    }

    @Test
    func prepareFailsOutsideARepositoryAndForAnInvalidName() async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let plain = base.appendingPathComponent("plain", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        await AppStorageDirectory.withSupportDirectoryURL(base.appendingPathComponent("support")) {
            await #expect(throws: AgentWorktreeError.notInRepository(path: plain.path)) {
                try await AgentWorktreeManager.prepare(name: "feature", launchDirectory: plain)
            }
            #expect(
                AgentWorktreeError.notInRepository(path: plain.path).localizedDescription
                    == "--worktree requires a Git repository: \(plain.path) is not inside one"
            )
            await #expect(throws: AgentConfigurationError.self) {
                try await AgentWorktreeManager.prepare(name: "a/b", launchDirectory: plain)
            }
            #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("support/worktrees").path))
        }
    }

    @Test
    func rewritingArgumentsAppendsTheWorktreeAsTheLastWorkingDirectory() async throws {
        try await withRepository { repository, _ in
            let expected = AgentWorktreeManager.directory(name: "feature", repositoryRoot: repository)
            for arguments in [
                ["zen", "--worktree", "feature", "--help"],
                ["zen", "-h", "--worktree", "feature"],
                ["zen", "--version", "--worktree", "feature"],
                ["zen", "--doctor", "--worktree", "feature"],
                ["zen", "--working-directory", repository.path],
                ["zen", "--worktree"]
            ] {
                let rewritten = try await AgentWorktreeManager.rewritingArguments(arguments, environment: [:])
                #expect(rewritten == arguments)
            }
            #expect(!FileManager.default.fileExists(atPath: expected.path))
            let invalid = await #expect(throws: AgentConfigurationError.self) {
                try await AgentWorktreeManager.rewritingArguments(["zen", "--worktree", "a b"], environment: [:])
            }
            #expect(invalid?.localizedDescription == "Invalid value for --worktree: a b")

            let arguments = [
                "zen", "--working-directory", repository.path, "--worktree", "first", "--worktree", "feature"
            ]
            let rewritten = try await AgentWorktreeManager.rewritingArguments(arguments, environment: [:])
            #expect(rewritten.count == arguments.count + 2)
            #expect(Array(rewritten.prefix(arguments.count)) == arguments)
            #expect(rewritten[arguments.count] == "--working-directory")
            #expect(sameFile(URL(fileURLWithPath: rewritten[arguments.count + 1]), expected))
            #expect(!FileManager.default.fileExists(
                atPath: AgentWorktreeManager.directory(name: "first", repositoryRoot: repository).path
            ))

            let configuration = try AgentConfiguration.withoutPersistedConfiguration(arguments: rewritten)
            #expect(configuration.worktree?.name == "feature")
            #expect(sameFile(configuration.workingDirectory, expected))
            #expect(configuration.worktree?.directory == configuration.workingDirectory)
        }
    }

    @Test
    func inspectReportsTheMainBranchAndRejectsTheMainWorkingTree() async throws {
        try await withRepository { repository, _ in
            let directory = try await AgentWorktreeManager.prepare(name: "feature", launchDirectory: repository)
            let worktree = AgentWorktree(name: "feature", directory: directory)

            let clean = try await AgentWorktreeManager.inspect(worktree)
            #expect(sameFile(clean.mainRoot, repository))
            #expect(clean.mainBranch == "main")
            #expect(!clean.hasUncommittedChanges)

            try Data("untracked\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
            #expect(try await AgentWorktreeManager.inspect(worktree).hasUncommittedChanges)

            await #expect(throws: AgentWorktreeError.notALinkedWorktree(path: repository.path)) {
                try await AgentWorktreeManager.inspect(AgentWorktree(name: "feature", directory: repository))
            }
        }
    }

    @Test
    func mergingADirtyWorktreeCommitsMergesAndRemovesIt() async throws {
        try await withRepository { repository, _ in
            let directory = try await AgentWorktreeManager.prepare(name: "feature", launchDirectory: repository)
            try Data("changed\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
            try Data("added\n".utf8).write(to: directory.appendingPathComponent("added.txt"))
            let worktree = AgentWorktree(name: "feature", directory: directory)
            let inspection = try await AgentWorktreeManager.inspect(worktree)
            #expect(inspection.hasUncommittedChanges)

            let outcome = await AgentWorktreeManager.perform(.merge, worktree: worktree, inspection: inspection)

            #expect(outcome == AgentWorktreeManager.ClosingOutcome(
                succeeded: true,
                lines: ["Merged feature into main", "Removed worktree \(directory.path)"]
            ))
            #expect(try String(contentsOf: repository.appendingPathComponent("file.txt"), encoding: .utf8) == "changed\n")
            #expect(FileManager.default.fileExists(atPath: repository.appendingPathComponent("added.txt").path))
            #expect(try await git(["log", "-1", "--format=%s"], in: repository) == "zen: worktree feature")
            #expect(try await git(["rev-parse", "--abbrev-ref", "HEAD"], in: repository) == "main")
            #expect(try await !gitSucceeds(["rev-parse", "--verify", "--quiet", "refs/heads/feature"], in: repository))
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path))
            #expect(try await worktreeCount(of: repository) == 1)
        }
    }

    @Test
    func aConflictingMergeKeepsTheWorktreeAndLeavesNoMergeInProgress() async throws {
        try await withRepository { repository, _ in
            let directory = try await AgentWorktreeManager.prepare(name: "feature", launchDirectory: repository)
            try Data("worktree\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
            try await git(["add", "-A"], in: directory)
            try await commit("worktree change", in: directory)
            try Data("main\n".utf8).write(to: repository.appendingPathComponent("file.txt"))
            try await git(["add", "-A"], in: repository)
            try await commit("main change", in: repository)
            let mainHead = try await git(["rev-parse", "HEAD"], in: repository)
            let worktree = AgentWorktree(name: "feature", directory: directory)
            let inspection = try await AgentWorktreeManager.inspect(worktree)

            let outcome = await AgentWorktreeManager.perform(.merge, worktree: worktree, inspection: inspection)

            #expect(!outcome.succeeded)
            #expect(outcome.lines.count >= 2)
            #expect(outcome.lines.last == "Merge manually: git -C \(inspection.mainRoot.path) merge feature")
            #expect(outcome.lines.contains { $0.contains("CONFLICT") || $0.contains("conflict") })
            #expect(try await !gitSucceeds(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: repository))
            #expect(try await git(["status", "--porcelain"], in: repository).isEmpty)
            #expect(try await git(["rev-parse", "HEAD"], in: repository) == mainHead)
            #expect(try String(contentsOf: repository.appendingPathComponent("file.txt"), encoding: .utf8) == "main\n")
            #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("file.txt").path))
            #expect(try await gitSucceeds(["rev-parse", "--verify", "--quiet", "refs/heads/feature"], in: repository))
            #expect(try await worktreeCount(of: repository) == 2)
        }
    }

    @Test
    func discardRemovesTheWorktreeTheBranchAndTheFolder() async throws {
        try await withRepository { repository, _ in
            let directory = try await AgentWorktreeManager.prepare(name: "feature", launchDirectory: repository)
            try Data("committed\n".utf8).write(to: directory.appendingPathComponent("file.txt"))
            try await git(["add", "-A"], in: directory)
            try await commit("unmerged", in: directory)
            try Data("uncommitted\n".utf8).write(to: directory.appendingPathComponent("new.txt"))
            let worktree = AgentWorktree(name: "feature", directory: directory)
            let inspection = try await AgentWorktreeManager.inspect(worktree)

            let outcome = await AgentWorktreeManager.perform(.discard, worktree: worktree, inspection: inspection)

            #expect(outcome == AgentWorktreeManager.ClosingOutcome(
                succeeded: true,
                lines: ["Removed worktree \(directory.path)", "Deleted branch feature"]
            ))
            #expect(!FileManager.default.fileExists(atPath: directory.path))
            #expect(!FileManager.default.fileExists(atPath: directory.deletingLastPathComponent().path))
            #expect(try await !gitSucceeds(["rev-parse", "--verify", "--quiet", "refs/heads/feature"], in: repository))
            #expect(try await worktreeCount(of: repository) == 1)
            #expect(try String(contentsOf: repository.appendingPathComponent("file.txt"), encoding: .utf8) == "initial\n")
        }
    }

    @Test
    func keepLeavesTheWorktreeAndExplainsHowToResumeIt() async throws {
        try await withRepository { repository, _ in
            let directory = try await AgentWorktreeManager.prepare(name: "feature", launchDirectory: repository)
            let worktree = AgentWorktree(name: "feature", directory: directory)
            let inspection = try await AgentWorktreeManager.inspect(worktree)

            let outcome = await AgentWorktreeManager.perform(.keep, worktree: worktree, inspection: inspection)

            #expect(outcome == AgentWorktreeManager.ClosingOutcome(
                succeeded: true,
                lines: ["Worktree feature kept at \(directory.path). Resume it with: zen --worktree feature"]
            ))
            #expect(FileManager.default.fileExists(atPath: directory.path))
            #expect(try await gitSucceeds(["rev-parse", "--verify", "--quiet", "refs/heads/feature"], in: repository))
        }
    }

    // MARK: - Support

    /// Runs `body` with a fresh Git repository named `app` on branch `main`
    /// and an isolated support directory, both removed afterwards.
    private func withRepository(
        _ body: (_ repository: URL, _ support: URL) async throws -> Void
    ) async throws {
        let base = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: base) }
        let repository = try await makeRepository(at: base.appendingPathComponent("app", isDirectory: true))
        let support = base.appendingPathComponent("support", isDirectory: true)
        try await AppStorageDirectory.withSupportDirectoryURL(support) {
            try await body(repository, support)
        }
    }

    /// A repository with one commit of `file.txt` on `main`. The identity is
    /// in its local configuration, shared by its worktrees, so the code under
    /// test commits without identity flags.
    private func makeRepository(at repository: URL) async throws -> URL {
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try await git(["init", "--quiet"], in: repository)
        try await git(["symbolic-ref", "HEAD", "refs/heads/main"], in: repository)
        try await git(["config", "user.name", "ZenCODE Tests"], in: repository)
        try await git(["config", "user.email", "tests@example.com"], in: repository)
        try await git(["config", "commit.gpgsign", "false"], in: repository)
        try Data("initial\n".utf8).write(to: repository.appendingPathComponent("file.txt"))
        try await git(["add", "file.txt"], in: repository)
        try await commit("initial", in: repository)
        return repository
    }

    private func commit(_ message: String, in directory: URL) async throws {
        try await git(
            ["-c", "user.name=ZenCODE Tests", "-c", "user.email=tests@example.com", "commit", "--quiet", "-m", message],
            in: directory
        )
    }

    private func worktreeCount(of repository: URL) async throws -> Int {
        try await git(["worktree", "list", "--porcelain"], in: repository)
            .split(separator: "\n")
            .filter { $0.hasPrefix("worktree ") }
            .count
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) async throws -> String {
        let result = try await runGit(arguments, in: directory)
        try #require(result.exitCode == 0, "git \(arguments.joined(separator: " ")): \(result.stderr)")
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func gitSucceeds(_ arguments: [String], in directory: URL) async throws -> Bool {
        try await runGit(arguments, in: directory).exitCode == 0
    }

    private func runGit(_ arguments: [String], in directory: URL) async throws -> AsyncProcessResult {
        try await AsyncProcessRunner.run(
            executableURL: GitExecutableResolver.executableURL(),
            arguments: ["-C", directory.path] + arguments,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: 60
        )
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-worktree-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
