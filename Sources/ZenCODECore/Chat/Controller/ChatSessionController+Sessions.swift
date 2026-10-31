//
//  ChatSessionController+Sessions.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The session operations shared by every channel: a fresh session, the saved
/// sessions of the project (list, save, load, delete), context compaction,
/// and the restore from a checkpoint entry.
///
/// Every operation returns its closing notices; notices raised while it runs
/// go to the presenter as they happen. A channel's own steps in the middle of
/// a saved-session load run through ``ChatSessionController/channelHooks``
/// (see ``ChatSessionChannelHooks/savedSessionWillLoad()``). The `choose…`
/// operations ask the ``ChatInteractionHost`` with a menu when the host has
/// the capability, and otherwise return the non-interactive notice.
///
/// Saved sessions live in ``TerminalSessionStore``, keyed by project; the
/// per-project index in `sessions.json` (``SavedSessionsStore``) follows
/// saves and deletions. The DS4 KV checkpoint of a saved session is written
/// only by a save and read only by a load.
extension ChatSessionController {
    // MARK: - New session

    /// Discards the active session and starts a fresh, unsaved one with the
    /// ID `newSessionID`, which the channel chooses. The selection is kept;
    /// the conversation, the artifacts, the saved-session link, and the plan
    /// are cleared.
    func startNewSession(newSessionID: String) async throws -> ChatSessionOperationOutcome {
        await abandonPlanBrainstorming()
        await managementRuntime?.resetSession(id: sessionID)
        sessionID = newSessionID
        resetFileArtifactState()
        cacheKey = nil
        history = []
        replaceTranscript(with: [])
        savedSessionState.systemPromptOverride = nil
        savedSessionState.dynamicContextOverride = nil
        savedSessionState.savedSessionName = nil
        savedSessionState.checkpointTree = nil
        activePlan = nil
        pendingPlanApprovalPlanID = nil
        await presentSessionStateChanged()
        try await createSessionWithSelectedSkills()
        return ChatSessionOperationOutcome(notices: [.sessionStarted])
    }

    // MARK: - Saved sessions

    /// The saved sessions of the project, most recently saved first.
    func savedSessions() throws -> [TerminalSavedSession] {
        try TerminalSessionStore.savedSessions(for: workingDirectory)
    }

    /// The menu entries of `sessions`, in list order.
    nonisolated static func savedSessionChoiceItems(
        _ sessions: [TerminalSavedSession]
    ) -> [ChatChoiceItem] {
        sessions.map { session in
            ChatChoiceItem(
                id: session.name,
                title: session.name,
                detail: ChatSessionNoticeText.savedSessionDetail(ChatSavedSessionSummary(session))
            )
        }
    }

    private func savedSessionSummaries(
        _ sessions: [TerminalSavedSession]
    ) -> [ChatSavedSessionSummary] {
        sessions.map(ChatSavedSessionSummary.init)
    }

    /// `/sessions`: asks the host for a saved session and loads it.
    func chooseSavedSession() async throws -> ChatSessionOperationOutcome {
        let sessions = try savedSessions()
        guard !sessions.isEmpty else {
            return ChatSessionOperationOutcome(notices: [.noSavedSessions, .sessionSelectionUsage])
        }
        guard host.capabilities.contains(.singleChoice) else {
            return ChatSessionOperationOutcome(notices: [
                .requiresInteractiveHost(
                    .savedSessionSelection(
                        savedSessionSummaries(sessions),
                        activeName: savedSessionState.savedSessionName
                    )
                ),
            ])
        }

        guard let selectedName = await host.chooseOne(
            title: "Saved sessions",
            items: Self.savedSessionChoiceItems(sessions),
            selectedID: savedSessionState.savedSessionName
        ),
            let selectedSession = sessions.first(where: { $0.name == selectedName }) else {
            return ChatSessionOperationOutcome(notices: [
                .savedSessions(
                    savedSessionSummaries(sessions),
                    activeName: savedSessionState.savedSessionName
                ),
            ])
        }
        return try await loadSavedSession(selectedSession)
    }

    // MARK: - Save

