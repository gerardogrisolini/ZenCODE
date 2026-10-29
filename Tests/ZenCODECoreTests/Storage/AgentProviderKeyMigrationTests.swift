//
//  AgentProviderKeyMigrationTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

/// Characterization of the settings v14 -> v15 migration from provider UUIDs
/// to stable provider keys. Every test works in its own temporary directory
/// (named with a UUID) and passes it explicitly: no process-wide state.
@Suite
struct AgentProviderKeyMigrationTests {
    // MARK: - Fixtures

    private static let openRouterUUID = "6f1c2a40-1b2c-4d5e-8f90-a1b2c3d4e5f6"
    private static let zaiCodingPlanUUID = "7a2b3c4d-5e6f-4a1b-9c2d-3e4f5a6b7c8d"
    private static let staleUUID = "9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
    private static let chatGPTUUID = "00000000-0000-0000-0000-000000000003"
    private static let claudeUUID = "00000000-0000-0000-0000-000000000004"
    private static let ds4UUID = "00000000-0000-0000-0000-000000000005"

    private static func legacyModelID(_ providerUUID: String, _ modelID: String) -> String {
        "remoteapi:\(providerUUID):\(modelID)"
    }

    /// A v14 `settings.json` as written by the previous release: provider ids
    /// are uppercase UUIDs (UUID encoding), model ids embed the lowercase UUID.
    private static func legacySettingsData(ds4Root: URL) throws -> Data {
        let ds4Runtime = try AgentDS4RuntimeManifest(
            rootDirectory: ds4Root.path,
            modelRelativePath: "deepseek-v4-flash.gguf",
            backend: .metal
        )
        let object: [String: Any] = [
            "version": 14,
            "providers": [
                [
                    "id": openRouterUUID.uppercased(),
                    "name": "OpenRouter",
                    "baseURL": "https://openrouter.ai/api/v1",
                    "chatEndpoint": "chat_completions",
                    "providerProfileID": "openrouter",
                    "protocolProfileID": "openai.chat-completions",
                    "authPolicy": "api_key_required"
                ],
                [
                    "id": chatGPTUUID,
                    "name": "ChatGPT Subscription",
                    "baseURL": "chatgpt://subscription",
                    "chatEndpoint": "responses",
                    "providerProfileID": "openai",
                    "protocolProfileID": "openai.chatgpt-subscription",
                    "authPolicy": "chatgpt_subscription"
                ],
                [
                    "id": claudeUUID,
                    "name": "Claude Subscription",
                    "baseURL": "anthropic://subscription",
                    "chatEndpoint": "responses",
                    "providerProfileID": "anthropic",
                    "protocolProfileID": "anthropic.claude-subscription",
                    "authPolicy": "anthropic_subscription"
                ],
                [
                    "id": ds4UUID,
                    "name": "DS4 (local)",
                    "baseURL": "http://127.0.0.1:8000/v1",
                    "chatEndpoint": "chat_completions",
                    "providerProfileID": "custom",
                    "protocolProfileID": "openai.chat-completions",
                    "authPolicy": "none",
                    "ds4Runtime": try jsonObject(ds4Runtime)
                ],
                [
                    "id": zaiCodingPlanUUID.uppercased(),
                    "name": "Z.ai Coding Plan",
                    "baseURL": "https://api.z.ai/api/coding/paas/v4",
                    "chatEndpoint": "chat_completions",
                    "providerProfileID": "zai",
                    "protocolProfileID": "zai.coding-plan",
                    "authPolicy": "api_key_required"
                ]
            ],
            "models": [
                [
                    "id": legacyModelID(openRouterUUID, "moonshotai/kimi-k3.1-pro"),
                    "kind": "remoteAPI",
                    "llmID": legacyModelID(openRouterUUID, "moonshotai/kimi-k3.1-pro"),
                    "modelID": "moonshotai/kimi-k3.1-pro",
                    "providerID": openRouterUUID.uppercased()
                ],
                [
                    "id": legacyModelID(openRouterUUID, "deepseek/deepseek-r1:free"),
                    "kind": "remoteAPI",
                    "llmID": legacyModelID(openRouterUUID, "deepseek/deepseek-r1:free"),
                    "modelID": "deepseek/deepseek-r1:free",
                    "providerID": openRouterUUID.uppercased()
                ],
                [
                    "id": "chatgpt:gpt-5",
                    "kind": "remoteAPI",
                    "llmID": "chatgpt:gpt-5",
                    "modelID": "gpt-5",
                    "providerID": chatGPTUUID
                ],
                [
                    "id": "claude:claude-sonnet-4",
                    "kind": "remoteAPI",
                    "llmID": "claude:claude-sonnet-4",
                    "modelID": "claude-sonnet-4",
                    "providerID": claudeUUID
                ],
                [
                    "id": "ds4:deepseek-v4-flash",
                    "kind": "remoteAPI",
                    "modelID": "deepseek-v4-flash",
                    "providerID": ds4UUID,
                    "ds4Runtime": try jsonObject(ds4Runtime)
                ],
                [
                    "id": legacyModelID(zaiCodingPlanUUID, "glm-5.2"),
                    "kind": "remoteAPI",
                    "llmID": legacyModelID(zaiCodingPlanUUID, "glm-5.2"),
                    "modelID": "glm-5.2",
                    "providerID": zaiCodingPlanUUID.uppercased()
                ]
            ],
            "selected": [
                "modelID": legacyModelID(openRouterUUID, "moonshotai/kimi-k3.1-pro"),
                "thinking": "high"
            ],
            "remoteAPIKeysByProviderID": [
                openRouterUUID: "sk-or-test",
                zaiCodingPlanUUID: "sk-zai-test",
                staleUUID: "sk-stale-test"
            ],
            "responseLanguage": "it",
            "memoryEmbedding": [
                "endpoint": "https://openrouter.ai/api/v1/embeddings",
                "model": "qwen/qwen3-embedding-4b",
                "providerID": openRouterUUID.uppercased()
            ]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func legacyAgentsData() throws -> Data {
        let kimi = legacyModelID(openRouterUUID, "moonshotai/kimi-k3.1-pro")
        let glm = legacyModelID(zaiCodingPlanUUID, "glm-5.2")
        let object: [String: Any] = [
            "version": 1,
            "agents": [
                [
                    "id": "developer",
                    "name": "Developer",
                    "role": "developer",
                    "readOnly": false,
                    "tools": ["files", "search"],
                    "skills": [],
                    "modelBindings": [
                        ["id": kimi, "modelID": kimi, "modelProvider": "OpenRouter", "capability": 7],
                        ["id": "fast", "modelID": glm, "thinkingSelection": "high", "capability": 5],
                        ["id": "chatgpt:gpt-5", "modelID": "chatgpt:gpt-5", "capability": 8],
                        ["id": "stale", "modelID": legacyModelID(staleUUID, "gone"), "capability": 2]
                    ],
                    "defaultModelBindingID": kimi
                ],
                [
                    // A profile without a role fails strict decoding, but its
                    // references are migrated too (JSON-level edit).
                    "id": "legacy-custom",
                    "name": "Legacy custom",
                    "tools": [],
                    "skills": [],
                    "modelID": glm,
                    "defaultModelID": glm
                ]
            ]
        ]
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    private static func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-provider-key-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.standardizedFileURL
    }

    private static func object(_ data: Data) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - settings.json

    @Test
    func legacyV14SettingsMigrateToStableProviderKeys() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try #require(
            try AgentProviderKeyMigration.migratedData(
                settingsData: Self.legacySettingsData(ds4Root: root),
                agentsData: nil
            )
        )
        let manifest = try JSONDecoder().decode(AgentSettingsManifest.self, from: result.settingsData)

        #expect(try Self.object(result.settingsData)["version"] as? Int == 15)
        #expect(manifest.version == AgentSettingsManifest.currentVersion)
        #expect(Set(manifest.providers.map(\.id)) == ["openrouter", "chatgpt", "claude", "ds4", "zai-coding-plan"])

        let ds4 = try #require(manifest.providers.first { $0.id == "ds4" })
        #expect(ds4.providerProfileID == .ds4)
        #expect(ds4.protocolProfileID == .openAIChatCompletions)
        #expect(ds4.authPolicy == .noAuthentication)
        #expect(ds4.ds4Runtime != nil)
        let chatGPT = try #require(manifest.providers.first { $0.id == "chatgpt" })
        #expect(chatGPT.protocolProfileID == .openAIChatGPTSubscription)
        let claude = try #require(manifest.providers.first { $0.id == "claude" })
        #expect(claude.protocolProfileID == .anthropicClaudeSubscription)
        let codingPlan = try #require(manifest.providers.first { $0.id == "zai-coding-plan" })
        #expect(codingPlan.providerProfileID == .zAI)
        #expect(codingPlan.protocolProfileID == .zaiCodingPlan)

        #expect(Set(manifest.models.map(\.id)) == [
            "openrouter:moonshotai/kimi-k3.1-pro",
            "openrouter:deepseek/deepseek-r1:free",
            "chatgpt:gpt-5",
            "claude:claude-sonnet-4",
            "ds4:deepseek-v4-flash",
            "zai-coding-plan:glm-5.2"
        ])
        let kimi = try #require(manifest.models.first { $0.modelID == "moonshotai/kimi-k3.1-pro" })
        #expect(kimi.llmID == "openrouter:moonshotai/kimi-k3.1-pro")
        #expect(kimi.providerID == "openrouter")
        #expect(kimi.provider?.id == "openrouter")
        let ds4Model = try #require(manifest.models.first { $0.id == "ds4:deepseek-v4-flash" })
        #expect(ds4Model.providerID == "ds4")
        #expect(ds4Model.provider?.providerProfileID == .ds4)
        #expect(ds4Model.ds4Runtime != nil)
        #expect(manifest.models.first { $0.id == "chatgpt:gpt-5" }?.providerID == "chatgpt")
        #expect(manifest.models.first { $0.id == "claude:claude-sonnet-4" }?.providerID == "claude")

        #expect(manifest.selectedModelID == "openrouter:moonshotai/kimi-k3.1-pro")
        #expect(manifest.remoteAPIKeysByProviderID == [
            "openrouter": "sk-or-test",
            "zai-coding-plan": "sk-zai-test"
        ])
        #expect(manifest.apiKey(providerID: "openrouter") == "sk-or-test")
        #expect(manifest.memoryEmbedding?.providerID == "openrouter")
        #expect(manifest.memoryEmbedding?.model == "qwen/qwen3-embedding-4b")
        #expect(manifest.responseLanguage == "it")

        // No provider UUID survives anywhere in the persisted bytes.
        let text = try #require(String(data: result.settingsData, encoding: .utf8)).lowercased()
        for uuid in [Self.openRouterUUID, Self.zaiCodingPlanUUID, Self.staleUUID, Self.chatGPTUUID, Self.claudeUUID, Self.ds4UUID] {
            #expect(!text.contains(uuid))
        }
        #expect(!text.contains("remoteapi:"))
    }

    @Test
    func fixedSubscriptionUUIDWithoutProfilesMigratesToTheSubscriptionKey() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 12,
            "providers": [[
                "id": Self.chatGPTUUID.uppercased(),
                "name": "Renamed connection",
                "baseURL": "https://irrelevant.example/v1",
                "chatEndpoint": "chat_completions"
            ]],
            "models": [[
                "id": "chatgpt:gpt-5",
                "kind": "remoteAPI",
                "modelID": "gpt-5",
                "providerID": Self.chatGPTUUID.uppercased()
            ]]
        ] as [String: Any])

        let result = try #require(try AgentProviderKeyMigration.migratedData(settingsData: data, agentsData: nil))
        let manifest = try JSONDecoder().decode(AgentSettingsManifest.self, from: result.settingsData)

        let provider = try #require(manifest.providers.first)
        #expect(provider.id == "chatgpt")
        #expect(provider.protocolProfileID == .openAIChatGPTSubscription)
        #expect(provider.authPolicy == .chatGPTSubscription)
        #expect(manifest.models.map(\.providerID) == ["chatgpt"])
    }

    @Test
    func keyCollisionKeepsTheFirstProviderInPersistedOrderAndWarns() throws {
        let first = "11111111-2222-4333-8444-555555555555"
        let second = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        // Persisted order differs from title order on purpose: "Zeta" first.
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 14,
            "providers": [
                ["id": first, "name": "Zeta OpenRouter", "baseURL": "https://openrouter.ai/api/v1",
                 "chatEndpoint": "chat_completions", "providerProfileID": "openrouter",
                 "protocolProfileID": "openai.chat-completions", "authPolicy": "api_key_required"],
                ["id": second, "name": "Alpha OpenRouter", "baseURL": "https://openrouter.ai/api/v1",
                 "chatEndpoint": "chat_completions", "providerProfileID": "openrouter",
                 "protocolProfileID": "openai.chat-completions", "authPolicy": "api_key_required"]
            ],
            "models": [
                ["id": Self.legacyModelID(first, "kept-model"), "kind": "remoteAPI",
                 "modelID": "kept-model", "providerID": first],
                ["id": Self.legacyModelID(second, "dropped-model"), "kind": "remoteAPI",
                 "modelID": "dropped-model", "providerID": second]
            ],
            "selected": ["modelID": Self.legacyModelID(second, "dropped-model")],
            "remoteAPIKeysByProviderID": [first: "sk-kept", second: "sk-dropped"]
        ] as [String: Any])

        let result = try #require(try AgentProviderKeyMigration.migratedData(settingsData: data, agentsData: nil))
        let manifest = try JSONDecoder().decode(AgentSettingsManifest.self, from: result.settingsData)

        #expect(manifest.providers.map(\.id) == ["openrouter"])
        #expect(manifest.providers.first?.name == "Zeta OpenRouter")
        #expect(manifest.models.map(\.id) == ["openrouter:kept-model"])
        #expect(manifest.remoteAPIKeysByProviderID == ["openrouter": "sk-kept"])
        #expect(manifest.selectedModelID == nil)
        #expect(result.warnings.count == 1)
        #expect(result.warnings.first?.contains("'Alpha OpenRouter'") == true)
        #expect(result.warnings.first?.contains("'openrouter'") == true)
        #expect(!(String(data: result.settingsData, encoding: .utf8) ?? "").contains("sk-dropped"))
    }

    @Test
    func currentSettingsAreNeverTouched() throws {
        let current = AgentSettingsManifest(
            providers: [
                AgentSettingsProviderManifest(
                    name: "OpenRouter",
                    baseURL: "https://openrouter.ai/api/v1",
                    chatEndpoint: .chatCompletions
                )
            ],
            models: [
                AgentSettingsModelManifestFactory.remoteAPIModel(
                    title: nil,
                    modelID: "openrouter/auto",
                    providerID: "openrouter",
                    providerName: "OpenRouter",
                    baseURL: "https://openrouter.ai/api/v1",
                    chatEndpoint: .chatCompletions,
                    configuredContextWindowLimit: nil,
                    generationParameterOverrides: nil,
                    thinkingSupport: nil
                )
            ]
        )
        let data = try AgentSettingsManifestStore.encodedData(for: current)
        #expect(try AgentProviderKeyMigration.migratedData(settingsData: data, agentsData: Self.legacyAgentsData()) == nil)
        // Unsupported or unreadable files are left to the regular loader.
        #expect(try AgentProviderKeyMigration.migratedData(settingsData: Data("not json".utf8), agentsData: nil) == nil)
        let future = try JSONSerialization.data(withJSONObject: ["version": 99, "models": []] as [String: Any])
        #expect(try AgentProviderKeyMigration.migratedData(settingsData: future, agentsData: nil) == nil)
    }

    @Test
    func currentVersionWithLegacyProviderIDsSelfHeals() throws {
        // A legacy-decoded manifest saved as v15 after a failed migration.
        let legacy = "12345678-1234-4234-8234-123456789abc"
        let data = try JSONSerialization.data(withJSONObject: [
            "version": 15,
            "providers": [["id": legacy, "name": "DeepSeek", "baseURL": "https://api.deepseek.com/v1",
                           "chatEndpoint": "chat_completions"]],
            "models": [
                ["id": Self.legacyModelID(legacy, "deepseek-v4-flash"), "kind": "remoteAPI",
                 "modelID": "deepseek-v4-flash", "providerID": legacy],
                // Added by setup after the failed migration: the new id format
                // built on the not-yet-migrated provider id.
                ["id": "\(legacy):deepseek-v4-pro", "kind": "remoteAPI",
                 "llmID": "\(legacy):deepseek-v4-pro",
                 "modelID": "deepseek-v4-pro", "providerID": legacy]
            ],
            "remoteAPIKeysByProviderID": [legacy: "sk-deepseek"]
        ] as [String: Any])

        let result = try #require(try AgentProviderKeyMigration.migratedData(settingsData: data, agentsData: nil))
        let manifest = try JSONDecoder().decode(AgentSettingsManifest.self, from: result.settingsData)
        #expect(manifest.providers.map(\.id) == ["deepseek"])
        #expect(Set(manifest.models.map(\.id)) == ["deepseek:deepseek-v4-flash", "deepseek:deepseek-v4-pro"])
        #expect(manifest.models.first { $0.modelID == "deepseek-v4-pro" }?.llmID == "deepseek:deepseek-v4-pro")
        #expect(manifest.remoteAPIKeysByProviderID == ["deepseek": "sk-deepseek"])
    }

    // MARK: - agents.json

    @Test
    func agentsBindingsFollowTheMigratedModelIDs() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let result = try #require(
            try AgentProviderKeyMigration.migratedData(
                settingsData: Self.legacySettingsData(ds4Root: root),
                agentsData: Self.legacyAgentsData()
            )
        )
        let agentsData = try #require(result.agentsData)
        let agents = try #require(try Self.object(agentsData)["agents"] as? [[String: Any]])
        let developer = try #require(agents.first { $0["id"] as? String == "developer" })
        let bindings = try #require(developer["modelBindings"] as? [[String: Any]])

        #expect(bindings.map { $0["id"] as? String } == [
            "openrouter:moonshotai/kimi-k3.1-pro", "fast", "chatgpt:gpt-5", "stale"
        ])
        #expect(bindings.map { $0["modelID"] as? String } == [
            "openrouter:moonshotai/kimi-k3.1-pro",
            "zai-coding-plan:glm-5.2",
            "chatgpt:gpt-5",
            // No legacy provider owns this UUID: left for the next profile save.
            Self.legacyModelID(Self.staleUUID, "gone")
        ])
        #expect(developer["defaultModelBindingID"] as? String == "openrouter:moonshotai/kimi-k3.1-pro")
        // Everything else is preserved.
        #expect(bindings[1]["thinkingSelection"] as? String == "high")
        #expect(bindings[0]["modelProvider"] as? String == "OpenRouter")
        #expect(developer["tools"] as? [String] == ["files", "search"])

        let legacyCustom = try #require(agents.first { $0["id"] as? String == "legacy-custom" })
        #expect(legacyCustom["modelID"] as? String == "zai-coding-plan:glm-5.2")
        #expect(legacyCustom["defaultModelID"] as? String == "zai-coding-plan:glm-5.2")
        #expect(legacyCustom["role"] == nil)

        // The migrated bindings survive the profile reconciliation that runs
        // on every save (which drops bindings to unknown model ids).
        let settings = try JSONDecoder().decode(AgentSettingsManifest.self, from: result.settingsData)
        let profile = AgentProfile(
            id: "developer",
            name: "Developer",
            role: .developer,
            modelBindings: bindings.compactMap { binding in
                (binding["modelID"] as? String).map {
                    AgentModelBinding(id: binding["id"] as? String, modelID: $0)
                }
            },
            defaultModelBindingID: developer["defaultModelBindingID"] as? String
        )
        let reconciled = AgentProfileBindingReconciler.reconciledAgents([profile], models: settings.models)
        #expect(Set(reconciled[0].modelBindings.map(\.id)) == [
            "openrouter:moonshotai/kimi-k3.1-pro", "fast", "chatgpt:gpt-5"
        ])
        #expect(reconciled[0].defaultModelBindingID == "openrouter:moonshotai/kimi-k3.1-pro")
    }

    @Test
    func agentsWithoutLegacyReferencesAndUnreadableAgentsStayUntouched() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = try Self.legacySettingsData(ds4Root: root)

        let clean = try JSONSerialization.data(withJSONObject: [
            "version": 1,
            "agents": [["id": "developer", "name": "Developer", "role": "developer",
                        "modelBindings": [["id": "chatgpt:gpt-5", "modelID": "chatgpt:gpt-5"]]]]
        ] as [String: Any])
        let unchanged = try #require(try AgentProviderKeyMigration.migratedData(settingsData: settings, agentsData: clean))
        #expect(unchanged.agentsData == nil)
        #expect(unchanged.warnings.isEmpty)

        let unreadable = try #require(
            try AgentProviderKeyMigration.migratedData(settingsData: settings, agentsData: Data("[1, 2".utf8))
        )
        #expect(unreadable.agentsData == nil)
        #expect(unreadable.warnings.contains { $0.contains("agents.json") })
    }

    // MARK: - Files

    @Test
    func migrationPersistsBothFilesOnceAndIsIdempotent() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        let agentsURL = root.appendingPathComponent(AgentProfileStore.manifestFilename)
        try Self.legacySettingsData(ds4Root: root).write(to: settingsURL)
        try Self.legacyAgentsData().write(to: agentsURL)

        var warnings: [String] = []
        let report = try AgentProviderKeyMigration.migrateIfNeeded(
            supportDirectoryURL: root,
            warningSink: { warnings.append($0) }
        )
        #expect(report.didMigrate)
        #expect(report.migratedFilenames == ["settings.json", "agents.json"])
        #expect(warnings.isEmpty)

        let migratedSettings = try Data(contentsOf: settingsURL)
        let migratedAgents = try Data(contentsOf: agentsURL)
        let manifest = try AgentSettingsManifestStore.loadRequired(from: settingsURL)
        #expect(manifest.version == 15)
        #expect(manifest.providers.allSatisfy { AgentRemoteProvider.knownProviderIDs.contains($0.id) })
        #expect(!(String(data: migratedAgents, encoding: .utf8) ?? "").contains(Self.openRouterUUID))
        // The transaction journal is gone and no temporary file is left behind.
        let filenames = try FileManager.default.contentsOfDirectory(atPath: root.path)
        #expect(!filenames.contains(SensitiveManifestCoordination.journalFilename))
        #expect(!filenames.contains { $0.hasSuffix(".tmp") })

        #if canImport(Darwin) || canImport(Glibc)
        for url in [settingsURL, agentsURL] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let mode = try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
            #expect(mode == 0o600)
        }
        #endif

        // A second run finds current files and touches nothing.
        let second = try AgentProviderKeyMigration.migrateIfNeeded(supportDirectoryURL: root)
        #expect(!second.didMigrate)
        #expect(try Data(contentsOf: settingsURL) == migratedSettings)
        #expect(try Data(contentsOf: agentsURL) == migratedAgents)
    }

    @Test
    func collisionWarningIsDeliveredAfterTheCommit() throws {
        let root = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let settingsURL = root.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        let first = "11111111-2222-4333-8444-555555555555"
        let second = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"
        try JSONSerialization.data(withJSONObject: [
            "version": 14,
            "providers": [
                ["id": first, "name": "Custom A", "baseURL": "http://127.0.0.1:1234/v1", "chatEndpoint": "chat_completions"],
                ["id": second, "name": "Custom B", "baseURL": "http://127.0.0.1:5678/v1", "chatEndpoint": "chat_completions"]
            ],
            "models": [
                ["id": Self.legacyModelID(first, "a"), "kind": "remoteAPI", "modelID": "a", "providerID": first],
                ["id": Self.legacyModelID(second, "b"), "kind": "remoteAPI", "modelID": "b", "providerID": second]
            ]
        ] as [String: Any]).write(to: settingsURL)

        var warnings: [String] = []
        let report = try AgentProviderKeyMigration.migrateIfNeeded(
            supportDirectoryURL: root,
            warningSink: { warnings.append($0) }
        )
        #expect(report.migratedFilenames == ["settings.json"])
        #expect(warnings == report.warnings)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("'Custom B'") == true)
        let manifest = try AgentSettingsManifestStore.loadRequired(from: settingsURL)
        #expect(manifest.providers.map(\.id) == ["custom"])
        #expect(manifest.providers.first?.name == "Custom A")
        #expect(manifest.models.map(\.id) == ["custom:a"])
    }

    @Test
    func missingSettingsCreateNothing() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-provider-key-migration-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let report = try AgentProviderKeyMigration.migrateIfNeeded(supportDirectoryURL: root)
        #expect(!report.didMigrate)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test
    func legacyModelReferencesAreRewrittenOnTheFirstColonOnly() {
        let providerIDs = [Self.openRouterUUID: "openrouter"]
        #expect(
            AgentProviderKeyMigration.rewrittenModelReference(
                "REMOTEAPI:\(Self.openRouterUUID.uppercased()):deepseek/deepseek-r1:free",
                providerIDs: providerIDs
            ) == "openrouter:deepseek/deepseek-r1:free"
        )
        #expect(AgentProviderKeyMigration.rewrittenModelReference("remoteapi:\(Self.staleUUID):m", providerIDs: providerIDs) == nil)
        #expect(AgentProviderKeyMigration.rewrittenModelReference("remoteapi:\(Self.openRouterUUID):", providerIDs: providerIDs) == nil)
        #expect(AgentProviderKeyMigration.rewrittenModelReference("chatgpt:gpt-5", providerIDs: providerIDs) == nil)
        // An id built on a not-yet-migrated provider id follows the provider.
        #expect(
            AgentProviderKeyMigration.rewrittenModelReference(
                "\(Self.openRouterUUID):deepseek/deepseek-r1:free",
                providerIDs: providerIDs
            ) == "openrouter:deepseek/deepseek-r1:free"
        )
        #expect(
            AgentProviderKeyMigration.rewrittenModelReference(
                "openrouter:model",
                providerIDs: providerIDs.merging(["openrouter": "openrouter"]) { first, _ in first }
            ) == nil
        )
    }
}
