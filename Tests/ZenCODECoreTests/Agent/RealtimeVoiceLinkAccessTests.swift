//
//  RealtimeVoiceLinkAccessTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Realtime voice link access", .serialized)
struct RealtimeVoiceLinkAccessTests {
    private func configuration(sessionID: String, modelID: String) -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: sessionID,
            modelID: modelID,
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: "System prompt.",
            cacheKey: nil,
            history: []
        )
    }

    @Test
    func nonRealtimeBackendsExposeNoVoiceLink() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runner = AgentCoreSessionRunner(backendFactory: { _, _ in backend })
        let link = try await runner.realtimeVoiceLink(
            configuration: configuration(sessionID: "voice-none-\(UUID().uuidString)", modelID: "test-model")
        )
        #expect(link == nil)
        await runner.shutdown()
    }

    @Test
    func realtimeBackendExposesAConnectedVoiceLink() async throws {
        let server = try await RealtimeLoopbackServer.start()
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        let url = server.url()
        let runner = AgentCoreSessionRunner(backendFactory: { configuration, mcpRuntime in
            RealtimeGenerationClient(
                configuration: configuration,
                provider: RealtimeGenerationClientTests.provider,
                apiKey: "test-key",
                transport: transport,
                webSocketURLOverride: url,
                mcpRuntime: mcpRuntime
            )
        })
        let sessionConfiguration = configuration(
            sessionID: "voice-link-\(UUID().uuidString)",
            modelID: "gpt-realtime-2.1"
        )

        do {
            let linkTask = Task {
                try await runner.realtimeVoiceLink(configuration: sessionConfiguration)
            }
            let connection = try await server.nextConnection()
            let update = try await connection.completeHandshake()
            let instructions = (update["session"] as? [String: Any])?["instructions"] as? String
            #expect(instructions?.contains("System prompt.") == true)

            let link = try #require(try await linkTask.value)
            #expect(link.modelID == "gpt-realtime-2.1")
            let (events, pump) = realtimeVoiceEventQueue(link.events)
            defer { pump.cancel() }
            #expect(try await events.next() == .connected)

            await link.appendInputAudio(Data([0, 1, 0, 1]))
            let append = try await connection.nextEvent()
            #expect(append["type"] as? String == "input_audio_buffer.append")
        } catch {
            await runner.shutdown()
            try? await transport.shutdown()
            await server.shutdown()
            throw error
        }
        await runner.shutdown()
        try? await transport.shutdown()
        await server.shutdown()
    }

    @Test
    func voiceMarkerTurnsSkipAutomaticMemoryRecall() {
        #expect(!AgentCoreSessionRunner.shouldRecallMemory(forPrompt: OpenAIRealtimeVoiceTurn.promptMarker))
        #expect(AgentCoreSessionRunner.shouldRecallMemory(forPrompt: "What is on my calendar?"))
        #expect(AgentCoreSessionRunner.shouldRecallMemory(forPrompt: "🎤 and some text"))
    }
}
