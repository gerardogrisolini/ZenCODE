//
//  ZenCODEAgentProfileSetupRunner+Selections.swift
//  ZenCODE
//

import Foundation
import ZenCODECore

extension ZenCODEAgentProfileSetupRunner {
    static func promptToolSelection(
        title: String,
        defaultTools: [String]
    ) -> [String] {
        let items = toolSelectionItems(existingTools: defaultTools)
        guard !items.isEmpty else {
            return defaultTools
        }
        let selectedKeys = TerminalChat.toolSelectionKeys(
            from: defaultTools,
            items: items
        )
        let selection = TerminalCheckboxMenu.select(
            title: title,
            items: TerminalChat.toolCheckboxItems(items: items),
            selected: selectedKeys
        ) ?? selectedKeys
        return TerminalToolSelectionCatalog.selectedKeyNames(
            selection,
            items: items
        )
    }

    static func toolSelectionItems(
        existingTools: [String]
    ) -> [TerminalToolSelectionItem] {
        let baseItems = TerminalToolSelectionCatalog.items(
            featureStatuses: SwiftFeatureRuntime.defaultFeatureStatuses()
        )
        var items = baseItems
        let missingTools = existingTools.compactMap(\.nilIfBlank).filter { tool in
            TerminalToolSelectionCatalog.selectionKeys(
                for: tool,
                items: baseItems
            ).isEmpty
        }
        for tool in missingTools {
            items.append(
                TerminalToolSelectionItem(
                    key: tool,
                    title: tool,
                    detail: "saved tool not currently listed",
                    groupTitle: "Saved",
                    allowedToolNames: [tool]
                )
            )
        }
        return items
    }

    static func promptSkillSelection(
        title: String,
        defaultSkills: [AgentProfileSkill]
    ) -> [AgentProfileSkill] {
        let selectedSkillIDs = Set(defaultSkills.compactMap { $0.id.nilIfBlank })
        let items = skillCheckboxItems(
            availableSkills: PromptSkillCatalog.discoverSkills(
                searchRoots: PromptSkillCatalog.appCatalogSearchRoots()
            ),
            selectedSkillIDs: selectedSkillIDs
        )
        guard !items.isEmpty else {
            AgentOutput.standardError.writeString("No prompt skills installed by the app.\n")
            return defaultSkills
        }
        let selection = TerminalCheckboxMenu.select(
            title: title,
            items: items,
            selected: selectedSkillIDs
        ) ?? selectedSkillIDs
        return selection.sorted().map { AgentProfileSkill(id: $0) }
    }

    static func skillCheckboxItems(
        availableSkills: [PromptSkill],
        selectedSkillIDs: Set<String>
    ) -> [TerminalCheckboxMenuItem<String>] {
        let availableIDs = Set(availableSkills.map(\.id))
        let availableItems = availableSkills.map { skill in
            let canonicalName = skill.canonicalName == skill.title
                ? ""
                : " (\(skill.canonicalName))"
            return TerminalCheckboxMenuItem(
                value: skill.id,
                title: "\(skill.title)\(canonicalName)",
                detail: truncatedInline(skill.summary, limit: 96)
            )
        }
        let missingItems = selectedSkillIDs
            .subtracting(availableIDs)
            .sorted()
            .map { skillID in
                TerminalCheckboxMenuItem(
                    value: skillID,
                    title: skillID,
                    detail: "saved skill not currently installed",
                    groupTitle: "Saved"
                )
            }
        return availableItems + missingItems
    }

