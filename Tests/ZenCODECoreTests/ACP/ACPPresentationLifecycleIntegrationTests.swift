import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@Suite(.timeLimit(.minutes(1)))
struct ACPPresentationLifecycleIntegrationTests {
    @Test func textOnlySecondPromptReattachesPersistentTasklessAgent() async throws {
        let (wire, messages) = AsyncStream<JSONValue>.makeStream()
        let backend = PresentationLifecycleBackend()
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableModels: [.init(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")],
            runMode: .acp, workingDirectory: FileManager.default.temporaryDirectory, appMode: false
        )
        let bridge = ZenCODEACPBridge(configuration: configuration, writer: ACPWriter { data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) { messages.yield(value) }
        }, backendFactory: { _, _ in backend })
        try await bridge.newSession(id: .number(1), params: ["cwd": "/tmp", "allowedTools": [String]()])
        let sessionID = try #require(await bridge.testAnySessionID())
        var iterator = wire.makeAsyncIterator()
        func nextWork(_ iterator: inout AsyncStream<JSONValue>.Iterator, id: String, status: String) async -> JSONValue? {
            while let message = await iterator.next() {
                let update = message.objectValue?["params"]?.objectValue?["update"]
                if update?.objectValue?["toolCallId"] == .string(id),
                   update?.objectValue?["status"] == .string(status) { return update }
            }
            return nil
        }
        let first = Task { try await bridge.prompt(id: .number(2), params: ["sessionId": sessionID, "prompt": "first"]) }
        let running = await nextWork(&iterator, id: "acp:work:persistent:1", status: "in_progress")
        #expect(running?.objectValue?["sessionUpdate"] == .string("tool_call"))
        await backend.finishExecution(failed: false)
        let completed = await nextWork(&iterator, id: "acp:work:persistent:1", status: "completed")
        #expect(completed?.objectValue?["sessionUpdate"] == .string("tool_call_update"))
        await backend.releasePrompt()
        try await first.value

        let second = Task { try await bridge.prompt(id: .number(3), params: ["sessionId": sessionID, "prompt": "text only"]) }
        let followup = await nextWork(&iterator, id: "acp:work:persistent:2", status: "in_progress")
        #expect(followup?.objectValue?["sessionUpdate"] == .string("tool_call"))
        await backend.finishExecution(failed: true)
        let failed = await nextWork(&iterator, id: "acp:work:persistent:2", status: "failed")
        #expect(failed?.objectValue?["sessionUpdate"] == .string("tool_call_update"))
        await backend.releasePrompt()
        try await second.value
        #expect(await backend.promptCount == 2)
        #expect(await backend.subscriptionCount == 2)
        await bridge.shutdown()
        messages.finish()
    }

    @Test func replacedIncarnationRejectsBufferedAndSuspendedOldProducer() async throws {
        let output = Mutex<[JSONValue]>([])
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableModels: [.init(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")],
            runMode: .acp, workingDirectory: FileManager.default.temporaryDirectory
        )
        let writer = ACPWriter { data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) { output.withLock { $0.append(value) } }
        }
        let bridge = ZenCODEACPBridge(configuration: configuration, writer: writer,
                                     backendFactory: { _, _ in PresentationLifecycleBackend() })
        try await bridge.newSession(id: .number(1), params: ["cwd": "/tmp", "allowedTools": [String]()])
        let sessionID = try #require(await bridge.testAnySessionID())
        let (epoch, promptID) = await bridge.installPresentationTestPrompt(sessionID: sessionID)
        let gate = PresentationSuspensionGate()
        let pipeline = ACPPromptUpdatePipeline(sessionID: sessionID, writer: writer, buffer: ACPPromptUpdateBuffer(),
            isValid: { await bridge.isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) },
            canDeliver: { await bridge.canDeliverPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) },
            onUnitStart: { ordinal in if ordinal == 2 { await gate.park() } })
        await pipeline.enqueue(.init(kind: .consume(ZenCODEACPBridge.textChunkJSONUpdate(kind: "agent_message_chunk", text: "old-buffer")))).value
        let suspended = pipeline.enqueue(.init(kind: .consume(ZenCODEACPBridge.textChunkJSONUpdate(kind: "agent_message_chunk", text: "old-late"))))
        await gate.waitForArrival()
        await bridge.replacePresentationTestSession(sessionID: sessionID)
        await gate.release()
        await suspended.value
        await pipeline.enqueue(.init(kind: .flush)).value
        await pipeline.drain()
        let wire = output.withLock { $0 }
        #expect(!wire.contains { $0.objectValue?["params"]?.objectValue?["update"]?.objectValue?["content"]?.objectValue?["text"] == .string("old-buffer") })
        #expect(!wire.contains { $0.objectValue?["params"]?.objectValue?["update"]?.objectValue?["content"]?.objectValue?["text"] == .string("old-late") })
        await bridge.shutdown()
    }
}

