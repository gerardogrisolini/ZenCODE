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
/// observer is bound to each new session.
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
}
