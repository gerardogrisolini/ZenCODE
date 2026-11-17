//
//  ZenCODESetupDS4Tests+Configuration.swift
//  ZenCODECoreTests
//
//  Tests of the DS4 setup that create and reconfigure the provider manifest:
//  inferred identifiers, preserved entries, launch parameters per file,
//  unselecting a file, cancellation and the providers path.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

extension ZenCODESetupDS4Tests {
    @Test
    func newProviderFromNilManifestUsesCatalogAndInferredIDs() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath])
        defer { fixture.remove() }

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, preselected in
                    #expect(preselected.isEmpty)
                    #expect(candidates.count == 2)
                    return Set(candidates.map(\.relativePath))
                },
                selectBackend: { _, defaultBackend in
                    #if os(macOS)
                    #expect(defaultBackend == .metal)
                    #else
                    #expect(defaultBackend == .cpu)
                    #endif
                    return .cuda
                },
                selectAPIModelID: { _ in
                    Issue.record("API id must be inferred")
                    return "glm-5.2"
                },
                selectAuxiliaryFile: { _, _, _, current in
                    #expect(current == nil)
                    return current
                },
                promptTuning: { _, defaults in
                    #expect(defaults == AgentDS4RuntimeTuning())
                    return defaults
                }
            ),
            engine: Self.engine(fixture)
        )

        let manifest = try #require(result)
        #expect(manifest.providers.count == 1)
        #expect(manifest.models.count == 2)
        let provider = try #require(manifest.providers.first)
        #expect(provider.id == ZenCODESetupRunner.ds4SetupProviderID)
        #expect(provider.id == "ds4")
        #expect(provider.providerProfileID == .ds4)
        #expect(manifest.models.allSatisfy { $0.providerID == "ds4" && $0.id.hasPrefix("ds4:") })
        #expect(provider.baseURL == ZenCODESetupRunner.ds4SetupProviderBaseURL)
        #expect(provider.authPolicy == .noAuthentication)
        #expect(provider.ds4Runtime != nil)

        let qwen = try #require(manifest.models.first { $0.id == "ds4:qwen38-q2" })
        #expect(qwen.title == "Qwen3.8 Flash Next Q2")
        #expect(qwen.modelID == "qwen3.8-flash-next")
        #expect(qwen.ds4Runtime?.modelRelativePath == Self.qwenPath)
        let custom = try #require(
            manifest.models.first { $0.id == "ds4:deepseek-v4.1-flash-custom-iq3_xxs" }
        )
        #expect(custom.modelID == "deepseek-v4.1-flash")
        #expect(custom.title == "DeepSeek-V4.1-Flash-Custom-IQ3_XXS")
        #expect(custom.configuredContextWindowLimit == 65_536)
        #expect(Set(manifest.models.map(\.id)).count == 2)
        #expect(manifest.selectedModelID == manifest.models[0].id)
    }

    @Test
    func nonDS4EntriesAndAPIKeysArePreserved() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath])
        defer { fixture.remove() }
        let existing = Self.remoteManifest()

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: existing,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
                selectBackend: { _, backend in backend },
                promptTuning: { _, tuning in tuning }
            ),
            engine: Self.engine(fixture)
        )

        let manifest = try #require(result)
        #expect(manifest.providers.contains { $0.id == existing.providers[0].id })
        #expect(manifest.models.contains { $0.id == "remote:model" })
        #expect(manifest.models.contains { $0.ds4Runtime != nil })
        #expect(manifest.remoteAPIKeysByProviderID == existing.remoteAPIKeysByProviderID)
        // The existing selection survives when still present.
        #expect(manifest.selectedModelID == "remote:model")
    }

    @Test
    func multipleFilesGetTheirOwnLaunchParametersAndDistinctIDs() async throws {
        let otherPath = "other-DeepSeek-V4-Flash.gguf"
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath, otherPath])
        defer { fixture.remove() }
        let backends: [String: AgentDS4RuntimeBackend] = [
            Self.qwenPath: .metal,
            Self.customPath: .cuda,
            otherPath: .cpu
        ]
        let tunings: [String: AgentDS4RuntimeTuning] = [
            Self.qwenPath: AgentDS4RuntimeTuning(contextWindow: 32_768, ssdStreaming: true, mtp: true, power: 50),
            Self.customPath: AgentDS4RuntimeTuning(contextWindow: 131_072, ssdStreaming: false, mtp: false, power: 90),
            otherPath: AgentDS4RuntimeTuning(contextWindow: 16_384, ssdStreaming: true, mtp: false, power: 10)
        ]
        var askedBackend: [String] = []
        var askedTuning: [String] = []

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
                selectBackend: { candidate, _ in
                    askedBackend.append(candidate.relativePath)
                    return try #require(backends[candidate.relativePath])
                },
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { candidate, defaults in
                    askedTuning.append(candidate.relativePath)
                    #expect(defaults == AgentDS4RuntimeTuning())
                    return try #require(tunings[candidate.relativePath])
                }
            ),
            engine: Self.engine(fixture)
        )

        let manifest = try #require(result)
        #expect(Set(askedBackend) == Set(backends.keys))
        #expect(askedBackend.count == 3)
        #expect(Set(askedTuning) == Set(tunings.keys))
        #expect(askedTuning.count == 3)
        #expect(manifest.models.count == 3)
        #expect(Set(manifest.models.map(\.id)).count == 3)
        #expect(Set(manifest.models.compactMap { $0.ds4Runtime?.modelRelativePath }).count == 3)
        for model in manifest.models {
            let runtime = try #require(model.ds4Runtime)
            let path = try #require(runtime.modelRelativePath)
            let tuning = try #require(tunings[path])
            #expect(runtime.rootDirectory == manifest.providers[0].ds4Runtime?.rootDirectory)
            #expect(runtime.backend == backends[path])
            #expect(runtime.contextWindow == tuning.contextWindow)
            #expect(runtime.ssdStreaming == tuning.ssdStreaming)
            #expect(runtime.mtp == tuning.mtp)
            #expect(runtime.power == tuning.power)
            #expect(model.configuredContextWindowLimit == tuning.contextWindow)
        }

        // Each model must keep its own GGUF and launch parameters after
        // persistence and normalization: the runtime selection reads the
        // model-level runtime, not the provider's.
        let decoded = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: JSONEncoder().encode(manifest)
        )
        for model in manifest.models {
            let restored = try #require(decoded.models.first { $0.id == model.id })
            #expect(restored.ds4Runtime == model.ds4Runtime)
            #expect(restored.provider?.ds4Runtime == model.ds4Runtime)
        }
    }

    @Test
    func reconfigurePreservesModelIDMetadataAndTuning() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath])
        defer { fixture.remove() }

        let previousRuntime = try AgentDS4RuntimeManifest(
            rootDirectory: fixture.root.path,
            modelRelativePath: Self.qwenPath,
            backend: .cuda,
            contextWindow: 131_072,
            ssdStreaming: true,
            ssdStreamingCacheExperts: 8,
            ssdStreamingCacheBytes: 4_000_000_000,
            ssdStreamingPreloadExperts: 2,
            ssdStreamingCold: true,
            mtp: true,
            power: 73
        )
        let providerID = ZenCODESetupRunner.ds4SetupProviderID
        let provider = AgentRemoteProvider(
            id: providerID,
            name: "Existing DS4",
            baseURL: "http://127.0.0.1:9000/v1",
            modelID: "qwen3.8-flash-next",
            chatEndpoint: .chatCompletions,
            providerProfileID: .ds4,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: previousRuntime
        )
        let oldModel = AgentSettingsModelManifest(
            id: "my-qwen",
            kind: .remoteAPI,
            title: "My Qwen",
            modelID: "qwen3.8-flash-next",
            providerID: providerID,
            provider: provider,
            configuredContextWindowLimit: 131_072,
            ds4Runtime: previousRuntime
        )
        let remote = Self.remoteManifest()
        let original = AgentSettingsManifest(
            providers: remote.providers + [AgentSettingsProviderManifest(provider: provider)],
            models: remote.models + [oldModel],
            selectedModelID: oldModel.id,
            remoteAPIKeysByProviderID: remote.remoteAPIKeysByProviderID
        )

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: original,
            prompts: DS4SetupPrompts(
                promptFolder: { previous in
                    #expect(previous == previousRuntime.rootDirectory)
                    return fixture.root.path
                },
                selectFiles: { candidates, preselected in
                    #expect(preselected == [Self.qwenPath])
                    return Set(candidates.map(\.relativePath))
                },
                selectBackend: { candidate, defaultBackend in
                    // Defaults come from the model's own saved runtime only.
                    if candidate.relativePath == Self.qwenPath {
                        #expect(defaultBackend == .cuda)
                    } else {
                        #expect(defaultBackend == ZenCODESetupRunner.defaultDS4Backend)
                    }
                    return defaultBackend
                },
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { candidate, defaults in
                    if candidate.relativePath == Self.qwenPath {
                        #expect(defaults.contextWindow == 131_072)
                        #expect(defaults.ssdStreaming)
                        #expect(defaults.mtp)
                        #expect(defaults.power == 73)
                    } else {
                        #expect(defaults == AgentDS4RuntimeTuning())
                    }
                    return defaults
                }
            ),
            selectAction: { .reconfigure },
            engine: Self.engine(fixture)
        )

        let updated = try #require(result)
        let updatedProvider = try #require(updated.providers.first { $0.id == providerID })
        #expect(updatedProvider.baseURL == "http://127.0.0.1:9000/v1")
        #expect(updatedProvider.name == "Existing DS4")
        #expect(updatedProvider.ds4Runtime != nil)
        let kept = try #require(updated.models.first { $0.id == "my-qwen" })
        #expect(kept.title == "My Qwen")
        let runtime = try #require(kept.ds4Runtime)
        #expect(runtime.backend == .cuda)
        #expect(runtime.contextWindow == 131_072)
        #expect(runtime.power == 73)
        #expect(runtime.ssdStreamingCacheExperts == 8)
        #expect(runtime.ssdStreamingCacheBytes == 4_000_000_000)
        #expect(runtime.ssdStreamingPreloadExperts == 2)
        #expect(runtime.ssdStreamingCold)
        // The newly added GGUF does not inherit the other model's settings.
        let added = try #require(updated.models.first {
            $0.ds4Runtime?.modelRelativePath == Self.customPath
        })
        let addedRuntime = try #require(added.ds4Runtime)
        #expect(addedRuntime.contextWindow == 65_536)
        #expect(addedRuntime.power == 100)
        #expect(addedRuntime.ssdStreamingCacheExperts == nil)
        #expect(!addedRuntime.ssdStreamingCold)
        #expect(updated.models.filter { $0.ds4Runtime != nil }.count == 2)
        #expect(updated.models.contains { $0.id == "remote:model" })
        #expect(updated.selectedModelID == "my-qwen")
        #expect(updated.remoteAPIKeysByProviderID == original.remoteAPIKeysByProviderID)
    }

    @Test
    func unselectingAFileRemovesItAndFallsBackToFirstDS4Model() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath])
        defer { fixture.remove() }
        let first = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
                selectBackend: { _, backend in backend },
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { _, tuning in tuning }
            ),
            engine: Self.engine(fixture)
        )
        let manifest = try #require(first)
        let selectedID = try #require(manifest.models.first {
            $0.ds4Runtime?.modelRelativePath == Self.customPath
        }?.id)
        let selected = AgentSettingsManifest(
            providers: manifest.providers,
            models: manifest.models,
            selectedModelID: selectedID
        )

        let second = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: selected,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { _, _ in [Self.qwenPath] },
                selectBackend: { _, backend in backend },
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { _, tuning in tuning }
            ),
            selectAction: { .reconfigure },
            engine: Self.engine(fixture)
        )
        let updated = try #require(second)
        #expect(updated.models.count == 1)
        #expect(updated.models[0].ds4Runtime?.modelRelativePath == Self.qwenPath)
        #expect(updated.selectedModelID == updated.models[0].id)
    }

    @Test
    func uninferrableNameUsesAPIModelIDSelection() async throws {
        let fixture = try Fixture.make(files: ["mystery.gguf"])
        defer { fixture.remove() }
        var asked: [String] = []

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
                selectBackend: { _, backend in backend },
                selectAPIModelID: { candidate in
                    asked.append(candidate.fileName)
                    return "glm-5.2"
                },
                promptTuning: { _, tuning in tuning }
            ),
            engine: Self.engine(fixture)
        )
        let manifest = try #require(result)
        #expect(asked == ["mystery.gguf"])
        #expect(manifest.models[0].modelID == "glm-5.2")
    }

    @Test
    func cancellationAndErrorsLeaveManifestUnchanged() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath])
        defer { fixture.remove() }
        let original = Self.remoteManifest()

        let cancelledFolder = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in throw ZenCODESetupError.cancelled }
            )
        )
        #expect(cancelledFolder == nil)

        let cancelledBackend = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: original,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
                selectBackend: { _, _ in throw ZenCODESetupError.cancelled }
            )
        )
        #expect(cancelledBackend == original)

        let tuningError = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: original,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
                selectBackend: { _, backend in backend },
                promptTuning: { _, _ in throw AgentDS4RuntimeConfigurationError.invalidPower(0) }
            ),
            engine: Self.engine(fixture)
        )
        #expect(tuningError == original)

        let missingFolder = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: original,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path + "/does-not-exist" }
            )
        )
        #expect(missingFolder == original)
    }

    @Test
    func providersPathReconfiguresDS4WithoutNetwork() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath])
        defer { fixture.remove() }

        let runtime = try AgentDS4RuntimeManifest(
            rootDirectory: fixture.root.path,
            modelRelativePath: Self.qwenPath,
            backend: .metal
        )
        let providerID = ZenCODESetupRunner.ds4SetupProviderID
        // Port-less loopback URL: the generic path would call `/models` here.
        let provider = AgentRemoteProvider(
            id: providerID,
            name: "DS4",
            baseURL: "http://127.0.0.1/v1",
            modelID: "qwen3.8-flash-next",
            chatEndpoint: .chatCompletions,
            providerProfileID: .ds4,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: runtime
        )
        let model = AgentSettingsModelManifest(
            id: "ds4:qwen38-q2",
            kind: .remoteAPI,
            modelID: "qwen3.8-flash-next",
            providerID: providerID,
            provider: provider,
            ds4Runtime: runtime
        )
        let input = ZenCODESetupRunner.preserveProviderInput(
            provider: AgentSettingsProviderManifest(provider: provider),
            models: [model],
            apiKey: nil
        )

        let changed = await ZenCODESetupRunner.reconfigureDS4ProviderInput(
            input,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, preselected in
                    #expect(preselected == [Self.qwenPath])
                    return Set(candidates.map(\.relativePath))
                },
                selectBackend: { _, backend in backend },
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { _, tuning in tuning }
            ),
            engine: Self.engine(fixture)
        )
        #expect(changed.id == providerID)
        #expect(changed.baseURL == "http://127.0.0.1/v1")
        #expect(changed.models.count == 2)
        #expect(changed.models.contains { $0.id == "ds4:qwen38-q2" })

        let cancelled = await ZenCODESetupRunner.reconfigureDS4ProviderInput(
            input,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in throw ZenCODESetupError.cancelled }
            ),
            engine: Self.engine(fixture)
        )
        #expect(cancelled.models == input.models)
        #expect(cancelled.id == input.id)
    }

    private static func remoteManifest() -> AgentSettingsManifest {
        let providerID = "custom"
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
            remoteAPIKeysByProviderID: [providerID: "keep-me"]
        )
    }
}
