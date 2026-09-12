import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

extension RemoteSessionSnapshotTests {
    private func subscriptionRecoveryCredentials() async throws -> CodexAgentCredentials {
        CodexAgentCredentials(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, accountID: "fixture")
    }

    private func subscriptionRecoveryFrames(
        id: String, text: String = "Hello", thought: String = "Thinking",
        arguments: String? = nil, appendPath: String? = nil, mixed: Bool = false,
        completedText: Bool = true
    ) throws -> [Result<ChatGPTSubscriptionWebSocketMessage, Error>] {
        let toolName = appendPath == nil ? "local.pwd" : "local.append"
        var output: [[String: Any]] = []
        if completedText {
            output.append(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]])
        }
        if let arguments {
            output.append(["type": "function_call", "id": "fc_\(id)", "call_id": "call_\(id)", "name": toolName, "arguments": arguments])
        }
        if mixed {
            output.append(["type": "function_call", "id": "fc_rejected_valid", "call_id": "rejected_valid", "name": "local.pwd", "arguments": "{}"])
        }
        let events: [[String: Any]] = [
            ["type": "response.reasoning_text.delta", "delta": thought],
            ["type": "response.output_text.delta", "delta": text],
            ["type": "response.completed", "response": ["id": id, "status": "completed", "output": output]]
        ]
        return try events.map {
            .success(.text(String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)))
        }
    }

    private func subscriptionRecoveryPool(_ tasks: [ChatGPTSubscriptionTestWebSocketTask]) -> ChatGPTSubscriptionWebSocketPool {
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

    private func subscriptionRecoveryRequests(_ task: ChatGPTSubscriptionTestWebSocketTask) throws -> [[String: Any]] {
        try task.sentMessages.compactMap { message in
            guard case let .text(text) = message else { return nil }
            return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
    }

    @Test(arguments: [false, true], [false, true])
    func subscriptionMalformedRoundRetriesWithoutDuplicatePrefixes(divergent: Bool, fallback: Bool) async throws {
        let first = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes: try subscriptionRecoveryFrames(id: "invalid", arguments: "{", mixed: true))
        let retryText = divergent ? "Help" : "Hello"
        let retryThought = divergent ? "Think again" : "Thinking"
        let second = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes:
            try subscriptionRecoveryFrames(id: "valid", text: retryText, thought: retryThought, arguments: "{}", completedText: !fallback)
            + subscriptionRecoveryFrames(id: "final", text: "Done", thought: "Next"))
        let pool = subscriptionRecoveryPool([first, second])
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(configuration: remoteStreamingConfiguration(), webSocketPool: pool)
        await client.createSession(id: "recovery", cwd: FileManager.default.temporaryDirectory.path, allowedToolNames: ["local.pwd"])
        let content = Mutex("")
        let thought = Mutex("")
        let calls = Mutex<[String]>([])
        let response = try await client.sendPrompt(sessionID: "recovery", prompt: "hi", attachments: [], loadCredentials: subscriptionRecoveryCredentials) { event in
            switch event {
            case let .content(value): content.withLock { $0 += value }
            case let .thought(value): thought.withLock { $0 += value }
            case let .toolCallStarted(call): calls.withLock { $0.append(call.id) }
            case let .diagnostic(value) where value.contains("Invalid tool arguments"):
                // Output must already be visible before regeneration starts.
                #expect(content.withLock { $0 } == "Hello")
                #expect(thought.withLock { $0 } == "Thinking")
                #expect(calls.withLock { $0.isEmpty })
                #expect(await client.subscriptionRecoveryContinuationID("recovery") == nil)
            default: break
            }
        }
        #expect(response.text == retryText + "Done")
        #expect(content.withLock { $0 } == (divergent ? "HellopDone" : "HelloDone"))
        #expect(thought.withLock { $0 } == (divergent ? "Thinking againNext" : "ThinkingNext"))
        #expect(calls.withLock { $0 } == ["call_valid"])
        #expect(first.cancelCount > 0)
        let requests = try subscriptionRecoveryRequests(second)
        #expect(requests.count == 2)
        #expect(requests.first?["previous_response_id"] == nil)
        #expect(requests.last?["previous_response_id"] as? String == "valid")
        let retryJSON = String(decoding: try JSONSerialization.data(withJSONObject: requests[0]), as: UTF8.self)
        #expect(!retryJSON.contains("invalid"))
        #expect(!retryJSON.contains("rejected_valid"))
        let snapshot = try #require(await client.snapshotSession(id: "recovery"))
        #expect(snapshot.history.flatMap(\.toolCalls).compactMap(\.id) == ["call_valid"])
        #expect(!snapshot.history.contains { $0.content == "Hello" && divergent })
        #expect(await client.subscriptionRecoveryContinuationID("recovery") == "final")
    }

    @Test
    func subscriptionRetryBudgetSpansToolRoundsWithoutRepeatingMutation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("counter.txt")
        try Data().write(to: file)
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["path": file.path, "content": "once"]), as: UTF8.self)
        let first = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes:
            try subscriptionRecoveryFrames(id: "mutation", arguments: arguments, appendPath: file.path)
            + subscriptionRecoveryFrames(id: "invalid_first", arguments: "{"))
        let second = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes:
            try subscriptionRecoveryFrames(id: "valid", arguments: "{}")
            + subscriptionRecoveryFrames(id: "invalid_second", arguments: "{"))
        let pool = subscriptionRecoveryPool([first, second])
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(configuration: remoteStreamingConfiguration(), webSocketPool: pool)
        await client.createSession(id: "budget", cwd: directory.path, allowedToolNames: ["local.append", "local.pwd"])
        let calls = Mutex<[String]>([])
        do {
            _ = try await client.sendPrompt(sessionID: "budget", prompt: "hi", attachments: [], loadCredentials: subscriptionRecoveryCredentials) { event in
                if case let .toolCallStarted(call) = event { calls.withLock { $0.append(call.id) } }
            }
            Issue.record("Expected exhausted invalid-arguments budget")
        } catch RemoteGenerationClientError.invalidToolArguments {}
        #expect(try String(contentsOf: file, encoding: .utf8) == "once")
        #expect(calls.withLock { $0 } == ["call_mutation", "call_valid"])
        #expect(try subscriptionRecoveryRequests(first).count == 2)
        let retryRequests = try subscriptionRecoveryRequests(second)
        #expect(retryRequests.count == 2)
        #expect(retryRequests[0]["previous_response_id"] == nil)
        let retryJSON = String(decoding: try JSONSerialization.data(withJSONObject: retryRequests[0]), as: UTF8.self)
        #expect(retryJSON.contains("call_mutation"))
        #expect(retryJSON.contains("function_call_output"))
        #expect(!retryJSON.contains("invalid_first"))
        #expect(first.cancelCount > 0)
        #expect(second.cancelCount > 0)
        #expect(await client.subscriptionRecoveryContinuationID("budget") == nil)
        let snapshot = try #require(await client.snapshotSession(id: "budget"))
        #expect(snapshot.history.flatMap(\.toolCalls).compactMap(\.id) == ["call_mutation", "call_valid"])
        #expect(snapshot.history.filter { $0.role == .tool }.compactMap(\.toolCallID) == ["call_mutation", "call_valid"])
    }

    @Test(arguments: [false, true])
    func subscriptionCancellationOrResetAtRetryDoesNotStartAnotherRequest(reset: Bool) async throws {
        let first = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes: try subscriptionRecoveryFrames(id: "invalid", arguments: "{"))
        let pool = subscriptionRecoveryPool([first])
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(configuration: remoteStreamingConfiguration(), webSocketPool: pool)
        await client.createSession(id: "cancel", cwd: FileManager.default.temporaryDirectory.path, allowedToolNames: ["local.pwd"])
        let task = Task {
            try await client.sendPrompt(sessionID: "cancel", prompt: "hi", attachments: [], loadCredentials: subscriptionRecoveryCredentials) { event in
                if case let .diagnostic(value) = event, value.contains("Invalid tool arguments") {
                    if reset {
                        await client.createSession(id: "cancel", cwd: FileManager.default.temporaryDirectory.path)
                    } else {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation or stale session")
        } catch is CancellationError {
            #expect(!reset)
        } catch ChatGPTSubscriptionGenerationError.missingSession {
            #expect(reset)
        }
        #expect(try subscriptionRecoveryRequests(first).count == 1)
        #expect(first.cancelCount > 0)
        #expect(await client.subscriptionRecoveryContinuationID("cancel") == nil)
        let snapshot = try #require(await client.snapshotSession(id: "cancel"))
        #expect(!snapshot.history.contains { $0.role == .assistant || $0.role == .tool })
    }
}

private extension ChatGPTSubscriptionGenerationClient {
    func subscriptionRecoveryContinuationID(_ id: String) -> String? {
        sessions[id]?.continuation?.responseID
    }
}
