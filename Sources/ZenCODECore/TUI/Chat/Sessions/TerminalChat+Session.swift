//
//  TerminalChat+Session.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 26/05/26.
//

#if canImport(Darwin)

import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import ToolCore
import ZenCODERuntime

extension TerminalChat {
    public func createCurrentSession(
        discoverExternalTools: Bool = true
    ) async throws {
        try await chatSession.createSessionWithSelectedSkills(
            discoverExternalTools: discoverExternalTools
        )
        await startTaskGraphObserver()
    }

    public func currentSessionConfiguration(
        discoverExternalTools: Bool = false
    ) async -> AgentCoreSessionConfiguration {
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: discoverExternalTools
        )
        return currentSessionConfiguration(allowedToolNames: allowedToolNames)
    }

    public func currentSessionConfiguration(
        allowedToolNames: Set<String>,
        includesActivePlanProgress: Bool = true
    ) -> AgentCoreSessionConfiguration {
        chatSession.currentSessionConfiguration(
            allowedToolNames: allowedToolNames,
            includesActivePlanProgress: includesActivePlanProgress,
            responseLanguageSection: responseLanguageSystemPromptSection()
        )
    }

    public func refreshInitialStatusBarContextWindow() async {
        _ = await statusBar.update(agentName: selectedAgent?.displayName)
        await refreshStatusBarThinkingSelection()
        let statusModel = chatSession.statusModel()
        if let modelID = statusModel.modelID {
            _ = await statusBar.update(modelID: modelID)
        }
        if let contextWindow = statusModel.contextWindow {
            _ = await statusBar.update(contextWindow: contextWindow)
        }
    }

    @discardableResult
    func refreshStatusBarThinkingSelection() async -> Bool {
        await statusBar.update(thinkingSelection: currentAgentThinkingSelection())
    }

    public func currentAgentThinkingSelection() -> AgentThinkingSelection? {
        chatSession.currentAgentThinkingSelection()
    }

    public func hostedModelManifest(
        for modelID: String?
    ) -> AgentSettingsModelManifest? {
        chatSession.hostedModelManifest(for: modelID)
    }

    public func selectedAllowedToolNames(
        discoverExternalTools: Bool = true
    ) async -> Set<String> {
        await chatSession.selectedAllowedToolNames(
            discoverExternalTools: discoverExternalTools
        )
    }

    /// Adapter of ``ChatSessionController/updateSessionToolOptions(discoverExternalTools:)``;
    /// the active tools are printed again after the change.
    @discardableResult
    public func updateCurrentSessionToolOptions(
        discoverExternalTools: Bool = true
    ) async -> Set<String> {
        let allowedToolNames = await chatSession.updateSessionToolOptions(
            discoverExternalTools: discoverExternalTools
        )
        didPrintActiveTools = false
        return allowedToolNames
    }

    /// Adapter of ``ChatSessionController/ensureWorkspaceAccess()``.
    public func ensureWorkspaceAccessIfNeeded() async {
        await chatSession.ensureWorkspaceAccess()
    }
}
