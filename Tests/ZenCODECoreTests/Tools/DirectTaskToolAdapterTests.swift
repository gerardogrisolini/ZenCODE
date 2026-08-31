import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct DirectTaskToolAdapterTests {
    @Test
    func tasksCreateDescriptorExplainsCanonicalBatchAndAgentClaimShapes() throws {
        let descriptor = try #require(
            DirectToolCatalog.todoTaskDescriptors.first { $0.name == "tasks.create" }
        )

        #expect(descriptor.description.contains("canonical tasks array"))
        #expect(descriptor.description.contains("do not mix it with root-level single-task fields"))
        #expect(descriptor.description.contains("agent.create agents item's taskID field"))
    }

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

        let rootExpected = ["dependsOn", "evidence", "status"]
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
    func taskSchemasUseCanonicalEnglishAgentSelectionPolicy() throws {
        for name in ["tasks.create", "tasks.update"] {
            let descriptor = try #require(
                DirectToolCatalog.todoTaskDescriptors.first { $0.name == name }
            )
            #expect(descriptor.inputSchema.contains(TaskRecord.complexityRubric))
            #expect(descriptor.inputSchema.contains(TaskRecord.agentSelectionPolicy))
        }
        let createDescriptor = try #require(
            DirectToolCatalog.todoTaskDescriptors.first { $0.name == "tasks.create" }
        )
        #expect(createDescriptor.description.contains("leave independent tasks dependency-free"))
        #expect(createDescriptor.description.contains("safe, useful parallelism"))
        #expect(createDescriptor.description.contains("execution.executor as sub_agent"))
        #expect(createDescriptor.inputSchema.contains("\"sub_agent\""))
        #expect(!createDescriptor.inputSchema.contains("toolNames"))
        #expect(createDescriptor.schemaObject != nil)
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
    func tasksGetFallsBackToTaskIDWhenIDIsBlank() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "work", title: "Work")]
        )
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)

        let output = try await adapter.execute(
            sessionID: "session",
            toolCall: call(
                name: "tasks.get",
                arguments: ["id": "   ", "taskID": "work"]
            )
        )

        #expect(output.contains("work"))
        #expect(output.contains("Work"))
    }

    @Test
    func workflowTaskCreationRequiresSubAgentExecution() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "workflow-session",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: []
        )
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await adapter.execute(
                sessionID: "workflow-session",
                toolCall: call(
                    name: "tasks.create",
                    arguments: ["id": "implementation", "title": "Implement"]
                )
            )
        }

        _ = try await adapter.execute(
            sessionID: "workflow-session",
            toolCall: call(
                name: "tasks.create",
                arguments: [
                    "id": "implementation",
                    "title": "Implement",
                    "execution": ["executor": "sub_agent"],
                ]
            )
        )

        #expect(try await orchestrator.task(
            sessionID: "workflow-session",
            taskID: "implementation"
        ).task.execution.executor == .subAgent)
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
    func taskCreateFallsBackToPopulatedItemsWhenTasksIsEmpty() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)

        _ = try await adapter.execute(
            sessionID: "session",
            toolCall: call(
                name: "tasks.create",
                arguments: [
                    "graphID": "graph",
                    "tasks": [],
                    "items": [
                        ["id": "a", "title": "A"],
                        ["id": "b", "title": "B", "dependsOn": ["a"]],
                    ],
                ]
            )
        )

        let output = try await adapter.execute(
            sessionID: "session",
            toolCall: call(name: "tasks.list", arguments: [:])
        )
        #expect(output.contains("[pending] a: A"))
        #expect(output.contains("[pending] b: B"))
        #expect(output.contains("blocked_by=a"))
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

    @Test
    func complexityIsParsedAndRenderedFromToolCall() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)

        _ = try await adapter.execute(
            sessionID: "session",
            toolCall: call(
                name: "tasks.create",
                arguments: [
                    "graphID": "graph",
                    "tasks": [
                        ["id": "a", "title": "A", "complexity": 3],
                        ["id": "b", "title": "B", "complexity": 9],
                    ],
                ]
            )
        )
        let output = try await adapter.execute(
            sessionID: "session",
            toolCall: call(name: "tasks.list", arguments: [:])
        )

        #expect(output.contains("complexity=3"))
        #expect(output.contains("complexity=9"))
    }

    @Test
    func complexityDefaultIsRenderedWhenNotSpecified() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)

        _ = try await adapter.execute(
            sessionID: "session",
            toolCall: call(
                name: "tasks.create",
                arguments: [
                    "graphID": "graph",
                    "tasks": [["id": "a", "title": "A"]],
                ]
            )
        )
        let output = try await adapter.execute(
            sessionID: "session",
            toolCall: call(name: "tasks.list", arguments: [:])
        )

        #expect(output.contains("complexity=5"))
    }

    @Test
    func retryAppendsEscalationHintAfterFailedAttempt() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let adapter = DirectTaskToolAdapter(orchestrator: orchestrator)

        _ = try await adapter.execute(
            sessionID: "session",
            toolCall: call(
                name: "tasks.create",
                arguments: [
                    "graphID": "graph",
                    "tasks": [["id": "a", "title": "A", "complexity": 8]],
                ]
            )
        )
        let receipt = try #require(try await orchestrator.claimTasks(
            sessionID: "session",
            claims: [TaskClaim(taskID: "a", agentID: "agent-a")]
        ).first)
        _ = try await orchestrator.failAttempt(
            sessionID: "session",
            taskID: "a",
            attemptID: receipt.attemptID,
            error: "Attempt failed."
        )

        let output = try await adapter.execute(
            sessionID: "session",
            toolCall: call(name: "tasks.retry", arguments: ["id": "a"])
        )

        #expect(output.contains("Hint: 1 previous attempt on this task (complexity 8) did not succeed"))
        #expect(output.contains("role-compatible profile and its lowest-capability authorized model binding"))
        #expect(output.contains("profile's highest-capability binding"))
        #expect(output.contains("report the capability gap"))
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
