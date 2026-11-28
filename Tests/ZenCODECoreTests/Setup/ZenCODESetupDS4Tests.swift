//
//  ZenCODESetupDS4Tests.swift
//  ZenCODECoreTests
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore
@testable import ZenCODERuntime

final class SetupLineCollector: Sendable {
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
final class FakeEngineBuilder: DS4EngineBuilding {
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

/// Seam of the "DS4 models" menu: answers with the scripted choices in order
/// and records what each visit showed. Once the script ends it answers Esc.
final class ScriptedDS4ModelMenu {
    private var choices: [DS4SetupModelMenuChoice]
    /// The ids of the models shown at each visit.
    private(set) var shown: [[String]] = []
    /// Whether Add models was offered at each visit.
    private(set) var offeredAdd: [Bool] = []

    init(_ choices: [DS4SetupModelMenuChoice]) {
        self.choices = choices
    }

    func select(
        _ models: [AgentSettingsModelManifest],
        _ canAdd: Bool
    ) throws -> DS4SetupModelMenuChoice {
        shown.append(models.map(\.id))
        offeredAdd.append(canAdd)
        guard !choices.isEmpty else {
            throw ZenCODESetupError.cancelled
        }
        return choices.removeFirst()
    }
}

@Suite("ZenCODE setup DS4")
struct ZenCODESetupDS4Tests {
    static let qwenPath = "gguf/Qwen3.8-Flash-Next-Q2.gguf"
    static let customPath = "gguf/DeepSeek-V4.1-Flash-Custom-IQ3_XXS.gguf"
    private static let ds41Q2Path = "gguf/DeepSeek-V4.1-Flash-1017-IQ2_XXS-Q2_K-imatrix.gguf"
    static let visionPath = "gguf/vision-projector.gguf"
    static let mtpPath = "gguf/mtp-support.gguf"
    static let steeringPath = "dir-steering/out/verbosity.f32"

    /// Keeps every saved optional file (none for a model never configured).
    static var keepAuxiliary: DS4SetupAuxiliaryFileSelector {
        { _, _, _, current in current }
    }

    /// Engine seam that never starts a process, never asks the terminal and
    /// keeps the library state inside the fixture.
    static func engine(
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

    // MARK: - Thinking levels

    private static let deepSeek41Levels: [AgentThinkingSelection] = [
        .off, .minimal, .low, .medium, .high, .xhigh, .max
    ]
    private static let otherFamilyLevels: [AgentThinkingSelection] = [
        .off, .low, .medium, .high, .max
    ]

    @Test
    func newDeepSeekV41ModelsGetTheSevenThinkingLevelsWithHighDefault() async throws {
        let fixture = try Fixture.make(files: [Self.customPath, Self.ds41Q2Path])
        defer { fixture.remove() }

        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: nil,
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, _ in Set(candidates.map(\.relativePath)) },
                selectBackend: { _, backend in backend },
                selectAPIModelID: { _ in
                    Issue.record("API id must be inferred")
                    return "glm-5.2"
                },
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { _, tuning in tuning }
            ),
            engine: Self.engine(fixture)
        )

        let manifest = try #require(result)
        #expect(manifest.models.count == 2)
        for model in manifest.models {
            #expect(model.modelID == "deepseek-v4.1-flash")
            #expect(model.thinkingOptions == Self.deepSeek41Levels)
            #expect(model.defaultThinkingSelection == .high)
            #expect(model.supportsThinking)
            #expect(model.availableThinkingSelections == Self.deepSeek41Levels)
            #expect(model.resolvedDefaultThinkingSelection == .high)
        }
        try Self.expectThinkingSurvivesPersistence(manifest)
    }

