//
//  SessionTaskOrchestratorTests+Workflow.swift
//  ZenCODE
//
//  Tests for graph removal, direct and delegated attempts, workflow
//  validation and the restore rules for workflow graphs in
//  SessionTaskOrchestrator.
//

import Foundation
import Testing
@testable import ZenCODECore

extension SessionTaskOrchestratorTests {
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

    @Test(arguments: [TaskGraphSource.workflow, .manual])
    func graphSupportsDirectAndDelegatedAttempts(source: TaskGraphSource) async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session", id: "graph", source: source, state: .active,
            tasks: [
                TaskDefinition(id: "direct", title: "Direct"),
                TaskDefinition(
                    id: "delegated", title: "Delegated", dependsOn: ["direct"],
                    execution: TaskExecutionSpec(executor: .subAgent)
                )
            ]
        )
        await #expect(throws: SessionTaskOrchestratorError.self) {
            _ = try await orchestrator.claimTasks(
                sessionID: "session", claims: [TaskClaim(taskID: "delegated", agentID: "worker")]
            )
        }
        let started = try await orchestrator.updateTask(
            sessionID: "session", taskID: "direct", update: TaskUpdate(status: .inProgress)
        )
        #expect(started.task.activeAttempt?.executor == .coordinator)
        let completed = try await orchestrator.updateTask(
            sessionID: "session", taskID: "direct",
            update: TaskUpdate(status: .completed, output: "Direct work validated")
        )
        #expect(completed.task.status == .completed)
        #expect(completed.task.attempts.last?.status == .completed)
        #expect(completed.task.activeAttemptID == nil)
        #expect(try await orchestrator.graphSnapshot(sessionID: "session")?.state == .active)

        let receipt = try #require(try await orchestrator.claimTasks(
            sessionID: "session", claims: [TaskClaim(taskID: "delegated", agentID: "worker")]
        ).first)
        _ = try await orchestrator.completeAttempt(
            sessionID: "session", taskID: "delegated", attemptID: receipt.attemptID,
            output: "Delegated result", requiresValidation: false
        )
        let delegated = try await orchestrator.task(sessionID: "session", taskID: "delegated")
        #expect(delegated.task.status == (source.isWorkflow ? .awaitingValidation : .completed))
        if source.isWorkflow {
            #expect(try await orchestrator.graphSnapshot(sessionID: "session")?.state == .active)
            _ = try await orchestrator.validateTaskResult(
                sessionID: "session", taskID: "delegated", succeeded: true
            )
            let ready = try #require(try await orchestrator.graphSnapshot(sessionID: "session"))
            #expect(ready.state == .active)
            _ = try await orchestrator.updateWorkflow(
                sessionID: "session", graphID: ready.id, state: .completed,
                message: nil, expectedRevision: ready.revision
            )
        }
        #expect(try await orchestrator.graphSnapshot(sessionID: "session")?.state == .completed)
    }

    @Test(arguments: [false, true])
    func workflowValidationUsesActualAttemptExecutor(requiresValidation: Bool) async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "session", id: "workflow", source: .workflow, state: .active,
            tasks: [TaskDefinition(
                id: "work", title: "Work", execution: TaskExecutionSpec(executor: .subAgent)
            )]
        )
        let claim = try #require(try await orchestrator.claimTasks(
            sessionID: "session", claims: [TaskClaim(taskID: "work", executor: .coordinator)]
        ).first)
        _ = try await orchestrator.completeAttempt(
            sessionID: "session", taskID: "work", attemptID: claim.attemptID,
            output: "Direct result", requiresValidation: requiresValidation
        )
        let direct = try await orchestrator.task(sessionID: "session", taskID: "work")
        #expect(direct.task.status == (requiresValidation ? .awaitingValidation : .completed))
        if requiresValidation {
            let rejected = try await orchestrator.validateTaskResult(
                sessionID: "session", taskID: "work", succeeded: false,
                failureReason: "Access needed", blocked: true
            )
            #expect(rejected.task.status == .blocked)
            _ = try await orchestrator.retryTask(sessionID: "session", taskID: "work")
            let retried = try await orchestrator.updateTask(
                sessionID: "session", taskID: "work", update: TaskUpdate(status: .inProgress)
            )
            #expect(retried.task.attempts.count == 2)
            #expect(retried.task.activeAttemptID != claim.attemptID)
        }
    }

    @Test
    func activeWorkflowGraphCannotBeReplacedAndItsSourceRoundTrips() async throws {
        #expect(TaskGraphSource.workflow.isWorkflow)
        #expect(!TaskGraphSource.manual.isWorkflow)
        #expect(!TaskGraphSource.workflow.requiresSubAgentExecution)
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

    @Test
    func delegatedScopeHasSymmetricReadOnlySnapshotAndCheckpointBoundary() async throws {
        let orchestrator = SessionTaskOrchestrator()
        _ = try await orchestrator.createGraph(
            sessionID: "root", id: "graph", source: .manual, state: .active,
            tasks: [TaskDefinition(id: "task", title: "Task")]
        )
        let attempt = try #require(try await orchestrator.claimTasks(
            sessionID: "root",
            claims: [TaskClaim(taskID: "task", agentID: "worker")]
        ).first)
        try await orchestrator.registerExecutionScope(
            executionSessionID: "delegated",
            scope: TaskExecutionScope(
                rootSessionID: "root",
                graphID: "graph",
                taskID: "task",
                attemptID: attempt.attemptID
            )
        )

        #expect(try await orchestrator.graphSnapshot(sessionID: "delegated")?.id == "graph")
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await orchestrator.clearTaskGraphs(sessionID: "delegated")
        }
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
}
