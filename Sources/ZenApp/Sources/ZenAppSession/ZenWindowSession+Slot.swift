//
//  ZenWindowSession+Slot.swift
//  ZenApp
//
//  The window following its slot: each new incarnation, its snapshots, the
//  block still streaming, and the task-graph card of a turn.
//

import Foundation
import ToolCore
import ZenCODECore

extension ZenWindowSession {
    // MARK: - Following the slot

    /// Follows a new incarnation of the slot: its snapshots, its status
    /// facts, and its shared-chat room. The hooks move the task-graph
    /// observer with it.
    func follow(_ incarnation: ChatSessionIncarnation?) async {
        // A slot without session keeps showing the last one.
        guard !isClosed, let incarnation, incarnation.epoch != current.epoch else { return }
        current = incarnation
        // A sidebar load that ended waits for its own incarnation only.
        if let anchor = savedSessionLoadAnchor, anchor.epoch != incarnation.epoch {
            clearSavedSessionLoad()
        }
        // The sub-agents of the earlier session are not this one's.
        closeSubAgentTabs()
        // Nor are its shared-chat room and messages.
        resetSharedChat()
        // Voice mode, when it follows this window, treats the new session as
        // a new target, as the terminal does on `/sessions`: the reading
        // stops, the live-chat question and the queued announcements are
        // dropped, and only what the new room sends from now on is
        // announced, taken before its observation starts.
        voiceHost.post(.targetDidChange(since: Date.now, host: voiceHost))
        // No task-graph card: the local rows go with the epoch, and so does
        // the card of the turn.
        lastSnapshotTaskGraph = nil
        turnTaskGraphCard = nil
        await hooks.resetResponseLanguageLock(unlessLockedIn: incarnation.epoch)
        guard !isClosed, current.epoch == incarnation.epoch else { return }
        observeSnapshots(of: incarnation)
        statusFactsDidChange()
        await followSharedChat(of: incarnation)
    }

    func observeSnapshots(of incarnation: ChatSessionIncarnation) {
        snapshotTask?.cancel()
        guard let reducer = incarnation.reducer else { return }
        snapshotTask = Task { [weak self] in
            let snapshots = await reducer.snapshots()
            for await snapshot in snapshots {
                guard let self, !Task.isCancelled else { return }
                if let snapshotWillApply = self.snapshotWillApply {
                    await snapshotWillApply()
                    guard !Task.isCancelled else { return }
                }
                self.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: ChatSessionSnapshot) {
        guard !isClosed, snapshot.epoch == current.epoch else { return }
        // The prompts hidden before this snapshot was published.
        for mark in hiddenPrompts.drain() {
            projection.hidePrompt(after: mark.afterSequence, epoch: mark.epoch)
        }
        let wasGenerating = isGenerating
        self.snapshot = snapshot
        if epoch != snapshot.epoch {
            epoch = snapshot.epoch
        }
        // Before the projection, which composes once for both.
        updateTaskGraphCard(from: snapshot)
        if projection.update(with: snapshot) {
            transcript = projection.items
            let groups = ZenArtifactTurnGroup.groups(in: transcript)
            if fileArtifacts != groups {
                fileArtifacts = groups
            }
        }
        updateLiveBlock(from: snapshot)
        if subAgents != snapshot.subAgents {
            subAgents = snapshot.subAgents
        }
        let firstRequest = snapshot.pendingRequests.first
        if pendingRequest != firstRequest {
            pendingRequest = firstRequest
        }
        let generating = snapshot.turn.isGenerating
        if isGenerating != generating {
            isGenerating = generating
        }
        var newStatus = status
        newStatus.isGenerating = generating
        if generating, !wasGenerating {
            newStatus.turnStartedAt = Date()
        }
        newStatus.metrics = snapshot.turn.metrics
        newStatus.contextWindow = snapshot.turn.contextWindow
        newStatus.subscriptionUsage = snapshot.turn.subscriptionUsage
        if newStatus != status {
            status = newStatus
        }
        let savedName = Self.nonBlank(snapshot.savedSession.savedSessionName)
        let title = savedName ?? projection.firstVisiblePromptTitle
        if sessionTitle != title {
            sessionTitle = title
        }
        if currentSavedSessionName != snapshot.savedSession.savedSessionName {
            currentSavedSessionName = snapshot.savedSession.savedSessionName
        }
        settleSavedSessionLoad()
    }

    /// Publishes the block still streaming, each part on its own.
    private func updateLiveBlock(from snapshot: ChatSessionSnapshot) {
        let turn = snapshot.turn
        if liveThought != turn.liveThought {
            liveThought = turn.liveThought
        }
        if liveAssistantText != turn.liveAssistantText {
            liveAssistantText = turn.liveAssistantText
        }
        let blockID = projection.liveBlockID(for: snapshot)
        let turnID = blockID == nil ? nil : turn.turnID
        if liveTurnID != turnID {
            liveTurnID = turnID
        }
        if liveBlockID != blockID {
            liveBlockID = blockID
        }
    }

    /// The card of a turn, as the terminal writes its `Tasks` section: a
    /// change of the graph while a turn generates, when the graph is
    /// significant (``ChatTaskGraphOverview/isSignificant``), shows the card
    /// of the turn after the last log entry of `snapshot` (so before the
    /// block still streaming), with the graph as it is now. The first such
    /// change of a turn adds the card, a later one moves it
    /// (``ZenTranscriptProjection/moveLocal(id:to:content:)``), keeping its
    /// id. Once the turn ended the card stays where it is; a change outside
    /// a turn, or to a graph that is not significant, shows nothing and
    /// leaves every card as it is, and the next turn adds a card of its own.
    /// An unchanged graph (every streamed token) costs one comparison; the
    /// projection composes only when the card changed.
    private func updateTaskGraphCard(from snapshot: ChatSessionSnapshot) {
        guard snapshot.taskGraph != lastSnapshotTaskGraph else { return }
        lastSnapshotTaskGraph = snapshot.taskGraph
        guard snapshot.turn.isGenerating,
              let turnID = snapshot.turn.turnID,
              let overview = snapshot.taskGraph,
              overview.isSignificant
        else { return }
        let anchorSequence = ZenLocalTranscriptItem.anchorSequence(in: snapshot)
        if let card = turnTaskGraphCard, card.turnID == turnID,
           projection.moveLocal(id: card.id, to: anchorSequence, content: .taskGraph(overview)) {
            return
        }
        let item = ZenLocalTranscriptItem(
            epoch: snapshot.epoch,
            anchorSequence: anchorSequence,
            content: .taskGraph(overview)
        )
        turnTaskGraphCard = TurnTaskGraphCard(turnID: turnID, id: item.id)
        projection.insertLocal(item)
    }
}
