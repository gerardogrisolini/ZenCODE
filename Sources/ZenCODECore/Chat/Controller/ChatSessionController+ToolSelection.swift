//
//  ChatSessionController+ToolSelection.swift
//  ZenCODE
//
//  Tool selection: the tool menu, `/tools`, and keeping the running
//  session's tool options in step with the selection.
//

import Foundation

extension ChatSessionController {
    // MARK: - Tools

    /// The tool menu: every tool group, the selected ones ticked.
    func toolChoices() async -> ChatChoiceList {
        let items = await toolSelectionItems()
        return ChatChoiceList(
            title: "Tools",
            items: items.map { item in
                ChatChoiceItem(
                    id: item.key,
                    title: item.title,
                    detail: item.detail,
                    group: item.groupTitle
                )
            },
            selectedIDs: TerminalToolSelectionCatalog.normalizedSelectionKeys(
                selection.toolKeys,
                items: items
            )
        )
    }

    /// `/tools`: asks the host for the tool groups and applies them.
    public func chooseTools() async -> ChatSelectionOutcome {
        guard host.capabilities.contains(.multipleChoice) else {
            return ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(.toolSelection(await activeToolsSummary())),
            ])
        }

        let choices = await toolChoices()
        guard let selectedKeys = await host.chooseMany(
            title: choices.title,
            items: choices.items,
            selectedIDs: choices.selectedIDs
        ) else {
            return ChatSelectionOutcome(notices: [.activeTools(await activeToolsSummary())])
        }
        return await selectTools(keys: selectedKeys)
    }

    /// Selects the tool groups `rawSelection` names (`all`, `none`, names,
    /// packages, numbers).
    public func selectTools(rawSelection: String) async throws -> ChatSelectionOutcome {
        let items = await toolSelectionItems()
        let selectedKeys = try TerminalToolSelectionCatalog.parseSelection(
            rawSelection,
            items: items
        )
        return await selectTools(keys: selectedKeys)
    }

    /// Selects the tool groups `keys` and keeps the session in step: a
    /// changed allowlist rebuilds it (keeping the conversation and telling
    /// the model what changed), otherwise its options are updated.
    public func selectTools(keys: Set<String>) async -> ChatSelectionOutcome {
        let previousKeys = selection.toolKeys
        let items = await toolSelectionItems()
        selection.toolKeys = TerminalToolSelectionCatalog.normalizedSelectionKeys(
            keys,
            items: items
        )
        savedSessionState.systemPromptOverride = nil
        _ = await requestWorkspaceAccessIfNeeded()
        let shouldDiscoverExternalTools = Self.shouldDiscoverExternalTools(
            previousKeys: previousKeys,
            selectedKeys: selection.toolKeys,
            items: items
        )
        await presentSessionStateChanged()
        let update = await updateSessionToolOptionsReportingChange(
            discoverExternalTools: shouldDiscoverExternalTools
        )
        let activeToolNames = await resolvedActiveToolNames(
            fallbackAllowedToolNames: update.allowedToolNames
        )
        let renderItems = await toolSelectionItems()
        return ChatSelectionOutcome(
            change: update.change,
            notices: [
                .activeTools(
                    ChatActiveToolsSummary(
                        toolNames: activeToolNames,
                        items: renderItems,
                        selectedKeys: selection.toolKeys
                    )
                ),
            ]
        )
    }

    /// The tool groups the session exposes now, as the terminal's startup
    /// summary and `/tools` list them.
    public func activeToolsSummary() async -> ChatActiveToolsSummary {
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: false
        )
        let activeToolNames = await resolvedActiveToolNames(
            fallbackAllowedToolNames: allowedToolNames
        )
        let items = await toolSelectionItems()
        return ChatActiveToolsSummary(
            toolNames: activeToolNames,
            items: items,
            selectedKeys: selection.toolKeys
        )
    }

    /// Uses the backend's resolved descriptor set so runtime-discovered
    /// feature prefixes such as `git.` are not presented as active groups
    /// with zero tools.
    func resolvedActiveToolNames(
        fallbackAllowedToolNames: Set<String>
    ) async -> [String] {
        let activeDescriptors = await managementRuntime?.activeToolDescriptors(
            sessionID: sessionID
        ) ?? []
        return Self.resolvedActiveToolNames(
            fallbackAllowedToolNames: fallbackAllowedToolNames,
            activeDescriptors: activeDescriptors
        )
    }

    nonisolated static func resolvedActiveToolNames(
        fallbackAllowedToolNames: Set<String>,
        activeDescriptors: [DirectToolDescriptor]
    ) -> [String] {
        let activeToolNames = Set(activeDescriptors.map(\.name))
        return (activeToolNames.isEmpty ? fallbackAllowedToolNames : activeToolNames)
            .sorted()
    }

    nonisolated static func shouldDiscoverExternalTools(
        previousKeys: Set<String>,
        selectedKeys: Set<String>,
        items: [TerminalToolSelectionItem]
    ) -> Bool {
        let previousPrefixes = TerminalToolSelectionCatalog.externalDiscoveryPrefixes(
            for: previousKeys,
            items: items
        )
        let selectedPrefixes = TerminalToolSelectionCatalog.externalDiscoveryPrefixes(
            for: selectedKeys,
            items: items
        )
        return !selectedPrefixes.subtracting(previousPrefixes).isEmpty
    }

    /// Applies the current tool selection to the running session and returns
    /// the allowed tool names. A changed allowlist rebuilds the session,
    /// keeping its conversation; otherwise its options are updated. A runtime
    /// failure is presented, not thrown.
    @discardableResult
    func updateSessionToolOptions(
        discoverExternalTools: Bool = true
    ) async -> Set<String> {
        await updateSessionToolOptionsReportingChange(
            discoverExternalTools: discoverExternalTools
        ).allowedToolNames
    }

    func updateSessionToolOptionsReportingChange(
        discoverExternalTools: Bool
    ) async -> (allowedToolNames: Set<String>, change: ChatSelectionChange) {
        let previousSnapshot = await managementRuntime?.snapshotSession(id: sessionID)
        let previousAllowedToolNames = previousSnapshot?.allowedToolNames
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: discoverExternalTools
        )
        guard let managementRuntime else {
            return (allowedToolNames, .sessionUpdated)
        }

        let rebuildsSession = previousSnapshot != nil
            && previousAllowedToolNames != .some(allowedToolNames)
        do {
            if rebuildsSession {
                cacheKey = previousSnapshot?.cacheKey ?? cacheKey
                history = previousSnapshot?.history ?? history
                if !history.isEmpty {
                    history.append(
                        Self.toolSelectionChangedMessage(
                            previousAllowedToolNames: previousAllowedToolNames ?? [],
                            currentAllowedToolNames: allowedToolNames
                        )
                    )
                }
                await managementRuntime.rebuildSession(id: sessionID)
                try await managementRuntime.createSession(
                    configuration: currentSessionConfiguration(
                        allowedToolNames: allowedToolNames,
                        responseLanguageSection: channelResponseLanguageSection()
                    )
                )
                // The rebuild dropped the session's prompt-skill provider.
                await managementRuntime.updatePromptSkillSelection(
                    selectedPromptSkills(),
                    sessionID: sessionID
                )
            } else {
                try await managementRuntime.updateSessionOptions(
                    configuration: currentSessionConfiguration(
                        allowedToolNames: allowedToolNames,
                        responseLanguageSection: channelResponseLanguageSection()
                    )
                )
            }
        } catch {
            await effectivePresenter(for: nil).presentSessionNotice(
                .operationFailed(description: error.localizedDescription)
            )
        }
        return (allowedToolNames, rebuildsSession ? .sessionRecreated : .sessionUpdated)
    }

    nonisolated static func toolSelectionChangedMessage(
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

    private nonisolated static func toolSelectionChangedToolList(
        _ toolNames: Set<String>
    ) -> String {
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