private extension ZenCODEACPBridge {
    func installPresentationTestPrompt(sessionID: String) -> (UInt64, UUID) {
        let promptID = UUID()
        sessions[sessionID]?.activePromptID = promptID
        sessions[sessionID]?.operationState = .prompting(promptID)
        return (sessions[sessionID]!.epoch, promptID)
    }

    func installTasklessPreparationGate(sessionID: String, gate: PresentationSuspensionGate) {
        let didPark = Mutex(false)
        sessions[sessionID]?.tasklessPresentation = ACPTasklessPresentation(onPrepared: { updates in
            guard updates.contains(where: { $0.objectValue?["status"] == .string("completed") }) else { return }
            let shouldPark = didPark.withLock { parked in
                if parked { return false }
                parked = true
                return true
            }
            if shouldPark { await gate.park() }
        })
    }

    func waitForTasklessTeardown(sessionID: String) async {
        // Teardown clears the observer slot and cancels it before awaiting it.
        // The preparation gate keeps that cancelled observer alive until released.
        while sessions[sessionID]?.tasklessObserver != nil { await Task.yield() }
    }

    func presentationEpoch(sessionID: String) -> UInt64? { sessions[sessionID]?.epoch }

    func replacePresentationTestSession(sessionID: String) {
        let old = sessions[sessionID]!
        sessions[sessionID] = sessionState(configuration: old.configuration)
    }
}

