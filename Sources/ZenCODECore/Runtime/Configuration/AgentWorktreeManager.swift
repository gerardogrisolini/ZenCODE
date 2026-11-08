//
//  AgentWorktreeManager.swift
//  ZenCODE
//
//  Git worktrees requested with `--worktree NAME`: created (or reused) in the
//  support directory before the arguments are parsed, and merged, kept or
//  discarded when the session closes.
//

import Foundation
import ToolCore

/// A failure of ``AgentWorktreeManager``.
public enum AgentWorktreeError: LocalizedError, Sendable, Equatable {
    /// The launch directory is not inside a Git repository.
    case notInRepository(path: String)
    /// The worktree destination exists but is not that worktree of the
    /// repository.
    case destinationInUse(name: String, path: String)
    /// The directory is the main working tree of its repository, not a linked
    /// worktree.
    case notALinkedWorktree(path: String)
    /// A Git command failed; the message is Git's own.
    case gitFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .notInRepository(path):
            return "--worktree requires a Git repository: \(path) is not inside one"
        case let .destinationInUse(name, path):
            return "Cannot use the worktree \(name): \(path) exists but is not a worktree of this repository."
        case let .notALinkedWorktree(path):
            return "\(path) is the main working tree of its repository, not a worktree."
        case let .gitFailed(message):
            return message
        }
    }
}

/// Creates, inspects and closes the Git worktrees requested with
/// `--worktree NAME`.
///
/// A worktree lives in
/// `<support>/worktrees/<project key>/<NAME>/<repository folder name>`: the
/// leaf keeps the repository folder name, so the name-based
/// ``ProjectStorageKey`` of the worktree is the one of the repository and the
/// project memory, sessions, task graphs and project agents stay shared. The
/// branch of the worktree is also named `NAME`.
///
/// Every Git command runs with a 60-second time limit. Commits use the user's
/// own Git identity.
public enum AgentWorktreeManager {
    /// What the repository looks like when a worktree session closes.
    public struct Inspection: Sendable {
        /// The main working tree of the repository.
        public let mainRoot: URL
        /// The branch checked out in the main working tree (`HEAD` when
        /// detached).
        public let mainBranch: String
        /// Whether the worktree has changes that are not committed yet.
        public let hasUncommittedChanges: Bool

        public init(mainRoot: URL, mainBranch: String, hasUncommittedChanges: Bool) {
            self.mainRoot = mainRoot
            self.mainBranch = mainBranch
            self.hasUncommittedChanges = hasUncommittedChanges
        }
    }

    /// How a worktree session is closed.
    public enum ClosingAction: Sendable, Hashable, CaseIterable {
        /// Commit any uncommitted change, merge the branch into the main
        /// branch, then remove the worktree and its branch.
        case merge
        /// Leave the worktree and its branch for a later session.
        case keep
        /// Remove the worktree and delete its branch, losing its changes.
        case discard
    }

    /// The result of a ``ClosingAction``: whether it fully succeeded and the
    /// lines to show the user.
    public struct ClosingOutcome: Sendable, Equatable {
        public let succeeded: Bool
        public let lines: [String]

        public init(succeeded: Bool, lines: [String]) {
            self.succeeded = succeeded
            self.lines = lines
        }
    }

    /// Time limit of every Git command, in seconds.
    static let gitTimeout: TimeInterval = 60

    /// Where the worktree `name` of the repository at `repositoryRoot` lives:
    /// `<support>/worktrees/<project key>/<name>/<repository folder name>`.
    public static func directory(
        name: String,
        repositoryRoot: URL,
        fileManager: FileManager = .default
    ) -> URL {
        let root = repositoryRoot.standardizedFileURL
        return AppStorageDirectory.appSupportDirectoryURL(fileManager: fileManager)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(ProjectStorageKey.key(for: root), isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
            .appendingPathComponent(root.lastPathComponent, isDirectory: true)
            .standardizedFileURL
    }

    /// Returns the directory of the worktree `name` of the repository that
    /// contains `launchDirectory`, creating it on first use.
    ///
    /// An existing worktree is reused. A new one checks out the branch `name`
    /// when it exists, otherwise a new branch `name` from the current `HEAD`;
    /// uncommitted changes of the repository are not carried over.
    public static func prepare(name: String, launchDirectory: URL) async throws -> URL {
        guard AgentConfiguration.isValidWorktreeName(name) else {
            throw AgentConfigurationError.invalidValue("--worktree", name)
        }
        guard let repositoryRoot = try await topLevelDirectory(of: launchDirectory) else {
            throw AgentWorktreeError.notInRepository(path: launchDirectory.path)
        }
        let destination = directory(name: name, repositoryRoot: repositoryRoot)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            guard try await isWorktree(destination, of: repositoryRoot) else {
                throw AgentWorktreeError.destinationInUse(name: name, path: destination.path)
            }
            return destination
        }

        let nameDirectory = destination.deletingLastPathComponent()
        try fileManager.createDirectory(at: nameDirectory, withIntermediateDirectories: true)
        do {
            try await requireGit(["worktree", "prune"], in: repositoryRoot)
            let branch = try await runGit(
                ["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"],
                in: repositoryRoot
            )
            if succeeded(branch) {
                try await requireGit(["worktree", "add", destination.path, name], in: repositoryRoot)
            } else {
                try await requireGit(
                    ["worktree", "add", "-b", name, destination.path, "HEAD"],
                    in: repositoryRoot
                )
            }
        } catch {
            removeDirectoryIfEmpty(nameDirectory)
            throw error
        }
        return destination
    }

