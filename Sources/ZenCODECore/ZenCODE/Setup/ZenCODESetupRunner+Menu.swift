//
//  ZenCODESetupRunner+Menu.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation

extension ZenCODESetupRunner {
    static func promptSetupSection(
        currentManifest manifest: AgentSettingsManifest?
    ) throws -> SetupSection {
        let modelsConfigured = manifest?.models.isEmpty == false
        while true {
            let options = setupSectionOptions(currentManifest: manifest)
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
        case .agents:
            return setupStatusMarker(agentsSetupDetail() != "not configured")
        case .agentModels:
            return setupStatusMarker(agentModelsSetupDetail() != "not configured", optional: true)
        case .telegram:
            return setupStatusMarker(manifest?.telegram?.isEnabled == true, optional: true)
        case .features:
            return setupStatusMarker(featuresAreEnabled(), optional: true)
        case .memoryEmbedding:
            return setupStatusMarker(manifest?.memoryEmbedding != nil, optional: true)
        case .dataManagement, .resetRemoteConfiguration, .finish, .cancel, .responseLanguage:
            return nil
        }
    }

    static func setupSectionOptions(
        currentManifest manifest: AgentSettingsManifest?
    ) -> [SetupSectionOption] {
        let options: [SetupSectionOption] = [
            SetupSectionOption(
                section: .providersAndModels,
                detail: providersAndModelsSetupDetail(manifest)
            ),
            SetupSectionOption(
                section: .agents,
                detail: agentsSetupDetail()
            ),
            SetupSectionOption(
                section: .agentModels,
                detail: agentModelsSetupDetail()
            ),
            SetupSectionOption(
                section: .responseLanguage,
                detail: responseLanguageSetupDetail(manifest)
            ),
            SetupSectionOption(
                section: .features,
                detail: featuresSetupDetail()
            ),
            SetupSectionOption(
                section: .memoryEmbedding,
                detail: memoryEmbeddingSetupDetail(manifest)
            ),
            SetupSectionOption(
                section: .telegram,
                detail: manifest?.telegram?.isEnabled == true ? "enabled" : "disabled"
            ),
            SetupSectionOption(
                section: .dataManagement,
                detail: "export, import, and reset ZenCODE data"
            ),
            SetupSectionOption(section: .finish, detail: "save and exit"),
            SetupSectionOption(section: .cancel, detail: "discard changes")
        ]
        return groupedByCategory(options)
    }

    /// Lays the options out in category order while preserving the authored
    /// order inside each category. The menu renderer starts a new heading on
    /// every category change, so an option listed out of category order would
    /// print its group heading a second time.
    static func groupedByCategory(
        _ options: [SetupSectionOption]
    ) -> [SetupSectionOption] {
        options.enumerated()
            .sorted { lhs, rhs in
                let lhsOrder = lhs.element.section.category.displayOrder
                let rhsOrder = rhs.element.section.category.displayOrder
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    static func setupStatusMarker(_ isReady: Bool, optional: Bool = false) -> String {
        if isReady {
            return "[✓]"
        }
        return optional ? "[-]" : "[!]"
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

    static func agentModelsSetupDetail() -> String {
        guard let agents = try? AgentProfileStore.loadRequired() else {
            return "not configured"
        }
        let withBindings = agents.filter { !$0.modelBindings.isEmpty }
        guard !withBindings.isEmpty else {
            return "no model bindings assigned"
        }
        let bindingCount = agents.reduce(0) { $0 + $1.modelBindings.count }
        return "\(withBindings.count)/\(agents.count) agents · \(bindingCount) bindings"
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

}
