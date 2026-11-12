import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct DirectTaskToolAdapterTests {
    @Test
    func taskBoundSessionReceivesScopedTaskUpdateDescriptionOnly() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "work", title: "Work")]
        )
        let receipt = try #require(try await orchestrator.claimTasks(
            sessionID: "root",
            claims: [TaskClaim(taskID: "work", agentID: "worker")]
        ).first)
        try await orchestrator.registerExecutionScope(
            executionSessionID: "child",
            scope: TaskExecutionScope(
                rootSessionID: "root",
                graphID: receipt.graphID,
                taskID: receipt.taskID,
                attemptID: receipt.attemptID
            )
        )
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory:
                DirectSubAgentRuntime.unavailableContextualBackendFactory
        )
        await executor.installTaskOrchestrator(orchestrator)

        let rootDescriptor = try #require(await executor.descriptors(
            allowedToolNames: ["tasks.update"],
            sessionID: "root"
        ).first)
        let childDescriptor = try #require(await executor.descriptors(
            allowedToolNames: ["tasks.update"],
            sessionID: "child"
        ).first)

        #expect(rootDescriptor.description.contains("Updates task metadata"))
        #expect(!rootDescriptor.description.contains("As a task-bound sub-agent"))
        #expect(childDescriptor.description.contains("As a task-bound sub-agent"))
        #expect(childDescriptor.description.contains("final response is recorded automatically"))
        #expect(childDescriptor.inputSchema != rootDescriptor.inputSchema)
        #expect(childDescriptor.inputSchema.contains("\"progress\""))
        #expect(childDescriptor.inputSchema.contains("\"output\""))
        #expect(!childDescriptor.inputSchema.contains("\"dependsOn\""))
        #expect(!childDescriptor.inputSchema.contains("\"evidence\""))
        #expect(!childDescriptor.inputSchema.contains("\"status\""))
        #expect(!childDescriptor.inputSchema.contains("\"workflow\""))
        #expect(rootDescriptor.inputSchema.contains("\"workflow\""))
    }

    @Test
    func taskUpdatePayloadSchemasFollowTheSessionForBothOpenAIWireFormats() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "work", title: "Work")]
        )
        let receipt = try #require(try await orchestrator.claimTasks(
            sessionID: "root",
            claims: [TaskClaim(taskID: "work", agentID: "worker")]
        ).first)
        try await orchestrator.registerExecutionScope(
            executionSessionID: "child",
            scope: TaskExecutionScope(
                rootSessionID: "root",
                graphID: receipt.graphID,
                taskID: receipt.taskID,
                attemptID: receipt.attemptID
            )
        )
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory:
                DirectSubAgentRuntime.unavailableContextualBackendFactory
        )
        await executor.installTaskOrchestrator(orchestrator)

        let rootProperties = try await executor.taskUpdatePayloadPropertiesForTesting(
            sessionID: "root"
        )
        let childProperties = try await executor.taskUpdatePayloadPropertiesForTesting(
            sessionID: "child"
        )

        let rootExpected = ["dependsOn", "evidence", "status", "workflow"]
        let childExpected = ["output", "progress", "statusReason", "expectedRevision"]
        for properties in [
            rootProperties.responses,
            rootProperties.chatCompletions,
        ] {
            for name in rootExpected {
                #expect(properties.contains(name))
            }
        }
        for properties in [
            childProperties.responses,
            childProperties.chatCompletions,
        ] {
            for name in childExpected {
                #expect(properties.contains(name))
            }
            for name in rootExpected {
                #expect(!properties.contains(name))
            }
        }
    }

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
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "tasks") == nil)
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "agents") == nil)
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "send_input") == nil)
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "retry_task") == nil)
        #expect(SubAgentToolRequestCompatibility.canonicalToolName(for: "cancel_task") == nil)
        #expect(DirectTaskToolAdapter.isTaskToolName("tasks.create"))
        #expect(!DirectTaskToolAdapter.isTaskToolName("task.create"))
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
    func workflowTaskCreationSupportsDirectAndDelegatedWork() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "workflow-session", id: "workflow", source: .workflow,
            state: .active, tasks: []
        )
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)
        _ = try await adapter.execute(
            sessionID: "workflow-session",
            toolCall: call(name: "tasks.create", arguments: ["tasks": [
                ["id": "direct", "title": "Direct", "execution": ["executor": "coordinator"]],
                ["id": "delegated", "title": "Delegated", "execution": ["executor": "sub_agent"]],
            ]])
        )
        for status in ["in_progress", "completed"] {
            _ = try await adapter.execute(
                sessionID: "workflow-session",
                toolCall: call(name: "tasks.update", arguments: ["id": "direct", "status": status])
            )
        }
        let direct = try await orchestrator.task(sessionID: "workflow-session", taskID: "direct").task
        #expect(direct.status == .completed)
        #expect(direct.attempts.last?.executor == .coordinator)
        #expect(direct.attempts.last?.status == .completed)
        #expect(try await orchestrator.task(
            sessionID: "workflow-session", taskID: "delegated"
        ).task.execution.executor == .subAgent)
        #expect(try await orchestrator.graphSnapshot(sessionID: "workflow-session")?.state == .active)
    }

    @Test
    func workflowValidationFailureIsRetriedThroughTaskAdapterBeforeANewClaim() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "workflow-session",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "implementation",
                    title: "Implement",
                    execution: TaskExecutionSpec(executor: .subAgent)
                )
            ]
        )
        let first = try #require(try await orchestrator.claimTasks(
            sessionID: "workflow-session",
            claims: [TaskClaim(taskID: "implementation", agentID: "worker-1")]
        ).first)
        _ = try await orchestrator.completeAttempt(
            sessionID: "workflow-session",
            taskID: "implementation",
            attemptID: first.attemptID,
            output: "implementation complete",
            requiresValidation: false
        )
        _ = try await orchestrator.validateTaskResult(
            sessionID: "workflow-session",
            taskID: "implementation",
            succeeded: false,
            failureReason: "validation failed"
        )

        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)
        _ = try await adapter.execute(
            sessionID: "workflow-session",
            toolCall: call(name: "tasks.retry", arguments: ["id": "implementation"])
        )

        let pending = try await orchestrator.task(
            sessionID: "workflow-session",
            taskID: "implementation"
        ).task
        #expect(pending.status == .pending)
        #expect(pending.attempts.count == 1)
        let second = try #require(try await orchestrator.claimTasks(
            sessionID: "workflow-session",
            claims: [TaskClaim(taskID: "implementation", agentID: "worker-2")]
        ).first)
        #expect(second.ordinal == 2)
        #expect(second.attemptID != first.attemptID)
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

    @Test
    func executorEnforcesScopedTaskUpdateBeyondAdvertisedDescriptor() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "work", title: "Work")]
        )
        let receipt = try #require(try await orchestrator.claimTasks(
            sessionID: "root",
            claims: [TaskClaim(taskID: "work", agentID: "worker")]
        ).first)
        try await orchestrator.registerExecutionScope(
            executionSessionID: "child",
            scope: TaskExecutionScope(
                rootSessionID: "root",
                graphID: receipt.graphID,
                taskID: receipt.taskID,
                attemptID: receipt.attemptID
            )
        )
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory:
                DirectSubAgentRuntime.unavailableContextualBackendFactory
        )
        await executor.installTaskOrchestrator(orchestrator)

        let forbidden = await executor.execute(
            sessionID: "child",
            toolCall: call(
                name: "tasks.update",
                arguments: ["id": "work", "status": "completed"]
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            allowedToolNames: ["tasks.update"]
        )
        #expect(forbidden.status == .failed)
        #expect(
            forbidden.output.contains(
                "may only append progress output to its own attempt"
            )
        )
        #expect(
            try await orchestrator.task(sessionID: "root", taskID: "work").task.status
                == .inProgress
        )

        let progress = await executor.execute(
            sessionID: "child",
            toolCall: call(
                name: "tasks.update",
                arguments: ["id": "work", "output": "still working"]
            ),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            allowedToolNames: ["tasks.update"]
        )
        #expect(progress.status == .completed)
        #expect(
            try await orchestrator.task(sessionID: "root", taskID: "work")
                .task.activeAttempt?.output == "still working"
        )
    }

    @Test
    func executorRejectsTaskCancelWithoutExplicitSessionInsteadOfUsingDefault() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "default",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "work", title: "Work")]
        )
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory:
                DirectSubAgentRuntime.unavailableContextualBackendFactory
        )
        await executor.installTaskOrchestrator(orchestrator)

        let result = await executor.execute(
            sessionID: nil,
            toolCall: call(name: "tasks.cancel", arguments: ["id": "work"]),
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            allowedToolNames: ["tasks.cancel"]
        )

        #expect(result.status == .failed)
        #expect(result.output.contains("requires an explicit sessionID"))
        #expect(
            try await orchestrator.task(sessionID: "default", taskID: "work").task.status
                == .pending
        )
    }

    // MARK: - Legacy input forms
    //
    // The model-visible schemas expose only canonical properties. The tests below
    // pin the aliases and legacy shapes that stay invisible but accepted.

    @Test
    func tasksCreateAcceptsLegacyItemsAndSnakeCaseKeys() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)
        let sessionID = "legacy-create-\(UUID().uuidString)"

        _ = try await adapter.execute(
            sessionID: sessionID,
            toolCall: call(name: "tasks.create", arguments: [
                "graph_id": "legacy-graph",
                "items": [
                    [
                        "task_id": "base",
                        "name": "Base",
                        "details": "Foundation work",
                        "execution": ["executor": "coordinator"],
                    ],
                    [
                        "id": "feature",
                        "title": "Feature",
                        "depends_on": ["base"],
                        "acceptance_criteria": ["It compiles", "It is tested"],
                        "execution": ["executor": "sub_agent", "file_scopes": ["Sources/Feature"]],
                    ],
                ],
            ])
        )

        let graph = try #require(try await orchestrator.graphSnapshot(
            sessionID: sessionID, graphID: "legacy-graph"
        ))
        #expect(graph.id == "legacy-graph")
        #expect(graph.tasks.map(\.id) == ["base", "feature"])

        let base = try await orchestrator.task(
            sessionID: sessionID, taskID: "base", graphID: "legacy-graph"
        ).task
        #expect(base.title == "Base")
        #expect(base.details == "Foundation work")
        #expect(base.execution.executor == .coordinator)

        let feature = try await orchestrator.task(
            sessionID: sessionID, taskID: "feature", graphID: "legacy-graph"
        ).task
        #expect(feature.dependsOn == ["base"])
        #expect(feature.acceptanceCriteria == ["It compiles", "It is tested"])
        #expect(feature.execution.executor == .subAgent)
        #expect(feature.execution.fileScopes == ["Sources/Feature"])
    }

    @Test
    func tasksCreateAcceptsASingleTaskInRootForm() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)
        let sessionID = "legacy-root-form-\(UUID().uuidString)"

        _ = try await adapter.execute(
            sessionID: sessionID,
            toolCall: call(name: "tasks.create", arguments: [
                "id": "solo",
                "title": "Solo",
                "description": "Single task without a tasks array",
                "priority": "high",
                "complexity": 3,
                "acceptanceCriteria": ["Done"],
                "execution": ["executor": "sub_agent", "role": "reviewer"],
            ])
        )

        let solo = try await orchestrator.task(sessionID: sessionID, taskID: "solo").task
        #expect(solo.title == "Solo")
        #expect(solo.details == "Single task without a tasks array")
        #expect(solo.priority == .high)
        #expect(solo.complexity == 3)
        #expect(solo.order == 1)
        #expect(solo.acceptanceCriteria == ["Done"])
        #expect(solo.execution.executor == .subAgent)
        #expect(solo.execution.role == "reviewer")
    }

    @Test
    func tasksUpdateAcceptsLegacySnakeCaseKeys() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let sessionID = "legacy-update-\(UUID().uuidString)"
        _ = try await orchestrator.createGraph(
            sessionID: sessionID,
            id: "legacy-graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "work", title: "Work")]
        )
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)

        _ = try await adapter.execute(
            sessionID: sessionID,
            toolCall: call(name: "tasks.update", arguments: [
                "task_id": "work",
                "graph_id": "legacy-graph",
                "status": "in_progress",
                "status_reason": "picked up",
                "progress": "step 1",
            ])
        )
        let started = try await orchestrator.task(
            sessionID: sessionID, taskID: "work", graphID: "legacy-graph"
        ).task
        #expect(started.status == .inProgress)
        #expect(started.statusReason == "picked up")
        #expect(started.activeAttempt?.output == "step 1")

        // A stale expected_revision must be read and enforced, leaving the task untouched.
        do {
            _ = try await adapter.execute(
                sessionID: sessionID,
                toolCall: call(name: "tasks.update", arguments: [
                    "task_id": "work",
                    "graph_id": "legacy-graph",
                    "expected_revision": started.revision + 100,
                    "progress": "step 2",
                ])
            )
            Issue.record("A stale expected_revision should have been rejected.")
        } catch SessionTaskOrchestratorError.staleRevision(let expected, let actual) {
            #expect(expected == started.revision + 100)
            #expect(actual == started.revision)
        }
        #expect(try await orchestrator.task(
            sessionID: sessionID, taskID: "work", graphID: "legacy-graph"
        ).task.activeAttempt?.output == "step 1")

        _ = try await adapter.execute(
            sessionID: sessionID,
            toolCall: call(name: "tasks.update", arguments: [
                "task_id": "work",
                "graph_id": "legacy-graph",
                "expected_revision": started.revision,
                "progress": "step 2",
            ])
        )
        #expect(try await orchestrator.task(
            sessionID: sessionID, taskID: "work", graphID: "legacy-graph"
        ).task.activeAttempt?.output == "step 2")
    }

    @Test
    func tasksListGetRetryAndCancelAcceptLegacySnakeCaseKeys() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let sessionID = "legacy-read-\(UUID().uuidString)"
        _ = try await orchestrator.createGraph(
            sessionID: sessionID,
            id: "legacy-graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(id: "a", title: "A"),
                TaskDefinition(id: "b", title: "B", dependsOn: ["a"]),
            ]
        )
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)

        let runnable = try await adapter.execute(
            sessionID: sessionID,
            toolCall: call(name: "tasks.list", arguments: [
                "graph_id": "legacy-graph",
                "runnable_only": true,
            ])
        )
        #expect(runnable.contains(" a: A"))
        #expect(!runnable.contains(" b: B"))

        let detail = try await adapter.execute(
            sessionID: sessionID,
            toolCall: call(name: "tasks.get", arguments: [
                "task_id": "b",
                "graph_id": "legacy-graph",
            ])
        )
        #expect(detail.contains(" b: B"))

        do {
            _ = try await adapter.execute(
                sessionID: sessionID,
                toolCall: call(name: "tasks.retry", arguments: [
                    "task_id": "a",
                    "graph_id": "legacy-graph",
                    "expected_revision": 999,
                ])
            )
            Issue.record("A stale expected_revision should have been rejected.")
        } catch SessionTaskOrchestratorError.staleRevision(let expected, _) {
            #expect(expected == 999)
        }

        _ = try await adapter.execute(
            sessionID: sessionID,
            toolCall: call(name: "tasks.cancel", arguments: [
                "task_id": "b",
                "graph_id": "legacy-graph",
                "message": "no longer needed",
            ])
        )
        #expect(try await orchestrator.task(
            sessionID: sessionID, taskID: "b", graphID: "legacy-graph"
        ).task.status == .cancelled)
        #expect(try await orchestrator.task(
            sessionID: sessionID, taskID: "a", graphID: "legacy-graph"
        ).task.status == .pending)
    }

    /// tasks.retry's hint is one of the places that state the retry mechanics
    /// after the prompt policies stopped repeating them; keep it complete.
    @Test
    func retryAfterAFailedAttemptReturnsTheCompleteNewAttemptHint() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let sessionID = "retry-hint-\(UUID().uuidString)"
        _ = try await orchestrator.createGraph(
            sessionID: sessionID,
            id: "retry-graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "a", title: "A")]
        )
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)
        _ = try await adapter.execute(
            sessionID: sessionID,
            toolCall: call(name: "tasks.update", arguments: ["id": "a", "status": "in_progress"])
        )
        _ = try await adapter.execute(
            sessionID: sessionID,
            toolCall: call(name: "tasks.update", arguments: ["id": "a", "status": "failed", "error": "boom"])
        )

        let retried = try await adapter.execute(
            sessionID: sessionID,
            toolCall: call(name: "tasks.retry", arguments: ["id": "a"])
        )

        #expect(retried.contains("Hint: 1 previous attempt on this task"))
        #expect(retried.contains("start a new direct attempt with tasks.update status in_progress"))
        #expect(retried.contains("lowest-capability authorized model binding that meets the task complexity"))
        #expect(retried.contains("omit model in agent.create to inherit the main session model and provider"))
        #expect(retried.contains("Put taskID in the new agents item"))
        #expect(retried.contains("cannot reopen a closed attempt"))
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

