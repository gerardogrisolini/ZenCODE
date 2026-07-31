//
//  TerminalChat+Setup.swift
//  ZenCODE
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
            checkpointTree: activeCheckpointTree,
            savedSessionName: activeSavedSessionName
        )
    }

    func applyRuntimeSetupResumeSnapshotIfNeeded() {
        guard let snapshot = runtimeSetupResumeSnapshot else {
            return
        }
        sessionID = snapshot.sessionID
        activeSessionCacheKey = snapshot.cacheKey
        activeSessionHistory = snapshot.history
        activeSessionTranscript = snapshot.transcriptHistory
        activePlan = snapshot.activePlan
        activeCheckpointTree = snapshot.checkpointTree
        activeSavedSessionName = snapshot.savedSessionName
        activeSessionSystemPromptOverride = nil
        resetResponseLanguageLock()
    }
}
