//
//  OpenAIRealtimeSessionTests.swift
//  ZenCODECoreTests
//

import Foundation
import NIOHTTP1
import Testing
import ToolCore
@testable import ZenCODECore

actor RealtimeDeltaRecorder {
    private(set) var values: [String] = []

    func append(_ value: String) {
        values.append(value)
    }
}

/// Collects a realtime voice-event stream into a timed queue.
func realtimeVoiceEventQueue(
    _ stream: AsyncStream<OpenAIRealtimeVoiceEvent>
) -> (queue: RealtimeTestQueue<OpenAIRealtimeVoiceEvent>, pump: Task<Void, Never>) {
    let queue = RealtimeTestQueue<OpenAIRealtimeVoiceEvent>()
    let pump = Task {
        for await event in stream {
            queue.append(event)
        }
        queue.close()
    }
    return (queue, pump)
}

@Suite("OpenAI realtime session", .serialized)
struct OpenAIRealtimeSessionTests {
    private struct Fixture {
        let server: RealtimeLoopbackServer
        let transport: RemoteTransportCore
        let session: OpenAIRealtimeSession
        let events: RealtimeTestQueue<OpenAIRealtimeVoiceEvent>
        let pump: Task<Void, Never>

        func tearDown() async {
            await session.close()
            pump.cancel()
            try? await transport.shutdown()
            await server.shutdown()
        }
    }

    private func makeFixture() async throws -> Fixture {
        let server = try await RealtimeLoopbackServer.start()
        let transport = RemoteTransportCore(owningEventLoopThreads: 1)
        let session = OpenAIRealtimeSession(
            transport: transport,
            url: server.url(),
            apiKey: "test-key"
        )
        let (events, pump) = realtimeVoiceEventQueue(session.voiceEvents)
        return Fixture(server: server, transport: transport, session: session, events: events, pump: pump)
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

    /// Starts the session while the server completes the handshake.
    private func startSession(
        _ fixture: Fixture,
        tools: [JSONValue] = []
    ) async throws -> (connection: RealtimeLoopbackConnection, update: [String: Any]) {
        let session = fixture.session
        async let started: Void = session.start(instructions: "Be brief.", tools: tools)
        let connection = try await fixture.server.nextConnection()
        let update = try await connection.completeHandshake()
        try await started
        #expect(try await fixture.events.next() == .connected)
        return (connection, update)
    }

    @Test("The handshake configures audio and server VAD without auto responses or input transcription")
    func handshakeConfiguresVoiceSession() async throws {
        try await withFixture { fixture in
            let tool = JSONValue(jsonObject: [
                "type": "function",
                "name": "custom_echo",
                "description": "Echo fixture.",
                "parameters": ["type": "object", "properties": [String: Any]()]
            ] as [String: Any])
            let (connection, update) = try await startSession(fixture, tools: [tool])

            #expect(connection.requestHead.headers.first(name: "authorization") == "Bearer test-key")
            #expect(connection.requestHead.uri.contains("model=gpt-realtime-2.1"))
            #expect(await fixture.session.isReady)

            let session = try #require(update["session"] as? [String: Any])
            #expect(session["type"] as? String == "realtime")
            #expect(session["output_modalities"] as? [String] == ["audio"])
            #expect(session["instructions"] as? String == "Be brief.")
            #expect(session["tool_choice"] as? String == "auto")
            let tools = try #require(session["tools"] as? [[String: Any]])
            #expect(tools.count == 1)
            #expect(tools.first?["name"] as? String == "custom_echo")

            let audio = try #require(session["audio"] as? [String: Any])
            let input = try #require(audio["input"] as? [String: Any])
            #expect(input["transcription"] == nil)
            let inputFormat = try #require(input["format"] as? [String: Any])
            #expect(inputFormat["type"] as? String == "audio/pcm")
            #expect(inputFormat["rate"] as? Int == 24_000)
            let turnDetection = try #require(input["turn_detection"] as? [String: Any])
            #expect(turnDetection["type"] as? String == "server_vad")
            #expect(turnDetection["create_response"] as? Bool == false)
            #expect(turnDetection["interrupt_response"] as? Bool == true)
            let output = try #require(audio["output"] as? [String: Any])
            #expect(output["voice"] as? String == "marin")
            #expect((output["format"] as? [String: Any])?["rate"] as? Int == 24_000)
        }
    }

    @Test("A text turn returns function calls, accepts their output and starts the next response")
    func textTurnRoundTripsFunctionCall() async throws {
        try await withFixture { fixture in
            let (connection, _) = try await startSession(fixture)
            let session = fixture.session

            try await session.createUserTextItem("What is on my calendar?")
            let item = try #require(
                try await connection.nextEvent(ofType: "conversation.item.create").event["item"] as? [String: Any]
            )
            #expect(item["type"] as? String == "message")
            #expect(item["role"] as? String == "user")
            let content = try #require(item["content"] as? [[String: Any]])
            #expect(content.first?["type"] as? String == "input_text")
            #expect(content.first?["text"] as? String == "What is on my calendar?")

            try await session.createResponse()
            _ = try await connection.nextEvent(ofType: "response.create")
            try await connection.send(["type": "response.created", "response": ["id": "resp_1", "status": "in_progress"]])
            for delta in ["Let me ", "check."] {
                try await connection.send([
                    "type": "response.output_audio_transcript.delta",
                    "response_id": "resp_1",
                    "item_id": "item_1",
                    "delta": delta
                ])
            }
            try await connection.send([
                "type": "response.done",
                "response": [
                    "id": "resp_1",
                    "status": "completed",
                    "output": [
                        [
                            "type": "message",
                            "id": "item_1",
                            "role": "assistant",
                            "content": [["type": "output_audio", "transcript": "Let me check."]]
                        ] as [String: Any],
                        [
                            "type": "function_call",
                            "id": "item_2",
                            "call_id": "call_1",
                            "name": "macos_calendar",
                            "arguments": #"{"range":"today"}"#
                        ] as [String: Any]
                    ] as [[String: Any]]
                ] as [String: Any]
            ])

            let deltas = RealtimeDeltaRecorder()
            let result = try await session.awaitResponseDone { delta in
                await deltas.append(delta)
            }
            #expect(result.status == "completed")
            #expect(result.transcript == "Let me check.")
            #expect(result.functionCalls == [
                OpenAIRealtimeFunctionCall(
                    callID: "call_1",
                    name: "macos_calendar",
                    argumentsJSON: #"{"range":"today"}"#
                )
            ])
            #expect(await deltas.values == ["Let me ", "check."])

