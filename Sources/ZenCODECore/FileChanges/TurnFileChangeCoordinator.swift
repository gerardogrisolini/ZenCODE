//
//  TurnFileChangeCoordinator.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/06/26.
//

import Foundation
import ToolCore

public actor TurnFileChangeCoordinator {
    private let tracker: TurnFileChangeTracker
    private var latestSummary: TurnFileChangeSummary?
    private var didPublishSummary = false

    public init(workspacePath: String?) {
        tracker = TurnFileChangeTracker(workspacePath: workspacePath)
    }

    public init(baseDirectoryURL: URL) {
        tracker = TurnFileChangeTracker(baseDirectoryURL: baseDirectoryURL)
    }

    /// Captures the initial worktree baseline so end-of-turn reconciliation can
    /// attribute changes made by tools whose paths cannot be predicted (such as
    /// `local.exec`, sub-agents, and MCP tools). Call once at the start of a turn.
    public func prepareForTurn() async {
        await tracker.prepareInitialWorktreeBaselineIfNeeded()
    }

    public func captureBaselineIfNeeded(forAgentToolCall toolCall: DirectAgentToolCall) async {
        await tracker.captureBaselineIfNeeded(forAgentToolCall: toolCall)
    }

    @discardableResult
    public func publishSummaryIfNeeded(
        matching liveChanges: [OperationFileChange] = []
    ) async -> TurnFileChangeSummary? {
        guard !didPublishSummary else {
            return nil
        }

        didPublishSummary = true
        latestSummary = await tracker.makeSummary(matching: liveChanges)
        return latestSummary
    }

    func collectLiveSummary(matching changes: [OperationFileChange]) async -> TurnFileChangeSummary? {
        guard !didPublishSummary else { return nil }
        return await tracker.collectLiveSummary(matching: changes)
    }

    /// The net file changes of the turn so far, without side effects (see
    /// ``TurnFileChangeTracker/peekNetSummary()``); once the summary is
    /// published, the published summary.
    func peekNetSummary() async -> TurnFileChangeSummary? {
        guard !didPublishSummary else { return latestSummary }
        return await tracker.peekNetSummary()
    }

    func matchingLiveArtifactPaths() async -> Set<String> {
        await tracker.matchingLiveArtifactPaths
    }

    /// The Git processes the tracker launched, as an internal test seam.
    func gitInvocationCount() async -> Int {
        await tracker.gitInvocationCount
    }
}

public enum TurnFileChangeUndoError: LocalizedError, Sendable, Equatable {
    case noTrackedFileChanges
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .noTrackedFileChanges:
            return "No tracked file changes to undo."
        case .unavailable:
            return "Undo is not available for the latest file changes."
        }
    }
}
