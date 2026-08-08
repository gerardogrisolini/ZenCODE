//
//  TerminalSharedChatSafetyTests.swift
//  ZenCODE
//

import Testing
@testable import ZenCODECore

@Suite
struct TerminalSharedChatSafetyTests {
    @Test
    func sharedChatCardRendersControlsBidiAndUnicodeSeparatorsAsInertMarkers() {
        let hostile = "text\u{001B}[31m\u{202E}\u{061C}\u{200D}\u{2028}row\u{2029}paragraph\u{0085}"
        let card = TerminalChat.renderSharedChatCard(
            route: "operator\u{202E} → coordinator\u{2029}",
            text: hostile,
            terminalColumns: 120,
            usesColor: false
        )

        #expect(card.contains("␛[31m"))
        #expect(card.contains("<U+202E>"))
        #expect(card.contains("<U+061C>"))
        #expect(card.contains("<U+200D>"))
        #expect(card.contains("<LS>"))
        #expect(card.contains("<PS>"))
        #expect(card.contains("<C1-85>"))
        #expect(!card.unicodeScalars.contains { scalar in
            scalar.value == 0x1B
                || scalar.value == 0x2028
                || scalar.value == 0x2029
                || scalar.properties.isBidiControl
                || scalar.properties.isJoinControl
                || scalar.properties.generalCategory == .format
        })
    }

    @Test
    func reservedMentionsRemainUsableWhileTheirTextIsTerminalSanitized() {
        #expect(
            TerminalChat.sharedChatMentionRoute(from: "@all report\u{2028}status")
                == TerminalChat.SharedChatMentionRoute(
                    destination: .all,
                    text: "report<LS>status"
                )
        )
        #expect(
            TerminalChat.sharedChatMentionRoute(from: "@coordinator check\u{202E}identity")
                == TerminalChat.SharedChatMentionRoute(
                    destination: .coordinator,
                    text: "check<U+202E>identity"
                )
        )
    }

    @Test
    func unicodeAndBidiOnlyNamesProduceAsciiAgentFallbackSuggestions() async {
        let catalog = SharedChatMentionCatalog()
        let participants = [
            AgentSharedChat.Participant(id: "uuid-1", name: "日本語\u{202E}\u{061C}", kind: .agent),
            AgentSharedChat.Participant(id: "uuid-2", name: "\u{202E}\u{202C}\u{200D}", kind: .agent),
            AgentSharedChat.Participant(id: "uuid-3", name: "\u{061C}\u{200D}", kind: .agent),
        ]
        let handleMap = await catalog.handleMap(for: participants)
        let suggestions = TerminalChat.sharedChatMentionSuggestions(
            for: participants,
            handleMap: handleMap
        )
        let commands = suggestions.map(\.command)

        #expect(commands.contains("@agent "))
        #expect(commands.contains("@agent-2 "))
        #expect(commands.contains("@agent-3 "))
        // Every offered handle is pure ASCII: no bidi, no control, no UUID.
        #expect(commands.allSatisfy { command in
            command.unicodeScalars.allSatisfy { $0.value < 0x80 }
        })
        #expect(commands.allSatisfy { !$0.contains("uuid") })
    }

    @Test
    func reservedBroadcastHandlesAreNeverSuggestedAsDirectAgentMentions() async {
        let catalog = SharedChatMentionCatalog()
        let participants = [
            AgentSharedChat.Participant(id: "all-id", name: "all", kind: .agent),
            AgentSharedChat.Participant(id: "coord-id", name: "Coordinator", kind: .agent),
            AgentSharedChat.Participant(id: "inactive-id", name: "Inactive", kind: .agent, isActive: false),
        ]
        let handleMap = await catalog.handleMap(for: participants)
        let suggestions = TerminalChat.sharedChatMentionSuggestions(
            for: participants,
            handleMap: handleMap
        )
        let commands = suggestions.map(\.command)

        // Exactly the two reserved mentions (once each) plus the two colliding
        // agents under -2 handles; the inactive agent is not suggested at all.
        #expect(commands.count == 4)
        #expect(Array(commands.prefix(2)) == ["@coordinator ", "@all "])
        #expect(commands.contains("@all-2 "))
        #expect(commands.contains("@coordinator-2 "))
        #expect(commands.filter { $0 == "@all " }.count == 1)
        #expect(commands.filter { $0 == "@coordinator " }.count == 1)
        #expect(!commands.contains("@inactive "))
    }
}
