//
//  ZenCODESetupDS4Tests.swift
//  ZenCODECoreTests
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

private final class SetupLineCollector: Sendable {
    private let storage = Mutex<[String]>([])

    func append(_ line: String) {
        storage.withLock { $0.append(line) }
    }

    var lines: [String] {
        storage.withLock { $0 }
    }

    var text: String {
        lines.joined(separator: "\n")
    }
}

/// Engine builder seam: records the requests, replays canned log lines and
/// returns or throws a canned result. It never starts a process.
private final class FakeEngineBuilder: DS4EngineBuilding {
    private let result: Result<URL, DS4EngineBuildError>
    private let logLines: [String]
    private let recorded = Mutex<[DS4EngineBuildRequest]>([])

    init(
        result: Result<URL, DS4EngineBuildError> = .success(URL(fileURLWithPath: "/fake/libzencode-ds4.dylib")),
        logLines: [String] = ["fake build log"]
    ) {
        self.result = result
        self.logLines = logLines
    }

    var requests: [DS4EngineBuildRequest] {
        recorded.withLock { $0 }
    }

    func build(
        _ request: DS4EngineBuildRequest,
        output: @escaping @Sendable (String) -> Void
    ) async throws -> URL {
        recorded.withLock { $0.append(request) }
        for line in logLines {
            output(line)
        }
        return try result.get()
    }
}

@Suite("ZenCODE setup DS4", .serialized)
struct ZenCODESetupDS4Tests {
    private static let qwenPath = "gguf/Qwen3.8-Flash-Next-Q2.gguf"
    private static let customPath = "gguf/DeepSeek-V4.1-Flash-Custom-IQ3_XXS.gguf"
    private static let ds41Q2Path = "gguf/DeepSeek-V4.1-Flash-1017-IQ2_XXS-Q2_K-imatrix.gguf"
    private static let visionPath = "gguf/vision-projector.gguf"
    private static let mtpPath = "gguf/mtp-support.gguf"
    private static let steeringPath = "dir-steering/out/verbosity.f32"

    /// Keeps every saved optional file (none for a model never configured).
    private static var keepAuxiliary: DS4SetupAuxiliaryFileSelector {
        { _, _, _, current in current }
    }