    @Test
    func reconfigureKeepsTheSavedThinkingLevelsOfAModel() async throws {
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.ds41Q2Path, Self.customPath])
        defer { fixture.remove() }
        let qwen = try Self.savedDS4Model(
            id: "my-qwen",
            apiModelID: "qwen3.8-flash-next",
            path: Self.qwenPath,
            in: fixture,
            thinkingOptions: [.off, .medium, .ultra],
            defaultThinkingSelection: .medium
        )
        let deepSeek = try Self.savedDS4Model(
            id: "my-ds41",
            apiModelID: "deepseek-v4.1-flash",
            path: Self.ds41Q2Path,
            in: fixture,
            thinkingOptions: [.off, .enabled],
            defaultThinkingSelection: .enabled
        )

        let menu = ScriptedDS4ModelMenu([.add, .done])
        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: Self.savedDS4Manifest(models: [qwen, deepSeek]),
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { candidates, preselected in
                    // Only the GGUF that no model uses yet can be added.
                    #expect(candidates.map(\.relativePath) == [Self.customPath])
                    #expect(preselected.isEmpty)
                    return Set(candidates.map(\.relativePath))
                },
                selectModelMenu: menu.select,
                selectBackend: { _, backend in backend },
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { _, tuning in tuning }
            ),
            selectAction: { .reconfigure },
            engine: Self.engine(fixture)
        )

        #expect(menu.shown.count == 2)
        let updated = try #require(result)
        #expect(updated.models.count == 3)
        // The levels the user already has, even if they differ from the family's.
        let keptQwen = try #require(updated.models.first { $0.id == "my-qwen" })
        #expect(keptQwen.thinkingOptions == [.off, .medium, .ultra])
        #expect(keptQwen.defaultThinkingSelection == .medium)
        let keptDeepSeek = try #require(updated.models.first { $0.id == "my-ds41" })
        #expect(keptDeepSeek.thinkingOptions == [.off, .enabled])
        #expect(keptDeepSeek.defaultThinkingSelection == .enabled)
        // A GGUF added in the same run gets the levels of its family.
        let added = try #require(updated.models.first {
            $0.ds4Runtime?.modelRelativePath == Self.customPath
        })
        #expect(added.thinkingOptions == Self.deepSeek41Levels)
        #expect(added.defaultThinkingSelection == .high)
        try Self.expectThinkingSurvivesPersistence(updated)
    }

    @Test
    func reconfigureAssignsTheFamilyLevelsToSavedModelsWithoutThinking() async throws {
        let mysteryPath = "mystery.gguf"
        let fixture = try Fixture.make(files: [Self.qwenPath, Self.ds41Q2Path, mysteryPath])
        defer { fixture.remove() }
        let models = try [
            Self.savedDS4Model(
                id: "my-qwen",
                apiModelID: "qwen3.8-flash-next",
                path: Self.qwenPath,
                in: fixture,
                title: "My Qwen"
            ),
            // A default without levels is meaningless and must not survive.
            Self.savedDS4Model(
                id: "my-ds41",
                apiModelID: "deepseek-v4.1-flash",
                path: Self.ds41Q2Path,
                in: fixture,
                defaultThinkingSelection: .low
            ),
            // The API id comes from the saved model (served id, no question).
            Self.savedDS4Model(
                id: "my-mystery",
                apiModelID: "glm-5.3-flash",
                path: mysteryPath,
                in: fixture
            )
        ]
        #expect(models.allSatisfy { !$0.supportsThinking })

        // Done right away: the saved models are not asked anything, but they
        // still get the levels of their family.
        let menu = ScriptedDS4ModelMenu([.done])
        let result = try await ZenCODESetupRunner.configureDS4Runtime(
            existingManifest: Self.savedDS4Manifest(models: models),
            prompts: DS4SetupPrompts(
                promptFolder: { _ in fixture.root.path },
                selectFiles: { _, _ in
                    Issue.record("Nothing is added")
                    return nil
                },
                selectModelMenu: menu.select,
                selectBackend: { _, backend in
                    Issue.record("No model is configured")
                    return backend
                },
                selectAPIModelID: { _ in
                    Issue.record("The saved API id must be reused")
                    return "glm-5.2"
                },
                selectAuxiliaryFile: Self.keepAuxiliary,
                promptTuning: { _, tuning in tuning }
            ),
            selectAction: { .reconfigure },
            engine: Self.engine(fixture)
        )

        #expect(menu.shown == [["my-qwen", "my-ds41", "my-mystery"]])
        let updated = try #require(result)
        #expect(updated.models.count == 3)
        let qwen = try #require(updated.models.first { $0.id == "my-qwen" })
        #expect(qwen.title == "My Qwen")
        #expect(qwen.thinkingOptions == Self.otherFamilyLevels)
        #expect(qwen.defaultThinkingSelection == .high)
        let deepSeek = try #require(updated.models.first { $0.id == "my-ds41" })
        #expect(deepSeek.thinkingOptions == Self.deepSeek41Levels)
        #expect(deepSeek.defaultThinkingSelection == .high)
        let mystery = try #require(updated.models.first { $0.id == "my-mystery" })
        #expect(mystery.modelID == "glm-5.3-flash")
        #expect(mystery.thinkingOptions == Self.otherFamilyLevels)
        #expect(mystery.defaultThinkingSelection == .high)
        #expect(updated.models.allSatisfy { $0.supportsThinking })
        try Self.expectThinkingSurvivesPersistence(updated)
    }

    /// Persistence must keep the levels and the default of every model.
    private static func expectThinkingSurvivesPersistence(
        _ manifest: AgentSettingsManifest
    ) throws {
        let decoded = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: JSONEncoder().encode(manifest)
        )
        for model in manifest.models {
            let restored = try #require(decoded.models.first { $0.id == model.id })
            #expect(restored.thinkingOptions == model.thinkingOptions)
            #expect(restored.defaultThinkingSelection == model.defaultThinkingSelection)
            #expect(restored.supportsThinking == model.supportsThinking)
        }
    }

    /// A DS4 model as a previous setup saved it, for the GGUF at `path`.
    static func savedDS4Model(
        id: String,
        apiModelID: String,
        path: String,
        in fixture: Fixture,
        title: String? = nil,
        thinkingOptions: [AgentThinkingSelection]? = nil,
        defaultThinkingSelection: AgentThinkingSelection? = nil,
        runtime: AgentDS4RuntimeManifest? = nil
    ) throws -> AgentSettingsModelManifest {
        let runtime = try runtime ?? AgentDS4RuntimeManifest(
            rootDirectory: AgentDS4PathGuard.canonicalRootDirectory(fixture.root.path),
            modelRelativePath: path
        )
        return AgentSettingsModelManifest(
            id: id,
            kind: .remoteAPI,
            title: title,
            modelID: apiModelID,
            providerID: ZenCODESetupRunner.ds4SetupProviderID,
            thinkingOptions: thinkingOptions,
            defaultThinkingSelection: defaultThinkingSelection,
            ds4Runtime: runtime
        )
    }

    /// A manifest with the DS4 provider and the given saved DS4 models.
    static func savedDS4Manifest(
        models: [AgentSettingsModelManifest]
    ) -> AgentSettingsManifest {
        let provider = AgentSettingsProviderManifest(
            id: ZenCODESetupRunner.ds4SetupProviderID,
            name: ZenCODESetupRunner.ds4SetupProviderName,
            baseURL: ZenCODESetupRunner.ds4SetupProviderBaseURL,
            chatEndpoint: .chatCompletions,
            providerProfileID: .ds4,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: models.first?.ds4Runtime
        )
        return AgentSettingsManifest(
            providers: [provider],
            models: models,
            selectedModelID: models.first?.id
        )
    }

    struct Fixture {
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
