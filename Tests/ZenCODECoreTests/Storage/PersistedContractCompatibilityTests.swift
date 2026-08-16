//
//  PersistedContractCompatibilityTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite("Persisted contract compatibility")
struct PersistedContractCompatibilityTests {
    @Test
    func legacyProviderProfilesMigrateInMemoryWithoutUsingDisplayName() throws {
        let openRouter = try decode(
            AgentSettingsProviderManifest.self,
            from: #"""
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "ChatGPT Subscription",
              "baseURL": "https://openrouter.ai/api/v1/",
              "chatEndpoint": "chat_completions"
            }
            """#
        )
        let customResponses = try decode(
            AgentSettingsProviderManifest.self,
            from: #"""
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "name": "OpenAI",
              "baseURL": "https://example.test/v1",
              "chatEndpoint": "responses"
            }
            """#
        )

        #expect(openRouter.providerProfileID == .openRouter)
        #expect(openRouter.protocolProfileID == .openAIChatCompletions)
        #expect(openRouter.authPolicy == .apiKeyRequired)
        #expect(customResponses.providerProfileID == .custom)
        #expect(customResponses.protocolProfileID == .openAIResponses)
        #expect(customResponses.authPolicy == .apiKeyOptional)
    }

    @Test
    func legacyHostedProvidersMigrateToNominalProfilesWithoutCustomFallback() throws {
        func legacy(_ json: String) throws -> AgentSettingsProviderManifest {
            try decode(AgentSettingsProviderManifest.self, from: json)
        }

        let zaiAPI = try legacy(#"""
        {
          "id": "aaaaaaaa-1111-1111-1111-111111111111",
          "name": "My own label",
          "baseURL": "https://api.z.ai/api/paas/v4",
          "chatEndpoint": "chat_completions"
        }
        """#)
        let zaiCodingPlan = try legacy(#"""
        {
          "id": "aaaaaaaa-2222-2222-2222-222222222222",
          "name": "Renamed plan",
          "baseURL": "https://api.z.ai/api/coding/paas/v4",
          "chatEndpoint": "chat_completions"
        }
        """#)
        let gemini = try legacy(#"""
        {
          "id": "aaaaaaaa-3333-3333-3333-333333333333",
          "name": "Google",
          "baseURL": "https://generativelanguage.googleapis.com/v1beta/openai",
          "chatEndpoint": "chat_completions"
        }
        """#)
        let deepSeek = try legacy(#"""
        {
          "id": "aaaaaaaa-4444-4444-4444-444444444444",
          "name": "reasoning",
          "baseURL": "https://api.deepseek.com/v1",
          "chatEndpoint": "chat_completions"
        }
        """#)
        let kimiCN = try legacy(#"""
        {
          "id": "aaaaaaaa-5555-5555-5555-555555555555",
          "name": "moonshot",
          "baseURL": "https://api.moonshot.cn/v1",
          "chatEndpoint": "chat_completions"
        }
        """#)

        #expect(zaiAPI.providerProfileID == .zAI)
        #expect(zaiAPI.protocolProfileID == .openAIChatCompletions)
        #expect(zaiAPI.authPolicy == .apiKeyRequired)
        #expect(zaiCodingPlan.providerProfileID == .zAI)
        #expect(zaiCodingPlan.protocolProfileID == .zaiCodingPlan)
        #expect(zaiCodingPlan.authPolicy == .apiKeyRequired)
        #expect(gemini.providerProfileID == .googleGemini)
        #expect(gemini.protocolProfileID == .openAIChatCompletions)
        #expect(gemini.authPolicy == .apiKeyRequired)
        #expect(deepSeek.providerProfileID == .deepSeek)
        #expect(deepSeek.protocolProfileID == .openAIChatCompletions)
        #expect(deepSeek.authPolicy == .apiKeyRequired)
        #expect(kimiCN.providerProfileID == .moonshot)
        #expect(kimiCN.protocolProfileID == .openAIChatCompletions)
        #expect(kimiCN.authPolicy == .apiKeyRequired)

        let displayNameTrap = try legacy(#"""
        {
          "id": "aaaaaaaa-6666-6666-6666-666666666666",
          "name": "Z.ai Coding Plan Kimi DeepSeek Gemini",
          "baseURL": "https://unrelated.example/v1",
          "chatEndpoint": "chat_completions"
        }
        """#)
        #expect(displayNameTrap.providerProfileID == .custom)
        #expect(displayNameTrap.protocolProfileID == .openAIChatCompletions)
        #expect(displayNameTrap.authPolicy == .apiKeyOptional)

        #expect(throws: DecodingError.self) {
            try decode(
                AgentSettingsProviderManifest.self,
                from: #"""
                {
                  "id": "aaaaaaaa-7777-7777-7777-777777777777",
                  "name": "Invalid",
                  "baseURL": "https://api.z.ai/api/coding/paas/v4",
                  "chatEndpoint": "chat_completions",
                  "providerProfileID": "moonshot",
                  "protocolProfileID": "zai.coding-plan",
                  "authPolicy": "api_key_required"
                }
                """#
            )
        }
    }

    // Regression: a legacy api.openai.com provider migrates with a required
    // API key instead of the permissive optional policy.
    @Test
    func legacyOpenAIBaseURLMigratesToAPIKeyRequiredProfile() throws {
        let openAIChat = try decode(
            AgentSettingsProviderManifest.self,
            from: #"""
            {
              "id": "bbbbbbbb-1111-1111-1111-111111111111",
              "name": "Whatever label",
              "baseURL": "https://api.openai.com/v1",
              "chatEndpoint": "chat_completions"
            }
            """#
        )
        let openAIResponses = try decode(
            AgentSettingsProviderManifest.self,
            from: #"""
            {
              "id": "bbbbbbbb-2222-2222-2222-222222222222",
              "name": "OpenAI-ish",
              "baseURL": "https://api.openai.com/v1",
              "chatEndpoint": "responses"
            }
            """#
        )

        #expect(openAIChat.providerProfileID == .openAI)
        #expect(openAIChat.protocolProfileID == .openAIChatCompletions)
        #expect(openAIChat.authPolicy == .apiKeyRequired)
        #expect(openAIChat.authPolicy.requiresAPIKey)
        #expect(openAIResponses.providerProfileID == .openAI)
        #expect(openAIResponses.protocolProfileID == .openAIResponses)
        #expect(openAIResponses.authPolicy == .apiKeyRequired)
    }

    @Test
    func legacySubscriptionIdentityAndDispatchProfilesArePreserved() throws {
        let chatGPT = try decode(
            AgentSettingsProviderManifest.self,
            from: #"""
            {
              "id": "00000000-0000-0000-0000-000000000003",
              "name": "Renamed connection",
              "baseURL": "https://irrelevant.example/v1",
              "chatEndpoint": "chat_completions"
            }
            """#
        )
        let claude = try decode(
            AgentSettingsProviderManifest.self,
            from: #"""
            {
              "id": "44444444-4444-4444-4444-444444444444",
              "name": "Renamed connection",
              "baseURL": "anthropic://subscription",
              "chatEndpoint": "responses"
            }
            """#
        )

        #expect(chatGPT.id == AgentRemoteProvider.chatGPTSubscriptionProviderID)
        #expect(chatGPT.baseURL == "https://irrelevant.example/v1")
        #expect(chatGPT.protocolProfileID == .openAIChatGPTSubscription)
        #expect(chatGPT.authPolicy == .chatGPTSubscription)
        #expect(chatGPT.remoteProvider(modelID: "chatgpt:test").isChatGPTSubscriptionProvider)
        #expect(claude.id.uuidString == "44444444-4444-4444-4444-444444444444")
        #expect(claude.baseURL == AgentRemoteProvider.anthropicSubscriptionBaseURL)
        #expect(claude.protocolProfileID == .anthropicClaudeSubscription)
        #expect(claude.authPolicy == .anthropicSubscription)
        #expect(claude.remoteProvider(modelID: "claude:test").isAnthropicSubscriptionProvider)
    }

    @Test
    func providerProfilesRoundTripInV13AndInvalidCombinationsFailClosed() throws {
        let provider = AgentSettingsProviderManifest(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "Local responses",
            baseURL: "http://127.0.0.1:8080/v1",
            chatEndpoint: .responses,
            providerProfileID: .custom,
            protocolProfileID: .openAIResponses,
            authPolicy: .noAuthentication
        )
        let manifest = AgentSettingsManifest(providers: [provider], models: [])
        let encoded = try JSONEncoder().encode(manifest)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let encodedProviders = try #require(object["providers"] as? [[String: Any]])
        let encodedProvider = try #require(encodedProviders.first)
        let reloaded = try JSONDecoder().decode(AgentSettingsManifest.self, from: encoded)

        #expect(object["version"] as? Int == 13)
        #expect(encodedProvider["providerProfileID"] as? String == "custom")
        #expect(encodedProvider["protocolProfileID"] as? String == "openai.responses")
        #expect(encodedProvider["authPolicy"] as? String == "none")
        #expect(reloaded.providers.first == provider)

        #expect(throws: DecodingError.self) {
            try decode(
                AgentSettingsProviderManifest.self,
                from: #"""
                {
                  "id": "33333333-3333-3333-3333-333333333333",
                  "name": "Invalid",
                  "baseURL": "https://example.test/v1",
                  "chatEndpoint": "responses",
                  "providerProfileID": "custom",
                  "protocolProfileID": "openai.chatgpt-subscription",
                  "authPolicy": "api_key_optional"
                }
                """#
            )
        }
    }

    @Test
    func settingsProfileAndPermissionsFixturesRemainReadable() throws {
        let settings = try decode(
            AgentSettingsManifest.self,
            from: #"""
            {
              "version": 10,
              "providers": [{
                "id": "11111111-1111-1111-1111-111111111111",
                "name": "Example Remote",
                "baseURL": "https://example.test/v1/",
                "chatEndpoint": "responses"
              }],
              "models": [{
                "id": "example/model",
                "kind": "remoteAPI",
                "title": "Example Model",
                "llmID": "example/model-v1",
                "modelID": "example/model",
                "providerID": "11111111-1111-1111-1111-111111111111",
                "context": { "configuredWindowLimit": 32768 },
                "thinking": { "options": ["off", "high"], "default": "high" }
              }],
              "selected": { "modelID": "example/model-v1", "thinking": "high" },
              "remoteAPIKeysByProviderID": {
                "11111111-1111-1111-1111-111111111111": "test-token"
              },
              "localExecAllowedCommands": ["swift", "git"]
            }
            """#
        )
        let profiles = try decode(
            AgentProfileManifest.self,
            from: #"""
            {
              "version": 1,
              "agents": [{
                "id": "reviewer",
                "name": "Reviewer",
                "instructions": "Review changes only.",
                "symbolName": "eye",
                "tools": ["files", "git"],
                "skills": [{
                  "id": "review-skill",
                  "canonicalName": "review",
                  "title": "Review",
                  "summary": "Inspect proposed changes.",
                  "symbolName": "checkmark"
                }],
                "modelID": "example/model",
                "modelProvider": "Example Remote",
                "thinkingSelection": "high"
              }]
            }
            """#
        )
        let permissions = try decode(
            AgentPermissionsManifest.self,
            from: #"""
            {
              "version": 1,
              "localExecAllowedCommands": ["swift test --filter Focused", "git status"]
            }
            """#
        )

        #expect(settings.selectedModelID == "example/model")
        #expect(settings.version == 10)
        #expect(settings.selectedThinkingSelection == .high)
        #expect(settings.providers.first?.baseURL == "https://example.test/v1")
        #expect(settings.providers.first?.providerProfileID == .custom)
        #expect(settings.providers.first?.protocolProfileID == .openAIResponses)
        #expect(settings.providers.first?.authPolicy == .apiKeyOptional)
        #expect(settings.models.first?.configuredContextWindowLimit == 32_768)
        #expect(settings.models.first?.defaultThinkingSelection == .high)
        #expect(settings.remoteAPIKeysByProviderID.count == 1)
        #expect(settings.localExecAllowedCommands == ["swift", "git"])
        #expect(profiles.agents.first?.skills.first?.canonicalName == "review")
        #expect(profiles.agents.first?.thinkingSelection == .high)
        #expect(permissions.localExecAllowedCommands == ["swift test --filter Focused", "git status"])

        let reloadedSettings = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: JSONEncoder().encode(settings)
        )
        let reloadedProfiles = try JSONDecoder().decode(
            AgentProfileManifest.self,
            from: JSONEncoder().encode(profiles)
        )
        let reloadedPermissions = try JSONDecoder().decode(
            AgentPermissionsManifest.self,
            from: JSONEncoder().encode(permissions)
        )
        #expect(reloadedSettings.selectedModelID == settings.selectedModelID)
        #expect(reloadedSettings.selectedThinkingSelection == settings.selectedThinkingSelection)
        #expect(reloadedSettings.models == settings.models)
        #expect(reloadedSettings.remoteAPIKeysByProviderID == settings.remoteAPIKeysByProviderID)
        #expect(reloadedProfiles.agents == profiles.agents)
        #expect(reloadedPermissions == permissions)
    }

    @Test
    func responseLanguageRoundTripsAndDecodesAbsence() throws {
        let withLanguage = AgentSettingsManifest(
            models: [],
            responseLanguage: "it"
        )
        let encoded = try JSONEncoder().encode(withLanguage)
        let reloaded = try JSONDecoder().decode(
            AgentSettingsManifest.self,
            from: encoded
        )

        #expect(reloaded.responseLanguage == "it")

        // A manifest without the field decodes to nil.
        let absent = try decode(
            AgentSettingsManifest.self,
            from: #"""
            {
              "version": 10,
              "models": []
            }
            """#
        )
        #expect(absent.responseLanguage == nil)
    }

    @Test
    func savedSessionSnapshotRoundTripsPersistedTranscriptAndPlan() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("persisted-contract-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let workingDirectory = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let date = Date(timeIntervalSinceReferenceDate: 123_456)
        let session = TerminalSavedSession(
            name: "Compatibility snapshot",
            sessionID: "session-compatibility",
            cacheKey: "cache-compatibility",
            workingDirectoryPath: workingDirectory.path,
            createdAt: date,
            savedAt: date,
            modelID: "example/model",
            agentID: "reviewer",
            agentName: "Reviewer",
            selectedTools: ["files", "git"],
            selectedSkillIDs: ["review-skill"],
            thinkingSelection: "high",
            contextWindow: TerminalSavedSessionContextWindow(
                usedTokens: 120,
                maxTokens: 1_024,
                modelID: "example/model",
                isApproximate: false
            ),
            systemPrompt: "Review the implementation.",
            history: [
                AgentRuntimeMessage(role: .user, content: "Inspect the change."),
                AgentRuntimeMessage(role: .assistant, content: "I found one issue.")
            ],
            transcriptHistory: [
                AgentRuntimeMessage(role: .user, content: "Inspect the change."),
                AgentRuntimeMessage(role: .assistant, content: "I found one issue.")
            ],
            activePlan: TerminalSessionPlan(
                originalGoal: "Review the implementation",
                consolidatedText: "1. Inspect\n2. Report",
                createdAt: date,
                isApproved: true,
                points: [
                    TerminalSessionPlanPoint(id: "1", text: "Inspect", status: .completed),
                    TerminalSessionPlanPoint(id: "2", text: "Report", status: .inProgress)
                ]
            ),
            checkpointTree: SessionCheckpointTree.fromLinearHistory(
                [
                    AgentRuntimeMessage(role: .user, content: "Inspect the change."),
                    AgentRuntimeMessage(role: .assistant, content: "I found one issue.")
                ],
                sessionID: "persisted-contract"
            )
        )

        let fileURL = try TerminalSessionStore.save(
            session,
            supportDirectoryURL: root.appendingPathComponent("storage", isDirectory: true)
        )
        let restored = try TerminalSessionStore.load(from: fileURL)

        #expect(restored == session)
        #expect(restored.displayHistory == session.transcriptHistory)
        #expect(restored.activePlan?.points.map(\.status) == [.completed, .inProgress])
        #expect(restored.contextWindow?.runtimeStatus?.maxTokens == 1_024)
    }

    @Test
    func featureManifestDescriptorEnvelopeSupportsEstablishedAliasesAndRoundTrips() throws {
        let manifest = try decode(
            SwiftFeatureManifest.self,
            from: #"""
            {
              "schema_version": 1,
              "id": "example-feature",
              "name": "Example Feature",
              "description": "A representative generated feature.",
              "binary": "example-feature",
              "enabled": true,
              "tools": [{
                "name": "example.echo",
                "title": "Echo",
                "description": "Returns the supplied text.",
                "input_schema": "{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}",
                "output_schema": "{\"type\":\"string\"}"
              }],
              "tool_name_prefixes": ["example.", "example."],
              "tool_name_aliases": ["example.run", "example.run"],
              "discovers_tools_at_runtime": true,
              "invocation_timeout_seconds": 30,
              "build": {
                "system": "swiftpm",
                "package_path": ".",
                "product": "example-feature",
                "configuration": "release",
                "executable_path": ".build/release/example-feature",
                "arguments": ["--verbose"]
              },
              "generated": {
                "by": "feature-builder",
                "created_at": "2026-06-13T12:00:00Z",
                "adopted_from": "legacy-feature"
              }
            }
            """#
        )

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.displayName == "Example Feature")
        #expect(manifest.executable == "example-feature")
        #expect(manifest.tools.first?.inputSchema.contains("\"text\"") == true)
        #expect(manifest.tools.first?.presentation == nil)
        #expect(manifest.toolNamePrefixes == ["example."])
        #expect(manifest.toolNameAliases == ["example.run"])
        #expect(manifest.discoversToolsAtRuntime)
        #expect(manifest.invocationTimeoutSeconds == 30)
        #expect(manifest.build?.executablePath == ".build/release/example-feature")
        #expect(manifest.generated?.createdAt == "2026-06-13T12:00:00Z")

        let reloaded = try JSONDecoder().decode(
            SwiftFeatureManifest.self,
            from: JSONEncoder().encode(manifest)
        )
        #expect(reloaded.id == manifest.id)
        #expect(reloaded.tools.first?.name == manifest.tools.first?.name)
        #expect(reloaded.toolNamePrefixes == manifest.toolNamePrefixes)
        #expect(reloaded.build?.arguments == ["--verbose"])
        #expect(reloaded.generated?.adoptedFrom == "legacy-feature")
    }

    @Test
    func featureManifestV2RejectsToolsWithoutPresentation() throws {
        let fixture = Data(
            #"{"schemaVersion":2,"id":"current","executable":"current","enabled":true,"tools":[{"name":"current.tool","description":"D","inputSchema":"{}"}]}"#.utf8
        )

        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(SwiftFeatureManifest.self, from: fixture)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from fixture: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(fixture.utf8))
    }
}
