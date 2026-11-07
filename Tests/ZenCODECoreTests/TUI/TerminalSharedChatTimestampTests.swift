//
//  TerminalSharedChatTimestampTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalSharedChatTimestampTests {
    @Test
    func messageLabelKeepsRecipientsAndPlacesTimeBesideTheSender() {
        let roomID = "timestamp-room"
        let reviewer = AgentSharedChat.Participant(id: "reviewer", name: "Reviewer", kind: .agent)
        let cases = [
            ([AgentSharedChat.coordinatorID(for: roomID)], "Coordinator"),
            (["reviewer", "worker-2"], "All"),
            ([AgentSharedChat.operatorID(for: roomID)], "Operator"),
            ([reviewer.id], "Reviewer"),
            (["unknown-agent"], "Agent"),
        ]
        for (recipientIDs, recipientName) in cases {
            let message = AgentSharedChat.Message(
                roomID: roomID,
                sender: AgentSharedChat.Participant(id: "worker", name: "Worker", kind: .agent),
                recipientIDs: recipientIDs,
                text: "message",
            )
            let label = TerminalChat.sharedChatIncomingCardRoute(for: message, participantMap: [reviewer.id: reviewer])
            #expect(label == "Worker [\(localTime(message.sentAt))] → \(recipientName)")
        }
    }

    @Test(arguments: [80, 40, 20, 7, 1])
    func readerKeepsTheOriginalTimestampAcrossRendersAndRebuilds(width: Int) throws {
        let message = try historicalMessage()
        let expectedAuthor = "Author: Worker [\(localTime(message.sentAt))] → Coordinator"
        var dock = TerminalSharedChatReaderDock()
        dock.replace(entries: [TerminalSharedChatReaderEntry(message: message, participantMap: [:])], unreadCount: 1)
        let firstRows = dock.rows(width: width)

        #expect(firstRows.first == expectedAuthor)
        #expect(firstRows.last == "")
        #expect(firstRows.dropFirst().allSatisfy { TerminalANSIText.visibleWidth($0) <= width })
        #expect(dock.rows(width: width) == firstRows)

        // Production refreshes rebuild entries from the retained Message. They
        // must not substitute the render time for the historical send instant.
        dock.replace(entries: [TerminalSharedChatReaderEntry(message: message, participantMap: [:])], unreadCount: 0)
        #expect(dock.rows(width: width) == firstRows)
    }

    private func localTime(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let components = calendar.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", components.hour ?? -1, components.minute ?? -1, components.second ?? -1)
    }

    private func historicalMessage() throws -> AgentSharedChat.Message {
        // Decode a fixed send time through the existing Codable model rather
        // than introducing a clock override into the shared-chat domain.
        let data = Data(#"""
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "roomID": "timestamp-room",
            "sender": {
                "id": "worker",
                "name": "Worker",
                "kind": "agent",
                "joinedAt": "2000-01-01T00:00:00Z",
                "isActive": true
            },
            "recipientIDs": ["coordinator:timestamp-room"],
            "text": "historical message",
            "sentAt": "2000-01-01T18:05:09Z"
        }
        """#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentSharedChat.Message.self, from: data)
    }
}
