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
