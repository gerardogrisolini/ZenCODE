//
//  ChatGPTSubscriptionStreamFailureCharacterizationTests.swift
//  ZenCODECoreTests
//
//  Pins the precedence between the per-turn retries of the ChatGPT
//  Subscription prompt loop: stream interruption, continuation replay
//  fallback, context-limit compaction and the unsatisfiable-budget notice.
//  Every scenario runs end to end over deterministic WebSocket doubles and
//  never reaches the real credential refresh.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

private struct ChatGPTStreamFailureTurn {
    let response: DirectAgentResponse?
    let error: Error?
    let diagnostics: [String]
}

extension RemoteSessionSnapshotTests {
    private static let chatGPTStreamFailureContextLimitMessage =
        "Your input exceeds the context window of this model."
    private static let chatGPTStreamFailureContinuationMessage =
        "Previous response with id 'first' not found."
    private static let chatGPTStreamFailureContextRetryPrefix =
        "ChatGPT Subscription context limit reached. Retrying once with compacted conversation history"
    private static let chatGPTStreamFailureUnsatisfiablePrefix =
        "ChatGPT Subscription request cannot fit the 10000 token context window"

    // MARK: - Fixtures

    private func chatGPTStreamFailureFrames(
        _ events: [[String: Any]]
    ) throws -> [Result<ChatGPTSubscriptionWebSocketMessage, Error>] {
        try events.map {
            .success(.text(String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)))
        }
    }

    private func chatGPTStreamFailureCompleted(id: String, text: String) -> [String: Any] {
        [
            "type": "response.completed",
            "response": [
                "id": id,
                "status": "completed",
                "output": [["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]]]
            ]
        ]
    }

    private func chatGPTStreamFailureToolCall(id: String) -> [String: Any] {
        [
            "type": "response.completed",
            "response": [
                "id": id,
                "status": "completed",
                "output": [["type": "function_call", "id": "fc_\(id)", "call_id": "call_\(id)", "name": "local.pwd", "arguments": "{}"]]
            ]
        ]
    }

    private func chatGPTStreamFailureErrorEvent(code: String, message: String) -> [String: Any] {
        ["type": "error", "error": ["type": "invalid_request_error", "code": code, "message": message]]
    }

    /// A replay-unsafe provisional delta: once it crosses the callback
    /// boundary the transport client no longer retries on its own.
    private func chatGPTStreamFailureDelta() -> [String: Any] {
        ["type": "response.output_text.delta", "delta": "partial"]
    }

    private func chatGPTStreamFailureInterruption() throws -> [Result<ChatGPTSubscriptionWebSocketMessage, Error>] {
        try chatGPTStreamFailureFrames([chatGPTStreamFailureDelta()]) + [.failure(RemoteTransportError.closed)]
    }

    private func chatGPTStreamFailureContextLimit() throws -> [Result<ChatGPTSubscriptionWebSocketMessage, Error>] {
        try chatGPTStreamFailureFrames([
            chatGPTStreamFailureErrorEvent(code: "context_length_exceeded", message: Self.chatGPTStreamFailureContextLimitMessage)
        ])
    }

    /// Enough history for the context-limit retry to compact materially.
    private func chatGPTStreamFailureHistory() -> [AgentRuntimeMessage] {
        (0..<8).map { index in
            AgentRuntimeMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "Message \(index): " + String(repeating: "context filler \(index) ", count: 40)
            )
        }
    }

    private func chatGPTStreamFailurePool(
        _ tasks: [ChatGPTSubscriptionTestWebSocketTask]
    ) -> ChatGPTSubscriptionWebSocketPool {
        let pending = Mutex(tasks)
        return ChatGPTSubscriptionWebSocketPool(
            heartbeatIntervalNanoseconds: UInt64.max,
            webSocketTaskFactory: { _ in
                pending.withLock {
                    guard !$0.isEmpty else {
                        Issue.record("Unexpected extra transport attempt")
                        return ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes: [.failure(CancellationError())])
                    }
                    return $0.removeFirst()
                }
            }
        )
    }

    private func chatGPTStreamFailureRequests(
        _ task: ChatGPTSubscriptionTestWebSocketTask
    ) throws -> [[String: Any]] {
        try task.sentMessages.compactMap { message in
            guard case let .text(text) = message else { return nil }
            return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
    }

    private func chatGPTStreamFailurePreviousIDs(
        _ task: ChatGPTSubscriptionTestWebSocketTask
    ) throws -> [String?] {
        try chatGPTStreamFailureRequests(task).map { $0["previous_response_id"] as? String }
    }

    private func chatGPTStreamFailureInputCount(_ request: [String: Any]) -> Int {
        (request["input"] as? [Any])?.count ?? -1
    }

    private func chatGPTStreamFailureRunTurn(
        _ client: ChatGPTSubscriptionGenerationClient,
        sessionID: String,
        prompt: String = "hi"
    ) async -> ChatGPTStreamFailureTurn {
        let diagnostics = Mutex<[String]>([])
        do {
            let response = try await client.sendPrompt(
                sessionID: sessionID,
                prompt: prompt,
                attachments: [],
                loadCredentials: {
                    CodexAgentCredentials(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, accountID: "fixture")
                }
            ) { event in
                if case let .diagnostic(value) = event {
                    diagnostics.withLock { $0.append(value) }
                }
            }
            return ChatGPTStreamFailureTurn(response: response, error: nil, diagnostics: diagnostics.withLock { $0 })
        } catch {
            return ChatGPTStreamFailureTurn(response: nil, error: error, diagnostics: diagnostics.withLock { $0 })
        }
    }

    private func chatGPTStreamFailureResponseFailedMessage(_ error: Error?) -> String? {
        guard let error = error as? ChatGPTSubscriptionGenerationError,
              case let .responseFailed(message) = error else {
            return nil
        }
        return message
    }

    // MARK: - Precedence between retries

    @Test(arguments: [true, false])
    func chatGPTStreamFailureInterruptionAndContextLimitEachRetryOnce(interruptionFirst: Bool) async throws {
        let interruption = try chatGPTStreamFailureInterruption()
        let contextLimit = try chatGPTStreamFailureContextLimit()
        let first = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes: interruptionFirst ? interruption : contextLimit)
        let second = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes: interruptionFirst ? contextLimit : interruption)
        let third = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes:
            try chatGPTStreamFailureFrames([chatGPTStreamFailureCompleted(id: "done", text: "Recovered")]))
        let pool = chatGPTStreamFailurePool([first, second, third])
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(configuration: remoteStreamingConfiguration(), webSocketPool: pool)
        await client.createSession(id: "precedence", cwd: FileManager.default.temporaryDirectory.path, history: chatGPTStreamFailureHistory())

        let turn = await chatGPTStreamFailureRunTurn(client, sessionID: "precedence")

        #expect(turn.error == nil)
        #expect(turn.response?.text == "Recovered")
        try #require(turn.diagnostics.count == 2)
        let interruptionIndex = interruptionFirst ? 0 : 1
        #expect(turn.diagnostics[interruptionIndex] == ChatGPTSubscriptionGenerationClient.streamInterruptionRetryDiagnostic())
        #expect(turn.diagnostics[1 - interruptionIndex].hasPrefix(Self.chatGPTStreamFailureContextRetryPrefix))
        // Every attempt is a full replay on a fresh connection.
        #expect(try chatGPTStreamFailurePreviousIDs(first) == [nil])
        #expect(try chatGPTStreamFailurePreviousIDs(second) == [nil])
        #expect(try chatGPTStreamFailurePreviousIDs(third) == [nil])
        // The request after the context-limit retry carries the compacted history.
        let contextLimitSocket = interruptionFirst ? second : first
        let contextLimitInput = chatGPTStreamFailureInputCount(try #require(try chatGPTStreamFailureRequests(contextLimitSocket).first))
        let finalInput = chatGPTStreamFailureInputCount(try #require(try chatGPTStreamFailureRequests(third).first))
        #expect(finalInput < contextLimitInput)
        #expect(first.cancelCount > 0)
        #expect(second.cancelCount > 0)
        #expect(await client.chatGPTStreamFailureContinuationID("precedence") == "done")
    }

    @Test
    func chatGPTStreamFailureContinuationUnavailableDuringReplayFallsBackToFullReplay() async throws {
        let first = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes:
            try chatGPTStreamFailureFrames([
                chatGPTStreamFailureCompleted(id: "first", text: "One"),
                chatGPTStreamFailureErrorEvent(code: "invalid_request_error", message: Self.chatGPTStreamFailureContinuationMessage)
            ]))
        let second = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes:
            try chatGPTStreamFailureFrames([chatGPTStreamFailureCompleted(id: "second", text: "Two")]))
        let pool = chatGPTStreamFailurePool([first, second])
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(configuration: remoteStreamingConfiguration(), webSocketPool: pool)
        await client.createSession(id: "replay", cwd: FileManager.default.temporaryDirectory.path)

        let firstTurn = await chatGPTStreamFailureRunTurn(client, sessionID: "replay")
        #expect(firstTurn.error == nil)
        #expect(firstTurn.response?.text == "One")
        #expect(firstTurn.diagnostics.isEmpty)
        #expect(await client.chatGPTStreamFailureContinuationID("replay") == "first")

        let secondTurn = await chatGPTStreamFailureRunTurn(client, sessionID: "replay", prompt: "again")

        #expect(secondTurn.error == nil)
        #expect(secondTurn.response?.text == "Two")
        #expect(secondTurn.diagnostics == [ChatGPTSubscriptionGenerationClient.continuationReplayFallbackDiagnostic()])
        // The continuation request used previous_response_id on the reused
        // socket; the fallback replays the whole conversation on a new one.
        #expect(try chatGPTStreamFailurePreviousIDs(first) == [nil, "first"])
        let replay = try chatGPTStreamFailureRequests(second)
        #expect(replay.map { $0["previous_response_id"] as? String } == [nil])
        let replayJSON = String(decoding: try JSONSerialization.data(withJSONObject: try #require(replay.first)), as: UTF8.self)
        #expect(replayJSON.contains("One"))
        #expect(replayJSON.contains("again"))
        #expect(first.cancelCount > 0)
        #expect(await client.chatGPTStreamFailureContinuationID("replay") == "second")
    }

    @Test
    func chatGPTStreamFailureContinuationUnavailableWithoutReplayRethrows() async throws {
        let first = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes:
            try chatGPTStreamFailureFrames([
                chatGPTStreamFailureErrorEvent(code: "invalid_request_error", message: Self.chatGPTStreamFailureContinuationMessage)
            ]))
        let pool = chatGPTStreamFailurePool([first])
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(configuration: remoteStreamingConfiguration(), webSocketPool: pool)
        await client.createSession(id: "no-replay", cwd: FileManager.default.temporaryDirectory.path)

        let turn = await chatGPTStreamFailureRunTurn(client, sessionID: "no-replay")

        #expect(turn.response == nil)
        #expect(chatGPTStreamFailureResponseFailedMessage(turn.error)?.contains("not found") == true)
        #expect(turn.diagnostics.isEmpty)
        #expect(try chatGPTStreamFailurePreviousIDs(first) == [nil])
    }

    @Test
    func chatGPTStreamFailureInterruptionAfterConsumedRetryRethrows() async throws {
        let first = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes: try chatGPTStreamFailureInterruption())
        let second = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes: try chatGPTStreamFailureInterruption())
        let pool = chatGPTStreamFailurePool([first, second])
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(configuration: remoteStreamingConfiguration(), webSocketPool: pool)
        await client.createSession(id: "interrupted", cwd: FileManager.default.temporaryDirectory.path)

        let turn = await chatGPTStreamFailureRunTurn(client, sessionID: "interrupted")

        #expect(turn.response == nil)
        let failure = try #require(turn.error as? ChatGPTSubscriptionResponsesClient.ReplayUnsafeStreamFailure)
        #expect(failure.underlying as? RemoteTransportError == .closed)
        #expect(turn.diagnostics == [ChatGPTSubscriptionGenerationClient.streamInterruptionRetryDiagnostic()])
        #expect(try chatGPTStreamFailurePreviousIDs(first) == [nil])
        #expect(try chatGPTStreamFailurePreviousIDs(second) == [nil])
        #expect(await client.chatGPTStreamFailureContinuationID("interrupted") == nil)
    }

    @Test
    func chatGPTStreamFailureInterruptionBudgetResetsAfterCompletedRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes: try chatGPTStreamFailureInterruption())
        let second = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes:
            try chatGPTStreamFailureFrames([chatGPTStreamFailureToolCall(id: "tool")])
            + chatGPTStreamFailureInterruption())
        let third = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes:
            try chatGPTStreamFailureFrames([chatGPTStreamFailureCompleted(id: "final", text: "Done")]))
        let pool = chatGPTStreamFailurePool([first, second, third])
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(configuration: remoteStreamingConfiguration(), webSocketPool: pool)
        await client.createSession(id: "reset", cwd: directory.path, allowedToolNames: ["local.pwd"])

        let turn = await chatGPTStreamFailureRunTurn(client, sessionID: "reset")

        #expect(turn.error == nil)
        #expect(turn.response?.text == "Done")
        #expect(turn.diagnostics == [
            ChatGPTSubscriptionGenerationClient.streamInterruptionRetryDiagnostic(),
            ChatGPTSubscriptionGenerationClient.streamInterruptionRetryDiagnostic()
        ])
        #expect(try chatGPTStreamFailurePreviousIDs(first) == [nil])
        // The tool round continued on the reused socket before it failed.
        #expect(try chatGPTStreamFailurePreviousIDs(second) == [nil, "tool"])
        let replay = try chatGPTStreamFailureRequests(third)
        #expect(replay.map { $0["previous_response_id"] as? String } == [nil])
        let replayJSON = String(decoding: try JSONSerialization.data(withJSONObject: try #require(replay.first)), as: UTF8.self)
        #expect(replayJSON.contains("call_tool"))
        #expect(replayJSON.contains("function_call_output"))
        let snapshot = try #require(await client.snapshotSession(id: "reset"))
        #expect(snapshot.history.flatMap(\.toolCalls).compactMap(\.id) == ["call_tool"])
        #expect(await client.chatGPTStreamFailureContinuationID("reset") == "final")
    }

    @Test
    func chatGPTStreamFailureContextLimitRetriesOnlyOnce() async throws {
        let first = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes: try chatGPTStreamFailureContextLimit())
        let second = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes: try chatGPTStreamFailureContextLimit())
        let pool = chatGPTStreamFailurePool([first, second])
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(configuration: remoteStreamingConfiguration(), webSocketPool: pool)
        await client.createSession(id: "context", cwd: FileManager.default.temporaryDirectory.path, history: chatGPTStreamFailureHistory())

        let turn = await chatGPTStreamFailureRunTurn(client, sessionID: "context")

        #expect(turn.response == nil)
        #expect(chatGPTStreamFailureResponseFailedMessage(turn.error) == Self.chatGPTStreamFailureContextLimitMessage)
        try #require(turn.diagnostics.count == 1)
        #expect(turn.diagnostics[0].hasPrefix(Self.chatGPTStreamFailureContextRetryPrefix))
        #expect(try chatGPTStreamFailurePreviousIDs(first) == [nil])
        #expect(try chatGPTStreamFailurePreviousIDs(second) == [nil])
        let originalInput = chatGPTStreamFailureInputCount(try #require(try chatGPTStreamFailureRequests(first).first))
        let retryInput = chatGPTStreamFailureInputCount(try #require(try chatGPTStreamFailureRequests(second).first))
        #expect(retryInput < originalInput)
    }

    @Test
    func chatGPTStreamFailureContextLimitWithoutCompactableHistoryReportsUnavailable() async throws {
        let first = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes: try chatGPTStreamFailureContextLimit())
        let pool = chatGPTStreamFailurePool([first])
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(configuration: remoteStreamingConfiguration(), webSocketPool: pool)
        await client.createSession(id: "uncompactable", cwd: FileManager.default.temporaryDirectory.path)

        let turn = await chatGPTStreamFailureRunTurn(client, sessionID: "uncompactable")

        #expect(turn.response == nil)
        #expect(chatGPTStreamFailureResponseFailedMessage(turn.error) == Self.chatGPTStreamFailureContextLimitMessage)
        #expect(turn.diagnostics == [ChatGPTSubscriptionGenerationClient.contextLimitRetryUnavailableDiagnostic()])
        #expect(try chatGPTStreamFailurePreviousIDs(first) == [nil])
    }

    /// A replay-unsafe failure that is not a transient interruption is never
    /// retried, not even when its underlying error is a context-limit refusal.
    @Test(arguments: [false, true])
    func chatGPTStreamFailureReplayUnsafeNonRetryableRethrows(contextLimitUnderlying: Bool) async throws {
        let outcomes: [Result<ChatGPTSubscriptionWebSocketMessage, Error>] = contextLimitUnderlying
            ? try chatGPTStreamFailureFrames([chatGPTStreamFailureDelta()]) + chatGPTStreamFailureContextLimit()
            : try chatGPTStreamFailureFrames([chatGPTStreamFailureDelta()])
                + [.failure(RemoteTransportError.protocolViolation("fixture"))]
        let first = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes: outcomes)
        let pool = chatGPTStreamFailurePool([first])
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(configuration: remoteStreamingConfiguration(), webSocketPool: pool)
        await client.createSession(id: "unsafe", cwd: FileManager.default.temporaryDirectory.path, history: chatGPTStreamFailureHistory())

        let turn = await chatGPTStreamFailureRunTurn(client, sessionID: "unsafe")

        #expect(turn.response == nil)
        let failure = try #require(turn.error as? ChatGPTSubscriptionResponsesClient.ReplayUnsafeStreamFailure)
        if contextLimitUnderlying {
            #expect(chatGPTStreamFailureResponseFailedMessage(failure.underlying) == Self.chatGPTStreamFailureContextLimitMessage)
        } else {
            #expect(failure.underlying as? RemoteTransportError == .protocolViolation("fixture"))
        }
        #expect(turn.diagnostics.isEmpty)
        #expect(try chatGPTStreamFailurePreviousIDs(first) == [nil])
    }

    @Test
    func chatGPTStreamFailureUnsatisfiableBudgetIsReportedOncePerTurnAcrossRounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes:
            try chatGPTStreamFailureFrames([
                chatGPTStreamFailureToolCall(id: "round"),
                chatGPTStreamFailureCompleted(id: "turn", text: "Done"),
                chatGPTStreamFailureCompleted(id: "next", text: "Again")
            ]))
        let pool = chatGPTStreamFailurePool([socket])
        defer { pool.closeAll() }
        // The reserved output alone exceeds this window, so every request of
        // every round is unsatisfiable.
        let configuration = AgentRuntimeConfiguration(
            modelID: "unit-model",
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            configuredContextWindowLimit: 10_000,
            maxToolRounds: 4,
            toolAuthorizationHandler: nil
        )
        let client = ChatGPTSubscriptionGenerationClient(configuration: configuration, webSocketPool: pool)
        await client.createSession(id: "budget", cwd: directory.path, allowedToolNames: ["local.pwd"])

        let firstTurn = await chatGPTStreamFailureRunTurn(client, sessionID: "budget")

        #expect(firstTurn.error == nil)
        #expect(firstTurn.response?.text == "Done")
        try #require(firstTurn.diagnostics.count == 1)
        #expect(firstTurn.diagnostics[0].hasPrefix(Self.chatGPTStreamFailureUnsatisfiablePrefix))
        #expect(try chatGPTStreamFailurePreviousIDs(socket) == [nil, "round"])

        let secondTurn = await chatGPTStreamFailureRunTurn(client, sessionID: "budget", prompt: "again")

        #expect(secondTurn.error == nil)
        #expect(secondTurn.response?.text == "Again")
        #expect(secondTurn.diagnostics == firstTurn.diagnostics)
        #expect(try chatGPTStreamFailurePreviousIDs(socket) == [nil, "round", "turn"])
    }

    /// Only the provider-wire estimate (inflated by the escaped, multi-scalar
    /// history) overflows the window, so the start-of-round compaction stays
    /// idle and the preflight compacts exactly once before the single request.
    @Test
    func chatGPTStreamFailurePreflightCompactsOnceBeforeTheRequest() async throws {
        let payload = String(repeating: "👩🏽‍💻\u{301}", count: 64) + "\\\"\n"
        let history = (0..<12).map { index in
            AgentRuntimeMessage(
                role: index.isMultiple(of: 2) ? .user : .assistant,
                content: "unicode wire turn \(index): " + String(repeating: payload, count: 4)
            )
        }
        let socket = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes:
            try chatGPTStreamFailureFrames([chatGPTStreamFailureCompleted(id: "fit", text: "Fit")]))
        let pool = chatGPTStreamFailurePool([socket])
        defer { pool.closeAll() }
        let configuration = AgentRuntimeConfiguration(
            modelID: "unit-model",
            workingDirectory: URL(fileURLWithPath: "/tmp/project", isDirectory: true),
            configuredContextWindowLimit: 26_000,
            maxToolRounds: 4,
            toolAuthorizationHandler: nil
        )
        let client = ChatGPTSubscriptionGenerationClient(configuration: configuration, webSocketPool: pool)
        await client.createSession(
            id: "preflight",
            cwd: FileManager.default.temporaryDirectory.path,
            systemPrompt: "System prompt",
            history: history,
            allowedToolNames: ["local.pwd"]
        )
        let originalCount = try #require(await client.chatGPTStreamFailureMessageCount("preflight"))
        #expect(await client.chatGPTStreamFailureStartOfRoundCompacts("preflight") == false)
        // The symmetric precondition: the provider-wire estimate of the same
        // history does overflow. A recalibration of either estimator then fails
        // here, with this message, instead of as a puzzling missing compaction.
        let wire = try #require(await client.chatGPTStreamFailureWireEstimate("preflight"))
        #expect(
            wire.estimate > wire.budget,
            "The provider-wire estimate (\(wire.estimate) tokens) no longer exceeds the prompt budget (\(wire.budget)): the estimator was recalibrated and this fixture no longer reaches the preflight."
        )

        let turn = await chatGPTStreamFailureRunTurn(client, sessionID: "preflight")

        #expect(turn.error == nil)
        #expect(turn.response?.text == "Fit")
        try #require(turn.diagnostics.count == 1)
        #expect(turn.diagnostics[0].hasPrefix("Compacted conversation history from "))
        let requests = try chatGPTStreamFailureRequests(socket)
        #expect(requests.map { $0["previous_response_id"] as? String } == [nil])
        let input = chatGPTStreamFailureInputCount(try #require(requests.first))
        #expect(input > 0)
        #expect(input < originalCount)
        #expect(await client.chatGPTStreamFailureContinuationID("preflight") == "fit")
    }

    // MARK: - Classification predicates (credential refresh stays offline)

    /// 401/403 are characterized on the predicates that drive the retry: an
    /// end-to-end run would reach the real token refresh endpoint.
    @Test
    func chatGPTStreamFailureAuthenticationPredicatesSelectRefreshForRetryable401And403() {
        typealias Client = ChatGPTSubscriptionGenerationClient
        let unauthorized = RemoteTransportError.upgradeRejected(status: 401, body: "")
        let cases: [(error: Error, completedRetries: Int, retries: Bool, refreshes: Bool)] = [
            (unauthorized, 0, true, true),
            (RemoteTransportError.upgradeRejected(status: 403, body: "forbidden"), 0, true, true),
            (ChatGPTSubscriptionGenerationError.http(status: 401, output: "expired"), 0, true, true),
            (ChatGPTSubscriptionGenerationError.http(status: 403, output: ""), 0, true, true),
            (ChatGPTSubscriptionResponsesClient.ReplayUnsafeStreamFailure(underlying: unauthorized), 0, true, true),
            (unauthorized, 1, false, true),
            (RemoteTransportError.upgradeRejected(status: 429, body: ""), 0, false, false),
            (ChatGPTSubscriptionGenerationError.http(status: 500, output: ""), 0, false, false),
            (RemoteTransportError.closed, 0, true, false),
            (ChatGPTSubscriptionResponsesClient.ReplayUnsafeStreamFailure(underlying: RemoteTransportError.closed), 0, true, false)
        ]
        for testCase in cases {
            #expect(
                Client.shouldRetryStreamInterruption(testCase.error, completedRetries: testCase.completedRetries)
                    == testCase.retries,
                "\(testCase.error) after \(testCase.completedRetries) retries"
            )
            #expect(
                Client.isAuthenticationFailure(Client.underlyingStreamInterruptionError(testCase.error))
                    == testCase.refreshes,
                "\(testCase.error)"
            )
        }
        #expect(Client.maxStreamInterruptionRetries == 1)
        #expect(Client.authRefreshDiagnostic().hasPrefix("ChatGPT Subscription returned an authentication error"))
    }

    @Test
    func chatGPTStreamFailureCancellationPredicates() {
        #expect(ChatGPTSubscriptionResponsesClient.isCancellationError(CancellationError()))
        #expect(ChatGPTSubscriptionResponsesClient.isCancellationError(ChatGPTSubscriptionGenerationError.cancelled))
        #expect(ChatGPTSubscriptionResponsesClient.isCancellationError(URLError(.cancelled)))
        #expect(!ChatGPTSubscriptionResponsesClient.isCancellationError(RemoteTransportError.closed))
        #expect(!ChatGPTSubscriptionGenerationClient.isRetryableStreamInterruption(CancellationError()))
    }
}

