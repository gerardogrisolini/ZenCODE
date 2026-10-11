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
            batchedSessions: true,
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
            providerProfileID: .custom,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication,
            ds4Runtime: runtime
        )
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
        #expect(json.contains("\"version\":14"))
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

    private func makeTemporaryDirectory(fileManager: FileManager) throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("zencode-ds4-")
            .appendingPathComponent(UUID().uuidString)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
