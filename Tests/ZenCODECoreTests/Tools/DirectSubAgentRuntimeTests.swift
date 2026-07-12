//
//  DirectSubAgentRuntimeTests.swift
//  ZenCODE
//
//  Created by ZenCODE on 02/07/26.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct DirectSubAgentRuntimeTests {
    @Test
    func createAgentsUsesMatchedProfileModelFromRole() async throws {
        let planner = AgentProfile(
            id: "planner-profile",
            name: "Planner",
            tools: [],
            modelID: "planner-model",
            thinkingSelection: .high
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let recorder = SubAgentFactoryRecorder()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { context in
                recorder.append(context)
                return backend
            },
            profileResolver: { payload in
                DirectSubAgentRuntime.agentProfile(
                    matching: payload,
                    in: [planner]
                )
            }
        )

        let output = try await runtime.createAgents(
            arguments: [
                "name": .string("planning-pass"),
                "role": .string("Planner"),
                "isolationMode": .string("report")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        let context = try #require(recorder.contexts.first)
        #expect(context.profile == planner)
        #expect(context.modelID == "planner-model")
        #expect(context.thinkingSelection == .high)
        #expect(await backend.createdThinkingSelection() == .high)

        let snapshot = try #require(await runtime.snapshots().first)
        #expect(snapshot.profileID == planner.id)
        #expect(snapshot.profileName == planner.name)
        #expect(snapshot.modelID == "planner-model")
        #expect(output.contains("model=planner-model"))
    }

    @Test
    func createAgentsUseUniqueEphemeralSessionsWithoutCacheKeys() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in backend }
        )

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object([
                        "name": .string("planner-one"),
                        "prompt": .string("Plan one")
                    ]),
                    .object([
                        "name": .string("planner-two"),
                        "prompt": .string("Plan two")
                    ])
                ])
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests", isDirectory: true),
            parentAllowedToolNames: nil
        )

        let createdSessions = await backend.createdSessions()
        let sessionIDs = createdSessions.map(\.id)

        #expect(createdSessions.count == 2)
        #expect(Set(sessionIDs).count == 2)
        #expect(sessionIDs.allSatisfy { $0.hasPrefix("agent_") && $0.hasSuffix("_session") })
        #expect(createdSessions.allSatisfy { $0.cacheKey == nil })
        #expect(createdSessions.allSatisfy { $0.historyCount == 0 })
    }

    @Test
    func overviewSnapshotsShowOnlyMostRecentCreateBatchWithoutPruningRegistry() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory: { _ in backend }
        )
        let runtime = await executor.subAgentRuntime
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests",
            isDirectory: true
        )

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first-a")]),
                    .object(["name": .string("first-b")])
                ])
            ],
            workingDirectory: workingDirectory,
            parentAllowedToolNames: nil
        )

        let firstOverview = await executor.subAgentSnapshots()
        #expect(Set(firstOverview.map(\.name)) == ["first-a", "first-b"])

        _ = try await runtime.createAgents(
            arguments: ["name": .string("second")],
            workingDirectory: workingDirectory,
            parentAllowedToolNames: nil
        )

        let currentOverview = await executor.subAgentSnapshots()
        let allSnapshots = await runtime.snapshots()
        let listedAgents = await runtime.listAgents(arguments: [:])

        #expect(currentOverview.map(\.name) == ["second"])
        #expect(Set(allSnapshots.map(\.name)) == ["first-a", "first-b", "second"])
        #expect(listedAgents.contains("first-a"))
        #expect(listedAgents.contains("first-b"))
        #expect(listedAgents.contains("second"))
    }
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
        let runtime = DirectSubAgentRuntime(contextualBackendFactory: { _ in backend })
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("reporter"),
                "taskID": .string("task-a"),
                "isolationMode": .string("report"),
                "prompt": .string("Do the report"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])

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

    @Test
    func singleTasklessDelegationRemainsAllowedOutsideAWorkflow() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("focused-lookup")],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        #expect(await runtime.snapshots().map(\.name) == ["focused-lookup"])
    }

    @Test
    func tasklessSubAgentPromptReceivesWorkflowPolicyWhenItCanCoordinate() {
        let taskTools: Set<String> = [
            "task.create",
            "task.list",
            "task.update",
            "agent.create",
        ]
        let tasklessPrompt = DirectSubAgentRuntime.systemPrompt(
            name: "coordinator",
            role: "Coordinator",
            isolationMode: .report,
            allowedToolNames: taskTools
        )
        let taskBoundPrompt = DirectSubAgentRuntime.systemPrompt(
            name: "worker",
            role: "Worker",
            isolationMode: .report,
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("focused-lookup")],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        do {
            _ = try await runtime.createAgents(
                arguments: ["name": .string("second-lookup")],
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("lookup"),
                "prompt": .string("Inspect the current concern")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first")]),
                    .object(["name": .string("second")]),
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object(["name": .string("first")]),
                        .object(["name": .string("second")]),
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object(["name": .string("tracked"), "taskID": .string("tracked")]),
                        .object(["name": .string("untracked")]),
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("plan-author")],
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
            }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("first"),
                "prompt": .string("Investigate the first concern")
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )

        do {
            _ = try await runtime.createAgents(
                arguments: ["name": .string("second")],
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first"), "taskID": .string("first")]),
                    .object(["name": .string("second"), "task_id": .string("second")]),
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first")]),
                    .object(["name": .string("second")]),
                ])
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: ["agent.create"],
            rootSessionID: "root"
        )

        #expect(await runtime.snapshots().count == 2)
    }

    @Test
    func taskNamespacePrefixEnforcesTheCoordinatedDelegationGuard() async throws {
        let orchestrator = SessionTaskOrchestrator()
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        do {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object(["name": .string("first")]),
                        .object(["name": .string("second")]),
                    ])
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: ["agent.", "task."],
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
    func implementationCompletionAwaitsValidation() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "task-a", title: "Implement")]
        )
        let backend = CapturingSubAgentRuntimeBackend(responseText: "implementation complete")
        let runtime = DirectSubAgentRuntime(contextualBackendFactory: { _ in backend })
        await runtime.installTaskOrchestrator(orchestrator)

        _ = try await runtime.createAgents(
            arguments: [
                "taskID": .string("task-a"),
                "isolationMode": .string("implementation"),
                "prompt": .string("Implement"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        _ = await runtime.waitForAgents(arguments: ["timeoutSeconds": .number(5)])

        let task = try await orchestrator.task(sessionID: "root", taskID: "task-a")
        #expect(task.task.status == .awaitingValidation)
        #expect(task.task.result?.output == "implementation complete")
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object(["name": .string("a"), "taskID": .string("task-a")]),
                        .object(["name": .string("b"), "taskID": .string("task-b")]),
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)
        let arguments: [String: JSONValue] = ["taskID": .string("task-a")]
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

    @Test
    func closeCancelsTaskAndShutdownInterruptsTask() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [
                TaskDefinition(id: "close-task", title: "Close"),
                TaskDefinition(id: "shutdown-task", title: "Shutdown"),
            ]
        )
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        await runtime.installTaskOrchestrator(orchestrator)
        _ = try await runtime.createAgents(
            arguments: ["name": .string("closer"), "taskID": .string("close-task")],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        let closeAgent = try #require(await runtime.snapshots().first)
        _ = try await runtime.closeAgent(arguments: ["id": .string(closeAgent.id)])
        #expect(try await orchestrator.task(
            sessionID: "root", taskID: "close-task"
        ).task.status == .cancelled)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("shutdown"), "taskID": .string("shutdown-task")],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        await runtime.shutdown()
        let interrupted = try await orchestrator.task(
            sessionID: "root", taskID: "shutdown-task"
        ).task
        #expect(interrupted.status == .blocked)
        #expect(interrupted.attempts.last?.status == .interrupted)
    }

    @Test
    func createRejectsOversizedBatchesAndParallelImplementationWork() async throws {
        let runtime = DirectSubAgentRuntime(
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() }
        )
        let oversized = (0...DirectSubAgentRuntime.maximumAgentsPerCreate).map { index in
            JSONValue.object(["name": .string("report-\(index)")])
        }

        await #expect(throws: DirectSubAgentRuntimeError.self) {
            _ = try await runtime.createAgents(
                arguments: ["agents": .array(oversized)],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil
            )
        }
        await #expect(throws: DirectSubAgentRuntimeError.self) {
            _ = try await runtime.createAgents(
                arguments: [
                    "agents": .array([
                        .object([
                            "name": .string("writer-a"),
                            "isolationMode": .string("implementation"),
                            "prompt": .string("Implement A"),
                        ]),
                        .object([
                            "name": .string("writer-b"),
                            "isolationMode": .string("implementation"),
                            "prompt": .string("Implement B"),
                        ]),
                    ])
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil
            )
        }
        #expect(await runtime.snapshots().isEmpty)
    }

    @Test
    func taskCancellationClosesOnlyTheAssignedAgentInTheSameRootSession() async throws {
        let orchestrator = SessionTaskOrchestrator()
        for sessionID in ["root-a", "root-b"] {
            _ = try await orchestrator.createGraph(
                sessionID: sessionID,
                id: "graph",
                source: .manual,
                state: .active,
                tasks: [TaskDefinition(id: "shared-task", title: sessionID)]
            )
        }
        let backend = CapturingSubAgentRuntimeBackend(blocksPrompts: true)
        let runtime = DirectSubAgentRuntime(contextualBackendFactory: { _ in backend })
        await runtime.installTaskOrchestrator(orchestrator)
        for sessionID in ["root-a", "root-b"] {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string(sessionID),
                    "taskID": .string("shared-task"),
                    "isolationMode": .string("report"),
                    "prompt": .string("Wait"),
                ],
                workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
                parentAllowedToolNames: nil,
                rootSessionID: sessionID
            )
        }

        #expect(await runtime.closeAgentAssigned(
            to: "shared-task",
            rootSessionID: "root-b"
        ))
        let snapshots = await runtime.snapshots()
        #expect(snapshots.first(where: { $0.rootSessionID == "root-b" })?.status == .closed)
        #expect(snapshots.first(where: { $0.rootSessionID == "root-a" })?.status != .closed)
        #expect(try await orchestrator.task(
            sessionID: "root-b", taskID: "shared-task"
        ).task.status == .cancelled)
        #expect(try await orchestrator.task(
            sessionID: "root-a", taskID: "shared-task"
        ).task.status == .inProgress)

        #expect(await runtime.interruptAgents(rootSessionID: "root-a") == 1)
        let interrupted = try await orchestrator.task(
            sessionID: "root-a", taskID: "shared-task"
        ).task
        #expect(interrupted.status == .blocked)
        #expect(interrupted.attempts.last?.status == .interrupted)
        await runtime.shutdown()
    }
}