private actor PresentationLifecycleBackend: AgentRuntimeBackend {
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var continuation: AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>.Continuation?
    private var rootID = ""
    private var promptWaiter: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var promptCount = 0
    private(set) var subscriptionCount = 0
    private var snapshot: DirectSubAgentRuntime.AgentSnapshot?
    private let preservesExecutionAcrossPrompts: Bool

    init(preservesExecutionAcrossPrompts: Bool = false) {
        self.preservesExecutionAcrossPrompts = preservesExecutionAcrossPrompts
    }

    func createSession(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
                       cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {
        sessions[id] = .init(sessionID: id, workingDirectoryPath: cwd, systemPrompt: systemPrompt,
                            cacheKey: cacheKey, history: history, allowedToolNames: allowedToolNames,
                            thinkingSelection: thinkingSelection, preserveThinking: preserveThinking)
    }
    func createSessionIfNeeded(id: String, cwd: String, systemPrompt: String?, history: [AgentRuntimeMessage],
                               cacheKey: String?, allowedToolNames: Set<String>?, thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {
        guard sessions[id] == nil else { return }
        createSession(id: id, cwd: cwd, systemPrompt: systemPrompt, history: history, cacheKey: cacheKey,
                      allowedToolNames: allowedToolNames, thinkingSelection: thinkingSelection, preserveThinking: preserveThinking)
    }
    func updateSessionOptions(id: String, systemPrompt: String?, allowedToolNames: Set<String>?,
                              thinkingSelection: AgentThinkingSelection?, preserveThinking: Bool) {}
    func closeSession(id: String) { sessions.removeValue(forKey: id) }
    func shutdown() async { continuation?.finish(); sessions.removeAll() }
    func preloadModel(onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> String { "test-model" }
    func activeToolDescriptors() async -> [DirectToolDescriptor] { [] }
    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? { sessions[id] }
    func subAgentSnapshotEvents(rootSessionID: String) async -> AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]> {
        subscriptionCount += 1
        let (stream, sink) = AsyncStream<[DirectSubAgentRuntime.AgentSnapshot]>.makeStream()
        continuation = sink
        sink.yield(snapshot.map { [$0] } ?? [])
        return stream
    }
    func sendPrompt(sessionID: String, prompt: String, attachments: [AgentRuntimeAttachment],
                    onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void) async throws -> DirectAgentResponse {
        rootID = sessionID
        promptCount += 1
        released = false
        if promptCount == 1 {
            await onEvent(.toolCallStarted(.init(id: "create", name: "agent.create", argumentsObject: [:], argumentsJSON: "{}")))
        }
        await onEvent(.content("root text"))
        if !preservesExecutionAcrossPrompts || promptCount == 1 {
            publish(status: .running, completed: promptCount > 1 ? 1 : 0)
        }
        if !released { await withCheckedContinuation { promptWaiter = $0 } }
        return .init(text: "root text", stopReason: "end_turn", modelID: "test-model")
    }
    func finishExecution(failed: Bool) {
        publish(status: failed ? .failed : .idle, completed: failed ? 1 : UInt64(promptCount),
                error: failed ? "Second execution failed" : nil)
    }
    func releasePrompt() { released = true; promptWaiter?.resume(); promptWaiter = nil }
    private func publish(status: DirectSubAgentRuntime.Status, completed: UInt64, error: String? = nil) {
        let value = DirectSubAgentRuntime.AgentSnapshot(id: "persistent", rootSessionID: rootID,
            name: "Persistent", role: "Worker", status: status, pending: status == .running,
            latestOutput: completed > 0 ? "Previous execution" : nil,
            executionRevision: UInt64(promptCount), completedExecutionRevision: completed,
            latestOutputRevision: completed, latestError: error, createdAt: .now, updatedAt: .now)
        snapshot = value
        continuation?.yield([value])
    }
}

extension ACPPresentationLifecycleIntegrationTests {
    @Test func delegatedDAGMutationFlowsThroughInvalidationAndPipelineUntilValidationRetry() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let output = Mutex<[JSONValue]>([])
        let writer = ACPWriter { data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) { output.withLock { $0.append(value) } }
        }
        let pipeline = ACPPromptUpdatePipeline(sessionID: "root", writer: writer, buffer: ACPPromptUpdateBuffer(), buffersUpdates: false)
        let projection = ACPTaskPresentation()
        let stream = await orchestrator.events(sessionID: "root")
        var events = stream.makeAsyncIterator()
        func publishNext(_ events: inout AsyncStream<TaskGraphEvent>.Iterator) async throws {
            _ = try #require(await events.next())
            let graph = try await orchestrator.graphSnapshot(sessionID: "root")
            for update in await projection.updates(for: graph) {
                await pipeline.enqueue(.init(kind: .consume(update))).value
            }
            await pipeline.drain()
        }
        _ = try await orchestrator.createGraph(sessionID: "root", id: "graph", source: .manual, state: .active,
            tasks: [.init(id: "task", title: "Work", execution: .init(executor: .subAgent))])
        try await publishNext(&events)
        let receipt = try #require(try await orchestrator.claimTasks(sessionID: "root", claims: [
            .init(taskID: "task", agentID: "worker", executor: .subAgent)
        ]).first)
        try await publishNext(&events)
        let create = DirectAgentToolCall(id: "create", name: "agent.create", argumentsObject: [:], argumentsJSON: "{}")
        await pipeline.enqueue(.init(kind: .consume(ZenCODEACPBridge.toolCallCompletionJSONUpdate(
            for: create, result: .init(output: "Agent created", summary: "Created")
        )))).value
        let claimedGraph = try #require(try await orchestrator.graphSnapshot(sessionID: "root"))
        #expect(claimedGraph.tasks.first?.status != .completed)
        _ = try await orchestrator.markAttemptRunning(sessionID: "root", taskID: "task", attemptID: receipt.attemptID)
        try await publishNext(&events)
        try await orchestrator.registerExecutionScope(executionSessionID: "child", scope: .init(
            rootSessionID: "root", graphID: "graph", taskID: "task", attemptID: receipt.attemptID
        ))
        _ = try await orchestrator.updateTask(sessionID: "child", taskID: "task", update: .init(output: "Delegated progress"))
        try await publishNext(&events)
        _ = try await orchestrator.completeAttempt(sessionID: "root", taskID: "task", attemptID: receipt.attemptID,
                                                  output: "Implementation done", requiresValidation: true)
        try await publishNext(&events)
        let awaiting = try #require(try await orchestrator.graphSnapshot(sessionID: "root"))
        #expect(awaiting.tasks.first?.status == .awaitingValidation)
        _ = try await orchestrator.validateTaskResult(sessionID: "root", taskID: "task", succeeded: false, failureReason: "Independent failure")
        try await publishNext(&events)
        _ = try await orchestrator.retryTask(sessionID: "root", taskID: "task")
        try await publishNext(&events)
        let retry = try #require(try await orchestrator.claimTasks(sessionID: "root", claims: [
            .init(taskID: "task", agentID: "retry-worker", executor: .subAgent)
        ]).first)
        try await publishNext(&events)
        let updates = output.withLock { $0 }.compactMap { $0.objectValue?["params"]?.objectValue?["update"] }
        let oldID = "acp:work:graph:task:\(receipt.attemptID)"
        let newID = "acp:work:graph:task:\(retry.attemptID)"
        #expect(oldID != newID)
        #expect(updates.contains { $0.objectValue?["toolCallId"] == .string(oldID) && $0.objectValue?["status"] == .string("completed") })
        #expect(updates.contains { $0.objectValue?["toolCallId"] == .string(newID) && $0.objectValue?["status"] == .string("pending") })
        #expect(updates.contains { update in
            update.objectValue?["entries"]?.arrayValue?.contains {
                $0.objectValue?["content"] == .string("[awaiting_validation] Work") && $0.objectValue?["status"] == .string("in_progress")
            } == true
        })
        let text = String(decoding: try JSONEncoder().encode(JSONValue.array(updates)), as: UTF8.self)
        #expect(text.contains("Delegated progress"))
        #expect(text.contains("[failed] Work"))
        await orchestrator.finishEventStreams()
    }
}

