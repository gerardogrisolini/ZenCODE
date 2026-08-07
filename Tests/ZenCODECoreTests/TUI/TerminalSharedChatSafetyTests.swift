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
}
