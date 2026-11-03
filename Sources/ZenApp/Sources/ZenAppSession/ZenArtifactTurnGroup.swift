//
//  ZenArtifactTurnGroup.swift
//  ZenApp
//
//  The file artifacts of a window's transcript, grouped by artifact turn,
//  for the artifacts sidebar.
//

import Foundation
import ToolCore
import ZenCODECore

/// One file artifact of the artifacts sidebar: one artifact of a
/// `.fileArtifacts` transcript row, with the agent that produced it.
public struct ZenArtifactEntry: Identifiable, Equatable, Sendable {
    /// `<transcript item id>-<index in its turn>`: unique across the rows and
    /// the sessions of a window, as the row ids are.
    public let id: String
    /// The artifact.
    public let artifact: FileChangeArtifact
    /// The sub-agent that produced the artifact, or `nil` for the coordinator.
    public let agentID: String?

    public init(id: String, artifact: FileChangeArtifact, agentID: String?) {
        self.id = id
        self.artifact = artifact
        self.agentID = agentID
    }
}

/// The file artifacts of one artifact-history turn
/// (`SessionFileArtifactHistory.Turn.number`), as the sidebar groups them:
/// the live and the sealed rows of the turn, one entry per artifact of each
/// row, in transcript order.
public struct ZenArtifactTurnGroup: Identifiable, Equatable, Sendable {
    /// `<id of the group's first transcript item>-turn-<number>`.
    public let id: String
    /// The artifact turn number.
    public let number: UInt64
    /// The artifacts of the turn, in transcript order.
    public let entries: [ZenArtifactEntry]

    public init(id: String, number: UInt64, entries: [ZenArtifactEntry]) {
        self.id = id
        self.number = number
        self.entries = entries
    }

    /// The groups of the `.fileArtifacts` rows of `transcript`, by artifact
    /// turn number in the order the numbers first appear; every other row is
    /// ignored. Each entry keeps the agent of its row. A row without
    /// artifacts adds no entry and starts no group.
    public static func groups(in transcript: [ZenTranscriptItem]) -> [ZenArtifactTurnGroup] {
        var numbers: [UInt64] = []
        var firstItemIDs: [UInt64: String] = [:]
        var entries: [UInt64: [ZenArtifactEntry]] = [:]
        for item in transcript {
            guard case let .fileArtifacts(turn, agentID, _) = item.content, !turn.artifacts.isEmpty else {
                continue
            }
            if firstItemIDs[turn.number] == nil {
                firstItemIDs[turn.number] = item.id
                numbers.append(turn.number)
            }
            for (index, artifact) in turn.artifacts.enumerated() {
                entries[turn.number, default: []].append(ZenArtifactEntry(
                    id: "\(item.id)-\(index)",
                    artifact: artifact,
                    agentID: agentID
                ))
            }
        }
        return numbers.map { number in
            ZenArtifactTurnGroup(
                id: "\(firstItemIDs[number] ?? "")-turn-\(number)",
                number: number,
                entries: entries[number] ?? []
            )
        }
    }
}
