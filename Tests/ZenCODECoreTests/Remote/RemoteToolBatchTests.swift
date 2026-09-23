import Foundation
import Synchronization
import Testing
@testable import ZenCODECore

@Suite("Remote tool batch boundaries")
struct RemoteToolBatchTests {
    @Test(arguments: [0, 1, 3], [DirectAgentToolResult.Status.completed, .failed, .permissionDenied])
    func cancellationDuringExecutionPreservesObtainedResult(count: Int, status: DirectAgentToolResult.Status) async throws {
        let owner = BatchOwner()
        let calls = batchCalls(count: count)
        let completed = Mutex<[String]>([])
        let task = Task {
            if count == 0 { withUnsafeCurrentTask { $0?.cancel() } }
            try await owner.run(calls, cancelDuringExecution: true, resultStatus: status) { event in
                if case let .toolCallCompleted(call, _) = event {
                    completed.withLock { $0.append(call.id) }
                    #expect(await owner.resultIDs().contains(call.id))
                }
            }
        }
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        #expect(await owner.executedIDs() == Array(calls.prefix(1)).map(\.id))
        #expect(await owner.resultIDs() == calls.map(\.id))
        #expect(completed.withLock { $0 } == calls.map(\.id))
        let outputs = await owner.outputs()
        if count > 0 {
            #expect(outputs.first == "obtained-result")
            #expect(await owner.statuses().first == status)
            #expect(outputs.dropFirst().allSatisfy { $0.contains("cancelled before dispatch") })
        }
    }

    @Test
    func emptyAndSuccessfulBatchesAreSerial() async throws {
        let owner = BatchOwner()
        try await owner.run([]) { _ in Issue.record("Empty batch emitted an event") }
        let order = Mutex<[String]>([])
        try await owner.run(batchCalls(count: 3)) { event in
            switch event {
            case let .toolCallStarted(call): order.withLock { $0.append("start-" + call.id) }
            case let .toolCallCompleted(call, _):
                #expect(await owner.resultIDs().last == call.id)
                order.withLock { $0.append("end-" + call.id) }
            default: break
            }
        }
        #expect(order.withLock { $0 } == ["start-0", "end-0", "start-1", "end-1", "start-2", "end-2"])
    }

    @Test
    func leaseInvalidatedDuringExecutionCannotPersistOrEmitCompletion() async throws {
        let owner = BatchOwner()
        do {
            try await owner.run(batchCalls(count: 3), resetDuringExecution: true) { event in
                if case .toolCallCompleted = event { Issue.record("Stale completion") }
            }
            Issue.record("Expected stale lease")
        } catch BatchOwner.Failure.staleLease {}
        #expect(await owner.executedIDs() == ["0"])
        #expect(await owner.resultIDs().isEmpty)
    }