private extension ChatGPTSubscriptionGenerationClient {
    func chatGPTStreamFailureContinuationID(_ id: String) -> String? {
        sessions[id]?.continuation?.responseID
    }

    func chatGPTStreamFailureMessageCount(_ id: String) -> Int? {
        sessions[id]?.messages.count
    }

    func chatGPTStreamFailureStartOfRoundCompacts(_ id: String) -> Bool? {
        guard let messages = sessions[id]?.messages else { return nil }
        return Self.compactedMessagesIfNeeded(
            messages,
            maxTokens: resolvedContextWindowTokenLimit(),
            maxOutputTokens: configuration.maxOutputTokens
        ).wasCompacted
    }

    /// The provider-wire estimate of the stored history, next to the budget the
    /// preflight holds it to. Measured like the preflight does but without the
    /// tool catalogue and the incoming prompt: the real request can only be
    /// larger, so overflowing here implies overflowing there.
    func chatGPTStreamFailureWireEstimate(_ id: String) -> (estimate: Int, budget: Int)? {
        guard let messages = sessions[id]?.messages,
              let budget = Self.compactionPolicyMaxTokens(
                  for: resolvedContextWindowTokenLimit(),
                  maxOutputTokens: configuration.maxOutputTokens
              ) else {
            return nil
        }
        let payload = ChatGPTSubscriptionRequestBuilder.chatGPTResponsesInputPayload(from: messages)
        let estimate = Self.requestEstimate(
            instructions: payload.instructions,
            fullHistoryInput: payload.input,
            toolPayloads: []
        )
        return (estimate.totalTokens, budget)
    }
}
