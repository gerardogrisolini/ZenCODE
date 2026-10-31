//
//  TerminalChat+Sessions.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// What `/sessions` does: the shared action.
typealias TerminalSavedSessionCommandAction = ChatSavedSessionCommandAction

extension TerminalChat {
    /// `/sessions`: adapter of ``ChatSessionController/runSessionsCommand(line:)``.
    public func handleSessionsCommand(_ command: String) async {
        await writeSessionNotices(await chatSession.runSessionsCommand(line: command).notices)
    }

    /// Resets the runtime conversation and starts a fresh, unsaved session.
    /// Replaces the former `/clear` command. Adapter of
    /// ``ChatSessionController/newSessionCommand()``; the terminal's steps
    /// around the new session run in ``sessionWillStartNew()`` and
    /// ``sessionDidStartNew()``.
    public func startNewSession() async {
        await writeSessionNotices(await chatSession.newSessionCommand().notices)
    }

    /// `/sessions`: adapter of ``ChatSessionController/savedSessionListCommand()``.
    public func handleSavedSessionList() async {
        await writeSessionNotices(await chatSession.savedSessionListCommand().notices)
    }

    /// `/sessions delete`: adapter of
    /// ``ChatSessionController/savedSessionDeleteCommand()``.
    public func handleSavedSessionDelete() async {
        await writeSessionNotices(await chatSession.savedSessionDeleteCommand().notices)
    }

    /// `/sessions save`: adapter of
    /// ``ChatSessionController/saveActiveSessionCommand()``, with the context
    /// window of the status bar (``commandContextWindow()``).
    public func saveActiveSession() async {
        await writeSessionNotices(await chatSession.saveActiveSessionCommand().notices)
    }

    /// `/sessions <name>`: adapter of
    /// ``ChatSessionController/saveSessionCommand(named:)``, with the context
    /// window of the status bar (``commandContextWindow()``).
    public func saveCurrentSession(named rawName: String) async {
        await writeSessionNotices(await chatSession.saveSessionCommand(named: rawName).notices)
    }

    /// `/sessions compact`: adapter of
    /// ``ChatSessionController/compactSessionCommand()``; the status bar
    /// bounds the compaction and shows its result
    /// (``sessionDidCompact(contextWindow:)``).
    public func compactCurrentSession() async {
        await writeSessionNotices(await chatSession.compactSessionCommand().notices)
    }

    /// See ``ChatSessionController/recordSavedSessionIndex(_:)``.
    public func recordSavedSessionIndex(_ savedSession: TerminalSavedSession) {
        chatSession.recordSavedSessionIndex(savedSession)
    }

    public func loadSavedSession(_ savedSession: TerminalSavedSession) async throws {
        try await loadSavedSession(savedSession, checkpointEntryID: nil)
    }

    /// Loads a saved session, optionally restoring from a specific checkpoint
    /// entry in the tree.  When `checkpointEntryID` is provided the message
    /// history is rebuilt from the root-to-entry path and a new branch is
    /// started from that entry. Adapter of
    /// ``ChatSessionController/loadSavedSession(_:checkpointEntryID:)``; the
    /// terminal's own steps run in the `savedSession…` hooks.
    public func loadSavedSession(
        _ savedSession: TerminalSavedSession,
        checkpointEntryID: String?
    ) async throws {
        let outcome = try await chatSession.loadSavedSession(
            savedSession,
            checkpointEntryID: checkpointEntryID
        )
        await writeSessionNotices(outcome.notices)
    }

    // MARK: - Saved-session load steps

    /// Before the active session is discarded: the task-graph observer stops
    /// and the response language is decided again for the loaded session.
    func savedSessionWillLoad() async {
        await stopTaskGraphObserver()
        resetResponseLanguageLock()
    }

    /// Before the loaded session's model is loaded: pending input and the
    /// overview are cleared, the active tools and the loaded-model line are
    /// printed again, and the status bar starts over from the loaded
    /// selection.
    func savedSessionWillRestore() async {
        pendingAttachments.removeAll()
        await renderCoordinator.resetOverview(.subAgents)
        await publishSubAgentOverviewIfChanged()
        didPrintActiveTools = false
        printedModelID = nil
        await statusBar.reset()
        await refreshInitialStatusBarContextWindow()
        // The first step of `preloadCurrentModel`, which the controller's
        // preload replaces.
        await refreshStatusBarThinkingSelection()
    }

    /// After the runtime session and its task graph are restored: the
    /// observer is bound to the loaded session, the status bar shows its
    /// saved context window, and its transcript is replayed.
    func savedSessionDidRestore(
        transcript: [AgentRuntimeMessage],
        contextWindow: DirectAgentContextWindowStatus?
    ) async {
        await startTaskGraphObserver()
        if let contextWindow {
            _ = await statusBar.update(contextWindow: contextWindow)
        }
        await printActiveToolsIfNeeded()
        await renderSavedSessionHistory(transcript)
    }

