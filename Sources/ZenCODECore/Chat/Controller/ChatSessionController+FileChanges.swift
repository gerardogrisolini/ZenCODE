//
//  ChatSessionController+FileChanges.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// One turn of live file-artifact recording.
///
/// Publications are chained so artifacts are presented in completion order,
/// and the turn stops accepting new ones once its summary is being sealed.
@ChatSessionActor
final class ChatFileArtifactTurn {
    let id: UUID
    let sessionID: String
    let history: SessionFileArtifactHistory
    let coordinator: TurnFileChangeCoordinator?
    /// Presents this turn's artifacts.
    let presenter: any ChatSessionPresenter
    var pendingPublication: Task<Void, Never>?
    var acceptsPublications = true

    init(
        id: UUID,
        sessionID: String,
        history: SessionFileArtifactHistory,
        coordinator: TurnFileChangeCoordinator?,
        presenter: any ChatSessionPresenter
    ) {
        self.id = id
        self.sessionID = sessionID
        self.history = history
        self.coordinator = coordinator
        self.presenter = presenter
    }
}

/// The file artifacts of a session as `/artifacts` lists them: the finished
/// turns and, while a turn runs, the net changes of that turn so far.
public struct ChatFileArtifactSnapshot: Sendable, Equatable {
    /// Finished turns, oldest first, then the turn in progress when it changed files.
    public let turns: [SessionFileArtifactHistory.Turn]
    /// The number of the turn in progress within `turns`, when present.
    public let activeTurnNumber: UInt64?

    public init(turns: [SessionFileArtifactHistory.Turn], activeTurnNumber: UInt64?) {
        self.turns = turns
        self.activeTurnNumber = activeTurnNumber
    }
}

extension ChatSessionController {
    func beginFileArtifactTurn(
        coordinator: TurnFileChangeCoordinator? = nil,
        presenter: (any ChatSessionPresenter)? = nil
    ) async -> ChatFileArtifactTurn? {
        let observedSessionID = sessionID
        let history = fileArtifactHistory
        guard let id = await history.beginTurn(sessionID: observedSessionID),
              sessionID == observedSessionID, fileArtifactHistory === history else { return nil }
        let context = ChatFileArtifactTurn(
            id: id,
            sessionID: observedSessionID,
            history: history,
            coordinator: coordinator,
            presenter: presenter ?? effectivePresenter(for: nil)
        )
        activeFileArtifactTurn = context
        return context
    }

    /// `true` while `context` is the session's recording turn.
    func isActiveFileArtifactTurn(_ context: ChatFileArtifactTurn) -> Bool {
        sessionID == context.sessionID
            && fileArtifactHistory === context.history
            && activeFileArtifactTurn?.id == context.id
    }

    /// The file artifacts of the session as `/artifacts` lists them, safe to
    /// read while the model is working: the finished turns, then the turn in
    /// progress when it changed files. That turn shows its net changes so far
    /// against the start of the turn, read without reconciling or
    /// checkpointing it (see ``TurnFileChangeCoordinator/peekNetSummary()``),
    /// with the mapping of a finished turn. A turn that finishes while this
    /// reads is listed once, as finished. A session change while this reads
    /// answers an empty snapshot, so nothing of the previous session is listed.
    public func fileArtifactSnapshot() async -> ChatFileArtifactSnapshot {
        let observedSessionID = sessionID
        let history = fileArtifactHistory
        let stale = ChatFileArtifactSnapshot(turns: [], activeTurnNumber: nil)
        var active: SessionFileArtifactHistory.Turn?
        if let context = activeFileArtifactTurn, isActiveFileArtifactTurn(context),
           let coordinator = context.coordinator {
            let summary = await coordinator.peekNetSummary()
            guard sessionID == observedSessionID, fileArtifactHistory === history else { return stale }
            if let summary {
                let number = await history.pendingTurnNumber(context.id)
                guard sessionID == observedSessionID, fileArtifactHistory === history else { return stale }
                let artifacts = FileChangeArtifactMapper.artifacts(from: summary, workingDirectory: workingDirectory)
                if let number, !artifacts.isEmpty {
                    active = SessionFileArtifactHistory.Turn(number: number, artifacts: artifacts)
                }
            }
        }
        // Read last: a turn finished meanwhile wins over its view in progress.
        var turns = await history.snapshot()
        guard sessionID == observedSessionID, fileArtifactHistory === history else { return stale }
        guard let active, !turns.contains(where: { $0.number == active.number }) else {
            return ChatFileArtifactSnapshot(turns: turns, activeTurnNumber: nil)
        }
        turns.append(active)
        return ChatFileArtifactSnapshot(turns: turns, activeTurnNumber: active.number)
    }