    /// Prepares the worktree requested by `arguments` (`arguments[0]` is the
    /// executable) and returns them with its directory appended as the last
    /// `--working-directory`, so it wins over any earlier one.
    ///
    /// The arguments are returned unchanged when they request no worktree
    /// (the last `--worktree NAME` wins; one without a value is left to the
    /// parser) or contain `--help`, `-h`, `--version` or `--doctor`. The
    /// worktree belongs to the repository of the launch directory.
    public static func rewritingArguments(
        _ arguments: [String],
        environment: [String: String]
    ) async throws -> [String] {
        let sanitized = ZenCODECommandLineArgumentSanitizer.sanitized(arguments)
        var name: String?
        var index = 1
        while index < sanitized.count {
            switch sanitized[index] {
            case "--help", "-h", "--version", "--doctor":
                return arguments
            case "--worktree" where index + 1 < sanitized.count:
                index += 1
                name = sanitized[index]
            default:
                break
            }
            index += 1
        }
        guard let name else {
            return arguments
        }
        guard AgentConfiguration.isValidWorktreeName(name) else {
            throw AgentConfigurationError.invalidValue("--worktree", name)
        }
        let launchDirectory = AgentConfiguration.launchWorkingDirectoryURL(
            arguments: sanitized,
            environment: environment
        )
        let worktreeDirectory = try await prepare(name: name, launchDirectory: launchDirectory)
        return arguments + ["--working-directory", worktreeDirectory.path]
    }

    /// Reads the main working tree and branch of the repository and whether
    /// `worktree` has uncommitted changes.
    public static func inspect(_ worktree: AgentWorktree) async throws -> Inspection {
        let list = try await requireGit(["worktree", "list", "--porcelain"], in: worktree.directory)
        let prefix = "worktree "
        guard let mainPath = list.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first(where: { $0.hasPrefix(prefix) })
            .map({ String($0.dropFirst(prefix.count)) }),
            !mainPath.isEmpty else {
            throw AgentWorktreeError.gitFailed("Git did not report the main working tree of \(worktree.directory.path).")
        }
        let mainRoot = URL(fileURLWithPath: mainPath, isDirectory: true).standardizedFileURL
        guard !sameFilePath(mainRoot, worktree.directory) else {
            throw AgentWorktreeError.notALinkedWorktree(path: worktree.directory.path)
        }
        let branch = try await requireGit(["rev-parse", "--abbrev-ref", "HEAD"], in: mainRoot)
        let status = try await requireGit(["status", "--porcelain"], in: worktree.directory)
        return Inspection(
            mainRoot: mainRoot,
            mainBranch: branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            hasUncommittedChanges: !status.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
        )
    }

    /// Closes the worktree session with `action`. Never throws: a failure is
    /// reported as `succeeded == false` with Git's message in `lines`, and the
    /// worktree is left in place.
    public static func perform(
        _ action: ClosingAction,
        worktree: AgentWorktree,
        inspection: Inspection
    ) async -> ClosingOutcome {
        switch action {
        case .merge:
            return await merge(worktree, inspection: inspection)
        case .keep:
            return ClosingOutcome(
                succeeded: true,
                lines: [
                    "Worktree \(worktree.name) kept at \(worktree.directory.path). Resume it with: zen --worktree \(worktree.name)"
                ]
            )
        case .discard:
            var lines: [String] = []
            let removed = await remove(
                worktree,
                mainRoot: inspection.mainRoot,
                branchDeletionFlag: "-D",
                reportsBranchDeletion: true,
                lines: &lines
            )
            return ClosingOutcome(succeeded: removed, lines: lines)
        }
    }

    // MARK: - Closing

    private static func merge(_ worktree: AgentWorktree, inspection: Inspection) async -> ClosingOutcome {
        let name = worktree.name
        let mainRoot = inspection.mainRoot
        do {
            if inspection.hasUncommittedChanges {
                try await requireGit(["add", "-A"], in: worktree.directory)
                try await requireGit(["commit", "-m", "zen: worktree \(name)"], in: worktree.directory)
            }
            let merge = try await runGit(["merge", "--no-edit", name], in: mainRoot)
            guard succeeded(merge) else {
                // Never leave the main repository in the middle of a merge.
                let mergeHead = try await runGit(["rev-parse", "-q", "--verify", "MERGE_HEAD"], in: mainRoot)
                if succeeded(mergeHead) {
                    _ = try await runGit(["merge", "--abort"], in: mainRoot)
                }
                return ClosingOutcome(
                    succeeded: false,
                    lines: messageLines(failureMessage(merge, arguments: ["merge"]))
                        + ["Merge manually: git -C \(mainRoot.path) merge \(name)"]
                )
            }
        } catch {
            return ClosingOutcome(succeeded: false, lines: messageLines(error.localizedDescription))
        }

        var lines = ["Merged \(name) into \(inspection.mainBranch)"]
        let removed = await remove(
            worktree,
            mainRoot: mainRoot,
            branchDeletionFlag: "-d",
            reportsBranchDeletion: false,
            lines: &lines
        )
        return ClosingOutcome(succeeded: removed, lines: lines)
    }

