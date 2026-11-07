//
//  SharedChatMentionCatalogTests.swift
//  ZenCODE
//

import Testing
@testable import ZenCODECore

/// Covers the actor-isolated mention catalogue: readable handles derived from
/// display names, unique disambiguation, non-recycled aliases, session reset,
/// sanitisation and stable routing by participant id.
@Suite
struct SharedChatMentionCatalogTests {
    @Test
    func departedParticipantsStopResolvingWhileTheirAliasesStayReserved() async {
        let catalog = SharedChatMentionCatalog()
        _ = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "first", name: "Developer", kind: .agent),
        ])
        #expect(await catalog.participantID(forHandle: "developer") == "first")

        _ = await catalog.handleMap(for: [])
        #expect(await catalog.participantID(forHandle: "developer") == nil)

        let replacement = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "second", name: "Developer", kind: .agent),
        ])
        #expect(replacement == ["developer-2": "second"])
        #expect(await catalog.participantID(forHandle: "developer") == nil)
        #expect(await catalog.participantID(forHandle: "developer-2") == "second")
    }

    @Test
    func hostileNamesAreSanitizedToSafeSlugs() async {
        let map = await SharedChatMentionCatalog().handleMap(for: [
            AgentSharedChat.Participant(id: "x-1", name: "Evil\u{1B}[31m Name\r\u{202E}", kind: .agent),
            AgentSharedChat.Participant(id: "x-2", name: "  Multiple   Spaces  ", kind: .agent),
            AgentSharedChat.Participant(id: "x-3", name: "UPPER_Case", kind: .agent),
        ])
        #expect(map["evil31m-name"] == "x-1")
        #expect(map["multiple-spaces"] == "x-2")
        #expect(map["upper-case"] == "x-3")
    }

    @Test
    func blankUnicodeBidiOrPunctuationNamesFallBackToAgentNeverTheId() async {
        let catalog = SharedChatMentionCatalog()
        let map = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "abc-123", name: "", kind: .agent),
            AgentSharedChat.Participant(id: "---", name: "   ", kind: .agent),
            AgentSharedChat.Participant(id: "uuid-CAFE-1", name: "日本語", kind: .agent),
            AgentSharedChat.Participant(id: "uuid-CAFE-2", name: "\u{202E}\u{202C}\u{061C}", kind: .agent),
            AgentSharedChat.Participant(id: "uuid-CAFE-3", name: "!!!???", kind: .agent),
        ])
        // A name that yields no ASCII slug falls back to the stable readable
        // handle "agent"; the participant id is never used as a fallback, so no
        // internal identifier or UUID is exposed as a visible handle.
        #expect(map["agent"] == "abc-123")
        #expect(map["agent-2"] == "---")
        #expect(map["agent-3"] == "uuid-CAFE-1")
        #expect(map["agent-4"] == "uuid-CAFE-2")
        #expect(map["agent-5"] == "uuid-CAFE-3")
        #expect(map["abc-123"] == nil)
        #expect(map["uuid-CAFE-1"] == nil)
        #expect(map.keys.allSatisfy { $0 == "agent" || $0.hasPrefix("agent-") })
    }

    @Test
    func allAndCoordinatorAreSessionReservedAndSurviveReset() async {
        let catalog = SharedChatMentionCatalog()
        let map = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "all-agent", name: "all", kind: .agent),
            AgentSharedChat.Participant(id: "coord-agent", name: "Coordinator", kind: .agent),
            AgentSharedChat.Participant(id: "plain", name: "Plain Worker", kind: .agent),
        ])
        // The broadcast spellings are never assigned to an agent: the collision
        // is disambiguated with the -2 suffix and remains routable.
        #expect(map["all"] == nil)
        #expect(map["coordinator"] == nil)
        #expect(map["all-2"] == "all-agent")
        #expect(map["coordinator-2"] == "coord-agent")
        #expect(map["plain-worker"] == "plain")

        // A session reset releases ordinary aliases but keeps the reserved
        // broadcast destinations, so a future agent can never capture them.
        await catalog.reset()
        let afterReset = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "all-agent-2", name: "All", kind: .agent),
            AgentSharedChat.Participant(id: "coord-agent-2", name: "coordinator", kind: .agent),
            AgentSharedChat.Participant(id: "plain-2", name: "Plain Worker", kind: .agent),
        ])
        #expect(afterReset["all"] == nil)
        #expect(afterReset["coordinator"] == nil)
        #expect(afterReset["all-2"] == "all-agent-2")
        #expect(afterReset["coordinator-2"] == "coord-agent-2")
        #expect(afterReset["plain-worker"] == "plain-2")
    }

    @Test
    func handleMapOnlyCoversActiveAgentParticipants() async {
        let catalog = SharedChatMentionCatalog()
        let map = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "active-1", name: "Active One", kind: .agent),
            AgentSharedChat.Participant(id: "inactive-1", name: "Inactive One", kind: .agent, isActive: false),
            AgentSharedChat.Participant(id: "coord-1", name: "The Coordinator", kind: .coordinator),
            AgentSharedChat.Participant(id: "op-1", name: "Operator", kind: .operator),
        ])
        #expect(map == ["active-one": "active-1"])
        // An inactive agent that later becomes active keeps a handle, but the
        // retired roster never leaked one while it was inactive.
        let reactivated = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "inactive-1", name: "Inactive One", kind: .agent, isActive: true),
        ])
        #expect(reactivated["inactive-one"] == "inactive-1")
    }

    @Test
    func reservedHandlesAndSuffixesStayWithinTheLengthBound() {
        // Reserved broadcast spellings must survive even when an agent name
        // collides at the exact handle limit.
        let longBase = String(repeating: "a", count: SharedChatMentionCatalog.maximumHandleLength)
        var reserved: Set<String> = SharedChatMentionCatalog.sessionReservedHandles
        reserved.insert(longBase)
        let collided = SharedChatMentionCatalog.uniqueHandle(base: longBase, reserved: reserved)
        #expect(collided.hasSuffix("-2"))
        #expect(collided.count == SharedChatMentionCatalog.maximumHandleLength)
        #expect(!collided.contains("all"))
        #expect(!collided.contains("coordinator"))
    }
}
