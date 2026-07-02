//
//  ZenCODESetupRunner+Prompting.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

import Foundation
import ZenCODECore

extension ZenCODESetupRunner {
    static func promptString(
        _ label: String,
        defaultValue: String?,
        allowEmpty: Bool,
        help: String? = nil
    ) throws -> String {
        while true {
            guard let value = TerminalCheckboxMenu.promptLine(
                title: "ZenCODE setup",
                prompt: label,
                defaultValue: defaultValue,
                allowEmpty: allowEmpty,
                help: help
            ) else {
                throw ZenCODESetupError.cancelled
            }
            if value.isEmpty, !allowEmpty {
                AgentOutput.standardError.writeString("\(label) is required. Enter ? for help.\n")
                continue
            }
            return value
        }
    }

    static func promptYesNo(
        _ label: String,
        defaultValue: Bool,
        help: String? = nil
    ) throws -> Bool {
        let items = [
            TerminalCheckboxMenuItem(value: true, title: "Yes", detail: nil),
            TerminalCheckboxMenuItem(value: false, title: "No", detail: nil)
        ]
        guard let value = TerminalCheckboxMenu.selectOne(
            title: label,
            items: items,
            selected: defaultValue
        ) else {
            throw ZenCODESetupError.cancelled
        }
        return value
    }

    static func promptMenuChoice<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected defaultValue: Value
    ) throws -> Value {
        guard let value = TerminalCheckboxMenu.selectOne(
            title: title,
            items: items,
            selected: defaultValue
        ) else {
            throw ZenCODESetupError.cancelled
        }
        return value
    }

    static func promptMenuSelection<Value: Hashable>(
        title: String,
        items: [TerminalCheckboxMenuItem<Value>],
        selected defaultValues: Set<Value>
    ) -> Set<Value> {
        TerminalCheckboxMenu.select(
            title: title,
            items: items,
            selected: defaultValues
        ) ?? defaultValues
    }


    static func printSetupSummary(
        manifest: AgentSettingsManifest,
        settingsWillBeWritten: Bool
    ) {
        let selectedModelTitle = selectedModel(in: manifest)?.displayTitle ?? "not selected"
        let thinkingTitle = selectedModel(in: manifest)
            .flatMap { $0.thinkingSelection(for: manifest.selectedThinkingSelection)?.displayTitle }
            ?? "default"
        let telegramStatus = manifest.telegram?.isEnabled == true ? "enabled" : "disabled"
        let voiceStatus = manifest.voice?.isConfigured == true ? "enabled" : "disabled"
        let agentsDetail = agentsSetupDetail()

        AgentOutput.standardError.writeString(
            """

            Setup summary:
              Providers: \(manifest.providers.count)
              Models: \(manifest.models.count)
              Default model: \(selectedModelTitle)
              Default thinking: \(thinkingTitle)
              Agents: \(agentsDetail)
              Telegram remote control: \(telegramStatus)
              Local voice tools: \(voiceStatus)

            Files:
              settings.json: \(settingsWillBeWritten ? "will be updated" : "unchanged")
              base support files: will be created if missing

            """
        )
    }

    static func printResult(
        _ result: ZenCODESupportFileResult,
        settingsWasWritten: Bool
    ) {
        if !result.createdFilenames.isEmpty {
            AgentOutput.standardError.writeString(
                "Created: \(result.createdFilenames.joined(separator: ", "))\n"
            )
        }
        if !result.preservedFilenames.isEmpty {
            AgentOutput.standardError.writeString(
                "Preserved: \(result.preservedFilenames.joined(separator: ", "))\n"
            )
        }
        if settingsWasWritten && !result.createdFilenames.contains(AgentSettingsManifestStore.settingsFilename) {
            AgentOutput.standardError.writeString("Updated: settings.json\n")
        }
    }
}