    /// Records and presents the file changes of a completed tool call, then
    /// a workspace checkpoint of the turn. `toolName` names the completed
    /// tool: a core tool that only reads and reports no file change takes no
    /// checkpoint (see ``TurnFileChangeLiveCheckpointPolicy``); `nil` takes it.
    func publishLiveFileArtifacts(
        _ result: DirectAgentToolResult,
        callID: String,
        toolName: String? = nil,
        agentID: String? = nil,
        context: ChatFileArtifactTurn?
    ) async {
        guard let context, context.acceptsPublications, isActiveFileArtifactTurn(context) else {
            return
        }
        guard !TurnFileChangeLiveCheckpointPolicy.skipsCheckpoint(
            toolName: toolName, fileChanges: result.fileChanges
        ) else {
            // Nothing to record or present; still return after the earlier ones.
            await context.pendingPublication?.value
            return
        }
        let previous = context.pendingPublication
        let publication = Task(name: "ZenCODE.Chat.live-artifact-publication") { @ChatSessionActor [weak self] in
            await previous?.value
            await self?.publishCompletedFileArtifacts(
                result,
                callID: callID,
                agentID: agentID,
                context: context
            )
        }
        context.pendingPublication = publication
        await publication.value
    }

    private func publishCompletedFileArtifacts(
        _ result: DirectAgentToolResult,
        callID: String,
        agentID: String?,
        context: ChatFileArtifactTurn
    ) async {
        guard isActiveFileArtifactTurn(context) else { return }
        var turns: [SessionFileArtifactHistory.Turn] = []
        if let turn = await context.history.recordLive(
            result.fileChanges, agentID: agentID, callID: callID,
            turnID: context.id, workingDirectory: workingDirectory
        ) { turns.append(turn) }
        if let summary = await context.coordinator?.collectLiveSummary(matching: result.fileChanges),
           let turn = await context.history.recordLiveSummary(
               summary, turnID: context.id, workingDirectory: workingDirectory
           ) {
            // Present each file once per completion: the workspace checkpoint
            // replaces this completion's direct artifact for the same path,
            // even when their diffs differ. Both recordings stay intact.
            let checkpointPaths = Set(turn.artifacts.map(\.absolutePath))
            turns = turns.compactMap { liveTurn in
                let artifacts = liveTurn.artifacts.filter { !checkpointPaths.contains($0.absolutePath) }
                return artifacts.isEmpty ? nil : .init(number: liveTurn.number, artifacts: artifacts)
            }
            turns.append(turn)
        }
        guard sessionID == context.sessionID, fileArtifactHistory === context.history else { return }
        guard !turns.isEmpty else { return }
        await context.presenter.presentLiveFileArtifacts(turns, agentID: agentID)
    }

    /// Replacing the actor also fences restores that reuse the same session ID.
    func resetFileArtifactState() {
        lastFileChangeSummary = nil
        activeFileArtifactTurn = nil
        fileArtifactHistory = SessionFileArtifactHistory(sessionID: sessionID)
    }

    /// Seals the turn's live artifacts, reconciles the worktree, and records
    /// the turn's file-change summary. Artifacts that were not presented live
    /// are presented once, as one sealed turn.
    func collectFileChangeSummaryIfNeeded(
        from coordinator: TurnFileChangeCoordinator,
        sessionID expectedSessionID: String? = nil,
        history expectedHistory: SessionFileArtifactHistory? = nil,
        turnID: UUID? = nil,
        presenter turnPresenter: (any ChatSessionPresenter)? = nil
    ) async -> TurnFileChangeSummary? {
        let observedSessionID = expectedSessionID ?? sessionID
        let history = expectedHistory ?? fileArtifactHistory
        if let turnID, let context = activeFileArtifactTurn, context.id == turnID {
            context.acceptsPublications = false
            await context.pendingPublication?.value
            guard sessionID == observedSessionID, fileArtifactHistory === history else { return nil }
            activeFileArtifactTurn = nil
        }
        let liveChanges: [OperationFileChange]
        if let turnID {
            liveChanges = await history.sealTurn(turnID)
        } else {
            liveChanges = []
        }
        let summary = await coordinator.publishSummaryIfNeeded(matching: liveChanges)
        // A session switch may race the final reconciliation of an old turn.
        // Keep both the latest-summary slot and the runtime artifact history
        // fenced to the session that started the turn.
        guard sessionID == observedSessionID, fileArtifactHistory === history else {
            return nil
        }
        let unseen: SessionFileArtifactHistory.Turn?
        if let turnID {
            let matchingPaths = await coordinator.matchingLiveArtifactPaths()
            unseen = await history.finishTurn(
                turnID, summary: summary, matchingLivePaths: matchingPaths,
                workingDirectory: workingDirectory
            )
        } else if let summary {
            unseen = await history.append(
                summary: summary, sessionID: observedSessionID,
                workingDirectory: workingDirectory
            )
        } else {
            unseen = nil
        }
        guard sessionID == observedSessionID, fileArtifactHistory === history else { return nil }
        if let summary { lastFileChangeSummary = summary }
        if let unseen {
            await (turnPresenter ?? effectivePresenter(for: nil)).presentSealedFileArtifacts(unseen)
        }
        if !retainsFileArtifactHistory {
            await history.discardFinishedTurns()
        }
        guard sessionID == observedSessionID, fileArtifactHistory === history else { return nil }
        return summary
    }
}
