//
//  ChatSessionController+Composition.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Composes what the session runs with from the selection: the session
/// configuration and system prompt, the effective model and thinking level,
/// the allowed tools, and the selected prompt skills.
///
/// The response-language section of the prompt depends on the channel (the
/// terminal locks a language on the first prompt), so the channel supplies it
/// to every composition.
extension ChatSessionController {
    // MARK: - Session configuration and prompt

    func currentSessionConfiguration(
        discoverExternalTools: Bool = false,
        responseLanguageSection: String?
    ) async -> AgentCoreSessionConfiguration {
        let allowedToolNames = await selectedAllowedToolNames(
            discoverExternalTools: discoverExternalTools
        )
        return currentSessionConfiguration(
            allowedToolNames: allowedToolNames,
            responseLanguageSection: responseLanguageSection
        )
    }

    func currentSessionConfiguration(
        allowedToolNames: Set<String>,
        includesActivePlanProgress: Bool = true,
        responseLanguageSection: String?
    ) -> AgentCoreSessionConfiguration {
        let effectiveAllowedToolNames = allowedToolNamesIncludingSelectedPromptSkills(
            allowedToolNames
        )
        let promptSections: SystemPromptSections
        if let restoredSystemPrompt = savedSessionState.systemPromptOverride?.nilIfBlank {
            // Older saved sessions contain one combined prompt. Keep that
            // legacy representation intact, while new snapshots carry the
            // dynamic part explicitly and can retain a stable system prefix.
            promptSections = SystemPromptSections(
                systemPrompt: SystemPromptBuilder.replacingSelectedSkillSection(
                    in: restoredSystemPrompt
                ),
                dynamicContext: savedSessionState.dynamicContextOverride ?? ""
            )
        } else {
            promptSections = currentPromptSections(
                allowedToolNames: effectiveAllowedToolNames,
                responseLanguageSection: responseLanguageSection
            )
        }
        let dynamicContext = includesActivePlanProgress
            ? systemPromptWithActivePlanProgress(promptSections.dynamicContext)
            : promptSections.dynamicContext
        return AgentCoreSessionConfigurationBuilder(
            sessionID: sessionID,
            modelID: currentEffectiveModelID(),
            agentID: selection.agent?.id,
            agentName: selection.agent?.name,
            agentRole: selection.agent?.role,
            workingDirectory: workingDirectory,
            systemPrompt: promptSections.systemPrompt,
            dynamicContext: dynamicContext,
            cacheKey: cacheKey ?? sessionID,
            sessionRevision: 0,
            history: history,
            allowedToolNames: effectiveAllowedToolNames,
            maxToolRounds: environment.maxToolRounds,
            maxOutputTokens: environment.maxOutputTokens,
            appMode: environment.appMode,
            thinkingSelection: currentAgentThinkingSelection(),
            preserveThinking: false
        )
        .makeConfiguration()
    }

    func allowedToolNamesIncludingSelectedPromptSkills(
        _ allowedToolNames: Set<String>
    ) -> Set<String> {
        let allowedToolNames = AgentSessionComposition.allowedToolNamesIncludingIntrinsicSkillTools(
            allowedToolNames
        )
        return selection.agent?.resolvedAllowedToolNames(allowedToolNames)
            ?? allowedToolNames
    }

    func currentSystemPrompt(
        allowedToolNames: Set<String>,
        responseLanguageSection: String?
    ) -> String {
        currentPromptSections(
            allowedToolNames: allowedToolNames,
            responseLanguageSection: responseLanguageSection
        ).combinedPrompt
    }

    func currentPromptSections(
        allowedToolNames: Set<String>,
        responseLanguageSection: String?
    ) -> SystemPromptSections {
        AgentSessionComposition.standardPromptSections(
            cwd: workingDirectory.path,
            allowedToolNames: allowedToolNames,
            selectedAgent: selection.agent,
            locksModelToSession: environment.hostedAgentProfiles != nil,
            responseLanguageSection: responseLanguageSection,
            launchFolderProjects: launchFolderProjectsForSelectedAgent()
        )
    }

