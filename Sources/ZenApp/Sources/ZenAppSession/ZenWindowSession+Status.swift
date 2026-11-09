//
//  ZenWindowSession+Status.swift
//  ZenApp
//
//  The status bar of a window: the facts of the next turn and the git
//  summary of the workspace.
//

import Foundation
import ZenCODECore

extension ZenWindowSession {
    // MARK: - Status

    /// Reads the model, thinking level, agent, command context, and startup
    /// summary of the next turn from the controller the slot runs now.
    func refreshStatus() async {
        statusFactsAreStale = false
        statusFactsGeneration &+= 1
        let generation = statusFactsGeneration
        statusFactsReadCount += 1
        let facts = await ZenControllerFacts.read(in: sessionHost, slotID: slotID, hooks: hooks)
        guard !isClosed, generation == statusFactsGeneration, let facts else { return }
        var newStatus = status
        newStatus.modelID = facts.modelID
        newStatus.thinking = facts.thinking
        newStatus.agentName = facts.agentName
        if newStatus != status {
            status = newStatus
        }
        if startupSummary != facts.startupSummary {
            startupSummary = facts.startupSummary
        }
        if commandContext != facts.commandContext {
            commandContext = facts.commandContext
            commandDescriptors = ZenAppCommands.visibleDescriptors(in: facts.commandContext)
        }
    }

    /// A hook or a new incarnation changed what the status bar shows: read it
    /// again now when no line runs, otherwise when the line ends.
    func statusFactsDidChange() {
        guard !isClosed else { return }
        statusFactsAreStale = true
        if !isBusy, besideTasks.isEmpty {
            scheduleStatusRefresh()
        }
    }

    /// Reads the status facts in a task of their own until they are current.
    func scheduleStatusRefresh() {
        guard !isClosed, statusTask == nil else { return }
        statusTask = Task { [weak self] in
            while let self, self.statusFactsAreStale, !self.isClosed {
                await self.refreshStatus()
            }
            self?.statusTask = nil
        }
    }

    /// Reads the git summary of the workspace again, off the main actor; a
    /// refresh asked while one runs runs once more after it.
    public func refreshGitStatus() {
        guard !isClosed else { return }
        guard gitTask == nil else {
            gitRefreshPending = true
            return
        }
        let workspace = workspace
        gitTask = Task { [weak self] in
            let summary = await ZenGitStatus.summary(in: workspace)
            guard let self else { return }
            self.gitTask = nil
            guard !self.isClosed else { return }
            if self.status.gitStatus != summary {
                self.status.gitStatus = summary
            }
            if self.gitRefreshPending {
                self.gitRefreshPending = false
                self.refreshGitStatus()
            }
        }
    }
}
