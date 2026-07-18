import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct SessionTaskOrchestratorTests {
    @Test
    func creationIsAtomicWhenDependencyIsMissing() async throws {
        let orchestrator = SessionTaskOrchestrator()
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await orchestrator.createGraph(
                sessionID: "session", id: "graph", source: .manual, state: .active,
                tasks: [
                    TaskDefinition(id: "a", title: "A"),
                    TaskDefinition(id: "b", title: "B", dependsOn: ["missing"]),
                ]
            )
        }
        #expect(try await orchestrator.graphSnapshot(sessionID: "session") == nil)
    }

    @Test
    func complexityIsClampedOnCreationAndUpdate() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session", id: "graph", source: .manual, state: .active,
            tasks: [
                TaskDefinition(id: "high", title: "High", complexity: 42),
                TaskDefinition(id: "low", title: "Low", complexity: -3),
                TaskDefinition(id: "default", title: "Default"),
            ]
        )
        #expect(try await orchestrator.task(sessionID: "session", taskID: "high").task.complexity == 10)
        #expect(try await orchestrator.task(sessionID: "session", taskID: "low").task.complexity == 1)
        #expect(try await orchestrator.task(sessionID: "session", taskID: "default").task.complexity == 5)

        var update = TaskUpdate()
        update.complexity = 0
        let updated = try await orchestrator.updateTask(
            sessionID: "session", taskID: "high", update: update
        )
        #expect(updated.task.complexity == 1)
    }

    @Test
    func rejectsDuplicateSelfAndCyclicDependencies() async throws {
        let duplicate = SessionTaskOrchestrator()
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await duplicate.createGraph(
                sessionID: "session", id: "duplicate", source: .manual, state: .active,
                tasks: [
                    TaskDefinition(id: "a", title: "A"),
                    TaskDefinition(id: "a", title: "Again"),
                ]
            )
        }

        let selfDependency = SessionTaskOrchestrator()
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await selfDependency.createGraph(
                sessionID: "session", id: "self", source: .manual, state: .active,
                tasks: [TaskDefinition(id: "a", title: "A", dependsOn: ["a"])]
            )
        }

        let cycle = SessionTaskOrchestrator()
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await cycle.createGraph(
                sessionID: "session", id: "cycle", source: .manual, state: .active,
                tasks: [
                    TaskDefinition(id: "a", title: "A", dependsOn: ["b"]),
                    TaskDefinition(id: "b", title: "B", dependsOn: ["a"]),
                ]
            )
        }
    }

    @Test
    func runnableTasksRespectDependenciesAndPriorityOrder() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session", id: "graph", source: .manual, state: .active,
            tasks: [
                TaskDefinition(id: "normal", title: "Normal", order: 1),
                TaskDefinition(id: "high-b", title: "High B", order: 3, priority: .high),
                TaskDefinition(id: "high-a", title: "High A", order: 2, priority: .high),
                TaskDefinition(id: "dependent", title: "Dependent", order: 4, dependsOn: ["normal"]),
            ]
        )

        let runnable = try await orchestrator.listTasks(sessionID: "session", runnableOnly: true)
        #expect(runnable.map(\.task.id) == ["high-a", "high-b", "normal"])
        let dependent = try await orchestrator.task(sessionID: "session", taskID: "dependent")
        #expect(!dependent.isRunnable)
        #expect(dependent.blockedBy == ["normal"])
    }

    @Test
    func completionUnlocksDependentsAndCompletesGraph() async throws {
        let orchestrator = try await makeTwoTaskGraph()
        let first = try #require(try await orchestrator.claimTasks(
            sessionID: "session",
            claims: [TaskClaim(taskID: "a", agentID: "agent-a")]
        ).first)
        #expect(try await orchestrator.completeAttempt(
            sessionID: "session", taskID: "a", attemptID: first.attemptID,
            output: "A done", requiresValidation: false
        ))
        #expect(try await orchestrator.task(sessionID: "session", taskID: "b").isRunnable)

        let second = try #require(try await orchestrator.claimTasks(
            sessionID: "session",
            claims: [TaskClaim(taskID: "b", agentID: "agent-b")]
        ).first)
        #expect(try await orchestrator.completeAttempt(
            sessionID: "session", taskID: "b", attemptID: second.attemptID,
            output: "B done", requiresValidation: false
        ))
        #expect(try await orchestrator.graphSnapshot(sessionID: "session")?.state == .completed)
    }

    @Test
    func failureBlocksDescendantAndRetryPreservesHistory() async throws {
        let orchestrator = try await makeTwoTaskGraph()
        let first = try #require(try await orchestrator.claimTasks(
            sessionID: "session",
            claims: [TaskClaim(taskID: "a", agentID: "agent-a")]
        ).first)
        #expect(try await orchestrator.failAttempt(
            sessionID: "session", taskID: "a", attemptID: first.attemptID,
            error: "boom", output: "partial"
        ))

        let dependent = try await orchestrator.task(sessionID: "session", taskID: "b")
        #expect(dependent.task.status == .pending)
        #expect(!dependent.isRunnable)
        #expect(dependent.blockedReason == "dependency a failed")

        let retried = try await orchestrator.retryTask(sessionID: "session", taskID: "a")
        #expect(retried.task.status == .pending)
        #expect(retried.task.attempts.count == 1)
        #expect(retried.task.attempts[0].status == .failed)
        #expect(retried.task.attempts[0].output == "partial")
        #expect(retried.task.attempts[0].error == "boom")
        let second = try #require(try await orchestrator.claimTasks(
            sessionID: "session",
            claims: [TaskClaim(taskID: "a", agentID: "agent-a-2")]
        ).first)
        #expect(second.ordinal == 2)
    }

    @Test
    func revisionAndAttemptFencingRejectStaleEvents() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session", id: "graph", source: .manual, state: .active,
            tasks: [TaskDefinition(id: "a", title: "A")]
        )
        let original = try await orchestrator.task(sessionID: "session", taskID: "a")
        _ = try await orchestrator.updateTask(
            sessionID: "session", taskID: "a",
            update: TaskUpdate(title: "Updated", expectedRevision: original.task.revision)
        )
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await orchestrator.updateTask(
                sessionID: "session", taskID: "a",
                update: TaskUpdate(title: "Stale", expectedRevision: original.task.revision)
            )
        }

        let first = try #require(try await orchestrator.claimTasks(
            sessionID: "session", claims: [TaskClaim(taskID: "a", agentID: "old")]
        ).first)
        _ = try await orchestrator.failAttempt(
            sessionID: "session", taskID: "a", attemptID: first.attemptID, error: "failed"
        )
        _ = try await orchestrator.retryTask(sessionID: "session", taskID: "a")
        let second = try #require(try await orchestrator.claimTasks(
            sessionID: "session", claims: [TaskClaim(taskID: "a", agentID: "new")]
        ).first)
        #expect(!(try await orchestrator.completeAttempt(
            sessionID: "session", taskID: "a", attemptID: first.attemptID,
            output: "late", requiresValidation: false
        )))
        #expect(try await orchestrator.task(
            sessionID: "session", taskID: "a"
        ).task.activeAttemptID == second.attemptID)
    }

    @Test
    func coordinatorLifecycleCreatesAndCompletesAnAttempt() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "a", title: "A")]
        )

        let started = try await orchestrator.updateTask(
            sessionID: "session",
            taskID: "a",
            update: TaskUpdate(status: .inProgress, output: "started")
        )
        let attemptID = try #require(started.task.activeAttemptID)
        #expect(started.task.activeAttempt?.executor == .coordinator)
        #expect(started.task.activeAttempt?.status == .running)
        #expect(started.task.activeAttempt?.output == "started")

        let completed = try await orchestrator.updateTask(
            sessionID: "session",
            taskID: "a",
            update: TaskUpdate(
                status: .completed,
                output: "done",
                evidence: [TaskEvidence(kind: "test", summary: "focused checks passed")]
            )
        )
        #expect(completed.task.status == .completed)
        #expect(completed.task.activeAttemptID == nil)
        #expect(completed.task.attempts.count == 1)
        #expect(completed.task.attempts[0].id == attemptID)
        #expect(completed.task.attempts[0].status == .completed)
        #expect(completed.task.attempts[0].output == "done")
        #expect(completed.task.result?.output == "done")
        #expect(completed.task.result?.evidence.first?.summary == "focused checks passed")
    }

    @Test
    func implementationCompletionRequiresIndependentValidation() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session", id: "graph", source: .manual, state: .active,
            tasks: [TaskDefinition(id: "a", title: "A")]
        )
        let claim = try #require(try await orchestrator.claimTasks(
            sessionID: "session", claims: [TaskClaim(taskID: "a", agentID: "worker")]
        ).first)
        _ = try await orchestrator.completeAttempt(
            sessionID: "session", taskID: "a", attemptID: claim.attemptID,
            output: "implemented", requiresValidation: true
        )
        #expect(try await orchestrator.task(
            sessionID: "session", taskID: "a"
        ).task.status == .awaitingValidation)

        let validated = try await orchestrator.validateTaskResult(
            sessionID: "session", taskID: "a", succeeded: true,
            evidence: [TaskEvidence(kind: "test", summary: "Focused tests passed")]
        )
        #expect(validated.task.status == .completed)
        #expect(validated.task.result?.validatedAt != nil)
        #expect(validated.task.result?.evidence.count == 1)
    }

    @Test
    func workflowCompletionRequiresValidationAndFailedValidationRequiresRetry() async throws {
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
        #expect(try await orchestrator.completeAttempt(
            sessionID: "workflow-session",
            taskID: "implementation",
            attemptID: first.attemptID,
            output: "implementation complete",
            requiresValidation: false
        ))

        let awaitingValidation = try await orchestrator.task(
            sessionID: "workflow-session",
            taskID: "implementation"
        ).task
        #expect(awaitingValidation.status == .awaitingValidation)
        #expect(awaitingValidation.activeAttemptID == nil)
        #expect(awaitingValidation.attempts.count == 1)
        #expect(awaitingValidation.attempts[0].id == first.attemptID)
        #expect(awaitingValidation.attempts[0].status == .completed)
        #expect(awaitingValidation.attempts[0].output == "implementation complete")

        let failedValidation = try await orchestrator.validateTaskResult(
            sessionID: "workflow-session",
            taskID: "implementation",
            succeeded: false,
            failureReason: "focused validation failed",
            blocked: true
        )
        #expect(failedValidation.task.status == .failed)
        #expect(failedValidation.task.statusReason == "focused validation failed")

        let retried = try await orchestrator.retryTask(
            sessionID: "workflow-session",
            taskID: "implementation"
        )
        #expect(retried.task.status == .pending)
        #expect(retried.task.attempts.count == 1)
        let second = try #require(try await orchestrator.claimTasks(
            sessionID: "workflow-session",
            claims: [TaskClaim(taskID: "implementation", agentID: "worker-2")]
        ).first)
        #expect(second.ordinal == 2)
        #expect(second.attemptID != first.attemptID)
    }

    @Test
    func manualValidationKeepsBlockedOutcomeForBackwardCompatibility() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "manual-session",
            id: "manual",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "implementation", title: "Implement")]
        )
        let attempt = try #require(try await orchestrator.claimTasks(
            sessionID: "manual-session",
            claims: [TaskClaim(taskID: "implementation", agentID: "worker")]
        ).first)
        _ = try await orchestrator.completeAttempt(
            sessionID: "manual-session",
            taskID: "implementation",
            attemptID: attempt.attemptID,
            output: "implementation complete",
            requiresValidation: true
        )

        let blockedValidation = try await orchestrator.validateTaskResult(
            sessionID: "manual-session",
            taskID: "implementation",
            succeeded: false,
            blocked: true
        )
        #expect(blockedValidation.task.status == .blocked)
    }

    @Test
    func restoreInterruptsRunningAttempt() async throws {
        let source = SessionTaskOrchestrator()
        _ = try await source.createGraph(
            sessionID: "session", id: "graph", source: .manual, state: .active,
            tasks: [TaskDefinition(id: "a", title: "A")]
        )
        _ = try await source.claimTasks(
            sessionID: "session", claims: [TaskClaim(taskID: "a", agentID: "worker")]
        )
        let snapshot = try #require(try await source.graphSnapshot(sessionID: "session"))

        let restored = SessionTaskOrchestrator()
        _ = try await restored.restoreTaskGraph(snapshot, sessionID: "session")
        let task = try await restored.task(sessionID: "session", taskID: "a")
        #expect(task.task.status == .blocked)
        #expect(task.task.activeAttemptID == nil)
        #expect(task.task.attempts.last?.status == .interrupted)
        #expect(task.task.statusReason == "execution interrupted during session restore")
    }

    @Test
    func activatingAnotherGraphCannotOrphanAnActiveAttempt() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session",
            id: "active",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "a", title: "A")]
        )
        _ = try await orchestrator.createGraph(
            sessionID: "session",
            id: "draft",
            source: .manual,
            state: .draft,
            tasks: [TaskDefinition(id: "b", title: "B")],
            makeCurrent: false
        )
        _ = try await orchestrator.claimTasks(
            sessionID: "session",
            claims: [TaskClaim(taskID: "a", agentID: "worker")]
        )

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await orchestrator.activateGraph(id: "draft", sessionID: "session")
        }
        #expect(try await orchestrator.graphSnapshot(
            sessionID: "session", graphID: "active"
        )?.state == .active)
        #expect(try await orchestrator.graphSnapshot(
            sessionID: "session", graphID: "draft"
        )?.state == .draft)
        #expect(try await orchestrator.graphSnapshot(sessionID: "session")?.id == "active")
    }

    @Test
    func storeRoundTripAndCorruptionAreExplicit() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTaskOrchestratorTests-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let working = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        let writer = SessionTaskOrchestrator(store: store)
        try await writer.registerSession(id: "session", workingDirectory: working)
        _ = try await writer.createGraph(
            sessionID: "session", id: "graph", source: .manual, state: .active,
            tasks: [TaskDefinition(id: "a", title: "A")]
        )

        let reader = SessionTaskOrchestrator(store: store)
        try await reader.registerSession(id: "session", workingDirectory: working)
        #expect(try await reader.graphSnapshot(sessionID: "session")?.tasks.map(\.id) == ["a"])

        let fileURL = store.checkpointFileURL(
            sessionID: "corrupt-session", workingDirectory: working
        )
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("not a plist".utf8).write(to: fileURL)
        #expect(throws: SessionTaskGraphStoreError.self) {
            _ = try store.load(sessionID: "corrupt-session", workingDirectory: working)
        }
        let siblings = try FileManager.default.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent(), includingPropertiesForKeys: nil
        )
        #expect(siblings.contains { $0.lastPathComponent.contains(".corrupt-") })
    }

    @Test
    func complexityDefaultsToFiveAndClampsToRange() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session", id: "graph", source: .manual, state: .active,
            tasks: [
                TaskDefinition(id: "default", title: "Default complexity"),
                TaskDefinition(id: "low", title: "Clamped low", complexity: -5),
                TaskDefinition(id: "high", title: "Clamped high", complexity: 99),
                TaskDefinition(id: "explicit", title: "Explicit", complexity: 7),
            ]
        )
        let snapshot = try await orchestrator.graphSnapshot(sessionID: "session", graphID: "graph")
        let tasks = snapshot?.tasks ?? []
        #expect(tasks.first { $0.id == "default" }?.complexity == 5)
        #expect(tasks.first { $0.id == "low" }?.complexity == 1)
        #expect(tasks.first { $0.id == "high" }?.complexity == 10)
        #expect(tasks.first { $0.id == "explicit" }?.complexity == 7)
    }

    @Test
    func complexityIsUpdatedViaTaskUpdate() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session", id: "graph", source: .manual, state: .active,
            tasks: [TaskDefinition(id: "a", title: "A")]
        )
        _ = try await orchestrator.updateTask(
            sessionID: "session", taskID: "a", graphID: "graph",
            update: TaskUpdate(complexity: 8)
        )
        let snapshot = try await orchestrator.graphSnapshot(sessionID: "session", graphID: "graph")
        #expect(snapshot?.tasks.first?.complexity == 8)
    }

    @Test
    func taskRecordDecodesWithoutComplexityKeyForBackwardCompat() throws {
        let json = """
        {
            "id": "legacy",
            "title": "Legacy task",
            "details": null,
            "order": 1,
            "status": "pending",
            "priority": "normal",
            "dependsOn": [],
            "execution": {"executor": "coordinator", "toolNames": [], "fileScopes": []},
            "acceptanceCriteria": [],
            "activeAttemptID": null,
            "attempts": [],
            "result": null,
            "statusReason": null,
            "revision": 1,
            "createdAt": 0,
            "updatedAt": 0
        }
        """.data(using: .utf8)!
        let record = try JSONDecoder().decode(TaskRecord.self, from: json)
        #expect(record.complexity == 5)
        #expect(record.id == "legacy")
    }

    @Test
    func removeGraphEliminatesGraphAndAllowsRecreationWithSameID() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session",
            id: "plan-stale",
            source: .plan(planID: "plan-stale"),
            state: .draft,
            tasks: [TaskDefinition(id: "plan-stale-1", title: "Old", order: 1)]
        )
        #expect(try await orchestrator.graphSnapshot(
            sessionID: "session", graphID: "plan-stale"
        ) != nil)

        let removed = try await orchestrator.removeGraph(
            id: "plan-stale",
            sessionID: "session"
        )
        #expect(removed.id == "plan-stale")
        #expect(try await orchestrator.graphSnapshot(
            sessionID: "session", graphID: "plan-stale"
        ) == nil)

        // The same id can now be reused for a fresh graph.
        let recreated = try await orchestrator.createGraph(
            sessionID: "session",
            id: "plan-stale",
            source: .plan(planID: "plan-stale"),
            state: .draft,
            tasks: [
                TaskDefinition(id: "plan-stale-1", title: "New A", order: 1),
                TaskDefinition(id: "plan-stale-2", title: "New B", order: 2),
            ]
        )
        #expect(recreated.tasks.count == 2)
        #expect(recreated.tasks.map(\.title) == ["New A", "New B"])
    }

    @Test
    func removeGraphRejectsGraphWithActiveAttempt() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session",
            id: "graph",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "a", title: "A", order: 1)]
        )
        _ = try await orchestrator.claimTasks(
            sessionID: "session",
            claims: [TaskClaim(taskID: "a", agentID: "worker")]
        )

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await orchestrator.removeGraph(
                id: "graph",
                sessionID: "session"
            )
        }
    }

    @Test
    func workflowGraphsRequireDelegatedTaskAttemptsWithoutChangingManualGraphs() async throws {
        let orchestrator = SessionTaskOrchestrator()

        do {
            _ = try await orchestrator.createGraph(
                sessionID: "workflow-session",
                id: "workflow-invalid",
                source: .workflow,
                state: .active,
                tasks: [TaskDefinition(id: "implementation", title: "Implement")]
            )
            Issue.record("A workflow task without sub-agent execution should be rejected")
        } catch let error as SessionTaskOrchestratorError {
            #expect(error == .taskRequiresSubAgentExecution("implementation"))
        }

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

        do {
            _ = try await orchestrator.updateTask(
                sessionID: "workflow-session",
                taskID: "implementation",
                update: TaskUpdate(status: .inProgress)
            )
            Issue.record("The workflow coordinator must not start a task attempt")
        } catch let error as SessionTaskOrchestratorError {
            #expect(error == .taskRequiresSubAgentExecution("implementation"))
        }

        do {
            _ = try await orchestrator.claimTasks(
                sessionID: "workflow-session",
                claims: [TaskClaim(
                    taskID: "implementation",
                    executor: .coordinator
                )]
            )
            Issue.record("A workflow task must not be claimed by the coordinator")
        } catch let error as SessionTaskOrchestratorError {
            #expect(error == .taskRequiresSubAgentExecution("implementation"))
        }

        let delegatedReceipt = try #require(try await orchestrator.claimTasks(
            sessionID: "workflow-session",
            claims: [TaskClaim(taskID: "implementation", agentID: "worker")]
        ).first)
        #expect(delegatedReceipt.agentID == "worker")
        #expect(try await orchestrator.task(
            sessionID: "workflow-session",
            taskID: "implementation"
        ).task.activeAttempt?.executor == .subAgent)

        let manual = SessionTaskOrchestrator()
        _ = try await manual.createGraph(
            sessionID: "manual-session",
            id: "manual",
            source: .manual,
            state: .active,
            tasks: [TaskDefinition(id: "direct", title: "Direct")]
        )
        let direct = try await manual.updateTask(
            sessionID: "manual-session",
            taskID: "direct",
            update: TaskUpdate(status: .inProgress)
        )
        #expect(direct.task.activeAttempt?.executor == .coordinator)
    }

    @Test
    func activeWorkflowGraphCannotBeReplacedAndItsSourceRoundTrips() async throws {
        let sourceData = try JSONEncoder().encode(TaskGraphSource.workflow)
        #expect(try JSONDecoder().decode(TaskGraphSource.self, from: sourceData) == .workflow)

        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "workflow-session",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: []
        )

        do {
            _ = try await orchestrator.createGraph(
                sessionID: "workflow-session",
                id: "replacement",
                source: .manual,
                state: .active,
                tasks: []
            )
            Issue.record("An active workflow graph must not be replaced")
        } catch let error as SessionTaskOrchestratorError {
            #expect(error == .graphNotMutable("workflow"))
        }
    }

    @Test
    func createGraphCannotDeselectANonTerminalWorkflowWhenArchivingIsDisabled() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "workflow-session",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: []
        )

        do {
            _ = try await orchestrator.createGraph(
                sessionID: "workflow-session",
                id: "replacement",
                source: .manual,
                state: .draft,
                tasks: [],
                archivePreviousCurrent: false
            )
            Issue.record("A non-terminal workflow must remain current even when archiving is disabled")
        } catch let error as SessionTaskOrchestratorError {
            #expect(error == .graphNotMutable("workflow"))
        }
        #expect(try await orchestrator.graphSnapshot(sessionID: "workflow-session")?.id == "workflow")
        #expect(try await orchestrator.graphSnapshot(
            sessionID: "workflow-session",
            graphID: "workflow"
        )?.state == .active)
    }

    @Test
    func activateGraphCannotAbandonOrArchiveANonTerminalWorkflow() async throws {
        for workflowState in [TaskGraphState.draft, .active] {
            let orchestrator = SessionTaskOrchestrator()
            let sessionID = "workflow-\(workflowState.rawValue)"
            _ = try await orchestrator.createGraph(
                sessionID: sessionID,
                id: "workflow",
                source: .workflow,
                state: workflowState,
                tasks: []
            )
            _ = try await orchestrator.createGraph(
                sessionID: sessionID,
                id: "other",
                source: .manual,
                state: .draft,
                tasks: [],
                makeCurrent: false
            )

            do {
                _ = try await orchestrator.activateGraph(id: "other", sessionID: sessionID)
                Issue.record("A non-terminal workflow must not be implicitly deselected")
            } catch let error as SessionTaskOrchestratorError {
                #expect(error == .graphNotMutable("workflow"))
            }
            #expect(try await orchestrator.graphSnapshot(sessionID: sessionID)?.id == "workflow")
            #expect(try await orchestrator.graphSnapshot(
                sessionID: sessionID,
                graphID: "workflow"
            )?.state == workflowState)
            #expect(try await orchestrator.graphSnapshot(
                sessionID: sessionID,
                graphID: "other"
            )?.state == .draft)
        }

        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "non-current-workflow",
            id: "current",
            source: .manual,
            state: .active,
            tasks: []
        )
        _ = try await orchestrator.createGraph(
            sessionID: "non-current-workflow",
            id: "workflow",
            source: .workflow,
            state: .active,
            tasks: [],
            makeCurrent: false
        )
        _ = try await orchestrator.createGraph(
            sessionID: "non-current-workflow",
            id: "replacement",
            source: .manual,
            state: .draft,
            tasks: [],
            makeCurrent: false
        )

        do {
            _ = try await orchestrator.activateGraph(
                id: "replacement",
                sessionID: "non-current-workflow"
            )
            Issue.record("An active workflow must not be implicitly archived when it is not current")
        } catch let error as SessionTaskOrchestratorError {
            #expect(error == .graphNotMutable("workflow"))
        }
        #expect(try await orchestrator.graphSnapshot(
            sessionID: "non-current-workflow",
            graphID: "workflow"
        )?.state == .active)
    }

    @Test
    func workflowRestoreAcceptsFailedValidationAfterACompletedAttempt() async throws {
        let source = SessionTaskOrchestrator()
        _ = try await source.createGraph(
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
        let receipt = try #require(try await source.claimTasks(
            sessionID: "workflow-session",
            claims: [TaskClaim(taskID: "implementation", agentID: "worker")]
        ).first)
        #expect(try await source.completeAttempt(
            sessionID: "workflow-session",
            taskID: "implementation",
            attemptID: receipt.attemptID,
            output: "implemented",
            requiresValidation: true
        ))
        let failed = try await source.validateTaskResult(
            sessionID: "workflow-session",
            taskID: "implementation",
            succeeded: false,
            failureReason: "validation failed"
        )
        #expect(failed.task.status == .failed)
        #expect(failed.task.activeAttemptID == nil)
        #expect(failed.task.attempts.last?.status == .completed)

        let snapshot = try #require(try await source.graphSnapshot(sessionID: "workflow-session"))
        let restored = SessionTaskOrchestrator()
        _ = try await restored.restoreTaskGraph(snapshot, sessionID: "workflow-session")
        let restoredTask = try await restored.task(
            sessionID: "workflow-session",
            taskID: "implementation"
        )
        #expect(restoredTask.task.status == .failed)
        #expect(restoredTask.task.attempts.last?.status == .completed)
    }

    @Test
    func workflowRestoreRejectsIncoherentAttemptLifecyclesWhileManualSnapshotsRemainCompatible() async throws {
        let queuedAttempt = workflowAttempt(id: "queued", status: .queued)
        let failedAttempt = workflowAttempt(id: "failed", status: .failed)

        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await SessionTaskOrchestrator().restoreTaskGraph(
                workflowSnapshot(taskStatus: .inProgress, attempts: [queuedAttempt]),
                sessionID: "missing-active-attempt"
            )
        }
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await SessionTaskOrchestrator().restoreTaskGraph(
                workflowSnapshot(
                    taskStatus: .completed,
                    activeAttemptID: queuedAttempt.id,
                    attempts: [queuedAttempt]
                ),
                sessionID: "completed-active-attempt"
            )
        }
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await SessionTaskOrchestrator().restoreTaskGraph(
                workflowSnapshot(taskStatus: .failed, attempts: [queuedAttempt]),
                sessionID: "orphaned-active-attempt"
            )
        }
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await SessionTaskOrchestrator().restoreTaskGraph(
                workflowSnapshot(taskStatus: .awaitingValidation, attempts: [failedAttempt]),
                sessionID: "awaiting-without-completion"
            )
        }
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await SessionTaskOrchestrator().restoreTaskGraph(
                workflowSnapshot(taskStatus: .completed, attempts: [failedAttempt]),
                sessionID: "completed-without-completion"
            )
        }

        let manualSnapshot = TaskGraphSnapshot(
            id: "manual",
            source: .manual,
            state: .active,
            tasks: [
                TaskRecord(
                    id: "legacy",
                    title: "Legacy in-progress task",
                    order: 1,
                    status: .inProgress
                )
            ]
        )
        let manual = SessionTaskOrchestrator()
        _ = try await manual.restoreTaskGraph(
            manualSnapshot,
            sessionID: "manual-session",
            interruptActiveAttempts: false
        )
        #expect(try await manual.task(
            sessionID: "manual-session",
            taskID: "legacy"
        ).task.status == .inProgress)
    }

    @Test
    func workflowRestoreRejectsCompletedGraphsUntilEveryTaskIsCompleted() async throws {
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await SessionTaskOrchestrator().restoreTaskGraph(
                workflowSnapshot(taskStatus: .pending, graphState: .completed),
                sessionID: "incomplete-workflow"
            )
        }

        let completedAttempt = workflowAttempt(status: .completed)
        let completedWorkflow = workflowSnapshot(
            taskStatus: .completed,
            graphState: .completed,
            attempts: [completedAttempt]
        )
        let restored = SessionTaskOrchestrator()
        _ = try await restored.restoreTaskGraph(
            completedWorkflow,
            sessionID: "completed-workflow"
        )
        #expect(try await restored.graphSnapshot(
            sessionID: "completed-workflow"
        )?.state == .completed)
    }

    private func workflowSnapshot(
        taskStatus: TaskStatus,
        graphState: TaskGraphState = .active,
        activeAttemptID: String? = nil,
        attempts: [TaskAttempt] = []
    ) -> TaskGraphSnapshot {
        let now = Date(timeIntervalSince1970: 1)
        return TaskGraphSnapshot(
            id: "workflow",
            source: .workflow,
            state: graphState,
            tasks: [
                TaskRecord(
                    id: "task",
                    title: "Task",
                    order: 1,
                    status: taskStatus,
                    execution: TaskExecutionSpec(executor: .subAgent),
                    activeAttemptID: activeAttemptID,
                    attempts: attempts,
                    createdAt: now,
                    updatedAt: now
                )
            ],
            createdAt: now,
            updatedAt: now
        )
    }

    private func workflowAttempt(
        id: String = "attempt",
        status: TaskAttemptStatus
    ) -> TaskAttempt {
        let now = Date(timeIntervalSince1970: 1)
        return TaskAttempt(
            id: id,
            ordinal: 1,
            agentID: "worker",
            executor: .subAgent,
            status: status,
            startedAt: now,
            finishedAt: status.isActive ? nil : now
        )
    }

    private func makeTwoTaskGraph() async throws -> SessionTaskOrchestrator {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session", id: "graph", source: .manual, state: .active,
            tasks: [
                TaskDefinition(id: "a", title: "A", order: 1),
                TaskDefinition(id: "b", title: "B", order: 2, dependsOn: ["a"]),
            ]
        )
        return orchestrator
    }
}
