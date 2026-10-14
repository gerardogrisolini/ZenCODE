import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    @Test
    func taskClaimAndReportCompletionUpdateTaskAutomatically() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task-a", title: "Report")]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "report complete")
        let runtime = makeDirectSubAgentRuntime(backend: backend)
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("reporter"),
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Do the report"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()

        let task = try await orchestrator.task(sessionID: "root", taskID: "task-a")
        let agent = try #require(await runtime.snapshots().first)
        #expect(task.task.status == .completed)
        #expect(task.task.attempts.count == 1)
        #expect(task.task.attempts[0].agentID == agent.id)
        #expect(task.task.attempts[0].output == "report complete")
        #expect(agent.rootSessionID == "root")
        #expect(agent.taskID == "task-a")
        #expect(agent.taskAttemptID == task.task.attempts[0].id)
        #expect(agent.taskAttemptOrdinal == 1)
        #expect(await backend.didInstallTaskOrchestrator())
    }

    @Test(arguments: [TaskExecutorKind.subAgent, .coordinator])
    func workflowAttemptIsFencedAfterValidationFailureUntilRetryCreatesANewAgent(declaredExecutor: TaskExecutorKind) async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: [
                TaskDefinition(
                    id: "implementation",
                    title: "Implement",
                    execution: TaskExecutionSpec(executor: declaredExecutor)
                )
            ]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "implementation complete")
        let runtime = makeDirectSubAgentRuntime(backend: backend)
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker-1"),
                "profile": .string("Developer"),
                "taskID": .string("implementation"),
                "prompt": .string("Implement the change"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()

        let firstAgent = try #require(await runtime.snapshots().first)
        let completed = try await orchestrator.task(
            sessionID: "root",
            taskID: "implementation"
        ).task
        let firstAttemptID = try #require(completed.attempts.first?.id)
        #expect(completed.status == .awaitingValidation)
        #expect(completed.activeAttemptID == nil)
        #expect(await backend.sentPromptCount() == 1)

        let failedValidation = try await orchestrator.validateTaskResult(
            sessionID: "root",
            taskID: "implementation",
            succeeded: false,
            failureReason: "focused validation failed",
            blocked: true
        )
        #expect(failedValidation.task.status == .failed)

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await runtime.messageAgents(
                arguments: [
                    "id": .string(firstAgent.id),
                    "message": .string("Try a correction"),
                ]
            )
        }

        try await runtime.queuePrompt("stale correction", for: firstAgent.id)
        await runtime.waitForDirectSubAgentTestWorkLoops(agentID: firstAgent.id)
        #expect(await backend.sentPromptCount() == 1)
        #expect(await runtime.snapshots().first?.pending == false)

        _ = try await orchestrator.retryTask(sessionID: "root", taskID: "implementation")
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("worker-2"),
                "profile": .string("Developer"),
                "taskID": .string("implementation"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        let agentsAfterRetry = await runtime.snapshots()
        let secondAgent = try #require(agentsAfterRetry.first { $0.id != firstAgent.id })
        let retried = try await orchestrator.task(
            sessionID: "root",
            taskID: "implementation"
        ).task
        #expect(retried.status == .inProgress)
        #expect(retried.attempts.count == 2)
        #expect(retried.activeAttemptID == secondAgent.taskAttemptID)
        #expect(secondAgent.taskAttemptID != firstAttemptID)

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await runtime.messageAgents(
                arguments: [
                    "id": .string(firstAgent.id),
                    "message": .string("Reuse the old attempt"),
                ]
            )
        }

        #expect(await runtime.closeAgent(id: firstAgent.id))
        let afterClosingOldAgent = try await orchestrator.task(
            sessionID: "root",
            taskID: "implementation"
        ).task
        #expect(afterClosingOldAgent.status == .inProgress)
        #expect(afterClosingOldAgent.activeAttemptID == secondAgent.taskAttemptID)
        await runtime.shutdown()
    }

    @Test
    func singleTasklessDelegationRemainsAllowedOutsideAWorkflow() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("focused-lookup"), "profile": .string("Developer")],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        #expect(await runtime.snapshots().map(\.name) == ["focused-lookup"])
    }

    @Test
    func tasklessSubAgentPromptReceivesWorkflowPolicyWhenItCanCoordinate() {
        let taskTools: Set<String> = [
            "tasks.create",
            "tasks.list",
            "tasks.update",
            "agent.create",
        ]
        let tasklessPrompt = DirectSubAgentRuntime.systemPrompt(
            name: "coordinator",
            role: "Coordinator",
            allowedToolNames: taskTools
        )
        let taskBoundPrompt = DirectSubAgentRuntime.systemPrompt(
            name: "worker",
            role: "Worker",
            taskID: "task-1",
            allowedToolNames: taskTools
        )

        #expect(tasklessPrompt.contains("Task workflow policy:"))
        #expect(taskBoundPrompt.contains("must not change dependencies"))
        #expect(!taskBoundPrompt.contains("Task workflow policy:"))
    }

    @Test
    func idleTasklessDelegationBlocksAnotherWorkflowAndGraphActivationUntilClosed() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("focused-lookup"), "profile": .string("Developer")],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        do {
            _ = try await runtime.createAgents(
                arguments: ["name": .string("second-lookup"), "profile": .string("Developer")],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
            Issue.record("A second idle taskless delegation should require a task graph")
        } catch let error as DirectSubAgentRuntimeError {
            guard case .taskGraphRequiredForCoordinatedDelegation = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        }

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await orchestrator.createGraph(
                sessionID: "root",
                id: "graph",
                source: .manual,
                state: .active,
                tasks: [TaskDefinition(id: "tracked", title: "Tracked")]
            )
        }

        let agentID = try #require(await runtime.snapshots().first?.id)
        _ = try await runtime.closeAgent(arguments: ["id": .string(agentID)])
        let graph = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "tracked", title: "Tracked")]
        )
        #expect(graph.state == .active)
    }

    @Test
    func tasklessAgentCannotBeResumedAfterAGraphBecomesActive() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("lookup"),
                "profile": .string("Developer"),
                "prompt": .string("Inspect the current concern")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()
        let agentID = try #require(await runtime.snapshots().first?.id)

        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "tracked", title: "Tracked")]
        )

        do {
            _ = try await runtime.messageAgents(
                arguments: [
                    "id": .string(agentID),
                    "message": .string("Continue the lookup")
                ],
                parentAllowedToolNames: nil
            )
            Issue.record("An active graph should reject resuming a taskless agent")
        } catch let error as DirectSubAgentRuntimeError {
            guard case let .taskIDRequiredForActiveTaskGraph(graphID) = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
            #expect(graphID == "graph")
        }
    }

    @Test
    func tasklessIdleAgentsCannotBeStartedTogetherThroughAgentMessage() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first"), "profile": .string("Developer")]),
                    .object(["name": .string("second"), "profile": .string("Developer")]),
                ])
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: ["agent.create"],
            rootSessionID: "root"
        )
        let agentIDs = await runtime.snapshots().map(\.id)

        do {
            _ = try await runtime.messageAgents(
                arguments: [
                    "ids": .array(agentIDs.map { .string($0) }),
                    "message": .string("Start the lookup")
                ],
                parentAllowedToolNames: nil
            )
            Issue.record("Starting multiple taskless idle agents should require a task graph")
        } catch let error as DirectSubAgentRuntimeError {
            guard case .taskGraphRequiredForCoordinatedDelegation = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        }
    }

    @Test
    func parallelTasklessDelegationRequiresTaskGraphBeforeCreatingAgents() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object(["name": .string("first"), "profile": .string("Developer")]),
                        .object(["name": .string("second"), "profile": .string("Developer")]),
                    ])
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
            Issue.record("Parallel taskless delegation should require a task graph")
        } catch let error as DirectSubAgentRuntimeError {
            guard case .taskGraphRequiredForCoordinatedDelegation = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        }

        #expect(await runtime.snapshots().isEmpty)
        #expect(try await orchestrator.graphSnapshot(sessionID: "root") == nil)
    }

    @Test
    func activeTaskGraphRequiresTaskIDBeforeAnyClaimIsCreated() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(id: "tracked", title: "Tracked work"),
                TaskDefinition(id: "other", title: "Other work"),
            ]
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object([
                            "name": .string("tracked"),
                            "profile": .string("Developer"),
                            "taskID": .string("tracked"),
                        ]),
                        .object(["name": .string("untracked"), "profile": .string("Developer")]),
                    ])
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
            Issue.record("An active graph should require taskID for every delegated agent")
        } catch let error as DirectSubAgentRuntimeError {
            guard case let .taskIDRequiredForActiveTaskGraph(graphID) = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
            #expect(graphID == "graph")
        }

        #expect(await runtime.snapshots().isEmpty)
        #expect(try await orchestrator.task(
            sessionID: "root", taskID: "tracked"
        ).task.attempts.isEmpty)
        #expect(try await orchestrator.task(
            sessionID: "root", taskID: "other"
        ).task.attempts.isEmpty)
    }

    @Test
    func draftTaskGraphDoesNotRequireTaskIDForAStandalonePlannerDelegation() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "plan-draft",
            source: .plan(planID: "plan-draft"),
            state: .draft,
            tasks: [TaskDefinition(id: "plan-draft-1", title: "Draft task")]
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("plan-author"), "profile": .string("Planner")],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        #expect(await runtime.snapshots().map(\.name) == ["plan-author"])
    }

    @Test
    func secondConcurrentTasklessDelegationRequiresTaskGraph() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in
                CapturingSubAgentRuntimeBackend(blocksPrompts: true)
            },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("first"),
                "profile": .string("Developer"),
                "prompt": .string("Investigate the first concern")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        do {
            _ = try await runtime.createAgents(
                arguments: ["name": .string("second"), "profile": .string("Developer")],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
            Issue.record("A concurrent taskless delegation should require a task graph")
        } catch let error as DirectSubAgentRuntimeError {
            guard case .taskGraphRequiredForCoordinatedDelegation = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        }

        #expect(await runtime.snapshots().map(\.name) == ["first"])
        await runtime.shutdown()
    }

    @Test
    func taskBoundParallelDelegationClaimsIndependentTasks() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(id: "first", title: "First"),
                TaskDefinition(id: "second", title: "Second"),
            ]
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object([
                        "name": .string("first"),
                        "profile": .string("Developer"),
                        "taskID": .string("first"),
                    ]),
                    .object([
                        "name": .string("second"),
                        "profile": .string("Developer"),
                        "task_id": .string("second"),
                    ]),
                ])
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        #expect(await runtime.snapshots().count == 2)
        #expect(try await orchestrator.task(
            sessionID: "root", taskID: "first"
        ).task.status == .inProgress)
        #expect(try await orchestrator.task(
            sessionID: "root", taskID: "second"
        ).task.status == .inProgress)
    }

    @Test
    func parallelDelegationRemainsAvailableWhenTaskWorkflowToolsAreUnavailable() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first"), "profile": .string("Developer")]),
                    .object(["name": .string("second"), "profile": .string("Developer")]),
                ])
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: ["agent.create"],
            rootSessionID: "root"
        )

        #expect(await runtime.snapshots().count == 2)
    }

    @Test
    func tasksNamespacePrefixEnforcesTheCoordinatedDelegationGuard() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object(["name": .string("first"), "profile": .string("Developer")]),
                        .object(["name": .string("second"), "profile": .string("Developer")]),
                    ])
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: ["agent.", "tasks."],
                rootSessionID: "root"
            )
            Issue.record("The task namespace prefix should require a task graph")
        } catch let error as DirectSubAgentRuntimeError {
            guard case .taskGraphRequiredForCoordinatedDelegation = error else {
                Issue.record("Unexpected error: \(error.localizedDescription)")
                return
            }
        }
    }

    @Test
    func delegatedTaskCompletionCompletesTask() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task-a", title: "Implement")]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "implementation complete")
        let runtime = makeDirectSubAgentRuntime(backend: backend)
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "profile": .string("Developer"),
                "taskID": .string("task-a"),
                "prompt": .string("Implement"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()

        let task = try await orchestrator.task(sessionID: "root", taskID: "task-a")
        #expect(task.task.status == .completed)
        #expect(task.task.result?.output == "implementation complete")
        await runtime.shutdown()
    }

    @Test
    func taskClaimBatchIsAtomicWhenOneTaskIsNotRunnable() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(id: "task-a", title: "A"),
                TaskDefinition(id: "task-b", title: "B", dependsOn: ["task-a"]),
            ]
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object([
                            "name": .string("a"),
                            "profile": .string("Developer"),
                            "taskID": .string("task-a"),
                        ]),
                        .object([
                            "name": .string("b"),
                            "profile": .string("Developer"),
                            "taskID": .string("task-b"),
                        ]),
                    ])
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
        }

        #expect(await runtime.snapshots().isEmpty)
        #expect(try await orchestrator.task(
            sessionID: "root", taskID: "task-a"
        ).task.attempts.isEmpty)
    }

    @Test
    func duplicateTaskClaimIsRejected() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task-a", title: "A")]
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)
        let arguments: [String: JSONValue] = [
            "profile": .string("Developer"),
            "taskID": .string("task-a"),
        ]
        _ = try await runtime.createAgents(
            arguments: arguments,
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await runtime.createAgents(
                arguments: arguments,
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: "root"
            )
        }
        #expect(await runtime.snapshots().count == 1)
    }
}
