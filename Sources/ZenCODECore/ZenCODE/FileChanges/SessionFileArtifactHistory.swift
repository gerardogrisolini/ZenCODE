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

    private var sessionID: String?
    private var nextTurnNumber: UInt64 = 1
    private var turns: [Turn] = []

    public init(sessionID: String? = nil) {
        self.sessionID = sessionID
    }

    public func reset(for sessionID: String) {
        self.sessionID = sessionID
        nextTurnNumber = 1
        turns.removeAll(keepingCapacity: false)
    }

    private func beginTurn() -> UInt64 {
        defer { nextTurnNumber += 1 }
        return nextTurnNumber
    }

    @discardableResult
    public func append(
        summary: TurnFileChangeSummary,
        sessionID: String,
        workingDirectory: URL
    ) -> Turn? {
        guard self.sessionID == nil || self.sessionID == sessionID else {
            return nil
        }
        self.sessionID = sessionID
        let artifacts = FileChangeArtifactMapper.artifacts(
            from: summary,
            workingDirectory: workingDirectory
        )
        guard !artifacts.isEmpty else {
            return nil
        }
        let number = beginTurn()
        guard !turns.contains(where: { $0.number == number }) else { return nil }
        let turn = Turn(number: number, artifacts: artifacts)
        turns.append(turn)
        turns.sort { $0.number < $1.number }
        return turn
    }

    public func snapshot() -> [Turn] {
        turns
    }
}
