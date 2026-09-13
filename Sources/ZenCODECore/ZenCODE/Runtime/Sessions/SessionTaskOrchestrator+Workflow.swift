//
//  SessionTaskOrchestrator+Workflow.swift
//  ZenCODE
//

import Foundation
import ToolCore

extension SessionTaskOrchestrator {
    /// Root-only structured control. Task lifecycle and validation remain independent.
    @discardableResult
    public func updateWorkflow(
        sessionID rawSessionID: String,
        graphID: String,
        state: TaskGraphWorkflowState,
        message: String?,
        expectedRevision: Int
    ) throws -> TaskGraphSnapshot {
        let sessionID = try requireRootAccess(rawSessionID)
        let graph = try activeWorkflowGraph(sessionID: sessionID, graphID: graphID)
        guard graph.revision == expectedRevision else {
            throw SessionTaskOrchestratorError.staleRevision(expected: expectedRevision, actual: graph.revision)
        }
        var workflow = graph.workflow ?? TaskGraphWorkflow(originalGoal: nil)
        workflow.state = state
        workflow.message = message?.nilIfBlank
        workflow.revision += 1
        return try commitWorkflow(workflow, graph: graph, sessionID: sessionID)
    }

    /// A user reply consumes the observed workflow signal, not a task revision:
    /// a child may legitimately report progress while the operator is answering.
    @discardableResult
    public func resumeWorkflow(
        sessionID rawSessionID: String,
        expectedGraph: TaskGraphSnapshot
    ) throws -> TaskGraphSnapshot {
        let sessionID = try requireRootAccess(rawSessionID)
        let graph = try activeWorkflowGraph(sessionID: sessionID, graphID: expectedGraph.id)
        guard graph.createdAt == expectedGraph.createdAt,
              graph.workflow == expectedGraph.workflow else {
            throw SessionTaskOrchestratorError.invalidSnapshot("workflow changed before the user reply was accepted")
        }
        var workflow = graph.workflow ?? TaskGraphWorkflow(originalGoal: nil)
        workflow.state = .running
        workflow.message = nil
        workflow.revision += 1
        return try commitWorkflow(workflow, graph: graph, sessionID: sessionID)
    }

    /// Roll back only this reservation's resume, never concurrent task progress
    /// or a newer workflow signal. Revision stays monotonic to fence ABA races.
    public func rollbackWorkflowResume(
        sessionID rawSessionID: String,
        previousGraph: TaskGraphSnapshot,
        resumedGraph: TaskGraphSnapshot
    ) throws {
        let sessionID = try requireRootAccess(rawSessionID)
        let graph = try activeWorkflowGraph(sessionID: sessionID, graphID: resumedGraph.id)
        guard previousGraph.id == resumedGraph.id,
              graph.createdAt == resumedGraph.createdAt,
              graph.workflow == resumedGraph.workflow else { return }
        var workflow = previousGraph.workflow ?? TaskGraphWorkflow(originalGoal: nil)
        workflow.revision = (graph.workflow?.revision ?? 0) + 1
        _ = try commitWorkflow(workflow, graph: graph, sessionID: sessionID, checkingCancellation: false)
    }

    private func activeWorkflowGraph(sessionID: String, graphID: String) throws -> TaskGraphSnapshot {
        guard let graph = try selectedGraph(sessionID: sessionID, graphID: graphID) else {
            throw SessionTaskOrchestratorError.graphNotFound(graphID)
        }
        guard sessionStates[sessionID]?.currentGraphID == graphID,
              graph.source.requiresSubAgentExecution,
              graph.state == .active else {
            throw SessionTaskOrchestratorError.graphNotActive(graphID)
        }
        return graph
    }

    private func commitWorkflow(
        _ workflow: TaskGraphWorkflow,
        graph original: TaskGraphSnapshot,
        sessionID: String,
        checkingCancellation: Bool = true
    ) throws -> TaskGraphSnapshot {
        if checkingCancellation { try Task.checkCancellation() }
        var graph = original
        graph.workflow = workflow
        try validate(graph)
        touchGraph(&graph, at: Date())
        guard var sessionState = sessionStates[sessionID] else {
            throw SessionTaskOrchestratorError.graphNotFound(graph.id)
        }
        sessionState.graphs[graph.id] = graph
        try commit(sessionID: sessionID, state: sessionState, eventKind: .updated, graphID: graph.id)
        return graph
    }
}
