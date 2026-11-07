//  Created by Gerardo Grisolini on 30/05/26.
//
import Foundation
import ToolCore

/// Runtime projection only; the session owns one instance per incarnation and
/// the orchestrator remains the sole DAG owner. The projection reads the graph
/// of the shared ``ChatTaskGraphOverview``: the `plan` lists its tasks and
/// every delegated attempt is a `tool_call`.
actor ACPTaskPresentation {
    private var lastPlan: JSONValue?
    private var attempts: [String: JSONValue] = [:]

    func updates(for overview: ChatTaskGraphOverview?) -> [JSONValue] {
        let graph = overview?.graph
        let tasks = (graph?.tasks ?? []).sorted {
            $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order
        }
        let plan: JSONValue = .object([
            "sessionUpdate": .string("plan"),
            "entries": .array(tasks.map(Self.entry))
        ])
        var updates: [JSONValue] = []
        if lastPlan != plan {
            updates.append(plan)
        }
        guard let graph else { return updates }
        for task in tasks {
            for attempt in task.attempts where attempt.executor == .subAgent {
                let id = "acp:work:\(graph.id):\(task.id):\(attempt.id)"
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
        return updates
    }

    /// Called only for units accepted by the owning prompt pipeline. Preparing
    /// an update must not commit deduplication state: a cancelled observer or
    /// a rejected pipeline unit has to be replayable by the next prompt.
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

    static func entry(_ task: TaskRecord) -> JSONValue {
        let status: String
        switch task.status {
        case .inProgress, .awaitingValidation: status = "in_progress"
        case .completed: status = "completed"
        case .pending, .blocked, .failed, .cancelled: status = "pending"
        }
        let label: String
        switch task.status {
        case .blocked, .failed, .cancelled, .awaitingValidation:
            label = "[\(task.status.rawValue)] "
        default: label = ""
        }
        return .object([
            "content": .string(label + task.title),
            "priority": .string(task.priority == .normal ? "medium" : task.priority.rawValue),
            "status": .string(status)
        ])
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
        let overview: ChatTaskGraphOverview?
        do { overview = try await ChatTaskGraphOverview.current(in: sessionRunner, sessionID: sessionID) }
        catch { return } // An unavailable snapshot is not an authoritative clear.
        guard !Task.isCancelled,
              await isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) else { return }
        let updates = await presentation.updates(for: overview)
        for update in updates {
            guard !Task.isCancelled,
                  await isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) else { return }
            await pipeline.enqueue(.init(kind: .consume(update)), onAccepted: {
                await presentation.acknowledge(update)
            }).value
        }
    }
}

extension ZenCODEACPBridge {
    /// Claims, for the prompt `promptID` of the incarnation `epoch` of
    /// `sessionID`, the delivery of one delegated tool notification (a tool
    /// call id and its phase): `true` the first time during that prompt, and
    /// only while the prompt holds its incarnation and the session has a
    /// prompt update pipeline (from the moment the prompt starts presenting
    /// until its task presentation finishes). The pipeline is not compared
    /// with the prompt's: the prompt installs its own before its presenter
    /// exists, and no other prompt can install one while this one holds the
    /// reservation. The prompt's presenter renders the notification (see
    /// ``ACPPromptPresenter/presentSubAgentToolEvent(_:)``); the host routes
    /// the event to the session's controller by its root session.
    func claimDelegatedToolNotification(
        _ notificationID: String,
        sessionID: String,
        epoch: UInt64,
        promptID: UUID
    ) async -> Bool {
        guard let session = await reservedPromptSession(sessionID: sessionID, epoch: epoch, promptID: promptID),
              session.promptUpdatePipeline != nil else { return false }
        return sessions[session.id]?.delegatedToolNotifications.insert(notificationID).inserted == true
    }
}
