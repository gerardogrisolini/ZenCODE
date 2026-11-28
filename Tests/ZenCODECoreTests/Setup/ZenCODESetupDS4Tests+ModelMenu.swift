//
//  ZenCODESetupDS4Tests+ModelMenu.swift
//  ZenCODECoreTests
//
//  Tests of the "DS4 models" menu: one model configured, deleted or added on
//  its own, Esc inside a step and on the menu, Done without models, the
//  values setup no longer asks, DSpark proposed again and a changed folder.
//

import Foundation
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

extension ZenCODESetupDS4Tests {
    @Test
    func configuringOneModelAsksOnlyThatModel() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath])
        defer { fixture.remove() }
        let root = try AgentDS4PathGuard.canonicalRootDirectory(fixture.root.path)
        let qwen = try Self.savedDS4Model(
            id: "my-qwen",
            apiModelID: "qwen3.8-flash-next",
            path: Self.qwenPath,
            in: fixture,
            runtime: AgentDS4RuntimeManifest(
                rootDirectory: root, modelRelativePath: Self.qwenPath, backend: .cpu, contextWindow: 8_192
            )
        )
        let deepSeek = try Self.savedDS4Model(
            id: "my-ds41",
            apiModelID: "deepseek-v4.1-flash",
            path: Self.customPath,
            in: fixture,
            runtime: AgentDS4RuntimeManifest(
                rootDirectory: root, modelRelativePath: Self.customPath, backend: .cuda,
                contextWindow: 131_072, ssdStreaming: true
            )
        )
        var asked: [String] = []
        let menu = ScriptedDS4ModelMenu([.configure("my-qwen"), .done])

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: Self.savedDS4Manifest(models: [qwen, deepSeek]),
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectModelMenu: menu.select,
                selectBackend: { candidate, backend in
                    asked.append(candidate.relativePath)
                    #expect(backend == .cpu)
                    return .metal
                },
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { _, defaults in
                    #expect(defaults.contextWindow == 8_192)
                    return AgentDS4RuntimeTuning(contextWindow: 32_768, ssdStreaming: true, mtp: true)
                }
            ),
            selectAction: { .reconfigure },
            engine: Self.engine(fixture)
        )

        let updated = try #require(result)
        #expect(asked == [Self.qwenPath])
        #expect(menu.shown == [["my-qwen", "my-ds41"], ["my-qwen", "my-ds41"]])
        // Both GGUFs of the folder are used: there is nothing to add.
        #expect(menu.offeredAdd == [false, false])
        #expect(updated.models.map(\.id) == ["my-qwen", "my-ds41"])
        let configured = try #require(updated.models.first { $0.id == "my-qwen" }?.ds4Runtime)
        #expect(configured.backend == .metal)
        #expect(configured.contextWindow == 32_768)
        #expect(configured.ssdStreaming)
        #expect(configured.mtp)
        // The other model is exactly as it was saved.
        #expect(updated.models.first { $0.id == "my-ds41" }?.ds4Runtime == deepSeek.ds4Runtime)
    }

    @Test
    func addingAModelAsksOnlyTheAddedFile() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath])
        defer { fixture.remove() }
        let qwen = try Self.savedDS4Model(
            id: "my-qwen",
            apiModelID: "qwen3.8-flash-next",
            path: Self.qwenPath,
            in: fixture
        )
        var asked: [String] = []
        let menu = ScriptedDS4ModelMenu([.add, .done])

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: Self.savedDS4Manifest(models: [qwen]),
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, preselected in
                    #expect(candidates.map(\.relativePath) == [Self.customPath])
                    #expect(preselected.isEmpty)
                    return [Self.customPath]
                },
                selectModelMenu: menu.select,
                selectBackend: { candidate, backend in
                    asked.append(candidate.relativePath)
                    return backend
                },
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { _, tuning in tuning }
            ),
            selectAction: { .reconfigure },
            engine: Self.engine(fixture)
        )

        let updated = try #require(result)
        #expect(asked == [Self.customPath])
        #expect(menu.offeredAdd == [true, false])
        #expect(updated.models.count == 2)
        #expect(updated.models.first { $0.id == "my-qwen" }?.ds4Runtime == qwen.ds4Runtime)
        #expect(updated.models.contains { $0.ds4Runtime?.modelRelativePath == Self.customPath })
    }

    @Test
    func escOrAnErrorInsideAStepDiscardsOnlyThatStep() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath])
        defer { fixture.remove() }
        let qwen = try Self.savedDS4Model(
            id: "my-qwen",
            apiModelID: "qwen3.8-flash-next",
            path: Self.qwenPath,
            in: fixture
        )
        var configurations = 0
        let menu = ScriptedDS4ModelMenu([.configure("my-qwen"), .configure("my-qwen"), .add, .done])

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: Self.savedDS4Manifest(models: [qwen]),
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                // Esc on the selection of Add models.
                selectFiles: { _, _ in nil },
                selectModelMenu: menu.select,
                selectBackend: { _, backend in
                    configurations += 1
                    // Esc in the first configuration.
                    if configurations == 1 {
                        throw ZenCODESetupError.cancelled
                    }
                    return .cuda
                },
                selectAuxiliaryFile: Self.keepAuxiliary,
                // An invalid value in the second one.
                promptTuning: { _, _ in throw AgentDS4RuntimeConfigurationError.invalidPower(0) }
            ),
            selectAction: { .reconfigure },
            engine: Self.engine(fixture)
        )

        // Each step went back to the menu, and Done kept the model as it was.
        let updated = try #require(result)
        #expect(menu.shown.count == 4)
        #expect(updated.models.count == 1)
        #expect(updated.models[0].ds4Runtime == qwen.ds4Runtime)
    }

    @Test
    func escOnTheMenuDiscardsEveryChange() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath])
        defer { fixture.remove() }
        let existing = try Self.savedDS4Manifest(models: [
            Self.savedDS4Model(id: "my-qwen", apiModelID: "qwen3.8-flash-next", path: Self.qwenPath, in: fixture),
            Self.savedDS4Model(id: "my-ds41", apiModelID: "deepseek-v4.1-flash", path: Self.customPath, in: fixture)
        ])
        // Delete one, configure the other, then Esc.
        let menu = ScriptedDS4ModelMenu([.delete("my-ds41"), .configure("my-qwen")])

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: existing,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectModelMenu: menu.select,
                selectBackend: { _, _ in .cuda },
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { _, _ in AgentDS4RuntimeTuning(contextWindow: 1_024) }
            ),
            selectAction: { .reconfigure },
            engine: Self.engine(fixture)
        )

        #expect(menu.shown == [["my-qwen", "my-ds41"], ["my-qwen"], ["my-qwen"]])
        #expect(result == existing)
    }

    @Test
    func doneNeedsAtLeastOneModel() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath])
        defer { fixture.remove() }
        let existing = try Self.savedDS4Manifest(models: [
            Self.savedDS4Model(id: "my-qwen", apiModelID: "qwen3.8-flash-next", path: Self.qwenPath, in: fixture)
        ])
        // Delete the only model and press Done: the menu opens again; then Esc.
        let menu = ScriptedDS4ModelMenu([.delete("my-qwen"), .done])

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: existing,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectModelMenu: menu.select
            ),
            selectAction: { .reconfigure },
            engine: Self.engine(fixture)
        )

        #expect(menu.shown == [["my-qwen"], [], []])
        // With nothing left the deleted GGUF can be added again.
        #expect(menu.offeredAdd == [false, true, true])
        #expect(result == existing)
    }

    @Test
    func valuesSetupNoLongerAsksAreKeptWhenAModelIsConfigured() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.steeringPath])
        defer { fixture.remove() }
        let saved = try AgentDS4RuntimeManifest(
            rootDirectory: AgentDS4PathGuard.canonicalRootDirectory(fixture.root.path),
            modelRelativePath: Self.qwenPath,
            backend: .cuda,
            power: 40,
            steeringRelativePath: Self.steeringPath,
            mtpDraftTokens: 4,
            mtpMargin: 2.5,
            quality: true,
            threads: 12,
            prefillChunk: 512,
            warmWeights: true,
            steeringFFN: 1.5,
            steeringAttn: -0.25,
            cudaArch: "sm_120",
            engineSessions: 4,
            extraEngineArguments: ["--gpu-devices", "0,1"]
        )
        let qwen = try Self.savedDS4Model(
            id: "my-qwen",
            apiModelID: "qwen3.8-flash-next",
            path: Self.qwenPath,
            in: fixture,
            runtime: saved
        )

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: Self.savedDS4Manifest(models: [qwen]),
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectModelMenu: ScriptedDS4ModelMenu([.configure("my-qwen"), .done]).select,
                selectBackend: { _, backend in backend },
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { _, defaults in defaults }
            ),
            selectAction: { .reconfigure },
            engine: Self.engine(fixture)
        )

        let manifest = try #require(result)
        let runtime = try #require(manifest.models.first?.ds4Runtime)
        #expect(runtime == saved)
        #expect(runtime.power == 40)
        #expect(runtime.steeringRelativePath == Self.steeringPath)
        #expect(runtime.steeringFFN == 1.5)
        #expect(runtime.steeringAttn == -0.25)
        #expect(runtime.mtpDraftTokens == 4)
        #expect(runtime.mtpMargin == 2.5)
        #expect(runtime.quality)
        #expect(runtime.threads == 12)
        #expect(runtime.prefillChunk == 512)
        #expect(runtime.warmWeights)
        #expect(runtime.cudaArch == "sm_120")
        #expect(runtime.engineSessions == 4)
        #expect(runtime.extraEngineArguments == ["--gpu-devices", "0,1"])
    }

    @Test
    func dsparkSupportModelIsProposedAgainOnlyWhenDSparkWasOn() async throws {
        let otherDeepSeekPath = "other-DeepSeek-V4-Flash.gguf"
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.customPath, otherDeepSeekPath, Self.mtpPath])
        defer { fixture.remove() }
        let root = try AgentDS4PathGuard.canonicalRootDirectory(fixture.root.path)
        func saved(_ id: String, _ apiModelID: String, _ path: String, dspark: Bool) throws -> AgentSettingsModelManifest {
            try Self.savedDS4Model(
                id: id,
                apiModelID: apiModelID,
                path: path,
                in: fixture,
                runtime: AgentDS4RuntimeManifest(
                    rootDirectory: root, modelRelativePath: path, mtpRelativePath: Self.mtpPath, dspark: dspark
                )
            )
        }
        let models = try [
            saved("ds-on", "deepseek-v4.1-flash", Self.customPath, dspark: true),
            // A support file without DSpark (the legacy MTP drafter).
            saved("ds-off", "deepseek-v4-flash", otherDeepSeekPath, dspark: false),
            // DSpark and a support file on a family that has no DSpark.
            saved("qwen", "qwen3.8-flash-next", Self.qwenPath, dspark: true)
        ]
        var proposed: [String: String?] = [:]
        var kinds: [String: [DS4SetupAuxiliaryKind]] = [:]

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: Self.savedDS4Manifest(models: models),
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectModelMenu: ScriptedDS4ModelMenu([
                    .configure("ds-on"), .configure("ds-off"), .configure("qwen"), .done
                ]).select,
                selectBackend: { _, backend in backend },
                selectAuxiliaryFile: { model, kind, _, current in
                    kinds[model.relativePath, default: []].append(kind)
                    if kind == .dspark {
                        proposed[model.relativePath] = current
                    }
                    return current
                },
                promptTuning: { _, tuning in tuning }
            ),
            selectAction: { .reconfigure },
            engine: Self.engine(fixture)
        )

        #expect(kinds[Self.customPath] == [.vision, .dspark])
        #expect(kinds[otherDeepSeekPath] == [.vision, .dspark])
        #expect(kinds[Self.qwenPath] == [.vision])
        #expect(proposed[Self.customPath] == .some(Self.mtpPath))
        #expect(proposed[otherDeepSeekPath] == .some(nil))

        let updated = try #require(result)
        let on = try #require(updated.models.first { $0.id == "ds-on" }?.ds4Runtime)
        #expect(on.dspark)
        #expect(on.mtpRelativePath == Self.mtpPath)
        let off = try #require(updated.models.first { $0.id == "ds-off" }?.ds4Runtime)
        #expect(!off.dspark)
        #expect(off.mtpRelativePath == nil)
        let qwen = try #require(updated.models.first { $0.id == "qwen" }?.ds4Runtime)
        #expect(!qwen.dspark)
        #expect(qwen.mtpRelativePath == nil)
    }

    @Test
    func savedModelsMoveToANewFolderAndTheOnesItLacksAreDropped() async throws {
        let oldFixture = try Fixture.make(files: [Self.qwenPath, Self.customPath, Self.visionPath])
        defer { oldFixture.remove() }
        let newFixture = try Fixture.make(files: [Self.qwenPath])
        defer { newFixture.remove() }
        let oldRoot = try AgentDS4PathGuard.canonicalRootDirectory(oldFixture.root.path)
        let newRoot = try AgentDS4PathGuard.canonicalRootDirectory(newFixture.root.path)
        let models = try [
            Self.savedDS4Model(
                id: "my-qwen",
                apiModelID: "qwen3.8-flash-next",
                path: Self.qwenPath,
                in: oldFixture,
                runtime: AgentDS4RuntimeManifest(
                    rootDirectory: oldRoot, modelRelativePath: Self.qwenPath, contextWindow: 8_192,
                    mtp: true, visionRelativePath: Self.visionPath
                )
            ),
            Self.savedDS4Model(id: "my-ds41", apiModelID: "deepseek-v4.1-flash", path: Self.customPath, in: oldFixture)
        ]
        let menu = ScriptedDS4ModelMenu([.done])

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: Self.savedDS4Manifest(models: models),
            prompts: DS4SetupPrompts(
                promptFolder: { previous in
                    #expect(previous == oldRoot)
                    return newFixture.root.path
                },
                selectModelMenu: menu.select
            ),
            selectAction: { .reconfigure },
            engine: Self.engine(newFixture)
        )

        // Only the model whose GGUF the new folder holds is shown and kept.
        #expect(menu.shown == [["my-qwen"]])
        let updated = try #require(result)
        #expect(updated.models.map(\.id) == ["my-qwen"])
        let runtime = try #require(updated.models[0].ds4Runtime)
        #expect(runtime.rootDirectory == newRoot)
        #expect(runtime.contextWindow == 8_192)
        #expect(runtime.mtp)
        // The vision projector is not in the new folder.
        #expect(runtime.visionRelativePath == nil)
        #expect(updated.providers.first { $0.ds4Runtime != nil }?.ds4Runtime?.rootDirectory == newRoot)
    }
}
