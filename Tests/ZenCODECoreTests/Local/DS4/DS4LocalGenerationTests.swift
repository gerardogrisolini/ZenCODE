//
//  DS4LocalGenerationTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("DS4 local generation configuration")
struct DS4LocalGenerationTests {
    private static func touch(_ name: String, in root: String) throws -> String {
        let url = URL(fileURLWithPath: root).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x47, count: 64).write(to: url)
        return url.path
    }

    @Test
    func mapsEveryManifestFieldToEngineOptions() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }
        let root = fixture.rootDirectory
        let model = try Self.touch("models/flash.gguf", in: root)
        let mtp = try Self.touch("models/mtp.gguf", in: root)
        let vision = try Self.touch("models/vision.gguf", in: root)
        let steering = try Self.touch("steering/dir.bin", in: root)
        let manifest = try AgentDS4RuntimeManifest(
            rootDirectory: root,
            modelRelativePath: "models/flash.gguf",
            backend: .cuda,
            contextWindow: 131_072,
            ssdStreaming: true,
            ssdStreamingCacheBytes: 16 << 30,
            ssdStreamingPreloadExperts: 8,
            ssdStreamingCold: true,
            mtp: true,
            power: 80,
            visionRelativePath: "models/vision.gguf",
            mtpRelativePath: "models/mtp.gguf",
            steeringRelativePath: "steering/dir.bin",
            dspark: true,
            mtpDraftTokens: 3,
            mtpMargin: 2.5,
            quality: true,
            threads: 12,
            prefillChunk: 4096,
            warmWeights: true,
            steeringFFN: 1.5,
            steeringAttn: -2,
            cudaArch: "sm_120",
            engineSessions: 4,
            extraEngineArguments: ["--gpu-devices", "0,1"]
        )

        let options = try DS4EngineConfigurationMapping.options(for: manifest)

        #expect(options.map(\.keyValue) == [
            "ds4_root=\(root)",
            "model_path=\(model)",
            "mtp_path=\(mtp)",
            "vision_path=\(vision)",
            "backend=cuda",
            "n_threads=12",
            "context_size=131072",
            "session_count=4",
            "prefill_chunk=4096",
            "mtp_draft_tokens=3",
            "mtp_margin=2.5",
            "glm_mtp=1",
            "dspark=1",
            "power_percent=80",
            "quality=1",
            "warm_weights=1",
            "ssd_streaming=1",
            "ssd_streaming_cold=1",
            "ssd_streaming_cache_experts=16GB",
            "ssd_streaming_preload_experts=8",
            "directional_steering_file=\(steering)",
            "directional_steering_ffn=1.5",
            "directional_steering_attn=-2",
            "extra_arg=--gpu-devices",
            "extra_arg=0,1",
        ])
        // The engine configuration adds nothing: context and sessions are explicit.
        let configuration = DS4EngineConfiguration(
            libraryURL: URL(fileURLWithPath: "/tmp/lib"),
            options: options,
            contextSize: manifest.contextWindow,
            sessionCapacity: manifest.engineSessions,
            buildHint: ""
        )
        #expect(configuration.effectiveOptions == options)
    }

    @Test
    func minimalManifestPassesOnlyRequiredOptions() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }
        let model = try Self.touch("flash.gguf", in: fixture.rootDirectory)
        let manifest = try AgentDS4RuntimeManifest(rootDirectory: fixture.rootDirectory, modelRelativePath: "flash.gguf")

        let options = try DS4EngineConfigurationMapping.options(for: manifest)

        #expect(options.map(\.keyValue) == [
            "ds4_root=\(fixture.rootDirectory)",
            "model_path=\(model)",
            "backend=metal",
            "context_size=65536",
            "session_count=\(AgentDS4RuntimeManifest.defaultEngineSessions)",
            "power_percent=100",
        ])
    }

    @Test
    func missingModelFileFailsTheMapping() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }
        let manifest = try AgentDS4RuntimeManifest(rootDirectory: fixture.rootDirectory, modelRelativePath: "absent.gguf")
        #expect(throws: AgentDS4PathValidationError.self) {
            _ = try DS4EngineConfigurationMapping.options(for: manifest)
        }
    }

    @Test
    func cacheExpertsPrefersTheCountAndRoundsBytesToGiB() {
        #expect(DS4EngineConfigurationMapping.cacheExpertsValue(experts: 64, bytes: 8 << 30) == "64")
        #expect(DS4EngineConfigurationMapping.cacheExpertsValue(experts: nil, bytes: (8 << 30) + 5) == "8GB")
        #expect(DS4EngineConfigurationMapping.cacheExpertsValue(experts: nil, bytes: 1024) == "1GB")
        #expect(DS4EngineConfigurationMapping.cacheExpertsValue(experts: nil, bytes: nil) == nil)
        #expect(DS4EngineConfigurationMapping.format(3) == "3")
        #expect(DS4EngineConfigurationMapping.format(0.25) == "0.25")
    }

    @Test
    func missingLibraryThrowsLibraryUnavailableWithTheBuildCommand() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }
        _ = try Self.touch("flash.gguf", in: fixture.rootDirectory)
        let manifest = try AgentDS4RuntimeManifest(rootDirectory: fixture.rootDirectory, modelRelativePath: "flash.gguf")
        let expectedHint = DS4EngineBuilder.manualCommand(for: DS4EngineBuildRequest(
            rootDirectory: fixture.rootDirectory,
            backend: .metal,
            cudaArch: nil,
            rocmArch: nil,
            supportDirectory: fixture.supportDirectory
        ))

        #expect {
            _ = try DS4EngineConfigurationMapping.configuration(for: manifest, supportDirectory: fixture.supportDirectory)
        } throws: { error in
            guard case let DS4EngineError.libraryUnavailable(reason, hint) = error else {
                return false
            }
            return hint == expectedHint && reason.contains("not built")
        }

        // A library built for another root is stale.
        let hash = try DS4EngineLibraryLocator.sourceHash(rootDirectory: fixture.rootDirectory)
        try fixture.installLibrary(backend: .metal, hash: hash, recordedRoot: "/elsewhere")
        #expect {
            _ = try DS4EngineConfigurationMapping.configuration(for: manifest, supportDirectory: fixture.supportDirectory)
        } throws: { error in
            guard case let DS4EngineError.libraryUnavailable(reason, _) = error else {
                return false
            }
            return reason.contains("other sources")
        }
    }

    @Test
    func builtLibraryProducesTheEngineConfiguration() throws {
        let fixture = try DS4EngineBuildFixture()
        defer { fixture.remove() }
        _ = try Self.touch("flash.gguf", in: fixture.rootDirectory)
        let hash = try DS4EngineLibraryLocator.sourceHash(rootDirectory: fixture.rootDirectory)
        let library = try fixture.installLibrary(backend: .rocm, hash: hash, arch: "gfx1100")
        let manifest = try AgentDS4RuntimeManifest(
            rootDirectory: fixture.rootDirectory,
            modelRelativePath: "flash.gguf",
            backend: .rocm,
            contextWindow: 32_768,
            rocmArch: "gfx1100",
            engineSessions: 3
        )

        let configuration = try DS4EngineConfigurationMapping.configuration(
            for: manifest,
            supportDirectory: fixture.supportDirectory
        )

        #expect(configuration.libraryURL.standardizedFileURL.path == library.standardizedFileURL.path)
        #expect(configuration.contextSize == 32_768)
        #expect(configuration.sessionCapacity == 3)
        #expect(configuration.options.contains(DS4EngineOption(key: "backend", value: "rocm")))
        #expect(configuration.buildHint.contains("--backend rocm"))
        // The production environment uses the same mapping.
        let generation = DS4LocalGeneration(
            manifest: manifest,
            environment: DS4LocalGeneration.Environment(registry: DS4EngineRegistry()) { manifest in
                try DS4EngineConfigurationMapping.configuration(for: manifest, supportDirectory: fixture.supportDirectory)
            }
        )
        #expect(try generation.engineConfiguration() == configuration)
    }
}

