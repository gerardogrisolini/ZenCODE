//
//  ACPCloseQuiescenceTests+Telegram.swift
//  ZenCODE
//
//  Tests that `session/close` and `shutdown()` shut down the Telegram channel
//  of an ACP session's slot, through a scripted Bot API.
//

import Foundation
import Synchronization
@testable import ZenCODECore
import Testing
import ToolCore

// MARK: - Telegram channel

/// The Telegram channel of an ACP session's slot ends with the slot:
/// `session/close` and a discarded incarnation close the slot, which shuts
/// the channel down, and the bridge's `shutdown()` shuts every one down.
/// Telegram goes through a scripted Bot API.
extension ACPCloseQuiescenceTests {
    /// `session/close` shuts the channel down before it answers; the session
    /// created again with the same id is a new slot, without a link, that
    /// needs `/telegram on` again.
    @Test
    func closeShutsDownTheTelegramChannelBeforeItsReply() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let sessionID = "acp-close-telegram-\(UUID().uuidString)"
            let fixture = try await ACPTelegramBridgeFixture.make(
                root: root,
                sessionIDs: [sessionID],
                transport: ACPTelegramScriptedTransport(botID: ACPTelegramTestSupport.uniqueBotID())
            )
            #expect(await fixture.turnTelegramOn(sessionID: sessionID, id: 1)
                == "Telegram remote control is active.\nLinked chat: Test")
            let channel = try #require(await fixture.telegramChannel(sessionID: sessionID))
            #expect(await channel.isActive)
            #expect(await ACPTelegramTestSupport.waitUntil { await fixture.transport.runningPollCount == 1 })

            await fixture.bridge.handleMessage([
                "jsonrpc": "2.0", "id": 2, "method": "session/close",
                "params": ["sessionId": sessionID],
            ])

            #expect(fixture.wire.response(id: 2)?["result"] == .object([:]))
            #expect(await !channel.isActive)
            #expect(await !channel.readsIngress)
            #expect(await ACPTelegramTestSupport.waitUntil { await fixture.transport.runningPollCount == 0 })

            let sessionConfiguration = AgentCoreSessionConfiguration(
                sessionID: sessionID,
                modelID: "test-model",
                workingDirectory: fixture.workingDirectory,
                systemPrompt: "ACP Telegram test",
                cacheKey: nil,
                history: [],
                allowedToolNames: nil
            )
            try await fixture.bridge.sessionRunner.createSession(configuration: sessionConfiguration)
            await fixture.bridge.installTestSession(sessionConfiguration)
            #expect(await fixture.telegramChannel(sessionID: sessionID) == nil)
            let start = fixture.wire.count
            await fixture.prompt("/telegram", id: 3, sessionID: sessionID)
            #expect(fixture.lastAgentText(from: start) == "Telegram: Configured")
            await fixture.bridge.shutdown()
        }
    }

    /// `shutdown()` shuts down the channel of every session's slot: each
    /// link stops, the reducer each handover created leaves its controller,
    /// and nothing more is written on the closed ACP transport.
    @Test
    func shutdownShutsDownEveryTelegramChannel() async throws {
        try await ACPTelegramTestSupport.withSupportDirectory { root in
            let sessionIDs = (1...2).map { "acp-shutdown-telegram-\($0)-\(UUID().uuidString)" }
            let fixture = try await ACPTelegramBridgeFixture.make(
                root: root,
                sessionIDs: sessionIDs,
                transport: ACPTelegramScriptedTransport(botID: ACPTelegramTestSupport.uniqueBotID())
            )
            var channels: [(channel: TelegramChannel, controller: ChatSessionController)] = []
            for (index, sessionID) in sessionIDs.enumerated() {
                await fixture.turnTelegramOn(sessionID: sessionID, id: index + 1)
                let channel = try #require(await fixture.telegramChannel(sessionID: sessionID))
                let controller = try #require(await channel.controller)
                #expect(await channel.isActive)
                #expect(await channel.drivesSlot)
                #expect(await controller.observers.count == 1)
                channels.append((channel, controller))
            }
            let wireCount = fixture.wire.count

            await fixture.bridge.shutdown()

            for (channel, controller) in channels {
                #expect(await !channel.isActive)
                #expect(await !channel.readsIngress)
                #expect(await controller.observers.isEmpty)
            }
            #expect(await ACPTelegramTestSupport.waitUntil { await fixture.transport.runningPollCount == 0 })
            #expect(fixture.wire.count == wireCount)
        }
    }
}
