import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct WorkflowCompletionTests {
    private func updateCall(_ graph: TaskGraphSnapshot, state: String, message: String? = nil) throws -> DirectAgentToolCall {
        var workflow = ["state": state]
        workflow["message"] = message
        let arguments: [String: Any] = [
            "graphID": graph.id, "expectedRevision": graph.revision, "workflow": workflow,
        ]
        return DirectAgentToolCall(
            id: UUID().uuidString, name: "tasks.update", argumentsObject: arguments,
            argumentsJSON: String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        )
    }

    private func complete(_ taskID: String, owner: SessionTaskOrchestrator) async throws {
        for status in [TaskStatus.inProgress, .completed] {
            _ = try await owner.updateTask(sessionID: "root", taskID: taskID, update: TaskUpdate(status: status))
        }
    }

    @Test(arguments: [false, true], [TaskGraphWorkflowState.running, .awaitingUser, .blocked])
    func completedAnalysisCanPersistPauseResumeAndExtendBeforeExplicitCompletion(
        legacy: Bool, state: TaskGraphWorkflowState
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = SessionTaskGraphStore(supportDirectoryURL: root.appendingPathComponent("support"))
        let writer = SessionTaskOrchestrator(store: store)
        try await writer.registerSession(id: "root", workingDirectory: workspace)
        _ = try await writer.createGraph(
            sessionID: "root", id: "goal", source: .workflow, state: .active,
            tasks: [TaskDefinition(id: "analysis", title: "Analyze scope")],
            originalGoal: legacy ? nil : "Implement and validate the complete objective"
        )
        try await complete("analysis", owner: writer)
        let analyzed = try #require(try await writer.graphSnapshot(sessionID: "root"))
        #expect(analyzed.state == .active)
        #expect(analyzed.tasks.allSatisfy { $0.status == .completed })
        #expect(PlanningCommandKernel.workflowTurnDisposition(
            graph: analyzed, expectedGraphID: analyzed.id, coordinatorMessage: "Analysis complete"
        ) == .continueAutomatically)

        if state != .running {
            _ = try await DirectTaskToolAdapter(orchestrator: writer).execute(
                sessionID: "root", toolCall: updateCall(analyzed, state: state.rawValue, message: "Choose the scope")
            )
        }
        let saved = try #require(try await writer.graphSnapshot(sessionID: "root"))
        let reader = SessionTaskOrchestrator(store: store)
        let candidates = await reader.resumableTaskGraphCheckpoints(workingDirectory: workspace)
        #expect(candidates.map(\.graphID) == [saved.id])
        try await reader.registerSession(id: "root", workingDirectory: workspace)
        let restored = try #require(try await reader.graphSnapshot(sessionID: "root"))
        #expect(restored.state == .active)
        #expect(restored.tasks == saved.tasks)
        #expect(restored.workflow == saved.workflow)
        let resumed = try await reader.resumeWorkflow(sessionID: "root", expectedGraph: restored)
        #expect(resumed.id == analyzed.id)
        #expect(resumed.workflow?.state == .running)
        #expect(resumed.workflow?.originalGoal == analyzed.workflow?.originalGoal)
        _ = try await reader.createTasks(sessionID: "root", tasks: [
            TaskDefinition(id: "implementation", title: "Implement and validate", dependsOn: ["analysis"]),
        ])
        try await complete("implementation", owner: reader)
        let ready = try #require(try await reader.graphSnapshot(sessionID: "root"))
        #expect(ready.id == analyzed.id)
        #expect(ready.state == .active)
        #expect(ready.tasks.count == 2)
        let adapter = DirectTaskToolAdapter(orchestrator: reader)
        let output = try await adapter.execute(sessionID: "root", toolCall: updateCall(ready, state: "completed"))
        let finished = try #require(try await reader.graphSnapshot(sessionID: "root"))
        #expect(output.contains("Workflow state=completed"))
        #expect(finished.state == .completed)
        #expect(finished.workflow?.state.rawValue == "completed")
        #expect(finished.workflow?.originalGoal == ready.workflow?.originalGoal)
        #expect(finished.revision == ready.revision + 1)
        #expect(finished.workflow?.revision == (ready.workflow?.revision ?? 0) + 1)
        #expect(finished.tasks == ready.tasks)
        #expect(PlanningCommandKernel.workflowTurnDisposition(
            graph: finished, expectedGraphID: finished.id, coordinatorMessage: "Done"
        ) == .completed)
        let encoded = try JSONEncoder().encode(finished)
        #expect(try JSONDecoder().decode(TaskGraphSnapshot.self, from: encoded) == finished)
        #expect(finished.schemaVersion == 1)
        #expect(await reader.resumableTaskGraphCheckpoints(workingDirectory: workspace).isEmpty)
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await reader.resumeWorkflow(sessionID: "root", expectedGraph: finished)
        }
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await reader.createTasks(sessionID: "root", graphID: finished.id, tasks: [TaskDefinition(id: "extra", title: "Extra")])
        }
    }

    @Test(arguments: [TaskStatus.pending, .inProgress, .awaitingValidation, .failed, .blocked, .cancelled])
    func cannotFinalizeWithUnfinishedTasks(status: TaskStatus) async throws {
        let owner = SessionTaskOrchestrator()
        _ = try await owner.createGraph(
            sessionID: "root", id: "goal", source: .workflow, state: .active,
            tasks: [TaskDefinition(id: "work", title: "Work")], originalGoal: "Goal"
        )
        if status != .pending {
            _ = try await owner.updateTask(sessionID: "root", taskID: "work", update: TaskUpdate(status: .inProgress))
            if status == .cancelled {
                _ = try await owner.cancelTask(sessionID: "root", taskID: "work")
            } else if status != .inProgress {
                _ = try await owner.updateTask(sessionID: "root", taskID: "work", update: TaskUpdate(status: status))
            }
        }
        let before = try #require(try await owner.graphSnapshot(sessionID: "root"))
        let adapter = DirectTaskToolAdapter(orchestrator: owner)
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await adapter.execute(sessionID: "root", toolCall: updateCall(before, state: "completed"))
        }
        #expect(try await owner.graphSnapshot(sessionID: "root") == before)
    }

    @Test
    func completionRequiresTasksRootAccessAndFreshRevision() async throws {
        let owner = SessionTaskOrchestrator()
        let empty = try await owner.createGraph(
            sessionID: "root", id: "goal", source: .workflow, state: .active, tasks: [], originalGoal: "Goal"
        )
        let adapter = DirectTaskToolAdapter(orchestrator: owner)
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await adapter.execute(sessionID: "root", toolCall: updateCall(empty, state: "completed"))
        }
        _ = try await owner.createTasks(sessionID: "root", tasks: [
            TaskDefinition(id: "work", title: "Work", execution: TaskExecutionSpec(executor: .subAgent)),
        ])
        let claim = try #require(try await owner.claimTasks(
            sessionID: "root", claims: [TaskClaim(taskID: "work", agentID: "worker")]
        ).first)
        try await owner.registerExecutionScope(
            executionSessionID: "child",
            scope: TaskExecutionScope(rootSessionID: "root", graphID: empty.id, taskID: "work", attemptID: claim.attemptID)
        )
        _ = try await owner.completeAttempt(
            sessionID: "root", taskID: "work", attemptID: claim.attemptID, output: "Result", requiresValidation: false
        )
        let awaiting = try #require(try await owner.graphSnapshot(sessionID: "root"))
        #expect(awaiting.tasks.first?.status == .awaitingValidation)
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await adapter.execute(sessionID: "root", toolCall: updateCall(awaiting, state: "completed"))
        }
        _ = try await owner.validateTaskResult(sessionID: "root", taskID: "work", succeeded: true)
        let ready = try #require(try await owner.graphSnapshot(sessionID: "root"))
        #expect(ready.state == .active)
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await adapter.execute(sessionID: "child", toolCall: updateCall(ready, state: "completed"))
        }
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await adapter.execute(sessionID: "root", toolCall: updateCall(awaiting, state: "completed"))
        }
        #expect(try await owner.graphSnapshot(sessionID: "root") == ready)
        _ = try await adapter.execute(sessionID: "root", toolCall: updateCall(ready, state: "completed", message: "Validated"))
        let finished = try #require(try await owner.graphSnapshot(sessionID: "root"))
        #expect(finished.state == .completed)
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await adapter.execute(sessionID: "root", toolCall: updateCall(finished, state: "running"))
        }
    }

    @Test
    func descriptorExposesExplicitCompletion() throws {
        let descriptor = try #require(DirectTodoRuntime.toolDescriptors.first { $0.name == "tasks.update" })
        let schema = try #require(try JSONSerialization.jsonObject(with: Data(descriptor.inputSchema.utf8)) as? [String: Any])
        let properties = try #require(schema["properties"] as? [String: Any])
        let workflow = try #require(properties["workflow"] as? [String: Any])
        let workflowProperties = try #require(workflow["properties"] as? [String: Any])
        let state = try #require(workflowProperties["state"] as? [String: Any])
        #expect(state["enum"] as? [String] == ["running", "awaiting_user", "blocked", "completed"])
        #expect(descriptor.description.contains("Completing tasks does not close /goal"))
    }

    @Test
    func finalizationRemainsAtomicIfCheckpointWriteFails() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        let support = root.appendingPathComponent("support")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let owner = SessionTaskOrchestrator(store: SessionTaskGraphStore(supportDirectoryURL: support))
        try await owner.registerSession(id: "root", workingDirectory: workspace)
        _ = try await owner.createGraph(
            sessionID: "root", id: "goal", source: .workflow, state: .active,
            tasks: [TaskDefinition(id: "work", title: "Work")], originalGoal: "Goal"
        )
        try await complete("work", owner: owner)
        let before = try #require(try await owner.graphSnapshot(sessionID: "root"))
        try FileManager.default.removeItem(at: support)
        try Data("not a directory".utf8).write(to: support)
        await #expect(throws: (any Error).self) {
            try await owner.updateWorkflow(
                sessionID: "root", graphID: before.id, state: .completed,
                message: nil, expectedRevision: before.revision
            )
        }
        #expect(try await owner.graphSnapshot(sessionID: "root") == before)
    }

    @Test
    func restoreValidatesExplicitCompletionAndKeepsLegacyTerminalGraphsClosed() async throws {
        let owner = SessionTaskOrchestrator()
        _ = try await owner.createGraph(
            sessionID: "root", id: "goal", source: .workflow, state: .active,
            tasks: [TaskDefinition(id: "work", title: "Work")], originalGoal: "Goal"
        )
        try await complete("work", owner: owner)
        let ready = try #require(try await owner.graphSnapshot(sessionID: "root"))
        var inconsistent = ready
        inconsistent.workflow?.state = .completed
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await SessionTaskOrchestrator().restoreTaskGraph(inconsistent, sessionID: "invalid")
        }
        for metadata in [ready.workflow, nil] {
            var legacy = ready
            legacy.state = .completed
            legacy.workflow = metadata
            let restoredOwner = SessionTaskOrchestrator()
            _ = try await restoredOwner.restoreTaskGraph(legacy, sessionID: "restored")
            #expect(try await restoredOwner.graphSnapshot(sessionID: "restored")?.state == .completed)
            await #expect(throws: SessionTaskOrchestratorError.self) {
                try await restoredOwner.resumeWorkflow(sessionID: "restored", expectedGraph: legacy)
            }
        }
    }

    @Test(arguments: [TaskGraphSource.manual, .plan(planID: "plan")])
    func nonWorkflowGraphsStillCompleteAutomatically(source: TaskGraphSource) async throws {
        let owner = SessionTaskOrchestrator()
        _ = try await owner.createGraph(
            sessionID: "root", id: "graph", source: source, state: .active,
            tasks: [TaskDefinition(id: "work", title: "Work")]
        )
        try await complete("work", owner: owner)
        #expect(try await owner.graphSnapshot(sessionID: "root")?.state == .completed)
    }
}