private final class SubAgentFactoryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedContexts: [DirectSubAgentRuntime.BackendContext] = []

    var contexts: [DirectSubAgentRuntime.BackendContext] {
        lock.lock()
        defer { lock.unlock() }
        return recordedContexts
    }

    func append(_ context: DirectSubAgentRuntime.BackendContext) {
        lock.lock()
        recordedContexts.append(context)
        lock.unlock()
    }
}

private actor CapturingSubAgentRuntimeBackend: AgentRuntimeBackend {
    struct CreatedSession: Sendable {
        let id: String
        let cacheKey: String?
        let historyCount: Int
    }

    private var thinkingSelection: AgentThinkingSelection?
    private var sessions: [CreatedSession] = []
    private let responseText: String
    private let blocksPrompts: Bool
    private var installedTaskOrchestrator = false

    init(responseText: String = "done", blocksPrompts: Bool = false) {
        self.responseText = responseText
        self.blocksPrompts = blocksPrompts
    }

    func installTaskOrchestrator(
        _ orchestrator: SessionTaskOrchestrator
    ) async {
        installedTaskOrchestrator = true
    }

    func createSession(
        id: String,
        cwd _: String,
        systemPrompt _: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {
        sessions.append(
            CreatedSession(
                id: id,
                cacheKey: cacheKey,
                historyCount: history.count
            )
        )
        self.thinkingSelection = thinkingSelection
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id _: String) {}

    func shutdown() {}

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID _: String,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        if blocksPrompts {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        return DirectAgentResponse(
            text: responseText,
            stopReason: "stop",
            modelID: "test-model"
        )
    }

    func snapshotSession(id _: String) -> AgentRuntimeSessionSnapshot? {
        nil
    }

    func didInstallTaskOrchestrator() -> Bool {
        installedTaskOrchestrator
    }

    func createdThinkingSelection() -> AgentThinkingSelection? {
        thinkingSelection
    }

    func createdSessions() -> [CreatedSession] {
        sessions
    }
}