    /// `/sessions save`: saves the session under its saved-session name, or
    /// under a name derived from the first prompt when it was never saved.
    /// `contextWindow` is the context window the channel displays now.
    func saveActiveSession(
        contextWindow: DirectAgentContextWindowStatus?
    ) async -> ChatSessionOperationOutcome {
        if let name = savedSessionState.savedSessionName?.nilIfBlank {
            return await saveSession(named: name, contextWindow: contextWindow)
        }

        guard let derivedName = Self.derivedSessionName(
            fromFirstPromptIn: transcript.isEmpty ? history : transcript
        ) else {
            return ChatSessionOperationOutcome(notices: [.nothingToSave])
        }
        return await saveSession(named: derivedName, contextWindow: contextWindow)
    }

    /// `/sessions <name>`: saves (or overwrites) the session as `rawName`,
    /// records it in the project's saved-session index, and writes the DS4
    /// KV checkpoint next to it. `contextWindow` is the context window the
    /// channel displays now.
    ///
    /// The saved notice is presented as soon as the session is on disk; the
    /// checkpoint outcome is returned.
    func saveSession(
        named rawName: String,
        contextWindow: DirectAgentContextWindowStatus?
    ) async -> ChatSessionOperationOutcome {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            return ChatSessionOperationOutcome(notices: [.sessionSelectionUsage])
        }

        guard let snapshot = await runtime.snapshotSession(id: sessionID) else {
            return ChatSessionOperationOutcome(notices: [.sessionUnavailableToSave])
        }

        let existingSession = try? TerminalSessionStore.load(
            name: name,
            workingDirectory: workingDirectory
        )
        let taskGraph = try? await runtime.taskGraphSnapshot(sessionID: sessionID, graphID: nil)
        let now = Date()
        let savedSession = TerminalSavedSession(
            name: name,
            sessionID: snapshot.sessionID,
            cacheKey: snapshot.cacheKey
                ?? cacheKey
                ?? Self.savedSessionCacheKey(
                    name: name,
                    workingDirectory: workingDirectory
                ),
            workingDirectoryPath: workingDirectory.path,
            createdAt: existingSession?.createdAt ?? now,
            savedAt: now,
            modelID: currentEffectiveModelID(),
            agentID: selection.agent?.id,
            agentName: selection.agent?.name,
            selectedTools: Self.selectedToolSelectionNames(selection.toolKeys),
            selectedSkillIDs: selection.skillIDs.sorted(),
            thinkingSelection: currentAgentThinkingSelection()?.rawValue,
            contextWindow: contextWindow.map {
                TerminalSavedSessionContextWindow($0)
            },
            systemPrompt: snapshot.systemPrompt,
            dynamicContext: snapshot.dynamicContext,
            history: snapshot.history,
            transcriptHistory: transcript,
            activePlan: activePlan,
            taskGraph: taskGraph,
            checkpointTree: (savedSessionState.checkpointTree ?? existingSession?.checkpointTree)?
                .mergingHistory(transcript)
                ?? SessionCheckpointTree.fromLinearHistory(transcript, sessionID: snapshot.sessionID)
        )

        do {
            _ = try TerminalSessionStore.save(savedSession)
        } catch {
            return ChatSessionOperationOutcome(notices: [
                .operationFailed(description: error.localizedDescription),
            ])
        }
        recordSavedSessionIndex(savedSession)
        savedSessionState.savedSessionName = savedSession.name
        savedSessionState.checkpointTree = savedSession.checkpointTree
        await presentSessionStateChanged()
        await presenter.presentSessionNotice(
            .sessionSaved(name: savedSession.name, messageCount: savedSession.messageCount)
        )

