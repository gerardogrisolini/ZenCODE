//
//  TerminalSharedChatTimestampTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct TerminalSharedChatTimestampTests {
    @Test(arguments: [
        (0.0, "00:00:00"),
        (7.0, "00:00:07"),
        (32_643.0, "09:04:03"),
        (65_109.0, "18:05:09"),
        (86_399.0, "23:59:59"),
    ])
    func timestampUses24HourClockWithZeroPaddedSeconds(seconds: TimeInterval, expected: String) throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        #expect(TerminalChat.sharedChatTimestamp(Date(timeIntervalSince1970: seconds), timeZone: utc) == expected)
    }

    @Test
    func timestampHonorsTimeZoneIncludingNonWholeHourOffsets() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 19_800))
        let sentAt = Date(timeIntervalSince1970: 65_109)
        #expect(TerminalChat.sharedChatTimestamp(sentAt, timeZone: timeZone) == "23:35:09")
    }

    @Test
    func timestampDefaultsToTheLocalTimeZone() throws {
        let message = try historicalMessage()
        #expect(TerminalChat.sharedChatTimestamp(message.sentAt) == localTime(message.sentAt))
    }

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

    @Test(arguments: [80, 40, 32, 20])
    @TerminalChatActor
    func statusBarFitsTimestampedAuthorWithinNarrowReaderRows(columns: Int) async throws {
        let message = try historicalMessage()
        let expectedAuthor = "Author: Worker [\(localTime(message.sentAt))] → Coordinator"
        let statusBar = TerminalStatusBar(isEnabled: false)
        await statusBar.configureForTesting(row: 20, columns: columns)
        await statusBar.updateInputPanel(text: "draft", cursorIndex: 5, modeText: "Chat", helpText: "Enter")
        await statusBar.setSharedChatReader(
            entries: [TerminalSharedChatReaderEntry(message: message, participantMap: [:])],
            unreadCount: 1,
            isExpanded: true,
        )
        var state = await statusBar.state
        let sequence = await statusBar.sharedChatReaderRenderSequenceLocked(state: &state)
        let rows = sequence.components(separatedBy: "\u{1B}[2K")
            .dropFirst().map { TerminalANSIText.stripANSI($0) }
        let authorRow = try #require(rows.first { $0.contains("Author:") })
        let contentWidth = columns - 4
        let fittedAuthor = TerminalStatusBar.fit(expectedAuthor, width: contentWidth)

        #expect(rows.count >= 3)
        #expect(rows.allSatisfy { TerminalANSIText.visibleWidth($0) <= columns })
        #expect(authorRow == "│ \(TerminalStatusBar.padded(fittedAuthor, width: contentWidth)) │")
        #expect(await statusBar.sharedChatReaderRenderSequenceLocked(state: &state) == sequence)
        #expect(state.sharedChatReaderDock?.entries.first?.route == String(expectedAuthor.dropFirst("Author: ".count)))
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
