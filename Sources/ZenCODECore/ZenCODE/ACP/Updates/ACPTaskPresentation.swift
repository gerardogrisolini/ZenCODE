import Foundation
import ToolCore

/// Ephemeral projection only. The orchestrator remains the sole DAG owner.
actor ACPTaskPresentation {
    private var lastPlan: JSONValue?
    private var attempts: [String: JSONValue] = [:]

    func updates(for graph: TaskGraphSnapshot?) -> [JSONValue] {
        let tasks = (graph?.tasks ?? []).sorted {
            $0.order == $1.order ? $0.id < $1.id : $0.order < $1.order
        }
        let plan: JSONValue = .object([
            "sessionUpdate": .string("plan"),
            "entries": .array(tasks.map(Self.entry))
        ])
        var updates: [JSONValue] = []
        if lastPlan != plan {
            lastPlan = plan
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
                attempts[id] = snapshot
                updates.append(.object(update))
            }
        }
        return updates
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
    func isCurrentPresentation(sessionID: String, epoch: UInt64, promptID: UUID) -> Bool {
        guard let session = liveSession(id: sessionID, epoch: epoch) else { return false }
        return session.activePromptID == promptID && session.operationState == .prompting(promptID)
    }

    func publishTaskPresentation(
        sessionID: String, epoch: UInt64, promptID: UUID,
        presentation: ACPTaskPresentation, pipeline: ACPPromptUpdatePipeline
    ) async {
        guard isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) else { return }
        let graph: TaskGraphSnapshot?
        do { graph = try await sessionRunner.taskGraphSnapshot(sessionID: sessionID) }
        catch { return } // An unavailable snapshot is not an authoritative clear.
        guard !Task.isCancelled,
              isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) else { return }
        let updates = await presentation.updates(for: graph)
        for update in updates {
            guard !Task.isCancelled,
                  isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) else { return }
            await pipeline.enqueue(.init(kind: .consume(update))).value
        }
    }
}

extension ZenCODEACPBridge {
    func presentDelegatedToolEvent(_ event: DirectSubAgentToolEvent) async {
        // Capture ownership before the cross-actor lookup. A suspended callback
        // must never adopt a replacement session or a later prompt.
        let owners = sessions.mapValues { ($0.epoch, $0.activePromptID) }
        let snapshots = await sessionRunner.subAgentSnapshots()
        guard let agent = snapshots.first(where: { $0.id == event.agentID }),
              let (epoch, ownerPromptID) = owners[agent.rootSessionID],
              let promptID = ownerPromptID,
              let session = liveSession(id: agent.rootSessionID, epoch: epoch),
              session.activePromptID == promptID,
              let pipeline = session.promptUpdatePipeline,
              isCurrentPresentation(sessionID: session.id, epoch: session.epoch, promptID: promptID) else { return }
        // Runtime agent IDs are unique per creation/attempt, and are also
        // available to the permission broker before any operation executes.
        let id = "acp:tool:\(agent.id):\(event.toolCall.id)"
        var update: [String: Any]
        let phase: String
        switch event.lifecycle {
        case .started:
            phase = "started"
            update = Self.toolCallCreateUpdate(for: event.toolCall, workingDirectory: URL(fileURLWithPath: session.cwd))
        case let .completed(result):
            phase = "completed"
            update = Self.toolCallCompletionUpdate(for: event.toolCall, result: result, workingDirectory: URL(fileURLWithPath: session.cwd))
        }
        let notificationID = id + ":" + phase
        guard sessions[session.id]?.delegatedToolNotifications.insert(notificationID).inserted == true else { return }
        update["toolCallId"] = id
        update["title"] = "\(agent.name) — \(Self.toolTitle(for: event.toolCall))"
        await pipeline.enqueue(.init(kind: .consume(JSONValue.acpValue(from: update)))).value
    }
}
