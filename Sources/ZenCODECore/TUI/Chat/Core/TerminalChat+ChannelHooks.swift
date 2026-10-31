//
//  TerminalChat+ChannelHooks.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation

/// The terminal's own steps between the steps of a selection operation: the
/// panel suggestions and the response-language lock follow the agent, the
/// status bar and the loaded-model line follow the session, and the task-graph
/// observer is bound to each new session. An approved plan locks the response
/// language before its implementation turn. The steps of the shared slash
/// commands are the ones the terminal's command handlers ran: the status bar
/// after a selection, and the observer, the status bar, the staged
/// attachments, and the overview around `/sessions new`.
extension TerminalChat: ChatSessionChannelHooks {
    func responseLanguageSection() -> String? {
        responseLanguageSystemPromptSection()
    }

    func agentDidChange(_ agent: AgentProfile) async {
        await interactiveReader.setPanelCommandSuggestions(
            await panelSuggestionsForCurrentAgent()
        )
        resetResponseLanguageLock()
    }

    func sessionWillCreate(reason: ChatSessionRecreationReason) async {
        printedModelID = nil
        if reason == .agentSwitched {
            didPrintActiveTools = false
        }
        await statusBar.reset()
    }

    func sessionDidCreate(reason: ChatSessionRecreationReason) async {
        await startTaskGraphObserver()
        await refreshInitialStatusBarContextWindow()
        // The first step of `preloadCurrentModel`, which the controller's
        // preload replaces.
        await refreshStatusBarThinkingSelection()
    }

    func modelPreloadDidEmit(_ event: DirectAgentEvent) async {
        await handleModelPreloadEvent(event)
    }

    func modelDidPreload(_ modelID: String, reason: ChatSessionRecreationReason) async {
        // An agent switch preloads as `preloadCurrentModel()` does; a model
        // change as `preloadCurrentModel(emitStatus: hostedModels != nil)`.
        await finishModelPreload(
            modelID,
            emitStatus: reason == .agentSwitched || configuration.hostedModels != nil
        )
    }

    func responseLanguageShouldLock() {
        lockResponseLanguageIfNeeded()
    }

    // MARK: Command steps

    func selectionDidApply(_ change: ChatSelectionChange, command: ChatSelectionCommand) async {
        switch command {
        case .models:
            // A new model's session already went through the session hooks.
            guard change == .sessionUpdated else {
                return
            }
            await statusBar.reset()
            await refreshInitialStatusBarContextWindow()
        case .thinking:
            await refreshStatusBarThinkingSelection()
        case .skills:
            await statusBar.reset()
            await refreshInitialStatusBarContextWindow()
        case .tools:
            // An applied selection has printed the active tools.
            didPrintActiveTools = true
        case .agents:
            break
        }
    }

    func commandContextWindow() async -> DirectAgentContextWindowStatus? {
        await statusBar.currentContextWindowStatus()
    }

    func newSessionID() -> String? {
        Self.newTerminalSessionID()
    }

    func sessionWillStartNew() async {
        await stopTaskGraphObserver()
        resetResponseLanguageLock()
    }

    func sessionDidStartNew() async {
        await startTaskGraphObserver()
        await statusBar.reset()
        await refreshInitialStatusBarContextWindow()
        pendingAttachments.removeAll()
        await renderCoordinator.resetOverview(.subAgents)
    }

    func sessionDidCompact(contextWindow: DirectAgentContextWindowStatus) async {
        _ = await statusBar.update(contextWindow: contextWindow)
    }
}
