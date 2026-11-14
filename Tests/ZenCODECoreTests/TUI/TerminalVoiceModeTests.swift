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
        let commands = TerminalChat.commandRegistry.visibleDescriptors(
            in: TerminalChat.commandContext(
                builderAgentEnabled: false,
                telegramEnabled: false,
                ds4ModelEnabled: false
            )
        ).map(\.command)
        #expect(commands.contains("/voice"))
        #expect(TerminalChat.isKnownSlashCommand("/voice"))
        #expect(TerminalChat.isKnownSlashCommand("/voice on"))
        #expect(TerminalChat.isAvailableDuringGeneration(for: "/voice"))
    }
}
