//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation
import ToolCore
import ZenCODERuntime

/// Runtime projection only; the session owns one instance per incarnation and
/// the orchestrator remains the sole DAG owner. The projection reads one graph
/// snapshot: the `plan` lists its tasks and every delegated attempt is a
/// `tool_call`.
///
/// Two paths present through it: a prompt, whose presentation writes the
/// updates through its pipeline and acknowledges the units the pipeline
/// accepted, and the session's own observer or an explicit `/tasks`, which read
/// the graph, write the plan themselves and acknowledge it. Preparing never
/// commits deduplication state; ``acknowledge(_:)`` does, once the update
/// reached the writer (or the pipeline).
///
/// Preparing does reserve the graph as the newest one prepared
/// (``planToPresent(for:force:)``), so a plan built from a snapshot an event
/// later than one already prepared is dropped instead of written over it: both
/// paths read the graph immediately before preparing, and the later read wins
/// the reservation whichever write reaches the writer first.
actor ACPTaskPresentation {
    private var lastPlan: JSONValue?
    /// The graph the newest plan was prepared from. Revisions are compared only
    /// within one graph: another graph replaces the section.
    private var newestGraphID: String?
    private var newestGraphRevision: Int?
    private var attempts: [String: JSONValue] = [:]

    /// The updates to present for `graph`: the `plan` when it changed, then one
    /// `tool_call`/`tool_call_update` per delegated attempt. Preparing an update
    /// does not commit deduplication state: a cancelled observer or a rejected
    /// pipeline unit has to be replayable by the next prompt.
    func updates(for graph: TaskGraphSnapshot?) -> [JSONValue] {
        var updates: [JSONValue] = []
        if let plan = planToPresent(for: graph) {
            updates.append(plan)
        }
        let tasks = Self.orderedTasks(graph)
        guard let graph else {
            // No graph, no task rows to keep: the section is gone with it.
            attempts.removeAll()
            return updates
        }
        var liveAttemptIDs = Set<String>()
        for task in tasks {
            for attempt in task.attempts where attempt.executor == .subAgent {
                let id = "acp:work:\(graph.id):\(task.id):\(attempt.id)"
                liveAttemptIDs.insert(id)
                let status: String
                switch attempt.status {
                case .queued: status = "pending"
                case .running: status = "in_progress"
                case .completed: status = "completed"
                case .failed, .cancelled, .interrupted: status = "failed"
                }
                let text = [
                    "Execution: \(attempt.status.rawValue). Task: \(task.status.rawValue).",
                    attempt.output, attempt.error
                ].compactMap { $0 }.joined(separator: "\n\n")
                let fields: [String: JSONValue] = [
                    "toolCallId": .string(id),
                    "title": .string("\(task.title) — \(attempt.agentID ?? "delegated agent") · attempt \(attempt.ordinal)"),
                    "kind": .string("other"),
                    "status": .string(status),
                    "content": .array([.object([
                        "type": .string("content"),
                        "content": .object(["type": .string("text"), "text": .string(text)])
                    ])])
                ]
                let snapshot = JSONValue.object(fields)
                guard attempts[id] != snapshot else { continue }
                var update = fields
                update["sessionUpdate"] = .string(attempts[id] == nil ? "tool_call" : "tool_call_update")
                updates.append(.object(update))
            }
        }
        // The rows of attempts the graph no longer has are dropped, so a long
        // incarnation does not keep the text of every attempt it ever ran.
        attempts = attempts.filter { liveAttemptIDs.contains($0.key) }
        return updates
    }

    /// Called only once the update reached its destination: the unit the prompt
    /// pipeline accepted, or the plan this projection wrote itself.
    func acknowledge(_ update: JSONValue) {
        guard let object = update.objectValue else { return }
        if object["sessionUpdate"] == .string("plan") {
            lastPlan = update
            return
        }
        var fields = object
        guard let id = fields["toolCallId"]?.acpStringValue else { return }
        fields.removeValue(forKey: "sessionUpdate")
        attempts[id] = .object(fields)
    }

    /// The `plan` to write for `graph`, or `nil` when that graph's plan is
    /// already the one presented (`force` presents it anyway) or when a newer
    /// graph was already prepared. It reserves `graph` as the newest prepared
    /// one; the caller writes the plan and then calls ``acknowledge(_:)``.
    func planToPresent(for graph: TaskGraphSnapshot?, force: Bool = false) -> JSONValue? {
        let plan = Self.planUpdate(for: graph)
        guard isNotOlder(graph) else { return nil }
        newestGraphID = graph?.id
        newestGraphRevision = graph?.revision
        return force || lastPlan != plan ? plan : nil
    }

    /// Whether `graph` is not older than the newest graph a plan was prepared
    /// from. A graph the projection has never seen, and the absence of a graph,
    /// are always accepted.
    private func isNotOlder(_ graph: TaskGraphSnapshot?) -> Bool {
        guard let graph,
              graph.id == newestGraphID,
              let newestRevision = newestGraphRevision else {
            return true
        }
        return graph.revision >= newestRevision
    }

    /// The `plan` update of `graph`: the Tasks section of the ACP client, with
    /// one entry per task of the graph.
    static func planUpdate(for graph: TaskGraphSnapshot?) -> JSONValue {
        .object([
            "sessionUpdate": .string("plan"),
            "entries": .array(orderedTasks(graph).map(entry))
        ])
    }

    /// The tasks of `graph` in the order the terminal and Telegram list them:
    /// by `order`, then by id.
    private static func orderedTasks(_ graph: TaskGraphSnapshot?) -> [TaskRecord] {
        (graph?.tasks ?? []).sorted {
            $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order
        }
    }

    /// One plan entry. ACP's status enum has no failure values, so a task that
    /// needs the operator's attention keeps a `pending` status and says which
    /// state it is in.
    static func entry(_ task: TaskRecord) -> JSONValue {
        let status: String
        let label: String
        switch task.status {
        case .pending:
            (status, label) = ("pending", "")
        case .inProgress:
            (status, label) = ("in_progress", "")
        case .awaitingValidation:
            (status, label) = ("in_progress", "[\(task.status.rawValue)] ")
        case .completed:
            (status, label) = ("completed", "")
        case .blocked, .failed, .cancelled:
            (status, label) = ("pending", "[\(task.status.rawValue)] ")
        }
        return .object([
            "content": .string(label + task.title),
            "priority": .string(priority(task.priority)),
            "status": .string(status)
        ])
    }

    private static func priority(_ priority: TaskPriority) -> String {
        switch priority {
        case .low: "low"
        case .normal: "medium"
        case .high: "high"
        }
    }
}

extension ZenCODEACPBridge {
    /// Whether `promptID` still holds the live incarnation `epoch` of
    /// `sessionID`: the bridge's own entry and the host's reservation.
    func isCurrentPresentation(sessionID: String, epoch: UInt64, promptID: UUID) async -> Bool {
        await reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID) != nil
    }

    func publishTaskPresentation(
        sessionID: String, epoch: UInt64, promptID: UUID,
        presentation: ACPTaskPresentation, pipeline: ACPPromptUpdatePipeline
    ) async {
        guard await isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) else { return }
        let graph: TaskGraphSnapshot?
        do { graph = try await sessionRunner.taskGraphSnapshot(sessionID: sessionID) }
        catch { return } // An unavailable snapshot is not an authoritative clear.
        guard !Task.isCancelled,
              await isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) else { return }
        let updates = await presentation.updates(for: graph)
        for update in updates {
            guard !Task.isCancelled,
                  await isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) else { return }
            await pipeline.enqueue(.init(kind: .consume(update)), onAccepted: {
                await presentation.acknowledge(update)
            }).value
        }
    }
}
