//
//  TerminalChat+Setup.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

extension TerminalChat {
    func makeRuntimeSetupResumeSnapshot() async -> TerminalChatResumeSnapshot {
        let runtimeSnapshot = await sessionRunner.snapshotSession(id: sessionID)
        return TerminalChatResumeSnapshot(
            sessionID: sessionID,
            cacheKey: runtimeSnapshot?.cacheKey ?? activeSessionCacheKey,
            history: runtimeSnapshot?.history ?? activeSessionHistory,
            transcriptHistory: activeSessionTranscript,
            activePlan: activePlan,
            queuedPlans: queuedPlans,
            checkpointTree: activeCheckpointTree,
            savedSessionName: activeSavedSessionName,
            commandHistory: interactiveReader.commandHistory
        )
    }

    func applyRuntimeSetupResumeSnapshotIfNeeded() {
        guard let snapshot = runtimeSetupResumeSnapshot else {
            return
        }
        // The session id is the snapshot's from `init`: the terminal's slot
        // opened its first incarnation with it (see `TerminalChat.init`).
        interactiveReader.restoreCommandHistory(snapshot.commandHistory)
        resetFileArtifactState()
        activeSessionCacheKey = snapshot.cacheKey
        activeSessionHistory = snapshot.history
        replaceActiveSessionTranscript(with: snapshot.transcriptHistory)
        activePlan = snapshot.activePlan
        queuedPlans = snapshot.activePlan == nil ? [] : snapshot.queuedPlans
        // A setup restart restores persisted session data only, never an
        // unfinished conversational planning exchange.
        planBrainstorming = nil
        pendingPlanApprovalPlanID = nil
        activeCheckpointTree = snapshot.checkpointTree
        activeSavedSessionName = snapshot.savedSessionName
        activeSessionSystemPromptOverride = nil
        resetResponseLanguageLock()
    }
}