    /// Engine seam that never starts a process, never asks the terminal and
    /// keeps the library state inside the fixture.
    private static func engine(
        _ fixture: Fixture,
        builder: FakeEngineBuilder = FakeEngineBuilder(),
        output: SetupLineCollector = SetupLineCollector(),
        confirm: @escaping ([DS4EngineBuildRequest]) throws -> Bool = { _ in
            Issue.record("The build question must not be asked")
            return false
        }
    ) -> DS4SetupEngineOptions {
        DS4SetupEngineOptions(
            builder: builder,
            supportDirectory: fixture.support,
            confirmBuild: confirm,
            output: { output.append($0) }
        )
    }

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
            selectAuxiliaryFile: { _, _, _, current in
                #expect(current == nil)
                return current
            },
            promptTuning: { _, defaults in
                #expect(defaults == AgentDS4RuntimeTuning())
                return defaults
            },
            engine: Self.engine(fixture)
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
            promptTuning: { _, tuning in tuning },
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
            },
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
            },
            engine: Self.engine(fixture)
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
            },
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
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, backend in backend },
            selectAuxiliaryFile: Self.keepAuxiliary,
            promptTuning: { _, tuning in tuning },
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
            promptFolder: { _ in fixture.root.path },
            selectFiles: { _, _ in [Self.qwenPath] },
            selectBackend: { _, backend in backend },
            selectAuxiliaryFile: Self.keepAuxiliary,
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture)
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
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture)
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
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture)
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
            promptTuning: { _, _ in throw AgentDS4RuntimeConfigurationError.invalidPower(0) },
            engine: Self.engine(fixture)
        )
        #expect(tuningError == original)

        let missingFolder = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: original,
            promptFolder: { _ in fixture.root.path + "/does-not-exist" }
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

        let changed = await ZenCODESetupRunner.reconfigureDS4ProviderInput(
            input,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, preselected in
                #expect(preselected == [Self.qwenPath])
                return Set(candidates.map(\.relativePath))
            },
            selectBackend: { _, backend in backend },
            selectAuxiliaryFile: Self.keepAuxiliary,
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture)
        )
        #expect(changed.id == providerID)
        #expect(changed.baseURL == "http://127.0.0.1/v1")
        #expect(changed.models.count == 2)
        #expect(changed.models.contains { $0.id == "ds4:qwen38-q2" })

        let cancelled = await ZenCODESetupRunner.reconfigureDS4ProviderInput(
            input,
            promptFolder: { _ in throw ZenCODESetupError.cancelled },
            engine: Self.engine(fixture)
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
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { _, tuning in tuning },
                engine: Self.engine(fixture)
            )
        )
        let detail = ZenCODESetupRunner.ds4RuntimeSetupDetail(manifest, supportDirectory: fixture.support)
        for model in manifest.models {
            let runtime = try #require(model.ds4Runtime)
            #expect(detail.contains(
                "\(model.id) (\(runtime.backend.rawValue), power \(runtime.power), ctx \(runtime.contextWindow), "
                    + "vision none, MTP model none, steer none, engine missing)"
            ))
        }
        #expect(detail.hasSuffix(manifest.providers[0].ds4Runtime?.rootDirectory ?? "?"))
        #expect(ZenCODESetupRunner.ds4RuntimeSetupDetail(nil, supportDirectory: fixture.support) == "not configured")
    }

    @Test
    func menuDetailShowsAuxiliaryFilesAndEngineState() async throws {
        let fixture = try Fixture.make(
            files: [Self.qwenPath, Self.customPath, Self.visionPath, Self.mtpPath, Self.steeringPath],
            ds4Header: true
        )
        defer { fixture.remove() }
        let root = try AgentDS4PathGuard.canonicalRootDirectory(fixture.root.path)
        let builtRuntime = try AgentDS4RuntimeManifest(
            rootDirectory: root,
            modelRelativePath: Self.qwenPath,
            backend: .metal,
            ssdStreaming: true,
            mtp: true,
            visionRelativePath: Self.visionPath,
            mtpRelativePath: Self.mtpPath,
            steeringRelativePath: Self.steeringPath,
            dspark: true
        )
        let staleRuntime = try AgentDS4RuntimeManifest(
            rootDirectory: root,
            modelRelativePath: Self.customPath,
            backend: .cuda,
            cudaArch: "sm_120"
        )
        try fixture.markEngineBuilt(for: builtRuntime)
        // A library recorded for another architecture must be rebuilt.
        try fixture.writeEngineLibrary(
            for: staleRuntime,
            metadata: DS4EngineBuildMetadata(
                root: root, backend: "cuda", arch: "sm_90", date: nil, hash: nil, abiVersion: nil
            )
        )

        func model(_ id: String, _ runtime: AgentDS4RuntimeManifest) -> AgentSettingsModelManifest {
            AgentSettingsModelManifest(
                id: id,
                kind: .remoteAPI,
                modelID: "deepseek-v4.1-flash",
                providerID: ZenCODESetupRunner.ds4SetupProviderID,
                ds4Runtime: runtime
            )
        }
        let provider = AgentSettingsProviderManifest(
            id: ZenCODESetupRunner.ds4SetupProviderID,
            name: ZenCODESetupRunner.ds4SetupProviderName,
            baseURL: ZenCODESetupRunner.ds4SetupProviderBaseURL,
            chatEndpoint: .chatCompletions,
            providerProfileID: .custom,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: builtRuntime
        )
        let manifest = AgentSettingsManifest(
            providers: [provider],
            models: [model("built-model", builtRuntime), model("stale-model", staleRuntime)],
            selectedModelID: "built-model"
        )

        let detail = ZenCODESetupRunner.ds4RuntimeSetupDetail(manifest, supportDirectory: fixture.support)
        #expect(detail.contains(
            "built-model (metal, SSD streaming, MTP, DSpark, power 100, ctx 65536, "
                + "vision vision-projector.gguf, MTP model mtp-support.gguf, steer verbosity.f32, engine built)"
        ))
        #expect(detail.contains(
            "stale-model (cuda, power 100, ctx 65536, vision none, MTP model none, steer none, engine rebuild required)"
        ))
    }

    // MARK: Optional files and launch options

    @Test
    func optionalFilesAndLaunchOptionsArePersistedPerModel() async throws {
        let shardPath = "gguf/DeepSeek-V4-Pro-Q4K-Layers00-30.gguf"
        let fixture = try Fixture.make(
            files: [Self.qwenPath, Self.customPath, Self.visionPath, Self.mtpPath, shardPath, Self.steeringPath]
        )
        defer { fixture.remove() }
        var asked: [String] = []

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in
                #expect(!candidates.contains { $0.relativePath == shardPath })
                return [Self.qwenPath, Self.customPath]
            },
            selectBackend: { _, backend in backend },
            selectAuxiliaryFile: { model, kind, pairable, current in
                asked.append("\(model.relativePath)|\(kind)")
                #expect(current == nil)
                // The model itself is never offered; the list is complete (shards included).
                #expect(!pairable.contains { $0.relativePath == model.relativePath })
                #expect(pairable.contains { $0.relativePath == shardPath })
                // Five GGUFs in the folder, minus the model itself; the steering file is no GGUF.
                #expect(pairable.count == 4)
                #expect(!pairable.contains { $0.relativePath == Self.steeringPath })
                guard model.relativePath == Self.qwenPath else { return nil }
                return kind == .vision ? Self.visionPath : Self.mtpPath
            },
            promptTuning: { candidate, defaults in
                #expect(defaults == AgentDS4RuntimeTuning())
                guard candidate.relativePath == Self.qwenPath else { return defaults }
                return AgentDS4RuntimeTuning(
                    contextWindow: 32_768,
                    mtp: true,
                    dspark: true,
                    mtpDraftTokens: 4,
                    mtpMargin: 2.5,
                    quality: true,
                    threads: 12,
                    prefillChunk: 512,
                    warmWeights: true,
                    steeringRelativePath: Self.steeringPath,
                    steeringFFN: 1.5,
                    steeringAttn: -0.25,
                    cudaArch: "sm_120",
                    rocmArch: "gfx1100",
                    engineSessions: 4,
                    extraEngineArguments: ["--gpu-devices", "0,1"]
                )
            },
            engine: Self.engine(fixture)
        )

        let manifest = try #require(result)
        #expect(Set(asked) == [
            "\(Self.qwenPath)|vision", "\(Self.qwenPath)|mtp",
            "\(Self.customPath)|vision", "\(Self.customPath)|mtp"
        ])
        let qwen = try #require(manifest.models.first { $0.ds4Runtime?.modelRelativePath == Self.qwenPath })
        let runtime = try #require(qwen.ds4Runtime)
        #expect(runtime.visionRelativePath == Self.visionPath)
        #expect(runtime.mtpRelativePath == Self.mtpPath)
        #expect(runtime.steeringRelativePath == Self.steeringPath)
        #expect(runtime.mtp)
        #expect(runtime.dspark)
        #expect(runtime.mtpDraftTokens == 4)
        #expect(runtime.mtpMargin == 2.5)
        #expect(runtime.quality)
        #expect(runtime.threads == 12)
        #expect(runtime.prefillChunk == 512)
        #expect(runtime.warmWeights)
        #expect(runtime.steeringFFN == 1.5)
        #expect(runtime.steeringAttn == -0.25)
        #expect(runtime.cudaArch == "sm_120")
        #expect(runtime.rocmArch == "gfx1100")
        #expect(runtime.engineSessions == 4)
        #expect(runtime.extraEngineArguments == ["--gpu-devices", "0,1"])
        #expect(try runtime.resolvedVisionURL()?.lastPathComponent == "vision-projector.gguf")

        // The other model keeps the standard defaults and no optional file.
        let custom = try #require(manifest.models.first { $0.ds4Runtime?.modelRelativePath == Self.customPath })
        let customRuntime = try #require(custom.ds4Runtime)
        #expect(customRuntime.visionRelativePath == nil)
        #expect(customRuntime.mtpRelativePath == nil)
        #expect(customRuntime.steeringRelativePath == nil)
        #expect(customRuntime.engineSessions == 2)
        #expect(customRuntime.extraEngineArguments.isEmpty)

        let decoded = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: JSONEncoder().encode(manifest)
        )
        #expect(decoded.models.first { $0.id == qwen.id }?.ds4Runtime == runtime)
    }

    @Test
    func savedOptionsAreTheDefaultsOfThatModelOnly() async throws {
        let fixture = try Fixture.make(
            files: [Self.qwenPath, Self.customPath, Self.visionPath, Self.mtpPath, Self.steeringPath]
        )
        defer { fixture.remove() }
        let root = try AgentDS4PathGuard.canonicalRootDirectory(fixture.root.path)
        let saved = try AgentDS4RuntimeManifest(
            rootDirectory: root,
            modelRelativePath: Self.qwenPath,
            backend: .cuda,
            visionRelativePath: Self.visionPath,
            mtpRelativePath: Self.mtpPath,
            steeringRelativePath: Self.steeringPath,
            dspark: true,
            mtpDraftTokens: 3,
            mtpMargin: 4,
            quality: true,
            threads: 8,
            prefillChunk: 256,
            warmWeights: true,
            steeringFFN: 2,
            steeringAttn: 0.5,
            cudaArch: "sm_120",
            engineSessions: 3,
            extraEngineArguments: ["--gpu-devices", "0"]
        )
        let provider = AgentSettingsProviderManifest(
            id: ZenCODESetupRunner.ds4SetupProviderID,
            name: ZenCODESetupRunner.ds4SetupProviderName,
            baseURL: ZenCODESetupRunner.ds4SetupProviderBaseURL,
            chatEndpoint: .chatCompletions,
            providerProfileID: .custom,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: saved
        )
        let existing = AgentSettingsManifest(
            providers: [provider],
            models: [
                AgentSettingsModelManifest(
                    id: "my-qwen",
                    kind: .remoteAPI,
                    modelID: "qwen3.8-flash-next",
                    providerID: provider.id,
                    ds4Runtime: saved
                )
            ],
            selectedModelID: "my-qwen"
        )
        var auxiliaryDefaults: [String: String?] = [:]

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: existing,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)).intersection([Self.qwenPath, Self.customPath]) },
            selectBackend: { _, backend in backend },
            selectAuxiliaryFile: { model, kind, _, current in
                auxiliaryDefaults["\(model.relativePath)|\(kind)"] = .some(current)
                return current
            },
            promptTuning: { candidate, defaults in
                if candidate.relativePath == Self.qwenPath {
                    #expect(defaults.dspark)
                    #expect(defaults.mtpDraftTokens == 3)
                    #expect(defaults.mtpMargin == 4)
                    #expect(defaults.quality)
                    #expect(defaults.threads == 8)
                    #expect(defaults.prefillChunk == 256)
                    #expect(defaults.warmWeights)
                    #expect(defaults.steeringRelativePath == Self.steeringPath)
                    #expect(defaults.steeringFFN == 2)
                    #expect(defaults.steeringAttn == 0.5)
                    #expect(defaults.cudaArch == "sm_120")
                    #expect(defaults.engineSessions == 3)
                    #expect(defaults.extraEngineArguments == ["--gpu-devices", "0"])
                } else {
                    #expect(defaults == AgentDS4RuntimeTuning())
                }
                return defaults
            },
            engine: Self.engine(fixture)
        )

        #expect(auxiliaryDefaults["\(Self.qwenPath)|vision"] == .some(Self.visionPath))
        #expect(auxiliaryDefaults["\(Self.qwenPath)|mtp"] == .some(Self.mtpPath))
        #expect(auxiliaryDefaults["\(Self.customPath)|vision"] == .some(nil))
        #expect(auxiliaryDefaults["\(Self.customPath)|mtp"] == .some(nil))
        let updated = try #require(result)
        let kept = try #require(updated.models.first { $0.id == "my-qwen" }?.ds4Runtime)
        #expect(kept == saved)
    }

    @Test
    func savedAuxiliaryFileThatDisappearedIsDropped() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath, Self.visionPath])
        defer { fixture.remove() }
        let root = try AgentDS4PathGuard.canonicalRootDirectory(fixture.root.path)
        let saved = try AgentDS4RuntimeManifest(
            rootDirectory: root,
            modelRelativePath: Self.qwenPath,
            visionRelativePath: Self.visionPath
        )
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(Self.visionPath))
        let provider = AgentSettingsProviderManifest(
            id: ZenCODESetupRunner.ds4SetupProviderID,
            name: ZenCODESetupRunner.ds4SetupProviderName,
            baseURL: ZenCODESetupRunner.ds4SetupProviderBaseURL,
            chatEndpoint: .chatCompletions,
            providerProfileID: .custom,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: saved
        )
        let existing = AgentSettingsManifest(
            providers: [provider],
            models: [
                AgentSettingsModelManifest(
                    id: "my-qwen",
                    kind: .remoteAPI,
                    modelID: "qwen3.8-flash-next",
                    providerID: provider.id,
                    ds4Runtime: saved
                )
            ],
            selectedModelID: "my-qwen"
        )

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: existing,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { _, _ in [Self.qwenPath] },
            selectBackend: { _, backend in backend },
            selectAuxiliaryFile: { _, _, _, current in
                #expect(current == nil)
                return current
            },
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture)
        )
        let updated = try #require(result)
        #expect(updated.models.first { $0.id == "my-qwen" }?.ds4Runtime?.visionRelativePath == nil)
    }

    @Test
    func optionalFilesAreNotOfferedWithoutOtherGGUFs() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath])
        defer { fixture.remove() }

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, backend in backend },
            selectAuxiliaryFile: { _, _, _, _ in
                Issue.record("There is no other GGUF to pair")
                return nil
            },
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture)
        )
        let manifest = try #require(result)
        #expect(manifest.models.count == 1)
    }

    @Test
    func invalidAuxiliarySelectionLeavesManifestUnchanged() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath])
        defer { fixture.remove() }
        let original = Self.remoteManifest()

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: original,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { _, _ in [Self.qwenPath] },
            selectBackend: { _, backend in backend },
            selectAuxiliaryFile: { _, kind, _, _ in kind == .vision ? "../outside.gguf" : nil },
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture)
        )
        #expect(result == original)
    }

    // MARK: Engine build

    @Test
    func engineBuildIsAskedOnceForTheDistinctBackendsAndForwardsTheLog() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath, "other-DeepSeek-V4-Flash.gguf"], ds4Header: true)
        defer { fixture.remove() }
        let root = try AgentDS4PathGuard.canonicalRootDirectory(fixture.root.path)
        let builder = FakeEngineBuilder(logLines: ["compiling shim", "linking"])
        let output = SetupLineCollector()
        var questions: [[DS4EngineBuildRequest]] = []

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { candidate, _ in
                // Two models share the CPU backend, one needs CUDA.
                candidate.relativePath == Self.customPath ? .cuda : .cpu
            },
            selectAuxiliaryFile: Self.keepAuxiliary,
            promptTuning: { candidate, defaults in
                candidate.relativePath == Self.customPath ? AgentDS4RuntimeTuning(cudaArch: "sm_120") : defaults
            },
            engine: Self.engine(fixture, builder: builder, output: output) { requests in
                questions.append(requests)
                return true
            }
        )

        #expect(result != nil)
        #expect(questions.count == 1)
        let expected = [
            DS4EngineBuildRequest(
                rootDirectory: root, backend: .cuda, cudaArch: "sm_120", rocmArch: nil,
                supportDirectory: fixture.support
            ),
            DS4EngineBuildRequest(
                rootDirectory: root, backend: .cpu, cudaArch: nil, rocmArch: nil,
                supportDirectory: fixture.support
            )
        ]
        #expect(Set(questions[0].map(\.backend)) == [.cuda, .cpu])
        #expect(builder.requests.count == 2)
        for request in expected {
            #expect(builder.requests.contains(request))
        }
        #expect(output.lines.filter { $0 == "compiling shim" }.count == 2)
        #expect(output.lines.contains("linking"))
        #expect(output.text.contains("DS4 engine built (cuda sm_120)"))
        #expect(output.text.contains("DS4 engine built (cpu)"))
    }

    @Test
    func declinedEngineBuildKeepsTheConfiguration() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath], ds4Header: true)
        defer { fixture.remove() }
        let builder = FakeEngineBuilder()
        let output = SetupLineCollector()
        var asked = 0

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, backend in backend },
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture, builder: builder, output: output) { _ in
                asked += 1
                return false
            }
        )

        #expect(try #require(result).models.count == 1)
        #expect(asked == 1)
        #expect(builder.requests.isEmpty)
        #expect(output.text.contains("DS4 engine build skipped"))
    }

    @Test
    func engineAlreadyBuiltIsNotRebuiltNorAsked() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath], ds4Header: true)
        defer { fixture.remove() }
        let root = try AgentDS4PathGuard.canonicalRootDirectory(fixture.root.path)
        try fixture.markEngineBuilt(for: AgentDS4RuntimeManifest(rootDirectory: root, backend: .cpu))
        let builder = FakeEngineBuilder()
        let output = SetupLineCollector()

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, _ in .cpu },
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture, builder: builder, output: output)
        )

        #expect(result != nil)
        #expect(builder.requests.isEmpty)
        #expect(output.text.contains("DS4 engine already built (cpu)"))
    }

    @Test
    func staleEngineIsRebuiltAfterTheQuestion() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath], ds4Header: true)
        defer { fixture.remove() }
        let root = try AgentDS4PathGuard.canonicalRootDirectory(fixture.root.path)
        try fixture.writeEngineLibrary(
            for: AgentDS4RuntimeManifest(rootDirectory: root, backend: .cpu),
            metadata: DS4EngineBuildMetadata(
                root: "/somewhere/else", backend: "cpu", arch: nil, date: nil, hash: nil, abiVersion: nil
            )
        )
        let builder = FakeEngineBuilder()
        let output = SetupLineCollector()
        var asked = 0

        _ = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, _ in .cpu },
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture, builder: builder, output: output) { _ in
                asked += 1
                return true
            }
        )

        #expect(asked == 1)
        #expect(builder.requests.count == 1)
        #expect(output.text.contains("out of date"))
    }

    @Test
    func failedEngineBuildPrintsErrorAndManualCommandWithoutCancellingTheSetup() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath], ds4Header: true)
        defer { fixture.remove() }
        let libraryPath = "/missing/libzencode-ds4.dylib"
        let builder = FakeEngineBuilder(
            result: .failure(.libraryNotProduced(path: libraryPath)),
            logLines: ["make: *** error"]
        )
        let output = SetupLineCollector()

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, _ in .cpu },
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture, builder: builder, output: output) { _ in true }
        )

        // The staged configuration survives the failed build.
        let manifest = try #require(result)
        #expect(manifest.models.count == 1)
        let request = try #require(builder.requests.first)
        #expect(output.lines.contains("make: *** error"))
        #expect(output.text.contains("DS4 engine build failed (cpu)"))
        #expect(output.text.contains(libraryPath))
        #expect(output.text.contains(DS4EngineBuilder.manualCommand(for: request)))
    }

    @Test
    func buildErrorThatAlreadyCarriesTheManualCommandIsNotRepeated() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath], ds4Header: true)
        defer { fixture.remove() }
        let builder = FakeEngineBuilder(result: .failure(.buildFailed(exitCode: 2, manualCommand: "make-it-by-hand")))
        let output = SetupLineCollector()

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, _ in .cpu },
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture, builder: builder, output: output) { _ in true }
        )

        #expect(result != nil)
        #expect(output.text.components(separatedBy: "make-it-by-hand").count == 2)
    }

    @Test
    func missingDS4HeaderSkipsTheEngineQuestion() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath])
        defer { fixture.remove() }
        let builder = FakeEngineBuilder()
        let output = SetupLineCollector()

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, backend in backend },
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture, builder: builder, output: output)
        )

        #expect(result != nil)
        #expect(builder.requests.isEmpty)
        #expect(output.text.contains("ds4.h not found"))
    }

    @Test
    func cancellingTheEngineQuestionLeavesManifestUnchanged() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath], ds4Header: true)
        defer { fixture.remove() }
        let original = Self.remoteManifest()
        let builder = FakeEngineBuilder()

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: original,
            promptFolder: { _ in fixture.root.path },
            selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
            selectBackend: { _, backend in backend },
            promptTuning: { _, tuning in tuning },
            engine: Self.engine(fixture, builder: builder) { _ in throw ZenCODESetupError.cancelled }
        )

        #expect(result == original)
        #expect(builder.requests.isEmpty)
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
        let base: URL
        /// The DS4 checkout.
        let root: URL
        /// Stand-in for the app support folder (engine libraries and sources).
        let support: URL

        static func make(files: [String], ds4Header: Bool = false) throws -> Fixture {
            let fileManager = FileManager.default
            let base = fileManager.temporaryDirectory
                .appendingPathComponent("zencode-ds4-setup-")
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            let root = base.appendingPathComponent("ds4", isDirectory: true)
            let support = base.appendingPathComponent("support", isDirectory: true)
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
            for file in files {
                let url = root.appendingPathComponent(file)
                try fileManager.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try Data(repeating: 1, count: 16).write(to: url)
            }
            if ds4Header {
                try Data("/* ds4.h */\n".utf8).write(to: root.appendingPathComponent("ds4.h"))
            }
            return Fixture(base: base, root: root, support: support)
        }

        /// Creates the library of `runtime` with a build record that matches it.
        func markEngineBuilt(for runtime: AgentDS4RuntimeManifest) throws {
            let arch = DS4EngineLibraryLocator.effectiveArch(
                backend: runtime.backend,
                arch: runtime.backend == .cuda ? runtime.cudaArch : runtime.rocmArch
            )
            try writeEngineLibrary(
                for: runtime,
                metadata: DS4EngineBuildMetadata(
                    root: runtime.rootDirectory,
                    backend: runtime.backend.rawValue,
                    arch: arch,
                    date: nil,
                    hash: nil,
                    abiVersion: nil
                )
            )
        }

        /// Creates the library of `runtime` next to the given build record.
        func writeEngineLibrary(
            for runtime: AgentDS4RuntimeManifest,
            metadata: DS4EngineBuildMetadata
        ) throws {
            let library = try DS4EngineLibraryLocator.expectedURL(
                rootDirectory: runtime.rootDirectory,
                backend: runtime.backend,
                supportDirectory: support
            )
            let directory = library.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("library".utf8).write(to: library)
            try JSONEncoder().encode(metadata).write(
                to: directory.appendingPathComponent(DS4EngineLibraryLocator.buildMetadataFileName)
            )
        }

        func remove() {
            try? FileManager.default.removeItem(at: base)
        }
    }
}
