import Foundation
import ToolCore

/// Runtime-only artifact history for one active terminal session.
/// It is deliberately not Codable and never participates in session snapshots,
/// checkpoints, transcripts, or ACP state.
public actor SessionFileArtifactHistory {
    public struct Turn: Sendable, Equatable, Hashable {
        public let number: UInt64
        public let artifacts: [FileChangeArtifact]

        public init(number: UInt64, artifacts: [FileChangeArtifact]) {
            self.number = number
            self.artifacts = artifacts
        }
    }

    private struct EventID: Hashable {
        let agentID: String?
        let callID: String
    }

    private struct PendingTurn {
        var number: UInt64?
        var latestChanges: [String: OperationFileChange] = [:]
        var seenEvents: Set<EventID> = []
        var isSealed = false
    }

    private var sessionID: String?
    private var nextTurnNumber: UInt64 = 1
    private var turns: [Turn] = []
    private var pendingTurns: [UUID: PendingTurn] = [:]

    public init(sessionID: String? = nil) {
        self.sessionID = sessionID
    }

    public func reset(for sessionID: String) {
        self.sessionID = sessionID
        nextTurnNumber = 1
        turns.removeAll(keepingCapacity: false)
        pendingTurns.removeAll(keepingCapacity: false)
    }

    private func reserveNumber() -> UInt64 {
        defer { nextTurnNumber += 1 }
        return nextTurnNumber
    }

    /// Tokens are invalid after reset, even when the session ID is reused.
    func beginTurn(sessionID: String) -> UUID? {
        guard self.sessionID == nil || self.sessionID == sessionID else { return nil }
        self.sessionID = sessionID
        let id = UUID()
        pendingTurns[id] = PendingTurn()
        return id
    }

    /// Only the newly completed operation is returned; history remains net-final.
    func recordLive(
        _ changes: [OperationFileChange],
        agentID: String?,
        callID: String,
        turnID: UUID,
        workingDirectory: URL
    ) -> Turn? {
        guard var pending = pendingTurns[turnID], !pending.isSealed,
              !changes.isEmpty else { return nil }
        let event = EventID(agentID: agentID, callID: callID)
        guard pending.seenEvents.insert(event).inserted else { return nil }
        let artifacts = FileChangeArtifactMapper.artifacts(from: changes, workingDirectory: workingDirectory)
        guard !artifacts.isEmpty else { return nil }
        let number = pending.number ?? reserveNumber()
        pending.number = number
        // Match the mapper's first-path-wins semantics within one operation.
        var seenPaths = Set<String>()
        for change in changes where !change.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let path = FileChangeArtifactMapper.absolutePath(for: change.path, workingDirectory: workingDirectory)
            if seenPaths.insert(path).inserted {
                pending.latestChanges[path] = OperationFileChange(
                    path: path, oldText: change.oldText, newText: change.newText,
                    explanation: change.explanation
                )
            }
        }
        pendingTurns[turnID] = pending
        return Turn(number: number, artifacts: artifacts)
    }

    /// Stop admitting live events before final reconciliation suspends.
    func sealTurn(_ id: UUID) -> [OperationFileChange] {
        guard var pending = pendingTurns[id], !pending.isSealed else { return [] }
        pending.isSealed = true
        pendingTurns[id] = pending
        return pending.latestChanges.values.sorted { $0.path < $1.path }
    }

    /// Stores the complete net-final turn, but returns only evidence not already
    /// shown live in the same final state. A reverted live turn leaves a number gap.
    func finishTurn(
        _ id: UUID,
        summary: TurnFileChangeSummary?,
        matchingLivePaths: Set<String>,
        workingDirectory: URL
    ) -> Turn? {
        guard let pending = pendingTurns.removeValue(forKey: id), let summary else { return nil }
        let artifacts = FileChangeArtifactMapper.artifacts(from: summary, workingDirectory: workingDirectory)
        guard !artifacts.isEmpty else { return nil }
        let number = pending.number ?? reserveNumber()
        turns.append(Turn(number: number, artifacts: artifacts))
        turns.sort { $0.number < $1.number }
        let unseen = artifacts.filter { !matchingLivePaths.contains($0.absolutePath) }
        return unseen.isEmpty ? nil : Turn(number: number, artifacts: unseen)
    }

    @discardableResult
    public func append(
        summary: TurnFileChangeSummary,
        sessionID: String,
        workingDirectory: URL
    ) -> Turn? {
        guard let id = beginTurn(sessionID: sessionID) else { return nil }
        return finishTurn(id, summary: summary, matchingLivePaths: [], workingDirectory: workingDirectory)
    }

    public func snapshot() -> [Turn] {
        turns
    }
}
