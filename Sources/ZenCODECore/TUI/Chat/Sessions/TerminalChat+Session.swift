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

    public func currentSystemPrompt(allowedToolNames: Set<String>) -> String {
        chatSession.currentSystemPrompt(
            allowedToolNames: allowedToolNames,
            responseLanguageSection: responseLanguageSystemPromptSection()
        )
    }

    public func currentPromptSections(
        allowedToolNames: Set<String>
    ) -> SystemPromptSections {
        chatSession.currentPromptSections(
            allowedToolNames: allowedToolNames,
            responseLanguageSection: responseLanguageSystemPromptSection()
        )
    }

    /// See ``ChatSessionController/launchFolderProjectsForSelectedAgent()``.
    func launchFolderProjectsForSelectedAgent() -> LaunchFolderProjects? {
        chatSession.launchFolderProjectsForSelectedAgent()
    }

    func systemPromptWithActivePlanProgress(_ baseSystemPrompt: String?) -> String? {
        chatSession.systemPromptWithActivePlanProgress(baseSystemPrompt)
    }

    public func refreshInitialStatusBarContextWindow() async {
        await refreshStatusBarThinkingSelection()
        let effectiveModelID = currentEffectiveModelID()
        if let hostedModel = hostedModelManifest(for: effectiveModelID) {
            _ = await statusBar.update(modelID: hostedModel.modelID)
            guard let maxTokens = hostedModel.configuredContextWindowLimit else {
                return
            }
            _ = await statusBar.update(
                contextWindow: DirectAgentContextWindowStatus(
                    usedTokens: nil,
                    maxTokens: maxTokens,
                    modelID: hostedModel.modelID,
                    isApproximate: true
                )
            )
            return
        }

        guard let selection = AgentSettingsStore.defaultSelection(
            explicitModelID: effectiveModelID
        ) else {
            if let effectiveModelID {
                _ = await statusBar.update(modelID: effectiveModelID)
            }
            return
        }

        _ = await statusBar.update(modelID: selection.modelID)
        guard let maxTokens = selection.configuredContextWindowLimit else {
            return
        }

        _ = await statusBar.update(
            contextWindow: DirectAgentContextWindowStatus(
                usedTokens: nil,
                maxTokens: maxTokens,
                modelID: selection.modelID,
                isApproximate: true
            )
        )
    }

    @discardableResult
    func refreshStatusBarThinkingSelection() async -> Bool {
        await statusBar.update(thinkingSelection: currentAgentThinkingSelection())
    }

    public func currentAgentThinkingSelection() -> AgentThinkingSelection? {
        chatSession.currentAgentThinkingSelection()
    }

    public nonisolated static func effectiveThinkingSelection(
        manualThinkingSelectionOverride: AgentThinkingSelection?,
        hostedModel: AgentSettingsModelManifest?,
        explicitModelID: String?,
        agentModelID: String?,
        agentThinkingSelection: AgentThinkingSelection? = nil,
        manifest: AgentSettingsManifest? = AgentSettingsManifestStore.load()
    ) -> AgentThinkingSelection? {
        ChatSessionController.effectiveThinkingSelection(
            manualThinkingSelectionOverride: manualThinkingSelectionOverride,
            hostedModel: hostedModel,
            explicitModelID: explicitModelID,
            agentModelID: agentModelID,
            agentThinkingSelection: agentThinkingSelection,
            manifest: manifest
        )
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

    public nonisolated static func toolSelectionChangedMessage(
        previousAllowedToolNames: Set<String>,
        currentAllowedToolNames: Set<String>
    ) -> AgentRuntimeMessage {
        ChatSessionController.toolSelectionChangedMessage(
            previousAllowedToolNames: previousAllowedToolNames,
            currentAllowedToolNames: currentAllowedToolNames
        )
    }
}