private struct ToolPayloadPropertySets: Sendable {
    let responses: Set<String>
    let chatCompletions: Set<String>
}

private extension DirectToolExecutor {
    /// Keeps the non-Sendable `[String: Any]` wire payload inside the actor and
    /// transfers only its Sendable property-name projection to the test.
    func taskUpdatePayloadPropertiesForTesting(
        sessionID: String
    ) async throws -> ToolPayloadPropertySets {
        let responses = await responsesToolPayloads(
            sessionID: sessionID,
            allowedToolNames: ["tasks.update"]
        )
        let chatCompletions = await chatCompletionToolPayloads(
            sessionID: sessionID,
            allowedToolNames: ["tasks.update"]
        )
        return try ToolPayloadPropertySets(
            responses: payloadProperties(responses, chatCompletions: false),
            chatCompletions: payloadProperties(chatCompletions, chatCompletions: true)
        )
    }

    func payloadProperties(
        _ payloads: [[String: Any]],
        chatCompletions: Bool
    ) throws -> Set<String> {
        let payload = try #require(payloads.first)
        let parameters: [String: Any]
        if chatCompletions {
            let function = try #require(payload["function"] as? [String: Any])
            parameters = try #require(function["parameters"] as? [String: Any])
        } else {
            parameters = try #require(payload["parameters"] as? [String: Any])
        }
        return Set(try #require(parameters["properties"] as? [String: Any]).keys)
    }
}
