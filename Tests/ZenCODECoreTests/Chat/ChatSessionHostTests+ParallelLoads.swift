//
//  ChatSessionHostTests+ParallelLoads.swift
//  ZenCODE
//
//  Saved-session identity reservations across concurrent slot loads.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

extension ChatSessionHostTests {
    @Test("Concurrent loads under different names cannot adopt the same saved session ID")
    nonisolated func concurrentLoadsOfSameSessionID() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let sourceSlot = try host.openSlot(environment.descriptor(identity: .window("source")))
            let source = try await host.newSession(in: sourceSlot, sessionID: "shared-snapshot-id")
            try await source.controller.createSessionWithSelectedSkills(discoverExternalTools: false)
            _ = try await source.controller.runTurn(ChatTurnRequest(
                prompt: "Saved content",
                sessionConfiguration: await source.controller.currentSessionConfiguration(responseLanguageSection: nil)
            ))
            _ = await source.controller.saveSession(named: "first-name", contextWindow: nil)
            _ = await source.controller.saveSession(named: "second-name", contextWindow: nil)
            let snapshots = try TerminalSessionStore.savedSessions(for: environment.workspace)
            let firstSaved = try #require(snapshots.first { $0.name == "first-name" })
            let secondSaved = try #require(snapshots.first { $0.name == "second-name" })
            #expect(firstSaved.sessionID == secondSaved.sessionID)
            await host.closeSlot(sourceSlot)

            let firstSlot = try host.openSlot(environment.descriptor(identity: .window("first")))
            let secondSlot = try host.openSlot(environment.descriptor(identity: .window("second")))
            let first = try await host.newSession(in: firstSlot, sessionID: "first-original")
            let second = try await host.newSession(in: secondSlot, sessionID: "second-original")
            let firstHooks = ParallelLoadHooks(hold: true)
            let secondHooks = ParallelLoadHooks(hold: false)
            first.controller.channelHooks = firstHooks
            second.controller.channelHooks = secondHooks

            let loading = Task { @ChatSessionActor in
                try await host.loadSavedSession(in: firstSlot, name: "first-name")
            }
            let deadline = ContinuousClock.now + .seconds(30)
            while !firstHooks.reached && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(5))
            }
            #expect(firstHooks.reached)
            var rejected = false
            do {
                _ = try await host.loadSavedSession(in: secondSlot, name: "second-name")
            } catch {
                rejected = true
                #expect(error.localizedDescription.contains("already open elsewhere"))
            }
            #expect(rejected)
            #expect(!secondHooks.reached)
            #expect(host.incarnation(in: secondSlot)?.epoch == second.epoch)
            #expect(host.incarnation(in: secondSlot)?.sessionID == "second-original")
            firstHooks.release = true
            _ = try await loading.value
            #expect(host.incarnation(in: firstSlot)?.sessionID == firstSaved.sessionID)
            #expect(host.incarnation(in: secondSlot)?.sessionID == "second-original")
            await host.shutdown()
        }
    }
}

@ChatSessionActor
private final class ParallelLoadHooks: ChatSessionChannelHooks {
    let hold: Bool
    var reached = false
    var release = false

    init(hold: Bool) {
        self.hold = hold
    }

    func incarnationDidChange(reason: ChatIncarnationChange) async {
        guard case .savedSessionWillLoad = reason else { return }
        reached = true
        guard hold else { return }
        let deadline = ContinuousClock.now + .seconds(30)
        while !release && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !release { Issue.record("The parallel load hook was never released") }
    }
}
