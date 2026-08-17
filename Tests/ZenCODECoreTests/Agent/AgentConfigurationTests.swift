//
//  AgentConfigurationTests.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct AgentConfigurationTests {
    @Test
    func syntaxValidationRejectsRemovedSetupOptionWithoutLoadingConfiguration() throws {
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "--setup"])
        }
        try AgentConfiguration.validateArguments([
            "zen",
            "--agent",
            "Developer",
            "--working-directory",
            "/tmp",
        ])
    }

    @Test
    func syntaxValidationRejectsRemovedBearerTokenOptionWithoutLoadingConfiguration() {
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments([
                "zen",
                "--bearer-token",
                "no-longer-supported",
            ])
        }
    }

    @Test
    func missingRemoteAPIKeyDirectsUsersToProviderSetup() {
        #expect(
            AgentCoreBackendError.missingRemoteAPIKey("Example provider")
                .localizedDescription
                == "No API key is stored for Example provider. Run /setup to configure that provider."
        )
    }

    @Test
    func anthropicDirectAPIProtocolBuildsNativeRemoteBackend() throws {
        let configuration = AgentRuntimeConfiguration(
            modelID: "claude-unit-test",
            workingDirectory: URL(fileURLWithPath: "/tmp/provider-factory-tests", isDirectory: true),
            maxToolRounds: 1,
            verboseLogging: false,
            toolAuthorizationHandler: nil
        )
        let anthropicAPISelection = AgentModelSelection(
            providerKind: .remoteAPI,
            modelID: "claude-unit-test",
            remoteProvider: AgentRemoteProvider(
                name: "Anthropic API",
                baseURL: "https://api.anthropic.com/v1",
                modelID: "claude-unit-test",
                chatEndpoint: .chatCompletions,
                providerProfileID: .anthropic,
                protocolProfileID: .anthropicMessages,
                authPolicy: .apiKeyRequired
            ),
            apiKey: "unit-test-key",
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingOptions: nil,
            thinkingSelection: nil
        )

        let backend = try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: DirectMCPToolRuntime(),
            resolvedModelSelection: anthropicAPISelection
        )
        #expect(backend is RemoteGenerationClient)
    }

    @Test
    func remoteBackendReceivesPersistedThinkingCapabilities() async throws {
        let configuration = AgentRuntimeConfiguration(
            modelID: "gpt-test",
            workingDirectory: URL(fileURLWithPath: "/tmp/provider-factory-tests", isDirectory: true),
            maxToolRounds: 1,
            verboseLogging: false,
            toolAuthorizationHandler: nil
        )
        let selection = AgentModelSelection(
            providerKind: .remoteAPI,
            modelID: "gpt-test",
            remoteProvider: AgentRemoteProvider(
                name: "OpenAI API",
                baseURL: "https://api.openai.com/v1",
                modelID: "gpt-test",
                chatEndpoint: .chatCompletions,
                providerProfileID: .openAI,
                protocolProfileID: .openAIChatCompletions,
                authPolicy: .apiKeyRequired
            ),
            apiKey: "unit-test-key",
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingOptions: [.off, .low, .high],
            thinkingSelection: .high
        )

        let backend = try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: configuration,
            mcpRuntime: DirectMCPToolRuntime(),
            resolvedModelSelection: selection
        )
        let client = try #require(backend as? RemoteGenerationClient)
        #expect(await client.thinkingOptions == [.off, .low, .high])
    }

    @Test
    func explicitWorkingDirectoryIsNeverReplacedByLaunchFallbacks() throws {
        let executableURL = try #require(Bundle.main.executableURL)
        let explicitDirectory = executableURL
            .deletingLastPathComponent()
            .standardizedFileURL
            .resolvingSymlinksInPath()

        let configuration = try AgentConfiguration(
            arguments: [
                "zen",
                "--help",
                "--working-directory",
                explicitDirectory.path,
            ]
        )

        #expect(configuration.workingDirectory == explicitDirectory)
        #expect(
            AgentConfiguration.resolvedWorkingDirectory(
                rawValue: explicitDirectory.path,
                applyLaunchDirectoryFallback: false
            ) == explicitDirectory
        )
    }
}
