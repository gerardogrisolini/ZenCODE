import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// The ACP projection reads only the graph of the shared overview, so the
/// overview a test hands it carries no task views.
private func taskOverview(_ graph: TaskGraphSnapshot?) -> ChatTaskGraphOverview? {
    graph.map { ChatTaskGraphOverview(graph: $0, tasks: []) }
}

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

    @Test func taskAttemptTerminalAfterTeardownUsesUpdateInNextPrompt() async throws {
        let projection = ACPTaskPresentation()
        let startedAt = Date(timeIntervalSince1970: 1)
        func graph(status: TaskAttemptStatus, output: String? = nil) -> TaskGraphSnapshot {
            let attempt = TaskAttempt(id: "attempt", ordinal: 1, agentID: "worker", executor: .subAgent,
                                      status: status, startedAt: startedAt,
                                      finishedAt: status == .completed ? Date(timeIntervalSince1970: 2) : nil,
                                      output: output)
            return TaskGraphSnapshot(id: "graph", source: .manual, state: .active, tasks: [
                TaskRecord(id: "task", title: "Work", order: 0,
                           status: status == .completed ? .completed : .inProgress,
                           attempts: [attempt])
            ])
        }

        // Prompt A emits and admits the running attempt before its teardown.
        let promptA = await projection.updates(for: taskOverview(graph(status: .running)))
        let start = try #require(promptA.first {
            $0.objectValue?["toolCallId"] == .string("acp:work:graph:task:attempt")
        })
        #expect(start.objectValue?["sessionUpdate"] == .string("tool_call"))
        for update in promptA { await projection.acknowledge(update) }

        // The terminal graph arrives after teardown; prompt B must continue the
        // already admitted row instead of opening a second tool call.
        let promptB = await projection.updates(for: taskOverview(graph(status: .completed, output: "done")))
        let terminal = try #require(promptB.first {
            $0.objectValue?["toolCallId"] == .string("acp:work:graph:task:attempt")
        })
        #expect(promptB.filter { $0.objectValue?["toolCallId"] == .string("acp:work:graph:task:attempt") }.count == 1)
        #expect(terminal.objectValue?["sessionUpdate"] == .string("tool_call_update"))
        #expect(terminal.objectValue?["status"] == .string("completed"))
        await projection.acknowledge(terminal)
        let terminalReplay = (await projection.updates(for: taskOverview(graph(status: .completed, output: "done")))).filter {
            $0.objectValue?["toolCallId"] == .string("acp:work:graph:task:attempt")
        }
        #expect(terminalReplay.isEmpty)
    }
}

extension ACPStandardPresentationTests {
    @Test func permissionWireUsesRootButOnlyOfferedAllowOptionsAuthorize() async throws {
        let (stream, continuation) = AsyncStream<JSONValue>.makeStream()
        let writer = ACPWriter { data in
            if let message = try? JSONDecoder().decode(JSONValue.self, from: data) { continuation.yield(message) }
        }
        let broker = ACPPermissionBroker(writer: writer)
        let request = AgentToolAuthorizationRequest(sessionID: "child", toolCallID: "call", toolName: "git.push",
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
        let request = AgentToolAuthorizationRequest(sessionID: "child", toolCallID: "call", toolName: "git.push",
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
    @Test func cancelledDelegatedPermissionCannotAuthorizeRecreatedRoot() async throws {
        let (stream, continuation) = AsyncStream<JSONValue>.makeStream()
        let writer = ACPWriter { data in
            if let message = try? JSONDecoder().decode(JSONValue.self, from: data) { continuation.yield(message) }
        }
        let broker = ACPPermissionBroker(writer: writer)
        let request = AgentToolAuthorizationRequest(sessionID: "child", toolCallID: "call", toolName: "git.push",
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
