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
        try await sessionRunner.createSession(
            configuration: await currentSessionConfiguration(
                discoverExternalTools: discoverExternalTools
            )
        )
        await sessionRunner.updatePromptSkillSelection(
            selectedPromptSkills(),
            sessionID: sessionID
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
        let effectiveAllowedToolNames = allowedToolNamesIncludingSelectedPromptSkills(
            allowedToolNames
        )
        let promptSections: SystemPromptSections
        if let restoredSystemPrompt = activeSessionSystemPromptOverride?.nilIfBlank {
            // Older saved sessions contain one combined prompt. Keep that
            // legacy representation intact, while new snapshots carry the
            // dynamic part explicitly and can retain a stable system prefix.
            promptSections = SystemPromptSections(
                systemPrompt: SystemPromptBuilder.replacingSelectedSkillSection(
                    in: restoredSystemPrompt
                ),
                dynamicContext: activeSessionDynamicContextOverride ?? ""
            )
        } else {
            promptSections = currentPromptSections(
                allowedToolNames: effectiveAllowedToolNames
            )
        }
        let dynamicContext = includesActivePlanProgress
            ? systemPromptWithActivePlanProgress(promptSections.dynamicContext)
            : promptSections.dynamicContext
        return AgentCoreSessionConfigurationBuilder(
            sessionID: sessionID,
            modelID: currentEffectiveModelID(),
            agentID: selectedAgent?.id,
            agentName: selectedAgent?.name,
            workingDirectory: configuration.workingDirectory,
            systemPrompt: promptSections.systemPrompt,
            dynamicContext: dynamicContext,
            cacheKey: activeSessionCacheKey ?? sessionID,
            sessionRevision: 0,
            history: activeSessionHistory,
            allowedToolNames: effectiveAllowedToolNames,
            maxToolRounds: configuration.maxToolRounds,
            maxOutputTokens: configuration.maxOutputTokens,
            verboseLogging: configuration.verboseLogging,
            appMode: configuration.appMode,
            thinkingSelection: currentAgentThinkingSelection(),
            preserveThinking: false
        )
        .makeConfiguration()
    }

    private func allowedToolNamesIncludingSelectedPromptSkills(
        _ allowedToolNames: Set<String>
    ) -> Set<String> {
        let allowedToolNames = AgentSessionComposition.allowedToolNamesIncludingIntrinsicSkillTools(
            allowedToolNames
        )
        return selectedAgent?.resolvedAllowedToolNames(allowedToolNames)
            ?? allowedToolNames
    }

    public func currentSystemPrompt(allowedToolNames: Set<String>) -> String {
        currentPromptSections(allowedToolNames: allowedToolNames).combinedPrompt
    }

    public func currentPromptSections(
        allowedToolNames: Set<String>
    ) -> SystemPromptSections {
        AgentSessionComposition.standardPromptSections(
            cwd: configuration.workingDirectory.path,
            allowedToolNames: allowedToolNames,
            selectedAgent: selectedAgent,
            locksModelToSession: configuration.hostedAgentProfiles != nil,
            responseLanguageSection: responseLanguageSystemPromptSection()
        )
    }

    func systemPromptWithActivePlanProgress(_ baseSystemPrompt: String?) -> String? {
        guard let plan = activePlan,
              plan.isApproved,
              !plan.isCompleted,
              !plan.points.isEmpty else {
            return baseSystemPrompt
        }
        let pointList = plan.points.map { point in
            "- \(point.id) [\(point.status.rawValue)]: \(point.text)"
        }.joined(separator: "\n")
        let progressSection = """

            Active approved plan progress:
            Goal: \(plan.originalGoal)
            \(pointList)

            The task graph is the authoritative control plane for this approved plan. Use this
            progress snapshot to choose and report the current plan work; the common task workflow
            policy in the session context governs graph operations and delegation.
            """
        guard let baseSystemPrompt = baseSystemPrompt?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !baseSystemPrompt.isEmpty else {
            return progressSection.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return baseSystemPrompt + "\n\n" + progressSection.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
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
        let effectiveModelID = currentEffectiveModelID()
        let selectedBinding: AgentModelBinding?
        if let model = effectiveModelID.flatMap({ modelID in
            availableModelManifests().first { $0.matches(modelID) }
        }) {
            selectedBinding = selectedAgentModelBinding(for: model)
        } else {
            selectedBinding = selectedAgent?.modelBinding(matching: effectiveModelID)
        }

        // The default binding informs a profile only when the user did not
        // explicitly choose another model. Its thinking setting must not leak
        // onto an independent `/models` choice.
        let effectiveBinding = selectedBinding
            ?? (manualModelIDOverride == nil
                ? selectedAgent?.defaultModelBinding
                : nil)
        return Self.effectiveThinkingSelection(
            manualThinkingSelectionOverride: manualThinkingSelectionOverride,
            hostedModel: hostedModelManifest(for: effectiveModelID),
            explicitModelID: manualModelIDOverride,
            agentModelID: effectiveBinding?.modelID,
            agentThinkingSelection: effectiveBinding?.thinkingSelection
        )
    }

    public nonisolated static func effectiveThinkingSelection(
        manualThinkingSelectionOverride: AgentThinkingSelection?,
        hostedModel: AgentSettingsModelManifest?,
        explicitModelID: String?,
        agentModelID: String?,
        agentThinkingSelection: AgentThinkingSelection? = nil,
        manifest: AgentSettingsManifest? = AgentSettingsManifestStore.load()
    ) -> AgentThinkingSelection? {
        if let manualThinkingSelectionOverride {
            return manualThinkingSelectionOverride
        }
        if let hostedModel {
            return hostedModel.thinkingSelection(for: agentThinkingSelection)
        }
        return AgentSettingsStore.thinkingSelection(
            requestedSelection: nil,
            explicitModelID: explicitModelID,
            agentModelID: agentModelID,
            agentThinkingSelection: agentThinkingSelection,
            manifest: manifest
        )
    }

    public func hostedModelManifest(
        for modelID: String?
    ) -> AgentSettingsModelManifest? {
        guard let modelID,
              let hostedModels = configuration.hostedModels else {
            return nil
        }
        return hostedModels.first { $0.matches(modelID) }
    }

    public func selectedAllowedToolNames(
        discoverExternalTools: Bool = true
    ) async -> Set<String> {
        let intrinsicToolNames = intrinsicAllowedToolNamesForSelectedAgent()
        let baseItems = await toolSelectionItems()
        guard !selectedToolKeys.isEmpty else {
            return allowedToolNamesIncludingSelectedPromptSkills(
                intrinsicToolNames
            )
        }

        selectedToolKeys = TerminalToolSelectionCatalog.normalizedSelectionKeys(
            selectedToolKeys,
            items: baseItems
        )
        _ = discoverExternalTools
        let items = baseItems
        var allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedToolKeys,
            items: items
        )
        allowedToolNames.formUnion(intrinsicToolNames)
        return allowedToolNamesIncludingSelectedPromptSkills(allowedToolNames)
    }

    @discardableResult
    public func updateCurrentSessionToolOptions(
        discoverExternalTools: Bool = true
    ) async -> Set<String> {
        let previousSnapshot = await sessionRunner.snapshotSession(id: sessionID)
        let previousAllowedToolNames = previousSnapshot?.allowedToolNames
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: discoverExternalTools
        )
        do {
            if previousSnapshot != nil, previousAllowedToolNames != .some(allowedToolNames) {
                activeSessionCacheKey = previousSnapshot?.cacheKey ?? activeSessionCacheKey
                activeSessionHistory = previousSnapshot?.history ?? activeSessionHistory
                if !activeSessionHistory.isEmpty {
                    activeSessionHistory.append(
                        Self.toolSelectionChangedMessage(
                            previousAllowedToolNames: previousAllowedToolNames ?? [],
                            currentAllowedToolNames: allowedToolNames
                        )
                    )
                }
                await sessionRunner.rebuildSession(id: sessionID)
                try await sessionRunner.createSession(
                    configuration: currentSessionConfiguration(
                        allowedToolNames: allowedToolNames
                    )
                )
            } else {
                try await sessionRunner.updateSessionOptions(
                    configuration: currentSessionConfiguration(
                        allowedToolNames: allowedToolNames
                    )
                )
            }
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
        didPrintActiveTools = false
        return allowedToolNames
    }

    public func ensureWorkspaceAccessIfNeeded() async {
        let items = await toolSelectionItems()
        let workspaceSelectionKeys = TerminalToolSelectionCatalog.workspaceAccessSelectionKeys(
            for: selectedToolKeys,
            items: items
        )
        guard stdinIsTerminal,
              !configuration.appMode,
              !workspaceSelectionKeys.isEmpty else {
            return
        }

        #if os(macOS)
        let granted = await TerminalWorkspaceToolAccessStore.shared.ensureAccess(
            for: configuration.workingDirectory
        )
        guard !granted else {
            return
        }

        selectedToolKeys.subtract(workspaceSelectionKeys)
        let disabledToolNames = items
            .filter { workspaceSelectionKeys.contains($0.key) }
            .map(\.title)
            .joined(separator: ", ")
        await writeSystemMessage(
            """
            Workspace access was not granted for \(configuration.workingDirectory.path).
            Disabled tools: \(disabledToolNames).

            """
        )
        #endif
    }

    public nonisolated static func toolSelectionChangedMessage(
        previousAllowedToolNames: Set<String>,
        currentAllowedToolNames: Set<String>
    ) -> AgentRuntimeMessage {
        let addedToolNames = currentAllowedToolNames.subtracting(previousAllowedToolNames)
        let removedToolNames = previousAllowedToolNames.subtracting(currentAllowedToolNames)
        let currentTools = toolSelectionChangedToolList(currentAllowedToolNames)
        let addedTools = toolSelectionChangedToolList(addedToolNames)
        let removedTools = toolSelectionChangedToolList(removedToolNames)

        return AgentRuntimeMessage(
            role: .system,
            content: """
            Tool selection changed during this session.
            Current available tool names: \(currentTools).
            Added tool names: \(addedTools).
            Removed tool names: \(removedTools).
            Only call tools currently exposed by the native tool interface. Treat earlier calls or results for removed tools as historical context, not as available capabilities.
            """
        )
    }

    private nonisolated static func toolSelectionChangedToolList(_ toolNames: Set<String>) -> String {
        let names = toolNames
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
        guard !names.isEmpty else {
            return "none"
        }
        return names.joined(separator: ", ")
    }
}
