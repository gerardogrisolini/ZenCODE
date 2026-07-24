//
//  TerminalChat+GitStatus.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Dispatch
import Foundation

extension TerminalChat {
    func refreshStatusBarGitStatusSummaryForFileMutation() async {
        didRefreshGitStatusDuringCurrentPrompt = true
        await refreshStatusBarGitStatusSummary()
    }

    /// Refreshes the statusbar git summary when a delegated sub-agent reaches a
    /// terminal state, so files modified by the sub-agent become visible without
    /// waiting for a coordinator-side file-mutation tool call. Each completion
    /// is keyed by agent ID, status, and output revision and triggers exactly
    /// one refresh; unchanged snapshots add no work to the render path.
    func refreshStatusBarGitStatusSummaryForCompletedSubAgents(
        _ snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) async {
        var didObserveNewCompletion = false
        for snapshot in snapshots where !snapshot.pending {
            let isTerminal: Bool
            switch snapshot.status {
            case .idle:
                isTerminal = snapshot.latestOutput?.nilIfBlank != nil
            case .failed, .closed:
                isTerminal = true
            case .queued, .running:
                isTerminal = false
            }
            guard isTerminal else {
                continue
            }
            let key = "\(snapshot.id)#\(snapshot.status.rawValue)#\(snapshot.latestOutputRevision)"
            if recordSubAgentCompletionKey(key) {
                didObserveNewCompletion = true
            }
        }
        guard didObserveNewCompletion else {
            return
        }
        await refreshStatusBarGitStatusSummaryForFileMutation()
    }

    func refreshStatusBarGitStatusSummaryAfterPromptIfNeeded() async {
        guard !didRefreshGitStatusDuringCurrentPrompt else {
            return
        }
        await refreshStatusBarGitStatusSummary()
    }

    func refreshStatusBarGitStatusSummary() async {
        let workingDirectory = configuration.workingDirectory
        let statusBar = statusBar
        let refreshGeneration = await statusBar.beginGitStatusRefresh()
        Task {
            let summary = await Self.gitStatusSummary(in: workingDirectory)
            _ = await statusBar.update(
                gitStatusSummary: summary,
                refreshGeneration: refreshGeneration
            )
        }
    }

    static func gitStatusSummary(in workingDirectory: URL) async -> TerminalGitStatusSummary? {
        #if canImport(Darwin) || canImport(Glibc)
        do {
            let diffResult = try await AsyncProcessRunner.run(
                executableURL: GitExecutableResolver.executableURL(),
                arguments: ["diff", "--numstat", "HEAD", "--"],
                workingDirectory: workingDirectory,
                timeout: 2,
                stdoutLineLimit: 10_000
            )
            guard diffResult.exitCode == 0, !diffResult.timedOut else {
                return nil
            }

                let diffSummary = Self.gitNumstatSummary(from: diffResult.stdout)
            let untrackedFileCount = await Self.gitUntrackedFileCount(in: workingDirectory) ?? 0
            return TerminalGitStatusSummary(
                changedFileCount: diffSummary.changedFileCount + untrackedFileCount,
                additions: diffSummary.additions,
                deletions: diffSummary.deletions
            )
        } catch {
            return nil
        }
        #else
        _ = workingDirectory
        return nil
        #endif
    }

    static func gitNumstatSummary(from output: String) -> TerminalGitStatusSummary {
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

    static func gitUntrackedFileCount(in workingDirectory: URL) async -> Int? {
        do {
            let result = try await AsyncProcessRunner.run(
                executableURL: GitExecutableResolver.executableURL(),
                arguments: ["status", "--porcelain=v1", "--untracked-files=all"],
                workingDirectory: workingDirectory,
                timeout: 2,
                stdoutLineLimit: 10_000
            )
            guard result.exitCode == 0, !result.timedOut else {
                return nil
            }
            return result.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .filter { $0.hasPrefix("?? ") }
                .count
        } catch {
            return nil
        }
    }
}
