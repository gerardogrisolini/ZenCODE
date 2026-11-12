//
//  TurnMemoryPrefixStabilityTests.swift
//  ZenCODECoreTests
//
//  Each generation client sends the prompt of an earlier turn again exactly as
//  it was first sent, recalled memory block included, so the request prefix a
//  provider caches stays valid across turns. The block still never enters the
//  session history, and the private key that carries it never reaches a wire.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite("Turn memory prefix stability", .serialized)
struct TurnMemoryPrefixStabilityTests {
    private static let firstBlock = "<project-memory>\nfirst turn\n</project-memory>"
    private static let secondBlock = "<project-memory>\nsecond turn\n</project-memory>"
    private static let firstPrompt = "first question\n\n\(firstBlock)"
    private static let secondPrompt = "second question\n\n\(secondBlock)"

    // MARK: OpenAI-compatible provider

    @Test("a chat-completions request starts with the previous turn's request")
    func chatCompletionsRequestKeepsEarlierPrompt() async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: try sse([
            ["choices": [["delta": ["content": "Answer"], "finish_reason": "stop"]]]
        ]))
        defer { fixture.beginShutdown() }
        let client = RemoteGenerationClient(
            configuration: configuration(modelID: "unit-model"),
            provider: AgentRemoteProvider(
                name: "Prefix fixture",
                baseURL: "https://unit.test/v1",
                modelID: "unit-model",
                chatEndpoint: .chatCompletions,
                protocolProfileID: .openAIChatCompletions
            ),
            apiKey: "test-key",
            transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )
        await client.createSession(
            id: "session", cwd: "/tmp/project", systemPrompt: "system prompt", allowedToolNames: []
        )

        try await turn(Self.firstBlock) {
            try await client.sendPrompt(
                sessionID: "session", prompt: "first question", attachments: [], onEvent: { _ in }
            )
        }
        try await turn(Self.secondBlock) {
            try await client.sendPrompt(
                sessionID: "session", prompt: "second question", attachments: [], onEvent: { _ in }
            )
        }

        let requests = try fixture.capturedRequests().map { request in
            let payload = try request.jsonObject()
            return try #require(payload["messages"] as? [[String: Any]])
        }
        try #require(requests.count == 2)
        let userContents = requests.map { messages in
            messages.filter { $0["role"] as? String == "user" }.map { $0["content"] as? String }
        }
        #expect(userContents[0] == [Self.firstPrompt])
        #expect(userContents[1] == [Self.firstPrompt, Self.secondPrompt])
        // Every message of the first request opens the second one unchanged.
        #expect(
            try canonicalJSON(Array(requests[1].prefix(requests[0].count)))
                == canonicalJSON(requests[0])
        )
        for message in requests.joined() {
            #expect(message[RemoteGenerationClient.turnAdditionKey] == nil)
        }
        try expectHistoryWithoutMemory(await client.snapshotSession(id: "session"))
        await client.shutdown()
    }

    // MARK: Anthropic Subscription

    @Test("an Anthropic Subscription request repeats the earlier prompt with its block")
    func anthropicSubscriptionRequestKeepsEarlierPrompt() async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: try sse([
            ["type": "message_start", "message": ["usage": ["input_tokens": 3, "output_tokens": 0]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": "Answer"]],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 1]],
            ["type": "message_stop"]
        ]))
        defer { fixture.beginShutdown() }
        let client = AnthropicSubscriptionGenerationClient(
            configuration: configuration(modelID: "claude-haiku-4-5"),
            provider: AgentRemoteProvider(
                name: "Anthropic Subscription",
                baseURL: AgentRemoteProvider.anthropicSubscriptionBaseURL,
                modelID: "claude-haiku-4-5",
                chatEndpoint: .responses
            ),
            transport: fixture.transport,
            messagesEndpointURLOverride: fixture.messagesURL
        )
        let credentials = AnthropicSubscriptionCredentials(
            accessToken: "access-token",
            refreshToken: "refresh-token",
            expiresAt: Date().addingTimeInterval(3_600)
        )
        await client.setCredentialProviders(load: { credentials }, refresh: { _ in credentials })
        await client.createSession(
            id: "session", cwd: "/tmp/project", systemPrompt: "system prompt", allowedToolNames: []
        )

        try await turn(Self.firstBlock) {
            try await client.sendPrompt(
                sessionID: "session", prompt: "first question", attachments: [], onEvent: { _ in }
            )
        }
        try await turn(Self.secondBlock) {
            try await client.sendPrompt(
                sessionID: "session", prompt: "second question", attachments: [], onEvent: { _ in }
            )
        }

        let userTexts = try fixture.capturedRequests().map { request in
            let payload = try request.jsonObject()
            let messages = try #require(payload["messages"] as? [[String: Any]])
            return messages.filter { $0["role"] as? String == "user" }.map { message in
                (message["content"] as? [[String: Any]] ?? [])
                    .compactMap { $0["text"] as? String }
                    .joined()
            }
        }
        try #require(userTexts.count == 2)
        #expect(userTexts[0] == [Self.firstPrompt])
        #expect(userTexts[1] == [Self.firstPrompt, Self.secondPrompt])
        try expectHistoryWithoutMemory(await client.snapshotSession(id: "session"))
        await client.shutdown()
    }

    // MARK: ChatGPT Subscription

    @Test("a full ChatGPT Subscription replay repeats the earlier prompt with its block")
    func chatGPTSubscriptionReplayKeepsEarlierPrompt() async throws {
        let socket = ChatGPTSubscriptionTestWebSocketTask(
            receiveOutcomes: try chatGPTFrames(id: "first") + chatGPTFrames(id: "second")
        )
        let pending = Mutex([socket])
        let pool = ChatGPTSubscriptionWebSocketPool(
            heartbeatIntervalNanoseconds: UInt64.max,
            webSocketTaskFactory: { _ in
                pending.withLock {
                    guard !$0.isEmpty else {
                        Issue.record("Unexpected extra transport attempt")
                        return ChatGPTSubscriptionTestWebSocketTask(
                            receiveOutcomes: [.failure(CancellationError())]
                        )
                    }
                    return $0.removeFirst()
                }
            }
        )
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(
            configuration: configuration(modelID: "unit-model"),
            webSocketPool: pool
        )
        await client.createSession(
            id: "session", cwd: "/tmp/project", systemPrompt: "system prompt", allowedToolNames: []
        )
        let credentials: @Sendable () async throws -> CodexAgentCredentials = {
            CodexAgentCredentials(
                accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, accountID: "fixture"
            )
        }

        try await turn(Self.firstBlock) {
            try await client.sendPrompt(
                sessionID: "session", prompt: "first question", attachments: [],
                loadCredentials: credentials, onEvent: { _ in }
            )
        }
        try await turn(Self.secondBlock) {
            try await client.sendPrompt(
                sessionID: "session", prompt: "second question", attachments: [],
                loadCredentials: credentials, onEvent: { _ in }
            )
        }

        let requests = try socket.sentMessages.compactMap { message -> [String: Any]? in
            guard case let .text(text) = message else { return nil }
            return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
        try #require(requests.count == 2)
        let sentFirstPrompt = try inputItem(containing: "first question", in: requests[0]["input"])
        #expect(sentFirstPrompt.contains("first turn"))
        // The second turn continues the first response, so only its own
        // prompt travels on this socket.
        #expect(requests[1]["previous_response_id"] as? String == "first")
        #expect(
            try inputItem(containing: "second question", in: requests[1]["input"])
                .contains("second turn")
        )
        // A request that replays the whole session (a new socket, the HTTP
        // fallback) sends the first prompt again as it was first sent.
        let replayJSON = try await client.fullReplayInputJSON(sessionID: "session")
        let replay = try JSONSerialization.jsonObject(with: Data(replayJSON.utf8))
        #expect(try inputItem(containing: "first question", in: replay) == sentFirstPrompt)
        try expectHistoryWithoutMemory(await client.snapshotSession(id: "session"))
        await client.shutdown()
    }

    // MARK: Helpers

    private func configuration(modelID: String) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: modelID,
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            maxToolRounds: 4,
            toolAuthorizationHandler: nil
        )
    }

    /// Runs one prompt with `block` bound as the memory recalled for its turn.
    private func turn(
        _ block: String,
        _ send: () async throws -> DirectAgentResponse
    ) async throws {
        _ = try await MemoryTurnContext.$currentTurnMemoryBlock.withValue(block) {
            try await send()
        }
    }

    /// The prompts are in the history as they were typed, and no message of
    /// the history holds a memory block.
    private func expectHistoryWithoutMemory(_ snapshot: AgentRuntimeSessionSnapshot?) throws {
        let history = try #require(snapshot).history
        #expect(
            history.filter { $0.role == .user }.map(\.content)
                == ["first question", "second question"]
        )
        #expect(!history.contains { $0.content.contains("project-memory") })
    }

    private func sse(_ events: [[String: Any]]) throws -> Data {
        try events.reduce(into: Data()) { data, event in
            data.append(Data("data: ".utf8))
            data.append(try JSONSerialization.data(withJSONObject: event))
            data.append(Data("\n\n".utf8))
        }
    }

    private func chatGPTFrames(
        id: String
    ) throws -> [Result<ChatGPTSubscriptionWebSocketMessage, Error>] {
        let events: [[String: Any]] = [
            ["type": "response.output_text.delta", "delta": "Answer"],
            ["type": "response.completed", "response": [
                "id": id,
                "status": "completed",
                "output": [[
                    "type": "message",
                    "role": "assistant",
                    "content": [["type": "output_text", "text": "Answer"]]
                ]]
            ]]
        ]
        return try events.map {
            .success(.text(String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)))
        }
    }

    private func canonicalJSON(_ value: Any) throws -> String {
        String(
            decoding: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
            as: UTF8.self
        )
    }

    /// The one item of a Responses `input` array whose JSON holds `text`.
    private func inputItem(containing text: String, in input: Any?) throws -> String {
        let items = try #require(input as? [Any]).map(canonicalJSON)
        let matches = items.filter { $0.contains(text) }
        try #require(matches.count == 1)
        return matches[0]
    }
}

private extension ChatGPTSubscriptionGenerationClient {
    /// The `input` of a request that replays the whole session, built the way
    /// the prompt loop builds it when no continuation applies.
    func fullReplayInputJSON(sessionID: String) throws -> String {
        let session = try #require(sessions[sessionID])
        let input = ChatGPTSubscriptionRequestBuilder.requestInputPayload(
            from: RemoteGenerationClient.applyingCurrentTurnMemory(
                to: session.messages,
                block: nil,
                instruction: nil
            ),
            continuation: nil
        ).input
        return String(
            decoding: try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys]),
            as: UTF8.self
        )
    }
}
