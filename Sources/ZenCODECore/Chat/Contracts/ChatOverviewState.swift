//
//  ChatOverviewState.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 30/05/26.
//

import Foundation
import ToolCore

/// Why an overview is presented.
///
/// Live progress that the session observes by itself is ``automatic``; a
/// channel may withhold it (the terminal does not append it beneath a model
/// response that already ended). An overview the operator asked for with a
/// command (`/tasks`) is ``explicit`` and is always shown.
enum ChatOverviewOrigin: Sendable, Equatable {
    case automatic
    case explicit
}

/// A channel's reservation of one overview publication, taken before the
/// session reads the state it presents.
///
/// Publications overlap: a debounced observer publication, a `/tasks`
/// command, the turn-boundary quiescence, and a deferred publication can each
/// read the graph and present it, and the one that started first can finish
/// last. The controller reserves a publication at the point it starts (for the
/// observer, as soon as the graph changes, before the debounce) and hands the
/// reservation back with what it presents. A channel that orders its sections
/// by reservation can then drop a publication that a later one overtook, and
/// can drop at reservation time a section it was holding back for later
/// (the terminal defers a section while a tool block or a stream is on
/// screen), because a fresher one is on its way.
///
/// The sub-agent overview has reservations of its own, taken the same way
/// before the controller reads the sub-agent snapshots: a publication after a
/// sub-agent tool call, a tick of the refresh that runs while a blocking
/// `agent.*` call executes, and the final publication when the refresh stops
/// can overlap like the task-graph ones.
///
/// The value belongs to the channel: the controller never reads it, it only
/// passes it back. A channel that does not order its publications reserves
/// nothing, and the controller presents with a `nil` reservation, which means
/// "present this as it comes".
struct ChatOverviewPublication: Sendable, Equatable {
    /// The channel's ordering of the reservation; a later reservation has a
    /// greater revision.
    let revision: Int
}

/// The session's current task graph with the task views a channel shows,
/// as the observer and `/tasks` publish it.
///
/// The type is the semantic state only. The text, the colors, and the width
/// of the section belong to the channel that presents it. The signature and the
/// significance threshold are the ones the terminal always used, so a channel
/// that skips an unchanged or trivial graph does it the same way.
struct ChatTaskGraphOverview: Sendable, Equatable {
    /// The current graph of the session.
    let graph: TaskGraphSnapshot
    /// The task views of ``graph``, in the runtime's order.
    let tasks: [TaskRecordView]
    /// Identity of what a channel renders, see ``signature(for:)``.
    let signature: String

    init(graph: TaskGraphSnapshot, tasks: [TaskRecordView]) {
        self.graph = graph
        self.tasks = tasks
        self.signature = Self.signature(for: graph)
    }

    /// Whether an automatic publication shows this graph: more than one task,
    /// or a task that has run, or one that needs the operator's attention
    /// (blocked, failed, awaiting validation). A graph below the threshold, a
    /// single task that has not run, stays hidden.
    var isSignificant: Bool {
        Self.isSignificant(graph)
    }

    /// The session's current graph with its task views, or `nil` when the
    /// session has no task graph: the read behind `/tasks` and the ACP plan.
    /// Throws when either read fails.
    static func current(
        in runtime: any ChatSessionRuntime,
        sessionID: String
    ) async throws -> ChatTaskGraphOverview? {
        guard let graph = try await runtime.taskGraphSnapshot(
            sessionID: sessionID,
            graphID: nil
        ) else {
            return nil
        }
        let tasks = try await runtime.taskOrchestrator.listTasks(
            sessionID: sessionID,
            graphID: graph.id
        )
        return ChatTaskGraphOverview(graph: graph, tasks: tasks)
    }

    static func isSignificant(_ graph: TaskGraphSnapshot) -> Bool {
        graph.tasks.count > 1 || graph.tasks.contains { task in
            !task.attempts.isEmpty
                || task.status == .blocked
                || task.status == .failed
                || task.status == .awaitingValidation
        }
    }