    public func renderSavedSessionHistory(_ history: [AgentRuntimeMessage]) async {
        guard Self.savedSessionHistoryHasVisibleContent(history) else {
            return
        }

        await finishThoughtOutputIfNeeded()
        await finishAssistantContentFormatting()
        await writeSystemMessage("\nRestored transcript:\n")
        let activeDescriptors = await sessionRunner.activeToolDescriptors(
            sessionID: sessionID
        )
        let descriptorsByName = Dictionary(
            activeDescriptors.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var renderedToolResultIDs = Set<String>()
        for message in history {
            switch message.role {
            case .user:
                await renderSavedUserMessage(message)
            case .assistant:
                await renderSavedAssistantMessage(
                    message,
                    history: history,
                    descriptorsByName: descriptorsByName,
                    renderedToolResultIDs: &renderedToolResultIDs
                )
            case .tool:
                await renderSavedUnmatchedToolResultIfNeeded(
                    message,
                    descriptorsByName: descriptorsByName,
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
        descriptorsByName: [String: DirectToolDescriptor],
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
            let directToolCall = Self.directToolCall(
                from: toolCall,
                descriptor: descriptorsByName[toolCall.name]
            )
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
        descriptorsByName: [String: DirectToolDescriptor],
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

        let name = message.toolName ?? "tool.result"
        let descriptor = descriptorsByName[name]
        let toolCall = DirectAgentToolCall(
            id: toolCallID,
            name: name,
            argumentsObject: [:],
            argumentsJSON: "{}",
            descriptorTitle: descriptor?.title,
            presentation: descriptor?.presentation
        )
        await writeToolCallCompleted(
            toolCall,
            result: DirectAgentToolResult(
                output: content,
                summary: Self.savedToolResultSummary(content)
            )
        )
    }

    private nonisolated static func savedSessionHistoryHasVisibleContent(
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

    nonisolated static func directToolCall(
        from toolCall: AgentRuntimeToolCall,
        descriptor: DirectToolDescriptor? = nil
    ) -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: toolCall.id ?? "restored-tool-\(UUID().uuidString.lowercased())",
            name: toolCall.name,
            argumentsObject: toolArgumentsObject(from: toolCall.argumentsJSON),
            argumentsJSON: toolCall.argumentsJSON,
            descriptorTitle: descriptor?.title,
            presentation: descriptor?.presentation
        )
    }

    private nonisolated static func toolArgumentsObject(from argumentsJSON: String) -> [String: Any] {
        DirectToolExecutor.toolArguments(from: argumentsJSON)
            .mapValues(\.jsonObject)
    }


    private nonisolated static func toolResult(
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

    private nonisolated static func savedToolResultSummary(_ output: String) -> String {
        output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfBlank ?? "restored tool output"
    }

    /// See ``ChatSessionController/savedSessionDisplayHistory(_:)``.
    public nonisolated static func savedSessionDisplayHistory(
        _ savedSession: TerminalSavedSession
    ) -> [AgentRuntimeMessage] {
        ChatSessionController.savedSessionDisplayHistory(savedSession)
    }

    public func renderSavedSessionList(_ sessions: [TerminalSavedSession]) async {
        await writeSessionNotice(
            .savedSessions(
                sessions.map(ChatSavedSessionSummary.init),
                activeName: activeSavedSessionName
            )
        )
    }

    public func savedSessionSelectionItems(
        _ sessions: [TerminalSavedSession]
    ) -> [TerminalCheckboxMenuItem<String>] {
        TerminalInteractionHost.menuItems(
            ChatSessionController.savedSessionChoiceItems(sessions)
        )
    }

    public func savedSessionDetail(_ session: TerminalSavedSession) -> String {
        ChatSessionNoticeText.savedSessionDetail(ChatSavedSessionSummary(session))
    }

    /// See ``ChatSessionController/restoredAgent(for:)``.
    public func restoredAgent(
        for savedSession: TerminalSavedSession
    ) throws -> AgentProfile? {
        try chatSession.restoredAgent(for: savedSession)
    }

    public nonisolated static func renderSessionSelectionUsage() -> String {
        ChatSessionNoticeText.text(for: .sessionSelectionUsage)
    }

    // MARK: - Checkpoint tree operations

    /// Restores the session from a specific checkpoint entry, branching from
    /// that point.  Subsequent messages will form a new branch in the tree.
    /// Adapter of ``ChatSessionController/restoreFromCheckpoint(_:entryID:)``.
    public func restoreFromCheckpoint(
        _ savedSession: TerminalSavedSession,
        entryID: String
    ) async throws {
        let outcome = try await chatSession.restoreFromCheckpoint(
            savedSession,
            entryID: entryID
        )
        await writeSessionNotices(outcome.notices)
    }
}
