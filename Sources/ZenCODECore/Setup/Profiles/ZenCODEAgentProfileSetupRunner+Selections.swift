//
//  ZenCODEAgentProfileSetupRunner+Selections.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

extension ZenCODEAgentProfileSetupRunner {
    /// The tools of the agent being added or edited. Esc throws
    /// `ZenCODESetupError.cancelled`, so the agent is left as it was.
    static func promptToolSelection(
        title: String,
        defaultTools: [String]
    ) throws -> [String] {
        let items = toolSelectionItems(existingTools: defaultTools)
        guard !items.isEmpty else {
            return defaultTools
        }
        let selectedKeys = ChatSessionController.toolSelectionKeys(
            from: defaultTools,
            items: items
        )
        let selection = try ZenCODESetupRunner.promptMenuSelection(
            title: title,
            items: TerminalChat.toolCheckboxItems(items: items),
            selected: selectedKeys
        )
        return TerminalToolSelectionCatalog.selectedKeyNames(
            selection,
            items: items
        )
    }

    static func toolSelectionItems(
        existingTools: [String]
    ) -> [TerminalToolSelectionItem] {
        return TerminalToolSelectionCatalog.items(
            featureStatuses: SwiftFeatureRuntime.defaultFeatureStatuses()
        )
    }

    /// The prompt skills of the agent being added or edited. Skills are
    /// identified by their canonical name: the saved names are matched to the
    /// installed skills case-insensitively. Esc throws
    /// `ZenCODESetupError.cancelled`, so the agent is left as it was.
    static func promptSkillSelection(
        title: String,
        defaultSkills: [AgentProfileSkill]
    ) throws -> [AgentProfileSkill] {
        let availableSkills = PromptSkillCatalog.discoverSkills(
            searchRoots: PromptSkillCatalog.appCatalogSearchRoots()
        )
        let selectedSkillNames = Set(defaultSkills.compactMap { skill in
            skill.matchingSkillName(in: availableSkills) ?? skill.name.nilIfBlank
        })
        let items = skillCheckboxItems(
            availableSkills: availableSkills,
            selectedSkillNames: selectedSkillNames
        )
        guard !items.isEmpty else {
            AgentOutput.standardError.writeString("No prompt skills installed by the app.\n")
            return defaultSkills
        }
        let selection = try ZenCODESetupRunner.promptMenuSelection(
            title: title,
            items: items,
            selected: selectedSkillNames
        )
        return selection.sorted().map { AgentProfileSkill(name: $0) }
    }

    /// The menu entries of the setup's skill selection: every installed skill
    /// (valued by its canonical name), then the `selectedSkillNames` that no
    /// installed skill has, compared case-insensitively.
    static func skillCheckboxItems(
        availableSkills: [PromptSkill],
        selectedSkillNames: Set<String>
    ) -> [TerminalCheckboxMenuItem<String>] {
        let availableNameKeys = Set(availableSkills.map { $0.canonicalName.selectionKey })
        let availableItems = availableSkills.map { skill in
            let canonicalName = skill.canonicalName == skill.title
                ? ""
                : " (\(skill.canonicalName))"
            return TerminalCheckboxMenuItem(
                value: skill.canonicalName,
                title: "\(skill.title)\(canonicalName)",
                detail: truncatedInline(skill.summary, limit: 96)
            )
        }
        let missingItems = selectedSkillNames
            .filter { !availableNameKeys.contains($0.selectionKey) }
            .sorted()
            .map { skillName in
                TerminalCheckboxMenuItem(
                    value: skillName,
                    title: skillName,
                    detail: "saved skill not currently installed",
                    groupTitle: "Saved"
                )
            }
        return availableItems + missingItems
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

    /// The thinking selection of a model binding being added or edited, or
    /// `nil` when the model does not think. Esc throws
    /// `ZenCODESetupError.cancelled`, so the binding is left as it was.
    static func promptThinkingSelection(
        for model: AgentSettingsModelManifest,
        defaultSelection: AgentThinkingSelection?
    ) throws -> AgentThinkingSelection? {
        guard model.supportsThinking else {
            return nil
        }
        let resolvedDefaultSelection = model.thinkingSelection(for: defaultSelection)
        guard let selection = TerminalCheckboxMenu.selectOne(
            title: "Thinking for \(AgentModelCatalogPresentation.modelTitle(for: model))",
            items: thinkingSelectionItems(model.availableThinkingSelections),
            selected: resolvedDefaultSelection
        ) else {
            throw ZenCODESetupError.cancelled
        }
        return selection
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
