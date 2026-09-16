import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

struct ACPStandardPresentationTests {
    @Test func planUsesOnlyStandardStatusesAndPreservesFailureLabels() {
        for status in TaskStatus.allCases {
            let entry = ACPTaskPresentation.entry(TaskRecord(id: "t", title: "Task", order: 0, status: status))
            let fields = entry.objectValue!
            #expect(fields["priority"] == .string("medium"))
            if [.blocked, .failed, .cancelled].contains(status) {
                #expect(fields["status"] == .string("pending"))
                #expect(fields["content"] == .string("[\(status.rawValue)] Task"))
            }
            #expect(["pending", "in_progress", "completed"].contains(fields["status"]!.acpStringValue!))
        }
    }

    @Test func completePlanSnapshotsDeduplicateAndClear() async {
        let projection = ACPTaskPresentation()
        let graph = TaskGraphSnapshot(id: "g", source: .manual, state: .active,
                                      tasks: [TaskRecord(id: "t", title: "Task", order: 0)])
        #expect(await projection.updates(for: graph).count == 1)
        #expect(await projection.updates(for: graph).isEmpty)
        let cleared = await projection.updates(for: nil)
        #expect(cleared.first?.objectValue?["entries"] == .array([]))
        #expect(await projection.updates(for: nil).isEmpty)
    }

    @Test func cancelledPermissionOutcomeWinsOverLegacySelection() {
        let result: JSONValue = .object([
            "optionId": .string("allow_always"),
            "outcome": .object(["outcome": .string("cancelled"), "optionId": .string("allow_once")])
        ])
        #expect(ACPPermissionBroker.permissionOptionID(from: result) == nil)
    }

    @Test func delegatedConsentKeysRemainSeparate() {
        func request(agent: String) -> AgentToolAuthorizationRequest {
            AgentToolAuthorizationRequest(sessionID: "child", toolCallID: "call", toolName: "tool",
                title: "Tool", kind: "execute", command: "command", workingDirectory: "/tmp",
                delegatedIdentity: .init(agentID: agent, rootSessionID: "root"))
        }
        #expect(ACPPermissionBroker.permissionCacheKeyValue(for: request(agent: "a"))
                != ACPPermissionBroker.permissionCacheKeyValue(for: request(agent: "b")))
    }

    @Test func authenticDiffAndSummaryUseStandardContent() {
        let call = DirectAgentToolCall(id: "c", name: "local.writeFile", argumentsObject: [:], argumentsJSON: "{}")
        let result = DirectAgentToolResult(output: "output", summary: "summary", fileChanges: [
            .init(path: "/tmp/file", oldText: "before\n", newText: "after\n")
        ])
        let update = ZenCODEACPBridge.toolCallCompletionJSONUpdate(for: call, result: result)
        let content = update.objectValue?["content"]?.arrayValue ?? []
        #expect(content.count == 2)
        #expect(content.first?.objectValue?["content"]?.objectValue?["text"] == .string("summary\n\noutput"))
        #expect(content.last?.objectValue?["type"] == .string("diff"))
        #expect(content.last?.objectValue?["oldText"] == .string("before\n"))
        #expect(content.last?.objectValue?["newText"] == .string("after\n"))
    }
}

extension ACPStandardPresentationTests {
    @Test func tasklessExecutionsDoNotReuseTerminalRowsOrHistoricalOutput() async {
        func snapshot(_ status: DirectSubAgentRuntime.Status, execution: UInt64,
                      completed: UInt64 = 0, error: String? = nil) -> DirectSubAgentRuntime.AgentSnapshot {
            .init(id: "a", rootSessionID: "root", name: "Agent", role: "Worker", status: status,
                  pending: status == .running, latestOutput: completed > 0 ? "Old output" : nil,
                  executionRevision: execution, completedExecutionRevision: completed,
                  latestOutputRevision: completed, latestError: error, createdAt: .now, updatedAt: .now)
        }
        let projection = ACPTasklessPresentation()
        #expect(await projection.updates([snapshot(.idle, execution: 0)]).isEmpty)
        let running = await projection.updates([snapshot(.running, execution: 1)])
        #expect(running.first?.objectValue?["status"] == .string("in_progress"))
        for update in running { await projection.acknowledge(update) }
        let complete = await projection.updates([snapshot(.idle, execution: 1, completed: 1)])
        #expect(complete.first?.objectValue?["status"] == .string("completed"))
        for update in complete { await projection.acknowledge(update) }
        #expect(await projection.updates([snapshot(.idle, execution: 1, completed: 1)]).isEmpty)
        #expect(await projection.updates([snapshot(.running, execution: 1)]).isEmpty)
        let followup = await projection.updates([snapshot(.running, execution: 2, completed: 1)])
        #expect(followup.first?.objectValue?["sessionUpdate"] == .string("tool_call"))
        #expect(followup.first?.objectValue?["status"] == .string("in_progress"))
        #expect(followup.first?.objectValue?["toolCallId"] != complete.first?.objectValue?["toolCallId"])
        for update in followup { await projection.acknowledge(update) }
        let failure = await projection.updates([snapshot(.failed, execution: 2, completed: 1, error: "Second turn failed")])
        #expect(failure.first?.objectValue?["status"] == .string("failed"))
        #expect(failure.first?.objectValue?["toolCallId"] == followup.first?.objectValue?["toolCallId"])
        #expect(failure.first?.objectValue?["sessionUpdate"] == .string("tool_call_update"))
        for update in failure { await projection.acknowledge(update) }
        #expect(await projection.updates([snapshot(.running, execution: 2)]).isEmpty)
        let third = await projection.updates([snapshot(.running, execution: 3, completed: 1)])
        #expect(third.first?.objectValue?["status"] == .string("in_progress"))
        let response = await projection.updates([snapshot(.idle, execution: 3, completed: 3)])
        #expect(response.first?.objectValue?["status"] == .string("completed"))
    }

