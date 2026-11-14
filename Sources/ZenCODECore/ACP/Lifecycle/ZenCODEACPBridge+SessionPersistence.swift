//
//  ZenCODEACPBridge+SessionPersistence.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/11/26.
//

import Foundation
import ToolCore

/// The saved session an ACP session is saved as, remembered by the live
/// incarnation (``ZenCODEACPBridge/SessionState/savedSessionLink``) so that
/// every save after the first one writes the same file without reading it
/// again. A same-incarnation reconstruction keeps it; a close, a
/// `session/delete`, and the shutdown drop it with the session's entry.
struct ACPSavedSessionLink: Sendable {
    /// The name of the saved session, stable for the life of the session.
    let name: String
    /// When the saved session was first saved.
    let createdAt: Date
    /// The checkpoint tree of the saved session the incarnation was restored
    /// from, updated by every save (``SessionCheckpointTree/mergingHistory(_:)``);
    /// `nil` for a session that was not restored from a file, whose tree is
    /// built from its history on every save.
    let checkpointTree: SessionCheckpointTree?
}

/// The conversation of every ACP session is kept as a saved session of its
/// project (``TerminalSavedSession``, written by ``TerminalSessionStore``),
/// marked with ``TerminalSavedSession/acpAutosaveChannel``: `/sessions` lists,
/// loads, and deletes it like any other, and a client that reopens it after
/// `zen --acp` restarted (`session/load` or `session/resume` with only
/// `sessionId`, `cwd`, and `mcpServers`, as ACP specifies) finds it again by
/// the session's id.
///
/// A session is saved at the end of every turn of the editor, where the live
/// session adopts the runner's snapshot (`refreshSessionStateIfAvailable`,
/// also after `/plan load`), and after every turn the slot's Telegram channel
/// runs (``saveSessionHistoryAfterTurn(of:)``). A save is best effort: a
/// failure is logged and never changes a reply, the outcome of a turn, or the
/// session, and the client is told nothing. It runs on the bridge, in order,
/// not in a detached task: what it needs from the runner is read first, then
/// the file is written in one synchronous step, only while the incarnation it
/// was read for is still live, so a save in progress never writes a file
/// after `session/close` or `session/delete`. The saved-session index
/// (`sessions.json`) is not touched: it records the explicit saves.
extension ZenCODEACPBridge {
    /// The saved session that `session/load` or `session/resume` of the
    /// session `sessionID`, which the process does not hold, restores: among
    /// the saved sessions of that id in the project of `workingDirectory`, the
    /// one ACP saved, else the most recently saved; `nil` when there is none
    /// that can be read.
    func savedACPSession(id sessionID: String, workingDirectory: URL) -> TerminalSavedSession? {
        TerminalSessionStore.savedSession(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            preferringAutosaveChannel: TerminalSavedSession.acpAutosaveChannel
        )
    }

    /// Saves the live incarnation `epoch` of `sessionID` with `snapshot`, the
    /// runner's snapshot of its session after a turn. The dynamic context
    /// leading the history is not saved, and an empty conversation saves
    /// nothing, so a session without turns leaves no file.
    func saveSession(
        sessionID: String,
        epoch: UInt64,
        snapshot: AgentRuntimeSessionSnapshot
    ) async {
        let conversation = AgentRuntimeDynamicContext.separating(from: snapshot.history).history
        guard !conversation.isEmpty,
              liveSession(id: sessionID, epoch: epoch) != nil else {
            return
        }
        // Read before the write, as the terminal's save reads it; the
        // incarnation is checked again after the hop.
        let taskGraph = try? await sessionRunner.taskGraphSnapshot(sessionID: sessionID, graphID: nil)
        guard let workingDirectory = writeSavedSession(
            sessionID: sessionID,
            epoch: epoch,
            snapshot: snapshot,
            conversation: conversation,
            taskGraph: taskGraph
        ) else {
            return
        }
        // The host's shell lists the project's saved sessions.
        await host.savedSessionsDidChange(in: workingDirectory)
    }

    /// Saves the conversation of the live session whose incarnation runs
    /// `controller`, after a turn another channel of its slot (Telegram) ran
    /// on it: the runner's snapshot, with the selections of the session's
    /// configuration. The session itself is left as it is. A session that
    /// closed or was replaced while the snapshot was read is not saved.
    func saveSessionHistoryAfterTurn(of controller: ChatSessionController) async {
        guard let session = liveSession(of: controller) else {
            return
        }
        guard let snapshot = await sessionRunner.snapshotSession(id: session.id) else {
            return
        }
        await saveSession(sessionID: session.id, epoch: session.epoch, snapshot: snapshot)
    }

