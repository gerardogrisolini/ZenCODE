//
//  ZenCODESetupRunner+DS4.swift
//  ZenCODE
//
//  Read-only DS4 discovery and staged setup integration.
//

import Foundation

extension ZenCODESetupRunner {
    /// Stable identity for the optional local DS4 provider created by setup.
    /// The provider remains an ordinary OpenAI-compatible provider; runtime
    /// metadata is what lets the backend create a supervisor lazily later.
    static let ds4SetupProviderID = UUID(
        uuidString: "00000000-0000-0000-0000-000000000005"
    )!

    static let ds4SetupProviderBaseURL = "http://127.0.0.1/v1"
    static let ds4SetupProviderName = "DS4 (local)"

    /// Configures the optional local DS4 provider without touching the DS4
    /// checkout or writing settings. The returned manifest is folded into the
    /// caller's ``SetupSession`` and is persisted only by the normal setup
    /// transaction at the end of the wizard.
    ///
    /// There is deliberately one path prompt. Hardware probing and model
    /// compatibility are read-only; a confirmation is offered only for an
    /// installed, catalog-recognized and operational proposal. Missing GGUFs,
    /// unknown hardware, invalid paths and cancellation all return the input
    /// manifest unchanged.
    static func configureDS4Runtime(
        existingManifest: AgentSettingsManifest?,
        scanner: DS4InstallationScanner = DS4InstallationScanner(),
        catalog: DS4ModelCatalog = .default,
        hardwareProbe: (@Sendable () async -> DS4HardwareSnapshot)? = nil,
        promptFolder: ((String?) throws -> String?)? = nil,
        confirmProposal: ((DS4CompatibilityProposal) throws -> Bool)? = nil,
        selectProposal: (([DS4CompatibilityProposal], DS4CompatibilityProposal) throws -> DS4CompatibilityProposal?)? = nil
    ) async throws -> AgentSettingsManifest? {
        do {
            let previousRuntime = existingDS4Runtime(in: existingManifest)
            let folder: String?
            if let promptFolder {
                folder = try promptFolder(previousRuntime?.rootDirectory)
            } else {
                folder = try promptString(
                    "DS4 folder",
                    defaultValue: previousRuntime?.rootDirectory,
                    allowEmpty: false,
                    help: "Enter the existing DS4 checkout folder. Setup only scans it; it never builds or downloads DS4."
                )
            }
            guard let folder, !folder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return existingManifest
            }

            let installation = try scanner.scan(rootDirectory: folder)
            guard !installation.artifacts.isEmpty else {
                AgentOutput.standardError.writeString(
                    "No GGUF model was found in the DS4 folder. Nothing was changed.\n"
                )
                return existingManifest
            }

            let hardware = if let hardwareProbe {
                await hardwareProbe()
            } else {
                await DS4HardwareProbe().probe()
            }
            let report = DS4CompatibilityAdvisor(catalog: catalog).advise(
                hardware: hardware,
                installation: installation
            )
            printDS4CompatibilitySummary(
                hardware: hardware,
                installation: installation,
                report: report
            )

            let candidates = installedOperationalDS4Proposals(
                in: report,
                installation: installation
            )
            guard !candidates.isEmpty else {
                AgentOutput.standardError.writeString(
                    "No installed GGUF model is both recognized and compatible with this hardware. Nothing was changed.\n"
                )
                return existingManifest
            }
            let recommended = report.recommended.flatMap { candidate in
                candidates.contains(candidate) ? candidate : nil
            } ?? candidates[0]
            let proposal: DS4CompatibilityProposal
            if let selectProposal {
                guard let selected = try selectProposal(candidates, recommended),
                      candidates.contains(selected) else {
                    return existingManifest
                }
                proposal = selected
            } else if candidates.count == 1 {
                proposal = candidates[0]
            } else {
                let items = candidates.enumerated().map { index, candidate in
                    TerminalCheckboxMenuItem(
                        value: index,
                        title: candidate.model.displayName,
                        detail: "\(candidate.status.rawValue), \(candidate.model.id)"
                    )
                }
                let defaultIndex = candidates.firstIndex(of: recommended) ?? 0
                let selectedIndex = try promptMenuChoice(
                    title: "Select installed DS4 model",
                    items: items,
                    selected: defaultIndex
                )
                guard candidates.indices.contains(selectedIndex) else {
                    return existingManifest
                }
                proposal = candidates[selectedIndex]
            }

            let confirmed: Bool
            if let confirmProposal {
                confirmed = try confirmProposal(proposal)
            } else {
                confirmed = try promptYesNo(
                    "Use installed DS4 model \(proposal.model.displayName)?",
                    defaultValue: true,
                    help: "Only this installed, compatible GGUF can be added. Setup will not download, build, or start DS4."
                )
            }
            guard confirmed else {
                AgentOutput.standardError.writeString("DS4 setup was not confirmed. Nothing was changed.\n")
                return existingManifest
            }

            guard let artifact = proposal.model.artifacts.first,
                  artifact.role == .model else {
                // ``installedOperationalDS4Proposal`` already excludes split
                // or shard-only catalog entries. Keep this guard adjacent to
                // runtime construction so a future catalog cannot bypass it.
                return existingManifest
            }
            let modelURL = try AgentDS4PathGuard.resolveModelURL(
                rootDirectory: installation.rootDirectory,
                modelRelativePath: artifact.relativePath
            )
            guard modelURL.pathExtension.lowercased() == "gguf" else {
                return existingManifest
            }

            let runtime = try AgentDS4RuntimeManifest(
                rootDirectory: installation.rootDirectory,
                modelRelativePath: artifact.relativePath,
                backend: proposal.backend ?? .cpu,
                contextWindow: previousRuntime?.contextWindow ?? 65_536,
                batchedSessions: previousRuntime?.batchedSessions ?? false,
                ssdStreaming: proposal.mode == .ssdStreaming
                    || (previousRuntime?.ssdStreaming ?? false),
                ssdStreamingCacheExperts: previousRuntime?.ssdStreamingCacheExperts,
                ssdStreamingCacheBytes: previousRuntime?.ssdStreamingCacheBytes,
                ssdStreamingPreloadExperts: previousRuntime?.ssdStreamingPreloadExperts,
                ssdStreamingCold: previousRuntime?.ssdStreamingCold ?? false
            )
            return manifestByApplyingDS4(
                existingManifest,
                runtime: runtime,
                proposal: proposal
            )
        } catch {
            // Setup is staged. A failed discovery, an invalid folder, and an
            // Esc/EOF cancellation must all return to the menu without giving
            // ``SetupSession`` a partial manifest to persist.
            if !(error is ZenCODESetupError) {
                AgentOutput.standardError.writeString(
                    "DS4 setup did not change settings: \(error.localizedDescription)\n"
                )
            }
            return existingManifest
        }
    }

    /// Short alias for callers that use the menu label rather than the
    /// persisted runtime terminology.
    static func configureDS4(
        existingManifest: AgentSettingsManifest?
    ) async throws -> AgentSettingsManifest? {
        try await configureDS4Runtime(existingManifest: existingManifest)
    }

    static func existingDS4Runtime(
        in manifest: AgentSettingsManifest?
    ) -> AgentDS4RuntimeManifest? {
        manifest?.providers.compactMap(\.ds4Runtime).first
            ?? manifest?.models.compactMap(\.ds4Runtime).first
    }

    /// Returns only proposals that setup can safely represent with one model
    /// path in ``AgentDS4RuntimeManifest``. In particular, shard-only catalog
    /// entries are never silently reduced to their first file.
    static func installedOperationalDS4Proposal(
        in report: DS4CompatibilityReport,
        installation: DS4InstallationSnapshot
    ) -> DS4CompatibilityProposal? {
        installedOperationalDS4Proposals(in: report, installation: installation).first
    }

    static func installedOperationalDS4Proposals(
        in report: DS4CompatibilityReport,
        installation: DS4InstallationSnapshot
    ) -> [DS4CompatibilityProposal] {
        let candidates = report.proposals.filter { proposal in
            guard proposal.installationState == .installed,
                  proposal.status.isOperational,
                  proposal.backend != nil,
                  proposal.model.artifacts.count == 1,
                  let artifact = proposal.model.artifacts.first,
                  artifact.role == .model,
                  let installedArtifact = installation.artifact(
                    relativePath: artifact.relativePath
                  ),
                  installedArtifact.relativePath.lowercased().hasSuffix(".gguf") else {
                return false
            }
            return (try? AgentDS4PathGuard.resolveModelURL(
                rootDirectory: installation.rootDirectory,
                modelRelativePath: artifact.relativePath
            )) != nil
        }

        guard !candidates.isEmpty else {
            return []
        }
        let recommended = report.recommended.flatMap { candidate in
            candidates.contains(candidate) ? candidate : nil
        }
        if let recommended,
           let recommendedIndex = candidates.firstIndex(of: recommended) {
            return [recommended] + candidates.enumerated().compactMap { offset, candidate in
                offset == recommendedIndex ? nil : candidate
            }
        }
        return candidates
    }

    /// Reconciles one staged DS4 provider/model while retaining every existing
    /// non-DS4 provider, model, key and optional setting byte-for-byte at the
    /// value level. The normal manifest initializer performs its established
    /// normalization and provider/model linking afterward.
    static func manifestByApplyingDS4(
        _ existingManifest: AgentSettingsManifest?,
        runtime: AgentDS4RuntimeManifest,
        proposal: DS4CompatibilityProposal
    ) -> AgentSettingsManifest {
        let previousProvider = existingManifest?.providers.first {
            $0.ds4Runtime != nil
        }
        let providerID = previousProvider?.id ?? ds4SetupProviderID
        let provider = AgentSettingsProviderManifest(
            id: providerID,
            name: previousProvider?.name ?? ds4SetupProviderName,
            baseURL: previousProvider?.baseURL ?? ds4SetupProviderBaseURL,
            chatEndpoint: previousProvider?.chatEndpoint ?? .chatCompletions,
            providerProfileID: previousProvider?.providerProfileID ?? .custom,
            protocolProfileID: previousProvider?.protocolProfileID ?? .openAIChatCompletions,
            authPolicy: previousProvider?.authPolicy ?? .noAuthentication,
            ds4Runtime: runtime
        )

        let previousDS4Models = existingManifest?.models.filter { model in
            model.ds4Runtime != nil
                || model.provider?.ds4Runtime != nil
                || model.providerID == providerID
        } ?? []
        let previousModel = previousDS4Models.first
        let modelID = previousModel?.id ?? "ds4:\(proposal.model.id)"
        // ``proposal.model.id`` is a catalog/download identity (for example
        // ``ds4f-q4``), not necessarily an id emitted by ds4 /v1/models.
        // Persist and send the canonical API alias while retaining the
        // catalog id in the internal manifest key above.
        let apiModelID = proposal.model.apiModelID
        let remoteProvider = provider.remoteProvider(modelID: apiModelID)
        let model = AgentSettingsModelManifest(
            id: modelID,
            kind: .remoteAPI,
            title: proposal.model.displayName,
            llmID: previousModel?.llmID,
            modelID: apiModelID,
            providerID: providerID,
            provider: remoteProvider,
            configuredContextWindowLimit: previousModel?.configuredContextWindowLimit
                ?? runtime.contextWindow,
            generationParameterOverrides: previousModel?.generationParameterOverrides,
            thinkingOptions: previousModel?.thinkingOptions,
            defaultThinkingSelection: previousModel?.defaultThinkingSelection,
            ds4Runtime: runtime
        )

        let providersWithoutDS4 = existingManifest?.providers.filter {
            $0.id != providerID
        } ?? []
        let modelsWithoutDS4 = existingManifest?.models.filter { existingModel in
            guard existingModel.providerID != providerID,
                  existingModel.provider?.id != providerID,
                  existingModel.ds4Runtime == nil,
                  existingModel.provider?.ds4Runtime == nil else {
                return false
            }
            return true
        } ?? []

        return AgentSettingsManifest(
            version: existingManifest?.version ?? AgentSettingsManifest.currentVersion,
            providers: providersWithoutDS4 + [provider],
            models: modelsWithoutDS4 + [model],
            selectedModelID: model.id,
            selectedThinkingSelection: nil,
            telegram: existingManifest?.telegram,
            voice: existingManifest?.voice,
            remoteAPIKeysByProviderID: existingManifest?.remoteAPIKeysByProviderID ?? [:],
            localExecAllowedCommands: existingManifest?.localExecAllowedCommands ?? [],
            chatGPTSubscriptionCredentials: existingManifest?.chatGPTSubscriptionCredentials,
            anthropicSubscriptionCredentials: existingManifest?.anthropicSubscriptionCredentials,
            responseLanguage: existingManifest?.responseLanguage,
            memoryEmbedding: existingManifest?.memoryEmbedding
        )
    }

    static func ds4RuntimeSetupDetail(
        _ manifest: AgentSettingsManifest?
    ) -> String {
        guard let runtime = existingDS4Runtime(in: manifest) else {
            return "not configured"
        }
        let model = manifest?.models.first {
            $0.ds4Runtime != nil || $0.provider?.ds4Runtime != nil
        }?.modelID
        var parts: [String] = []
        if let model {
            parts.append(model)
        }
        parts.append(runtime.rootDirectory)
        if runtime.ssdStreaming {
            parts.append("SSD streaming")
        }
        return parts.joined(separator: " · ")
    }

    private static func printDS4CompatibilitySummary(
        hardware: DS4HardwareSnapshot,
        installation: DS4InstallationSnapshot,
        report: DS4CompatibilityReport
    ) {
        let memory = hardware.physicalMemoryBytes.map(formatDS4Bytes) ?? "unknown"
        let backends = hardware.availableBackends.map(\.rawValue).joined(separator: ", ")
        let gpuDetail = hardware.gpus.map {
            "\($0.name) [\($0.backend?.rawValue ?? "unknown")]"
        }.joined(separator: ", ")
        AgentOutput.standardError.writeString(
            """

            DS4 discovery (read-only):
              folder:   \(installation.rootDirectory)
              GGUFs:    \(installation.artifacts.count)
              platform: \(hardware.platform.rawValue), architecture: \(hardware.architecture ?? "unknown"), RAM \(memory)
              backends: \(backends.isEmpty ? "unknown" : backends)
              GPUs:     \(gpuDetail.isEmpty ? "none detected" : gpuDetail)

            """
        )
        for proposal in report.proposals {
            let disk = proposal.requiredDiskBytes.map(formatDS4Bytes) ?? "unknown"
            let resident = proposal.requiredResidentMemoryBytes.map(formatDS4Bytes) ?? "unknown"
            let streaming = proposal.requiredStreamingMemoryBytes.map(formatDS4Bytes) ?? "n/a"
            let marker = installedOperationalDS4Proposals(
                in: report,
                installation: installation
            ).contains(proposal)
                ? "[available]"
                : "[not selectable]"
            AgentOutput.standardError.writeString(
                "  \(marker) \(proposal.model.displayName): \(proposal.status.rawValue), disk \(disk), resident RAM \(resident), streaming RAM \(streaming)\n"
            )
        }
        let knownArtifactPaths = Set(
            report.proposals.flatMap { proposal in
                proposal.model.artifacts.map(\.relativePath)
            }
        )
        for artifact in installation.artifacts
            where !knownArtifactPaths.contains(artifact.relativePath) {
            AgentOutput.standardError.writeString(
                "  [not selectable] Unknown GGUF: \(artifact.relativePath) (not in the local DS4 catalog)\n"
            )
        }
        for diagnostic in installation.diagnostics {
            AgentOutput.standardError.writeString("  scan note: \(diagnostic)\n")
        }
        for diagnostic in report.diagnostics {
            AgentOutput.standardError.writeString("  note: \(diagnostic)\n")
        }
        AgentOutput.standardError.writeString(
            "Only an installed compatible GGUF may be selected; no DS4 download, build, or start is performed.\n\n"
        )
    }

    private static func formatDS4Bytes(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / Double(1024 * 1024 * 1024)
        if gib >= 1 {
            return String(format: "%.1f GiB", gib)
        }
        return "\(bytes) bytes"
    }
}
