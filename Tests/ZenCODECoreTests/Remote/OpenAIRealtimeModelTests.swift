//
//  OpenAIRealtimeModelTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("OpenAI realtime model detection")
struct OpenAIRealtimeModelTests {
    private static func provider(
        _ profile: AgentProviderProfileID,
        baseURL: String = "https://api.openai.com/v1",
        modelID: String = "gpt-realtime-2.1"
    ) -> AgentRemoteProvider {
        AgentRemoteProvider(
            name: profile == .openAI ? "OpenAI API" : "OpenRouter",
            baseURL: baseURL,
            modelID: modelID,
            chatEndpoint: .responses,
            providerProfileID: profile,
            protocolProfileID: .openAIResponses,
            authPolicy: .apiKeyRequired
        )
    }

    private static func selection(_ provider: AgentRemoteProvider) -> AgentModelSelection {
        AgentModelSelection(
            providerKind: .remoteAPI,
            modelID: provider.modelID,
            remoteProvider: provider,
            apiKey: "unit-test-key",
            configuredContextWindowLimit: nil,
            generationParameterOverrides: nil,
            thinkingSelection: nil
        )
    }

    private static let configuration = AgentRuntimeConfiguration(
        modelID: "gpt-realtime-2.1",
        workingDirectory: URL(fileURLWithPath: "/tmp/realtime-factory-tests", isDirectory: true),
        maxToolRounds: 1,
        toolAuthorizationHandler: nil
    )

    @Test
    func detectsRealtimeModelsOnTheOpenAIProfileOnly() {
        #expect(OpenAIRealtimeModel.matches(provider: Self.provider(.openAI), modelID: "gpt-realtime-2.1"))
        #expect(OpenAIRealtimeModel.matches(provider: Self.provider(.openAI), modelID: " GPT-Realtime "))
        #expect(!OpenAIRealtimeModel.matches(provider: Self.provider(.openAI), modelID: "gpt-6-astra"))
        #expect(!OpenAIRealtimeModel.matches(
            provider: Self.provider(.openRouter, baseURL: "https://openrouter.ai/api/v1"),
            modelID: "gpt-realtime-2.1"
        ))
    }

    @Test
    func derivesTheWebSocketEndpointFromTheProviderBaseURL() {
        #expect(
            OpenAIRealtimeModel.webSocketURL(baseURL: "https://api.openai.com/v1", modelID: "gpt-realtime-2.1")?
                .absoluteString == "wss://api.openai.com/v1/realtime?model=gpt-realtime-2.1"
        )
        #expect(
            OpenAIRealtimeModel.webSocketURL(baseURL: "http://127.0.0.1:8080/v1", modelID: "gpt-realtime")?
                .absoluteString == "ws://127.0.0.1:8080/v1/realtime?model=gpt-realtime"
        )
        #expect(OpenAIRealtimeModel.webSocketURL(baseURL: "not a url", modelID: "gpt-realtime") == nil)
    }

    @Test
    func nonRealtimeOpenAIModelsKeepTheRemoteClient() throws {
        let backend = try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: Self.configuration.withModelID("gpt-6-astra"),
            mcpRuntime: DirectMCPToolRuntime(),
            resolvedModelSelection: Self.selection(Self.provider(.openAI, modelID: "gpt-6-astra"))
        )
        #expect(backend is RemoteGenerationClient)
    }

    #if os(macOS)
    @Test
    func realtimeModelsBuildTheRealtimeBackendForTheCoordinator() throws {
        let backend = try AgentRemoteBackendFactory.makeRemoteBackend(
            configuration: Self.configuration,
            mcpRuntime: DirectMCPToolRuntime(),
            resolvedModelSelection: Self.selection(Self.provider(.openAI))
        )
        #expect(backend is RealtimeGenerationClient)
    }

    @Test
    func realtimeModelsCannotBackADelegatedAgent() {
        #expect {
            _ = try AgentRemoteBackendFactory.makeRemoteBackend(
                configuration: Self.configuration,
                mcpRuntime: DirectMCPToolRuntime(),
                resolvedModelSelection: Self.selection(Self.provider(.openAI)),
                sharedChatSenderID: "delegated-agent"
            )
        } throws: { error in
            guard case AgentCoreBackendError.realtimeModelUnsupportedForDelegation("gpt-realtime-2.1") = error else {
                return false
            }
            return true
        }
    }
    #else
    @Test
    func realtimeModelsRequireMacOS() {
        #expect {
            _ = try AgentRemoteBackendFactory.makeRemoteBackend(
                configuration: Self.configuration,
                mcpRuntime: DirectMCPToolRuntime(),
                resolvedModelSelection: Self.selection(Self.provider(.openAI))
            )
        } throws: { error in
            guard case AgentCoreBackendError.realtimeModelRequiresMacOS("gpt-realtime-2.1") = error else {
                return false
            }
            return true
        }
    }
    #endif
}
