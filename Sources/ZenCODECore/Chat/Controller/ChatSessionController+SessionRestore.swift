//
//  ChatSessionController+SessionRestore.swift
//  ZenCODE
//
//  The load of a saved session in place of the active one, with its engine
//  checkpoint, agent, and workflow, and the restore from an entry of the
//  checkpoint tree.
//

import Foundation
import ToolCore

extension ChatSessionController {
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
    /// the DS4 KV checkpoint. The channel's own steps run through
    /// ``ChatSessionChannelHooks/incarnationDidChange(reason:)`` with the
    /// `savedSession…` steps of ``ChatIncarnationChange``, and the restored
    /// transcript is handed to
    /// ``ChatIncarnationChange/savedSessionDidRestore(transcript:contextWindow:)``
    /// to present.
    ///
    /// In a host's slot (``hostBinding``) the saved session is loaded into a
    /// new incarnation: the first step and the end of the planning
    /// discussion run here, the rest on the new controller, in the same
    /// order (``ChatSessionHost/loadSavedSession(in:name:checkpointEntryID:)``);
    /// this controller is fenced from the switch on.
    ///
    /// The loaded notice and the checkpoint progress are presented as they
    /// happen; the outcome carries the restored session (the same transcript,
    /// for channels without hooks) and the checkpoint outcome.
    public func loadSavedSession(
        _ savedSession: TerminalSavedSession,
        checkpointEntryID: String? = nil
    ) async throws -> ChatSessionOperationOutcome {
        if let binding = hostBinding, let host = binding.host {
            return try await host.loadSavedSession(
                in: binding.slotID,
                savedSession,
                checkpointEntryID: checkpointEntryID,
                requestedBy: self
            )
        }
        await prepareForSavedSessionLoad()
        await managementRuntime?.resetSession(id: sessionID)
        sessionID = savedSession.sessionID
        return try await installSavedSession(savedSession, checkpointEntryID: checkpointEntryID)
    }

    /// The first steps of a saved-session load, on the controller whose
    /// session is being replaced: the channel's first step and the end of
    /// the planning discussion and of the workflow.
    func prepareForSavedSessionLoad() async {
        await channelHooks?.incarnationDidChange(reason: .savedSessionWillLoad)
        await abandonPlanBrainstorming()
        activeWorkflow = nil
    }

    /// The rest of a saved-session load, once the session to replace is
    /// discarded and this controller has the saved session's id: in place,
    /// after ``prepareForSavedSessionLoad()``; in a host's slot, on the new
    /// incarnation.
    func installSavedSession(
        _ savedSession: TerminalSavedSession,
        checkpointEntryID: String?
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

        resetFileArtifactState()
        cacheKey = savedSession.cacheKey
        history = restoredMessages
        replaceTranscript(with: restoredTranscript)
        savedSessionState.systemPromptOverride = savedSession.systemPrompt
        savedSessionState.dynamicContextOverride = savedSession.dynamicContext
        activePlan = savedSession.activePlan
        queuedPlans = savedSession.activePlan == nil ? [] : (savedSession.queuedPlans ?? [])
        // Deliberately absent from TerminalSavedSession; abandonment above closes
        // the runtime Planner before the restored state is installed.
        pendingPlanApprovalPlanID = nil
        savedSessionState.checkpointTree = workingTree
        savedSessionState.savedSessionName = savedSession.name
        selection.modelIDOverride = savedSession.modelID ?? environment.explicitModelID
        selection.thinkingOverride = savedSession.thinkingSelection.flatMap {
            AgentThinkingSelection(rawValue: $0)
        }
        let agent: AgentProfile?
        do {
            agent = try restoredAgent(for: savedSession)
        } catch {
            // The session already switched: presenters learn it even when the
            // load stops here.
            await effectivePresenter(for: nil).sessionDidChange(sessionID: sessionID)
            throw error
        }
        selection.agent = agent
        // The restored agent counts as selected again: read the launch folder
        // anew when the restored session's prompt is composed.
        launchFolderProjectsCache = nil
        // Next to the suspension that follows, so the call opens no new window
        // on the state installed above.
        await effectivePresenter(for: nil).sessionDidChange(sessionID: sessionID)
        let items = await toolSelectionItems()
        selection.toolKeys = Self.toolSelectionKeys(
            from: savedSession.selectedTools,
            items: items
        )
        selection.skillNames = Set(savedSession.selectedSkillNames)
        await presentSessionStateChanged()

        await ensureWorkspaceAccess()
        lastFileChangeSummary = nil
        await channelHooks?.incarnationDidChange(reason: .savedSessionWillRestore)

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
        // The one place the restored transcript becomes log entries.
        await effectivePresenter(for: nil).presentRestoredLog(
            ChatTurnEntry.kinds(fromTranscript: restoredSession.transcript)
        )
        await channelHooks?.incarnationDidChange(reason: .savedSessionDidRestore(
            transcript: restoredSession.transcript,
            contextWindow: savedSession.contextWindow?.runtimeStatus
        ))
        await effectivePresenter(for: nil).presentSessionNotice(
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
        let presenter = effectivePresenter(for: nil)
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

    /// The checkpoint menu of the active saved session, or the notice that
    /// says why there is none (``ChatSessionNotice/noActiveSavedSession``,
    /// ``ChatSessionNotice/activeSavedSessionNotFound(name:)``), as
    /// `/sessions restore` answers.
    func checkpointEntryMenu() throws -> ChatChoiceMenuState {
        switch try activeSavedSessionLookup() {
        case let .unavailable(notice):
            return .unavailable(notice)
        case let .found(session):
            return .available(Self.checkpointEntryChoices(for: session))
        }
    }

    /// `/sessions restore`: asks the host for an entry of the active saved
    /// session's checkpoint tree and restores from it. A cancelled menu, or a
    /// host without menus, presents nothing.
    public func chooseCheckpointEntry() async throws -> ChatSessionOperationOutcome {
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
    public func restoreFromCheckpoint(entryID: String) async throws -> ChatSessionOperationOutcome {
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
    /// The message count of the notice is read from the restored session,
    /// which in a host's slot lives in the new incarnation.
    public func restoreFromCheckpoint(
        _ savedSession: TerminalSavedSession,
        entryID: String
    ) async throws -> ChatSessionOperationOutcome {
        guard savedSession.checkpointTree.entry(id: entryID) != nil else {
            return ChatSessionOperationOutcome(notices: [
                .checkpointEntryNotFound(entryID: entryID, sessionName: savedSession.name),
            ])
        }
        let outcome = try await loadSavedSession(savedSession, checkpointEntryID: entryID)
        let restoredTranscript = outcome.restoredSession?.transcript ?? transcript
        let messageCount = restoredTranscript.filter { $0.role != .system }.count
        return ChatSessionOperationOutcome(
            restoredSession: outcome.restoredSession,
            notices: outcome.notices + [.checkpointRestored(entryID: entryID, messageCount: messageCount)]
        )
    }
}