private actor PresentationSuspensionGate {
    private var arrived = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    func park() async {
        await withCheckedContinuation { continuation in
            waiter = continuation
            arrived = true
            for observer in arrivalWaiters { observer.resume() }
            arrivalWaiters.removeAll()
        }
    }
    func waitForArrival() async {
        if arrived { return }
        await withCheckedContinuation { arrivalWaiters.append($0) }
    }
    func release() { waiter?.resume(); waiter = nil }
}

extension ACPPresentationLifecycleIntegrationTests {
    @Test func cancelledPreparedTerminalReplaysOnceInNextPromptOfSameEpoch() async throws {
        let (wire, messages) = AsyncStream<JSONValue>.makeStream()
        let output = Mutex<[JSONValue]>([])
        let backend = PresentationLifecycleBackend(preservesExecutionAcrossPrompts: true)
        let configuration = try AgentConfiguration(
            hostedModelID: "test-model",
            availableModels: [.init(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")],
            runMode: .acp, workingDirectory: FileManager.default.temporaryDirectory, appMode: false
        )
        let bridge = ZenCODEACPBridge(configuration: configuration, writer: ACPWriter { data in
            if let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
                output.withLock { $0.append(value) }
                messages.yield(value)
            }
        }, backendFactory: { _, _ in backend })
        try await bridge.newSession(id: .number(1), params: ["cwd": "/tmp", "allowedTools": [String]()])
        let sessionID = try #require(await bridge.testAnySessionID())
        let epoch = await bridge.presentationEpoch(sessionID: sessionID)
        let gate = PresentationSuspensionGate()
        await bridge.installTasklessPreparationGate(sessionID: sessionID, gate: gate)
        var iterator = wire.makeAsyncIterator()
        func nextStatus(_ status: String, _ iterator: inout AsyncStream<JSONValue>.Iterator) async -> JSONValue? {
            while let message = await iterator.next() {
                let update = message.objectValue?["params"]?.objectValue?["update"]
                if update?.objectValue?["toolCallId"] == .string("acp:work:persistent:1"),
                   update?.objectValue?["status"] == .string(status) { return update }
            }
            return nil
        }
        func terminals() -> [JSONValue] {
            output.withLock { values in values.filter {
                let update = $0.objectValue?["params"]?.objectValue?["update"]?.objectValue
                return update?["toolCallId"] == .string("acp:work:persistent:1")
                    && update?["status"] == .string("completed")
            } }
        }
        let first = Task { try await bridge.prompt(id: .number(2), params: ["sessionId": sessionID, "prompt": "first"]) }
        #expect(await nextStatus("in_progress", &iterator) != nil)
        await backend.finishExecution(failed: false)
        await gate.waitForArrival()
        // Terminal is prepared, but has not passed the observer's enqueue guard.
        await backend.releasePrompt()
        await bridge.waitForTasklessTeardown(sessionID: sessionID)
        await gate.release()
        try await first.value
        #expect(terminals().isEmpty)

        let second = Task { try await bridge.prompt(id: .number(3), params: ["sessionId": sessionID, "prompt": "text only"]) }
        let terminal = await nextStatus("completed", &iterator)
        #expect(terminal?.objectValue?["sessionUpdate"] == .string("tool_call_update"))
        while await backend.promptCount < 2 { await Task.yield() }
        await backend.releasePrompt()
        try await second.value
        #expect(await bridge.presentationEpoch(sessionID: sessionID) == epoch)
        #expect(terminals().count == 1)

        // A further replay of the same terminal must not reopen or duplicate it.
        let third = Task { try await bridge.prompt(id: .number(4), params: ["sessionId": sessionID, "prompt": "again"]) }
        while await backend.promptCount < 3 { await Task.yield() }
        await backend.releasePrompt()
        try await third.value
        #expect(terminals().count == 1)
        await bridge.shutdown()
        messages.finish()
    }
}