@Suite("AgentRemoteBackendFactory DS4")
struct AgentRemoteBackendFactoryDS4Tests {
    @Test
    func ds4SelectionGetsLocalGenerationAndTheManifestContextWindow() async throws {
        let harness = try DS4ClientHarness(contextSize: 16_384)
        let backend = try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: harness.runtimeConfiguration(),
            mcpRuntime: DirectMCPToolRuntime(),
            resolvedModelSelection: harness.selection(contextWindowLimit: 200_000),
            ds4Environment: harness.environment
        )
        let client = try #require(backend as? RemoteGenerationClient)

        let generation = try #require(await client.ds4Generation)
        #expect(generation.registry === harness.registry)
        #expect(generation.manifest == harness.manifest)
        // The manifest context window wins over the model settings.
        #expect(await client.configuration.configuredContextWindowLimit == 16_384)
        #expect(harness.openCount == 0)
        await client.shutdown()
    }

    @Test
    func remoteSelectionStaysAnOrdinaryClient() async throws {
        let provider = AgentRemoteProvider(
            name: "Remote",
            baseURL: "https://remote.invalid/v1",
            modelID: "remote-model",
            chatEndpoint: .chatCompletions,
            providerProfileID: .openAI,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .apiKeyRequired
        )
        let backend = try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: AgentRuntimeConfiguration(
                modelID: provider.modelID,
                workingDirectory: FileManager.default.temporaryDirectory,
                configuredContextWindowLimit: 100_000,
                maxToolRounds: 2,
                toolAuthorizationHandler: nil
            ),
            mcpRuntime: DirectMCPToolRuntime(),
            resolvedModelSelection: AgentModelSelection(
                providerKind: .remoteAPI,
                modelID: provider.modelID,
                remoteProvider: provider,
                apiKey: "key",
                configuredContextWindowLimit: 100_000,
                generationParameterOverrides: nil,
                thinkingSelection: nil
            )
        )
        let client = try #require(backend as? RemoteGenerationClient)
        #expect(await client.ds4Generation == nil)
        #expect(await client.configuration.configuredContextWindowLimit == 100_000)
        await client.shutdown()
    }
}