    @Test func retriesHaveSeparateAttemptToolIDs() async {
        let attempts = [
            TaskAttempt(id: "first", ordinal: 1, agentID: "a", executor: .subAgent, status: .failed, startedAt: .now),
            TaskAttempt(id: "retry", ordinal: 2, agentID: "b", executor: .subAgent, status: .running, startedAt: .now)
        ]
        let graph = TaskGraphSnapshot(id: "graph", source: .manual, state: .active, tasks: [
            TaskRecord(id: "task", title: "Task", order: 0, status: .inProgress, attempts: attempts)
        ])
        let updates = await ACPTaskPresentation().updates(for: graph)
        let ids = updates.compactMap { $0.objectValue?["toolCallId"]?.acpStringValue }
        #expect(Set(ids).count == 2)
        #expect(ids.contains("acp:work:graph:task:first"))
        #expect(ids.contains("acp:work:graph:task:retry"))
    }
}

extension ACPStandardPresentationTests {
    @Test func permissionWireUsesRootButOnlyOfferedAllowOptionsAuthorize() async throws {
        let (stream, continuation) = AsyncStream<JSONValue>.makeStream()
        let writer = ACPWriter { data in
            if let message = try? JSONDecoder().decode(JSONValue.self, from: data) { continuation.yield(message) }
        }
        let broker = ACPPermissionBroker(writer: writer)
        let request = AgentToolAuthorizationRequest(sessionID: "child", toolCallID: "call", toolName: "custom.exec",
            title: "Execute", kind: "execute", command: "command", workingDirectory: "/tmp",
            delegatedIdentity: .init(agentID: "a", rootSessionID: "root"))
        let authorization = Task { await broker.authorize(request) }
        var iterator = stream.makeAsyncIterator()
        let message = try #require(await iterator.next())
        #expect(message.objectValue?["params"]?.objectValue?["sessionId"] == .string("root"))
        await broker.handleResponse(.object([
            "jsonrpc": .string("2.0"), "id": message.objectValue!["id"]!,
            "result": .object(["optionId": .string("allow_unoffered")])
        ]))
        #expect(await authorization.value == false)
        continuation.finish()
    }

    @Test func cleanupFencesAllowAlwaysResponseAlreadyInFlight() async throws {
        let (stream, continuation) = AsyncStream<JSONValue>.makeStream()
        let writer = ACPWriter { data in
            if let message = try? JSONDecoder().decode(JSONValue.self, from: data) { continuation.yield(message) }
        }
        let broker = ACPPermissionBroker(writer: writer)
        let request = AgentToolAuthorizationRequest(sessionID: "child", toolCallID: "call", toolName: "custom.exec",
            title: "Execute", kind: "execute", command: "command", workingDirectory: "/tmp",
            delegatedIdentity: .init(agentID: "a", rootSessionID: "root"))
        let authorization = Task { await broker.authorize(request) }
        var iterator = stream.makeAsyncIterator()
        let message = try #require(await iterator.next())
        await broker.removeCachedDecisions(sessionID: "root")
        await broker.handleResponse(.object([
            "jsonrpc": .string("2.0"), "id": message.objectValue!["id"]!,
            "result": .object(["optionId": .string("allow_always")])
        ]))
        #expect(await authorization.value == false)
        #expect(await broker.cachedDecisionCount(sessionID: "root") == 0)
        continuation.finish()
    }
}

