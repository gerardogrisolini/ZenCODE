//
//  ChatSessionController+Selection.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// The selection commands shared by every channel: model, thinking level,
/// agent (with the project's agent association), tools, and prompt skills.
///
/// Each `choose…` operation asks the ``ChatInteractionHost`` with a menu when
/// the host has the capability, and otherwise returns the non-interactive
/// notice (``ChatSessionNotice/requiresInteractiveHost(_:)``). Each `select…`
/// operation applies a choice, keeps the runtime session in step with it, and
/// returns a ``ChatSelectionOutcome`` with the closing notices; notices raised
/// while it runs go to the presenter as they happen. A channel's own steps
/// between the runtime steps run through ``ChatSessionController/channelHooks``.
///
/// Model and thinking choices persist as the user's defaults through
/// ``ChatModelCatalog`` (unless the host supplies its own models); the
/// project's agent association is saved per project; tools and skills are
/// session state.
extension ChatSessionController {
    // MARK: - Session state

    /// The selection and the saved-session link, as channels mirror them.
    var sessionState: ChatSessionState {
        ChatSessionState(selection: selection, savedSession: savedSessionState)
    }

    func presentSessionStateChanged() async {
        await presenter.presentSessionStateChanged(sessionState)
    }

    // MARK: - Runtime steps

    /// The channel's response-language section, read where a composition
    /// needs it.
    func channelResponseLanguageSection() -> String? {
        channelHooks?.responseLanguageSection()
    }

