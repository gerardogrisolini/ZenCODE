//
//  ZenCODESetupRunner+VoiceMode.swift
//  ZenCODE
//
//  The Linux "Voice mode" setup section. It downloads the pinned sherpa-onnx
//  programs, speech recognition model and the Piper voice the operator picks
//  for the voice language, verifies each file against its SHA-256 checksum,
//  and installs them under `<support directory>/voice`. Like Data
//  management it acts immediately: nothing is staged in the settings
//  manifest, and cancelling setup does not undo a download.
//

import Foundation
import Synchronization

extension ZenCODESetupRunner {
    enum VoiceModeAction: Hashable {
        case sendMode
        case voice(String)
        case remove
        case back
    }

    static func voiceModeSetupDetail(
        installation: SherpaOnnxVoiceInstallation = .standard()
    ) -> String {
        if case .success = installation.runtimePaths(),
           let voice = installation.installedVoices().first {
            return "voice \(voice.speaker) (\(voice.locale))"
        }
        return installation.hasInstalledFiles ? "incomplete download" : "not installed"
    }

    static func voiceModeIsReady(
        installation: SherpaOnnxVoiceInstallation = .standard()
    ) -> Bool {
        if case .success = installation.runtimePaths() {
            return true
        }
        return false
    }

    /// The response language, else the system language — the same order
    /// voice mode uses at runtime.
    static func voiceModeLanguageCode(manifest: AgentSettingsManifest?) -> String {
        VoiceLanguage.resolvedCode(manifest: manifest)
    }

    /// Voices for `languageCode`, or every voice when none matches.
    static func voiceModeChoices(
        languageCode: String
    ) -> (voices: [SherpaOnnxVoice], matchesLanguage: Bool) {
        let matching = SherpaOnnxVoiceCatalog.voices(forLanguage: languageCode)
        if matching.isEmpty {
            return (SherpaOnnxVoiceCatalog.voices, false)
        }
        return (matching, true)
    }

    /// The voice mode options, the voices, "Remove" once something is
    /// installed, then "Back".
    static func voiceModeMenuItems(
        voices: [SherpaOnnxVoice],
        installation: SherpaOnnxVoiceInstallation,
        manifest: AgentSettingsManifest? = nil
    ) -> [TerminalCheckboxMenuItem<VoiceModeAction>] {
        let installed = Set(installation.installedVoices().map(\.id))
        var items = [
            TerminalCheckboxMenuItem(
                value: VoiceModeAction.sendMode,
                title: sendModeMenuTitle,
                detail: sendModeItemDetail(manifest: manifest)
            )
        ]
        items += voices.map { voice in
            var detail = "\(voice.locale) · \(voice.quality.map { $0.replacingOccurrences(of: "_", with: " ") } ?? "standard") · \(megabytes(voice.asset.byteCount))"
            if installed.contains(voice.id) {
                detail += " · installed"
            }
            return TerminalCheckboxMenuItem(
                value: VoiceModeAction.voice(voice.id),
                title: voice.speaker,
                detail: detail
            )
        }
        if installation.hasInstalledFiles {
            items.append(TerminalCheckboxMenuItem(
                value: .remove,
                title: "Remove voice mode files",
                detail: "delete every downloaded program, model and voice"
            ))
        }
        items.append(TerminalCheckboxMenuItem(
            value: .back,
            title: "Back",
            detail: "return to the main setup menu"
        ))
        return items
    }

    static func megabytes(_ bytes: Int64) -> String {
        "\(max(1, Int((Double(bytes) / 1_000_000).rounded()))) MB"
    }

