//
//  TerminalChat+Sessions.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

enum TerminalSavedSessionCommandAction: Equatable, Sendable {
    case list
    case delete
    case newSession
    case saveActive
    case compact
    case tree
    case branches
    case checkpoint(label: String?)
    case restore(entryID: String)
    case saveNamed(String)
}

extension TerminalChat {
    public func handleSessionsCommand(_ command: String) async {
        let rawArguments = String(command.dropFirst("/sessions".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        switch Self.savedSessionCommandAction(rawArguments: rawArguments) {
        case .list:
            await handleSavedSessionList()
        case .delete:
            await handleSavedSessionDelete()
        case .newSession:
            await startNewSession()
        case .saveActive:
            await saveActiveSession()
        case .compact:
            await compactCurrentSession()
        case .tree:
            await displayCheckpointTree()
        case .branches:
            await listBranches()
        case let .checkpoint(label):
            await createCheckpoint(label: label)
        case let .restore(entryID):
            await handleRestoreCommand(entryID)
        case let .saveNamed(name):
            await saveCurrentSession(named: name)
        }
    }

    /// Resets the runtime conversation and starts a fresh, unsaved session.
    /// Replaces the former `/clear` command.
    public func startNewSession() async {
        do {
            await stopTaskGraphObserver()
            await sessionRunner.resetSession(id: sessionID)
            sessionID = Self.newTerminalSessionID()
            activeSessionCacheKey = nil
            activeSessionHistory = []
            activeSessionTranscript = []
            activeSessionSystemPromptOverride = nil
            resetResponseLanguageLock()
            activeSavedSessionName = nil
            activeCheckpointTree = nil
            activePlan = nil
            try await createCurrentSession()
            await statusBar.reset()
            await refreshInitialStatusBarContextWindow()
            pendingAttachments.removeAll()
            await renderCoordinator.resetOverview(.subAgents)
            await writeSystemMessage("Started a new session.\n")
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    public func handleSavedSessionList() async {
        do {
            let sessions = try TerminalSessionStore.savedSessions(
                for: configuration.workingDirectory
            )
            guard !sessions.isEmpty else {
                await writeSystemMessage("No saved sessions for this project.\n")
                await writeSystemMessage(Self.renderSessionSelectionUsage())
                return
            }

            guard stdinIsTerminal else {
                await renderSavedSessionList(sessions)
                await writeSystemMessage(Self.renderSessionSelectionUsage())
                return
            }

            let items = savedSessionSelectionItems(sessions)
            guard let selectedName = TerminalCheckboxMenu.selectOne(
                title: "Saved sessions",
                items: items,
                selected: activeSavedSessionName,
                reservedBottomRows: await statusBar.reservedRowsForOverlay()
            ),
                  let selectedSession = sessions.first(where: { $0.name == selectedName }) else {
                await renderSavedSessionList(sessions)
                return
            }

            try await loadSavedSession(selectedSession)
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    public func handleSavedSessionDelete() async {
        do {
            let sessions = try TerminalSessionStore.savedSessions(
                for: configuration.workingDirectory
            )
            guard !sessions.isEmpty else {
                await writeSystemMessage("No saved sessions for this project.\n")
                return
            }

            guard stdinIsTerminal else {
                await renderSavedSessionList(sessions)
                await writeSystemMessage(Self.renderSessionSelectionUsage())
                return
            }

            let items = savedSessionSelectionItems(sessions)
            guard let selectedNames = TerminalCheckboxMenu.select(
                title: "Delete saved sessions",
                items: items,
                selected: [],
                reservedBottomRows: await statusBar.reservedRowsForOverlay()
            ),
                  !selectedNames.isEmpty else {
                return
            }

            let selectedSessions = sessions.filter { selectedNames.contains($0.name) }
            for selectedSession in selectedSessions {
                let didDelete = try TerminalSessionStore.delete(
                    name: selectedSession.name,
                    workingDirectory: configuration.workingDirectory
                )
                if activeSavedSessionName == selectedSession.name {
                    activeSavedSessionName = nil
                }
                if didDelete {
                    await writeSystemMessage("Deleted session: \(selectedSession.name).\n")
                } else {
                    await writeFailureMessage("ZenCODE: saved session not found: \(selectedSession.name).\n")
                }
            }
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

        public func saveActiveSession() async {
        if let name = activeSavedSessionName?.nilIfBlank {
            await saveCurrentSession(named: name)
            return
        }

        guard let derivedName = Self.derivedSessionName(
            fromFirstPromptIn: activeSessionTranscript.isEmpty
                ? activeSessionHistory
                : activeSessionTranscript
        ) else {
            await writeFailureMessage(
                "ZenCODE: nothing to save yet. Send a prompt first, or use /sessions <session name>.\n"
            )
            return
        }

        await saveCurrentSession(named: derivedName)
    }

    public func saveCurrentSession(named rawName: String) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            await writeSystemMessage(Self.renderSessionSelectionUsage())
            return
        }

        guard let snapshot = await sessionRunner.snapshotSession(id: sessionID) else {
            await writeFailureMessage("ZenCODE: current session is not available to save.\n")
            return
        }

        let existingSession = try? TerminalSessionStore.load(
            name: name,
            workingDirectory: configuration.workingDirectory
        )
        let taskGraph = try? await sessionRunner.taskGraphSnapshot(sessionID: sessionID)
        let now = Date()
        let savedSession = TerminalSavedSession(
            name: name,
            sessionID: snapshot.sessionID,
            cacheKey: snapshot.cacheKey
                ?? activeSessionCacheKey
                ?? Self.savedSessionCacheKey(
                    name: name,
                    workingDirectory: configuration.workingDirectory
                ),
            workingDirectoryPath: configuration.workingDirectory.path,
            createdAt: existingSession?.createdAt ?? now,
            savedAt: now,
            modelID: currentEffectiveModelID(),
            agentID: selectedAgent?.id,
            agentName: selectedAgent?.name,
            selectedTools: Self.selectedToolSelectionNames(selectedToolKeys),
            selectedSkillIDs: selectedSkillIDs.sorted(),
            thinkingSelection: currentAgentThinkingSelection()?.rawValue,
            contextWindow: await statusBar.currentContextWindowStatus().map {
                TerminalSavedSessionContextWindow($0)
            },
            systemPrompt: snapshot.systemPrompt,
            history: snapshot.history,
            transcriptHistory: activeSessionTranscript,
            activePlan: activePlan,
            taskGraph: taskGraph,
            checkpointTree: (activeCheckpointTree ?? existingSession?.checkpointTree)?.mergingHistory(activeSessionTranscript)
                ?? SessionCheckpointTree.fromLinearHistory(activeSessionTranscript, sessionID: snapshot.sessionID)
        )

        do {
            _ = try TerminalSessionStore.save(savedSession)
            recordSavedSessionIndex(savedSession)
            activeSavedSessionName = savedSession.name
            activeCheckpointTree = savedSession.checkpointTree
            await writeSystemMessage(
                "Saved session: \(savedSession.name) (\(savedSession.messageCount) messages).\n"
            )
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    public func compactCurrentSession() async {
        do {
            let runtimeMaxTokens = await statusBar.currentContextWindowStatus()?.maxTokens
                .flatMap { $0 > 0 ? $0 : nil }
            guard let result = try await sessionRunner.compactSession(
                id: sessionID,
                force: true,
                maxTokensOverride: runtimeMaxTokens
            ) else {
                await writeSystemMessage(
                    "Nothing to compact yet. The session may be too short or the current model has no context-window limit.\n"
                )
                return
            }

            let snapshot = result.snapshot
            activeSessionCacheKey = snapshot.cacheKey
            activeSessionHistory = snapshot.history
            activeSessionSystemPromptOverride = snapshot.systemPrompt

            _ = await statusBar.update(
                contextWindow: DirectAgentContextWindowStatus(
                    usedTokens: result.estimatedTokenCount,
                    maxTokens: result.maxTokens,
                    modelID: snapshot.modelID ?? currentEffectiveModelID() ?? "unknown",
                    isApproximate: true
                )
            )
            await writeSystemMessage(
                "Compacted session context from \(Self.savedSessionTokenCountText(result.originalEstimatedTokenCount)) to \(Self.savedSessionTokenCountText(result.estimatedTokenCount)) estimated tokens, keeping \(result.keptRecentMessageCount) recent messages.\n"
            )
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    public func recordSavedSessionIndex(_ savedSession: TerminalSavedSession) {
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

    public func loadSavedSession(_ savedSession: TerminalSavedSession) async throws {
        try await loadSavedSession(savedSession, checkpointEntryID: nil)
    }

    /// Loads a saved session, optionally restoring from a specific checkpoint
    /// entry in the tree.  When `checkpointEntryID` is provided the message
    /// history is rebuilt from the root-to-entry path and a new branch is
    /// started from that entry.
    public func loadSavedSession(
        _ savedSession: TerminalSavedSession,
        checkpointEntryID: String?
    ) async throws {
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

        await stopTaskGraphObserver()
        await sessionRunner.resetSession(id: sessionID)
        sessionID = savedSession.sessionID
        activeSessionCacheKey = savedSession.cacheKey
        activeSessionHistory = restoredMessages
        activeSessionTranscript = restoredTranscript
        activeSessionSystemPromptOverride = savedSession.systemPrompt
        activePlan = savedSession.activePlan
        activeCheckpointTree = workingTree
        resetResponseLanguageLock()
        activeSavedSessionName = savedSession.name
        manualModelIDOverride = savedSession.modelID ?? configuration.modelID
        manualThinkingSelectionOverride = savedSession.thinkingSelection.flatMap {
            AgentThinkingSelection(rawValue: $0)
        }

        if let agent = try restoredAgent(for: savedSession) {
            selectedAgent = agent
        } else {
            selectedAgent = nil
        }
        let items = await toolSelectionItems()
        selectedToolKeys = Self.toolSelectionKeys(
            from: savedSession.selectedTools,
            items: items
        )
        selectedSkillIDs = Set(savedSession.selectedSkillIDs)

        await ensureWorkspaceAccessIfNeeded()
        pendingAttachments.removeAll()
        lastFileChangeSummary = nil
        await renderCoordinator.resetOverview(.subAgents)
        await renderSubAgentOverview(force: false)
        didPrintActiveTools = false
        printedModelID = nil
        await statusBar.reset()

                await refreshInitialStatusBarContextWindow()
        _ = try await preloadCurrentModel(emitStatus: configuration.hostedModels != nil)
        try await sessionRunner.restoreSession(
            configuration: await currentSessionConfiguration(discoverExternalTools: true)
        )
        if let taskGraph = savedSession.taskGraph {
            _ = try await sessionRunner.restoreTaskGraph(
                taskGraph,
                sessionID: savedSession.sessionID
            )
        }
        await startTaskGraphObserver()
        if let contextWindow = savedSession.contextWindow?.runtimeStatus {
            _ = await statusBar.update(contextWindow: contextWindow)
        }
        await printActiveToolsIfNeeded()
        await renderSavedSessionHistory(activeSessionTranscript)
        await writeSystemMessage(
            "Loaded session: \(savedSession.name) (\(savedSession.messageCount) messages).\n"
        )
    }

    public func renderSavedSessionHistory(_ history: [AgentRuntimeMessage]) async {
        guard Self.savedSessionHistoryHasVisibleContent(history) else {
            return
        }

        await finishThoughtOutputIfNeeded()
        await finishAssistantContentFormatting()
        await writeSystemMessage("\nRestored transcript:\n")
        var renderedToolResultIDs = Set<String>()
        for message in history {
            switch message.role {
            case .user:
                await renderSavedUserMessage(message)
            case .assistant:
                await renderSavedAssistantMessage(
                    message,
                    history: history,
                    renderedToolResultIDs: &renderedToolResultIDs
                )
            case .tool:
                await renderSavedUnmatchedToolResultIfNeeded(
                    message,
                    renderedToolResultIDs: &renderedToolResultIDs
                )
            case .system:
                continue
            }
        }
        await finishThoughtOutputIfNeeded()
        await finishAssistantContentFormatting()
        await writeChatOutput("\n")
    }

    private func renderSavedUserMessage(_ message: AgentRuntimeMessage) async {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return
        }
        await writeSubmittedPrompt(content)
    }

    private func renderSavedAssistantMessage(
        _ message: AgentRuntimeMessage,
        history: [AgentRuntimeMessage],
        renderedToolResultIDs: inout Set<String>
    ) async {
        if let reasoning = message.reasoningContent?.nilIfBlank {
            await writeThought(reasoning)
            await finishThoughtOutputIfNeeded()
        }

        let content = message.content.trimmingCharacters(in: .newlines)
        if !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await writeAssistantContent(content)
            await finishAssistantContentFormatting()
            await writeChatOutput("\n")
        }

        for toolCall in message.toolCalls {
            let directToolCall = Self.directToolCall(from: toolCall)
            if let toolResult = Self.toolResult(
                for: toolCall,
                in: history,
                renderedToolResultIDs: &renderedToolResultIDs
            ) {
                await writeToolCallCompleted(directToolCall, result: toolResult)
            } else {
                await writeToolCallStarted(directToolCall)
            }
        }
    }

    private func renderSavedUnmatchedToolResultIfNeeded(
        _ message: AgentRuntimeMessage,
        renderedToolResultIDs: inout Set<String>
    ) async {
        let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return
        }
        let toolCallID = message.toolCallID ?? "restored-tool-\(UUID().uuidString.lowercased())"
        guard renderedToolResultIDs.insert(toolCallID).inserted else {
            return
        }

        let toolCall = DirectAgentToolCall(
            id: toolCallID,
            name: message.toolName ?? "tool.result",
            argumentsObject: [:],
            argumentsJSON: "{}"
        )
        await writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(
                output: content,
                summary: Self.savedToolResultSummary(content)
            )
        )
    }

    private static func savedSessionHistoryHasVisibleContent(
        _ history: [AgentRuntimeMessage]
    ) -> Bool {
        history.contains { message in
            switch message.role {
            case .user, .tool:
                return message.content.nilIfBlank != nil
            case .assistant:
                return message.content.nilIfBlank != nil
                    || message.reasoningContent?.nilIfBlank != nil
                    || !message.toolCalls.isEmpty
            case .system:
                return false
            }
        }
    }

        static func directToolCall(
        from toolCall: AgentRuntimeToolCall
    ) -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: toolCall.id ?? "restored-tool-\(UUID().uuidString.lowercased())",
            name: toolCall.name,
            argumentsObject: toolArgumentsObject(from: toolCall.argumentsJSON),
            argumentsJSON: toolCall.argumentsJSON
        )
    }

    private static func toolArgumentsObject(from argumentsJSON: String) -> [String: Any] {
        DirectToolExecutor.toolArguments(from: argumentsJSON)
            .mapValues(\.jsonObject)
    }


    private static func toolResult(
        for toolCall: AgentRuntimeToolCall,
        in history: [AgentRuntimeMessage],
        renderedToolResultIDs: inout Set<String>
    ) -> DirectAgentToolResult? {
        guard let toolCallID = toolCall.id else {
            return nil
        }
        guard let message = history.first(where: {
            $0.role == .tool && $0.toolCallID == toolCallID
        }) else {
            return nil
        }
        guard renderedToolResultIDs.insert(toolCallID).inserted else {
            return nil
        }
        return DirectAgentToolResult(
            output: message.content,
            summary: savedToolResultSummary(message.content)
        )
    }

    private static func savedToolResultSummary(_ output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank ?? "restored tool output"
    }

    public static func savedSessionDisplayHistory(
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

    private static func compactionSummaryDisplayText(
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

    public func renderSavedSessionList(_ sessions: [TerminalSavedSession]) async {
        await writeSystemMessage("\nSaved sessions:\n")
        for (offset, session) in sessions.enumerated() {
            let marker = activeSavedSessionName == session.name ? " *" : ""
            await writeSystemMessage(
                "  \(offset + 1). \(session.name) - \(savedSessionDetail(session))\(marker)\n"
            )
        }
        await writeSystemMessage("\n")
    }

    public func savedSessionSelectionItems(
        _ sessions: [TerminalSavedSession]
    ) -> [TerminalCheckboxMenuItem<String>] {
        sessions.map { session in
            TerminalCheckboxMenuItem(
                value: session.name,
                title: session.name,
                detail: savedSessionDetail(session)
            )
        }
    }

    public func savedSessionDetail(_ session: TerminalSavedSession) -> String {
        var parts: [String] = []
        if let modelID = session.modelID {
            parts.append(modelID)
        }
        parts.append("\(session.messageCount) messages")
        if let usedTokens = session.contextWindow?.usedTokens {
            parts.append("ctx \(Self.savedSessionTokenCountText(usedTokens))")
        }
        parts.append("saved \(Self.savedSessionTimestamp(session.savedAt))")
        return parts.joined(separator: " · ")
    }

    public func restoredAgent(
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

    public static func renderSessionSelectionUsage() -> String {
        """
        Usage: /sessions                    List and select saved sessions
               /sessions <name>             Save or overwrite a named snapshot
               /sessions save               Save the current session
               /sessions new                Start a new session
               /sessions compact            Compact context
               /sessions delete             Delete a session
               /sessions tree               Show the checkpoint tree
               /sessions branches           List branches (leaves)
               /sessions checkpoint [label] Create a checkpoint
               /sessions restore [id|index] Restore in-place from a checkpoint
                                            (interactive picker when omitted)
        """
    }

    // MARK: - Checkpoint tree operations

    /// Renders the checkpoint tree of the active (or given) saved session as
    /// an indented text outline for display in the TUI.
    public func renderCheckpointTree(
        for savedSession: TerminalSavedSession? = nil
    ) -> String {
        let tree: SessionCheckpointTree
        if let savedSession {
            tree = savedSession.checkpointTree
        } else if let activeCheckpointTree {
            tree = activeCheckpointTree
        } else {
            return "No checkpoint tree available. Save the session first with /sessions save."
        }
        let header = "Session checkpoint tree (\(tree.branches.count) branch(es), \(tree.entries.count) entries):\n"
        return header + tree.treeDescription()
    }

    /// Displays the checkpoint tree in the terminal.
    public func displayCheckpointTree(
        for savedSession: TerminalSavedSession? = nil
    ) async {
        let output = renderCheckpointTree(for: savedSession)
        await writeSystemMessage("\n\(output)\n")
    }

    /// Creates a manual checkpoint at the current position in the active
    /// session's tree.
    public func createCheckpoint(label: String?) async {
        if activeCheckpointTree == nil {
            activeCheckpointTree = SessionCheckpointTree.fromLinearHistory(
                activeSessionTranscript,
                sessionID: sessionID
            )
        }
        guard var tree = activeCheckpointTree else { return }
        let entry = tree.append(.checkpoint(label: label?.nilIfBlank))
        activeCheckpointTree = tree
        let labelDisplay = label?.nilIfBlank ?? "unnamed"
        await writeSystemMessage(
            "Checkpoint created: \(labelDisplay) (id: \(entry.id)).\n"
        )
    }

    /// Restores the session from a specific checkpoint entry, branching from
    /// that point.  Subsequent messages will form a new branch in the tree.
    public func restoreFromCheckpoint(
        _ savedSession: TerminalSavedSession,
        entryID: String
    ) async throws {
        let tree = savedSession.checkpointTree
        guard tree.entry(id: entryID) != nil else {
            await writeFailureMessage(
                "Checkpoint entry \(entryID) not found in session \(savedSession.name).\n"
            )
            return
        }
        try await loadSavedSession(savedSession, checkpointEntryID: entryID)
        let messageCount = activeSessionTranscript.filter { $0.role != .system }.count
        await writeSystemMessage(
            "Restored from checkpoint \(entryID) (\(messageCount) messages on this branch).\n"
        )
    }

    /// Lists all branches (leaves) in the active or given session's tree.
    public func listBranches(
        for savedSession: TerminalSavedSession? = nil
    ) async {
        let tree: SessionCheckpointTree
        if let savedSession {
            tree = savedSession.checkpointTree
        } else if let activeCheckpointTree {
            tree = activeCheckpointTree
        } else {
            await writeSystemMessage("No checkpoint tree available.\n")
            return
        }
        let branches = tree.branches
        await writeSystemMessage("\nBranches (\(branches.count)):\n")
        for (offset, branch) in branches.enumerated() {
            let active = branch.leafID == tree.activeLeafID ? " *" : ""
            let labelPart = branch.label.map { " [\($0)]" } ?? ""
            await writeSystemMessage(
                "  \(offset + 1).\(active)\(labelPart) \(branch.messageCount) msgs — \(branch.preview)\n"
            )
        }
        await writeSystemMessage("\n")
    }

}
