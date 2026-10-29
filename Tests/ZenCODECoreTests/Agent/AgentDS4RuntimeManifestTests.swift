import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct AgentDS4RuntimeManifestTests {
    @Test
    func v13ManifestDecodesWithoutDS4Runtime() throws {
        let providerID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
        let data = Data(
            """
            {
              "version": 13,
              "providers": [
                {
                  "id": "\(providerID)",
                  "name": "Legacy provider",
                  "baseURL": "https://example.invalid/v1",
                  "chatEndpoint": "chat_completions"
                }
              ],
              "models": [
                {
                  "id": "legacy-model",
                  "kind": "remoteAPI",
                  "modelID": "legacy-model",
                  "providerID": "\(providerID)"
                }
              ]
            }
            """.utf8
        )

        let manifest = try JSONDecoder().decode(AgentSettingsManifest.self, from: data)
        #expect(manifest.version == 13)
        #expect(manifest.providers.count == 1)
        #expect(manifest.providers[0].ds4Runtime == nil)
        #expect(manifest.models[0].ds4Runtime == nil)
        #expect(manifest.models[0].provider?.ds4Runtime == nil)
    }

    @Test
    func v14RuntimeRoundTripsAndExcludesTransientProcessFields() throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: root) }
        let modelURL = root.appendingPathComponent("models/deepseek-v4.gguf")
        try fileManager.createDirectory(
            at: modelURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("model".utf8).write(to: modelURL)

        let runtime = try AgentDS4RuntimeManifest(
            rootDirectory: root.appendingPathComponent(".").path,
            modelRelativePath: "models/./deepseek-v4.gguf",
            backend: .metal,
            contextWindow: 131_072,
            ssdStreaming: true,
            ssdStreamingCacheExperts: 8,
            ssdStreamingCacheBytes: 4_000_000_000,
            ssdStreamingPreloadExperts: 2,
            ssdStreamingCold: true,
            mtp: true,
            power: 37,
            fileManager: fileManager
        )
        let provider = AgentRemoteProvider(
            name: "DS4 placeholder",
            baseURL: "http://127.0.0.1:8080/v1",
            modelID: "deepseek-v4",
            chatEndpoint: .chatCompletions,
            providerProfileID: .ds4,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: runtime
        )
        #expect(provider.id == "ds4")
        let model = AgentSettingsModelManifest(
            id: "ds4-model",
            kind: .remoteAPI,
            modelID: "deepseek-v4",
            providerID: provider.id,
            provider: provider
        )
        let manifest = AgentSettingsManifest(
            providers: [AgentSettingsProviderManifest(provider: provider)],
            models: [model],
            selectedModelID: model.id
        )

        let encoded = try JSONEncoder().encode(manifest)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(json.contains("\"version\":\(AgentSettingsManifest.currentVersion)"))
        #expect(AgentSettingsManifest.currentVersion == 15)
        #expect(json.contains("\"ds4Runtime\""))
        #expect(json.contains("\"mtp\":true"))
        #expect(json.contains("\"power\":37"))
        #expect(!json.localizedCaseInsensitiveContains("pid"))
        #expect(!json.localizedCaseInsensitiveContains("port"))
        #expect(!json.localizedCaseInsensitiveContains("hardware"))

        let decoded = try JSONDecoder().decode(AgentSettingsManifest.self, from: encoded)
        let decodedRuntime = try #require(decoded.providers.first?.ds4Runtime)
        #expect(decodedRuntime == runtime)
        #expect(decoded.models.first?.ds4Runtime == runtime)
        #expect(decoded.models.first?.provider?.ds4Runtime == runtime)
        #expect(try decodedRuntime.requiredModelURL(fileManager: fileManager) == modelURL)

        let providerManifest = try #require(decoded.providers.first)
        #expect(providerManifest.remoteProvider(modelID: "deepseek-v4").ds4Runtime == runtime)
        let selection = AgentModelSelection(
            providerKind: .remoteAPI,
            modelID: "deepseek-v4",
            remoteProvider: providerManifest.remoteProvider(modelID: "deepseek-v4"),
            apiKey: nil,
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingOptions: nil,
            thinkingSelection: nil
        )
        #expect(selection.ds4Runtime == runtime)
    }

    @Test
    func legacyRuntimeDefaultsNewTuningFields() throws {
        let data = Data(
            """
            {
              "rootDirectory": "/tmp",
              "backend": "metal",
              "contextWindow": 65536,
              "batchedSessions": false,
              "ssdStreaming": false,
              "ssdStreamingCold": false
            }
            """.utf8
        )

        let runtime = try JSONDecoder().decode(AgentDS4RuntimeManifest.self, from: data)
        #expect(runtime.contextWindow == 65_536)
        #expect(!runtime.mtp)
        #expect(runtime.power == 100)
        #expect(runtime.visionRelativePath == nil)
        #expect(runtime.mtpRelativePath == nil)
        #expect(runtime.steeringRelativePath == nil)
        #expect(!runtime.dspark)
        #expect(runtime.mtpDraftTokens == nil)
        #expect(runtime.mtpMargin == nil)
        #expect(!runtime.quality)
        #expect(runtime.threads == nil)
        #expect(runtime.prefillChunk == nil)
        #expect(!runtime.warmWeights)
        #expect(runtime.steeringFFN == nil)
        #expect(runtime.steeringAttn == nil)
        #expect(runtime.cudaArch == nil)
        #expect(runtime.rocmArch == nil)
        #expect(runtime.engineSessions == 2)
        #expect(runtime.extraEngineArguments.isEmpty)
    }

    @Test
    func batchedSessionsIsIgnoredWhenDecodingAndNeverWritten() throws {
        let data = Data(
            """
            {
              "rootDirectory": "/tmp",
              "batchedSessions": true,
              "mtp": true
            }
            """.utf8
        )

        let runtime = try JSONDecoder().decode(AgentDS4RuntimeManifest.self, from: data)
        #expect(runtime.mtp)
        let json = try #require(String(data: JSONEncoder().encode(runtime), encoding: .utf8))
        #expect(!json.contains("batchedSessions"))
    }

    @Test
    func extendedRuntimeRoundTripsAndOmitsAbsentOptionals() throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory(fileManager: fileManager)
        defer { try? fileManager.removeItem(at: root) }
        try writeFile("gguf/model.gguf", in: root, fileManager: fileManager)
        try writeFile("gguf/vision.gguf", in: root, fileManager: fileManager)
        try writeFile("gguf/mtp.gguf", in: root, fileManager: fileManager)
        try writeFile("dir-steering/out/verbosity.f32", in: root, fileManager: fileManager)

        let runtime = try AgentDS4RuntimeManifest(
            rootDirectory: root.path,
            modelRelativePath: "gguf/model.gguf",
            backend: .cuda,
            mtp: true,
            visionRelativePath: "gguf/./vision.gguf",
            mtpRelativePath: "gguf/mtp.gguf",
            steeringRelativePath: "dir-steering/out/verbosity.f32",
            dspark: true,
            mtpDraftTokens: 4,
            mtpMargin: 2.5,
            quality: true,
            threads: 12,
            prefillChunk: 512,
            warmWeights: true,
            steeringFFN: 1.5,
            steeringAttn: -0.25,
            cudaArch: "sm_120",
            rocmArch: "gfx1151",
            engineSessions: 4,
            extraEngineArguments: ["--gpu-devices", "0,1"],
            fileManager: fileManager
        )
        #expect(runtime.visionRelativePath == "gguf/vision.gguf")

        let encoded = try JSONEncoder().encode(runtime)
        let json = try #require(String(data: encoded, encoding: .utf8))
        for key in [
            "visionRelativePath", "mtpRelativePath", "steeringRelativePath", "dspark",
            "mtpDraftTokens", "mtpMargin", "quality", "threads", "prefillChunk",
            "warmWeights", "steeringFFN", "steeringAttn", "cudaArch", "rocmArch",
            "engineSessions", "extraEngineArguments"
        ] {
            #expect(json.contains("\"\(key)\""), "missing \(key)")
        }
        let decoded = try JSONDecoder().decode(AgentDS4RuntimeManifest.self, from: encoded)
        #expect(decoded == runtime)
        #expect(try decoded.resolvedVisionURL(fileManager: fileManager)?.lastPathComponent == "vision.gguf")
        #expect(try decoded.resolvedMTPURL(fileManager: fileManager)?.lastPathComponent == "mtp.gguf")
        #expect(try decoded.resolvedSteeringURL(fileManager: fileManager)?.lastPathComponent == "verbosity.f32")

        let minimal = try AgentDS4RuntimeManifest(rootDirectory: root.path, fileManager: fileManager)
        let minimalJSON = try #require(String(data: JSONEncoder().encode(minimal), encoding: .utf8))
        for key in [
            "visionRelativePath", "mtpRelativePath", "steeringRelativePath", "mtpDraftTokens",
            "mtpMargin", "threads", "prefillChunk", "steeringFFN", "steeringAttn", "cudaArch",
            "rocmArch", "extraEngineArguments", "batchedSessions"
        ] {
            #expect(!minimalJSON.contains("\"\(key)\""), "unexpected \(key)")
        }
        #expect(try minimal.resolvedVisionURL(fileManager: fileManager) == nil)
        #expect(try minimal.resolvedMTPURL(fileManager: fileManager) == nil)
        #expect(try minimal.resolvedSteeringURL(fileManager: fileManager) == nil)
        #expect(minimal.engineSessions == 2)
    }

    @Test
    func blankArchitecturesAreStoredAsNil() throws {
        let runtime = try AgentDS4RuntimeManifest(
            rootDirectory: "/tmp",
            cudaArch: "  ",
            rocmArch: " gfx1100 "
        )
        #expect(runtime.cudaArch == nil)
        #expect(runtime.rocmArch == "gfx1100")
    }

    @Test
    func contextAndPowerAreValidatedAgainstUpstreamRanges() {
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidContextWindow(0)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", contextWindow: 0)
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidContextWindow(1_048_577)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", contextWindow: 1_048_577)
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidPower(0)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", power: 0)
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidPower(101)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", power: 101)
        }
    }

    @Test
    func engineOptionsAreValidatedAgainstShimRanges() {
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidMTPDraftTokens(0)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", mtpDraftTokens: 0)
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidMTPDraftTokens(17)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", mtpDraftTokens: 17)
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidMTPMargin(-0.5)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", mtpMargin: -0.5)
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidMTPMargin(1000.5)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", mtpMargin: 1000.5)
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidThreads(0)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", threads: 0)
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidPrefillChunk(-1)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", prefillChunk: -1)
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidSteeringFFN(100.5)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", steeringFFN: 100.5)
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidSteeringAttn(-101)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", steeringAttn: -101)
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidEngineSessions(0)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", engineSessions: 0)
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidEngineSessions(9)) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", engineSessions: 9)
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidArchitecture(option: "cudaArch", value: "sm 120")) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", cudaArch: "sm 120")
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidArchitecture(option: "rocmArch", value: "gfx;rm")) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", rocmArch: "gfx;rm")
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidEngineArgument("")) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", extraEngineArguments: [""])
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidEngineArgument("--a\nb")) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", extraEngineArguments: ["--a\nb"])
        }
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidEngineArgument("--a\0b")) {
            try AgentDS4RuntimeManifest(rootDirectory: "/tmp", extraEngineArguments: ["--a\0b"])
        }

        // Boundary values are accepted.
        #expect(throws: Never.self) {
            try AgentDS4RuntimeManifest(
                rootDirectory: "/tmp",
                mtpDraftTokens: 16,
                mtpMargin: 1000,
                threads: 1,
                prefillChunk: 1,
                steeringFFN: -100,
                steeringAttn: 100,
                engineSessions: 8
            )
        }
    }

    @Test
    func invalidEngineOptionsAreRejectedWhenDecoding() {
        let data = Data(
            """
            { "rootDirectory": "/tmp", "engineSessions": 12 }
            """.utf8
        )
        #expect(throws: AgentDS4RuntimeConfigurationError.invalidEngineSessions(12)) {
            try JSONDecoder().decode(AgentDS4RuntimeManifest.self, from: data)
        }
    }

    @Test
    func auxiliaryPathsMustStayBelowTheRoot() throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory(fileManager: fileManager)
        let outside = try makeTemporaryDirectory(fileManager: fileManager)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }
        let outsideFile = outside.appendingPathComponent("outside.gguf")
        try Data("outside".utf8).write(to: outsideFile)
        try fileManager.createSymbolicLink(
            at: root.appendingPathComponent("linked.gguf"),
            withDestinationURL: outsideFile
        )
        try fileManager.createDirectory(
            at: root.appendingPathComponent("folder.gguf"),
            withIntermediateDirectories: true
        )

        func isAuxiliaryError(_ error: any Error, option: String) -> Bool {
            guard case let .auxiliaryFileInvalid(failedOption, _)? = error as? AgentDS4PathValidationError else {
                return false
            }
            return failedOption == option
        }

        // Traversal and absolute paths are rejected at construction time.
        #expect {
            try AgentDS4RuntimeManifest(
                rootDirectory: root.path,
                visionRelativePath: "../outside.gguf",
                fileManager: fileManager
            )
        } throws: { isAuxiliaryError($0, option: "vision") }
        #expect {
            try AgentDS4RuntimeManifest(
                rootDirectory: root.path,
                mtpRelativePath: outsideFile.path,
                fileManager: fileManager
            )
        } throws: { isAuxiliaryError($0, option: "MTP") }
        #expect {
            try AgentDS4RuntimeManifest(
                rootDirectory: root.path,
                steeringRelativePath: "a/../../outside.f32",
                fileManager: fileManager
            )
        } throws: { isAuxiliaryError($0, option: "steering") }
        #expect {
            try AgentDS4RuntimeManifest(
                rootDirectory: root.path,
                visionRelativePath: "  ",
                fileManager: fileManager
            )
        } throws: { isAuxiliaryError($0, option: "vision") }
        // A symbolic link is rejected even before the file is resolved.
        #expect {
            try AgentDS4RuntimeManifest(
                rootDirectory: root.path,
                mtpRelativePath: "linked.gguf",
                fileManager: fileManager
            )
        } throws: { isAuxiliaryError($0, option: "MTP") }

        // A missing file is accepted at construction time but not when resolved;
        // an existing directory is rejected right away.
        #expect {
            try AgentDS4RuntimeManifest(
                rootDirectory: root.path,
                mtpRelativePath: "folder.gguf",
                fileManager: fileManager
            )
        } throws: { isAuxiliaryError($0, option: "MTP") }
        let runtime = try AgentDS4RuntimeManifest(
            rootDirectory: root.path,
            visionRelativePath: "missing.gguf",
            fileManager: fileManager
        )
        #expect {
            try runtime.resolvedVisionURL(fileManager: fileManager)
        } throws: { isAuxiliaryError($0, option: "vision") }

        // A persisted escape is rejected when decoding too.
        let data = Data(
            """
            { "rootDirectory": "\(root.path)", "steeringRelativePath": "../x.f32" }
            """.utf8
        )
        #expect {
            try JSONDecoder().decode(AgentDS4RuntimeManifest.self, from: data)
        } throws: { isAuxiliaryError($0, option: "steering") }
    }

    @Test
    func pathGuardRejectsRelativeTraversalAndSymlinkModels() throws {
        let fileManager = FileManager.default
        let root = try makeTemporaryDirectory(fileManager: fileManager)
        let outside = try makeTemporaryDirectory(fileManager: fileManager)
        defer {
            try? fileManager.removeItem(at: root)
            try? fileManager.removeItem(at: outside)
        }
        let outsideModel = outside.appendingPathComponent("outside.gguf")
        try Data("outside".utf8).write(to: outsideModel)
        let symlink = root.appendingPathComponent("model.gguf")
        try fileManager.createSymbolicLink(at: symlink, withDestinationURL: outsideModel)

        #expect(throws: AgentDS4PathValidationError.self) {
            try AgentDS4PathGuard.canonicalRootDirectory("relative/root")
        }
        #expect(throws: AgentDS4PathValidationError.self) {
            try AgentDS4PathGuard.normalizedModelRelativePath("../outside.gguf")
        }
        #expect(throws: AgentDS4PathValidationError.self) {
            try AgentDS4PathGuard.resolveModelURL(
                rootDirectory: root.path,
                modelRelativePath: "model.gguf",
                fileManager: fileManager
            )
        }
    }

    private func writeFile(
        _ relativePath: String,
        in root: URL,
        fileManager: FileManager
    ) throws {
        let url = root.appendingPathComponent(relativePath)
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("data".utf8).write(to: url)
    }

    private func makeTemporaryDirectory(fileManager: FileManager) throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("zencode-ds4-")
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
