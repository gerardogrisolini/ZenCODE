//
//  ZenCODESetupRunner+Menu.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import ZenCODECore

extension ZenCODESetupRunner {
    static func promptSetupSection(
        currentManifest manifest: AgentSettingsManifest?,
        additionalSectionGroups: [ZenCODESetupAdditionalSectionGroup]
    ) throws -> SetupSection {
        let modelsConfigured = manifest?.models.isEmpty == false
        while true {
            let options = setupSectionOptions(
                currentManifest: manifest,
                additionalSectionGroups: additionalSectionGroups
            )
            let defaultSection: SetupSection = modelsConfigured ? .finish : .providersAndModels
            let defaultIndex = options.firstIndex { $0.section == defaultSection } ?? 0

            let items = setupSectionMenuItems(
                options: options,
                currentManifest: manifest
            )
            guard let selectedIndex = TerminalCheckboxMenu.selectOne(
                title: "ZenCODE setup",
                items: items,
                selected: defaultIndex
            ) else {
                return .cancel
            }
            let selectedSection = options[selectedIndex].section

            if selectedSection.requiresConfiguredModels, !modelsConfigured {
                AgentOutput.standardError.writeString(
                    "Configure providers and models before modifying that section.\n\n"
                )
                continue
            }
            return selectedSection
        }
    }

    /// Builds the single-select menu items for the main setup menu, grouping
    /// them by category and prefixing each detail with a readiness marker so
    /// the progress overview is visible inline.
    static func setupSectionMenuItems(
        options: [SetupSectionOption],
        currentManifest manifest: AgentSettingsManifest?
    ) -> [TerminalCheckboxMenuItem<Int>] {
        options.enumerated().map { index, option in
            TerminalCheckboxMenuItem(
                value: index,
                title: option.section.title,
                detail: menuItemDetail(for: option, currentManifest: manifest),
                groupTitle: setupSectionGroupTitle(option.section.category)
            )
        }
    }

    static func setupSectionGroupTitle(_ category: SetupSectionCategory) -> String {
        switch category {
        case .required:
            return "Required"
        case .recommended:
            return "Recommended"
        case .optional:
            return "Optional"
        case .finish:
            return "Finish"
        }
    }

    static func menuItemDetail(
        for option: SetupSectionOption,
        currentManifest manifest: AgentSettingsManifest?
    ) -> String? {
        guard let marker = setupSectionReadinessMarker(
            for: option.section,
            currentManifest: manifest
        ) else {
            return option.detail
        }
        guard let detail = option.detail else {
            return marker
        }
        return "\(marker) \(detail)"
    }

    static func setupSectionReadinessMarker(
        for section: SetupSection,
        currentManifest manifest: AgentSettingsManifest?
    ) -> String? {
        switch section {
        case .providersAndModels:
            let ready = manifest?.providers.isEmpty == false && manifest?.models.isEmpty == false
            return setupStatusMarker(ready)
        case .defaultModelSettings:
            return setupStatusMarker(manifest.map { selectedModel(in: $0) != nil } ?? false)
        case .agents:
            return setupStatusMarker(agentsSetupDetail() != "not configured")
        case .telegram:
            return setupStatusMarker(manifest?.telegram?.isEnabled == true, optional: true)
        case .voice:
            return setupStatusMarker(manifest?.voice?.isConfigured == true, optional: true)
        case .features:
            return setupStatusMarker(featuresAreEnabled(), optional: true)
        case .defaultModel, .defaultThinking, .additionalGroup, .finish, .cancel:
            return nil
        }
    }

    static func setupSectionOptions(
        currentManifest manifest: AgentSettingsManifest?,
        additionalSectionGroups: [ZenCODESetupAdditionalSectionGroup]
    ) -> [SetupSectionOption] {
        let groupsAfterAgents = additionalSectionGroupOptions(
            additionalSectionGroups,
            placement: .afterAgents
        )
        let groupsAfterVoice = additionalSectionGroupOptions(
            additionalSectionGroups,
            placement: .afterVoice
        )

        var options = [
            SetupSectionOption(
                section: .providersAndModels,
                detail: providersAndModelsSetupDetail(manifest)
            ),
            SetupSectionOption(
                section: .defaultModelSettings,
                detail: defaultModelSettingsSetupDetail(manifest)
            ),
            SetupSectionOption(
                section: .agents,
                detail: agentsSetupDetail()
            )
        ]

        options.append(contentsOf: groupsAfterAgents)
        options.append(
            contentsOf: [
                SetupSectionOption(
                    section: .telegram,
                    detail: manifest?.telegram?.isEnabled == true ? "enabled" : "disabled"
                ),
                SetupSectionOption(
                    section: .voice,
                    detail: manifest?.voice?.isConfigured == true ? "enabled" : "disabled"
                ),
                SetupSectionOption(
                    section: .features,
                    detail: featuresSetupDetail()
                )
            ]
        )
        options.append(contentsOf: groupsAfterVoice)
        options.append(SetupSectionOption(section: .finish, detail: "save and exit"))
        options.append(SetupSectionOption(section: .cancel, detail: "discard changes"))
        return options
    }

