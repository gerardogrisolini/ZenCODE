import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct DirectTaskToolAdapterTests {
    @Test
    func tasksNamespaceIsCanonicalAndSingularNamespaceIsRejected() {
        let advertisedNames = DirectToolCatalog.todoTaskDescriptors
            .map(\.name)
            .filter { $0.hasPrefix("tasks.") || $0.hasPrefix("task.") }
        #expect(advertisedNames == [
            "tasks.create",
            "tasks.list",
            "tasks.get",
            "tasks.update",
            "tasks.retry",
            "tasks.cancel",
        ])

        for action in ["create", "list", "get", "update", "retry", "cancel"] {
            let canonicalName = "tasks.\(action)"
            #expect(
                SubAgentToolRequestCompatibility.canonicalToolName(for: canonicalName)
                    == canonicalName
            )
            #expect(
                SubAgentToolRequestCompatibility.canonicalToolName(for: "task.\(action)")
                    == nil
            )
            #expect(
                SubAgentToolRequestCompatibility.canonicalToolName(for: "task_\(action)")
                    == nil
            )
        }
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "retry_task") == nil)
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "cancel_task") == nil)
        #expect(DirectTaskToolAdapter.isTaskToolName("tasks.create"))
        #expect(!DirectTaskToolAdapter.isTaskToolName("task.create"))
        #expect(ToolCallPresentation.toolKind(for: "task.list") == "other")
        #expect(!DirectToolExecutor.isAllowed(
            "tasks.list",
            allowedToolNames: ["task.list"]
        ))
        #expect(!DirectToolExecutor.isAllowed(
            "tasks.list",
            allowedToolNames: ["task."]
        ))
        #expect(!DirectToolExecutor.isAllowed(
            "task.list",
            allowedToolNames: ["tasks."]
        ))
        #expect(!DirectToolExecutor.isAllowed(
            "tasks.update",
            allowedToolNames: ["feature.task.update"]
        ))
    }

    @Test
    func adaptersShareAuthoritativeGraphAcrossExecutors() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let first = DirectTaskToolAdapter()
        let second = DirectTaskToolAdapter()
        await first.installTaskOrchestrator(orchestrator)
        await second.installTaskOrchestrator(orchestrator)

        _ = try await first.execute(
            sessionID: "session",
            toolCall: call(
                name: "tasks.create",
                arguments: [
                    "graphID": "graph",
                    "tasks": [
                        ["id": "a", "title": "A", "priority": "high"],
                        ["id": "b", "title": "B", "dependsOn": ["a"]],
                    ],
                ]
            )
        )
        let output = try await second.execute(
            sessionID: "session",
            toolCall: call(name: "tasks.list", arguments: [:])
        )

        #expect(output.contains("Task graph graph"))
        #expect(output.contains("[pending] a: A"))
        #expect(output.contains("[pending] b: B"))
        #expect(output.contains("blocked_by=a"))
    }

    @Test
    func invalidBatchDoesNotPartiallyCreateTasks() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await adapter.execute(
                sessionID: "session",
                toolCall: call(
                    name: "tasks.create",
                    arguments: [
                        "tasks": [
                            ["id": "a", "title": "A"],
                            ["id": "b", "title": "B", "dependsOn": ["missing"]],
                        ]
                    ]
                )
            )
        }
        #expect(try await orchestrator.graphSnapshot(sessionID: "session") == nil)
    }

    @Test
    func taskCreateAcceptsTitlesLongerThanTheFormerLimit() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)
        let longTitle = String(repeating: "x", count: 1_024)

        _ = try await adapter.execute(
            sessionID: "session",
            toolCall: call(
                name: "tasks.create",
                arguments: [
                    "graphID": "graph",
                    "id": "long-title",
                    "title": longTitle,
                ]
            )
        )

        #expect(try await orchestrator.task(
            sessionID: "session",
            taskID: "long-title"
        ).task.title == longTitle)
    }

    @Test
    func delegatedScopeCanReadOwnTaskAndAppendProgressOnly() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(id: "a", title: "A"),
                TaskDefinition(id: "b", title: "B"),
            ]
        )
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "other-graph",
            source: .manual,
            state: .archived,
            tasks: [TaskDefinition(id: "b", title: "Archived B")],
            makeCurrent: false
        )
        let receipt = try #require(try await orchestrator.claimTasks(
            sessionID: "root",
            claims: [TaskClaim(taskID: "b", agentID: "worker")]
        ).first)
        try await orchestrator.registerExecutionScope(
            executionSessionID: "child",
            scope: TaskExecutionScope(
                rootSessionID: "root",
                graphID: receipt.graphID,
                taskID: "b",
                attemptID: receipt.attemptID
            )
        )
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)

        let list = try await adapter.execute(
            sessionID: "child",
            toolCall: call(name: "tasks.list", arguments: [:])
        )
        #expect(list.contains(" b: B"))
        #expect(!list.contains(" a: A"))

        _ = try await adapter.execute(
            sessionID: "child",
            toolCall: call(
                name: "tasks.update",
                arguments: ["id": "b", "output": "progress"]
            )
        )
        #expect(try await orchestrator.task(
            sessionID: "root", taskID: "b"
        ).task.activeAttempt?.output == "progress")

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await adapter.execute(
                sessionID: "child",
                toolCall: call(
                    name: "tasks.update",
                    arguments: ["id": "b", "status": "completed"]
                )
            )
        }
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await adapter.execute(
                sessionID: "child",
                toolCall: call(name: "tasks.get", arguments: ["id": "a"])
            )
        }
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await adapter.execute(
                sessionID: "child",
                toolCall: call(
                    name: "tasks.list",
                    arguments: ["graphID": "other-graph"]
                )
            )
        }
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await adapter.execute(
                sessionID: "child",
                toolCall: call(
                    name: "tasks.create",
                    arguments: ["id": "child-task", "title": "Escape scope"]
                )
            )
        }

        let subAgentRuntime = DirectSubAgentRuntime(
            contextualBackendFactory: DirectSubAgentRuntime.unavailableContextualBackendFactory
        )
        await subAgentRuntime.installTaskOrchestrator(orchestrator)
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await subAgentRuntime.createAgents(
                arguments: ["name": .string("nested")],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-task-scope"),
                parentAllowedToolNames: nil,
                rootSessionID: "child"
            )
        }
    }

    private func call(name: String, arguments: [String: Any]) -> DirectAgentToolCall {
        let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return DirectAgentToolCall(
            id: UUID().uuidString,
            name: name,
            argumentsObject: arguments,
            argumentsJSON: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        )
    }
}
