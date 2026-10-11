//
//  ZenCODESetupDS4Tests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("ZenCODE setup DS4", .serialized)
struct ZenCODESetupDS4Tests {
    @Test
    func installedCompatibleModelIsStagedAndExistingRemoteProviderSurvives() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        let existing = Self.remoteManifest()
        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: existing,
            catalog: fixture.catalog,
            hardwareProbe: { fixture.hardware },
            promptFolder: { _ in fixture.root.path },
            confirmProposal: { proposal in
                #expect(proposal.model.id == fixture.entry.id)
                #expect(proposal.installationState == .installed)
                #expect(proposal.status == .ready)
                return true
            },
            promptTuning: { defaults in
                #expect(defaults.contextWindow == 65_536)
                #expect(!defaults.mtp)
                #expect(defaults.power == 100)
                return defaults
            }
        )

        let manifest = try #require(result)
        #expect(manifest.providers.contains { $0.id == existing.providers[0].id })
        #expect(manifest.models.contains { $0.providerID == existing.providers[0].id })
        #expect(manifest.selectedModelID == "ds4:\(fixture.entry.id)")

        let ds4Provider = try #require(
            manifest.providers.first { $0.ds4Runtime != nil }
        )
        let runtime = try #require(ds4Provider.ds4Runtime)
        #expect(runtime.rootDirectory == fixture.root.path)
        #expect(runtime.modelRelativePath == fixture.entry.artifacts[0].relativePath)
        #expect(runtime.backend == .metal)
        #expect(try runtime.requiredModelURL() == fixture.modelURL)
        #expect(ds4Provider.authPolicy == .noAuthentication)
        #expect(ds4Provider.baseURL == ZenCODESetupRunner.ds4SetupProviderBaseURL)
        #expect(manifest.remoteAPIKeysByProviderID == existing.remoteAPIKeysByProviderID)
    }

    @Test
    func initialSetupCanCreateDS4ProviderWithoutAPreexistingRemoteProvider() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            catalog: fixture.catalog,
            hardwareProbe: { fixture.hardware },
            promptFolder: { _ in fixture.root.path },
            confirmProposal: { proposal in
                #expect(proposal.model.id == fixture.entry.id)
                return true
            },
            promptTuning: { $0 }
        )

        let manifest = try #require(result)
        #expect(manifest.providers.count == 1)
        #expect(manifest.models.count == 1)
        #expect(manifest.models[0].modelID == fixture.entry.apiModelID)
        #expect(manifest.models[0].ds4Runtime != nil)
        #expect(manifest.selectedModelID == manifest.models[0].id)
    }

    @Test
    func reconfigurationPreservesDS4TuningAndAllRemoteEntries() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }

        let previousRuntime = try AgentDS4RuntimeManifest(
            rootDirectory: fixture.root.path,
            modelRelativePath: fixture.entry.artifacts[0].relativePath,
            backend: .metal,
            contextWindow: 131_072,
            batchedSessions: true,
            ssdStreaming: true,
            ssdStreamingCacheExperts: 8,
            ssdStreamingCacheBytes: 4_000_000_000,
            ssdStreamingPreloadExperts: 2,
            ssdStreamingCold: true,
            mtp: true,
            power: 73
        )
        let ds4ProviderID = UUID()
        let ds4Provider = AgentRemoteProvider(
            id: ds4ProviderID,
            name: "Existing DS4",
            baseURL: "http://127.0.0.1/v1",
            modelID: "old-ds4",
            chatEndpoint: .chatCompletions,
            providerProfileID: .custom,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: previousRuntime
        )
        let oldDS4Model = AgentSettingsModelManifest(
            id: "old-ds4-manifest",
            kind: .remoteAPI,
            title: "Old DS4",
            modelID: "old-ds4",
            providerID: ds4ProviderID,
            provider: ds4Provider,
            configuredContextWindowLimit: 131_072,
            ds4Runtime: previousRuntime
        )
        let remote = Self.remoteManifest()
        let original = AgentSettingsManifest(
            providers: remote.providers + [AgentSettingsProviderManifest(provider: ds4Provider)],
            models: remote.models + [oldDS4Model],
            selectedModelID: remote.selectedModelID,
            remoteAPIKeysByProviderID: remote.remoteAPIKeysByProviderID
        )

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: original,
            catalog: fixture.catalog,
            hardwareProbe: { fixture.hardware },
            promptFolder: { _ in fixture.root.path },
            confirmProposal: { _ in true },
            promptTuning: { defaults in
                #expect(defaults.contextWindow == previousRuntime.contextWindow)
                #expect(defaults.ssdStreaming)
                #expect(defaults.mtp == previousRuntime.mtp)
                #expect(defaults.power == previousRuntime.power)
                return AgentDS4RuntimeTuning(
                    contextWindow: 65_536,
                    ssdStreaming: defaults.ssdStreaming,
                    mtp: defaults.mtp,
                    power: defaults.power
                )
            }
        )

        let updated = try #require(result)
        let updatedProvider = try #require(
            updated.providers.first { $0.id == ds4ProviderID }
        )
        let runtime = try #require(updatedProvider.ds4Runtime)
        #expect(runtime.contextWindow == 65_536)
        #expect(runtime.batchedSessions == previousRuntime.batchedSessions)
        #expect(runtime.ssdStreaming)
        #expect(runtime.ssdStreamingCacheExperts == previousRuntime.ssdStreamingCacheExperts)
        #expect(runtime.ssdStreamingCacheBytes == previousRuntime.ssdStreamingCacheBytes)
        #expect(runtime.ssdStreamingPreloadExperts == previousRuntime.ssdStreamingPreloadExperts)
        #expect(runtime.ssdStreamingCold == previousRuntime.ssdStreamingCold)
        #expect(runtime.mtp == previousRuntime.mtp)
        #expect(runtime.power == previousRuntime.power)
        let updatedModel = try #require(
            updated.models.first { $0.id == oldDS4Model.id }
        )
        #expect(updatedModel.configuredContextWindowLimit == runtime.contextWindow)
        #expect(updated.providers.contains { $0.id == remote.providers[0].id })
        #expect(updated.models.contains { $0.id == remote.models[0].id })
        #expect(updated.selectedModelID == "old-ds4-manifest")
    }

    @Test
    func rerunPreservesExplicitlyDisabledSSDStreamingWhenProposalRecommendsIt() async throws {
        let fixture = try Fixture.make(streamingRecommended: true)
        defer { fixture.remove() }

        let previousRuntime = try AgentDS4RuntimeManifest(
            rootDirectory: fixture.root.path,
            modelRelativePath: fixture.entry.artifacts[0].relativePath,
            backend: .metal,
            contextWindow: 131_072,
            ssdStreaming: false,
            ssdStreamingCacheExperts: 8,
            ssdStreamingPreloadExperts: 2,
            ssdStreamingCold: true
        )
        let ds4ProviderID = UUID()
        let ds4Provider = AgentRemoteProvider(
            id: ds4ProviderID,
            name: "Existing DS4",
            baseURL: "http://127.0.0.1/v1",
            modelID: "old-ds4",
            chatEndpoint: .chatCompletions,
            providerProfileID: .custom,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: previousRuntime
        )
        let oldDS4Model = AgentSettingsModelManifest(
            id: "old-ds4-manifest",
            kind: .remoteAPI,
            title: "Old DS4",
            modelID: "old-ds4",
            providerID: ds4ProviderID,
            provider: ds4Provider,
            configuredContextWindowLimit: previousRuntime.contextWindow,
            ds4Runtime: previousRuntime
        )
        let existing = AgentSettingsManifest(
            providers: [AgentSettingsProviderManifest(provider: ds4Provider)],
            models: [oldDS4Model],
            selectedModelID: oldDS4Model.id
        )

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: existing,
            catalog: fixture.catalog,
            hardwareProbe: { fixture.hardware },
            promptFolder: { _ in fixture.root.path },
            confirmProposal: { proposal in
                #expect(proposal.mode == .ssdStreaming)
                return true
            },
            promptTuning: { defaults in
                #expect(!defaults.ssdStreaming)
                return defaults
            }
        )

        let updated = try #require(result)
        let updatedProvider = try #require(
            updated.providers.first { $0.id == ds4ProviderID }
        )
        let runtime = try #require(updatedProvider.ds4Runtime)
        #expect(!runtime.ssdStreaming)
        #expect(runtime.ssdStreamingCacheExperts == previousRuntime.ssdStreamingCacheExperts)
        #expect(runtime.ssdStreamingPreloadExperts == previousRuntime.ssdStreamingPreloadExperts)
        #expect(runtime.ssdStreamingCold == previousRuntime.ssdStreamingCold)
    }

    @Test
    func noGGUFLeavesManifestUnchangedAndDoesNotAskForConfirmation() async throws {
        let fixture = try Fixture.make(writeModel: false)
        defer { fixture.remove() }
        let existing = Self.remoteManifest()
        var didConfirm = false

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: existing,
            catalog: fixture.catalog,
            hardwareProbe: {
                Issue.record("Hardware must not be probed when no GGUF exists")
                return fixture.hardware
            },
            promptFolder: { _ in fixture.root.path },
            confirmProposal: { _ in
                didConfirm = true
                return true
            }
        )

        #expect(result == existing)
        #expect(!didConfirm)
    }

    @Test
    func unknownHardwareLeavesManifestUnchangedAndCannotBeConfirmed() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let existing = Self.remoteManifest()
        var didConfirm = false

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: existing,
            catalog: fixture.catalog,
            hardwareProbe: { DS4HardwareSnapshot(platform: .unknown) },
            promptFolder: { _ in fixture.root.path },
            confirmProposal: { _ in
                didConfirm = true
                return true
            }
        )

        #expect(result == existing)
        #expect(!didConfirm)
    }

    @Test
    func cancellationLeavesManifestUnchangedEvenWithoutAPreexistingProvider() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            catalog: fixture.catalog,
            promptFolder: { _ in throw ZenCODESetupError.cancelled },
            confirmProposal: { _ in
                Issue.record("Confirmation must not run after cancellation")
                return true
            }
        )

        #expect(result == nil)
    }

    @Test
    func cancellationDuringTuningLeavesOriginalManifestUnchanged() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let original = Self.remoteManifest()
        var didPrompt = false

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: original,
            catalog: fixture.catalog,
            hardwareProbe: { fixture.hardware },
            promptFolder: { _ in fixture.root.path },
            confirmProposal: { _ in true },
            promptTuning: { _ in
                didPrompt = true
                throw ZenCODESetupError.cancelled
            }
        )

        #expect(didPrompt)
        #expect(result == original)
    }

    @Test
    func tuningErrorLeavesOriginalManifestUnchanged() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        let original = Self.remoteManifest()

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: original,
            catalog: fixture.catalog,
            hardwareProbe: { fixture.hardware },
            promptFolder: { _ in fixture.root.path },
            confirmProposal: { _ in true },
            promptTuning: { _ in
                throw AgentDS4RuntimeConfigurationError.invalidPower(0)
            }
        )

        #expect(result == original)
    }

    @Test
    func missingCatalogModelIsNeverOfferedForConfirmation() async throws {
        let fixture = try Fixture.make()
        defer { fixture.remove() }
        var didConfirm = false

        let unknownCatalog = DS4ModelCatalog(entries: [
            DS4ModelCatalogEntry(
                id: "other-model",
                displayName: "Other model",
                downloadTarget: "other-model",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/other.gguf")],
                resources: DS4ModelResourceEstimate(
                    diskBytes: 1,
                    residentMemoryBytes: 1
                ),
                supportedBackends: [.metal]
            )
        ])
        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            catalog: unknownCatalog,
            hardwareProbe: { fixture.hardware },
            promptFolder: { _ in fixture.root.path },
            confirmProposal: { _ in
                didConfirm = true
                return true
            }
        )

        #expect(result == nil)
        #expect(!didConfirm)
    }

    private static func remoteManifest() -> AgentSettingsManifest {
        let providerID = UUID()
        let provider = AgentRemoteProvider(
            id: providerID,
            name: "Existing remote",
            baseURL: "https://example.invalid/v1",
            modelID: "remote-model",
            chatEndpoint: .chatCompletions,
            providerProfileID: .custom,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .apiKeyOptional
        )
        let model = AgentSettingsModelManifest(
            id: "remote:model",
            kind: .remoteAPI,
            modelID: "remote-model",
            providerID: providerID,
            provider: provider
        )
        return AgentSettingsManifest(
            providers: [AgentSettingsProviderManifest(provider: provider)],
            models: [model],
            selectedModelID: model.id,
            remoteAPIKeysByProviderID: [providerID.uuidString.lowercased(): "keep-me"]
        )
    }

    private struct Fixture {
        let root: URL
        let modelURL: URL
        let entry: DS4ModelCatalogEntry
        let catalog: DS4ModelCatalog
        let hardware: DS4HardwareSnapshot

        static func make(
            writeModel: Bool = true,
            streamingRecommended: Bool = false
        ) throws -> Fixture {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory
                .appendingPathComponent("zencode-ds4-setup-")
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            let modelURL = root.appendingPathComponent("gguf/fixture.gguf")
            if writeModel {
                try fileManager.createDirectory(
                    at: modelURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(repeating: 1, count: 16).write(to: modelURL)
            }
            let entry = DS4ModelCatalogEntry(
                // Catalog/download identity is intentionally synthetic; setup
                // must persist the canonical ds4 API alias instead.
                id: "ds4f-q4",
                displayName: "Fixture DS4",
                downloadTarget: "ds4f-q4",
                artifacts: [DS4ModelArtifact(relativePath: "gguf/fixture.gguf")],
                resources: DS4ModelResourceEstimate(
                    diskBytes: 16,
                    residentMemoryBytes: streamingRecommended
                        ? 32 * 1024 * 1024 * 1024
                        : 8 * 1024 * 1024 * 1024,
                    streamingMemoryBytes: streamingRecommended
                        ? 8 * 1024 * 1024 * 1024
                        : nil
                ),
                supportedBackends: [.metal],
                supportsSSDStreaming: streamingRecommended
            )
            let hardware = DS4HardwareSnapshot(
                platform: .macOS,
                architecture: "arm64",
                physicalMemoryBytes: 16 * 1024 * 1024 * 1024,
                gpus: [DS4GPUDevice(name: "Fixture GPU", backend: .metal)],
                availableBackends: [.metal]
            )
            return Fixture(
                root: root,
                modelURL: modelURL,
                entry: entry,
                catalog: DS4ModelCatalog(entries: [entry]),
                hardware: hardware
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