    /// The launch-folder listing for the selected agent, or `nil` when there is
    /// no selected agent or its role does not delegate by role.
    ///
    /// The folder is read once per selection: the cache is cleared whenever
    /// the agent is selected (again) or a session is loaded, so a prompt
    /// recomposed on a later send, a `/tools` change, or an unchanged `/agents`
    /// menu choice reuses the same listing and never rescans the disk.
    func launchFolderProjectsForSelectedAgent() -> LaunchFolderProjects? {
        guard let agent = selection.agent, agent.role.delegatesByRole else {
            return nil
        }
        let agentKey = ProjectAgentSelectionStore.selectionKey(for: agent)
        if let cache = launchFolderProjectsCache, cache.agentKey == agentKey {
            return cache.projects
        }
        let projects = LaunchFolderProjects.scan(
            workingDirectory: workingDirectory
        )
        launchFolderProjectsCache = LaunchFolderProjectsCache(
            agentKey: agentKey,
            projects: projects
        )
        return projects
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

    // MARK: - Model and thinking

    /// The model the session runs with: the explicit choice, the selected
    /// agent's default binding, or the configured selection, falling back to
    /// the model the launch resolved.
    func currentEffectiveModelID() -> String? {
        let manifest = modelCatalog.resolutionManifest(
            selectedModelID: environment.launchModelID
        )
        let resolved = Self.effectiveModelID(
            selectedAgent: selection.agent,
            manualModelIDOverride: selection.modelIDOverride,
            manifest: manifest
        )
        return resolved ?? environment.launchModelID
    }

    nonisolated static func effectiveModelID(
        selectedAgent: AgentProfile?,
        manualModelIDOverride: String?,
        manifest: AgentSettingsManifest? = AgentSettingsManifestStore.load()
    ) -> String? {
        if let manualModelIDOverride = manualModelIDOverride?.nilIfBlank {
            return resolvedConfiguredModelID(
                matching: manualModelIDOverride,
                manifest: manifest,
                preservesUnknownReference: true
            )
        }

        if let defaultModelID = selectedAgent?.defaultModelBinding?.modelID {
            return resolvedConfiguredModelID(
                matching: defaultModelID,
                manifest: manifest,
                preservesUnknownReference: false
            )
        }

        return AgentSettingsStore.resolvedEffectiveModelID(
            explicitModelID: nil,
            agentModelID: nil,
            manifest: manifest
        )
    }

    /// Resolves a configured manifest identifier for a profile default or a
    /// manual selection. A manual reference is retained when it is external to
    /// the manifest, matching the command-line explicit-model behavior. A
    /// profile default instead falls through to the global selection when its
    /// binding no longer names a configured model.
    private nonisolated static func resolvedConfiguredModelID(
        matching modelID: String,
        manifest: AgentSettingsManifest?,
        preservesUnknownReference: Bool
    ) -> String? {
        guard let manifest else {
            return modelID
        }
        let references = ChatModelCatalog.modelReferences(for: modelID)
        for reference in references {
            if let model = manifest.models.first(where: { $0.matches(reference) }) {
                return model.id
            }
        }
        return preservesUnknownReference ? modelID : nil
    }

    func currentAgentThinkingSelection() -> AgentThinkingSelection? {
        let effectiveModelID = currentEffectiveModelID()
        let selectedBinding: AgentModelBinding?
        if let model = modelCatalog.model(matching: effectiveModelID) {
            selectedBinding = selectedAgentModelBinding(for: model)
        } else {
            selectedBinding = selection.agent?.modelBinding(matching: effectiveModelID)
        }

        // The default binding informs a profile only when the user did not
        // explicitly choose another model. Its thinking setting must not leak
        // onto an independent `/models` choice.
        let effectiveBinding = selectedBinding
            ?? (selection.modelIDOverride == nil
                ? selection.agent?.defaultModelBinding
                : nil)
        return Self.effectiveThinkingSelection(
            manualThinkingSelectionOverride: selection.thinkingOverride,
            hostedModel: hostedModelManifest(for: effectiveModelID),
            explicitModelID: selection.modelIDOverride,
            agentModelID: effectiveBinding?.modelID,
            agentThinkingSelection: effectiveBinding?.thinkingSelection
        )
    }

    nonisolated static func effectiveThinkingSelection(
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

    func hostedModelManifest(
        for modelID: String?
    ) -> AgentSettingsModelManifest? {
        modelCatalog.hostedModel(matching: modelID)
    }

    /// The selected agent's binding for `model`; `nil` without an agent or a
    /// matching binding.
    func selectedAgentModelBinding(
        for model: AgentSettingsModelManifest
    ) -> AgentModelBinding? {
        ChatModelCatalog.modelBinding(of: selection.agent, for: model)
    }

    // MARK: - Tools

    func selectedAllowedToolNames(
        discoverExternalTools: Bool = true
    ) async -> Set<String> {
        let intrinsicToolNames = intrinsicAllowedToolNamesForSelectedAgent()
        let baseItems = await toolSelectionItems()
        guard !selection.toolKeys.isEmpty else {
            return allowedToolNamesIncludingSelectedPromptSkills(
                intrinsicToolNames
            )
        }

        selection.toolKeys = TerminalToolSelectionCatalog.normalizedSelectionKeys(
            selection.toolKeys,
            items: baseItems
        )
        _ = discoverExternalTools
        let items = baseItems
        var allowedToolNames = TerminalToolSelectionCatalog.allowedToolNames(
            for: selection.toolKeys,
            items: items
        )
        allowedToolNames.formUnion(intrinsicToolNames)
        return allowedToolNamesIncludingSelectedPromptSkills(allowedToolNames)
    }

    /// The tool groups the session can select: the feature tools of the
    /// environment's feature runtime and the MCP tools known to the
    /// management runtime, plus `additionalDescriptors`.
    func toolSelectionItems(
        additionalDescriptors: [DirectToolDescriptor] = []
    ) async -> [TerminalToolSelectionItem] {
        let knownMCPDescriptors = await managementRuntime?.knownMCPToolDescriptors(
            allowedToolNames: nil,
            preferredWorkspaceRootURL: workingDirectory,
            sessionID: nil
        ) ?? []
        let featureStatuses = await environment.featureRuntime?.featureStatuses(
            includeTools: true,
            includeDisabled: true
        ) ?? []
        return Self.toolSelectionItems(
            featureStatuses: featureStatuses,
            additionalDescriptors: DirectToolExecutor.canonicalized(
                knownMCPDescriptors + additionalDescriptors
            )
        )
    }

    nonisolated static func toolSelectionItems(
        featureStatuses: [SwiftFeatureStatus],
        additionalDescriptors: [DirectToolDescriptor] = []
    ) -> [TerminalToolSelectionItem] {
        TerminalToolSelectionCatalog.items(
            featureStatuses: featureStatuses,
            additionalDescriptors: additionalDescriptors
        )
    }

    func intrinsicAllowedToolNamesForSelectedAgent() -> Set<String> {
        AgentProfileStore.isBuilderAgent(selection.agent)
            ? AgentProfileStore.featureManagementToolNames
            : []
    }

    /// The tool selection keys that `rawValues` (tool references such as an
    /// agent profile's `tools`) name among `items`.
    nonisolated static func toolSelectionKeys(
        from rawValues: [String],
        items: [TerminalToolSelectionItem]
    ) -> Set<String> {
        var selectedKeys = Set<String>()
        for rawValue in rawValues {
            selectedKeys.formUnion(
                TerminalToolSelectionCatalog.selectionKeys(
                    for: rawValue,
                    items: items
                )
            )
        }
        return selectedKeys
    }

    // MARK: - Skills

    func availableSkills() -> [PromptSkill] {
        if let availableSkillsCache {
            return availableSkillsCache
        }

        let skills = PromptSkillCatalog.discoverSkills(
            searchRoots: PromptSkillCatalog.appCatalogSearchRoots()
        )
        availableSkillsCache = skills
        return skills
    }

    func selectedPromptSkills() -> [PromptSkill] {
        let skills = availableSkills()
        return Self.promptSkills(withIDs: selection.skillIDs, in: skills)
    }

    /// The IDs of the skills among `availableSkills` that `agent` declares.
    /// Shared with ACP, which derives an agent's skills the same way.
    nonisolated static func promptSkillIDs(
        of agent: AgentProfile,
        in availableSkills: [PromptSkill]
    ) -> Set<String> {
        agent.selectedSkillIDs(availableSkills: availableSkills)
    }

    /// The skills among `availableSkills` whose ID is in `skillIDs`, in
    /// catalog order; empty for no ID. Shared with ACP.
    nonisolated static func promptSkills(
        withIDs skillIDs: Set<String>,
        in availableSkills: [PromptSkill]
    ) -> [PromptSkill] {
        guard !skillIDs.isEmpty else {
            return []
        }

        return availableSkills.filter { skillIDs.contains($0.id) }
    }

    func applyInitialSkillSelectionIfNeeded() throws {
        guard let initialSkillSelection = environment.initialSkillSelection else {
            return
        }

        selection.skillIDs = try Self.parseSkillSelection(
            initialSkillSelection,
            availableSkills: availableSkills()
        )
    }

    nonisolated static func parseSkillSelection(
        _ rawSelection: String,
        availableSkills: [PromptSkill]
    ) throws -> Set<String> {
        try TerminalSelection.parse(rawSelection, keys: availableSkills.map(\.id)) { token in
            guard let skill = skill(matching: token, in: availableSkills) else {
                throw TerminalSkillSelectionError.unknownToken(token)
            }
            return skill.id
        }
    }

    nonisolated static func skill(
        matching rawToken: String,
        in availableSkills: [PromptSkill]
    ) -> PromptSkill? {
        let token = selectionKey(rawToken)
        guard !token.isEmpty else {
            return nil
        }

        return availableSkills.first { skill in
            token == selectionKey(skill.canonicalName)
                || token == selectionKey(skill.title)
                || skill.sourceHash.hasPrefix(token)
                || skill.id.hasPrefix(token)
        }
    }

    nonisolated static func selectionKey(_ value: String) -> String {
        TerminalSelection.lookupKey(value)
    }

    // MARK: - Agents

    func availableAgents() throws -> [AgentProfile] {
        if let hostedAgentProfiles = environment.hostedAgentProfiles {
            return hostedAgentProfiles
        }
        return try AgentProfileStore.loadRequired()
    }

    /// Selects the tools and prompt skills `agent` declares.
    func applyAgentProfile(_ agent: AgentProfile) async {
        let items = await toolSelectionItems()
        selection.toolKeys = Self.toolSelectionKeys(
            from: agent.tools,
            items: items
        )
        selection.skillIDs = Self.promptSkillIDs(
            of: agent,
            in: availableSkills()
        )
    }

    /// Applies the profile of the agent the session starts with, if any.
    func applyInitialAgentSelectionIfNeeded() async {
        guard let agent = selection.agent else {
            return
        }
        await applyAgentProfile(agent)
    }
}
