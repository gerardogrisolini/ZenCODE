import Foundation
import Testing
@testable import ZenCODECore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@Suite struct SubscriptionModelCatalogTests {
    private static let catalog = """
    {"models":[
      {"slug":"future-model","display_name":"Future model","visibility":"list","supported_in_api":false,
       "context_window":123456,"max_context_window":200000,"input_modalities":["text","image"],
       "supported_reasoning_levels":[{"effort":"low"},{"effort":"high"}],"default_reasoning_level":"high"},
      {"slug":"hidden","visibility":"hide"},
      {"slug":"too-new","visibility":"list","minimal_client_version":"99.0.0"}
    ]}
    """
    private func directory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    }
    private static func response(_ request: URLRequest, _ json: String, status: Int = 200) -> (Data, HTTPURLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
    private func client(_ directory: URL, json: String = Self.catalog) -> SubscriptionModelCatalogClient {
        SubscriptionModelCatalogClient(directory: directory, version: "v1.2.3-beta+build") { request in
            Self.response(request, json)
        }
    }

    @Test func chatGPTRequestAndMetadata() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = SubscriptionModelCatalogClient(directory: dir, version: "v1.2.3-beta+build") { request in
            #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/codex/models?client_version=1.2.3")
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret")
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "account-a")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            return Self.response(request, Self.catalog)
        }
        let result = try await client.load(provider: .chatGPT, accessToken: "fixture-secret", accountID: "account-a")
        // minimal_client_version is a Codex requirement, not comparable to ZenCODE's identity.
        #expect(result.models.map(\.id) == ["future-model", "too-new"])
        let model = try #require(result.models.first)
        #expect(model.id == "future-model")
        #expect(model.contextWindow == 123456)
        #expect(model.maxContextWindow == 200000)
        #expect(model.inputModalities == ["text", "image"])
        #expect(model.thinkingSupport?.availableSelections == [.low, .high])
        #expect(model.thinkingSupport?.defaultSelection == .high)
        #expect(!result.isCached)
    }

    @Test func lastGoodCacheAndAccountIsolation() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await client(dir).load(provider: .chatGPT, accessToken: "old-token", accountID: "account-a")
        let offline = SubscriptionModelCatalogClient(directory: dir, version: "1.2.3") { _ in throw URLError(.notConnectedToInternet) }
        let cached = try await offline.load(provider: .chatGPT, accessToken: "rotated-token", accountID: "account-a")
        #expect(cached.isCached)
        #expect(cached.models.first?.id == "future-model")
        await #expect(throws: SubscriptionModelCatalogClient.CatalogError.self) {
            try await offline.load(provider: .chatGPT, accessToken: "old-token", accountID: "account-b")
        }
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        let persisted = try String(contentsOf: #require(files.first), encoding: .utf8)
        for secret in ["old-token", "rotated-token", "account-a", "Authorization"] {
            #expect(!persisted.contains(secret))
            #expect(!files[0].lastPathComponent.contains(secret))
        }
        let permissions = try FileManager.default.attributesOfItem(atPath: files[0].path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test(arguments: [401, 403]) func authenticationRejectionDoesNotUseCache(status: Int) async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await client(dir).load(provider: .chatGPT, accessToken: "token", accountID: "account-a")
        let denied = SubscriptionModelCatalogClient(directory: dir, version: "1.2.3") { request in
            Self.response(request, "do not expose response bodies", status: status)
        }
        do {
            _ = try await denied.load(provider: .chatGPT, accessToken: "token", accountID: "account-a")
            Issue.record("Expected authentication rejection")
        } catch SubscriptionModelCatalogClient.CatalogError.http(let actual) {
            #expect(actual == status)
        }
    }

    @Test func invalidResponsePreservesCacheAndEmptyReplacesIt() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await client(dir).load(provider: .chatGPT, accessToken: "token", accountID: "a")
        let failed = try await client(dir, json: "not json").load(provider: .chatGPT, accessToken: "token", accountID: "a")
        #expect(failed.isCached)
        let empty = try await client(dir, json: "{\"models\":[]}").load(provider: .chatGPT, accessToken: "token", accountID: "a")
        #expect(empty.models.isEmpty)
        #expect(!empty.isCached)
        let fallback = try await client(dir, json: "{}").load(provider: .chatGPT, accessToken: "token", accountID: "a")
        #expect(fallback.models.isEmpty)
        #expect(fallback.isCached)
    }

    @Test func anthropicPaginationBearerAndConservativeMetadata() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let client = SubscriptionModelCatalogClient(directory: dir) { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
            #expect(request.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
            #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
            #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
            if request.url?.query == nil {
                #expect(request.url?.absoluteString == "https://api.anthropic.com/v1/models")
                return Self.response(request, """
                {"data":[{"id":"future-claude","display_name":"Future","max_input_tokens":300000,"max_tokens":150000,"capabilities":{"thinking":{"supported":true}}}],"has_more":true,"last_id":"future-claude"}
                """)
            }
            #expect(request.url?.query == "after_id=future-claude")
            return Self.response(request, "{\"data\":[{\"id\":\"other\"}],\"has_more\":false,\"last_id\":\"other\"}")
        }
        let result = try await client.load(provider: .anthropic, accessToken: "fixture")
        #expect(result.models.count == 2)
        #expect(result.models[0].contextWindow == 300000)
        #expect(result.models[0].maxOutputTokens == 150000)
        #expect(result.models[0].thinkingSupport == nil)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func noIdentityNoPersistentReuseAndCancellation() async throws {
        let dir = directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await client(dir).load(provider: .chatGPT, accessToken: "token")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        let cancelled = SubscriptionModelCatalogClient(directory: dir) { _ in throw URLError(.cancelled) }
        await #expect(throws: CancellationError.self) {
            try await cancelled.load(provider: .chatGPT, accessToken: "token")
        }
        await #expect(throws: SubscriptionModelCatalogClient.CatalogError.self) {
            try await client(dir, json: "{}").load(provider: .chatGPT, accessToken: "token")
        }
    }

    @Test func unsafeCachePathIsNotFollowed() async throws {
        let dir = directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("untouched")
        try Data("unchanged".utf8).write(to: target)
        let client = client(dir)
        let scope = try #require(SubscriptionModelCatalogClient.accountScope("a"))
        try FileManager.default.createSymbolicLink(at: client.cacheURL(provider: .chatGPT, scope: scope), withDestinationURL: target)
        let result = try await client.load(provider: .chatGPT, accessToken: "token", accountID: "a")
        #expect(result.cacheWriteFailed)
        #expect(try String(contentsOf: target, encoding: .utf8) == "unchanged")
    }

    @Test func savedCandidatesAndManifestMetadata() throws {
        let saved = AgentSettingsModelManifestFactory.remoteAPIModel(manifestID: "persisted-custom-id", title: "Saved",
            modelID: "saved-model", providerID: AgentRemoteProvider.chatGPTSubscriptionProviderID,
            providerName: "ChatGPT", baseURL: AgentRemoteProvider.chatGPTSubscriptionBaseURL,
            chatEndpoint: .responses, configuredContextWindowLimit: 77777,
            generationParameterOverrides: nil, thinkingSupport: .generic)
        let merged = ZenCODESetupRunner.mergeSubscriptionCandidates([], existingModels: [saved])
        #expect(merged.map(\.manifestID) == ["persisted-custom-id"])
        #expect(ZenCODESetupRunner.subscriptionModelSelectionDefaultIndexes(candidates: merged, defaultModels: [saved]) == [0])
        let candidate = ZenCODESetupRunner.SubscriptionModelCandidate(manifestID: "claude:new-model", modelID: "new-model",
            title: "New", detail: "", contextWindowTokenLimit: 300000, thinkingSupport: nil,
            maxOutputTokens: 150000, isDiscovered: true)
        let manifest = ZenCODESetupRunner.subscriptionModelManifest(candidate: candidate,
            providerID: AgentRemoteProvider.anthropicSubscriptionProviderID, providerName: "Claude",
            baseURL: AgentRemoteProvider.anthropicSubscriptionBaseURL, chatEndpoint: .responses)
        #expect(manifest.id == candidate.manifestID)
        #expect(manifest.configuredContextWindowLimit == 300000)
        #expect(manifest.generationParameterOverrides?.maxTokens == 150000)
        #expect(manifest.thinkingOptions == [.off])
        #expect(manifest.defaultThinkingSelection == .off)
    }
}
