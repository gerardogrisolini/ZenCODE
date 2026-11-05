//
//  SharedChatMessageLabelTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite
struct SharedChatMessageLabelTests {
    /// 2000-01-01T18:05:09Z, the fixed send instant of every message below.
    private static let sentAtISO = "2000-01-01T18:05:09Z"
    private static let sentAtSeconds: TimeInterval = 946_749_909

    // MARK: - timestamp

    @Test(arguments: [
        (0.0, "00:00:00"),
        (7.0, "00:00:07"),
        (32_643.0, "09:04:03"),
        (43_200.0, "12:00:00"),
        (65_109.0, "18:05:09"),
        (86_399.0, "23:59:59"),
    ])
    func timestampUses24HourClockWithZeroPaddedFields(seconds: TimeInterval, expected: String) throws {
        let utc = try #require(TimeZone(secondsFromGMT: 0))
        #expect(SharedChatMessageLabel.timestamp(Date(timeIntervalSince1970: seconds), timeZone: utc) == expected)
    }

    @Test(arguments: [
        (0, "18:05:09"),
        (19_800, "23:35:09"),
        (-18_000, "13:05:09"),
        (36_000, "04:05:09"),
    ])
    func timestampHonorsTheTimeZoneIncludingNonWholeHourAndDayRollover(offset: Int, expected: String) throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: offset))
        let sentAt = Date(timeIntervalSince1970: Self.sentAtSeconds)
        #expect(SharedChatMessageLabel.timestamp(sentAt, timeZone: timeZone) == expected)
    }

    @Test
    func timestampDefaultsToTheLocalTimeZone() {
        let sentAt = Date(timeIntervalSince1970: Self.sentAtSeconds)
        #expect(SharedChatMessageLabel.timestamp(sentAt) == SharedChatMessageLabel.timestamp(sentAt, timeZone: .current))
    }

    // MARK: - route

    @Test
    func routeNamesTheCoordinatorWhenItIsAmongTheRecipients() throws {
        let roomID = "label-room"
        let coordinator = AgentSharedChat.coordinatorID(for: roomID)
        #expect(try label(roomID: roomID, recipientIDs: [coordinator]) == "Worker [18:05:09] → Coordinator")
        // The coordinator wins over the broadcast wording.
        #expect(try label(roomID: roomID, recipientIDs: ["reviewer", coordinator]) == "Worker [18:05:09] → Coordinator")
    }

    @Test
    func routeNamesAllForMoreThanOneRecipient() throws {
        #expect(try label(recipientIDs: ["reviewer", "worker-2"]) == "Worker [18:05:09] → All")
    }

    @Test
    func routeNamesTheOperator() throws {
        let roomID = "label-room"
        let operatorID = AgentSharedChat.operatorID(for: roomID)
        #expect(try label(roomID: roomID, recipientIDs: [operatorID]) == "Worker [18:05:09] → Operator")
        // The operator namespace wins even when a participant carries that id.
        let impostor = AgentSharedChat.Participant(id: operatorID, name: "Impostor", kind: .agent)
        #expect(
            try label(roomID: roomID, recipientIDs: [operatorID], participantMap: [operatorID: impostor])
                == "Worker [18:05:09] → Operator"
        )
    }

    @Test
    func routeNamesTheMappedAgentByDisplayName() throws {
        let reviewer = AgentSharedChat.Participant(id: "reviewer", name: "Reviewer", kind: .agent)
        #expect(
            try label(recipientIDs: [reviewer.id], participantMap: [reviewer.id: reviewer])
                == "Worker [18:05:09] → Reviewer"
        )
        // A blank name falls back to the identifier, like every other card.
        let unnamed = AgentSharedChat.Participant(id: "agent-7", name: "  ", kind: .agent)
        #expect(
            try label(recipientIDs: [unnamed.id], participantMap: [unnamed.id: unnamed])
                == "Worker [18:05:09] → agent-7"
        )
    }

    @Test
    func routeFallsBackToAgentForAnUnknownRecipient() throws {
        let reviewer = AgentSharedChat.Participant(id: "reviewer", name: "Reviewer", kind: .agent)
        #expect(try label(recipientIDs: ["unknown-agent"]) == "Worker [18:05:09] → Agent")
        #expect(
            try label(recipientIDs: ["unknown-agent"], participantMap: [reviewer.id: reviewer])
                == "Worker [18:05:09] → Agent"
        )
        #expect(try label(recipientIDs: []) == "Worker [18:05:09] → Agent")
    }

    @Test
    func routeShowsTheSendTimeInTheRequestedTimeZone() throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: 19_800))
        #expect(
            try label(recipientIDs: ["unknown-agent"], timeZone: timeZone)
                == "Worker [23:35:09] → Agent"
        )
    }

    @Test
    func routeDefaultsToTheLocalTimeZone() throws {
        let message = try makeMessage(recipientIDs: ["unknown-agent"])
        let expectedTime = SharedChatMessageLabel.timestamp(message.sentAt, timeZone: .current)
        #expect(SharedChatMessageLabel.route(for: message) == "Worker [\(expectedTime)] → Agent")
    }

    // MARK: - TerminalChat forwarders

    @Test(arguments: [0, 19_800, -18_000, 36_000])
    func terminalTimestampForwardsToTheSharedLabel(offset: Int) throws {
        let timeZone = try #require(TimeZone(secondsFromGMT: offset))
        for seconds in [0.0, 7.0, 32_643.0, Self.sentAtSeconds, 86_399.0] {
            let sentAt = Date(timeIntervalSince1970: seconds)
            #expect(
                TerminalChat.sharedChatTimestamp(sentAt, timeZone: timeZone)
                    == SharedChatMessageLabel.timestamp(sentAt, timeZone: timeZone)
            )
        }
        let sentAt = Date(timeIntervalSince1970: Self.sentAtSeconds)
        #expect(TerminalChat.sharedChatTimestamp(sentAt) == SharedChatMessageLabel.timestamp(sentAt))
    }

    @Test
    func terminalRouteForwardsToTheSharedLabel() throws {
        let roomID = "label-room"
        let reviewer = AgentSharedChat.Participant(id: "reviewer", name: "Reviewer", kind: .agent)
        let participantMap = [reviewer.id: reviewer]
        let cases: [[String]] = [
            [AgentSharedChat.coordinatorID(for: roomID)],
            ["reviewer", "worker-2"],
            [AgentSharedChat.operatorID(for: roomID)],
            [reviewer.id],
            ["unknown-agent"],
        ]
        for recipientIDs in cases {
            let message = try makeMessage(roomID: roomID, recipientIDs: recipientIDs)
            #expect(
                TerminalChat.sharedChatIncomingCardRoute(for: message, participantMap: participantMap)
                    == SharedChatMessageLabel.route(for: message, participantMap: participantMap)
            )
            #expect(
                TerminalChat.sharedChatIncomingCardRoute(for: message)
                    == SharedChatMessageLabel.route(for: message)
            )
        }
    }

    // MARK: - Helpers

    private func label(
        roomID: String = "label-room",
        recipientIDs: [String],
        participantMap: [String: AgentSharedChat.Participant] = [:],
        timeZone: TimeZone? = nil
    ) throws -> String {
        let message = try makeMessage(roomID: roomID, recipientIDs: recipientIDs)
        let zone = try timeZone ?? #require(TimeZone(secondsFromGMT: 0))
        return SharedChatMessageLabel.route(for: message, participantMap: participantMap, timeZone: zone)
    }

    /// Decodes a message with a fixed send instant through the existing Codable
    /// model rather than introducing a clock override into the shared-chat
    /// domain (`Message.init` stamps `.now`).
    private func makeMessage(
        roomID: String = "label-room",
        recipientIDs: [String]
    ) throws -> AgentSharedChat.Message {
        let payload: [String: Any] = [
            "id": "00000000-0000-0000-0000-000000000001",
            "roomID": roomID,
            "sender": [
                "id": "worker",
                "name": "Worker",
                "kind": "agent",
                "joinedAt": "2000-01-01T00:00:00Z",
                "isActive": true,
            ] as [String: Any],
            "recipientIDs": recipientIDs,
            "text": "message",
            "sentAt": Self.sentAtISO,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AgentSharedChat.Message.self, from: data)
    }
}
