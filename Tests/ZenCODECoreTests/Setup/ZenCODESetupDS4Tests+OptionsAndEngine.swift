//
//  ZenCODESetupDS4Tests+OptionsAndEngine.swift
//  ZenCODECoreTests
//
//  Tests of the DS4 setup that persist the optional files and the launch
//  options of each model and that ask for, decline, run or fail the engine
//  build and rebuild.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

extension ZenCODESetupDS4Tests {
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
            prompts: DS4SetupPrompts(
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
                }
            ),
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
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
                selectBackend: { candidate, _ in
                    // Two models share the CPU backend, one needs CUDA.
                    candidate.relativePath == Self.customPath ? .cuda : .cpu
                },
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { candidate, defaults in
                    candidate.relativePath == Self.customPath ? AgentDS4RuntimeTuning(cudaArch: "sm_120") : defaults
                }
            ),
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
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
                selectBackend: { _, backend in backend },
                promptTuning: { _, tuning in tuning }
            ),
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
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
                selectBackend: { _, _ in .cpu },
                promptTuning: { _, tuning in tuning }
            ),
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
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
                selectBackend: { _, _ in .cpu },
                promptTuning: { _, tuning in tuning }
            ),
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

    // MARK: Engine rebuild

    @Test
    func rebuildChoiceRebuildsEveryDistinctTargetEvenWhenBuilt() async throws {
        let otherPath = "other-DeepSeek-V4-Flash.gguf"
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath, otherPath], ds4Header: true)
        defer { fixture.remove() }
        let root = try AgentDS4PathGuard.canonicalRootDirectory(fixture.root.path)
        // Two models share the CPU library, one needs CUDA.
        let cpu = try AgentDS4RuntimeManifest(rootDirectory: root, modelRelativePath: Self.qwenPath, backend: .cpu)
        let sharedCPU = try AgentDS4RuntimeManifest(rootDirectory: root, modelRelativePath: otherPath, backend: .cpu)
        let cuda = try AgentDS4RuntimeManifest(
            rootDirectory: root, modelRelativePath: Self.customPath, backend: .cuda, cudaArch: "sm_120"
        )
        // Both libraries are up to date: the rebuild must not care.
        try fixture.markEngineBuilt(for: cpu)
        try fixture.markEngineBuilt(for: cuda)
        for runtime in [cpu, cuda] {
            let target = DS4EngineTarget(runtime: runtime)
            #expect(ZenCODESetupRunner.ds4EngineStateDescription(for: target, supportDirectory: fixture.support) == "built")
        }
        let existing = Self.ds4Manifest(runtimes: [cpu, cuda, sharedCPU])
        let builder = FakeEngineBuilder(logLines: ["compiling shim", "linking"])
        let output = SetupLineCollector()
        var questions = 0
        var actionPrompts = 0

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: existing,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in
                    Issue.record("The rebuild must not walk the reconfigure flow")
                    return nil
                }
            ),
            selectAction: {
                actionPrompts += 1
                return .rebuildEngine
            },
            engine: Self.engine(fixture, builder: builder, output: output) { _ in
                questions += 1
                return true
            }
        )

        // The settings are returned untouched.
        #expect(result == existing)
        #expect(actionPrompts == 1)
        // Choosing the entry is the confirmation: nothing is asked.
        #expect(questions == 0)
        #expect(builder.requests.count == 2)
        for runtime in [cpu, cuda] {
            #expect(builder.requests.contains(DS4EngineTarget(runtime: runtime).buildRequest(supportDirectory: fixture.support)))
        }
        #expect(output.lines.filter { $0 == "compiling shim" }.count == 2)
        #expect(output.lines.contains("linking"))
        #expect(output.lines.contains("==> Rebuilding the DS4 engine (cpu)"))
        #expect(output.lines.contains("==> Rebuilding the DS4 engine (cuda sm_120)"))
        #expect(output.lines.contains("DS4 engine rebuilt (cpu): /fake/libzencode-ds4.dylib"))
        #expect(output.lines.contains("DS4 engine rebuilt (cuda sm_120): /fake/libzencode-ds4.dylib"))
        #expect(!output.text.contains("already built"))
        #expect(!output.text.contains("Building the DS4 engine"))
    }

    /// A manifest with the DS4 provider and one DS4 model per runtime.
    private static func ds4Manifest(runtimes: [AgentDS4RuntimeManifest]) -> AgentSettingsManifest {
        let providerID = ZenCODESetupRunner.ds4SetupProviderID
        let provider = AgentSettingsProviderManifest(
            id: providerID,
            name: ZenCODESetupRunner.ds4SetupProviderName,
            baseURL: ZenCODESetupRunner.ds4SetupProviderBaseURL,
            chatEndpoint: .chatCompletions,
            providerProfileID: .ds4,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: runtimes.first
        )
        let models = runtimes.enumerated().map { index, runtime in
            AgentSettingsModelManifest(
                id: "ds4:model-\(index)",
                kind: .remoteAPI,
                modelID: "deepseek-v4.1-flash",
                providerID: providerID,
                ds4Runtime: runtime
            )
        }
        return AgentSettingsManifest(
            providers: [provider],
            models: models,
            selectedModelID: models.first?.id
        )
    }
}
