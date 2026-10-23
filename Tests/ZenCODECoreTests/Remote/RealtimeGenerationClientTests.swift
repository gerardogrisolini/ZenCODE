//
//  RealtimeGenerationClientTests.swift
//  ZenCODECoreTests
//

import Foundation
import NIOHTTP1
import Testing
import ToolCore
@testable import ZenCODECore

private actor RealtimeAgentEventRecorder {
    enum Entry: Equatable {
        case content(String)
        case toolStarted(String)
        case toolCompleted(String, String)
        case diagnostic(String)
    }

    private(set) var entries: [Entry] = []

    func record(_ event: DirectAgentEvent) {
        switch event {
        case let .content(text):
            entries.append(.content(text))
        case let .toolCallStarted(call):
            entries.append(.toolStarted(call.name))
        case let .toolCallCompleted(call, result):
            entries.append(.toolCompleted(call.name, result.output))
        case let .diagnostic(text):
            entries.append(.diagnostic(text))
        default:
            break
        }
    }
}

@Suite("Realtime generation client", .serialized)
struct RealtimeGenerationClientTests {
    private static let sessionID = "voice-session"

    private struct Fixture {
        let server: RealtimeLoopbackServer
        let transport: RemoteTransportCore
        let client: RealtimeGenerationClient
        let workingDirectory: URL

        func tearDown() async {
            await client.shutdown()
            try? await transport.shutdown()
            await server.shutdown()
            try? FileManager.default.removeItem(at: workingDirectory)
        }
    }

    static let provider = AgentRemoteProvider(
        name: "OpenAI API",
        baseURL: "https://api.openai.com/v1",
        modelID: "gpt-realtime-2.1",
        chatEndpoint: .responses,
        providerProfileID: .openAI,
        protocolProfileID: .openAIResponses,
        authPolicy: .apiKeyRequired
    )

    private func makeFixture() async throws -> Fixture {
        let server = try await RealtimeLoopbackServer.start()
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        let workingDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("realtime-client-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
        let client = RealtimeGenerationClient(
            configuration: AgentRuntimeConfiguration(
                modelID: "gpt-realtime-2.1",
                workingDirectory: workingDirectory,
                maxToolRounds: 4,
                toolAuthorizationHandler: nil
            ),
            provider: Self.provider,
            apiKey: "test-key",
            transport: transport,
            webSocketURLOverride: server.url()
        )
        await client.updateToolProviders([
            AgentToolProvider(
                tools: [
                    ToolDescriptor(
                        name: "custom.echo",
                        description: "Echo fixture.",
                        inputSchema: #"{"type":"object","properties":{"text":{"type":"string"}}}"#
                    )
                ],
                executor: { call in "echoed \(call.argumentsJSON)" }
            )
        ])
        await client.createSession(
            id: Self.sessionID,
            cwd: workingDirectory.path,
            systemPrompt: "System prompt.",
            history: [
                AgentRuntimeMessage(role: .user, content: AgentRuntimeDynamicContext.marker + "Organizer context."),
                AgentRuntimeMessage(role: .user, content: "Earlier question"),
                AgentRuntimeMessage(role: .assistant, content: "Earlier reply")
            ],
            allowedToolNames: ["custom.echo"]
        )
        return Fixture(server: server, transport: transport, client: client, workingDirectory: workingDirectory)
    }

    private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
        let fixture = try await makeFixture()
        do {
            try await body(fixture)
        } catch {
            await fixture.tearDown()
            throw error
        }
        await fixture.tearDown()
    }

    private func completeResponse(
        on connection: RealtimeLoopbackConnection,
        id: String,
        transcript: String,
        functionCalls: [[String: Any]] = []
    ) async throws {
        try await connection.send(["type": "response.created", "response": ["id": id]])
        try await connection.send([
            "type": "response.output_audio_transcript.delta",
            "response_id": id,
            "item_id": "\(id)_message",
            "delta": transcript
        ])
        var output: [[String: Any]] = [[
            "type": "message",
            "id": "\(id)_message",
            "role": "assistant",
            "content": [["type": "output_audio", "transcript": transcript]]
        ]]
        output.append(contentsOf: functionCalls)
        try await connection.send([
            "type": "response.done",
            "response": ["id": id, "status": "completed", "output": output] as [String: Any]
        ])
    }