extension ACPStandardPresentationTests {
    @Test func pipelineDrainsAcceptedContentButRejectsLateAdmission() async {
        let valid = Mutex(true)
        let messages = Mutex<[Data]>([])
        let writer = ACPWriter { data in messages.withLock { $0.append(data) } }
        let pipeline = ACPPromptUpdatePipeline(sessionID: "root", writer: writer,
            buffer: ACPPromptUpdateBuffer(), isValid: { valid.withLock { $0 } })
        await pipeline.enqueue(.init(kind: .consume(.object([
            "sessionUpdate": .string("agent_message_chunk"),
            "content": .object(["type": .string("text"), "text": .string("buffered")])
        ])))).value
        valid.withLock { $0 = false }
        await pipeline.enqueue(.init(kind: .consume(ZenCODEACPBridge.textChunkJSONUpdate(
            kind: "agent_message_chunk", text: "late-rejected"
        )))).value
        await pipeline.enqueue(.init(kind: .flush)).value
        await pipeline.drain()
        let wire = messages.withLock { $0.map { String(decoding: $0, as: UTF8.self) }.joined() }
        #expect(wire.contains("buffered"))
        #expect(!wire.contains("late-rejected"))
    }
}

extension ACPStandardPresentationTests {
    @Test func cancelledDelegatedPermissionCannotAuthorizeRecreatedRoot() async throws {
        let (stream, continuation) = AsyncStream<JSONValue>.makeStream()
        let writer = ACPWriter { data in
            if let message = try? JSONDecoder().decode(JSONValue.self, from: data) { continuation.yield(message) }
        }
        let broker = ACPPermissionBroker(writer: writer)
        let request = AgentToolAuthorizationRequest(sessionID: "child", toolCallID: "call", toolName: "custom.exec",
            title: "Execute", kind: "execute", command: "command", workingDirectory: "/tmp",
            delegatedIdentity: .init(agentID: "agent", rootSessionID: "root"))
        var iterator = stream.makeAsyncIterator()
        let first = Task { await broker.authorize(request) }
        let old = try #require(await iterator.next())
        first.cancel()
        await broker.removeCachedDecisions(sessionID: "root")
        #expect(await first.value == false)
        let second = Task { await broker.authorize(request) }
        let current = try #require(await iterator.next())
        #expect(old.objectValue?["id"] != current.objectValue?["id"])
        #expect(current.objectValue?["params"]?.objectValue?["sessionId"] == .string("root"))
        #expect(current.objectValue?["params"]?.objectValue?["toolCall"]?.objectValue?["toolCallId"] == .string("acp:tool:agent:call"))
        await broker.handleResponse(.object([
            "jsonrpc": .string("2.0"), "id": old.objectValue!["id"]!,
            "result": .object(["optionId": .string("allow_always")])
        ]))
        #expect(await broker.cachedDecisionCount(sessionID: "root") == 0)
        await broker.handleResponse(.object([
            "jsonrpc": .string("2.0"), "id": current.objectValue!["id"]!,
            "result": .object(["optionId": .string("allow_unoffered")])
        ]))
        #expect(await second.value == false)
        #expect(await broker.cachedDecisionCount(sessionID: "root") == 0)
        continuation.finish()
    }
}

extension ACPStandardPresentationTests {
    @Test func tasklessAcknowledgementRequiresPipelineAcceptance() async throws {
        let projection = ACPTasklessPresentation()
        let terminal = DirectSubAgentRuntime.AgentSnapshot(
            id: "a", rootSessionID: "root", name: "Agent", role: "Worker", status: .idle,
            pending: false, latestOutput: "Done", executionRevision: 1,
            completedExecutionRevision: 1, latestOutputRevision: 1, latestError: nil, createdAt: .now, updatedAt: .now)
        let update = try #require(await projection.updates([terminal]).first)
        let valid = Mutex(false)
        let deliver = Mutex(true)
        let output = Mutex<[Data]>([])
        let pipeline = ACPPromptUpdatePipeline(sessionID: "root",
            writer: ACPWriter { data in output.withLock { $0.append(data) } },
            buffer: ACPPromptUpdateBuffer(), buffersUpdates: false,
            isValid: { valid.withLock { $0 } }, canDeliver: { deliver.withLock { $0 } })
        await pipeline.enqueue(.init(kind: .consume(update)), onAccepted: {
            await projection.acknowledge(update)
        }).value
        #expect(await projection.updates([terminal]) == [update])
        valid.withLock { $0 = true }
        deliver.withLock { $0 = false }
        await pipeline.enqueue(.init(kind: .consume(update)), onAccepted: {
            await projection.acknowledge(update)
        }).value
        #expect(await projection.updates([terminal]) == [update])
        #expect(output.withLock { $0.isEmpty })
        deliver.withLock { $0 = true }
        await pipeline.enqueue(.init(kind: .consume(update)), onAccepted: {
            await projection.acknowledge(update)
        }).value
        #expect(await projection.updates([terminal]).isEmpty)
        #expect(output.withLock { $0.count } == 1)
    }
}
