//
//  SubscriptionToolBatchCancellationTests.swift
//  ZenCODECoreTests
//
//  Cancellation of a committed tool-call batch in the subscription clients:
//  no further tool runs after Stop, every call is paired with a result, and a
//  following prompt resumes without re-executing anything.
//

import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

extension RemoteSessionSnapshotTests {
    private static let batchCancellationIDs = ["batch_0", "batch_1", "batch_2"]

    private func batchCancellationArguments(path: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: ["path": path, "content": "once"]), as: UTF8.self)
    }

    /// Cancels the current task at boundary 0/1 (start of the first/middle
    /// tool) or 2/3 (completion of the first/last tool).
    private func batchCancellationEventHandler(
        boundary: Int,
        log: BatchCancellationEventLog
    ) -> @Sendable (DirectAgentEvent) async -> Void {
        { event in
            switch event {
            case let .toolCallStarted(call):
                log.started.withLock { $0.append(call.id) }
                if (boundary == 0 && call.id == "batch_0") || (boundary == 1 && call.id == "batch_1") {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            case let .toolCallCompleted(call, _):
                log.completed.withLock { $0.append(call.id) }
                if (boundary == 2 && call.id == "batch_0") || (boundary == 3 && call.id == "batch_2") {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            default: break
            }
        }
    }

    private func batchCancellationExecutedCount(boundary: Int) -> Int {
        boundary == 0 ? 0 : (boundary == 3 ? 3 : 1)
    }

    private func expectBatchCancellationTranscript(
        _ snapshot: AgentRuntimeSessionSnapshot,
        executed: Int
    ) {
        let calls = snapshot.history.flatMap(\.toolCalls).compactMap(\.id)
        let results = snapshot.history.filter { $0.role == .tool }
        #expect(calls == Self.batchCancellationIDs)
        #expect(results.compactMap(\.toolCallID) == calls)
        for (index, result) in results.enumerated() {
            #expect(result.content.contains("cancelled before dispatch") == (index >= executed))
        }
    }

    // MARK: ChatGPT Subscription

    private func chatGPTBatchCancellationFrames(
        id: String,
        functionCalls: [(callID: String, arguments: String)],
        text: String? = nil
    ) throws -> [Result<ChatGPTSubscriptionWebSocketMessage, Error>] {
        var output: [[String: Any]] = []
        if let text {
            output.append(["type": "message", "role": "assistant", "content": [["type": "output_text", "text": text]]])
        }
        for (index, call) in functionCalls.enumerated() {
            output.append(["type": "function_call", "id": "fc_\(index)", "call_id": call.callID, "name": "local.append", "arguments": call.arguments])
        }
        var events: [[String: Any]] = []
        if let text {
            events.append(["type": "response.output_text.delta", "delta": text])
        }
        events.append(["type": "response.completed", "response": ["id": id, "status": "completed", "output": output]])
        return try events.map {
            .success(.text(String(decoding: try JSONSerialization.data(withJSONObject: $0), as: UTF8.self)))
        }
    }

    private func chatGPTBatchCancellationPool(_ task: ChatGPTSubscriptionTestWebSocketTask) -> ChatGPTSubscriptionWebSocketPool {
        let pending = Mutex([task])
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

    private func chatGPTBatchCancellationRequests(_ task: ChatGPTSubscriptionTestWebSocketTask) throws -> [[String: Any]] {
        try task.sentMessages.compactMap { message in
            guard case let .text(text) = message else { return nil }
            return try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func chatGPTSubscriptionCancellationClosesCommittedToolBatchAndResumes(boundary: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("counter.txt")
        try Data().write(to: file)
        let arguments = try batchCancellationArguments(path: file.path)
        let socket = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes:
            try chatGPTBatchCancellationFrames(
                id: "batch",
                functionCalls: Self.batchCancellationIDs.map { ($0, arguments) }
            )
            + chatGPTBatchCancellationFrames(id: "resumed", functionCalls: [], text: "Resumed"))
        let pool = chatGPTBatchCancellationPool(socket)
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(configuration: remoteStreamingConfiguration(), webSocketPool: pool)
        await client.createSession(id: "batch", cwd: directory.path, allowedToolNames: ["local.append"])
        let credentials: @Sendable () async throws -> CodexAgentCredentials = {
            CodexAgentCredentials(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, accountID: "fixture")
        }
        let log = BatchCancellationEventLog()
        let onEvent = batchCancellationEventHandler(boundary: boundary, log: log)
        let task = Task {
            try await client.sendPrompt(
                sessionID: "batch", prompt: "hi", attachments: [],
                loadCredentials: credentials, onEvent: onEvent
            )
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        let executed = batchCancellationExecutedCount(boundary: boundary)
        let expectedContent = String(repeating: "once", count: executed)
        #expect(try String(contentsOf: file, encoding: .utf8) == expectedContent)
        #expect(try chatGPTBatchCancellationRequests(socket).count == 1)
        #expect(log.started.withLock { $0.count } == (boundary == 1 ? 2 : max(1, executed)))
        #expect(log.completed.withLock { $0 } == Self.batchCancellationIDs)
        expectBatchCancellationTranscript(
            try #require(await client.snapshotSession(id: "batch")),
            executed: executed
        )

        let response = try await client.sendPrompt(
            sessionID: "batch", prompt: "continue", attachments: [],
            loadCredentials: credentials
        ) { _ in }
        #expect(response.text == "Resumed")
        #expect(try String(contentsOf: file, encoding: .utf8) == expectedContent)
        let requests = try chatGPTBatchCancellationRequests(socket)
        #expect(requests.count == 2)
        // The resumed request continues the committed response and carries a
        // function_call_output for every call of the closed batch.
        let resumed = try #require(requests.last)
        #expect(resumed["previous_response_id"] as? String == "batch")
        let input = try #require(resumed["input"] as? [[String: Any]])
        let outputs = input.filter { $0["type"] as? String == "function_call_output" }
        #expect(outputs.compactMap { $0["call_id"] as? String } == Self.batchCancellationIDs)
        for (index, output) in outputs.enumerated() {
            let serialized = String(decoding: try JSONSerialization.data(withJSONObject: output), as: UTF8.self)
            #expect(serialized.contains("cancelled before dispatch") == (index >= executed))
        }
        #expect(!input.contains { $0["type"] as? String == "function_call" })
        let resumedJSON = String(decoding: try JSONSerialization.data(withJSONObject: resumed), as: UTF8.self)
        #expect(resumedJSON.contains("continue"))
        #expect(socket.cancelCount == 0)
    }

    // MARK: Anthropic Subscription

    private func anthropicBatchCancellationBody(appendPath: String) throws -> Data {
        let arguments = try batchCancellationArguments(path: appendPath)
        var events: [[String: Any]] = [
            ["type": "message_start", "message": ["usage": ["input_tokens": 3, "output_tokens": 0]]]
        ]
        for (index, id) in Self.batchCancellationIDs.enumerated() {
            events += [
                ["type": "content_block_start", "index": index, "content_block": ["type": "tool_use", "id": id, "name": "local.append", "input": [:]]],
                ["type": "content_block_delta", "index": index, "delta": ["type": "input_json_delta", "partial_json": arguments]],
                ["type": "content_block_stop", "index": index]
            ]
        }
        events += [
            ["type": "message_delta", "delta": ["stop_reason": "tool_use"], "usage": ["output_tokens": 1]],
            ["type": "message_stop"]
        ]
        return try anthropicBatchCancellationSSE(events)
    }

    private func anthropicBatchCancellationTextBody(_ text: String) throws -> Data {
        try anthropicBatchCancellationSSE([
            ["type": "message_start", "message": ["usage": ["input_tokens": 3, "output_tokens": 0]]],
            ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": text]],
            ["type": "message_delta", "delta": ["stop_reason": "end_turn"], "usage": ["output_tokens": 1]],
            ["type": "message_stop"]
        ])
    }

    private func anthropicBatchCancellationSSE(_ events: [[String: Any]]) throws -> Data {
        try events.reduce(into: Data()) { data, event in
            data.append(Data("data: ".utf8))
            data.append(try JSONSerialization.data(withJSONObject: event))
            data.append(Data("\n\n".utf8))
        }
    }

    /// `tool_result` blocks of an Anthropic request, in wire order.
    private func anthropicBatchCancellationToolResults(_ payload: [String: Any]) -> [[String: Any]] {
        let messages = payload["messages"] as? [[String: Any]] ?? []
        return messages.flatMap { message -> [[String: Any]] in
            guard let content = message["content"] as? [[String: Any]] else { return [] }
            return content.filter { $0["type"] as? String == "tool_result" }
        }
    }

    @Test(arguments: [0, 1, 2, 3])
    func anthropicSubscriptionCancellationClosesCommittedToolBatchAndResumes(boundary: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("counter.txt")
        try Data().write(to: file)
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: anthropicBatchCancellationTextBody("Resumed"),
            responseSequence: [anthropicBatchCancellationBody(appendPath: file.path)]
        )
        defer { fixture.beginShutdown() }
        let client = AnthropicSubscriptionGenerationClient(
            configuration: AgentRuntimeConfiguration(
                modelID: "claude-haiku-4-5",
                workingDirectory: directory,
                maxToolRounds: 4,
                toolAuthorizationHandler: nil
            ),
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
        await client.createSession(id: "batch", cwd: directory.path, allowedToolNames: ["local.append"])
        let log = BatchCancellationEventLog()
        let onEvent = batchCancellationEventHandler(boundary: boundary, log: log)
        let task = Task {
            try await client.sendPrompt(sessionID: "batch", prompt: "hi", attachments: [], onEvent: onEvent)
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        let executed = batchCancellationExecutedCount(boundary: boundary)
        let expectedContent = String(repeating: "once", count: executed)
        #expect(try String(contentsOf: file, encoding: .utf8) == expectedContent)
        #expect(fixture.capturedRequests().count == 1)
        #expect(log.started.withLock { $0.count } == (boundary == 1 ? 2 : max(1, executed)))
        #expect(log.completed.withLock { $0 } == Self.batchCancellationIDs)
        expectBatchCancellationTranscript(
            try #require(await client.snapshotSession(id: "batch")),
            executed: executed
        )

        let response = try await client.sendPrompt(sessionID: "batch", prompt: "continue", attachments: []) { _ in }
        #expect(response.text == "Resumed")
        #expect(fixture.capturedRequests().count == 2)
        #expect(try String(contentsOf: file, encoding: .utf8) == expectedContent)
        // The resumed request pairs every tool_use of the batch with a result.
        let resumed = try #require(fixture.capturedRequests().last).jsonObject()
        let toolResults = anthropicBatchCancellationToolResults(resumed)
        #expect(toolResults.compactMap { $0["tool_use_id"] as? String } == Self.batchCancellationIDs)
        for (index, result) in toolResults.enumerated() {
            let serialized = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
            #expect(serialized.contains("cancelled before dispatch") == (index >= executed))
        }
        await client.shutdown()
    }

    // MARK: Last allowed tool round

    /// A configuration whose only permitted tool round is the batch under test.
    private func batchCancellationLastRoundConfiguration(directory: URL) -> AgentRuntimeConfiguration {
        AgentRuntimeConfiguration(
            modelID: "unit-model",
            workingDirectory: directory,
            maxToolRounds: 1,
            toolAuthorizationHandler: nil
        )
    }

    @Test
    func chatGPTSubscriptionCancellationAtLastAllowedToolRoundIsNotTooManyToolRounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("counter.txt")
        try Data().write(to: file)
        let arguments = try batchCancellationArguments(path: file.path)
        let socket = ChatGPTSubscriptionTestWebSocketTask(receiveOutcomes:
            try chatGPTBatchCancellationFrames(
                id: "batch",
                functionCalls: Self.batchCancellationIDs.map { ($0, arguments) }
            )
            + chatGPTBatchCancellationFrames(id: "resumed", functionCalls: [], text: "Resumed"))
        let pool = chatGPTBatchCancellationPool(socket)
        defer { pool.closeAll() }
        let client = ChatGPTSubscriptionGenerationClient(
            configuration: batchCancellationLastRoundConfiguration(directory: directory),
            webSocketPool: pool
        )
        await client.createSession(id: "batch", cwd: directory.path, allowedToolNames: ["local.append"])
        let credentials: @Sendable () async throws -> CodexAgentCredentials = {
            CodexAgentCredentials(accessToken: "fixture", refreshToken: "fixture", expiresAt: .distantFuture, accountID: "fixture")
        }
        let log = BatchCancellationEventLog()
        // Boundary 3 stops during the completion of the last tool of the batch,
        // which is also the last tool round the configuration allows.
        let onEvent = batchCancellationEventHandler(boundary: 3, log: log)
        let task = Task {
            try await client.sendPrompt(
                sessionID: "batch", prompt: "hi", attachments: [],
                loadCredentials: credentials, onEvent: onEvent
            )
        }
        // Stop wins over the exhausted round budget: CancellationError, never
        // `tooManyToolRounds`.
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let expectedContent = String(repeating: "once", count: 3)
        #expect(try String(contentsOf: file, encoding: .utf8) == expectedContent)
        #expect(log.completed.withLock { $0 } == Self.batchCancellationIDs)
        expectBatchCancellationTranscript(
            try #require(await client.snapshotSession(id: "batch")),
            executed: 3
        )

        let response = try await client.sendPrompt(
            sessionID: "batch", prompt: "continue", attachments: [],
            loadCredentials: credentials
        ) { _ in }
        #expect(response.text == "Resumed")
        #expect(try String(contentsOf: file, encoding: .utf8) == expectedContent)
        let requests = try chatGPTBatchCancellationRequests(socket)
        #expect(requests.count == 2)
        let resumed = try #require(requests.last)
        #expect(resumed["previous_response_id"] as? String == "batch")
        let input = try #require(resumed["input"] as? [[String: Any]])
        let outputs = input.filter { $0["type"] as? String == "function_call_output" }
        #expect(outputs.compactMap { $0["call_id"] as? String } == Self.batchCancellationIDs)
        #expect(!input.contains { $0["type"] as? String == "function_call" })
    }

    @Test
    func anthropicSubscriptionCancellationAtLastAllowedToolRoundIsNotTooManyToolRounds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("counter.txt")
        try Data().write(to: file)
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: anthropicBatchCancellationTextBody("Resumed"),
            responseSequence: [anthropicBatchCancellationBody(appendPath: file.path)]
        )
        defer { fixture.beginShutdown() }
        let client = await anthropicBatchCancellationClient(
            configuration: batchCancellationLastRoundConfiguration(directory: directory),
            fixture: fixture
        )
        await client.createSession(id: "batch", cwd: directory.path, allowedToolNames: ["local.append"])
        let log = BatchCancellationEventLog()
        // Boundary 3 stops during the completion of the last tool of the batch,
        // which is also the last tool round the configuration allows.
        let onEvent = batchCancellationEventHandler(boundary: 3, log: log)
        let task = Task {
            try await client.sendPrompt(sessionID: "batch", prompt: "hi", attachments: [], onEvent: onEvent)
        }
        // Stop wins over the exhausted round budget: CancellationError, never
        // `tooManyToolRounds`.
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        let expectedContent = String(repeating: "once", count: 3)
        #expect(try String(contentsOf: file, encoding: .utf8) == expectedContent)
        #expect(fixture.capturedRequests().count == 1)
        #expect(log.completed.withLock { $0 } == Self.batchCancellationIDs)
        expectBatchCancellationTranscript(
            try #require(await client.snapshotSession(id: "batch")),
            executed: 3
        )

        let response = try await client.sendPrompt(sessionID: "batch", prompt: "continue", attachments: []) { _ in }
        #expect(response.text == "Resumed")
        #expect(fixture.capturedRequests().count == 2)
        #expect(try String(contentsOf: file, encoding: .utf8) == expectedContent)
        let resumed = try #require(fixture.capturedRequests().last).jsonObject()
        let toolResults = anthropicBatchCancellationToolResults(resumed)
        #expect(toolResults.compactMap { $0["tool_use_id"] as? String } == Self.batchCancellationIDs)
        await client.shutdown()
    }

    // MARK: Anthropic request overhead

    @Test
    func anthropicSubscriptionCancellationInvalidatesRequestOverheadWhenClosingPendingCalls() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("counter.txt")
        try Data().write(to: file)
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: anthropicBatchCancellationTextBody("Resumed"),
            responseSequence: [anthropicBatchCancellationBody(appendPath: file.path)]
        )
        defer { fixture.beginShutdown() }
        let client = await anthropicBatchCancellationClient(
            configuration: AgentRuntimeConfiguration(
                modelID: "claude-haiku-4-5",
                workingDirectory: directory,
                maxToolRounds: 4,
                toolAuthorizationHandler: nil
            ),
            fixture: fixture
        )
        await client.createSession(id: "batch", cwd: directory.path, allowedToolNames: ["local.append"])
        let log = BatchCancellationEventLog()
        let standardHandler = batchCancellationEventHandler(boundary: 2, log: log)
        let seededBeforeStop = Mutex(false)
        // The dispatch of a batch starts with no cached overhead (the assistant
        // append already dropped it), so seed an entry right before Stop, as if
        // a request had just measured it, to observe that closing the pending
        // calls invalidates it.
        let onEvent: @Sendable (DirectAgentEvent) async -> Void = { event in
            if case let .toolCallCompleted(call, _) = event, call.id == "batch_0" {
                await client.seedRequestOverhead(sessionID: "batch")
                let hasOverhead = await client.hasRequestOverhead(sessionID: "batch")
                seededBeforeStop.withLock { $0 = hasOverhead }
            }
            await standardHandler(event)
        }
        let task = Task {
            try await client.sendPrompt(sessionID: "batch", prompt: "hi", attachments: [], onEvent: onEvent)
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        #expect(seededBeforeStop.withLock { $0 })
        // One tool ran; the two pending calls were closed by the cancellation.
        expectBatchCancellationTranscript(
            try #require(await client.snapshotSession(id: "batch")),
            executed: 1
        )
        #expect(await client.hasRequestOverhead(sessionID: "batch") == false)
        await client.shutdown()
    }

    private func anthropicBatchCancellationClient(
        configuration: AgentRuntimeConfiguration,
        fixture: RemoteNIOStreamingFixture
    ) async -> AnthropicSubscriptionGenerationClient {
        let client = AnthropicSubscriptionGenerationClient(
            configuration: configuration,
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
        return client
    }
}

/// Tool lifecycle ids observed by a cancellation test's event callback.
private final class BatchCancellationEventLog: Sendable {
    let started = Mutex<[String]>([])
    let completed = Mutex<[String]>([])
}

private extension AnthropicSubscriptionGenerationClient {
    func seedRequestOverhead(sessionID: String) {
        sessionRequestOverhead[sessionID] = SubscriptionCompactionSupport.RequestOverhead(
            staticOverheadTokens: 1_000,
            conversationInflationFactor: 2.0
        )
    }

    func hasRequestOverhead(sessionID: String) -> Bool {
        sessionRequestOverhead[sessionID] != nil
    }
}