    /// Removes the worktree, deletes its branch and the then empty `<name>`
    /// folder, appending what was done (or Git's failure) to `lines`.
    private static func remove(
        _ worktree: AgentWorktree,
        mainRoot: URL,
        branchDeletionFlag: String,
        reportsBranchDeletion: Bool,
        lines: inout [String]
    ) async -> Bool {
        do {
            try await requireGit(["worktree", "remove", "--force", worktree.directory.path], in: mainRoot)
            lines.append("Removed worktree \(worktree.directory.path)")
            let nameDirectory = worktree.directory.deletingLastPathComponent()
            if nameDirectory.lastPathComponent == worktree.name {
                removeDirectoryIfEmpty(nameDirectory)
            }
            try await requireGit(["branch", branchDeletionFlag, worktree.name], in: mainRoot)
            if reportsBranchDeletion {
                lines.append("Deleted branch \(worktree.name)")
            }
            return true
        } catch {
            lines.append(contentsOf: messageLines(error.localizedDescription))
            return false
        }
    }

    // MARK: - Repository

    /// The top-level directory of the working tree containing `directory`,
    /// or `nil` when it is not inside one.
    private static func topLevelDirectory(of directory: URL) async throws -> URL? {
        let result = try await runGit(["rev-parse", "--show-toplevel"], in: directory)
        guard succeeded(result),
              let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
    }

    /// Whether `destination` is the top level of a working tree of the same
    /// repository as `repositoryRoot`. Project keys are name-based, so another
    /// repository with the same folder name maps to the same destination.
    private static func isWorktree(_ destination: URL, of repositoryRoot: URL) async throws -> Bool {
        guard let topLevel = try await topLevelDirectory(of: destination),
              sameFilePath(topLevel, destination),
              let worktreeCommonDirectory = try await commonDirectory(of: destination),
              let repositoryCommonDirectory = try await commonDirectory(of: repositoryRoot) else {
            return false
        }
        return sameFilePath(worktreeCommonDirectory, repositoryCommonDirectory)
    }

    /// The Git directory shared by every working tree of the repository.
    private static func commonDirectory(of directory: URL) async throws -> URL? {
        let result = try await runGit(["rev-parse", "--git-common-dir"], in: directory)
        guard succeeded(result),
              let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank else {
            return nil
        }
        // Older Git prints it relative to the directory the command ran in.
        return (path.hasPrefix("/")
            ? URL(fileURLWithPath: path, isDirectory: true)
            : directory.appendingPathComponent(path, isDirectory: true))
            .standardizedFileURL
    }

    private static func removeDirectoryIfEmpty(_ directory: URL) {
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path),
              contents.isEmpty else {
            return
        }
        try? fileManager.removeItem(at: directory)
    }

    private static func sameFilePath(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - Git

    private static func runGit(_ arguments: [String], in directory: URL) async throws -> AsyncProcessResult {
        #if os(macOS) || os(Linux)
        return try await AsyncProcessRunner.run(
            executableURL: GitExecutableResolver.executableURL(),
            arguments: ["-C", directory.path] + arguments,
            environment: DeveloperToolEnvironment.processEnvironment(),
            timeout: gitTimeout
        )
        #else
        _ = arguments
        _ = directory
        throw AsyncProcessRunnerError.unsupportedPlatform
        #endif
    }

    /// Runs Git and throws ``AgentWorktreeError/gitFailed(_:)`` with Git's
    /// message when it does not succeed.
    @discardableResult
    private static func requireGit(_ arguments: [String], in directory: URL) async throws -> AsyncProcessResult {
        let result = try await runGit(arguments, in: directory)
        guard succeeded(result) else {
            throw AgentWorktreeError.gitFailed(failureMessage(result, arguments: arguments))
        }
        return result
    }

    private static func succeeded(_ result: AsyncProcessResult) -> Bool {
        !result.timedOut && result.exitCode == 0
    }

    /// Git's stderr, trimmed; its stdout when stderr is empty (`git merge`
    /// reports conflicts there); else a generic line naming the subcommand.
    private static func failureMessage(_ result: AsyncProcessResult, arguments: [String]) -> String {
        let command = "git \(arguments.first ?? "")"
        if result.timedOut {
            return "\(command) timed out after \(Int(gitTimeout)) seconds."
        }
        if let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            return stderr
        }
        if let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlank {
            return stdout
        }
        return "\(command) exited with status \(result.exitCode)."
    }

    private static func messageLines(_ message: String) -> [String] {
        message
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
