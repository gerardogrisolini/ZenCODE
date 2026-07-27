//
//  ZenCODESetupRunner+Prompting.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 14/06/26.
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
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

    /// Prompts for a sensitive value (API key, token, authorization code) whose
    /// typed text must never be echoed to the terminal.
    ///
    /// Unlike ``promptString``, which uses the full TUI line editor and reflects
    /// every keystroke, this disables terminal echo via termios while a single
    /// line is read, so the secret stays hidden. Esc/EOF is treated as a cancel.
    static func promptSecret(
        _ label: String,
        allowEmpty: Bool,
        help: String? = nil
    ) throws -> String {
        while true {
            let helpHint = help != nil ? " (enter ? for help)" : ""
            AgentOutput.standardError.writeString("\(label)\(helpHint): ")
            guard let rawValue = SecretLineReader.read() else {
                AgentOutput.standardError.writeString("\n")
                throw ZenCODESetupError.cancelled
            }
            AgentOutput.standardError.writeString("\n")

            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "?", let help {
                AgentOutput.standardError.writeString("\(help)\n")
                continue
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
        #if canImport(AVFoundation)
        let voiceStatus = manifest.voice?.isConfigured == true ? "enabled" : "disabled"
        let voiceSummary = "\n  Local voice tools: \(voiceStatus)"
        #else
        let voiceSummary = ""
        #endif
        let agentsDetail = agentsSetupDetail()
        let responseLanguageDetail = responseLanguageSetupDetail(manifest)

        AgentOutput.standardError.writeString(
            """

            Setup summary:
              Providers: \(manifest.providers.count)
              Models: \(manifest.models.count)
              Default model: \(selectedModelTitle)
              Default thinking: \(thinkingTitle)
              Agents: \(agentsDetail)
              Response language: \(responseLanguageDetail)
              Telegram remote control: \(telegramStatus)\(voiceSummary)

            Files:
              settings.json: \(settingsWillBeWritten ? "will be updated" : "unchanged")
              base support files: will be created if missing

            """
        )
    }

    static func printResult(
        _ result: ZenFileResult,
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

/// Reads a single line from stdin with terminal echo disabled, so typed secrets
/// are not reflected. When stdin is not an interactive terminal (piped input,
/// tests), masking is moot and a plain line read is used instead.
private enum SecretLineReader {
    static func read() -> String? {
        var settings = termios()
        guard tcgetattr(STDIN_FILENO, &settings) == 0 else {
            return Swift.readLine()
        }

        let original = settings
        settings.c_lflag &= ~tcflag_t(ECHO)
        settings.c_lflag |= tcflag_t(ECHONL)
        let didApply = tcsetattr(STDIN_FILENO, TCSANOW, &settings) == 0
        defer {
            if didApply {
                var restored = original
                tcsetattr(STDIN_FILENO, TCSANOW, &restored)
            }
        }
        return Swift.readLine()
    }
}
