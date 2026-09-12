import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

extension RemoteSessionSnapshotTests {
    private func recoveryBody(_ profile: Int, malformed: Bool, tool: Bool = true, text: String = "Hello", mixed: Bool = false, appendPath: String? = nil) throws -> Data {
        let toolName = appendPath == nil ? "local.pwd" : "local.append"
        let validArguments = try String(decoding: JSONSerialization.data(withJSONObject: appendPath.map { ["path": $0, "content": "once"] } ?? [:]), as: UTF8.self)
        var events: [[String: Any]] = []
        if profile == 2 {
            events = [
                ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]]
            ]
            if tool {
                events += [
                    ["type": "content_block_start", "index": 1, "content_block": ["type": "tool_use", "id": "call_1", "name": toolName, "input": [:]]],
                    ["type": "content_block_delta", "index": 1, "delta": ["type": "input_json_delta", "partial_json": malformed ? "{" : validArguments]]
                ]
            }
            events.append(["type": "message_stop"])
        } else if profile == 1 {
            events = [["type": "response.output_text.delta", "delta": text]]
            if tool {
                events.append(["type": "response.output_item.done", "output_index": 0, "item": ["type": "function_call", "id": "fc_1", "call_id": "call_1", "name": toolName, "arguments": malformed ? "{" : validArguments]])
            }
            events.append(["type": "response.completed", "response": ["output": []]])
        } else {
            var delta: [String: Any] = ["content": text]
            if tool {
                delta["tool_calls"] = [["index": 0, "id": "call_1", "type": "function", "function": ["name": toolName, "arguments": malformed ? "{" : validArguments]]]
            }
            events = [["choices": [["delta": delta, "finish_reason": tool ? "tool_calls" : "stop"]]]]
        }
        if mixed {
            if profile == 2 {
                events.insert(["type": "content_block_start", "index": 2, "content_block": ["type": "tool_use", "id": "valid", "name": toolName, "input": [:]]], at: 0)
            } else if profile == 1 {
                events.insert(["type": "response.output_item.done", "output_index": 2, "item": ["type": "function_call", "id": "fc_valid", "call_id": "valid", "name": toolName, "arguments": "{}"]], at: 0)
            } else {
                events.insert(["choices": [["delta": ["tool_calls": [["index": 2, "id": "valid", "type": "function", "function": ["name": toolName, "arguments": "{}"]]]]]]], at: 0)
            }
        }
        return try events.reduce(into: Data()) { data, event in
            data.append(Data("data: ".utf8))
            data.append(try JSONSerialization.data(withJSONObject: event, options: [.sortedKeys]))
            data.append(Data("\n\n".utf8))
        }
    }

    private func recoveryClient(_ fixture: RemoteNIOStreamingFixture, profile: Int) -> RemoteGenerationClient {
        RemoteGenerationClient(
            configuration: remoteStreamingConfiguration(),
            provider: AgentRemoteProvider(
                name: "Recovery fixture", baseURL: "https://unit.test/v1", modelID: "unit-model",
                chatEndpoint: profile == 1 ? .responses : .chatCompletions,
                protocolProfileID: profile == 2 ? .anthropicMessages : (profile == 1 ? .openAIResponses : .openAIChatCompletions)
            ),
            apiKey: "test-key", transport: fixture.transport,
            streamEndpointBaseURLOverride: fixture.baseURL
        )
    }

    private func recoveryBatchBody(_ profile: Int, appendPath: String) throws -> Data {
        let arguments = String(decoding: try JSONSerialization.data(withJSONObject: ["path": appendPath, "content": "once"]), as: UTF8.self)
        var events: [[String: Any]] = []
        for index in 0..<3 {
            let id = "batch_\(index)"
            if profile == 2 {
                events += [
                    ["type": "content_block_start", "index": index, "content_block": ["type": "tool_use", "id": id, "name": "local.append", "input": [:]]],
                    ["type": "content_block_delta", "index": index, "delta": ["type": "input_json_delta", "partial_json": arguments]],
                    ["type": "content_block_stop", "index": index]
                ]
            } else if profile == 1 {
                events.append(["type": "response.output_item.done", "output_index": index, "item": ["type": "function_call", "id": "fc_\(index)", "call_id": id, "name": "local.append", "arguments": arguments]])
            } else {
                events.append(["choices": [["delta": ["tool_calls": [["index": index, "id": id, "type": "function", "function": ["name": "local.append", "arguments": arguments]]]]]]])
            }
        }
        if profile == 2 {
            events.append(["type": "message_stop"])
        } else if profile == 1 {
            events.append(["type": "response.completed", "response": ["output": []]])
        } else {
            events.append(["choices": [["delta": [:], "finish_reason": "tool_calls"]]])
        }
        return try events.reduce(into: Data()) { data, event in
            data.append(Data("data: ".utf8))
            data.append(try JSONSerialization.data(withJSONObject: event))
            data.append(Data("\n\n".utf8))
        }
    }

    // Start of first/middle tool and completion of first/last tool.
    @Test(arguments: [0, 1, 2], [0, 1, 2, 3])
    func cancellationClosesCommittedToolBatchAndResumes(profile: Int, boundary: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("counter.txt")
        try Data().write(to: file)
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: recoveryBody(profile, malformed: false, tool: false, text: "Resumed"),
            responseSequence: [recoveryBatchBody(profile, appendPath: file.path)]
        )
        defer { fixture.beginShutdown() }
        let client = recoveryClient(fixture, profile: profile)
        await client.createSession(id: "batch", cwd: directory.path, allowedToolNames: ["local.append"])
        let started = Mutex<[String]>([])
        let completed = Mutex<[String]>([])
        let task = Task {
            try await client.sendPrompt(sessionID: "batch", prompt: "hi", attachments: []) { event in
                switch event {
                case let .toolCallStarted(call):
                    started.withLock { $0.append(call.id) }
                    if (boundary == 0 && call.id == "batch_0") || (boundary == 1 && call.id == "batch_1") {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                case let .toolCallCompleted(call, _):
                    completed.withLock { $0.append(call.id) }
                    if (boundary == 2 && call.id == "batch_0") || (boundary == 3 && call.id == "batch_2") {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                default: break
                }
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        let executed = boundary == 0 ? 0 : (boundary == 3 ? 3 : 1)
        let expectedContent = String(repeating: "once", count: executed)
        #expect(try String(contentsOf: file, encoding: .utf8) == expectedContent)
        #expect(fixture.capturedRequests().count == 1)
        #expect(started.withLock { $0.count } == (boundary == 1 ? 2 : max(1, executed)))
        #expect(completed.withLock { $0 } == ["batch_0", "batch_1", "batch_2"])
        let snapshot = try #require(await client.snapshotSession(id: "batch"))
        let calls = snapshot.history.flatMap(\.toolCalls).compactMap(\.id)
        let results = snapshot.history.filter { $0.role == .tool }
        #expect(calls == ["batch_0", "batch_1", "batch_2"])
        #expect(results.compactMap(\.toolCallID) == calls)
        for (index, result) in results.enumerated() {
            #expect(result.content.contains("cancelled before dispatch") == (index >= executed))
        }
        let response = try await client.sendPrompt(sessionID: "batch", prompt: "continue", attachments: []) { _ in }
        #expect(response.text == "Resumed")
        #expect(fixture.capturedRequests().count == 2)
        #expect(try String(contentsOf: file, encoding: .utf8) == expectedContent)
    }

    @Test(arguments: [0, 1, 2], [false, true])
    func cancellationCallbacksCannotWriteIntoResetSession(profile: Int, resetDuringDrain: Bool) async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: recoveryBatchBody(profile, appendPath: "/unused-cancelled-tool-path")
        )
        defer { fixture.beginShutdown() }
        let client = recoveryClient(fixture, profile: profile)
        let task = Task {
            try await client.sendPrompt(sessionID: "reset-batch", prompt: "hi", attachments: []) { event in
                if case .toolCallStarted = event {
                    withUnsafeCurrentTask { $0?.cancel() }
                    if !resetDuringDrain {
                        await client.createSession(id: "reset-batch", cwd: FileManager.default.temporaryDirectory.path)
                    }
                }
                if case .toolCallCompleted = event, resetDuringDrain {
                    // The full batch must already be closed before this reentrant callback.
                    let snapshot = await client.snapshotSession(id: "reset-batch")
                    #expect(snapshot?.history.filter { $0.role == .tool }.count == 3)
                    await client.createSession(id: "reset-batch", cwd: FileManager.default.temporaryDirectory.path)
                }
            }
        }
        do {
            _ = try await task.value
            Issue.record("Expected stale session")
        } catch RemoteGenerationClientError.missingSession {}
        let snapshot = try #require(await client.snapshotSession(id: "reset-batch"))
        #expect(!snapshot.history.contains { $0.role == .tool || $0.role == .assistant })
        #expect(fixture.capturedRequests().count == 1)
    }

    @Test(arguments: [0, 1, 2])
    func malformedToolRoundRetriesLiveWithoutDuplicateDispatch(profile: Int) async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: recoveryBody(profile, malformed: false, tool: false, text: "Done"),
            responseSequence: [recoveryBody(profile, malformed: true), recoveryBody(profile, malformed: false)]
        )
        defer { fixture.beginShutdown() }
        let client = recoveryClient(fixture, profile: profile)
        let events = CapturedDirectAgentEvents()
        let calls = Mutex(0)
        let result = try await client.sendPrompt(sessionID: "recovery", prompt: "hi", attachments: []) { event in
            events.append(event)
            if case .toolCallStarted = event { calls.withLock { $0 += 1 } }
        }
        #expect(result.text == "HelloDone")
        #expect(events.contentText() == "HelloDone")
        #expect(calls.withLock { $0 } == 1)
        #expect(fixture.capturedRequests().count == 3)
        let snapshot = try #require(await client.snapshotSession(id: "recovery"))
        #expect(snapshot.history.filter { $0.role == .assistant }.count == 2)
    }

    @Test(arguments: [0, 1, 2])
    func malformedToolRetryBudgetSurvivesValidRound(profile: Int) async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: recoveryBody(profile, malformed: true),
            responseSequence: [recoveryBody(profile, malformed: true), recoveryBody(profile, malformed: false)]
        )
        defer { fixture.beginShutdown() }
        let client = recoveryClient(fixture, profile: profile)
        let calls = Mutex(0)
        do {
            _ = try await client.sendPrompt(sessionID: "budget", prompt: "hi", attachments: []) { event in
                if case .toolCallStarted = event { calls.withLock { $0 += 1 } }
            }
            Issue.record("Expected invalidToolArguments")
        } catch RemoteGenerationClientError.invalidToolArguments {}
        #expect(fixture.capturedRequests().count == 3)
        #expect(calls.withLock { $0 } == 1)
    }

    @Test(arguments: [0, 1, 2])
    func repeatedMalformedToolRoundStopsAfterTwoRequests(profile: Int) async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: recoveryBody(profile, malformed: true, mixed: true))
        defer { fixture.beginShutdown() }
        let client = recoveryClient(fixture, profile: profile)
        let calls = Mutex(0)
        do {
            _ = try await client.sendPrompt(sessionID: "repeated", prompt: "hi", attachments: []) { event in
                if case .toolCallStarted = event { calls.withLock { $0 += 1 } }
            }
            Issue.record("Expected invalidToolArguments")
        } catch RemoteGenerationClientError.invalidToolArguments {}
        #expect(fixture.capturedRequests().count == 2)
        #expect(calls.withLock { $0 } == 0)
        let snapshot = try #require(await client.snapshotSession(id: "repeated"))
        #expect(!snapshot.history.contains { $0.role == .assistant })
    }

    @Test func unrelatedHTTPErrorDoesNotConsumeToolRecovery() async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: Data("bad request".utf8), responseStatus: 400
        )
        defer { fixture.beginShutdown() }
        let client = recoveryClient(fixture, profile: 0)
        let events = CapturedDirectAgentEvents()
        do {
            _ = try await client.sendPrompt(sessionID: "http-error", prompt: "hi", attachments: []) { events.append($0) }
            Issue.record("Expected HTTP error")
        } catch {}
        #expect(fixture.capturedRequests().count == 1)
        #expect(!events.diagnostics().contains { $0.contains("Retrying this generation round") })
    }

    @Test(arguments: [0, 1, 2])
    func earlierMutatingRoundIsNeverReplayed(profile: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("counter.txt")
        try Data().write(to: file)
        let fixture = try await RemoteNIOStreamingFixture.start(
            responseBody: recoveryBody(profile, malformed: false, tool: false, text: "Done"),
            responseSequence: [
                recoveryBody(profile, malformed: false, appendPath: file.path),
                recoveryBody(profile, malformed: true),
                recoveryBody(profile, malformed: false)
            ]
        )
        defer { fixture.beginShutdown() }
        let client = recoveryClient(fixture, profile: profile)
        await client.createSession(id: "mutating", cwd: directory.path, allowedToolNames: ["local.append", "local.pwd"])
        _ = try await client.sendPrompt(sessionID: "mutating", prompt: "hi", attachments: []) { _ in }
        #expect(try String(contentsOf: file, encoding: .utf8) == "once")
        #expect(fixture.capturedRequests().count == 4)
    }

    @Test(arguments: [false, true])
    func resetOrCancellationDuringRecoveryPreventsRetry(reset: Bool) async throws {
        let fixture = try await RemoteNIOStreamingFixture.start(responseBody: recoveryBody(0, malformed: true))
        defer { fixture.beginShutdown() }
        let client = recoveryClient(fixture, profile: 0)
        let task = Task {
            try await client.sendPrompt(sessionID: "cancel", prompt: "hi", attachments: []) { event in
                if case let .diagnostic(text) = event, text.contains("Retrying this generation round") {
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
        } catch RemoteGenerationClientError.missingSession {
            #expect(reset)
        }
        #expect(fixture.capturedRequests().count == 1)
        let snapshot = try #require(await client.snapshotSession(id: "cancel"))
        #expect(!snapshot.history.contains { $0.role == .assistant })
    }
}

struct RemoteRoundOutputRelayTests {
    @Test func forwardsLiveAndReconcilesIndependentUnicodePrefixes() async {
        let relay = RemoteRoundOutputRelay()
        let events = CapturedDirectAgentEvents()
        let sink: @Sendable (DirectAgentEvent) async -> Void = { events.append($0) }
        await relay.forward(.content("e"), to: sink)
        #expect(events.contentText() == "e") // Before result/finalization.
        await relay.forward(.content("\u{301}👩‍💻 old"), to: sink)
        await relay.forward(.thought("think old"), to: sink)
        await relay.beginRetry()
        for chunk in ["e\u{301}👩", "‍", "💻 ", "new"] {
            await relay.forward(.content(chunk), to: sink)
        }
        for chunk in ["th", "ink", " new"] {
            await relay.forward(.thought(chunk), to: sink)
        }
        #expect(events.contentText() == "e\u{301}👩‍💻 oldnew")
        #expect(events.thoughtText() == "think oldnew")
    }

    @Test func identicalAndShorterRetriesEmitNothingAndExtensionStaysLive() async {
        let relay = RemoteRoundOutputRelay()
        let events = CapturedDirectAgentEvents()
        let sink: @Sendable (DirectAgentEvent) async -> Void = { events.append($0) }
        await relay.forward(.content("abc"), to: sink)
        await relay.forward(.thought("xyz"), to: sink)
        await relay.beginRetry()
        await relay.forward(.content("a"), to: sink)
        await relay.forward(.thought("xyz"), to: sink)
        #expect(events.contentText() == "abc")
        #expect(events.thoughtText() == "xyz")
        await relay.forward(.content("bc!"), to: sink)
        #expect(events.contentText() == "abc!")
    }
}
