//
//  ZenDoctor+Configuration.swift
//  ZenCODE
//
//  The configuration section of the doctor report: setup status, models, selected model and agents.
//

import Foundation
import ToolCore

extension ZenDoctor {
    // MARK: - Configuration

    static func configurationSection(
        paths: ManifestPaths,
        fileManager: FileManager
    ) -> ZenDoctorSection {
        var checks: [ZenDoctorCheck] = []

        let settingsURL = paths.settings
        let agentsURL = paths.agents

        // Read-only setup status. The manifests are decoded directly from their
        // raw bytes rather than through the manifest stores, which call
        // `SensitiveFilePermissions.hardenExistingFile` on load and would mutate
        // file permissions. The doctor must inspect without side effects.
        let settingsRead = readSettingsManifest(at: settingsURL, fileManager: fileManager)
        let agentsRead = readAgentProfiles(at: agentsURL, fileManager: fileManager)
        checks.append(setupStatusCheck(
            settingsRead: settingsRead,
            agentsRead: agentsRead,
            settingsURL: settingsURL,
            agentsURL: agentsURL
        ))

        // settings.json contains provider keys, so its privacy is worth checking
        // whenever the file is present (even if it does not decode).
        if case .missing = settingsRead {
            // No file: nothing to report.
        } else {
            checks.append(filePrivacyCheck(
                id: "configuration.settingsPrivacy",
                title: "settings.json privacy",
                url: settingsURL,
                fileManager: fileManager
            ))
        }

        // Model configuration summary (counts and names only, never keys).
        if case let .value(manifest) = settingsRead {
            checks.append(modelsCheck(manifest))
            checks.append(selectedModelCheck(manifest))
        } else {
            checks.append(
                ZenDoctorCheck(
                    id: "configuration.models",
                    title: "Providers and models",
                    status: .warning,
                    detail: "No readable settings.json, so no models are configured.",
                    remedy: "Run zen --setup to configure at least one model."
                )
            )
            checks.append(
                ZenDoctorCheck(
                    id: "configuration.selectedModel",
                    title: "Default model & thinking",
                    status: .warning,
                    detail: "No readable settings.json, so no default model or thinking level can be verified.",
                    remedy: "Run zen --setup to configure the default model and thinking level."
                )
            )
        }

        // Agents manifest summary (names only). Keep this required check visible
        // even when the manifest is missing or invalid.
        checks.append(agentsCheck(agentsRead, agentsURL: agentsURL))
        if case .missing = agentsRead {
            // No file: there is no privacy mode to inspect.
        } else {
            checks.append(filePrivacyCheck(
                id: "configuration.agentsPrivacy",
                title: "agents.json privacy",
                url: agentsURL,
                fileManager: fileManager
            ))
        }

        return ZenDoctorSection(title: "Configuration", checks: checks)
    }

    private static func setupStatusCheck(
        settingsRead: ManifestReadOutcome<AgentSettingsManifest>,
        agentsRead: ManifestReadOutcome<[AgentProfile]>,
        settingsURL: URL,
        agentsURL: URL
    ) -> ZenDoctorCheck {
        // Agents are validated first, mirroring ZenInspector, so a missing or
        // invalid agents.json is reported before settings.json.
        switch agentsRead {
        case .missing:
            return ZenDoctorCheck(
                id: "configuration.setup",
                title: "Setup",
                status: .warning,
                detail: "Missing agents.json at \(agentsURL.path).",
                remedy: "Run zen --setup to create the missing configuration."
            )
        case .invalid:
            return ZenDoctorCheck(
                id: "configuration.setup",
                title: "Setup",
                status: .failure,
                detail: "agents.json at \(agentsURL.path) could not be read.",
                remedy: "Repair or recreate the file, or run zen --setup to rewrite it."
            )
        case .value:
            break
        }

        switch settingsRead {
        case .missing:
            return ZenDoctorCheck(
                id: "configuration.setup",
                title: "Setup",
                status: .warning,
                detail: "Missing settings.json at \(settingsURL.path).",
                remedy: "Run zen --setup to create the missing configuration."
            )
        case .invalid:
            return ZenDoctorCheck(
                id: "configuration.setup",
                title: "Setup",
                status: .failure,
                detail: "settings.json at \(settingsURL.path) could not be read.",
                remedy: "Repair or recreate the file, or run zen --setup to rewrite it."
            )
        case .value:
            return ZenDoctorCheck(
                id: "configuration.setup",
                title: "Setup",
                status: .ok,
                detail: "ZenCODE is configured."
            )
        }
    }