    /// Identity of the graph state a channel renders: the graph revision and
    /// state, and for every task its revision, status, active attempt, and
    /// attempts. Equal signatures mean an equal section.
    static func signature(for graph: TaskGraphSnapshot) -> String {
        let tasks = graph.tasks.sorted { $0.id < $1.id }.map { task in
            let attempts = task.attempts.map {
                "\($0.id):\($0.status.rawValue)"
            }.joined(separator: ",")
            return "\(task.id):\(task.revision):\(task.status.rawValue):\(task.activeAttemptID, default: "-"):\(attempts)"
        }.joined(separator: "|")
        return "\(graph.id):\(graph.revision):\(graph.state.rawValue):\(tasks)"
    }
}

/// The sub-agents of the session at one moment: the runtime's snapshots,
/// the batch the runtime marks as current, and the signature of what they say.
///
/// Only the runtime's data is here. How a channel shows it (the density of
/// the section, the wrapping, the tool rows its render coordinator tracks) is
/// the channel's own, and a channel that keeps such presentation state adds
/// it to the signature itself.
struct ChatSubAgentOverview: Sendable {
    /// Every sub-agent snapshot, in the runtime's order. Empty when the
    /// session has no sub-agent to show.
    let snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    /// The identity (a UUID string) of the overview wave that is current now,
    /// or `nil` when no snapshot belongs to it. The overview can also hold
    /// older standby agents and agents active through shared chat, so the
    /// wave comes from the runtime's own mark, never from the array order.
    let currentBatchID: String?
    /// Identity of what a channel renders, see ``signature(for:)``.
    let signature: String

    init(snapshots: [DirectSubAgentRuntime.AgentSnapshot]) {
        self.snapshots = snapshots
        self.currentBatchID = Self.currentBatchID(in: snapshots)
        self.signature = Self.signature(for: snapshots)
    }

    /// The batch of the first snapshot the runtime marked as part of the
    /// current overview wave.
    static func currentBatchID(
        in snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> String? {
        snapshots
            .first(where: \.isInCurrentOverviewWave)?
            .overviewBatchID?
            .uuidString
    }

    /// Identity of the state a channel renders for `snapshots`. Equal
    /// signatures mean an equal section, so anything shown on a row takes part.
    static func signature(
        for snapshots: [DirectSubAgentRuntime.AgentSnapshot]
    ) -> String {
        snapshots.map { snapshot in
            let hasResponse = snapshot.latestContentPreview?.nilIfBlank != nil
                || snapshot.latestOutput?.nilIfBlank != nil
            return [
                snapshot.id,
                snapshot.name,
                snapshot.role,
                snapshot.profileName?.nilIfBlank ?? "",
                snapshot.status.rawValue,
                snapshot.pending ? "pending" : "idle",
                snapshot.configuredModelID?.nilIfBlank ?? "",
                snapshot.modelID?.nilIfBlank ?? "",
                // The kind participates in the signature: the same text can be
                // rendered as reasoning or as a message, and a phase change
                // with no visible activity still changes the placeholder row.
                snapshot.currentActivityKind?.rawValue ?? "",
                snapshot.currentActivity?.nilIfBlank ?? "",
                snapshot.currentToolName?.nilIfBlank ?? "",
                snapshot.currentToolTarget?.nilIfBlank ?? "",
                // The counters share the model row, so a metrics update alone
                // changes the rendered overview and must invalidate it.
                metricsSignature(snapshot),
                hasResponse ? "response" : "",
                snapshot.latestError?.nilIfBlank ?? ""
            ].joined(separator: "\u{1F}")
        }
        .joined(separator: "\u{1E}")
    }

    /// Identity of the counters rendered on the model row, built from the raw
    /// values so any reported change is detected even when the abbreviated
    /// text happens to stay the same.
    private static func metricsSignature(
        _ snapshot: DirectSubAgentRuntime.AgentSnapshot
    ) -> String {
        guard let metrics = snapshot.latestMetrics else {
            return ""
        }
        return [
            metrics.cachedPromptTokenCount.map(String.init) ?? "",
            metrics.promptTokenCount.map(String.init) ?? "",
            metrics.completionTokenCount.map(String.init) ?? ""
        ].joined(separator: "/")
    }
}
