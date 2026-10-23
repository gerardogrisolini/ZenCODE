//
//  ZenCODESetupRunner+VoiceModeOptions.swift
//  ZenCODE
//
//  The voice mode options of `/setup` > Voice mode, shared by the macOS and
//  Linux sections: how an utterance is sent (after a pause, or on a spoken
//  keyword) and the length past which an answer is read from its final
//  sentences only. The send mode is a two-way menu: "After a pause" goes on
//  to the preset pause that ends an utterance, "On a word" to the typed
//  keyword, so the pause is chosen only where it applies. The limit is a
//  preset menu. All are staged in the settings manifest (`voice.sendMode`,
//  `voice.sendKeyword`, `voice.utteranceSilenceSeconds`,
//  `voice.maximumSpokenCharacters`) and saved when setup finishes; voice mode
//  reads them the next time `/voice on` starts.
//

import Foundation

extension ZenCODESetupRunner {
    enum VoiceOptionAction: Hashable {
        case value(Int)
        case back
    }

    enum VoiceSendModeAction: Hashable {
        case pause
        case keyword
        case back
    }

    typealias VoiceOptionSelector = (
        String,
        [TerminalCheckboxMenuItem<VoiceOptionAction>],
        VoiceOptionAction
    ) -> VoiceOptionAction?

    typealias VoiceSendModeSelector = (
        String,
        [TerminalCheckboxMenuItem<VoiceSendModeAction>],
        VoiceSendModeAction
    ) -> VoiceSendModeAction?

    /// Asks for the keyword, with the saved one as default; nil cancels.
    typealias VoiceKeywordPrompter = (String?) -> String?

    /// Seconds of silence offered for the pause that ends an utterance.
    static let utteranceSilencePresetSeconds = [2, 3, 5, 8, 10]
    /// Characters offered for the spoken answer limit; 0 reads every answer
    /// whole.
    static let spokenCharacterPresets = [300, 600, 1_000, 2_000, 0]

    static let defaultUtteranceSilenceSeconds = TerminalVoiceOptions().utteranceSilenceSeconds
    static let defaultSpokenCharacters = TerminalVoiceOptions.defaultMaximumSpokenCharacters

    static let spokenLimitMenuTitle = "Spoken answer limit"
    static let sendModeMenuTitle = "Send mode"

    /// The effective send mode: keyword only with a usable keyword.
    static func sendsOnKeyword(manifest: AgentSettingsManifest?) -> Bool {
        TerminalVoiceOptions(voice: manifest?.voice).sendKeyword != nil
    }

    static func sendKeyword(manifest: AgentSettingsManifest?) -> String? {
        manifest?.voice?.sendKeyword
    }

    static func utteranceSilenceSeconds(manifest: AgentSettingsManifest?) -> Int {
        manifest?.voice?.utteranceSilenceSeconds ?? defaultUtteranceSilenceSeconds
    }

    /// 0 reads every answer whole.
    static func spokenCharacters(manifest: AgentSettingsManifest?) -> Int {
        manifest?.voice?.maximumSpokenCharacters ?? defaultSpokenCharacters
    }

    static func utteranceSilenceLabel(_ seconds: Int) -> String {
        "\(seconds) s"
    }

    static func spokenLimitLabel(_ characters: Int) -> String {
        characters > 0 ? "\(characters) characters" : "whole answer"
    }

    /// Menu details of the option items, e.g. "after 5 s of silence".
    static func sendModeItemDetail(manifest: AgentSettingsManifest?) -> String {
        if sendsOnKeyword(manifest: manifest), let keyword = sendKeyword(manifest: manifest) {
            return "on the word \u{201C}\(keyword)\u{201D} · silence never sends"
        }
        return "after \(utteranceSilenceLabel(utteranceSilenceSeconds(manifest: manifest))) of silence"
    }

    static func spokenLimitItemDetail(manifest: AgentSettingsManifest?) -> String {
        "\(spokenLimitLabel(spokenCharacters(manifest: manifest))) · a longer answer is read from its final sentences"
    }

    /// Main menu suffix for options that differ from the defaults, e.g.
    /// " · pause 8 s · whole answer"; empty when all are default.
    static func voiceOptionsSetupSuffix(manifest: AgentSettingsManifest?) -> String {
        var suffix = ""
        if sendsOnKeyword(manifest: manifest), let keyword = sendKeyword(manifest: manifest) {
            suffix += " · send on \u{201C}\(keyword)\u{201D}"
        }
        let silence = utteranceSilenceSeconds(manifest: manifest)
        if silence != defaultUtteranceSilenceSeconds, !sendsOnKeyword(manifest: manifest) {
            suffix += " · pause \(utteranceSilenceLabel(silence))"
        }
        let characters = spokenCharacters(manifest: manifest)
        if characters != defaultSpokenCharacters {
            suffix += " · \(spokenLimitLabel(characters))"
        }
        return suffix
    }