    private static func modelsCheck(_ manifest: AgentSettingsManifest) -> ZenDoctorCheck {
        let count = manifest.models.count
        let remoteProvidersWithoutKey = manifest.models.compactMap { model -> AgentRemoteProvider? in
            guard model.kind == .remoteAPI,
                  let provider = model.provider,
                  provider.requiresAPIKey else {
                return nil
            }
            guard manifest.apiKey(providerID: provider.id) == nil,
                  model.apiKey?.nilIfBlank == nil else {
                return nil
            }
            return provider
        }

        if count == 0 {
            return ZenDoctorCheck(
                id: "configuration.models",
                title: "Providers and models",
                status: .warning,
                detail: "No models are configured.",
                remedy: "Run zen --setup to configure at least one model."
            )
        }

        if !remoteProvidersWithoutKey.isEmpty {
            let modelsByProviderID = Dictionary(grouping: remoteProvidersWithoutKey) { provider in
                provider.id
            }
            let providers: [(id: String, title: String, modelCount: Int)] = modelsByProviderID.map { entry in
                let provider = entry.value[0]
                return (
                    id: entry.key,
                    title: provider.displayTitle,
                    modelCount: entry.value.count
                )
            }.sorted { lhs, rhs in
                let titleComparison = lhs.title.compare(
                    rhs.title,
                    options: String.CompareOptions.caseInsensitive,
                    locale: Locale(identifier: "en_US_POSIX")
                )
                if titleComparison == .orderedSame {
                    return lhs.id < rhs.id
                }
                return titleComparison == .orderedAscending
            }
            let summary = providers.map { provider in
                "\(provider.title) (\(provider.modelCount) model(s))"
            }.joined(separator: ", ")
            return ZenDoctorCheck(
                id: "configuration.models",
                title: "Providers and models",
                status: .warning,
                detail: "\(count) model(s) configured; \(providers.count) remote provider(s) have no stored API key: \(summary).",
                remedy: "Run zen --setup to save an API key for each provider."
            )
        }

        return ZenDoctorCheck(
            id: "configuration.models",
            title: "Providers and models",
            status: .ok,
            detail: "\(count) model(s) configured."
        )
    }

    private static func selectedModelCheck(_ manifest: AgentSettingsManifest) -> ZenDoctorCheck {
        guard let selected = manifest.selectedModelID?.nilIfBlank else {
            return ZenDoctorCheck(
                id: "configuration.selectedModel",
                title: "Default model & thinking",
                status: .warning,
                detail: "No default model is selected, so its thinking level cannot be verified.",
                remedy: "Select a default model and thinking level with zen --setup."
            )
        }
        guard let model = manifest.models.first(where: { $0.matches(selected) }) else {
            return ZenDoctorCheck(
                id: "configuration.selectedModel",
                title: "Default model & thinking",
                status: .warning,
                detail: "Default model \(selected) is not among configured models, so its thinking level cannot be verified.",
                remedy: "Reselect a configured model and thinking level with zen --setup."
            )
        }
        let thinking = model.supportsThinking
            ? model.thinkingSelection(for: manifest.selectedThinkingSelection)?.displayTitle ?? "default"
            : "not supported"
        return ZenDoctorCheck(
            id: "configuration.selectedModel",
            title: "Default model & thinking",
            status: .ok,
            detail: "Default model is \(selected); thinking: \(thinking)."
        )
    }

    private static func agentsCheck(
        _ agentsRead: ManifestReadOutcome<[AgentProfile]>,
        agentsURL: URL
    ) -> ZenDoctorCheck {
        switch agentsRead {
        case .missing:
            return ZenDoctorCheck(
                id: "configuration.agents",
                title: "Agents",
                status: .warning,
                detail: "Missing agents.json at \(agentsURL.path).",
                remedy: "Run zen --setup; it creates the default agent profiles."
            )
        case .invalid:
            return ZenDoctorCheck(
                id: "configuration.agents",
                title: "Agents",
                status: .failure,
                detail: "agents.json at \(agentsURL.path) could not be read.",
                remedy: "Repair or recreate the file, or run zen --setup to rewrite it."
            )
        case let .value(agents):
            return ZenDoctorCheck(
                id: "configuration.agents",
                title: "Agents",
                status: agents.isEmpty ? .warning : .ok,
                detail: agents.isEmpty
                    ? "No agent profiles are configured."
                    : "\(agents.count) agent profile(s): \(agents.map(\.displayName).joined(separator: ", ")).",
                remedy: agents.isEmpty
                    ? "Run zen --setup; it creates the default agent profiles."
                    : nil
            )
        }
    }
}
