//
//  SwiftFeatureRuntimePropagationTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite
struct SwiftFeatureRuntimePropagationTests {
    @Test
    @TerminalChatActor
    func terminalChatUsesTheRuntimeOwnedByAnInjectedSessionRunner() throws {
        let runtime = SwiftFeatureRuntime()
        let runner = AgentCoreSessionRunner(swiftFeatureRuntime: runtime)
        let configuration = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            availableAgents: AgentProfileStore.defaultProfiles(),
            workingDirectory: URL(fileURLWithPath: "/tmp/runtime-propagation", isDirectory: true)
        )

        let terminal = TerminalChat(
            configuration: configuration,
            stdinIsTerminal: false,
            sessionRunner: runner
        )

        #expect(terminal.featureRuntime === runtime)
        #expect(terminal.sessionRunner.swiftFeatureRuntime === terminal.featureRuntime)
    }

    @Test
    func remoteBackendUsesTheInjectedFeatureRuntimeForToolExecution() async throws {
        let runtime = SwiftFeatureRuntime()
        let configuration = AgentRuntimeConfiguration(
            modelID: "gpt-runtime-propagation",
            workingDirectory: URL(fileURLWithPath: "/tmp/runtime-propagation", isDirectory: true),
            maxToolRounds: 1,
            toolAuthorizationHandler: nil
        )
        let selection = AgentModelSelection(
            providerKind: .remoteAPI,
            modelID: "gpt-runtime-propagation",
            remoteProvider: AgentRemoteProvider(
                name: "OpenAI API",
                baseURL: "https://api.openai.com/v1",
                modelID: "gpt-runtime-propagation",
                chatEndpoint: .chatCompletions,
                providerProfileID: .openAI,
                protocolProfileID: .openAIChatCompletions,
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
            resolvedModelSelection: selection,
            swiftFeatureRuntime: runtime
        )
        let client = try #require(backend as? RemoteGenerationClient)

        let toolExecutor = await client.toolExecutor
        let executorRuntime = await toolExecutor.swiftFeatureRuntime
        #expect(executorRuntime === runtime)
    }
}
