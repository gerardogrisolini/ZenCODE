//
//  ZenArtifactTurnGroupTests.swift
//  ZenAppSessionTests
//
//  The grouping of the transcript's file artifacts for the artifacts
//  sidebar.
//

import Foundation
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

@Suite
struct ZenArtifactTurnGroupTests {
    private static func artifact(_ path: String) -> FileChangeArtifact {
        FileChangeArtifact(absolutePath: "/p/\(path)", displayPath: path, status: .modified, additions: 1)
    }

    private static func artifacts(
        _ id: String,
        number: UInt64,
        paths: [String],
        agentID: String? = nil,
        isSealed: Bool = false
    ) -> ZenTranscriptItem {
        ZenTranscriptItem(
            id: id,
            turnID: 1,
            content: .fileArtifacts(
                SessionFileArtifactHistory.Turn(number: number, artifacts: paths.map(artifact)),
                agentID: agentID,
                isSealed: isSealed
            )
        )
    }

    @Test("An empty transcript, or one without artifacts, has no groups")
    func noArtifactsNoGroups() {
        #expect(ZenArtifactTurnGroup.groups(in: []).isEmpty)
        let transcript = [
            ZenTranscriptItem(id: "1-log-1", turnID: 1, startsTurn: true,
                              content: .userPrompt(text: "Hi", attachments: [], origin: .app)),
            ZenTranscriptItem(id: "1-log-2", turnID: 1, content: .assistantText("Hello", isStreaming: false)),
            ZenTranscriptItem(id: "local-a", turnID: nil, content: .commandLine("/artifacts")),
            ZenTranscriptItem(id: "1-log-3", turnID: 1, content: .notice(.fileArtifacts([
                SessionFileArtifactHistory.Turn(number: 1, artifacts: [Self.artifact("a.swift")]),
            ]))),
        ]
        #expect(ZenArtifactTurnGroup.groups(in: transcript).isEmpty)
    }

    @Test("Groups follow the first appearance of each number; live and sealed rows of a number share one group")
    func groupsByNumber() {
        let transcript = [
            ZenTranscriptItem(id: "1-log-1", turnID: 1, startsTurn: true,
                              content: .userPrompt(text: "Hi", attachments: [], origin: .app)),
            Self.artifacts("1-log-2", number: 2, paths: ["a.swift"]),
            ZenTranscriptItem(id: "1-log-3", turnID: 1, content: .assistantText("Done", isStreaming: false)),
            Self.artifacts("1-log-4", number: 1, paths: ["b.swift", "c.swift"], agentID: "agent_1"),
            Self.artifacts("1-log-5", number: 2, paths: ["d.swift"], isSealed: true),
        ]
        let groups = ZenArtifactTurnGroup.groups(in: transcript)
        #expect(groups.map(\.number) == [2, 1])
        #expect(groups.map(\.id) == ["1-log-2-turn-2", "1-log-4-turn-1"])

        let second = groups[0]
        #expect(second.entries.map(\.id) == ["1-log-2-0", "1-log-5-0"])
        #expect(second.entries.map(\.artifact.displayPath) == ["a.swift", "d.swift"])
        #expect(second.entries.map(\.agentID) == [nil, nil])

        let first = groups[1]
        #expect(first.entries.map(\.id) == ["1-log-4-0", "1-log-4-1"])
        #expect(first.entries.map(\.artifact.displayPath) == ["b.swift", "c.swift"])
        #expect(first.entries.map(\.agentID) == ["agent_1", "agent_1"])
    }

    @Test("Each entry keeps the agent of its row, in transcript order")
    func entriesKeepTheirAgent() {
        let transcript = [
            Self.artifacts("2-log-1", number: 1, paths: ["a.swift"], agentID: "agent_1"),
            Self.artifacts("2-log-2", number: 1, paths: ["b.swift"]),
            Self.artifacts("2-log-3", number: 1, paths: ["a.swift"], agentID: "agent_2", isSealed: true),
        ]
        let groups = ZenArtifactTurnGroup.groups(in: transcript)
        #expect(groups.count == 1)
        #expect(groups.first?.id == "2-log-1-turn-1")
        #expect(groups.first?.entries == [
            ZenArtifactEntry(id: "2-log-1-0", artifact: Self.artifact("a.swift"), agentID: "agent_1"),
            ZenArtifactEntry(id: "2-log-2-0", artifact: Self.artifact("b.swift"), agentID: nil),
            ZenArtifactEntry(id: "2-log-3-0", artifact: Self.artifact("a.swift"), agentID: "agent_2"),
        ])
    }

    @Test("A row without artifacts adds no entry and starts no group")
    func emptyRowsAreIgnored() {
        let transcript = [
            Self.artifacts("1-log-1", number: 1, paths: []),
            Self.artifacts("1-log-2", number: 2, paths: []),
            Self.artifacts("1-log-3", number: 1, paths: ["a.swift"]),
        ]
        let groups = ZenArtifactTurnGroup.groups(in: transcript)
        #expect(groups.map(\.id) == ["1-log-3-turn-1"])
        #expect(groups.first?.entries.map(\.id) == ["1-log-3-0"])
    }
}
