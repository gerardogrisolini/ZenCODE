//
//  TurnFileChangeCoordinator.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 01/06/26.
//

import Foundation

public actor TurnFileChangeCoordinator {
    private let tracker: TurnFileChangeTracker
    private let baseDirectoryURL: URL
    private var latestSummary: TurnFileChangeSummary?
    private var didPublishSummary = false

    public init(workspacePath: String?) {
        let tracker = TurnFileChangeTracker(workspacePath: workspacePath)
        self.tracker = tracker
        self.baseDirectoryURL = tracker.baseDirectoryURL
    }

    public init(baseDirectoryURL: URL) {
        let tracker = TurnFileChangeTracker(baseDirectoryURL: baseDirectoryURL)
        self.tracker = tracker
        self.baseDirectoryURL = tracker.baseDirectoryURL
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
    public func publishSummaryIfNeeded() async -> TurnFileChangeSummary? {
        guard !didPublishSummary else {
            return nil
        }

        didPublishSummary = true
        latestSummary = await tracker.makeSummary()
        return latestSummary
    }

    public func latestFileChangeSummary() -> TurnFileChangeSummary? {
        latestSummary
    }

    public func replaceLatestSummary(_ summary: TurnFileChangeSummary?) {
        latestSummary = summary
        didPublishSummary = true
    }

    public func clearLatestSummary() {
        latestSummary = nil
    }

    @discardableResult
    public func undoLatestChanges() async throws -> TurnFileChangeSummary {
        // Reserve synchronously before the first suspension. Without clearing
        // the snapshot here, two actor calls can both read `latestSummary`,
        // suspend in the undo service and apply the same undo twice.
        guard let summary = latestSummary else {
            throw TurnFileChangeUndoError.noTrackedFileChanges
        }
        latestSummary = nil
        do {
            return try await TurnFileChangeUndoService.undoLatest(
                summary: summary,
                baseDirectoryURL: baseDirectoryURL
            )
        } catch {
            // Restore only when no newer summary was published while undo was
            // suspended; a newer turn always wins over the failed reservation.
            if latestSummary == nil {
                latestSummary = summary
            }
            throw error
        }
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
