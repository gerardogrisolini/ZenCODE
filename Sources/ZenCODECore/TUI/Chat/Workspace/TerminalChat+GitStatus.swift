//
//  TerminalChat+GitStatus.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore
import ZenCODERuntime

extension TerminalChat {
    func refreshStatusBarGitStatusSummaryForFileMutation() async {
        didRefreshGitStatusDuringCurrentPrompt = true
        await refreshStatusBarGitStatusSummary()
    }

    nonisolated static func shouldRefreshGitStatus(
        for event: DirectSubAgentToolEvent
    ) -> Bool {
        guard case .completed = event.lifecycle else {
            return false
        }
        return ToolMutationClassifier.isFileMutationTool(event.toolCall.name)
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
            case .standby:
                isTerminal = snapshot.latestOutput?.nilIfBlank != nil
            case .failed, .closed:
                isTerminal = true
            case .queued, .running:
                // `.closing` is pending work, not a completion boundary.
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
        Task(name: "ZenCODE.TUI.git-status-refresh") {
            let summary = await TerminalGitStatusSummary.read(in: workingDirectory)
            _ = await statusBar.update(
                gitStatusSummary: summary,
                refreshGeneration: refreshGeneration
            )
        }
    }
}
