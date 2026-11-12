//
//  RemoteToolBatchConcurrencyTests.swift
//  ZenCODECoreTests
//
//  Consecutive calls of one tool batch to core tools that only read run
//  together; every other call runs alone, in the order the model emitted it.
//  Events and results keep the order of the calls either way.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// How many calls are in flight, and the most that were at once.
private final class InFlightCounter: Sendable {
    private let state = Mutex((current: 0, peak: 0))

    func enter() {
        state.withLock {
            $0.current += 1
            $0.peak = max($0.peak, $0.current)
        }
    }

    func leave() {
        state.withLock { $0.current -= 1 }
    }

    var peak: Int {
        state.withLock { $0.peak }
    }
}

private final class LineLog: Sendable {
    private let lines = Mutex<[String]>([])

    func append(_ line: String) {
        lines.withLock { $0.append(line) }
    }

    var values: [String] {
        lines.withLock { $0 }
    }
}

@Suite
struct RemoteToolBatchConcurrencyTests {
    private static let readToolName = PromptSkillToolProvider.toolName
    private static let writeToolName = "fixture.write"

    @Test
    func consecutiveReadOnlyCallsRunTogetherAndTheOthersAlone() async throws {
        let reads = InFlightCounter()
        let writes = InFlightCounter()
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentContextualBackendFactory: DirectSubAgentRuntime.unavailableContextualBackendFactory
        )
        // `skills.read` is a core tool that only reads and is served by a
        // tool provider, so this provider can observe its executions.
        await executor.updateToolProviders([
            AgentToolProvider(
                tools: [Self.readToolName, Self.writeToolName].map { name in
                    ToolDescriptor(name: name, description: "Fixture.", inputSchema: #"{"type":"object"}"#)
                },
                executor: { call in
                    guard call.name == Self.readToolName else {
                        writes.enter()
                        defer { writes.leave() }
                        try await Task.sleep(for: .milliseconds(10))
                        return "wrote \(call.id)"
                    }
                    reads.enter()
                    defer { reads.leave() }
                    // In flight until a second read has started as well.
                    let deadline = ContinuousClock.now + .seconds(2)
                    while reads.peak < 2, ContinuousClock.now < deadline {
                        try await Task.sleep(for: .milliseconds(5))
                    }
                    return "read \(call.id)"
                }
            )
        ])
        let calls = [
            ("a", Self.readToolName), ("b", Self.readToolName),
            ("c", Self.writeToolName), ("d", Self.writeToolName),
            ("e", Self.readToolName)
        ].map { id, name in
            DirectAgentToolCall(id: id, name: name, argumentsObject: [:], argumentsJSON: "{}")
        }
        let session = RemoteToolDispatchSession(
            sessionID: "batch",
            workingDirectory: FileManager.default.temporaryDirectory,
            allowedToolNames: nil
        )
        let events = LineLog()
        let results = LineLog()

        #expect(
            RemoteToolBatchDispatcher.dispatchGroups(of: calls).map { $0.map(\.id) }
                == [["a", "b"], ["c"], ["d"], ["e"]]
        )
        try await RemoteToolBatchDispatcher.dispatch(
            calls,
            toolExecutor: executor,
            currentSession: { session },
            appendToolResults: { messages in
                for message in messages {
                    results.append(
                        "\(message["tool_call_id"] as? String ?? "?")=\(message["content"] as? String ?? "?")"
                    )
                }
                return true
            },
            missingSessionError: CancellationError(),
            onEvent: { event in
                switch event {
                case let .toolCallStarted(call):
                    events.append("start \(call.id)")
                case let .toolCallCompleted(call, _):
                    events.append("end \(call.id)")
                default:
                    break
                }
            }
        )

        // The two reads overlapped; the writes never did.
        #expect(reads.peak == 2)
        #expect(writes.peak == 1)
        // Every call still reports a start followed by its completion, and
        // the results are in the order of the calls.
        #expect(events.values == [
            "start a", "end a", "start b", "end b",
            "start c", "end c", "start d", "end d", "start e", "end e"
        ])
        #expect(results.values == ["a=read a", "b=read b", "c=wrote c", "d=wrote d", "e=read e"])
        await executor.shutdown()
    }
}
