//
//  TurnMemoryPrefixStabilityTests.swift
//  ZenCODECoreTests
//
//  Each generation client sends the prompt of an earlier turn again exactly as
//  it was first sent, recalled memory block included, so the request prefix a
//  provider caches stays valid across turns, also after the session is created
//  again from its history, which is what loading a saved session or switching
//  model does. The history carries the block beside the prompt, never in its
//  text, and the private key that holds it in a session never reaches a wire.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite("Turn memory prefix stability", .serialized)
struct TurnMemoryPrefixStabilityTests {
    private static let firstBlock = "<project-memory>\nfirst turn\n</project-memory>"
    private static let secondBlock = "<project-memory>\nsecond turn\n</project-memory>"
    private static let thirdBlock = "<project-memory>\nthird turn\n</project-memory>"
    private static let firstPrompt = "first question\n\n\(firstBlock)"
    private static let secondPrompt = "second question\n\n\(secondBlock)"
    private static let thirdPrompt = "third question\n\n\(thirdBlock)"

    // MARK: OpenAI-compatible provider

    @Test("a chat-completions request starts with the previous one, also in a session rebuilt from its history")
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
        let history = try checkedHistory(await client.snapshotSession(id: "session"))
        await client.createSession(
            id: "session", cwd: "/tmp/project", systemPrompt: "system prompt",
            history: history, allowedToolNames: []
        )
        try await turn(Self.thirdBlock) {
            try await client.sendPrompt(
                sessionID: "session", prompt: "third question", attachments: [], onEvent: { _ in }
            )
        }

        let requests = try fixture.capturedRequests().map { request in
            let payload = try request.jsonObject()
            return try #require(payload["messages"] as? [[String: Any]])
        }
        try #require(requests.count == 3)
        let userContents = requests.map { messages in
            messages.filter { $0["role"] as? String == "user" }.map { $0["content"] as? String }
        }
        #expect(userContents[0] == [Self.firstPrompt])
        #expect(userContents[1] == [Self.firstPrompt, Self.secondPrompt])
        #expect(userContents[2] == [Self.firstPrompt, Self.secondPrompt, Self.thirdPrompt])
        // Every message of a request opens the next one unchanged, the one
        // sent by the rebuilt session included.
        for (earlier, later) in zip(requests, requests.dropFirst()) {
            #expect(
                try canonicalJSON(Array(later.prefix(earlier.count)))
                    == canonicalJSON(earlier)
            )
        }
        expectNoPrivateKey(in: fixture.capturedRequests().map(\.body))
        await client.shutdown()
    }

    // MARK: Anthropic Subscription

    @Test("an Anthropic Subscription request repeats the earlier prompts with their blocks, also in a session loaded from a saved-session file")
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
        // The history goes through a saved-session file before the session is
        // created again from it.
        let history = try savedAndLoaded(
            checkedHistory(await client.snapshotSession(id: "session"))
        )
        await client.createSession(
            id: "session", cwd: "/tmp/project", systemPrompt: "system prompt",
            history: history, allowedToolNames: []
        )
        try await turn(Self.thirdBlock) {
            try await client.sendPrompt(
                sessionID: "session", prompt: "third question", attachments: [], onEvent: { _ in }
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
        try #require(userTexts.count == 3)
        #expect(userTexts[0] == [Self.firstPrompt])
        #expect(userTexts[1] == [Self.firstPrompt, Self.secondPrompt])
        #expect(userTexts[2] == [Self.firstPrompt, Self.secondPrompt, Self.thirdPrompt])
        expectNoPrivateKey(in: fixture.capturedRequests().map(\.body))
        await client.shutdown()
    }

    // MARK: ChatGPT Subscription

    @Test("a full ChatGPT Subscription replay repeats the earlier prompt with its block, also in a session rebuilt from its history")
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

        let sentTexts = socket.sentMessages.compactMap { message -> String? in
            guard case let .text(text) = message else { return nil }
            return text
        }
        let requests = try sentTexts.compactMap { text in
            try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
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
        expectNoPrivateKey(in: sentTexts.map { Data($0.utf8) })
        // A request that replays the whole session (a new socket, the HTTP
        // fallback) sends the first prompt again as it was first sent, here
        // from a session created again from its history.
        let history = try checkedHistory(await client.snapshotSession(id: "session"))
        await client.createSession(
            id: "session", cwd: "/tmp/project", systemPrompt: "system prompt",
            history: history, allowedToolNames: []
        )
        let replayJSON = try await client.fullReplayInputJSON(sessionID: "session")
        let replay = try JSONSerialization.jsonObject(with: Data(replayJSON.utf8))
        #expect(try inputItem(containing: "first question", in: replay) == sentFirstPrompt)
        expectNoPrivateKey(in: [Data(replayJSON.utf8)])
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

    /// The history of a session after its first two turns: the prompts as
    /// they were typed, each beside the block of its own turn and never
    /// holding it in its text.
    private func checkedHistory(
        _ snapshot: AgentRuntimeSessionSnapshot?
    ) throws -> [AgentRuntimeMessage] {
        let history = try #require(snapshot).history
        let prompts = history.filter { $0.role == .user }
        #expect(prompts.map(\.content) == ["first question", "second question"])
        #expect(prompts.map(\.turnAddition) == [Self.firstBlock, Self.secondBlock])
        #expect(!history.contains { $0.content.contains("project-memory") })
        return history
    }

    /// `history` after it was written to a saved-session file and read back,
    /// as saving a session and loading it do.
    private func savedAndLoaded(_ history: [AgentRuntimeMessage]) throws -> [AgentRuntimeMessage] {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-turn-memory-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let fileURL = try TerminalSessionStore.save(
            TerminalSavedSession(
                name: "prefix",
                sessionID: "session",
                cacheKey: nil,
                workingDirectoryPath: "/tmp/project",
                createdAt: Date(timeIntervalSince1970: 10),
                savedAt: Date(timeIntervalSince1970: 20),
                modelID: nil,
                agentID: nil,
                agentName: nil,
                selectedTools: [],
                selectedSkillNames: [],
                thinkingSelection: nil,
                systemPrompt: "system prompt",
                history: history,
                checkpointTree: SessionCheckpointTree.fromLinearHistory([], sessionID: "session")
            ),
            supportDirectoryURL: supportDirectory
        )
        return try TerminalSessionStore.load(from: fileURL).history
    }

    /// The key that holds a turn's text in a session is in none of `payloads`.
    private func expectNoPrivateKey(in payloads: [Data]) {
        for payload in payloads {
            #expect(
                !String(decoding: payload, as: UTF8.self)
                    .contains(RemoteGenerationClient.turnAdditionKey)
            )
        }
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