    @Test("A text turn runs the tool loop and returns the spoken transcript")
    func textTurnRunsToolLoop() async throws {
        try await withFixture { fixture in
            let client = fixture.client
            let recorder = RealtimeAgentEventRecorder()
            let turn = Task {
                try await client.sendPrompt(
                    sessionID: Self.sessionID,
                    prompt: "Echo hi",
                    attachments: [],
                    onEvent: { await recorder.record($0) }
                )
            }

            let connection = try await fixture.server.nextConnection()
            #expect(connection.requestHead.uri.contains("model=gpt-realtime-2.1"))
            let update = try await connection.completeHandshake()
            let session = try #require(update["session"] as? [String: Any])
            let instructions = try #require(session["instructions"] as? String)
            #expect(instructions.hasPrefix(RealtimeGenerationClient.voicePreamble))
            #expect(instructions.contains("System prompt."))
            #expect(instructions.contains("Organizer context."))
            #expect(!instructions.contains("Earlier reply"))
            let tools = try #require(session["tools"] as? [[String: Any]])
            let echo = try #require(tools.first { $0["description"] as? String == "Echo fixture." })
            #expect(echo["strict"] == nil)
            let wireName = try #require(echo["name"] as? String)
            #expect(!wireName.contains("."))

            let userItem = try #require(
                try await connection.nextEvent(ofType: "conversation.item.create").event["item"] as? [String: Any]
            )
            let content = try #require(userItem["content"] as? [[String: Any]])
            #expect(content.first?["text"] as? String == "Echo hi")
            _ = try await connection.nextEvent(ofType: "response.create")
            try await completeResponse(
                on: connection,
                id: "resp_1",
                transcript: "Sure. ",
                functionCalls: [[
                    "type": "function_call",
                    "id": "item_call",
                    "call_id": "call_1",
                    "name": wireName,
                    "arguments": #"{"text":"hi"}"#
                ]]
            )

            let toolOutput = try #require(
                try await connection.nextEvent(ofType: "conversation.item.create").event["item"] as? [String: Any]
            )
            #expect(toolOutput["type"] as? String == "function_call_output")
            #expect(toolOutput["call_id"] as? String == "call_1")
            let outputText = try #require(toolOutput["output"] as? String)
            #expect(outputText.contains("echoed"))
            #expect(outputText.contains("hi"))
            _ = try await connection.nextEvent(ofType: "response.create")
            try await completeResponse(on: connection, id: "resp_2", transcript: "Done.")

            let response = try await turn.value
            #expect(response.text == "Sure. Done.")
            #expect(response.stopReason == "stop")
            #expect(response.modelID == "gpt-realtime-2.1")

