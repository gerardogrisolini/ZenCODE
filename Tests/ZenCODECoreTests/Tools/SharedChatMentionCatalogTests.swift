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
    func readableHandlesAreDerivedFromDisplayName() async {
        let catalog = SharedChatMentionCatalog()
        let map = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "a-1", name: "Developer", kind: .agent),
            AgentSharedChat.Participant(id: "b-2", name: "Code Reviewer", kind: .agent),
            AgentSharedChat.Participant(id: "c-3", name: "Q.A. Tester", kind: .agent),
        ])
        #expect(map["developer"] == "a-1")
        #expect(map["code-reviewer"] == "b-2")
        #expect(map["qa-tester"] == "c-3")
    }

    @Test
    func duplicateNamesGetUniqueNumericSuffixes() async {
        let catalog = SharedChatMentionCatalog()
        let map = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "a-1", name: "Worker", kind: .agent),
            AgentSharedChat.Participant(id: "a-2", name: "Worker", kind: .agent),
            AgentSharedChat.Participant(id: "a-3", name: "Worker", kind: .agent),
        ])
        #expect(map["worker"] == "a-1")
        #expect(map["worker-2"] == "a-2")
        #expect(map["worker-3"] == "a-3")
    }

    @Test
    func numericSuffixKeepsTheDashWhenTheBaseIsTruncated() {
        // A base at the exact handle limit collides with itself; the suffixed
        // candidate must keep its dash separator even after the base is trimmed
        // to fit the bound.
        let longBase = String(repeating: "a", count: SharedChatMentionCatalog.maximumHandleLength)
        let first = SharedChatMentionCatalog.uniqueHandle(
            base: longBase,
            reserved: []
        )
        #expect(first == longBase)
        let second = SharedChatMentionCatalog.uniqueHandle(
            base: longBase,
            reserved: [longBase]
        )
        #expect(second.hasSuffix("-2"))
        #expect(second.count == SharedChatMentionCatalog.maximumHandleLength)
        #expect(second != longBase)
    }

    @Test
    func aliasesAreNeverRecycledWithinASession() async {
        let catalog = SharedChatMentionCatalog()
        _ = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "first", name: "Agent", kind: .agent),
        ])
        // The first participant leaves; a new one with the same name must not
        // reuse the retired alias.
        let map = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "second", name: "Agent", kind: .agent),
        ])
        // The retired alias stays reserved, so the new participant is
        // disambiguated even though the first one left the roster snapshot.
        #expect(map["agent-2"] == "second")
        #expect(map["agent"] == nil)
    }

    @Test
    func returningParticipantKeepsItsHandle() async {
        let catalog = SharedChatMentionCatalog()
        let first = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "stable", name: "Planner", kind: .agent),
        ])
        #expect(first["planner"] == "stable")
        // The same participant re-registered keeps its handle.
        let second = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "stable", name: "Planner", kind: .agent),
        ])
        #expect(second["planner"] == "stable")
    }

    @Test
    func sessionResetClearsTheAliasSpace() async {
        let catalog = SharedChatMentionCatalog()
        _ = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "first", name: "Agent", kind: .agent),
        ])
        await catalog.reset()
        // After reset the alias is available again.
        let map = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "second", name: "Agent", kind: .agent),
        ])
        #expect(map["agent"] == "second")
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

    @Test
    func routingAlwaysResolvesByStableId() async {
        let catalog = SharedChatMentionCatalog()
        let map = await catalog.handleMap(for: [
            AgentSharedChat.Participant(id: "uuid-stable", name: "Worker", kind: .agent),
        ])
        let handle = map.first(where: { $0.value == "uuid-stable" })?.key
        #expect(handle == "worker")
        let resolved = await catalog.participantID(forHandle: handle ?? "")
        #expect(resolved == "uuid-stable")
        // An unknown handle resolves to nil, never to a wrong agent.
        let unknown = await catalog.participantID(forHandle: "nonexistent")
        #expect(unknown == nil)
    }
}
