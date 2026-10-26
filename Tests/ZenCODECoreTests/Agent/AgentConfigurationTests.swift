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
    func syntaxValidationRejectsRemovedVerboseOptionWithoutLoadingConfiguration() {
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "--verbose"])
        }
        #expect {
            try AgentConfiguration.validateArguments(["zen", "--verbose"])
        } throws: { error in
            guard case let AgentConfigurationError.unknownArgument(argument) = error else {
                return false
            }
            return argument == "--verbose"
        }
    }

    @Test
    func helpTextNoLongerMentionsVerboseOption() throws {
        _ = try AgentConfiguration(arguments: ["zen", "--help"])
        #expect(!AgentConfiguration.helpText.contains("--verbose"))
        #expect(!AgentConfiguration.helpText.contains("ZENCODE_AGENT_VERBOSE"))
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

    // MARK: - Default agent per project

    @Test
    func defaultAgentIsTheDeveloperAssociatedWithTheLaunchProject() throws {
        let custom = AgentProfile(id: "custom-dev", name: "Custom Dev", role: .developer)
        let agents = [AgentProfileRoleTestSupport.developer, custom, AgentProfileRoleTestSupport.pluto]

        try ProjectAgentSelectionTestSupport.withTemporaryProject { _, workspace in
            // No saved selection: the system developer.
            let unconfigured = try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: agents,
                workingDirectory: workspace
            )
            #expect(unconfigured.selectedAgent?.id == "developer")
            #expect(unconfigured.requestedAgentName == nil)

            // The project associates a custom developer but not the system one.
            try ProjectAgentSelectionStore.save(
                agentIDs: [custom.id, AgentProfileRoleTestSupport.pluto.id],
                workspaceRootURL: workspace
            )
            let associated = try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: agents,
                workingDirectory: workspace
            )
            #expect(associated.selectedAgent == custom)
            #expect(associated.agentName == custom.displayName)
            #expect(associated.requestedAgentName == nil)

            // A project without any visible developer keeps the global default.
            try ProjectAgentSelectionStore.save(
                agentIDs: [AgentProfileRoleTestSupport.pluto.id],
                workspaceRootURL: workspace
            )
            let withoutDeveloper = try AgentConfiguration(
                hostedModelID: "remote-community/test",
                availableAgents: agents,
                workingDirectory: workspace
            )
            #expect(withoutDeveloper.selectedAgent?.id == "developer")
            #expect(withoutDeveloper.requestedAgentName == nil)
        }
    }

    @Test
    func explicitAgentNameStillSelectsAnyProfileRegardlessOfTheProject() throws {
        let custom = AgentProfile(id: "custom-dev", name: "Custom Dev", role: .developer)
        let pluto = AgentProfileRoleTestSupport.pluto
        let agents = [AgentProfileRoleTestSupport.developer, custom, pluto]

        try ProjectAgentSelectionTestSupport.withTemporaryProject { _, workspace in
            try ProjectAgentSelectionStore.save(agentIDs: [custom.id], workspaceRootURL: workspace)

            let explicit = try AgentConfiguration(
                hostedModelID: "remote-community/test",
                agentName: "  Pluto  ",
                availableAgents: agents,
                workingDirectory: workspace
            )
            #expect(explicit.selectedAgent == pluto)
            #expect(explicit.requestedAgentName == "Pluto")
            #expect(explicit.agentName == "Pluto")

            let blank = try AgentConfiguration(
                hostedModelID: "remote-community/test",
                agentName: "   ",
                availableAgents: agents,
                workingDirectory: workspace
            )
            #expect(blank.selectedAgent == custom)
            #expect(blank.requestedAgentName == nil)
        }
    }

    // MARK: - Launch working directory

    /// A real, symlink-resolved temporary directory removed on exit, so
    /// expectations compare against the same canonical path the resolver returns.
    private func withTemporaryDirectory(
        _ body: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-launch-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test
    func launchWorkingDirectoryPrefersArgumentOverEnvironmentAndShell() throws {
        try withTemporaryDirectory { argumentDirectory in
            try withTemporaryDirectory { environmentDirectory in
                try withTemporaryDirectory { shellDirectory in
                    let environment = [
                        "ZENCODE_AGENT_CWD": environmentDirectory.path,
                        "PWD": shellDirectory.path,
                    ]
                    #expect(
                        AgentConfiguration.launchWorkingDirectoryURL(
                            arguments: ["zen", "--working-directory", argumentDirectory.path],
                            environment: environment
                        ) == argumentDirectory
                    )
                    #expect(
                        AgentConfiguration.launchWorkingDirectoryURL(
                            arguments: ["zen"],
                            environment: environment
                        ) == environmentDirectory
                    )
                    #expect(
                        AgentConfiguration.launchWorkingDirectoryURL(
                            arguments: ["zen"],
                            environment: ["PWD": shellDirectory.path]
                        ) == shellDirectory
                    )
                }
            }
        }
    }

    @Test
    func launchWorkingDirectoryLastArgumentWins() throws {
        try withTemporaryDirectory { first in
            try withTemporaryDirectory { second in
                #expect(
                    AgentConfiguration.launchWorkingDirectoryURL(
                        arguments: [
                            "zen",
                            "--working-directory", first.path,
                            "--agent", "Developer",
                            "--working-directory", second.path,
                        ],
                        environment: [:]
                    ) == second
                )
            }
        }
    }

    @Test
    func launchWorkingDirectoryIgnoresRelativeOrMissingShellDirectory() {
        let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let missing = "/zencode-missing-\(UUID().uuidString)"
        for shellValue in ["relative/path", missing] {
            let resolved = AgentConfiguration.launchWorkingDirectoryURL(
                arguments: ["zen"],
                environment: ["PWD": shellValue]
            )
            // Falls through to the process's current directory (or home, when
            // that is the executable's directory), never to the ignored value.
            #expect(
                resolved == currentDirectory
                    || resolved == UserHomeDirectory.current().standardizedFileURL.resolvingSymlinksInPath()
            )
        }
        #expect(
            AgentConfiguration.defaultWorkingDirectoryRawPath(environment: ["PWD": "relative/path"])
                == FileManager.default.currentDirectoryPath
        )
        #expect(
            AgentConfiguration.defaultWorkingDirectoryRawPath(environment: ["PWD": missing])
                == FileManager.default.currentDirectoryPath
        )
    }

    @Test
    func defaultWorkingDirectoryRawPathIgnoresBlankEnvironmentValue() throws {
        try withTemporaryDirectory { shellDirectory in
            #expect(
                AgentConfiguration.defaultWorkingDirectoryRawPath(
                    environment: ["ZENCODE_AGENT_CWD": "   ", "PWD": shellDirectory.path]
                ) == shellDirectory.path
            )
        }
    }
}