    /// "After a pause", "On a word" (with the saved word), then Back.
    static func sendModeMenuItems(manifest: AgentSettingsManifest?) -> [TerminalCheckboxMenuItem<VoiceSendModeAction>] {
        let keyword = sendKeyword(manifest: manifest)
        return [
            TerminalCheckboxMenuItem(
                value: .pause,
                title: "After a pause",
                detail: "the utterance is sent after the silence you choose next, now \(utteranceSilenceLabel(utteranceSilenceSeconds(manifest: manifest))) (default)"
            ),
            TerminalCheckboxMenuItem(
                value: .keyword,
                title: "On a word",
                detail: keyword.map { "the utterance is sent when you say \u{201C}\($0)\u{201D}; silence never sends" }
                    ?? "the utterance is sent when you say a word you choose; silence never sends"
            ),
            TerminalCheckboxMenuItem(
                value: .back,
                title: "Back",
                detail: "keep the current send mode"
            )
        ]
    }

    /// Chooses the send mode; "After a pause" then lists the pause that ends
    /// an utterance, with the current one preselected, and "On a word" asks
    /// for the word, with the saved one as default. Back, Esc, or a cancelled
    /// pause or word keeps the manifest unchanged.
    static func configureSendMode(
        manifest: AgentSettingsManifest?,
        write: (String) -> Void = { AgentOutput.standardError.writeString($0) },
        selectOne: VoiceSendModeSelector = {
            TerminalCheckboxMenu.selectOne(title: $0, items: $1, selected: $2)
        },
        selectPause: VoiceOptionSelector = {
            TerminalCheckboxMenu.selectOne(title: $0, items: $1, selected: $2)
        },
        promptKeyword: VoiceKeywordPrompter = { saved in
            try? promptString(
                "Word that sends the utterance",
                defaultValue: saved,
                allowEmpty: false,
                help: "One word you will say at the end of what you dictate, e.g. \"vai\" or \"done\"; it is removed from the prompt. Esc keeps the current send mode."
            )
        }
    ) -> AgentSettingsManifest? {
        let current: VoiceSendModeAction = sendsOnKeyword(manifest: manifest) ? .keyword : .pause
        guard let action = selectOne(
            "\(sendModeMenuTitle): how voice mode decides that you finished speaking",
            sendModeMenuItems(manifest: manifest),
            current
        ) else {
            return manifest
        }
        switch action {
        case .back:
            return manifest
        case .pause:
            let current = utteranceSilenceSeconds(manifest: manifest)
            guard let pause = selectPause(
                "After a pause: silence after you stop speaking that sends the utterance",
                utteranceSilenceMenuItems(current: current),
                .value(current)
            ), case let .value(seconds) = pause else {
                return manifest
            }
            write("Send mode: after \(utteranceSilenceLabel(seconds)) of silence.\n\n")
            return manifestByUpdatingVoice(manifest) { voice in
                AgentVoiceSettingsManifest(
                    enabled: voice?.enabled ?? false,
                    macOSVoiceIdentifier: voice?.macOSVoiceIdentifier,
                    utteranceSilenceSeconds: seconds,
                    maximumSpokenCharacters: voice?.maximumSpokenCharacters,
                    sendMode: voice?.sendKeyword == nil ? nil : .pause,
                    sendKeyword: voice?.sendKeyword
                )
            }
        case .keyword:
            while true {
                guard let typed = promptKeyword(sendKeyword(manifest: manifest)) else {
                    return manifest
                }
                guard let keyword = TerminalVoiceSendKeyword(typed) else {
                    write("The word must contain letters or digits.\n")
                    continue
                }
                if TerminalVoiceChatPhrases.affirmation(in: keyword.text) != nil {
                    write("\u{201C}\(keyword.text)\u{201D} is a spoken yes or no and cannot send utterances; choose another word.\n")
                    continue
                }
                write("Send mode: on the word \u{201C}\(keyword.text)\u{201D}.\n\n")
                return manifestByUpdatingVoice(manifest) { voice in
                    AgentVoiceSettingsManifest(
                        enabled: voice?.enabled ?? false,
                        macOSVoiceIdentifier: voice?.macOSVoiceIdentifier,
                        utteranceSilenceSeconds: voice?.utteranceSilenceSeconds,
                        maximumSpokenCharacters: voice?.maximumSpokenCharacters,
                        sendMode: .keyword,
                        sendKeyword: keyword.text
                    )
                }
            }
        }
    }

