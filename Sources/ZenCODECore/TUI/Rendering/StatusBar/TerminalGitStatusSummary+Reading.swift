//
//  TerminalGitStatusSummary+Reading.swift
//  ZenCODE
//
//  How the working-tree summary of the status bar is read, shared by the
//  terminal status bar and the macOS app: the same git commands, time limit,
//  and parsing.
//

import Foundation

extension TerminalGitStatusSummary {
    /// The time limit of each git command of the summary.
    public static let defaultTimeout: TimeInterval = 2

    /// The summary of `workingDirectory`, read off the caller's actor with
    /// `git diff --numstat HEAD --` and `git status --porcelain=v1
    /// --untracked-files=all`: changed files (tracked changes against `HEAD`
    /// plus untracked files) with added and deleted lines. `nil` outside a git
    /// repository, without git, or when the diff fails or times out
    /// (`timeout` seconds per command); a failed status counts no untracked
    /// file.
    @concurrent
    public static func read(
        in workingDirectory: URL,
        timeout: TimeInterval = defaultTimeout
    ) async -> TerminalGitStatusSummary? {
        #if canImport(Darwin) || canImport(Glibc)
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
        #else
        _ = workingDirectory
        _ = timeout
        return nil
        #endif
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
}
