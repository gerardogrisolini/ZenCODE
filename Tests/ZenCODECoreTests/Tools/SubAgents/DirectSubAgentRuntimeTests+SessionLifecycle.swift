import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DirectSubAgentRuntimeTests {
    @Test
    func getAndWaitReturnCompleteLongOutputToTheModel() async throws {
        let endMarker = "PLANNER_OUTPUT_END"
        let plannerOutput = String(
            repeating: "p",
            count: DirectToolExecutor.defaultModelOutputLimit + 500
        ) + endMarker
        let backend = CapturingSubAgentRuntimeBackend(responseText: plannerOutput)
        let executor = DirectToolExecutor(
            swiftFeatureRuntime: SwiftFeatureRuntime(features: []),
            subAgentContextualBackendFactory: { _ in backend },
            subAgentProfileResolver: builtInDirectSubAgentProfileResolver
        )
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-sub-agent-output-tests",
            isDirectory: true
        )

        let createResult = await executor.execute(
            sessionID: "root",
            toolCall: presentedToolCall(
                id: "create-planner",
                name: "agent.create",
                argumentsObject: [
                    "name": "plan-author",
                    "profile": "Developer",
                    "prompt": "Write the complete plan"
                ],
                argumentsJSON: #"{"name":"plan-author","profile":"Developer","prompt":"Write the complete plan"}"#
            ),
            workingDirectory: workingDirectory
        )
        #expect(createResult.status == DirectAgentToolResult.Status.completed)

        let waitResult = await executor.execute(
            sessionID: "root",
            toolCall: presentedToolCall(
                id: "wait-planner",
                name: "agent.wait",
                argumentsObject: ["name": "plan-author"],
                argumentsJSON: #"{"name":"plan-author"}"#
            ),
            workingDirectory: workingDirectory
        )
        let getResult = await executor.execute(
            sessionID: "root",
            toolCall: presentedToolCall(
                id: "get-planner",
                name: "agent.get",
                argumentsObject: ["name": "plan-author"],
                argumentsJSON: #"{"name":"plan-author"}"#
            ),
            workingDirectory: workingDirectory
        )

        #expect(waitResult.modelOutput.contains(endMarker))
        #expect(getResult.modelOutput.contains(endMarker))
        #expect(!waitResult.modelOutput.contains("... truncated ..."))
        #expect(!waitResult.modelOutput.contains("truncated for model context"))
        #expect(!getResult.modelOutput.contains("... truncated ..."))
        #expect(!getResult.modelOutput.contains("truncated for model context"))

        await executor.subAgentRuntime.shutdown()
    }

    @Test
    func terminalAgentOutputRetentionKeepsOnlyABoundedFinalTail() throws {
        let endMarker = "TERMINAL_AGENT_OUTPUT_END"
        let output = String(
            repeating: "x",
            count: DirectSubAgentRuntime.maximumRetainedTerminalOutputBytes + 10_000
        ) + endMarker

        let retained = try #require(DirectSubAgentRuntime.boundedTerminalOutput(output))

        #expect(
            retained.utf8.count
                == DirectSubAgentRuntime.maximumRetainedTerminalOutputBytes
        )
        #expect(retained.hasPrefix("[Earlier delegated output discarded to bound memory.]"))
        #expect(retained.hasSuffix(endMarker))

        let unicodeOutput = String(
            repeating: "🙂",
            count: DirectSubAgentRuntime.maximumRetainedTerminalOutputBytes
        ) + endMarker
        let unicodeTail = try #require(
            DirectSubAgentRuntime.boundedTerminalOutput(unicodeOutput)
        )
        #expect(
            unicodeTail.utf8.count
                <= DirectSubAgentRuntime.maximumRetainedTerminalOutputBytes
        )
        #expect(unicodeTail.hasSuffix(endMarker))
    }

    @Test
    func tasklessFailedAgentRemainsRetryable() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = makeDirectSubAgentRuntime(backend: backend)
        let rootSessionID = "failed-agent-cleanup"
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("failure-fixture"),
                "profile": .string("Developer"),
                "prompt": .string("initial"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: rootSessionID
        )
        await runtime.waitForDirectSubAgentTestWorkLoops()
        let agentID = try #require(await runtime.snapshots().first?.id)

        await runtime.recordFailure(
            DirectSubAgentRuntimeError.agentNotFound("intentional failure"),
            agentID: agentID
        )

        #expect(await runtime.snapshots().first { $0.id == agentID }?.status == .failed)
        #expect(await backend.shutdownCount() == 0)
        #expect(
            (await runtime.sharedChat.participants(
                roomID: rootSessionID,
                includingInactive: true
            )).contains { $0.id == agentID }
        )

        try await runtime.queuePrompt("retry", for: agentID)
        await runtime.waitForDirectSubAgentTestWorkLoops(agentID: agentID)
        #expect(await runtime.snapshots().first { $0.id == agentID }?.status == .idle)
        #expect(await backend.sentPromptCount() == 2)
        await runtime.shutdown()
    }

    @Test
    func terminalTaskBoundFailureReleasesItsBackendAndSharedChatSlot() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "task-failure-cleanup",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "work", title: "Fail intentionally")]
        )
        let backend = CapturingSubAgentRuntimeBackend(failsPrompts: true)
        let runtime = makeDirectSubAgentRuntime(backend: backend)
        await runtime.installTaskOrchestrator(orchestrator)
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("failure-fixture"),
                "profile": .string("Developer"),
                "prompt": .string("fail"),
                "taskID": .string("work"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "task-failure-cleanup"
        )
        let agentID = try #require(await runtime.snapshots().first?.id)

        await backend.waitUntilShutdownCount(1)

        #expect(await runtime.snapshots().first { $0.id == agentID }?.status == .failed)
        #expect(await backend.shutdownCount() == 1)
        #expect(
            !((await runtime.sharedChat.participants(
                roomID: "task-failure-cleanup",
                includingInactive: true
            )).contains { $0.id == agentID })
        )
        #expect(
            try await orchestrator.task(
                sessionID: "task-failure-cleanup",
                taskID: "work"
            ).task.status == .failed
        )
        await runtime.shutdown()
    }

    @Test
    func createAgentsUseUniqueEphemeralSessionsWithoutCacheKeys() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = makeDirectSubAgentRuntime(backend: backend)

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object([
                        "name": .string("planner-one"),
                        "profile": .string("Developer"),
                        "prompt": .string("Plan one")
                    ]),
                    .object([
                        "name": .string("planner-two"),
                        "profile": .string("Developer"),
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
    func overviewKeepsSequentiallyCreatedSubAgentsWhileEarlierOnesStillWork() async throws {
        let backend = CapturingSubAgentRuntimeBackend(blocksPrompts: true)
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory: { _ in backend },
            subAgentProfileResolver: builtInDirectSubAgentProfileResolver
        )
        let runtime = await executor.subAgentRuntime
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests",
            isDirectory: true
        )

        for name in ["first", "second", "third"] {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string(name),
                    "profile": .string("Developer"),
                    "prompt": .string("Work on \(name)")
                ],
                workingDirectory: workingDirectory,
                parentAllowedToolNames: nil
            )
        }

        // One `agent.create` per call must be presented exactly like a single
        // parallel batch: every sub-agent that is still working stays visible.
        let overview = await executor.subAgentSnapshots()
        #expect(Set(overview.map(\.name)) == ["first", "second", "third"])
        #expect(Set(overview.filter(\.pending).map(\.name)) == ["first", "second", "third"])

        await runtime.shutdown()
    }

    @Test
    func overviewShowsMessagedSubAgentThatResumesWorkAfterALaterBatch() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory: { _ in backend },
            subAgentProfileResolver: builtInDirectSubAgentProfileResolver
        )
        let runtime = await executor.subAgentRuntime
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests",
            isDirectory: true
        )

        for name in ["first", "second"] {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string(name),
                    "profile": .string("Developer"),
                    "prompt": .string("Work on \(name)")
                ],
                workingDirectory: workingDirectory,
                parentAllowedToolNames: nil
            )
            await runtime.waitForDirectSubAgentTestWorkLoops()
        }

        #expect(await executor.subAgentSnapshots().map(\.name) == ["second"])

        let firstID = try #require(
            await runtime.snapshots().first { $0.name == "first" }?.id
        )
        _ = try await runtime.messageAgents(
            arguments: [
                "id": .string(firstID),
                "message": .string("Follow up on the earlier finding")
            ]
        )

        // A follow-up message restarts that sub-agent, so the overview has to
        // present it instead of the finished agents of the previous batch.
        #expect(await executor.subAgentSnapshots().map(\.name) == ["first"])

        await runtime.shutdown()
    }

    @Test
    func overviewSnapshotsStartAFreshBatchWhenNoSubAgentIsWorking() async throws {
        let backend = CapturingSubAgentRuntimeBackend()
        let executor = DirectToolExecutor(
            subAgentContextualBackendFactory: { _ in backend },
            subAgentProfileResolver: builtInDirectSubAgentProfileResolver
        )
        let runtime = await executor.subAgentRuntime
        let workingDirectory = URL(
            fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests",
            isDirectory: true
        )

        _ = try await runtime.createAgents(
            arguments: [
                "agents": .array([
                    .object(["name": .string("first-a"), "profile": .string("Developer")]),
                    .object(["name": .string("first-b"), "profile": .string("Developer")])
                ])
            ],
            workingDirectory: workingDirectory,
            parentAllowedToolNames: nil
        )

        let firstOverview = await executor.subAgentSnapshots()
        let firstOverviewIsCurrentWave = !firstOverview.contains {
            !$0.isInCurrentOverviewWave
        }
        #expect(Set(firstOverview.map(\.name)) == ["first-a", "first-b"])
        #expect(firstOverviewIsCurrentWave)
        #expect(Set(firstOverview.compactMap(\.overviewBatchID)).count == 1)

        _ = try await runtime.createAgents(
            arguments: ["name": .string("second"), "profile": .string("Developer")],
            workingDirectory: workingDirectory,
            parentAllowedToolNames: nil
        )

        let currentOverview = await executor.subAgentSnapshots()
        let allSnapshots = await runtime.snapshots()
        let listedAgents = await runtime.listAgents(arguments: [:])
        let currentOverviewIsCurrentWave = !currentOverview.contains {
            !$0.isInCurrentOverviewWave
        }
        let previousSnapshotsAreNotCurrentWave = !allSnapshots
            .filter { $0.name != "second" }
            .contains { $0.isInCurrentOverviewWave }

        #expect(currentOverview.map(\.name) == ["second"])
        #expect(currentOverviewIsCurrentWave)
        #expect(currentOverview.first?.overviewBatchID != nil)
        #expect(previousSnapshotsAreNotCurrentWave)
        #expect(Set(allSnapshots.map(\.name)) == ["first-a", "first-b", "second"])
        #expect(listedAgents.contains("first-a"))
        #expect(listedAgents.contains("first-b"))
        #expect(listedAgents.contains("second"))
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
            contextualBackendFactory: { _ in CapturingSubAgentRuntimeBackend() },
            profileResolver: builtInDirectSubAgentProfileResolver
        )
        await runtime.installTaskOrchestrator(orchestrator)
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("closer"),
                "profile": .string("Developer"),
                "taskID": .string("close-task"),
            ],
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
            arguments: [
                "name": .string("shutdown"),
                "profile": .string("Developer"),
                "taskID": .string("shutdown-task"),
            ],
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
    func closeCleansUpWhenTaskAttemptCancellationThrows() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root",
            id: "root-graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "close-task", title: "Close")]
        )
        let backend = CapturingSubAgentRuntimeBackend()
        let runtime = makeDirectSubAgentRuntime(backend: backend)
        await runtime.installTaskOrchestrator(orchestrator)
        _ = try await runtime.createAgents(
            arguments: [
                "name": .string("closer"),
                "profile": .string("Developer"),
                "taskID": .string("close-task"),
            ],
            workingDirectory: URL(fileURLWithPath: "/tmp/ZenCODE-sub-agent-tests"),
            parentAllowedToolNames: nil,
            rootSessionID: "root"
        )
        let agent = try #require(await runtime.snapshots().first)
        let agentSessionID = "\(agent.id)_session"

        // Redirect the root execution session to an incompatible task graph.
        // This makes close's cancelAttempt throw taskNotFound while leaving the
        // child scope in place, so the remainder of the close cleanup is observable.
        _ = try await orchestrator.createGraph(
            sessionID: "parent",
            id: "parent-graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "parent-task", title: "Parent")]
        )
        let parentReceipt = try #require(try await orchestrator.claimTasks(
            sessionID: "parent",
            claims: [TaskClaim(taskID: "parent-task", agentID: "parent-agent")]
        ).first)
        try await orchestrator.registerExecutionScope(
            executionSessionID: "root",
            scope: TaskExecutionScope(
                rootSessionID: "parent",
                graphID: parentReceipt.graphID,
                taskID: parentReceipt.taskID,
                attemptID: parentReceipt.attemptID
            )
        )

        do {
            _ = try await runtime.closeAgent(arguments: ["id": .string(agent.id)])
            Issue.record("Closing must propagate a task-attempt cancellation failure.")
        } catch let error as SessionTaskOrchestratorError {
            #expect(error == .taskNotFound("close-task"))
        }

        let closedAgent = try #require(await runtime.snapshots().first)
        #expect(closedAgent.status == .closed)
        #expect(closedAgent.pending == false)
        #expect(closedAgent.latestError?.contains("unable to cancel task attempt") == true)
        #expect(await orchestrator.executionScope(for: agentSessionID) == nil)

        let participants = await runtime.sharedChat.participants(
            roomID: "root",
            includingInactive: true
        )
        #expect(participants.first(where: { $0.name == "closer" }) == nil)
        #expect(await backend.shutdownCount() == 1)
        await #expect(throws: DirectSubAgentBackendFactoryError.self) {
            _ = try await backend.executeBorrowedSubAgentTool(
                AgentBorrowedToolCall(
                    id: "after-close",
                    name: "agent.list",
                    argumentsJSON: "{}"
                )
            )
        }

        // This scope exists only to force the cancellation error above. Removing
        // it lets the original task state be checked from its root session.
        await orchestrator.unregisterExecutionScope(executionSessionID: "root")
        let unmodifiedTask = try await orchestrator.task(
            sessionID: "root",
            taskID: "close-task"
        ).task
        #expect(unmodifiedTask.status == .inProgress)
        #expect(unmodifiedTask.activeAttemptID == agent.taskAttemptID)
        await runtime.shutdown()
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
        let runtime = makeDirectSubAgentRuntime(backend: backend)
        await runtime.installTaskOrchestrator(orchestrator)
        for sessionID in ["root-a", "root-b"] {
            _ = try await runtime.createAgents(
                arguments: [
                    "name": .string(sessionID),
                    "profile": .string("Developer"),
                    "taskID": .string("shared-task"),
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