            try await session.createFunctionCallOutput(callID: "call_1", output: "No events today.")
            let output = try #require(
                try await connection.nextEvent(ofType: "conversation.item.create").event["item"] as? [String: Any]
            )
            #expect(output["type"] as? String == "function_call_output")
            #expect(output["call_id"] as? String == "call_1")
            #expect(output["output"] as? String == "No events today.")

            try await session.createResponse()
            let second = try await connection.nextEvent(ofType: "response.create")
            #expect(second.skippedTypes.isEmpty)
        }
    }

    @Test("Committed speech is counted until one response answers it")
    func committedTurnsCoalesceIntoOneResponse() async throws {
        try await withFixture { fixture in
            let (connection, _) = try await startSession(fixture)
            let session = fixture.session

            await session.appendInputAudio(Data([1, 2, 3, 4]))
            let append = try await connection.nextEvent()
            #expect(append["type"] as? String == "input_audio_buffer.append")
            #expect(append["audio"] as? String == Data([1, 2, 3, 4]).base64EncodedString())

            try await connection.send(["type": "input_audio_buffer.committed", "item_id": "user_1"])
            try await connection.send(["type": "input_audio_buffer.committed", "item_id": "user_2"])
            #expect(try await fixture.events.next() == .turnCommitted(itemID: "user_1"))
            #expect(try await fixture.events.next() == .turnCommitted(itemID: "user_2"))
            #expect(await session.pendingCommittedTurns == 2)

            try await session.createResponse()
            _ = try await connection.nextEvent(ofType: "response.create")
            #expect(await session.pendingCommittedTurns == 0)
            #expect(await connection.expectNoClientEvent(within: .milliseconds(200)))
        }
    }

    @Test("Barge-in interrupts playback and truncates the unheard assistant audio")
    func bargeInTruncatesUnplayedAudio() async throws {
        try await withFixture { fixture in
            let (connection, _) = try await startSession(fixture)
            let session = fixture.session

            try await session.createResponse()
            _ = try await connection.nextEvent(ofType: "response.create")
            try await connection.send(["type": "response.created", "response": ["id": "resp_1"]])
            // 4 800 bytes of PCM16 mono 24 kHz are 100 ms of audio.
            let audio = Data(repeating: 7, count: 4_800)
            try await connection.send([
                "type": "response.output_audio.delta",
                "response_id": "resp_1",
                "item_id": "item_a",
                "output_index": 0,
                "content_index": 0,
                "delta": audio.base64EncodedString()
            ])
            #expect(try await fixture.events.next() == .audio(audio, itemID: "item_a", responseID: "resp_1"))

            await session.reportPlayback(itemID: "item_a", playedMilliseconds: 40)
            try await connection.send([
                "type": "input_audio_buffer.speech_started",
                "audio_start_ms": 1_000,
                "item_id": "user_1"
            ])
            #expect(try await fixture.events.next() == .speechStarted)
            #expect(try await fixture.events.next() == .interruptPlayback)

            let truncate = try await connection.nextEvent(ofType: "conversation.item.truncate").event
            #expect(truncate["item_id"] as? String == "item_a")
            #expect(truncate["content_index"] as? Int == 0)
            #expect(truncate["audio_end_ms"] as? Int == 40)
        }
    }

    @Test("Benign cancel errors are ignored while provider errors disconnect the session")
    func providerErrorDisconnects() async throws {
        try await withFixture { fixture in
            let (connection, _) = try await startSession(fixture)
            let session = fixture.session

            try await connection.send([
                "type": "error",
                "error": [
                    "type": "invalid_request_error",
                    "code": "response_cancel_not_active",
                    "message": "There is no active response to cancel."
                ]
            ])
            try await connection.send(["type": "input_audio_buffer.speech_stopped", "item_id": "user_1"])
            #expect(try await fixture.events.next() == .speechStopped)
            #expect(await session.isReady)

            try await session.createResponse()
            _ = try await connection.nextEvent(ofType: "response.create")
            try await connection.send([
                "type": "error",
                "error": [
                    "type": "invalid_request_error",
                    "code": "session_expired",
                    "message": "Your session hit the maximum duration of 60 minutes."
                ]
            ])

            await #expect(throws: OpenAIRealtimeSessionError.provider(
                code: "session_expired",
                message: "Your session hit the maximum duration of 60 minutes."
            )) {
                _ = try await session.awaitResponseDone { _ in }
            }
            #expect(try await fixture.events.next() == .disconnected(
                "session_expired: Your session hit the maximum duration of 60 minutes."
            ))
            #expect(try await fixture.events.next() == nil)
            #expect(await !session.isReady)
        }
    }

    @Test("A rejected WebSocket upgrade surfaces only the provider code and message")
    func rejectedUpgradeMapsToProviderError() {
        let body = #"{"error":{"message":"Incorrect API key provided.","type":"invalid_request_error","code":"invalid_api_key"}}"#
        #expect(
            OpenAIRealtimeSession.sessionError(for: .upgradeRejected(status: 401, body: body))
                == .provider(code: "invalid_api_key", message: "Incorrect API key provided.")
        )
        #expect(
            OpenAIRealtimeSession.sessionError(for: .upgradeRejected(status: 502, body: "<html>bad gateway</html>"))
                == .provider(code: "http_502", message: "The provider rejected the realtime connection (HTTP 502).")
        )
        #expect(
            OpenAIRealtimeSession.sessionError(for: .timeout)
                == .disconnected(RemoteTransportError.timeout.localizedDescription)
        )
    }

    @Test("A rejected session.update fails start with the provider error")
    func rejectedSessionUpdateFailsStart() async throws {
        try await withFixture { fixture in
            let session = fixture.session
            let startTask = Task {
                try await session.start(instructions: "Be brief.", tools: [])
            }
            let connection = try await fixture.server.nextConnection()
            try await connection.send(["type": "session.created", "session": ["id": "sess_test"]])
            _ = try await connection.nextEvent(ofType: "session.update")
            try await connection.send([
                "type": "error",
                "error": ["type": "invalid_request_error", "code": "invalid_value", "message": "Instructions are too long."]
            ])
            await #expect(throws: OpenAIRealtimeSessionError.provider(
                code: "invalid_value",
                message: "Instructions are too long."
            )) {
                try await startTask.value
            }
        }
    }
}