    /// The presets, plus a saved value that is not one of them, then Back.
    static func utteranceSilenceMenuItems(current: Int) -> [TerminalCheckboxMenuItem<VoiceOptionAction>] {
        let seconds = Set(utteranceSilencePresetSeconds + [current]).sorted()
        var items = seconds.map { value in
            TerminalCheckboxMenuItem(
                value: VoiceOptionAction.value(value),
                title: utteranceSilenceLabel(value),
                detail: value == defaultUtteranceSilenceSeconds ? "default" : ""
            )
        }
        items.append(TerminalCheckboxMenuItem(
            value: .back,
            title: "Back",
            detail: "keep the current send mode"
        ))
        return items
    }

    static func spokenLimitMenuItems(current: Int) -> [TerminalCheckboxMenuItem<VoiceOptionAction>] {
        // 0 (whole answer) sorts last.
        let characters = Set(spokenCharacterPresets + [current]).sorted { lhs, rhs in
            switch (lhs, rhs) {
            case (0, _): return false
            case (_, 0): return true
            default: return lhs < rhs
            }
        }
        var items = characters.map { value in
            TerminalCheckboxMenuItem(
                value: VoiceOptionAction.value(value),
                title: spokenLimitLabel(value),
                detail: value == defaultSpokenCharacters ? "default" : ""
            )
        }
        items.append(TerminalCheckboxMenuItem(
            value: .back,
            title: "Back",
            detail: "keep \(spokenLimitLabel(current))"
        ))
        return items
    }

    /// Chooses the spoken answer limit; Back or Esc keeps the manifest
    /// unchanged.
    static func configureSpokenLimit(
        manifest: AgentSettingsManifest?,
        write: (String) -> Void = { AgentOutput.standardError.writeString($0) },
        selectOne: VoiceOptionSelector = {
            TerminalCheckboxMenu.selectOne(title: $0, items: $1, selected: $2)
        }
    ) -> AgentSettingsManifest? {
        let current = spokenCharacters(manifest: manifest)
        guard let action = selectOne(
            "\(spokenLimitMenuTitle): a longer answer is read from its final sentences after a short notice",
            spokenLimitMenuItems(current: current),
            .value(current)
        ), case let .value(characters) = action else {
            return manifest
        }
        write("Spoken answer limit: \(spokenLimitLabel(characters)).\n\n")
        return manifestByUpdatingVoice(manifest) { voice in
            AgentVoiceSettingsManifest(
                enabled: voice?.enabled ?? false,
                macOSVoiceIdentifier: voice?.macOSVoiceIdentifier,
                utteranceSilenceSeconds: voice?.utteranceSilenceSeconds,
                maximumSpokenCharacters: characters,
                sendMode: voice?.sendMode,
                sendKeyword: voice?.sendKeyword
            )
        }
    }

    /// Replaces the voice settings, keeping every other setting. An unchanged
    /// result returns `manifest` as is.
    static func manifestByUpdatingVoice(
        _ manifest: AgentSettingsManifest?,
        _ update: (AgentVoiceSettingsManifest?) -> AgentVoiceSettingsManifest?
    ) -> AgentSettingsManifest? {
        let updated = update(manifest?.voice)
        // Settings with nothing to store are absent, as the manifest keeps them.
        let voice = updated?.isEmpty == false ? updated : nil
        guard voice != manifest?.voice else {
            return manifest
        }
        return AgentSettingsManifest(
            version: manifest?.version ?? AgentSettingsManifest.currentVersion,
            providers: manifest?.providers ?? [],
            models: manifest?.models ?? [],
            selectedModelID: manifest?.selectedModelID,
            selectedThinkingSelection: manifest?.selectedThinkingSelection,
            telegram: manifest?.telegram,
            voice: voice,
            remoteAPIKeysByProviderID: manifest?.remoteAPIKeysByProviderID ?? [:],
            localExecAllowedCommands: manifest?.localExecAllowedCommands ?? [],
            chatGPTSubscriptionCredentials: manifest?.chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: manifest?.anthropicSubscriptionCredentials,
            responseLanguage: manifest?.responseLanguage,
            memoryEmbedding: manifest?.memoryEmbedding
        )
    }
}