            let entries = await recorder.entries
            #expect(entries.first == .content("Sure. "))
            #expect(entries.last == .content("Done."))
            #expect(entries.contains(.toolStarted("custom.echo")))
            #expect(entries.contains { entry in
                if case let .toolCompleted(name, output) = entry {
                    return name == "custom.echo" && output.contains("echoed")
                }
                return false
            })
            #expect(await client.snapshotSession(id: Self.sessionID) == nil)
        }
    }

    @Test("Committed speech is answered once and a later voice marker turn is coalesced")
    func voiceMarkerTurnsCoalesce() async throws {
        try await withFixture { fixture in
            let client = fixture.client
            let linkTask = Task {
                try await client.voiceLink(sessionID: Self.sessionID)
            }
            let connection = try await fixture.server.nextConnection()
            _ = try await connection.completeHandshake()
            let link = try await linkTask.value
            let (events, pump) = realtimeVoiceEventQueue(link.events)
            defer { pump.cancel() }
            #expect(try await events.next() == .connected)

            try await connection.send(["type": "input_audio_buffer.committed", "item_id": "user_1"])
            try await connection.send(["type": "input_audio_buffer.committed", "item_id": "user_2"])
            #expect(try await events.next() == .turnCommitted(itemID: "user_1"))
            #expect(try await events.next() == .turnCommitted(itemID: "user_2"))

            let first = Task {
                try await client.sendPrompt(
                    sessionID: Self.sessionID,
                    prompt: OpenAIRealtimeVoiceTurn.promptMarker,
                    attachments: [],
                    onEvent: { _ in }
                )
            }
            let create = try await connection.nextEvent(ofType: "response.create")
            #expect(create.skippedTypes.isEmpty)
            try await completeResponse(on: connection, id: "resp_1", transcript: "Hello.")
            let answered = try await first.value
            #expect(answered.text == "Hello.")

            let coalesced = try await client.sendPrompt(
                sessionID: Self.sessionID,
                prompt: OpenAIRealtimeVoiceTurn.promptMarker,
                attachments: [],
                onEvent: { _ in }
            )
            #expect(coalesced.stopReason == "coalesced")
            #expect(coalesced.text.isEmpty)
            #expect(await connection.expectNoClientEvent(within: .milliseconds(200)))
        }
    }

    @Test("An isolated memory proposal never reaches the voice conversation")
    func isolatedMemoryProposalIsRejected() async throws {
        try await withFixture { fixture in
            let client = fixture.client
            await #expect(throws: CancellationError.self) {
                try await MemoryConsolidationContext.$isIsolated.withValue(true) {
                    _ = try await client.sendPrompt(
                        sessionID: Self.sessionID,
                        prompt: "Propose a memory.",
                        attachments: [],
                        onEvent: { _ in }
                    )
                }
            }
            #expect(await fixture.server.expectNoConnection(within: .milliseconds(200)))
            #expect(await client.snapshotSession(id: Self.sessionID) == nil)
        }
    }

    @Test("A lost connection is replaced by an empty conversation with a diagnostic")
    func reconnectsAfterDisconnect() async throws {
        try await withFixture { fixture in
            let client = fixture.client
            let linkTask = Task {
                try await client.voiceLink(sessionID: Self.sessionID)
            }
            let firstConnection = try await fixture.server.nextConnection()
            _ = try await firstConnection.completeHandshake()
            let link = try await linkTask.value
            let (events, pump) = realtimeVoiceEventQueue(link.events)
            defer { pump.cancel() }
            #expect(try await events.next() == .connected)

            await firstConnection.close()
            let disconnected = try await events.next()
            guard case .disconnected = disconnected else {
                Issue.record("Expected a disconnected voice event, got \(String(describing: disconnected)).")
                return
            }

            let recorder = RealtimeAgentEventRecorder()
            let turn = Task {
                try await client.sendPrompt(
                    sessionID: Self.sessionID,
                    prompt: "Are you there?",
                    attachments: [],
                    onEvent: { await recorder.record($0) }
                )
            }
            let secondConnection = try await fixture.server.nextConnection()
            _ = try await secondConnection.completeHandshake()
            _ = try await secondConnection.nextEvent(ofType: "conversation.item.create")
            _ = try await secondConnection.nextEvent(ofType: "response.create")
            try await completeResponse(on: secondConnection, id: "resp_1", transcript: "Yes.")

            let response = try await turn.value
            #expect(response.text == "Yes.")
            #expect(await recorder.entries.contains(.diagnostic(RealtimeGenerationClient.restartDiagnostic)))
        }
    }

    @Test("Tool output sent to the provider is bounded")
    func toolOutputIsTruncated() {
        let long = String(repeating: "a", count: RealtimeGenerationClient.toolOutputCharacterLimit + 10)
        let truncated = RealtimeGenerationClient.truncatedToolOutput(long)
        #expect(truncated.hasPrefix(String(repeating: "a", count: RealtimeGenerationClient.toolOutputCharacterLimit)))
        #expect(truncated.hasSuffix("[Output truncated: 10 characters omitted.]"))
        #expect(RealtimeGenerationClient.truncatedToolOutput("short") == "short")
    }
}
