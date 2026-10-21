//
//  ZenCODESetupDS4Tests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("ZenCODE setup DS4", .serialized)
struct ZenCODESetupDS4Tests {
    private static let qwenPath = "gguf/Qwen3.8-Flash-Next-Q2.gguf"
    private static let customPath = "gguf/DeepSeek-V4.1-Flash-Custom-IQ3_XXS.gguf"
    private static let ds41Q2Path = "gguf/DeepSeek-V4.1-Flash-1017-IQ2_XXS-Q2_K-imatrix.gguf"

    @Test
    func newProviderFromNilManifestUsesCatalogAndInferredIDs() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath])
        defer { fixture.remove() }

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
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
            promptTuning: { _, defaults in
                #expect(defaults.contextWindow == 65_536)
                #expect(!defaults.ssdStreaming)
                return defaults
            }
        )

        let manifest = try #require(result)
        #expect(manifest.providers.count == 1)
        #expect(manifest.models.count == 2)
        let provider = try #require(manifest.providers.first)
        #expect(provider.id == ZenCODESetupRunner.ds4SetupProviderID)
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
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, backend in backend },
            promptTuning: { _, tuning in tuning }
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
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { candidate, _ in
                askedBackend.append(candidate.relativePath)
                return try #require(backends[candidate.relativePath])
            },
            promptTuning: { candidate, defaults in
                askedTuning.append(candidate.relativePath)
                #expect(defaults == AgentDS4RuntimeTuning())
                return try #require(tunings[candidate.relativePath])
            }
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
    func currentAndLegacyDS41Q2FilesUseCatalogDisplayName() {
        let catalog = DS4ModelCatalog.default
        for path in [Self.ds41Q2Path, "gguf/DeepSeek-V4.1-Flash-Q2.gguf"] {
            let entry = catalog.entry(forArtifactPath: path)
            #expect(entry?.id == "ds41f-q2")
            #expect(entry?.displayName == "DeepSeek V4.1 Flash Q2")
            #expect(entry?.apiModelID == "deepseek-v4.1-flash")
        }
    }

    @Test
    func shardsOfMultiArtifactCatalogEntriesAreNotOffered() async throws {
        let fixture = try Fixture.make(files: [
            "gguf/DeepSeek-V4-Pro-Q4K-Layers00-30.gguf",
            "gguf/DeepSeek-V4-Pro-Q4K-Layers-31-output.gguf",
            Self.qwenPath
        ])
        defer { fixture.remove() }

        var offered: [String] = []
        _ = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in
                offered = candidates.map(\.relativePath)
                return nil
            }
        )
        #expect(offered == [Self.qwenPath])
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
            batchedSessions: true,
            ssdStreaming: true,
            ssdStreamingCacheExperts: 8,
            ssdStreamingCacheBytes: 4_000_000_000,
            ssdStreamingPreloadExperts: 2,
            ssdStreamingCold: true,
            mtp: true,
            power: 73
        )
        let providerID = UUID()
        let provider = AgentRemoteProvider(
            id: providerID,
            name: "Existing DS4",
            baseURL: "http://127.0.0.1:9000/v1",
            modelID: "qwen3.8-flash-next",
            chatEndpoint: .chatCompletions,
            providerProfileID: .custom,
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
        #expect(runtime.batchedSessions)
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
        #expect(!addedRuntime.batchedSessions)
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
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, backend in backend },
            promptTuning: { _, tuning in tuning }
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
            promptFolder: { _ in fixture.root.path },
            selectFiles: { _, _ in [Self.qwenPath] },
            selectBackend: { _, backend in backend },
            promptTuning: { _, tuning in tuning }
        )
        let updated = try #require(second)
        #expect(updated.models.count == 1)
        #expect(updated.models[0].ds4Runtime?.modelRelativePath == Self.qwenPath)
        #expect(updated.selectedModelID == updated.models[0].id)
    }

    @Test
    func unknownGGUFGetsInferredAPIModelID() async throws {
        let fixture = try Fixture.make(files: ["Qwen3.8-Flash-Next-Custom.gguf"])
        defer { fixture.remove() }

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, backend in backend },
            selectAPIModelID: { _ in
                Issue.record("Must not ask when the id can be inferred")
                return "glm-5.2"
            },
            promptTuning: { _, tuning in tuning }
        )
        let manifest = try #require(result)
        #expect(manifest.models[0].modelID == "qwen3.8-flash-next")
        #expect(manifest.models[0].id == "ds4:qwen3.8-flash-next-custom")
    }

    @Test
    func uninferrableNameUsesAPIModelIDSelection() async throws {
        let fixture = try Fixture.make(files: ["mystery.gguf"])
        defer { fixture.remove() }
        var asked: [String] = []

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, backend in backend },
            selectAPIModelID: { candidate in
                asked.append(candidate.fileName)
                return "glm-5.2"
            },
            promptTuning: { _, tuning in tuning }
        )
        let manifest = try #require(result)
        #expect(asked == ["mystery.gguf"])
        #expect(manifest.models[0].modelID == "glm-5.2")
    }

    @Test
    func noGGUFLeavesManifestUnchanged() async throws {
        let fixture = try Fixture.make(files: [])
        defer { fixture.remove() }
        let existing = Self.remoteManifest()

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: existing,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { _, _ in
                Issue.record("No selection must be offered without GGUF files")
                return nil
            }
        )
        #expect(result == existing)
    }

    @Test
    func emptySelectionAndCancelledSelectionLeaveManifestUnchanged() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath])
        defer { fixture.remove() }
        let existing = Self.remoteManifest()

        let empty = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: existing,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { _, _ in [] },
            selectBackend: { _, _ in
                Issue.record("Backend must not be asked after an empty selection")
                return .cpu
            }
        )
        #expect(empty == existing)

        let cancelled = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: existing,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { _, _ in nil }
        )
        #expect(cancelled == existing)
    }

    @Test
    func cancellationAndErrorsLeaveManifestUnchanged() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath])
        defer { fixture.remove() }
        let original = Self.remoteManifest()

        let cancelledFolder = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            promptFolder: { _ in throw ZenCODESetupError.cancelled }
        )
        #expect(cancelledFolder == nil)

        let cancelledBackend = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: original,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, _ in throw ZenCODESetupError.cancelled }
        )
        #expect(cancelledBackend == original)

        let tuningError = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: original,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, backend in backend },
            promptTuning: { _, _ in throw AgentDS4RuntimeConfigurationError.invalidPower(0) }
        )
        #expect(tuningError == original)

        let missingFolder = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: original,
            promptFolder: { _ in fixture.root.path + "/does-not-exist" }
        )
        #expect(missingFolder == original)
    }

    @Test
    func providersPathReconfiguresDS4WithoutNetwork() throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath])
        defer { fixture.remove() }

        let runtime = try AgentDS4RuntimeManifest(
            rootDirectory: fixture.root.path,
            modelRelativePath: Self.qwenPath,
            backend: .metal
        )
        let providerID = UUID()
        // Port-less loopback URL: the generic path would call `/models` here.
        let provider = AgentRemoteProvider(
            id: providerID,
            name: "DS4",
            baseURL: "http://127.0.0.1/v1",
            modelID: "qwen3.8-flash-next",
            chatEndpoint: .chatCompletions,
            providerProfileID: .custom,
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

        let changed = ZenCODESetupRunner.reconfigureDS4ProviderInput(
            input,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, preselected in
                #expect(preselected == [Self.qwenPath])
                return Set(candidates.map(\.relativePath))
            },
            selectBackend: { _, backend in backend },
            promptTuning: { _, tuning in tuning }
        )
        #expect(changed.id == providerID)
        #expect(changed.baseURL == "http://127.0.0.1/v1")
        #expect(changed.models.count == 2)
        #expect(changed.models.contains { $0.id == "ds4:qwen38-q2" })

        let cancelled = ZenCODESetupRunner.reconfigureDS4ProviderInput(
            input,
            promptFolder: { _ in throw ZenCODESetupError.cancelled }
        )
        #expect(cancelled.models == input.models)
        #expect(cancelled.id == input.id)
    }

    @Test
    func menuDetailListsAllDS4ModelIDs() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath])
        defer { fixture.remove() }
        let manifest = try #require(
            try await ZenCODESetupRunner.configureDS4Runtime(
                existingManifest: nil,
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
                selectBackend: { _, backend in backend },
                promptTuning: { _, tuning in tuning }
            )
        )
        let detail = ZenCODESetupRunner.ds4RuntimeSetupDetail(manifest)
        for model in manifest.models {
            let runtime = try #require(model.ds4Runtime)
            #expect(detail.contains(
                "\(model.id) (\(runtime.backend.rawValue), power \(runtime.power), ctx \(runtime.contextWindow))"
            ))
        }
        #expect(ZenCODESetupRunner.ds4RuntimeSetupDetail(nil) == "not configured")
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

        static func make(files: [String]) throws -> Fixture {
            let fileManager = FileManager.default
            let root = fileManager.temporaryDirectory
                .appendingPathComponent("zencode-ds4-setup-")
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            for file in files {
                let url = root.appendingPathComponent(file)
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(repeating: 1, count: 16).write(to: url)
            }
            return Fixture(root: root)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }
}
