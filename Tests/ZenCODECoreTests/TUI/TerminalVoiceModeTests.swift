//
//  TerminalVoiceModeTests.swift
//  ZenCODECoreTests
//

import Foundation
import Testing
@testable import ZenCODECore

@ChatSessionActor
@Suite("Terminal voice mode")
struct TerminalVoiceModeTests {
    @Test
    func voiceCommandIsKnownAndUsableDuringGeneration() {
        let commands = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        ).map(\.command)
        #expect(commands.contains("/voice"))
        #expect(TerminalChat.isKnownSlashCommand("/voice"))
        #expect(TerminalChat.isKnownSlashCommand("/voice on"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/voice"))
    }
}