    static func setupStatusMarker(_ isReady: Bool, optional: Bool = false) -> String {
        if isReady {
            return "[✓]"
        }
        return optional ? "[-]" : "[!]"
    }

    static func additionalSectionGroupOptions(
        _ groups: [ZenCODESetupAdditionalSectionGroup],
        placement: ZenCODESetupAdditionalSectionGroupPlacement
    ) -> [SetupSectionOption] {
        groups.enumerated().compactMap { index, group in
            guard group.placement == placement else {
                return nil
            }
            return SetupSectionOption(
                section: .additionalGroup(
                    index,
                    title: group.title,
                    aliases: group.aliases
                ),
                detail: group.detail
            )
        }
    }

    static func agentsSetupDetail() -> String {
        let url = AgentProfileStore.agentsManifestURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "not configured"
        }
        guard let agents = try? AgentProfileStore.loadRequired() else {
            return "configured"
        }
        return "\(agents.count) agents"
    }

    static func providersAndModelsSetupDetail(
        _ manifest: AgentSettingsManifest?
    ) -> String {
        let providerCount = manifest?.providers.count ?? 0
        let modelCount = manifest?.models.count ?? 0
        if providerCount == 0 && modelCount == 0 {
            return "not configured"
        }
        return "\(providerCount) providers, \(modelCount) models"
    }

    static func defaultModelSetupDetail(
        _ manifest: AgentSettingsManifest?
    ) -> String {
        guard let manifest,
              !manifest.models.isEmpty else {
            return "requires providers/models"
        }
        if let model = selectedModel(in: manifest) {
            return model.displayTitle
        }
        return "not selected"
    }

    static func defaultThinkingSetupDetail(
        _ manifest: AgentSettingsManifest?
    ) -> String {
        guard let manifest,
              !manifest.models.isEmpty else {
            return "requires providers/models"
        }
        guard let model = selectedModel(in: manifest) else {
            return "requires default model"
        }
        guard model.supportsThinking else {
            return "not supported by selected model"
        }
        let selection = model.thinkingSelection(for: manifest.selectedThinkingSelection)
        return selection?.displayTitle ?? "default"
    }

    static func defaultModelSettingsSetupDetail(
        _ manifest: AgentSettingsManifest?
    ) -> String {
        let modelDetail = defaultModelSetupDetail(manifest)
        let thinkingDetail = defaultThinkingSetupDetail(manifest)
        if modelDetail.hasPrefix("requires") {
            return modelDetail
        }
        return "\(modelDetail), thinking: \(thinkingDetail)"
    }

    static func promptDefaultModelSetupSection(
        currentManifest manifest: AgentSettingsManifest
    ) throws -> SetupSection? {
        let options = [
            SetupSectionOption(
                section: .defaultModel,
                detail: defaultModelSetupDetail(manifest)
            ),
            SetupSectionOption(
                section: .defaultThinking,
                detail: defaultThinkingSetupDetail(manifest)
            )
        ]
        return try promptNestedSetupSection(
            title: "Default model",
            options: options,
            defaultIndex: 0
        )
    }

    static func promptNestedSetupSection(
        title: String,
        options: [SetupSectionOption],
        defaultIndex: Int
    ) throws -> SetupSection? {
        let backValue = options.count
        var items = options.enumerated().map { index, option in
            TerminalCheckboxMenuItem(
                value: index,
                title: option.section.title,
                detail: option.detail
            )
        }
        items.append(
            TerminalCheckboxMenuItem(
                value: backValue,
                title: "Back",
                detail: "return to the previous menu",
                groupTitle: " "
            )
        )

        let selected = options.indices.contains(defaultIndex) ? defaultIndex : backValue
        guard let choice = TerminalCheckboxMenu.selectOne(
            title: title,
            items: items,
            selected: selected
        ), options.indices.contains(choice) else {
            return nil
        }
        return options[choice].section
    }

    static func promptAdditionalSetupSection(
        in group: ZenCODESetupAdditionalSectionGroup
    ) throws -> ZenCODESetupAdditionalSection? {
        guard !group.sections.isEmpty else {
            return nil
        }

        let backValue = group.sections.count
        var items = group.sections.enumerated().map { index, section in
            TerminalCheckboxMenuItem(
                value: index,
                title: section.title,
                detail: section.detail
            )
        }
        items.append(
            TerminalCheckboxMenuItem(
                value: backValue,
                title: "Back",
                detail: "return to the previous menu",
                groupTitle: " "
            )
        )

        let selected = group.prefersBackDefault ? backValue : 0
        guard let choice = TerminalCheckboxMenu.selectOne(
            title: group.title,
            items: items,
            selected: selected
        ), group.sections.indices.contains(choice) else {
            return nil
        }
        return group.sections[choice]
    }

}