    // Includes pre-cancel, first/middle start, first/last completion, and the
    // one-tool boundary where the completed prefix consumes the whole batch.
    @Test(arguments: [false, true], [-1, 0, 1, 2, 3, 4])
    func subscriptionAdaptersCloseBatchBeforeCallbacks(anthropic: Bool, boundary: Int) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("counter.txt")
        try Data().write(to: file)
        let client = SubscriptionBatchClient(anthropic: anthropic, directory: directory)
        let count = boundary == 4 ? 1 : 3
        let calls = batchCalls(count: count, path: file.path)
        try await client.prepare(calls, directory: directory)
        let completed = Mutex<[String]>([])
        let started = Mutex<[String]>([])
        let executed = boundary < 1 ? 0 : (boundary == 3 ? 3 : 1)
        let task = Task {
            if boundary == -1 { withUnsafeCurrentTask { $0?.cancel() } }
            try await client.run(calls) { event in
                switch event {
                case let .toolCallStarted(call):
                    started.withLock { $0.append(call.id) }
                    if (boundary == 0 && call.id == "0") || (boundary == 1 && call.id == "1") {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                case let .toolCallCompleted(call, result):
                    completed.withLock { $0.append(call.id) }
                    let results = await client.snapshot()?.history.filter { $0.role == .tool } ?? []
                    #expect(results.contains { $0.toolCallID == call.id })
                    if result.output.contains("cancelled before dispatch") {
                        #expect(results.count == count)
                        #expect(result.status == .failed)
                    }
                    await client.expectAccounting()
                    if (boundary == 2 && call.id == "0") || (boundary == 3 && call.id == "2") || boundary == 4 {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                default: break
                }
            }
        }
        do {
            try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        #expect(try String(contentsOf: file, encoding: .utf8) == String(repeating: "once", count: executed))
        #expect(completed.withLock { $0 } == calls.map(\.id))
        #expect(started.withLock { $0.count } == (boundary == -1 ? 0 : boundary == 1 ? 2 : max(1, executed)))
        let snapshot = try #require(await client.snapshot())
        let results = snapshot.history.filter { $0.role == .tool }
        #expect(results.compactMap(\.toolCallID) == calls.map(\.id))
        for (index, result) in results.enumerated() {
            #expect(result.content.contains("cancelled before dispatch") == (index >= executed))
        }
        await client.shutdown()
    }

    @Test(arguments: [false, true])
    func subscriptionDispatchReadsOptionsAfterStartedCallback(anthropic: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("must-not-exist.txt")
        let client = SubscriptionBatchClient(anthropic: anthropic, directory: directory)
        let calls = batchCalls(count: 1, path: file.path)
        try await client.prepare(calls, directory: directory)
        let completed = Mutex(0)
        try await client.run(calls) { event in
            switch event {
            case .toolCallStarted:
                await client.denyTools()
            case let .toolCallCompleted(call, result):
                completed.withLock { $0 += 1 }
                #expect(result.isFailure)
                let snapshot = await client.snapshot()
                #expect(snapshot?.history.last?.toolCallID == call.id)
            default: break
            }
        }
        #expect(completed.withLock { $0 } == 1)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        await client.shutdown()
    }

    // Reset during first start, normal completion, first drain and last drain.
    @Test(arguments: [false, true], [0, 1, 2, 3])
    func subscriptionCallbacksCannotWriteIntoReplacement(anthropic: Bool, boundary: Int) async throws {
        let directory = FileManager.default.temporaryDirectory
        let client = SubscriptionBatchClient(anthropic: anthropic, directory: directory)
        let calls = batchCalls(count: 3)
        try await client.prepare(calls, directory: directory)
        let completions = Mutex(0)
        let task = Task {
            try await client.run(calls) { event in
                switch event {
                case .toolCallStarted where boundary != 1:
                    withUnsafeCurrentTask { $0?.cancel() }
                    if boundary == 0 { await client.reset(directory: directory) }
                case let .toolCallCompleted(call, _):
                    completions.withLock { $0 += 1 }
                    if boundary == 1 || boundary == 2 || (boundary == 3 && call.id == "2") {
                        let snapshot = await client.snapshot()
                        #expect(snapshot?.history.filter { $0.role == .tool }.count == (boundary == 1 ? 1 : 3))
                        await client.reset(directory: directory)
                    }
                default: break
                }
            }
        }
        do {
            try await task.value
            Issue.record("Expected stale lease")
        } catch RemoteGenerationClientError.missingSession {
            #expect(anthropic)
        } catch ChatGPTSubscriptionGenerationError.missingSession {
            #expect(!anthropic)
        }
        let snapshot = try #require(await client.snapshot())
        #expect(!snapshot.history.contains { $0.role == .tool || $0.role == .assistant })
        #expect(completions.withLock { $0 } == (boundary == 0 ? 0 : boundary == 3 ? 3 : 1))
        await client.shutdown()
    }
}

private func batchCalls(count: Int, path: String? = nil) -> [DirectAgentToolCall] {
    (0..<count).map { index in
        DirectAgentToolCall(
            id: String(index), name: path == nil ? "local.pwd" : "local.append",
            argumentsObject: path.map { ["path": $0, "content": "once"] } ?? [:],
            argumentsJSON: "{}"
        )
    }
}

private actor BatchOwner {
    enum Failure: Error { case staleLease }
    private var valid = true
    private var executed: [String] = []
    private var results: [(DirectAgentToolCall, DirectAgentToolResult)] = []

    func run(
        _ calls: [DirectAgentToolCall],
        cancelDuringExecution: Bool = false,
        resetDuringExecution: Bool = false,
        resultStatus: DirectAgentToolResult.Status = .completed,
        onEvent: @Sendable (DirectAgentEvent) async -> Void
    ) async throws {
        try await RemoteToolBatchExecutor.run(
            calls, isolation: self,
            validateLease: { if !self.valid { throw Failure.staleLease } },
            execute: { call in
                self.executed.append(call.id)
                if cancelDuringExecution { withUnsafeCurrentTask { $0?.cancel() } }
                if resetDuringExecution { self.valid = false }
                return DirectAgentToolResult(output: "obtained-result", summary: "obtained-result", status: resultStatus)
            },
            persist: { self.results.append(contentsOf: $0) },
            onEvent: onEvent
        )
    }

    func resultIDs() -> [String] { results.map { $0.0.id } }
    func executedIDs() -> [String] { executed }
    func outputs() -> [String] { results.map { $0.1.output } }
    func statuses() -> [DirectAgentToolResult.Status] { results.map { $0.1.status } }
}

private enum SubscriptionBatchClient: Sendable {
    case chatGPT(ChatGPTSubscriptionGenerationClient)
    case anthropic(AnthropicSubscriptionGenerationClient)

    init(anthropic: Bool, directory: URL) {
        let configuration = AgentRuntimeConfiguration(
            modelID: "unit-model", workingDirectory: directory, maxToolRounds: 1,
            toolAuthorizationHandler: nil
        )
        if anthropic {
            self = .anthropic(AnthropicSubscriptionGenerationClient(
                configuration: configuration,
                provider: AgentRemoteProvider(
                    name: "Anthropic Subscription", baseURL: AgentRemoteProvider.anthropicSubscriptionBaseURL,
                    modelID: "claude-haiku-4-5", chatEndpoint: .responses
                )
            ))
        } else {
            self = .chatGPT(ChatGPTSubscriptionGenerationClient(configuration: configuration))
        }
    }

    func reset(directory: URL) async {
        switch self {
        case let .chatGPT(client):
            await client.createSession(id: "batch", cwd: directory.path, allowedToolNames: ["local.append", "local.pwd"])
        case let .anthropic(client):
            await client.createSession(id: "batch", cwd: directory.path, allowedToolNames: ["local.append", "local.pwd"])
        }
    }

    func denyTools() async {
        switch self {
        case let .chatGPT(client):
            await client.updateSessionOptions(id: "batch", systemPrompt: nil, allowedToolNames: [], thinkingSelection: nil, preserveThinking: false)
        case let .anthropic(client):
            await client.updateSessionOptions(id: "batch", systemPrompt: nil, allowedToolNames: [], thinkingSelection: nil, preserveThinking: false)
        }
    }

    func prepare(_ calls: [DirectAgentToolCall], directory: URL) async throws {
        await reset(directory: directory)
        switch self {
        case let .chatGPT(client): try await client.seedBatch(calls)
        case let .anthropic(client): try await client.seedBatch(calls)
        }
    }

    func run(_ calls: [DirectAgentToolCall], onEvent: @Sendable (DirectAgentEvent) async -> Void) async throws {
        switch self {
        case let .chatGPT(client):
            let lease = try #require(await client.sessionLease(for: "batch"))
            try await client.executeToolBatch(calls, lease: lease, onEvent: onEvent)
        case let .anthropic(client):
            let lease = try #require(await client.sessionLease(for: "batch"))
            try await client.executeToolBatch(calls, lease: lease, onEvent: onEvent)
        }
    }

    func snapshot() async -> AgentRuntimeSessionSnapshot? {
        switch self {
        case let .chatGPT(client): await client.snapshotSession(id: "batch")
        case let .anthropic(client): await client.snapshotSession(id: "batch")
        }
    }

    func expectAccounting() async {
        switch self {
        case let .chatGPT(client): await client.expectBatchContinuation()
        case let .anthropic(client): #expect(await client.requestOverhead(forSessionID: "batch") == .none)
        }
    }

    func shutdown() async {
        switch self {
        case let .chatGPT(client): await client.shutdown()
        case let .anthropic(client): await client.shutdown()
        }
    }
}

private func batchAssistantMessage(_ calls: [DirectAgentToolCall]) -> [String: Any] {
    ["role": "assistant", "content": "", "tool_calls": calls.map { call in
        ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.argumentsJSON]] as [String: Any]
    }]
}

