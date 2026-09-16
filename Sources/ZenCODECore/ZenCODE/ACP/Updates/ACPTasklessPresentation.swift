import Foundation
import ToolCore

actor ACPTasklessPresentation {
    private var previous: [String: JSONValue] = [:]
    private var finished = Set<String>()
    // Internal test seam: suspend after preparation, before observer admission.
    private let onPrepared: (@Sendable ([JSONValue]) async -> Void)?

    init(onPrepared: (@Sendable ([JSONValue]) async -> Void)? = nil) {
        self.onPrepared = onPrepared
    }

    /// Preparing a snapshot does not commit deduplication state. A cancelled
    /// observer or a rejected pipeline unit must remain replayable next prompt.
    func updates(_ agents: [DirectSubAgentRuntime.AgentSnapshot]) async -> [JSONValue] {
        var updates: [JSONValue] = []
        for agent in agents.sorted(by: { $0.id < $1.id }) where agent.taskID == nil {
            guard agent.executionRevision > 0 else { continue }
            let id = "acp:work:\(agent.id):\(agent.executionRevision)"
            guard !finished.contains(id) else { continue }
            let status: String
            if agent.latestError != nil || agent.status == .failed {
                status = "failed"
            } else if agent.completedExecutionRevision == agent.executionRevision {
                status = "completed"
            } else if agent.status == .closed {
                status = "failed"
            } else {
                status = agent.status == .running ? "in_progress" : "pending"
            }
            let text = ["Agent state: \(agent.status.rawValue). Execution output is not task validation.",
                        agent.completedExecutionRevision == agent.executionRevision ? agent.latestOutput : nil,
                        agent.latestError].compactMap { $0 }.joined(separator: "\n\n")
            var fields: [String: JSONValue] = [
                "toolCallId": .string(id), "title": .string("\(agent.name) — \(agent.role)"),
                "kind": .string("other"), "status": .string(status),
                "content": .array([.object(["type": .string("content"), "content": .object([
                    "type": .string("text"), "text": .string(text)
                ])])])
            ]
            let snapshot = JSONValue.object(fields)
            guard previous[id] != snapshot else { continue }
            fields["sessionUpdate"] = .string(previous[id] == nil ? "tool_call" : "tool_call_update")
            updates.append(.object(fields))
        }
        if let onPrepared { await onPrepared(updates) }
        return updates
    }

    /// Called only for units accepted by the owning prompt pipeline. Observer
    /// teardown waits for its unit (including this acknowledgement) to finish.
    func acknowledge(_ update: JSONValue) {
        guard var fields = update.objectValue,
              let id = fields["toolCallId"]?.acpStringValue,
              !finished.contains(id) else { return }
        fields.removeValue(forKey: "sessionUpdate")
        previous[id] = .object(fields)
        let status = fields["status"]?.acpStringValue
        if status == "completed" || status == "failed" { finished.insert(id) }
    }
}

extension ZenCODEACPBridge {
    /// Called at a runtime event boundary after its backend exists, before an
    /// agent.create tool can run. Runtime snapshots are invalidations, not polling.
    func ensureTasklessObserver(sessionID: String, epoch: UInt64, promptID: UUID) async {
        guard let session = liveSession(id: sessionID, epoch: epoch),
              session.activePromptID == promptID, session.tasklessObserver == nil,
              let pipeline = session.promptUpdatePipeline else { return }
        // Reserve before the suspension so concurrent callbacks cannot subscribe twice.
        sessions[sessionID]?.tasklessObserver = Task {}
        guard let stream = await sessionRunner.existingSubAgentSnapshotEvents(rootSessionID: sessionID) else {
            if isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) {
                sessions[sessionID]?.tasklessObserver = nil
            }
            return
        }
        guard isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) else {
            let cleanup = Task { for await _ in stream {} }
            cleanup.cancel()
            await cleanup.value
            return
        }
        let projection = session.tasklessPresentation
        sessions[sessionID]?.tasklessObserver = Task {
            for await snapshots in stream {
                guard !Task.isCancelled,
                      isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) else { return }
                let updates = await projection.updates(snapshots.filter { $0.rootSessionID == sessionID })
                for update in updates {
                    guard !Task.isCancelled,
                          isCurrentPresentation(sessionID: sessionID, epoch: epoch, promptID: promptID) else { return }
                    await pipeline.enqueue(.init(kind: .consume(update)), onAccepted: {
                        await projection.acknowledge(update)
                    }).value
                }
            }
        }
    }
}