    /// The session configuration for the current selection, with the
    /// channel's response-language section read after the tool catalog.
    func composedSessionConfiguration(
        discoverExternalTools: Bool
    ) async -> AgentCoreSessionConfiguration {
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: discoverExternalTools
        )
        return currentSessionConfiguration(
            allowedToolNames: allowedToolNames,
            responseLanguageSection: channelResponseLanguageSection()
        )
    }

    /// Applies the current selection to the running session in place.
    private func updateRuntimeSessionOptions() async throws {
        guard let managementRuntime else {
            return
        }
        let allowedToolNames = await selectedAllowedToolNames()
        try await managementRuntime.updateSessionOptions(
            configuration: currentSessionConfiguration(
                allowedToolNames: allowedToolNames,
                responseLanguageSection: channelResponseLanguageSection()
            )
        )
    }

    /// Creates the runtime session for the current selection and hands it the
    /// selected prompt skills.
    func createSessionWithSelectedSkills(
        discoverExternalTools: Bool = true
    ) async throws {
        guard let managementRuntime else {
            return
        }
        try await managementRuntime.createSession(
            configuration: await composedSessionConfiguration(
                discoverExternalTools: discoverExternalTools
            )
        )
        await managementRuntime.updatePromptSkillSelection(
            selectedPromptSkills(),
            sessionID: sessionID
        )
    }

    /// Stops the backend and creates the session anew, then loads the model,
    /// calling the channel hooks between the steps.
    private func recreateSession(reason: ChatSessionRecreationReason) async throws {
        await channelHooks?.sessionWillCreate(reason: reason)
        try await createSessionWithSelectedSkills()
        await channelHooks?.sessionDidCreate(reason: reason)
        try await preloadSessionModel(reason: reason)
    }

    /// Loads the session's model. The backend's events go to the channel
    /// hooks, or to the presenter when the channel set none.
    func preloadSessionModel(reason: ChatSessionRecreationReason) async throws {
        guard let managementRuntime else {
            return
        }
        let configuration = await composedSessionConfiguration(discoverExternalTools: false)
        let hooks = channelHooks
        let presenter = self.presenter
        let modelID = try await managementRuntime.preloadModel(
            configuration: configuration
        ) { event in
            if let hooks {
                await hooks.modelPreloadDidEmit(event)
            } else {
                await Self.presentPreloadEvent(event, on: presenter)
            }
        }
        await hooks?.modelDidPreload(modelID, reason: reason)
    }

    private static func presentPreloadEvent(
        _ event: DirectAgentEvent,
        on presenter: any ChatSessionPresenter
    ) async {
        switch event {
        case let .modelLoaded(modelID):
            await presenter.presentModelLoaded(modelID)
        case let .status(status):
            await presenter.presentStatus(status)
        case let .diagnostic(diagnostic):
            await presenter.presentDiagnostic(diagnostic)
        case .thought,
             .metrics,
             .contextWindow,
             .subscriptionUsage,
             .content,
             .toolCallStarted,
             .toolCallCompleted,
             .sessionSnapshot,
             .turnEnded:
            break
        }
    }

    // MARK: - Models

    /// The model menu: every available model, grouped by provider, the
    /// current one selected.
    func modelChoices() -> ChatChoiceList {
        modelChoices(modelCatalog.sortedModels(), title: "Available models")
    }

    func modelChoices(
        _ models: [AgentSettingsModelManifest],
        title: String
    ) -> ChatChoiceList {
        let selectedModel = ChatModelCatalog.model(
            matching: menuSelectedModelID(),
            in: models
        )
        return ChatChoiceList(
            title: title,
            items: Self.modelChoiceEntries(models).map(\.item),
            selectedIDs: selectedModel.map { [$0.id] } ?? []
        )
    }

    /// The menu entries of `models`, grouped by provider in presentation
    /// order, each with the model it stands for.
    nonisolated static func modelChoiceEntries(
        _ models: [AgentSettingsModelManifest]
    ) -> [(model: AgentSettingsModelManifest, item: ChatChoiceItem)] {
        ChatModelCatalog.providerGroups(models).flatMap { group in
            group.models.map { model in
                (
                    model: model,
                    item: ChatChoiceItem(
                        id: model.id,
                        title: AgentModelCatalogPresentation.modelTitle(for: model, in: group),
                        group: group.title
                    )
                )
            }
        }
    }

    /// The model a menu starts on: the session's model, or the configured
    /// selection.
    private func menuSelectedModelID() -> String? {
        currentEffectiveModelID() ?? AgentSettingsStore.selectedModelID()
    }

    /// `/models`: asks the host for a model and applies it.
    func chooseModel() async throws -> ChatSelectionOutcome {
        let models = modelCatalog.sortedModels()
        guard !models.isEmpty else {
            throw TerminalChatError.noConfiguredModels
        }
        guard host.capabilities.contains(.singleChoice) else {
            return ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(
                    .modelSelection(models: models, selectedModelID: menuSelectedModelID())
                ),
            ])
        }

        let choices = modelChoices(models, title: "Available models")
        guard let modelID = await host.chooseOne(
            title: choices.title,
            items: choices.items,
            selectedID: choices.selectedIDs.first
        ) else {
            return ChatSelectionOutcome(notices: [.modelUnchanged])
        }
        return try await selectModel(id: modelID)
    }

    /// Makes `modelID` the session's model and the user's default.
    ///
    /// The thinking level comes from the selected agent's binding for the
    /// model, or stays the current one when the model does not change. The
    /// same model updates the session in place; another model stops the
    /// backend, creates the session anew, and loads the model.
    func selectModel(id modelID: String) async throws -> ChatSelectionOutcome {
        let models = modelCatalog.sortedModels()
        guard !models.isEmpty else {
            throw TerminalChatError.noConfiguredModels
        }
        guard let selectedModel = models.first(where: { $0.id == modelID })
            ?? ChatModelCatalog.model(matching: modelID, in: models) else {
            throw ChatSelectionError.unknownModel(modelID)
        }

        let previousEffectiveModelID = currentEffectiveModelID()
        let previousThinkingSelection = currentAgentThinkingSelection()
        let keepsModel = previousEffectiveModelID.map(selectedModel.matches) == true
        let selectedThinkingSelection = selectedModel.thinkingSelection(
            for: selectedAgentModelBinding(for: selectedModel)?.thinkingSelection
                ?? (keepsModel ? previousThinkingSelection : nil)
        )
        try modelCatalog.saveModelSelection(
            modelID: selectedModel.id,
            thinking: selectedThinkingSelection
        )
        savedSessionState.systemPromptOverride = nil
        selection.modelIDOverride = selectedModel.id
        selection.thinkingOverride = selectedThinkingSelection
        await presentSessionStateChanged()

        if keepsModel {
            try await updateRuntimeSessionOptions()
            return ChatSelectionOutcome(change: .sessionUpdated)
        }

        await managementRuntime?.shutdownBackendKeepingExternalTools()
        try await recreateSession(reason: .modelChanged)
        return ChatSelectionOutcome(change: .sessionRecreated)
    }

    /// Picks a model when the session starts without one: the only
    /// configured model, or one the host asks for together with its thinking
    /// level. Returns the notice to present, or `nil` when the session
    /// already has a model. Nothing is persisted.
    func resolveInitialModel() async throws -> ChatSessionNotice? {
        guard currentEffectiveModelID() == nil else {
            return nil
        }

        let models = modelCatalog.sortedModels()
        guard !models.isEmpty else {
            throw TerminalChatError.noConfiguredModels
        }

        if models.count == 1,
           let model = models.first {
            let thinkingSelection = model.thinkingSelection(
                for: selectedAgentModelBinding(for: model)?.thinkingSelection
            )
            selection.modelIDOverride = model.id
            selection.thinkingOverride = thinkingSelection
            await presentSessionStateChanged()
            return .modelSelected(model, thinking: thinkingSelection)
        }

        let choices = modelChoices(models, title: "No model selected for ZenCODE.")
        guard host.capabilities.contains(.singleChoice),
              let modelID = await host.chooseOne(
                  title: choices.title,
                  items: choices.items,
                  selectedID: choices.selectedIDs.first
              ),
              let model = models.first(where: { $0.id == modelID }) else {
            throw TerminalChatError.modelSelectionRequired
        }

        let thinkingSelection = await chooseInitialThinking(for: model)
        selection.modelIDOverride = model.id
        selection.thinkingOverride = thinkingSelection
        await presentSessionStateChanged()
        return .modelSelected(model, thinking: thinkingSelection)
    }

    /// The thinking level for a model chosen at startup; a cancelled menu
    /// keeps the default level.
    func chooseInitialThinking(
        for model: AgentSettingsModelManifest
    ) async -> AgentThinkingSelection? {
        let options = ChatModelCatalog.thinkingOptions(for: model)
        guard !options.isEmpty else {
            return nil
        }

        let defaultSelection = defaultThinkingMenuSelection(for: model)
        let choices = thinkingChoices(for: model, options: options, selected: defaultSelection)
        guard let thinkingID = await host.chooseOne(
            title: choices.title,
            items: choices.items,
            selectedID: choices.selectedIDs.first
        ) else {
            return defaultSelection
        }
        return options.first { $0.rawValue == thinkingID } ?? defaultSelection
    }

    // MARK: - Thinking

    private enum ThinkingMenuState {
        case unavailable(ChatSessionNotice)
        case available(
            model: AgentSettingsModelManifest,
            options: [AgentThinkingSelection],
            selected: AgentThinkingSelection?
        )
    }

    /// The thinking menu of the current model; `nil` without a current model
    /// or when its thinking is not configurable.
    func thinkingChoices() throws -> ChatChoiceList? {
        guard case let .available(model, options, selected) = try thinkingMenuState() else {
            return nil
        }
        return thinkingChoices(for: model, options: options, selected: selected)
    }

    private func thinkingChoices(
        for model: AgentSettingsModelManifest,
        options: [AgentThinkingSelection],
        selected: AgentThinkingSelection?
    ) -> ChatChoiceList {
        ChatChoiceList(
            title: "Thinking / effort for \(AgentModelCatalogPresentation.modelTitle(for: model))",
            items: options.map { option in
                ChatChoiceItem(id: option.rawValue, title: option.menuTitle)
            },
            selectedIDs: selected.map { [$0.rawValue] } ?? []
        )
    }

    private func thinkingMenuState() throws -> ThinkingMenuState {
        let models = modelCatalog.sortedModels()
        guard !models.isEmpty else {
            throw TerminalChatError.noConfiguredModels
        }

        let effectiveModelID = currentEffectiveModelID()
            ?? AgentSettingsStore.selectedModelID()
        guard let currentModel = ChatModelCatalog.model(
            matching: effectiveModelID,
            in: models
        ) else {
            return .unavailable(.noCurrentModel)
        }

        let options = ChatModelCatalog.thinkingOptions(for: currentModel)
        guard !options.isEmpty else {
            return .unavailable(.thinkingNotSupported(model: currentModel))
        }
        return .available(
            model: currentModel,
            options: options,
            selected: defaultThinkingMenuSelection(for: currentModel)
        )
    }

    /// The level a thinking menu starts on: the configured level (the
    /// session's own one when the host supplies the models), else the
    /// model's default.
    private func defaultThinkingMenuSelection(
        for model: AgentSettingsModelManifest
    ) -> AgentThinkingSelection? {
        let currentSelection = model.thinkingSelection(
            for: modelCatalog.persistsSelections
                ? AgentSettingsStore.selectedThinkingSelection()
                : selection.thinkingOverride
        )
        return currentSelection ?? model.resolvedDefaultThinkingSelection
    }

    /// `/think`: asks the host for a thinking level of the current model and
    /// applies it.
    func chooseThinking() async throws -> ChatSelectionOutcome {
        let model: AgentSettingsModelManifest
        let options: [AgentThinkingSelection]
        let selected: AgentThinkingSelection?
        switch try thinkingMenuState() {
        case let .unavailable(notice):
            return ChatSelectionOutcome(notices: [notice])
        case let .available(currentModel, currentOptions, currentSelection):
            model = currentModel
            options = currentOptions
            selected = currentSelection
        }
        guard host.capabilities.contains(.singleChoice) else {
            return ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(
                    .thinkingSelection(model: model, options: options, selected: selected)
                ),
            ])
        }

        let choices = thinkingChoices(for: model, options: options, selected: selected)
        guard let thinkingID = await host.chooseOne(
            title: choices.title,
            items: choices.items,
            selectedID: choices.selectedIDs.first
        ), let thinkingSelection = options.first(where: { $0.rawValue == thinkingID }) else {
            return ChatSelectionOutcome(notices: [.thinkingUnchanged])
        }
        return try await selectThinking(thinkingSelection)
    }

    /// Makes `thinkingSelection` the session's thinking level and the user's
    /// default, updating the session in place.
    func selectThinking(
        _ thinkingSelection: AgentThinkingSelection
    ) async throws -> ChatSelectionOutcome {
        try modelCatalog.saveThinkingSelection(thinkingSelection)
        selection.thinkingOverride = thinkingSelection
        await presentSessionStateChanged()
        try await updateRuntimeSessionOptions()
        return ChatSelectionOutcome(change: .sessionUpdated)
    }

    // MARK: - Agents

    /// Where the agent profiles are read from, for the missing-manifest
    /// message.
    private var agentsManifestPath: String {
        AgentProfileStore.agentsManifestURL().path
    }

    /// The ID of an agent's menu entry: its persisted selection identifier.
    nonisolated static func agentChoiceID(_ agent: AgentProfile) -> String {
        ProjectAgentSelectionStore.selectionIdentifier(for: agent)
    }

    private nonisolated static func agentChoiceItem(
        _ agent: AgentProfile,
        isCurrent: Bool = false
    ) -> ChatChoiceItem {
        ChatChoiceItem(
            id: agentChoiceID(agent),
            title: agent.displayName,
            detail: ChatSessionNoticeText.agentDetail(agent),
            isCurrent: isCurrent
        )
    }

    /// The agent menu: every available profile, the active one selected.
    func agentChoices() throws -> ChatChoiceList {
        let agents = try availableAgents()
        return ChatChoiceList(
            title: "Agents",
            items: agents.map { Self.agentChoiceItem($0) },
            selectedIDs: Set(agents.filter { $0 == selection.agent }.map(Self.agentChoiceID))
        )
    }

    /// The project's agent menu: every available profile, the ones
    /// associated with the project selected, and the active one marked
    /// current.
    func projectAgentChoices() throws -> ChatChoiceList {
        projectAgentMenu(agents: try availableAgents()).choices
    }

    private struct ProjectAgentMenu {
        let choices: ChatChoiceList
        let projectName: String
        let activeKey: String?
        let activeAgent: AgentProfile?
    }

    private func projectAgentMenu(agents: [AgentProfile]) -> ProjectAgentMenu {
        let projectName = Self.projectDisplayName(workingDirectory)
        let savedSelection = ProjectAgentSelectionStore.load(workspaceRootURL: workingDirectory)
        let initialAssociation = Self.projectAgentMenuInitialAssociation(
            agents,
            savedSelection: savedSelection
        )
        let activeKey = selection.agent.map(ProjectAgentSelectionStore.selectionKey(for:))
        let activeAgent = agents.first {
            ProjectAgentSelectionStore.selectionKey(for: $0) == activeKey
        }
        let choices = ChatChoiceList(
            title: "Agent profiles · project: \(projectName)",
            items: agents.map { agent in
                Self.agentChoiceItem(agent, isCurrent: agent == activeAgent)
            },
            selectedIDs: Set(
                agents.filter { initialAssociation.contains($0) }.map(Self.agentChoiceID)
            )
        )
        return ProjectAgentMenu(
            choices: choices,
            projectName: projectName,
            activeKey: activeKey,
            activeAgent: activeAgent
        )
    }

    /// `/agents`: one menu that associates profiles with the project (the
    /// only ones the `sub-agents` tool may delegate to) and picks the active
    /// agent.
    ///
    /// - Confirming saves the ticked profiles and activates the focused one;
    ///   the cursor starts on the active agent, so confirming without moving
    ///   keeps it.
    /// - Cancelling saves and changes nothing.
    /// - A project without a saved selection starts with only the system
    ///   profiles ticked, and confirming an unchanged selection writes no
    ///   file.
    func chooseProjectAgents() async throws -> ChatSelectionOutcome {
        guard host.capabilities.contains(.focusedMultipleChoice) else {
            let agents: [AgentProfile]
            do {
                agents = try availableAgents()
            } catch {
                // The selected agent precedes the list that could not be read.
                await presenter.presentSessionNotice(.selectedAgent(selection.agent))
                throw error
            }
            return ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(
                    .agentSelection(
                        agents: agents,
                        selected: selection.agent,
                        manifestPath: agentsManifestPath
                    )
                ),
            ])
        }

        let agents = try availableAgents()
        guard !agents.isEmpty else {
            return ChatSelectionOutcome(notices: [
                .availableAgents(
                    agents: agents,
                    selected: selection.agent,
                    manifestPath: agentsManifestPath
                ),
            ])
        }

        let menu = projectAgentMenu(agents: agents)
        guard let choice = await host.chooseManyWithFocus(
            title: menu.choices.title,
            items: menu.choices.items,
            selectedIDs: menu.choices.selectedIDs,
            focusedID: menu.activeAgent.map(Self.agentChoiceID),
            toggleLabel: "agents",
            confirmLabel: "use agent"
        ) else {
            return ChatSelectionOutcome(notices: [.selectedAgent(selection.agent)])
        }

        let associatedAgents = agents.filter {
            choice.selectedIDs.contains(Self.agentChoiceID($0))
        }
        let associationChanged = choice.selectedIDs != menu.choices.selectedIDs
        if associationChanged {
            do {
                try ProjectAgentSelectionStore.save(
                    agentIDs: associatedAgents.map(ProjectAgentSelectionStore.selectionIdentifier(for:)),
                    workspaceRootURL: workingDirectory
                )
            } catch {
                return ChatSelectionOutcome(notices: [
                    .projectAgentsSaveFailed(description: error.localizedDescription),
                ])
            }
            await presenter.presentSessionNotice(
                .projectAgentsAssociated(agents: associatedAgents, projectName: menu.projectName)
            )
        }

        let focusedAgent = agents.first { Self.agentChoiceID($0) == choice.focusedID }
        if let focusedAgent,
           ProjectAgentSelectionStore.selectionKey(for: focusedAgent) != menu.activeKey {
            // The new session builds its prompt from the saved association.
            return try await selectAgent(focusedAgent)
        }
        if associationChanged {
            // Same agent: rebuild the prompt in place, as `/tools` does, so the
            // delegatable roster follows the new association without losing
            // the conversation.
            savedSessionState.systemPromptOverride = nil
            let change = await updateSessionToolOptionsReportingChange(
                discoverExternalTools: false
            ).change
            return ChatSelectionOutcome(change: change)
        }
        return ChatSelectionOutcome(notices: [.selectedAgent(selection.agent)])
    }

    /// Activates the agent `rawSelection` names (its number, ID, or name).
    func selectAgent(rawSelection: String) async throws -> ChatSelectionOutcome {
        let agent = try Self.parseAgentSelection(
            rawSelection,
            availableAgents: try availableAgents()
        )
        return try await selectAgent(agent)
    }

    /// Activates `agent`: applies its tools and skills, resets the plan and
    /// the task graph, and recreates the session keeping the conversation.
    ///
    /// A model chosen through `/models` is session state, not a property of
    /// the agent, so it is kept with its thinking level; only a session
    /// without one falls back to the agent's default binding.
    func selectAgent(_ agent: AgentProfile) async throws -> ChatSelectionOutcome {
        let previousModelIDOverride = selection.modelIDOverride
        let previousThinkingOverride = selection.thinkingOverride
        selection.agent = agent
        // Selecting an agent (the same one again included) reads the launch
        // folder anew when the next prompt is composed.
        launchFolderProjectsCache = nil
        await channelHooks?.agentDidChange(agent)
        await applyAgentProfile(agent)
        savedSessionState.systemPromptOverride = nil
        activePlan = nil
        pendingPlanApprovalPlanID = nil
        selection.modelIDOverride = previousModelIDOverride
            ?? (environment.hostedModels == nil ? nil : environment.explicitModelID)
        selection.thinkingOverride = previousModelIDOverride == nil
            ? nil
            : previousThinkingOverride
        _ = await requestWorkspaceAccessIfNeeded()
        await presentSessionStateChanged()

        await managementRuntime?.shutdownBackendKeepingExternalTools()
        try? await managementRuntime?.clearTaskGraphs(sessionID: sessionID)
        try await recreateSession(reason: .agentSwitched)
        return ChatSelectionOutcome(change: .sessionRecreated, notices: [.agentSwitched(agent)])
    }

    nonisolated static func parseAgentSelection(
        _ rawSelection: String,
        availableAgents: [AgentProfile]
    ) throws -> AgentProfile {
        let token = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedToken = agentSelectionKey(token)
        guard !normalizedToken.isEmpty else {
            throw TerminalAgentSelectionError.unknownAgent(token)
        }

        if let index = Int(token),
           availableAgents.indices.contains(index - 1) {
            return availableAgents[index - 1]
        }

        if let agent = availableAgents.first(where: {
            agentSelectionKey($0.id) == normalizedToken
                || agentSelectionKey($0.name) == normalizedToken
        }) {
            return agent
        }

        throw TerminalAgentSelectionError.unknownAgent(token)
    }

    nonisolated static func agentSelectionKey(_ value: String) -> String {
        TextUtilities.normalizedLookupValue(value)
    }

    /// Profiles ticked when the project's agent menu opens: the saved
    /// selection, or the system profiles when the project has none.
    nonisolated static func projectAgentMenuInitialAssociation(
        _ agents: [AgentProfile],
        savedSelection: Set<String>?
    ) -> Set<AgentProfile> {
        Set(ProjectAgentSelectionStore.filter(agents, selection: savedSelection))
    }

    /// Folder name shown in the project's agent menu title; the path itself
    /// when the folder has no usable last component (for example the
    /// filesystem root).
    nonisolated static func projectDisplayName(_ workspaceRootURL: URL) -> String {
        let standardized = workspaceRootURL.standardizedFileURL
        return standardized.lastPathComponent.nilIfBlank ?? standardized.path
    }

    // MARK: - Workspace access

    /// Asks the host to let the selected tools reach the workspace folder.
    /// When it refuses, the tools that need the folder are deselected and
    /// ``ChatSessionNotice/workspaceAccessDenied(_:)`` is presented.
    func ensureWorkspaceAccess() async {
        if await requestWorkspaceAccessIfNeeded() {
            await presentSessionStateChanged()
        }
    }

    /// Returns `true` when access was refused and tools were deselected.
    private func requestWorkspaceAccessIfNeeded() async -> Bool {
        let items = await toolSelectionItems()
        let workspaceSelectionKeys = TerminalToolSelectionCatalog.workspaceAccessSelectionKeys(
            for: selection.toolKeys,
            items: items
        )
        guard !workspaceSelectionKeys.isEmpty else {
            return false
        }

        let request = ChatWorkspaceAccessRequest(
            workspaceURL: workingDirectory,
            toolTitles: items
                .filter { workspaceSelectionKeys.contains($0.key) }
                .map(\.title)
        )
        guard !(await host.requestWorkspaceAccess(request)) else {
            return false
        }

        selection.toolKeys.subtract(workspaceSelectionKeys)
        await presenter.presentSessionNotice(.workspaceAccessDenied(request))
        return true
    }

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
    func chooseTools() async -> ChatSelectionOutcome {
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
    func selectTools(rawSelection: String) async throws -> ChatSelectionOutcome {
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
    func selectTools(keys: Set<String>) async -> ChatSelectionOutcome {
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

    /// The tool groups the session exposes now.
    func activeToolsSummary() async -> ChatActiveToolsSummary {
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

    private func updateSessionToolOptionsReportingChange(
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
            await presenter.presentSessionNotice(
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

    // MARK: - Skills

    /// The menu entries of the installed prompt skills.
    func skillChoiceItems() -> [ChatChoiceItem] {
        availableSkills().map { skill in
            let canonicalName = skill.canonicalName == skill.title
                ? ""
                : " (\(skill.canonicalName))"
            return ChatChoiceItem(
                id: skill.id,
                title: "\(skill.title)\(canonicalName)",
                detail: InlineTextTruncation.truncatedInline(skill.summary, limit: 96)
            )
        }
    }

    /// The skill menu: every installed prompt skill, the selected ones
    /// ticked.
    func skillChoices() -> ChatChoiceList {
        ChatChoiceList(
            title: "Prompt skills",
            items: skillChoiceItems(),
            selectedIDs: selection.skillIDs
        )
    }

    /// `/skills`: asks the host for the prompt skills and applies them.
    func chooseSkills() async -> ChatSelectionOutcome {
        guard host.capabilities.contains(.multipleChoice) else {
            return ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(.skillSelection(selected: selectedPromptSkills())),
            ])
        }

        let choices = skillChoices()
        guard !choices.items.isEmpty else {
            return ChatSelectionOutcome(notices: [
                .noPromptSkillsInstalled,
                .selectedSkills(selectedPromptSkills()),
            ])
        }
        guard let selectedSkillIDs = await host.chooseMany(
            title: choices.title,
            items: choices.items,
            selectedIDs: choices.selectedIDs
        ) else {
            return ChatSelectionOutcome(notices: [.selectedSkills(selectedPromptSkills())])
        }
        return await selectSkills(ids: selectedSkillIDs)
    }

    /// Selects the prompt skills `rawSelection` names (`all`, `none`, names,
    /// numbers).
    func selectSkills(rawSelection: String) async throws -> ChatSelectionOutcome {
        let selectedSkillIDs = try Self.parseSkillSelection(
            rawSelection,
            availableSkills: availableSkills()
        )
        return await selectSkills(ids: selectedSkillIDs)
    }

    /// Selects the prompt skills `ids`.
    func selectSkills(ids: Set<String>) async -> ChatSelectionOutcome {
        selection.skillIDs = ids
        await presentSessionStateChanged()
        await updateRuntimePromptSkills()
        return ChatSelectionOutcome(
            change: .sessionUpdated,
            notices: [.selectedSkills(selectedPromptSkills())]
        )
    }

    /// Hands the selected prompt skills to the session. Selection is
    /// session-scoped, mutable state: updating it must not touch the system
    /// prompt, allowlist, cache key, or history, so the remote continuation
    /// and KV-cache prefix stay valid.
    private func updateRuntimePromptSkills() async {
        await managementRuntime?.updatePromptSkillSelection(
            selectedPromptSkills(),
            sessionID: sessionID
        )
    }

    /// Where a skill is installed from.
    enum SkillInstallSource: Sendable, Equatable {
        /// A GitHub repository or folder URL.
        case gitHub(URL)
        /// A local skill folder or `SKILL.md` file.
        case local(URL)
    }

    /// Installs the skill at `source` (a GitHub URL, or a local path that a
    /// relative form resolves against ``workingDirectory``) and selects it.
    func installSkill(source: String) async -> ChatSelectionOutcome {
        guard let installSource = Self.skillInstallSource(
            source,
            workingDirectory: workingDirectory
        ) else {
            return ChatSelectionOutcome(notices: [
                .skillInstallSourceRequired,
                .skillSelectionUsage,
            ])
        }
        return await installSkill(from: installSource)
    }

    func installSkill(from source: SkillInstallSource) async -> ChatSelectionOutcome {
        let result: PromptSkillInstallResult
        do {
            switch source {
            case let .gitHub(url):
                await presenter.presentSessionNotice(
                    .skillInstallStarted(source: url.absoluteString)
                )
                result = try await PromptSkillInstaller.install(fromGitHubURL: url)
            case let .local(url):
                await presenter.presentSessionNotice(.skillInstallStarted(source: url.path))
                result = try PromptSkillInstaller.install(fromLocalURL: url)
            }
        } catch {
            return ChatSelectionOutcome(notices: [
                .operationFailed(description: error.localizedDescription),
                .skillSelectionUsage,
            ])
        }

        availableSkillsCache = nil
        selection.skillIDs.insert(result.skill.id)
        await presentSessionStateChanged()
        await updateRuntimePromptSkills()
        return ChatSelectionOutcome(
            change: .sessionUpdated,
            notices: [.skillInstalled(result.skill)]
        )
    }

    /// `/skills uninstall`: asks the host which installed skills to remove
    /// and uninstalls them. A cancelled menu presents nothing.
    func chooseSkillsToUninstall() async -> ChatSelectionOutcome {
        guard host.capabilities.contains(.multipleChoice) else {
            return ChatSelectionOutcome(notices: [
                .requiresInteractiveHost(.skillUninstall),
                .skillSelectionUsage,
            ])
        }

        guard !availableSkills().isEmpty else {
            return ChatSelectionOutcome(notices: [.noPromptSkillsInstalled])
        }
        guard let selectedSkillIDs = await host.chooseMany(
            title: "Uninstall prompt skills",
            items: skillChoiceItems(),
            selectedIDs: []
        ) else {
            return ChatSelectionOutcome()
        }
        return await uninstallSkills(ids: selectedSkillIDs)
    }

    /// Uninstalls the installed skills `ids` and deselects them.
    func uninstallSkills(ids: Set<String>) async -> ChatSelectionOutcome {
        let selectedSkills = availableSkills().filter { ids.contains($0.id) }
        guard !selectedSkills.isEmpty else {
            return ChatSelectionOutcome(notices: [.noSkillsSelectedForUninstall])
        }

        do {
            try PromptSkillInstaller.uninstall(skills: selectedSkills)
        } catch {
            return ChatSelectionOutcome(notices: [
                .operationFailed(description: error.localizedDescription),
                .skillSelectionUsage,
            ])
        }
        availableSkillsCache = nil
        selection.skillIDs.subtract(ids)
        await presentSessionStateChanged()
        await updateRuntimePromptSkills()
        return ChatSelectionOutcome(
            change: .sessionUpdated,
            notices: [.skillsUninstalled(selectedSkills)]
        )
    }

    // MARK: - Skill install sources

    /// The install source `value` names: a GitHub URL, else a local path
    /// (absolute, `~/`, `file://`, or relative to `workingDirectory` when it
    /// starts with `.` or `..`).
    nonisolated static func skillInstallSource(
        _ value: String,
        workingDirectory: URL
    ) -> SkillInstallSource? {
        if let url = gitHubSkillInstallURL(value: value) {
            return .gitHub(url)
        }
        if let url = localSkillInstallURL(value: value, baseDirectory: workingDirectory) {
            return .local(url)
        }
        return nil
    }

    nonisolated static func gitHubSkillInstallURL(value: String) -> URL? {
        guard let urlToken = value.split(whereSeparator: \.isWhitespace).first.map(String.init) else {
            return nil
        }

        guard let url = URL(string: urlToken),
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return nil
        }
        return url
    }

    nonisolated static func localSkillInstallURL(
        value: String,
        baseDirectory: URL
    ) -> URL? {
        if value.lowercased().hasPrefix("file://"),
           let url = URL(string: value),
           url.isFileURL {
            return url.standardizedFileURL
        }

        if value.hasPrefix("~/") {
            let expandedPath = NSString(string: value).expandingTildeInPath
            return URL(fileURLWithPath: expandedPath, isDirectory: true)
                .standardizedFileURL
        }

        if value.hasPrefix("/") {
            return URL(fileURLWithPath: value, isDirectory: true)
                .standardizedFileURL
        }

        if value == "."
            || value == ".."
            || value.hasPrefix("./")
            || value.hasPrefix("../") {
            return baseDirectory
                .appendingPathComponent(value, isDirectory: true)
                .standardizedFileURL
        }

        return nil
    }

    /// The install value of `/skills` arguments: what follows `install` or
    /// `add`, or the whole argument without that keyword. `nil` when there
    /// is none.
    nonisolated static func skillInstallValue(from rawArguments: String) -> String? {
        let trimmedArguments = rawArguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedArguments.isEmpty else {
            return nil
        }

        guard let commandEndIndex = trimmedArguments.firstIndex(where: \.isWhitespace) else {
            return isSkillInstallRequest(trimmedArguments) ? nil : trimmedArguments
        }

        let command = trimmedArguments[..<commandEndIndex].lowercased()
        guard ["install", "add"].contains(command) else {
            return trimmedArguments
        }

        let value = trimmedArguments[commandEndIndex...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    nonisolated static func isSkillInstallRequest(_ rawArguments: String) -> Bool {
        let tokens = rawArguments
            .split { $0.isWhitespace }
        guard let command = tokens.first?.lowercased() else {
            return false
        }
        return ["install", "add"].contains(command)
    }

    nonisolated static func isSkillUninstallRequest(_ rawArguments: String) -> Bool {
        let tokens = rawArguments
            .split { $0.isWhitespace }
        return tokens.count == 1 && tokens[0].lowercased() == "uninstall"
    }
}