    /// Downloads a voice or removes the files, and stages the voice mode
    /// options; returns the manifest with the options staged.
    static func configureVoiceMode(
        manifest initialManifest: AgentSettingsManifest?,
        installation: SherpaOnnxVoiceInstallation = .standard()
    ) async throws -> AgentSettingsManifest? {
        var manifest = initialManifest
        AgentOutput.standardError.writeString(
            """

            Voice mode listens with the sherpa-onnx speech recognizer (Parakeet, 25
            European languages) and reads answers aloud with a Piper voice. Files are
            downloaded from the sherpa-onnx GitHub releases, checked against pinned
            SHA-256 checksums, and stored in:
            \(installation.directoryURL.path)
            The options are saved when setup finishes and apply the next time /voice on
            starts.
            Status: \(voiceModeSetupDetail(installation: installation))\(voiceOptionsSetupSuffix(manifest: manifest))

            """
        )
        let languageCode = voiceModeLanguageCode(manifest: manifest)
        let choices = voiceModeChoices(languageCode: languageCode)
        if !choices.matchesLanguage {
            AgentOutput.standardError.writeString(
                "No voice reads the \"\(languageCode)\" language; every voice is listed.\n"
            )
        }
        var selected = installation.installedVoices().first.map { VoiceModeAction.voice($0.id) }
            ?? choices.voices.first.map { VoiceModeAction.voice($0.id) }
            ?? .back
        while true {
            let items = voiceModeMenuItems(
                voices: choices.voices,
                installation: installation,
                manifest: manifest
            )
            guard let action = TerminalCheckboxMenu.selectOne(
                title: choices.matchesLanguage
                    ? "Voice mode (\(languageCode)): options and the voice that reads answers aloud"
                    : "Voice mode: options and the voice that reads answers aloud",
                items: items,
                selected: selected
            ) else {
                return manifest
            }

            switch action {
            case .back:
                return manifest
            case .sendMode:
                manifest = configureSendMode(manifest: manifest)
                selected = action
            case .remove:
                guard try promptYesNo(
                    "Remove the voice mode files?",
                    defaultValue: false,
                    help: "Deletes \(installation.directoryURL.path). Voice mode needs them again before /voice on works."
                ) else {
                    return manifest
                }
                do {
                    try SherpaOnnxVoiceInstaller(installation: installation).removeAll()
                    AgentOutput.standardError.writeString("Voice mode files removed.\n\n")
                } catch {
                    AgentOutput.standardError.writeString(
                        "Voice mode files could not be removed: \(error.localizedDescription)\n\n"
                    )
                }
                return manifest
            case let .voice(id):
                guard let voice = SherpaOnnxVoiceCatalog.voice(id: id) else {
                    return manifest
                }
                try await installVoiceMode(voice: voice, installation: installation)
                return manifest
            }
        }
    }

    static func installVoiceMode(
        voice: SherpaOnnxVoice,
        installation: SherpaOnnxVoiceInstallation
    ) async throws {
        let installer = SherpaOnnxVoiceInstaller(installation: installation)
        guard let missing = installation.missingAssets(for: voice) else {
            AgentOutput.standardError.writeString(
                "\(SherpaOnnxVoiceInstallError.unsupportedArchitecture.localizedDescription)\n\n"
            )
            return
        }
        if !missing.isEmpty {
            let total = missing.reduce(Int64(0)) { $0 + $1.byteCount }
            let list = missing.map { "\($0.title), \(megabytes($0.byteCount))" }
                .joined(separator: "; ")
            guard try promptYesNo(
                "Download \(megabytes(total)) for voice mode?",
                defaultValue: true,
                help: "Downloads: \(list)."
            ) else {
                return
            }
        }
        let printer = VoiceModeDownloadPrinter()
        do {
            try await installer.install(voice: voice) { step in
                printer.report(step)
            }
            printer.finish()
            AgentOutput.standardError.writeString(
                "Voice mode is ready with the voice \(voice.speaker) (\(voice.locale)). Run /voice on in the terminal to start it.\n\n"
            )
        } catch {
            printer.finish()
            AgentOutput.standardError.writeString(
                "Voice mode download failed: \(error.localizedDescription)\nNothing incomplete was installed; choose the voice again to retry.\n\n"
            )
        }
    }
}

/// Prints download progress on one line per file, updating at most once per
/// percent.
final class VoiceModeDownloadPrinter: Sendable {
    private struct State {
        var currentFile: String?
        var lastPercent = -1
        var lineOpen = false
    }

    private let state = Mutex(State())

    func report(_ step: SherpaOnnxVoiceInstaller.Step) {
        let output: String? = state.withLock { state in
            switch step {
            case let .downloading(asset, received):
                let percent = asset.byteCount > 0 ? Int(received * 100 / asset.byteCount) : 100
                guard state.currentFile != asset.fileName || percent != state.lastPercent else {
                    return nil
                }
                state.currentFile = asset.fileName
                state.lastPercent = percent
                state.lineOpen = true
                return "\r  Downloading \(asset.title): \(percent)% of \(ZenCODESetupRunner.megabytes(asset.byteCount))"
            case let .unpacking(asset):
                let prefix = state.lineOpen ? "\n" : ""
                state.lineOpen = false
                return "\(prefix)  Unpacking \(asset.title)...\n"
            case let .installed(asset):
                let prefix = state.lineOpen ? "\n" : ""
                state.lineOpen = false
                state.currentFile = nil
                state.lastPercent = -1
                return "\(prefix)  Installed \(asset.title).\n"
            }
        }
        if let output {
            AgentOutput.standardError.writeString(output)
        }
    }

    func finish() {
        let lineOpen = state.withLock { state in
            defer { state.lineOpen = false }
            return state.lineOpen
        }
        if lineOpen {
            AgentOutput.standardError.writeString("\n")
        }
    }
}