    /// Writes the saved session of the live incarnation `epoch` of
    /// `sessionID`, without suspending, and returns the working directory of
    /// the project it was saved in; `nil` when the incarnation is no longer
    /// live or the write failed (logged). The first save names the session
    /// (``newSavedSessionLink(sessionID:workingDirectory:conversation:now:)``)
    /// and the incarnation remembers the name for the next ones.
    private func writeSavedSession(
        sessionID: String,
        epoch: UInt64,
        snapshot: AgentRuntimeSessionSnapshot,
        conversation: [AgentRuntimeMessage],
        taskGraph: TaskGraphSnapshot?
    ) -> URL? {
        guard let live = liveSession(id: sessionID, epoch: epoch) else {
            return nil
        }
        let configuration = live.configuration
        let workingDirectory = URL(fileURLWithPath: configuration.workingDirectoryPath)
        let now = Date()
        let link = live.savedSessionLink ?? newSavedSessionLink(
            sessionID: sessionID,
            workingDirectory: workingDirectory,
            conversation: conversation,
            now: now
        )
        let checkpointTree = link.checkpointTree?.mergingHistory(conversation)
            ?? SessionCheckpointTree.fromLinearHistory(conversation, sessionID: sessionID)
        let savedSession = TerminalSavedSession(
            name: link.name,
            sessionID: sessionID,
            cacheKey: snapshot.cacheKey,
            workingDirectoryPath: configuration.workingDirectoryPath,
            createdAt: link.createdAt,
            savedAt: now,
            modelID: configuration.modelID,
            agentID: configuration.agentID,
            agentName: configuration.agentName,
            selectedTools: live.selectedAgent?.tools ?? [],
            selectedSkillNames: live.selectedAgent.map { agent in
                selectedAgentSkills(for: agent).map(\.canonicalName).sorted()
            } ?? [],
            thinkingSelection: configuration.thinkingSelection?.rawValue,
            contextWindow: nil,
            systemPrompt: snapshot.systemPrompt,
            dynamicContext: snapshot.dynamicContext,
            history: conversation,
            transcriptHistory: nil,
            activePlan: nil,
            queuedPlans: nil,
            taskGraph: taskGraph,
            checkpointTree: checkpointTree,
            autosaveChannel: TerminalSavedSession.acpAutosaveChannel
        )
        do {
            _ = try TerminalSessionStore.save(savedSession)
        } catch {
            ZenLogger.warning(
                .sessionService,
                "Could not save ACP session \(sessionID) as '\(link.name)': \(error.localizedDescription)"
            )
            return nil
        }
        updateLiveSession(id: sessionID, epoch: epoch) { session in
            session.savedSessionLink = ACPSavedSessionLink(
                name: link.name,
                createdAt: link.createdAt,
                checkpointTree: link.checkpointTree == nil ? nil : checkpointTree
            )
        }
        return workingDirectory
    }

    /// The saved session the first save of `sessionID` writes, in the project
    /// of `workingDirectory`: named after the first prompt of `conversation`
    /// (``ChatSessionController/derivedSessionName(fromFirstPromptIn:)``), or
    /// after the session id without a prompt with text. A name that a saved
    /// session of another session already has, or whose file cannot be read,
    /// is never overwritten: ` (2)`, ` (3)`, … is added until the name is
    /// free. A saved session of this same session with the chosen name keeps
    /// its creation date.
    private func newSavedSessionLink(
        sessionID: String,
        workingDirectory: URL,
        conversation: [AgentRuntimeMessage],
        now: Date
    ) -> ACPSavedSessionLink {
        let baseName = ChatSessionController.derivedSessionName(fromFirstPromptIn: conversation)?.nilIfBlank
            ?? sessionID
        let directoryURL = TerminalSessionStore.sessionsDirectoryURL(for: workingDirectory)
        let files = TerminalSessionStore.savedSessionFiles(in: directoryURL)
        func ownFile(named name: String) -> TerminalSavedSessionFile? {
            let fileURL = directoryURL.appendingPathComponent(TerminalSessionStore.filename(for: name))
            return files.first {
                $0.url.standardizedFileURL == fileURL.standardizedFileURL && $0.header.sessionID == sessionID
            }
        }
        func isTaken(_ name: String) -> Bool {
            if files.contains(where: { $0.header.name == name && $0.header.sessionID != sessionID }) {
                return true
            }
            let fileURL = directoryURL.appendingPathComponent(TerminalSessionStore.filename(for: name))
            return FileManager.default.fileExists(atPath: fileURL.path) && ownFile(named: name) == nil
        }
        var name = baseName
        var suffix = 2
        while isTaken(name) {
            name = "\(baseName) (\(suffix))"
            suffix += 1
        }
        return ACPSavedSessionLink(
            name: name,
            createdAt: ownFile(named: name)?.header.createdAt ?? now,
            checkpointTree: nil
        )
    }

    /// `session/delete` of `sessionID`: deletes, in every project, the saved
    /// sessions of that id that ACP saved by itself, each with its DS4
    /// checkpoint and its entry in the saved-session index, then tells the
    /// host which projects changed. The saved sessions of that id that the
    /// user saved with `/sessions` stay. Nothing to delete is not an error; a
    /// file that cannot be removed ends the deletion with its error, after
    /// the files already removed.
    func deleteAutosavedSessions(sessionID: String) async throws {
        let files = TerminalSessionStore.autosavedSessionFiles(
            sessionID: sessionID,
            autosaveChannel: TerminalSavedSession.acpAutosaveChannel
        )
        var changedWorkspaces: [URL] = []
        var deletionError: Error?
        for file in files {
            do {
                guard try TerminalSessionStore.deleteSavedSessionFile(file) else {
                    continue
                }
            } catch {
                deletionError = error
                break
            }
            removeSavedSessionIndexEntry(of: file.header)
            let workspace = URL(fileURLWithPath: file.header.workingDirectoryPath).standardizedFileURL
            if !changedWorkspaces.contains(workspace) {
                changedWorkspaces.append(workspace)
            }
        }
        for workspace in changedWorkspaces {
            await host.savedSessionsDidChange(in: workspace)
        }
        if let deletionError {
            throw deletionError
        }
    }

    /// Removes a deleted saved session from the saved-session index, as the
    /// controller does when `/sessions` deletes one. A failure is logged: the
    /// session itself is deleted.
    private func removeSavedSessionIndexEntry(of header: TerminalSavedSessionHeader) {
        do {
            try SavedSessionsStore().removeSavedSession(
                projectPath: header.workingDirectoryPath,
                sessionName: header.name
            )
        } catch {
            ZenLogger.warning(
                .memory,
                "failed to remove \(header.name) from the saved-session index: \(error.localizedDescription)"
            )
        }
    }
}
