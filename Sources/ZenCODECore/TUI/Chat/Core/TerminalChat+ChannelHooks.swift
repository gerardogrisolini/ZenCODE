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
/// attachments, and the overview around `/sessions new`. The hooks are the
/// terminal's slot's: the first step of `/sessions new` and of a saved-session
/// load (``ChatIncarnationChange/newSessionWillStart``,
/// ``ChatIncarnationChange/savedSessionWillLoad``) runs while `chatSession` is
/// still the controller being replaced, whose observer it stops, and the
/// later steps once it is the new one. The conformance is declared with the
/// class, in `TerminalChat.swift`.
extension TerminalChat {
    public func responseLanguageSection() -> String? {
        responseLanguageSystemPromptSection()
    }

    public func agentDidChange(_ agent: AgentProfile) async {
        await interactiveReader.setPanelCommandSuggestions(
            await panelSuggestionsForCurrentAgent()
        )
        resetResponseLanguageLock()
    }

    public func sessionWillCreate(reason: ChatSessionRecreationReason) async {
        printedModelID = nil
        if reason == .agentSwitched {
            didPrintActiveTools = false
        }
        await statusBar.reset()
    }

    public func sessionDidCreate(reason: ChatSessionRecreationReason) async {
        await startTaskGraphObserver()
        await refreshInitialStatusBarContextWindow()
        // The first step of `preloadCurrentModel`, which the controller's
        // preload replaces.
        await refreshStatusBarThinkingSelection()
    }

    public func modelPreloadDidEmit(_ event: DirectAgentEvent) async {
        await handleModelPreloadEvent(event)
    }

    public func modelDidPreload(_ modelID: String, reason: ChatSessionRecreationReason) async {
        // An agent switch preloads as `preloadCurrentModel()` does; a model
        // change as `preloadCurrentModel(emitStatus: hostedModels != nil)`.
        await finishModelPreload(
            modelID,
            emitStatus: reason == .agentSwitched || configuration.hostedModels != nil
        )
    }

    /// The terminal's step of `/sessions new`, of a saved-session load (see
    /// `TerminalChat+Sessions.swift`), or of `/sessions compact`.
    public func incarnationDidChange(reason: ChatIncarnationChange) async {
        switch reason {
        case .newSessionWillStart:
            await stopTaskGraphObserver()
            resetResponseLanguageLock()
        case .newSessionDidStart:
            await startTaskGraphObserver()
            await statusBar.reset()
            await refreshInitialStatusBarContextWindow()
            pendingAttachments.removeAll()
            await renderCoordinator.resetOverview(.subAgents)
            // Before the panel loop rebinds the shared-chat relay to the new room.
            await rebindTelegramTopicToCurrentSession()
        case .savedSessionWillLoad:
            await savedSessionLoadWillStart()
        case .savedSessionWillRestore:
            await savedSessionLoadWillRestore()
        case let .savedSessionDidRestore(transcript, contextWindow):
            await savedSessionLoadDidRestore(transcript: transcript, contextWindow: contextWindow)
        case let .sessionDidCompact(contextWindow):
            _ = await statusBar.update(contextWindow: contextWindow)
        }
    }

    public func responseLanguageShouldLock() {
        lockResponseLanguageIfNeeded()
    }

    // MARK: Command steps

    public func selectionDidApply(_ change: ChatSelectionChange, command: ChatSelectionCommand) async {
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

    public func commandContextWindow() async -> DirectAgentContextWindowStatus? {
        await statusBar.currentContextWindowStatus()
    }
}
