import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct WorkflowControlTests {
    private func create(_ owner: SessionTaskOrchestrator, tasks: Bool = false) async throws -> TaskGraphSnapshot {
        try await owner.createGraph(
            sessionID: "root", id: "workflow", source: .workflow, state: .active,
            tasks: tasks ? [TaskDefinition(id: "work", title: "Work", execution: TaskExecutionSpec(executor: .subAgent))] : [],
            originalGoal: "Preserve the complete original objective"
        )
    }

    private func call(_ arguments: [String: Any]) throws -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: UUID().uuidString, name: "tasks.update", argumentsObject: arguments,
            argumentsJSON: String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        )
    }

    @Test
    func structuredStatesOverrideEveryHeadingAndProse() async throws {
        let owner = SessionTaskOrchestrator()
        var graph = try await create(owner)
        let question = "Quale database devo usare?"
        #expect(PlanningCommandKernel.workflowTurnDisposition(
            graph: graph, expectedGraphID: graph.id, coordinatorMessage: "Workflow question\nWhich database?"
        ) == .continueAutomatically)
        graph = try await owner.updateWorkflow(
            sessionID: "root", graphID: graph.id, state: .awaitingUser,
            message: question, expectedRevision: graph.revision
        )
        #expect(PlanningCommandKernel.workflowTurnDisposition(
            graph: graph, expectedGraphID: graph.id, coordinatorMessage: question
        ) == .awaitingClarification)
        var projection = WorkflowCommandRuntimeState(goal: graph.workflow?.originalGoal ?? "", graphID: graph.id)
        let didProjectQuestion = projection.recordCoordinatorOutput("A summary after tools", graph: graph)
        #expect(didProjectQuestion)
        #expect(projection.pendingCoordinatorMessage == question)
        graph = try await owner.updateWorkflow(
            sessionID: "root", graphID: graph.id, state: .blocked,
            message: "Credentials are unavailable; supply access before continuing.", expectedRevision: graph.revision
        )
        for prose in ["Done", "Workflow question\nAnything else?", "Retry automatically", ""] {
            #expect(PlanningCommandKernel.workflowTurnDisposition(
                graph: graph, expectedGraphID: graph.id, coordinatorMessage: prose
            ) == .blocked)
        }
        let didProjectBlock = projection.recordCoordinatorOutput(nil, graph: graph)
        #expect(didProjectBlock)
        let didRecordReply = projection.recordReply("Access is now available")
        #expect(didRecordReply)
        graph = try await owner.resumeWorkflow(sessionID: "root", expectedGraph: graph)
        #expect(graph.workflow?.state == .running)
        #expect(graph.workflow?.message == nil)
        #expect(graph.workflow?.originalGoal == "Preserve the complete original objective")
        #expect(PlanningCommandKernel.workflowTurnDisposition(
            graph: graph, expectedGraphID: graph.id, coordinatorMessage: "Workflow question"
        ) == .continueAutomatically)
    }

    @Test
    func workflowToolRequiresRootCurrentActiveWorkflowAndGraphRevision() async throws {
        let owner = SessionTaskOrchestrator()
        var graph = try await create(owner, tasks: true)
        let receipt = try #require(try await owner.claimTasks(
            sessionID: "root", claims: [TaskClaim(taskID: "work", agentID: "worker")]
        ).first)
        try await owner.registerExecutionScope(
            executionSessionID: "child",
            scope: TaskExecutionScope(rootSessionID: "root", graphID: graph.id, taskID: "work", attemptID: receipt.attemptID)
        )
        graph = try #require(try await owner.graphSnapshot(sessionID: "root"))
        let adapter = DirectTaskToolAdapter(orchestrator: owner)
        let request = try call([
            "graphID": graph.id, "expectedRevision": graph.revision,
            "workflow": ["state": "blocked", "message": "External access missing"]
        ])
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await adapter.execute(sessionID: "child", toolCall: request)
        }
        await #expect(throws: DirectTodoTaskRuntimeError.self) {
            try await adapter.execute(sessionID: nil, toolCall: request)
        }
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await adapter.execute(sessionID: "another-root", toolCall: request)
        }
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await owner.updateWorkflow(sessionID: "root", graphID: "wrong", state: .blocked, message: "Blocked", expectedRevision: graph.revision)
        }
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await owner.updateWorkflow(sessionID: "root", graphID: graph.id, state: .blocked, message: "Blocked", expectedRevision: graph.revision - 1)
        }
        let output = try await adapter.execute(sessionID: "root", toolCall: request)
        #expect(output.contains("Workflow state=blocked"))
        #expect(output.contains("Preserve the complete original objective"))
        let paused = try #require(try await owner.graphSnapshot(sessionID: "root"))
        #expect(paused.tasks == graph.tasks)

        let manual = try await owner.createGraph(sessionID: "manual-root", id: "manual", source: .manual, state: .active, tasks: [])
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await owner.updateWorkflow(sessionID: "manual-root", graphID: manual.id, state: .blocked, message: "Blocked", expectedRevision: manual.revision)
        }
        let inactive = try await owner.createGraph(sessionID: "root", id: "not-current", source: .workflow, state: .active, tasks: [], makeCurrent: false)
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await owner.updateWorkflow(sessionID: "root", graphID: inactive.id, state: .blocked, message: "Blocked", expectedRevision: inactive.revision)
        }
        let closed = try await owner.createGraph(sessionID: "closed-root", id: "closed", source: .workflow, state: .archived, tasks: [], originalGoal: "Closed")
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await owner.updateWorkflow(sessionID: "closed-root", graphID: closed.id, state: .blocked, message: "Blocked", expectedRevision: closed.revision)
        }
    }

    @Test
    func workflowToolRejectsMixedPayloadsAndObjectiveMutationWithoutChangingGraph() async throws {
        let owner = SessionTaskOrchestrator()
        let graph = try await create(owner)
        let adapter = DirectTaskToolAdapter(orchestrator: owner)
        let valid: [String: Any] = [
            "graphID": graph.id, "expectedRevision": graph.revision,
            "workflow": ["state": "awaiting_user", "message": "Which behavior?"]
        ]
        for field in ["id", "taskID", "status", "output", "title", "dependsOn", "originalGoal"] {
            var mixed = valid
            mixed[field] = "must not be accepted"
            let request = try call(mixed)
            await #expect(throws: DirectTodoTaskRuntimeError.self) {
                try await adapter.execute(sessionID: "root", toolCall: request)
            }
        }
        for workflow in [
            ["state": "blocked"],
            ["state": "awaiting_user", "message": "   "],
            ["state": "unknown", "message": "Invalid state"],
            ["state": "blocked", "message": "Blocked", "originalGoal": "Replacement objective"],
        ] {
            var invalid = valid
            invalid["workflow"] = workflow
            let request = try call(invalid)
            await #expect(throws: (any Error).self) {
                try await adapter.execute(sessionID: "root", toolCall: request)
            }
        }
        #expect(try await owner.graphSnapshot(sessionID: "root") == graph)
    }

    @Test
    func resumeAndRollbackFenceABAWhilePreservingConcurrentTaskProgress() async throws {
        let owner = SessionTaskOrchestrator()
        _ = try await create(owner, tasks: true)
        let receipt = try #require(try await owner.claimTasks(
            sessionID: "root", claims: [TaskClaim(taskID: "work", agentID: "worker")]
        ).first)
        try await owner.registerExecutionScope(
            executionSessionID: "child",
            scope: TaskExecutionScope(rootSessionID: "root", graphID: receipt.graphID, taskID: "work", attemptID: receipt.attemptID)
        )
        let claimed = try #require(try await owner.graphSnapshot(sessionID: "root"))
        let paused = try await owner.updateWorkflow(sessionID: "root", graphID: claimed.id, state: .awaitingUser, message: "Same question", expectedRevision: claimed.revision)
        _ = try await owner.updateTask(sessionID: "child", taskID: "work", update: TaskUpdate(output: "Progress while paused"))
        let resumed = try await owner.resumeWorkflow(sessionID: "root", expectedGraph: paused)
        _ = try await owner.updateTask(sessionID: "child", taskID: "work", update: TaskUpdate(output: "Progress after resume"))
        let progress = try #require(try await owner.graphSnapshot(sessionID: "root"))
        try await owner.rollbackWorkflowResume(sessionID: "root", previousGraph: paused, resumedGraph: resumed)
        let rolledBack = try #require(try await owner.graphSnapshot(sessionID: "root"))
        #expect(rolledBack.tasks == progress.tasks)
        #expect(rolledBack.workflow?.state == .awaitingUser)
        #expect(rolledBack.workflow?.message == "Same question")
        #expect((rolledBack.workflow?.revision ?? 0) > (resumed.workflow?.revision ?? 0))
        await #expect(throws: SessionTaskOrchestratorError.self) {
            try await owner.resumeWorkflow(sessionID: "root", expectedGraph: paused)
        }
        let resumedAgain = try await owner.resumeWorkflow(sessionID: "root", expectedGraph: rolledBack)
        let pausedAgain = try await owner.updateWorkflow(sessionID: "root", graphID: resumedAgain.id, state: .awaitingUser, message: "Same question", expectedRevision: resumedAgain.revision)
        try await owner.rollbackWorkflowResume(sessionID: "root", previousGraph: paused, resumedGraph: resumed)
        #expect(try await owner.graphSnapshot(sessionID: "root") == pausedAgain)
    }

    @Test
    func checkpointRetainsObjectiveAndPauseBeforeAnyTasksAndLegacyRemainsReadable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let workspace = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let store = SessionTaskGraphStore(supportDirectoryURL: root.appendingPathComponent("support"))
        let writer = SessionTaskOrchestrator(store: store)
        try await writer.registerSession(id: "root", workingDirectory: workspace)
        let initial = try await create(writer)
        let paused = try await writer.updateWorkflow(sessionID: "root", graphID: initial.id, state: .blocked, message: "Need external access", expectedRevision: initial.revision)
        let reader = SessionTaskOrchestrator(store: store)
        let candidates = await reader.resumableTaskGraphCheckpoints(workingDirectory: workspace)
        #expect(candidates.map(\.graphID) == [paused.id])
        #expect(candidates.first?.totalTaskCount == 0)
        try await reader.registerSession(id: "root", workingDirectory: workspace)
        let restored = try #require(try await reader.graphSnapshot(sessionID: "root"))
        #expect(restored.workflow == paused.workflow)
        #expect(restored.schemaVersion == 1)
        let continuation = PlanningCommandKernel.workflowAutomaticContinuationPrompt(goal: "unrelated later reply", graph: restored)
        #expect(continuation.contains("Goal: Preserve the complete original objective"))
        #expect(!continuation.contains("unrelated later reply"))

        let legacy = TaskGraphSnapshot(id: "legacy", source: .workflow, state: .active)
        let bytes = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(TaskGraphSnapshot.self, from: bytes)
        #expect(decoded.workflow == nil)
        #expect(decoded.schemaVersion == 1)
        let legacyOwner = SessionTaskOrchestrator()
        let legacyGraph = try await legacyOwner.createGraph(sessionID: "legacy-root", id: "legacy", source: .workflow, state: .active, tasks: [])
        let adopted = try await legacyOwner.resumeWorkflow(sessionID: "legacy-root", expectedGraph: legacyGraph)
        #expect(adopted.workflow?.originalGoal == nil)
        #expect(adopted.workflow?.state == .running)
        let prompt = PlanningCommandKernel.workflowAutomaticContinuationPrompt(goal: "", graph: adopted)
        #expect(prompt.contains("Original goal unavailable"))
        #expect(prompt.contains("do not invent one"))
    }
}