    static func promptModelSelection(
        title: String,
        defaultAgent: AgentProfile?
    ) -> AgentSetupModelSelection? {
        let models = AgentModelCatalogPresentation.sorted(
            AgentSettingsStore.availableModels()
        )
        guard !models.isEmpty else {
            if let modelID = defaultAgent?.modelID?.nilIfBlank {
                        AgentOutput.standardError.writeString(
                    "No configured models found. Preserving saved model: \(modelID)\n"
                )
                return AgentSetupModelSelection(
                    modelID: modelID,
                    modelProvider: defaultAgent?.modelProvider,
                    thinkingSelection: defaultAgent?.thinkingSelection
                )
            }
            AgentOutput.standardError.writeString("No configured models found for dedicated agent selection.\n")
            return nil
        }

        let existingModelID = defaultAgent?.modelID?.nilIfBlank
        let initialChoice = existingModelID.map { modelID in
            models.first(where: { $0.matches(modelID) })
                .map { AgentSetupModelChoice.configuredModel($0.id) }
                ?? .configuredModel(modelID)
        } ?? .noDedicatedModel
        let choice = TerminalCheckboxMenu.selectOne(
            title: title,
            items: modelChoiceItems(
                models: models,
                existingModelID: existingModelID
            ),
            selected: initialChoice
        ) ?? initialChoice

        switch choice {
        case .noDedicatedModel:
            return nil
        case let .configuredModel(modelID):
            guard let model = models.first(where: { $0.matches(modelID) }) else {
                return AgentSetupModelSelection(
                    modelID: modelID,
                    modelProvider: defaultAgent?.modelProvider,
                    thinkingSelection: defaultAgent?.thinkingSelection
                )
            }
            return AgentSetupModelSelection(
                modelID: model.id,
                modelProvider: modelProviderTitle(for: model),
                thinkingSelection: promptThinkingSelection(
                    for: model,
                    defaultSelection: defaultAgent?.thinkingSelection
                )
            )
        }
    }

    static func modelChoiceItems(
        models: [AgentSettingsModelManifest],
        existingModelID: String?
    ) -> [TerminalCheckboxMenuItem<AgentSetupModelChoice>] {
        var items: [TerminalCheckboxMenuItem<AgentSetupModelChoice>] = [
            TerminalCheckboxMenuItem(
                value: .noDedicatedModel,
                title: "No dedicated model",
                detail: noDedicatedModelDetail(),
                groupTitle: "None"
            )
        ]

        for group in AgentModelCatalogPresentation.groupedByProvider(models) {
            items.append(contentsOf: group.models.map { model in
                TerminalCheckboxMenuItem(
                    value: .configuredModel(model.id),
                    title: AgentModelCatalogPresentation.modelTitle(for: model, in: group),
                    detail: modelChoiceDetail(model),
                    groupTitle: group.title
                )
            })
        }

        if let existingModelID,
           !models.contains(where: { $0.matches(existingModelID) }) {
            items.append(
                TerminalCheckboxMenuItem(
                    value: .configuredModel(existingModelID),
                    title: existingModelID,
                    detail: "saved model not currently configured",
                    groupTitle: "Saved"
                )
            )
        }

        return items
    }

    static func noDedicatedModelDetail() -> String {
        if let selection = AgentSettingsStore.defaultSelection(explicitModelID: nil) {
            return "leave model empty; current default: \(selection.modelID)"
        }
        return "leave model empty; use ZenCODE default"
    }

    static func modelChoiceDetail(_ model: AgentSettingsModelManifest) -> String {
        var details = [model.modelID]
        if let thinking = model.resolvedDefaultThinkingSelection {
            details.append("thinking default: \(thinking.displayTitle)")
        }
        return details.joined(separator: " | ")
    }

    static func modelProviderTitle(for model: AgentSettingsModelManifest) -> String? {
        model.provider?.displayTitle.nilIfBlank
            ?? AgentModelCatalogPresentation.providerGroupTitle(for: model).nilIfBlank
    }

    static func promptThinkingSelection(
        for model: AgentSettingsModelManifest,
        defaultSelection: AgentThinkingSelection?
    ) -> AgentThinkingSelection? {
        guard model.supportsThinking else {
            return nil
        }
        let resolvedDefaultSelection = model.thinkingSelection(for: defaultSelection)
        return TerminalCheckboxMenu.selectOne(
            title: "Thinking for \(AgentModelCatalogPresentation.modelTitle(for: model))",
            items: thinkingSelectionItems(model.availableThinkingSelections),
            selected: resolvedDefaultSelection
        ) ?? resolvedDefaultSelection
    }

    static func thinkingSelectionItems(
        _ selections: [AgentThinkingSelection]
    ) -> [TerminalCheckboxMenuItem<AgentThinkingSelection>] {
        selections.map { selection in
            TerminalCheckboxMenuItem(
                value: selection,
                title: selection.menuTitle,
                detail: selection.rawValue
            )
        }
    }

}
