//
//  ZenGitStatus.swift
//  ZenApp
//
//  The git summary of the status bar, ported from the terminal
//  (`TerminalChat+GitStatus.swift`): the same commands and the same parsing.
//

import Foundation
import ZenCODECore

/// The working-tree summary the status bar shows: changed files (tracked
/// changes against `HEAD` plus untracked files) with added and deleted lines.
public enum ZenGitStatus {
    /// The time limit of each git command of the status bar: the terminal's.
    public static let defaultTimeout: TimeInterval = 2
    /// The summary of `workingDirectory`, read off the caller's actor with
    /// `git diff --numstat HEAD --` and `git status --porcelain=v1
    /// --untracked-files=all`; `nil` outside a git repository, without git,
    /// or when the diff fails or times out (`timeout` seconds per command,
    /// ``defaultTimeout`` by default).
    @concurrent
    public static func summary(
        in workingDirectory: URL,
        timeout: TimeInterval = defaultTimeout
    ) async -> TerminalGitStatusSummary? {
        do {
            let diff = try await AsyncProcessRunner.run(
                executableURL: GitExecutableResolver.executableURL(),
                arguments: ["diff", "--numstat", "HEAD", "--"],
                workingDirectory: workingDirectory,
                timeout: timeout,
                stdoutLineLimit: 10_000
            )
            guard diff.exitCode == 0, !diff.timedOut else {
                return nil
            }
            let diffSummary = numstatSummary(from: diff.stdout)
            let untracked = await untrackedFileCount(in: workingDirectory, timeout: timeout) ?? 0
            return TerminalGitStatusSummary(
                changedFileCount: diffSummary.changedFileCount + untracked,
                additions: diffSummary.additions,
                deletions: diffSummary.deletions
            )
        } catch {
            return nil
        }
    }

    /// Parses `git diff --numstat` output: one changed file per line with at
    /// least three tab-separated fields; a binary file (`-`) counts as a
    /// changed file with no lines.
    public static func numstatSummary(from output: String) -> TerminalGitStatusSummary {
        var changedFileCount = 0
        var additions = 0
        var deletions = 0
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count >= 3 else {
                continue
            }
            changedFileCount += 1
            additions += Int(fields[0]) ?? 0
            deletions += Int(fields[1]) ?? 0
        }
        return TerminalGitStatusSummary(
            changedFileCount: changedFileCount,
            additions: additions,
            deletions: deletions
        )
    }

    /// Counts the untracked files (`?? ` lines) of `git status --porcelain=v1`.
    public static func untrackedFileCount(fromPorcelain output: String) -> Int {
        output
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.hasPrefix("?? ") }
            .count
    }

    @concurrent
    private static func untrackedFileCount(in workingDirectory: URL, timeout: TimeInterval) async -> Int? {
        do {
            let result = try await AsyncProcessRunner.run(
                executableURL: GitExecutableResolver.executableURL(),
                arguments: ["status", "--porcelain=v1", "--untracked-files=all"],
                workingDirectory: workingDirectory,
                timeout: timeout,
                stdoutLineLimit: 10_000
            )
            guard result.exitCode == 0, !result.timedOut else {
                return nil
            }
            return untrackedFileCount(fromPorcelain: result.stdout)
        } catch {
            return nil
        }
    }

    /// The file-mutation tools after which the terminal refreshes the
    /// summary (`ToolMutationClassifier.isFileMutationTool`).
    public static func isFileMutationTool(_ toolName: String) -> Bool {
        switch toolName.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "local.writeFile", "local.append", "local.replace",
             "local.editFile", "local.multiEdit", "local.applyPatch",
             "local.delete", "local.move", "local.mkdir":
            true
        default:
            false
        }
    }
}