private extension ChatGPTSubscriptionGenerationClient {
    func seedBatch(_ calls: [DirectAgentToolCall]) throws {
        let lease = try #require(sessionLease(for: "batch"))
        #expect(mutateSession(for: lease) { session in
            session.messages.append(batchAssistantMessage(calls))
            session.continuation = ChatGPTSubscriptionContinuationState(
                responseID: "batch-response", messageCount: session.messages.count,
                instructions: "fixture", allowsFreshTransport: true
            )
        })
    }

    func expectBatchContinuation() {
        let session = sessions["batch"]
        #expect(session?.continuation?.responseID == "batch-response")
        let results = session?.messages.filter { $0["role"] as? String == "tool" }.count ?? 0
        #expect(session?.continuation?.messageCount == (session?.messages.count ?? 0) - results)
    }
}

private extension AnthropicSubscriptionGenerationClient {
    func seedBatch(_ calls: [DirectAgentToolCall]) throws {
        let lease = try #require(sessionLease(for: "batch"))
        #expect(mutateSession(for: lease) { session in
            session.messages.append(batchAssistantMessage(calls))
        })
        recordRequestOverhead(
            estimate: SubscriptionCompactionSupport.RequestEstimate(totalTokens: 200, staticOverheadTokens: 10),
            runtimeConversationTokens: 100, for: lease
        )
        #expect(requestOverhead(forSessionID: "batch") != .none)
    }
}