        // The only place that writes a DS4 KV checkpoint: an explicit save.
        let checkpointNotice = await saveEngineCheckpoint(forSavedSession: savedSession)
        return ChatSessionOperationOutcome(
            notices: checkpointNotice.map { [.engineCheckpoint($0)] } ?? []
        )
    }

    /// Records `savedSession` as the project's latest saved session in the
    /// saved-session index. A failure is logged: the session itself is saved.
    func recordSavedSessionIndex(_ savedSession: TerminalSavedSession) {
        do {
            try SavedSessionsStore().recordSavedSession(
                projectPath: savedSession.workingDirectoryPath,
                sessionName: savedSession.name,
                sessionID: savedSession.sessionID,
                savedAt: savedSession.savedAt
            )
        } catch {
            ZenLogger.warning(
                .memory,
                "failed to update saved-session index for \(savedSession.name): \(error.localizedDescription)"
            )
        }
    }

    /// Writes the engine KV checkpoint (DS4) next to the `.session` file that
    /// was just saved. Reached only through a save: ZenCODE never saves a
    /// checkpoint after a generation, on session close or on shutdown.
    /// Non-blocking: a failure is reported and the saved session stays valid.
    /// Whenever no new checkpoint is written, a checkpoint left by an earlier
    /// save of the same name is removed so it cannot outlive its session
    /// state. Returns `nil` when the model has no engine checkpoint.
    private func saveEngineCheckpoint(
        forSavedSession savedSession: TerminalSavedSession
    ) async -> ChatEngineCheckpointNotice? {
        let checkpointURL = TerminalSessionStore.engineCheckpointURL(
            name: savedSession.name,
            workingDirectory: workingDirectory
        )
        var notice: ChatEngineCheckpointNotice?
        do {
            let outcome = try await managementRuntime?.saveEngineCheckpoint(
                sessionID: sessionID,
                to: checkpointURL
            )
            switch outcome {
            case .saved:
                return .saved
            case .skippedImages:
                notice = .skippedImages
            case .skippedNoLiveState:
                notice = .skippedNoLiveState
            case .notApplicable, nil:
                break
            }
        } catch {
            notice = .saveFailed(description: error.localizedDescription)
        }
        TerminalSessionStore.deleteEngineCheckpoint(
            name: savedSession.name,
            workingDirectory: workingDirectory
        )
        return notice
    }

    // MARK: - Delete

    /// `/sessions delete`: asks the host which saved sessions to delete and
    /// deletes them. A cancelled or empty menu presents nothing.
    func chooseSavedSessionsToDelete() async throws -> ChatSessionOperationOutcome {
        let sessions = try savedSessions()
        guard !sessions.isEmpty else {
            return ChatSessionOperationOutcome(notices: [.noSavedSessions])
        }
        guard host.capabilities.contains(.multipleChoice) else {
            return ChatSessionOperationOutcome(notices: [
                .requiresInteractiveHost(
                    .savedSessionDeletion(
                        savedSessionSummaries(sessions),
                        activeName: savedSessionState.savedSessionName
                    )
                ),
            ])
        }

        guard let selectedNames = await host.chooseMany(
            title: "Delete saved sessions",
            items: Self.savedSessionChoiceItems(sessions),
            selectedIDs: []
        ),
            !selectedNames.isEmpty else {
            return ChatSessionOperationOutcome()
        }
        return await deleteSavedSessions(sessions.filter { selectedNames.contains($0.name) })
    }

    /// Deletes the saved sessions named `names`, in list order, with their
    /// DS4 checkpoints and their entries in the saved-session index. Names
    /// that match no saved session of the project are ignored.
    func deleteSavedSessions(names: Set<String>) async throws -> ChatSessionOperationOutcome {
        let sessions = try savedSessions()
        return await deleteSavedSessions(sessions.filter { names.contains($0.name) })
    }

    /// One notice per session, in order. A store failure ends the deletion
    /// with ``ChatSessionNotice/operationFailed(description:)`` after the
    /// notices of the sessions already handled.
    private func deleteSavedSessions(
        _ sessions: [TerminalSavedSession]
    ) async -> ChatSessionOperationOutcome {
        var notices: [ChatSessionNotice] = []
        let previousSavedSessionState = savedSessionState
        for savedSession in sessions {
            let didDelete: Bool
            do {
                didDelete = try TerminalSessionStore.delete(
                    name: savedSession.name,
                    workingDirectory: workingDirectory
                )
            } catch {
                notices.append(.operationFailed(description: error.localizedDescription))
                break
            }
            if savedSessionState.savedSessionName == savedSession.name {
                savedSessionState.savedSessionName = nil
            }
            if didDelete {
                removeSavedSessionIndex(savedSession)
                notices.append(.sessionDeleted(name: savedSession.name))
            } else {
                notices.append(.savedSessionNotFound(name: savedSession.name))
            }
        }
        if savedSessionState != previousSavedSessionState {
            await presentSessionStateChanged()
        }
        return ChatSessionOperationOutcome(notices: notices)
    }

    /// Removes a deleted session from the saved-session index. A failure is
    /// logged, as for a save: the session itself is deleted.
    func removeSavedSessionIndex(_ savedSession: TerminalSavedSession) {
        do {
            try SavedSessionsStore().removeSavedSession(
                projectPath: savedSession.workingDirectoryPath,
                sessionName: savedSession.name
            )
        } catch {
            ZenLogger.warning(
                .memory,
                "failed to remove \(savedSession.name) from the saved-session index: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - Compaction

    /// `/sessions compact`: compacts the session context now.
    /// `maxTokensOverride` is the context-window limit the channel displays;
    /// the outcome carries the estimated context window for that display.
    func compactSession(maxTokensOverride: Int?) async throws -> ChatSessionCompactionOutcome {
        guard let result = try await managementRuntime?.compactSession(
            id: sessionID,
            force: true,
            maxTokensOverride: maxTokensOverride
        ) else {
            return ChatSessionCompactionOutcome(contextWindow: nil, notice: .nothingToCompact)
        }

        let snapshot = result.snapshot
        cacheKey = snapshot.cacheKey
        history = snapshot.history
        savedSessionState.systemPromptOverride = snapshot.systemPrompt
        savedSessionState.dynamicContextOverride = snapshot.dynamicContext
        await presentSessionStateChanged()

        return ChatSessionCompactionOutcome(
            contextWindow: DirectAgentContextWindowStatus(
                usedTokens: result.estimatedTokenCount,
                maxTokens: result.maxTokens,
                modelID: snapshot.modelID ?? currentEffectiveModelID() ?? "unknown",
                isApproximate: true
            ),
            notice: .sessionCompacted(
                originalTokenCount: result.originalEstimatedTokenCount,
                tokenCount: result.estimatedTokenCount,
                keptRecentMessageCount: result.keptRecentMessageCount
            )
        )
    }

    // MARK: - Load

    /// Loads a saved session in place of the active one, optionally from a
    /// specific checkpoint entry of its tree. With `checkpointEntryID` the
    /// conversation is rebuilt from the root-to-entry path and new messages
    /// branch from that entry.
    ///
    /// The sequence discards the active session (planning discussion,
    /// workflow, runtime session, artifacts), installs the saved
    /// conversation, prompt, plan, checkpoint tree, model, thinking level,
    /// agent, tools, and skills, loads the model, restores the runtime
    /// session with its prompt skills and task graph, and finally restores
    /// the DS4 KV checkpoint. The channel's own steps run through the
    /// `savedSession…` hooks, and the restored transcript is handed to
    /// ``ChatSessionChannelHooks/savedSessionDidRestore(transcript:contextWindow:)``
    /// to present.
    ///
    /// The loaded notice and the checkpoint progress are presented as they
    /// happen; the outcome carries the restored session (the same transcript,
    /// for channels without hooks) and the checkpoint outcome.
    func loadSavedSession(
        _ savedSession: TerminalSavedSession,
        checkpointEntryID: String? = nil
    ) async throws -> ChatSessionOperationOutcome {
        let tree = savedSession.checkpointTree
        let restoredMessages: [AgentRuntimeMessage]
        let restoredTranscript: [AgentRuntimeMessage]
        var workingTree = tree

        if let entryID = checkpointEntryID,
           tree.entry(id: entryID) != nil {
            restoredMessages = tree.messages(from: entryID)
            restoredTranscript = restoredMessages
            // Move the active leaf to the selected entry so new messages branch
            // from it rather than from the previous leaf.
            workingTree.navigate(to: entryID)
        } else {
            restoredMessages = savedSession.history
            restoredTranscript = Self.savedSessionDisplayHistory(savedSession)
        }

        await channelHooks?.savedSessionWillLoad()
        await abandonPlanBrainstorming()
        activeWorkflow = nil
        await managementRuntime?.resetSession(id: sessionID)
        sessionID = savedSession.sessionID
        resetFileArtifactState()
        cacheKey = savedSession.cacheKey
        history = restoredMessages
        replaceTranscript(with: restoredTranscript)
        savedSessionState.systemPromptOverride = savedSession.systemPrompt
        savedSessionState.dynamicContextOverride = savedSession.dynamicContext
        activePlan = savedSession.activePlan
        // Deliberately absent from TerminalSavedSession; abandonment above closes
        // the runtime Planner before the restored state is installed.
        pendingPlanApprovalPlanID = nil
        savedSessionState.checkpointTree = workingTree
        savedSessionState.savedSessionName = savedSession.name
        selection.modelIDOverride = savedSession.modelID ?? environment.explicitModelID
        selection.thinkingOverride = savedSession.thinkingSelection.flatMap {
            AgentThinkingSelection(rawValue: $0)
        }
        selection.agent = try restoredAgent(for: savedSession)
        // The restored agent counts as selected again: read the launch folder
        // anew when the restored session's prompt is composed.
        launchFolderProjectsCache = nil
        let items = await toolSelectionItems()
        selection.toolKeys = Self.toolSelectionKeys(
            from: savedSession.selectedTools,
            items: items
        )
        selection.skillIDs = Set(savedSession.selectedSkillIDs)
        await presentSessionStateChanged()

        await ensureWorkspaceAccess()
        lastFileChangeSummary = nil
        await channelHooks?.savedSessionWillRestore()

        try await preloadSessionModel(reason: .savedSessionLoaded)
        try await managementRuntime?.restoreSession(
            configuration: await composedSessionConfiguration(discoverExternalTools: true)
        )
        await managementRuntime?.updatePromptSkillSelection(
            selectedPromptSkills(),
            sessionID: sessionID
        )
        if let taskGraph = savedSession.taskGraph {
            _ = try await managementRuntime?.restoreTaskGraph(
                taskGraph,
                sessionID: savedSession.sessionID
            )
        }
        restoreWorkflowProjection(
            from: try await runtime.taskGraphSnapshot(sessionID: sessionID, graphID: nil)
        )

        let restoredSession = ChatRestoredSession(
            name: savedSession.name,
            transcript: transcript,
            contextWindow: savedSession.contextWindow
        )
        await channelHooks?.savedSessionDidRestore(
            transcript: restoredSession.transcript,
            contextWindow: savedSession.contextWindow?.runtimeStatus
        )
        await presenter.presentSessionNotice(
            .sessionLoaded(name: savedSession.name, messageCount: savedSession.messageCount)
        )

        // The only place that reads a DS4 KV checkpoint: loading a saved session.
        let checkpointNotice = await restoreEngineCheckpoint(forSavedSession: savedSession)
        return ChatSessionOperationOutcome(
            restoredSession: restoredSession,
            notices: checkpointNotice.map { [.engineCheckpoint($0)] } ?? []
        )
    }

    /// Loads the engine KV checkpoint of a restored session, when the current
    /// model is DS4 and the file exists. Reached only from
    /// ``loadSavedSession(_:checkpointEntryID:)``, after the runtime session
    /// is restored. Never blocks loading the session: progress is presented
    /// as it happens and the outcome returned; `nil` when no checkpoint
    /// applies.
    private func restoreEngineCheckpoint(
        forSavedSession savedSession: TerminalSavedSession
    ) async -> ChatEngineCheckpointNotice? {
        let checkpointURL = TerminalSessionStore.engineCheckpointURL(
            name: savedSession.name,
            workingDirectory: workingDirectory
        )
        guard FileManager.default.fileExists(atPath: checkpointURL.path),
              let managementRuntime else {
            return nil
        }
        let presenter = self.presenter
        let outcome = await managementRuntime.restoreEngineCheckpoint(
            sessionID: sessionID,
            from: checkpointURL
        ) { event in
            if case let .status(message) = event {
                await presenter.presentSessionNotice(.engineCheckpoint(.status(message)))
            }
        }
        switch outcome {
        case .restored:
            return .restored
        case .incompatible:
            return .incompatible
        case .notApplicable:
            return nil
        case let .failed(reason):
            return .restoreFailed(reason: reason)
        }
    }

    /// The agent a saved session was saved with, found by ID and then by
    /// name among the available profiles; `nil` when it was saved without
    /// one or the profile no longer exists.
    func restoredAgent(
        for savedSession: TerminalSavedSession
    ) throws -> AgentProfile? {
        guard savedSession.agentID != nil || savedSession.agentName != nil else {
            return nil
        }
        let agents = try availableAgents()
        if let agentID = savedSession.agentID,
           let agent = agents.first(where: { $0.id == agentID }) {
            return agent
        }
        if let agentName = savedSession.agentName {
            let key = Self.agentSelectionKey(agentName)
            return agents.first { Self.agentSelectionKey($0.name) == key }
        }
        return nil
    }

    /// Arms the `/goal` workflow of a restored task graph: an open workflow
    /// graph resumes on the next message; any other graph clears the
    /// workflow.
    func restoreWorkflowProjection(from snapshot: TaskGraphSnapshot?) {
        guard let snapshot, snapshot.source.isWorkflow,
              !snapshot.state.isTerminal else {
            activeWorkflow = nil
            return
        }
        var workflow = WorkflowCommandRuntimeState(
            goal: snapshot.workflow?.originalGoal ?? "", graphID: snapshot.id
        )
        if snapshot.workflow != nil, snapshot.workflow?.state != .running {
            workflow.recordCoordinatorOutput(nil, graph: snapshot)
        } else {
            workflow.armForResumedGraph()
        }
        activeWorkflow = workflow
    }

    // MARK: - Checkpoints

    private enum ActiveSavedSessionLookup {
        case found(TerminalSavedSession)
        case unavailable(ChatSessionNotice)
    }

    /// The saved session a restore starts from: the active saved session, as
    /// the project's store holds it.
    private func activeSavedSessionLookup() throws -> ActiveSavedSessionLookup {
        guard let activeName = savedSessionState.savedSessionName else {
            return .unavailable(.noActiveSavedSession)
        }
        let sessions = try savedSessions()
        guard let session = sessions.first(where: { $0.name == activeName }) else {
            return .unavailable(.activeSavedSessionNotFound(name: activeName))
        }
        return .found(session)
    }

    /// The checkpoint menu of `savedSession`: every entry of its tree, the
    /// active leaf selected.
    nonisolated static func checkpointEntryChoices(
        for savedSession: TerminalSavedSession
    ) -> ChatChoiceList {
        let tree = savedSession.checkpointTree
        return ChatChoiceList(
            title: "Restore '\(savedSession.name)' from checkpoint entry",
            items: tree.entries.map { entry in
                ChatChoiceItem(
                    id: entry.id,
                    title: "\(entry.id) \(tree.entryLabel(entry))",
                    detail: entry.id == tree.activeLeafID ? "active" : nil
                )
            },
            selectedIDs: [tree.activeLeafID]
        )
    }

    /// The checkpoint menu of the active saved session; `nil` when there is
    /// no active saved session in the project's store.
    func checkpointEntryChoices() throws -> ChatChoiceList? {
        guard case let .found(session) = try activeSavedSessionLookup() else {
            return nil
        }
        return Self.checkpointEntryChoices(for: session)
    }

    /// `/sessions restore`: asks the host for an entry of the active saved
    /// session's checkpoint tree and restores from it. A cancelled menu, or a
    /// host without menus, presents nothing.
    func chooseCheckpointEntry() async throws -> ChatSessionOperationOutcome {
        let session: TerminalSavedSession
        switch try activeSavedSessionLookup() {
        case let .unavailable(notice):
            return ChatSessionOperationOutcome(notices: [notice])
        case let .found(activeSession):
            session = activeSession
        }
        guard host.capabilities.contains(.singleChoice) else {
            return ChatSessionOperationOutcome()
        }

        let choices = Self.checkpointEntryChoices(for: session)
        guard let entryID = await host.chooseOne(
            title: choices.title,
            items: choices.items,
            selectedID: choices.selectedIDs.first
        ) else {
            return ChatSessionOperationOutcome()
        }
        return try await restoreFromCheckpoint(session, entryID: entryID)
    }

    /// `/sessions restore <entry-id>`: restores the active saved session from
    /// the entry `entryID` of its checkpoint tree.
    func restoreFromCheckpoint(entryID: String) async throws -> ChatSessionOperationOutcome {
        let session: TerminalSavedSession
        switch try activeSavedSessionLookup() {
        case let .unavailable(notice):
            return ChatSessionOperationOutcome(notices: [notice])
        case let .found(activeSession):
            session = activeSession
        }
        guard session.checkpointTree.entry(id: entryID) != nil else {
            return ChatSessionOperationOutcome(notices: [.checkpointEntryUnknown(specifier: entryID)])
        }
        return try await restoreFromCheckpoint(session, entryID: entryID)
    }

    /// Restores `savedSession` from the checkpoint entry `entryID`, branching
    /// from that point: subsequent messages form a new branch in the tree.
    func restoreFromCheckpoint(
        _ savedSession: TerminalSavedSession,
        entryID: String
    ) async throws -> ChatSessionOperationOutcome {
        guard savedSession.checkpointTree.entry(id: entryID) != nil else {
            return ChatSessionOperationOutcome(notices: [
                .checkpointEntryNotFound(entryID: entryID, sessionName: savedSession.name),
            ])
        }
        let outcome = try await loadSavedSession(savedSession, checkpointEntryID: entryID)
        let messageCount = transcript.filter { $0.role != .system }.count
        return ChatSessionOperationOutcome(
            restoredSession: outcome.restoredSession,
            notices: outcome.notices + [.checkpointRestored(entryID: entryID, messageCount: messageCount)]
        )
    }

    // MARK: - Saved-session helpers

    /// The conversation a saved session presents: its transcript, or for a
    /// session saved before transcripts were kept its history, preceded by
    /// the compacted context summary when its prompt holds one.
    nonisolated static func savedSessionDisplayHistory(
        _ savedSession: TerminalSavedSession
    ) -> [AgentRuntimeMessage] {
        if let transcriptHistory = savedSession.transcriptHistory {
            return transcriptHistory
        }

        guard let compactedSummary = compactionSummaryDisplayText(
            from: savedSession.systemPrompt
        ) else {
            return savedSession.history
        }

        return [
            AgentRuntimeMessage(
                role: .assistant,
                content: compactedSummary
            )
        ] + savedSession.history
    }

    private nonisolated static func compactionSummaryDisplayText(
        from systemPrompt: String?
    ) -> String? {
        guard let systemPrompt,
              let summaryRange = systemPrompt.range(
                of: AgentConversationCompactionSupport.memorySummaryHeader
              ) else {
            return nil
        }
        let summary = String(systemPrompt[summaryRange.lowerBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else {
            return nil
        }
        return """
        Restored compacted context:

        \(summary)
        """
    }

    /// Derives a session name from the first user prompt in a message list.
    /// Used when `/sessions save` runs without an active saved session so a new
    /// snapshot is named after what the user first asked instead of failing.
    nonisolated static func derivedSessionName(
        fromFirstPromptIn messages: [AgentRuntimeMessage]
    ) -> String? {
        guard let firstPrompt = messages.first(where: { $0.role == .user })?.content else {
            return nil
        }
        return derivedSessionName(fromFirstPrompt: firstPrompt)
    }

    /// Reduces a raw prompt to a concise single-line session name, truncating at
    /// a word boundary when it exceeds `limit`. Returns nil for blank prompts.
    nonisolated static func derivedSessionName(
        fromFirstPrompt prompt: String,
        limit: Int = 40
    ) -> String? {
        let singleLine = prompt
            .replacingOccurrences(of: "\n", with: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !singleLine.isEmpty else {
            return nil
        }
        guard singleLine.count > limit else {
            return singleLine
        }

        let truncated = String(singleLine.prefix(limit))
        if let lastSpace = truncated.lastIndex(of: " ") {
            let wordBounded = String(truncated[..<lastSpace])
                .trimmingCharacters(in: .whitespaces)
            if !wordBounded.isEmpty {
                return wordBounded
            }
        }
        return truncated.trimmingCharacters(in: .whitespaces)
    }

    /// The tool selection a saved session records: the selected keys, sorted.
    nonisolated static func selectedToolSelectionNames(
        _ selectedToolKeys: Set<String>
    ) -> [String] {
        selectedToolKeys.sorted()
    }

    /// The cache key of a saved session whose runtime snapshot has none.
    nonisolated static func savedSessionCacheKey(
        name: String,
        workingDirectory: URL
    ) -> String {
        let stem = TerminalSessionStore.filenameStem(for: name)
        let projectKey = TerminalSessionStore.projectKey(for: workingDirectory)
        return "terminal:\(projectKey):session:\(stem)"
    }
}
