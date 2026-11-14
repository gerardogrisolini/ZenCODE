//
//  ZenCODEACPBridge+SessionPersistence.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/11/26.
//

import Foundation
import ToolCore

/// The conversation of every ACP session, kept on disk so that a client that
/// reopens it after `zen --acp` restarted (`session/load` or `session/resume`
/// with only `sessionId`, `cwd`, and `mcpServers`, as ACP specifies) finds it
/// again. The records are written by ``ACPSessionStore``, which alone knows
/// their layout.
///
/// A record is saved at the end of every turn of the editor, where the live
/// session adopts the runner's snapshot (`refreshSessionStateIfAvailable`,
/// also after `/plan load`), and after every turn the slot's Telegram channel
/// runs (``saveSessionHistoryAfterTurn(of:)``). A save is best effort: a
/// failure is logged and never changes a reply, the outcome of a turn, or the
/// session. It runs on the bridge, in order, not in a detached task.
extension ZenCODEACPBridge {
    /// The store of the session records, in the support directory resolved on
    /// every use.
    var acpSessionStore: ACPSessionStore {
        ACPSessionStore()
    }

    /// The record kept for the session `sessionID` in the project of
    /// `workingDirectory`; `nil` when there is none or it cannot be used (the
    /// store logs why).
    func savedACPSession(id sessionID: String, workingDirectory: URL) -> ACPSavedSession? {
        acpSessionStore.load(sessionID: sessionID, workingDirectory: workingDirectory)
    }

    /// Saves `history`, the conversation of the live session `sessionID`,
    /// with the model, agent, and thinking selections of `configuration`,
    /// the session's own configuration. The dynamic context leading a history
    /// is not saved: a restore composes it again. An empty conversation is
    /// not saved, so a session without turns leaves no record.
    func saveSessionHistory(
        sessionID: String,
        configuration: AgentCoreSessionConfiguration,
        history: [AgentRuntimeMessage]
    ) {
        let conversation = AgentRuntimeDynamicContext.separating(from: history).history
        guard !conversation.isEmpty else {
            return
        }
        let now = Date()
        let record = ACPSavedSession(
            sessionID: sessionID,
            workingDirectoryPath: configuration.workingDirectoryPath,
            createdAt: now,
            savedAt: now,
            modelID: configuration.modelID,
            agentID: configuration.agentID,
            thinkingSelection: configuration.thinkingSelection?.rawValue,
            preserveThinking: configuration.preserveThinking,
            history: conversation
        )
        do {
            try acpSessionStore.save(record)
        } catch {
            ZenLogger.warning(
                .sessionService,
                "Could not save the history of ACP session \(sessionID): \(error.localizedDescription)"
            )
        }
    }

    /// Saves the conversation of the live session whose incarnation runs
    /// `controller`, after a turn another channel of its slot (Telegram) ran
    /// on it: the history of the runner's snapshot, with the selections of
    /// the session's configuration. The session itself is left as it is. A
    /// session that closed or was replaced while the snapshot was read is
    /// not saved.
    func saveSessionHistoryAfterTurn(of controller: ChatSessionController) async {
        guard let (sessionID, session) = sessions.first(where: { $0.value.controller === controller }) else {
            return
        }
        guard let snapshot = await sessionRunner.snapshotSession(id: sessionID),
              let live = liveSession(id: sessionID, epoch: session.epoch) else {
            return
        }
        saveSessionHistory(
            sessionID: sessionID,
            configuration: live.configuration,
            history: snapshot.history
        )
    }
}
