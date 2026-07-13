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
import XcodeToolsFeature

extension TerminalChat {
    public func createCurrentSession(
        discoverExternalTools: Bool = true
    ) async throws {
        try await sessionRunner.createSession(
            configuration: await currentSessionConfiguration(
                discoverExternalTools: discoverExternalTools
            )
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
        let baseSystemPrompt = SystemPromptBuilder.appendingTaskOrchestrationSection(
            to: activeSessionSystemPromptOverride?.nilIfBlank
                ?? currentSystemPrompt(allowedToolNames: allowedToolNames),
            allowedToolNames: allowedToolNames
        )
        let systemPrompt = includesActivePlanProgress
            ? systemPromptWithActivePlanProgress(baseSystemPrompt)
            : baseSystemPrompt
        return AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: currentEffectiveModelID(),
            bearerToken: configuration.bearerToken,
            workingDirectory: configuration.workingDirectory,
            systemPrompt: systemPrompt,
            cacheKey: activeSessionCacheKey ?? sessionID,
            sessionRevision: 0,
            history: activeSessionHistory,
            allowedToolNames: allowedToolNames,
            maxToolRounds: configuration.maxToolRounds,
            maxOutputTokens: configuration.maxOutputTokens,
            verboseLogging: configuration.verboseLogging,
            appMode: configuration.appMode,
            thinkingSelection: currentAgentThinkingSelection(),
            preserveThinking: false
        )
    }

    public func currentSystemPrompt(allowedToolNames: Set<String>) -> String {
        let memoryToolEnabled = Self.memoryToolEnabled(allowedToolNames)
        return AgentStandaloneSystemPrompt.prompt(
            cwd: configuration.workingDirectory.path,
            memoryToolEnabled: memoryToolEnabled,
            allowedToolNames: allowedToolNames,
            selectedAgentSection: selectedAgent?.promptSection(memoryToolEnabled: memoryToolEnabled),
                        selectedSkillSection: SystemPromptBuilder.selectedSkillSection(
                skills: selectedPromptSkills()
            ),
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

            The task graph is the authoritative control plane for this approved plan. Call \
            tasks.list with runnableOnly=true before choosing work. Use tasks.update to record \
            direct progress and lifecycle transitions, and pass taskID to agent.create when \
            delegating so attempts are claimed atomically. Read-only report agents may run in \
            parallel, but run only one implementation agent at a time because they share this \
            working directory. Respect dependencies and validate implementation tasks before \
            completing them; checklist tools are not part of plan progress reporting.
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
        Self.effectiveThinkingSelection(
            manualThinkingSelectionOverride: manualThinkingSelectionOverride,
            hostedModel: hostedModelManifest(for: currentEffectiveModelID()),
            explicitModelID: manualModelIDOverride,
            agentModelID: selectedAgent?.modelID,
            agentThinkingSelection: selectedAgent?.thinkingSelection
        )
    }

    public static func effectiveThinkingSelection(
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
            return intrinsicToolNames
        }

        selectedToolKeys = TerminalToolSelectionCatalog.normalizedSelectionKeys(
            selectedToolKeys,
            items: baseItems
        )
        let dynamicToolPrefixes = TerminalToolSelectionCatalog.externalDiscoveryPrefixes(
            for: selectedToolKeys,
            items: baseItems
        )
        let requestedMCPDiscoveryToolNames = Set(
            dynamicToolPrefixes.filter {
                $0 == XcodeToolIntegration.toolPrefix || $0 == "figma."
            }
        )
        let mcpDiscoveryToolNames = ExternalToolAvailability.discoverableToolPrefixes(
            requestedMCPDiscoveryToolNames
        )
        let mcpDescriptors: [DirectToolDescriptor]
        if discoverExternalTools, !mcpDiscoveryToolNames.isEmpty {
            mcpDescriptors = await sessionRunner.mcpToolDescriptors(
                allowedToolNames: mcpDiscoveryToolNames,
                preferredWorkspaceRootURL: configuration.workingDirectory
            )
        } else {
            mcpDescriptors = await sessionRunner.knownMCPToolDescriptors(
                allowedToolNames: requestedMCPDiscoveryToolNames,
                preferredWorkspaceRootURL: configuration.workingDirectory
            )
        }

        let items = await toolSelectionItems(
            additionalDescriptors: mcpDescriptors
        )
        var allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selectedToolKeys,
            items: items
        )
        allowedToolNames.formUnion(intrinsicToolNames)
        return allowedToolNames
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

    public static func toolSelectionChangedMessage(
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

    private static func toolSelectionChangedToolList(_ toolNames: Set<String>) -> String {
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
