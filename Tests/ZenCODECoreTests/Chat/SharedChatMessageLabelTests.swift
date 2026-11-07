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
