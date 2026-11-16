//
//  ChatSessionHostTests+Sessions.swift
//  ZenCODE
//
//  Host tests for saved sessions, slot retirement, slot bindings and hosted
//  session operations, with the channel hooks that record the session steps.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

extension ChatSessionHostTests {
    /// Runs one turn on `incarnation` through its controller, as a channel does.
    private static func runTurn(_ prompt: String, on incarnation: ChatSessionIncarnation) async throws {
        let controller = incarnation.controller
        _ = try await controller.runTurn(
            ChatTurnRequest(
                prompt: prompt,
                sessionConfiguration: await controller.currentSessionConfiguration(responseLanguageSection: nil)
            )
        )
    }

    // MARK: - Saved sessions

    @Test
    nonisolated func loadSavedSessionKeepsTheOldIncarnationUntilTheSwitchAndTheNewOneAfterIt() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let slot = try host.openSlot(environment.descriptor())
            let original = try await host.newSession(in: slot, sessionID: "original")
            try await original.controller.createSessionWithSelectedSkills(discoverExternalTools: false)
            try await Self.runTurn("Remember me", on: original)
            _ = await original.controller.saveSession(named: "kept", contextWindow: nil)
            #expect(try TerminalSessionStore.savedSessions(for: environment.workspace).map(\.name) == ["kept"])

            // An unknown name changes nothing: the slot keeps its incarnation.
            await #expect(throws: ChatSessionHostError.savedSessionNotFound("missing")) {
                try await host.loadSavedSession(in: slot, name: "missing")
            }
            #expect(host.incarnation(in: slot)?.epoch == original.epoch)
            #expect(original.controller.sessionID == "original")

            // A load is a new incarnation of the saved session, whose reducer
            // keeps the host's epoch through the switch and holds the
            // restored log.
            let outcome = try await host.loadSavedSession(in: slot, name: "kept")
            let loaded = try #require(host.incarnation(in: slot))
            #expect(loaded.epoch > original.epoch)
            #expect(loaded.sessionID == "original")
            #expect(loaded.controller !== original.controller)
            #expect(loaded.controller.sessionID == "original")
            #expect(loaded.controller.savedSessionState.savedSessionName == "kept")
            #expect(outcome.restoredSession?.name == "kept")
            #expect(loaded.reducer?.snapshot.epoch == loaded.epoch)
            #expect(loaded.reducer?.snapshot.sessionID == "original")
            #expect(loaded.reducer?.snapshot.savedSession.savedSessionName == "kept")
            #expect(loaded.reducer?.snapshot.transcript.contains { entry in
                if case .userPrompt(let text, _, _) = entry.kind {
                    return text == "Remember me"
                }
                return false
            } == true)

            // A load that fails after the switch leaves the new incarnation,
            // as the controller stays on the session it switched to.
            await environment.backend.setPreloadFails(true)
            let failed = await capturedError {
                try await host.loadSavedSession(in: slot, name: "kept")
            }
            #expect(failed != nil)
            let afterFailure = try #require(host.incarnation(in: slot))
            #expect(afterFailure.epoch > loaded.epoch)
            #expect(afterFailure.controller !== loaded.controller)
            #expect(afterFailure.controller.sessionID == "original")
            #expect(afterFailure.reducer?.snapshot.epoch == afterFailure.epoch)
            await environment.backend.setPreloadFails(false)

            // A busy session is not replaced by a load either.
            let reservation = try host.reservePrompt(in: slot)
            await #expect(throws: ChatSessionHostError.sessionBusy) {
                try await host.loadSavedSession(in: slot, name: "kept")
            }
            #expect(host.incarnation(in: slot)?.epoch == afterFailure.epoch)
            #expect(host.releasePrompt(reservation))
            await host.shutdown()
        }
    }

    // MARK: - Retirement

    /// A slot retired for its close refuses every new reservation, a turn of
    /// its Telegram channel included, and keeps what was reserved before, its
    /// incarnation, and its controller fenced; closing it forgets the
    /// retirement. An announced shutdown refuses every reservation on every
    /// slot before the shutdown itself.
    @Test
    nonisolated func aRetiredSlotAndAnAnnouncedShutdownRefuseEveryNewReservation() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let retired = try host.openSlot(environment.descriptor(identity: .window("retired")))
            let other = try host.openSlot(environment.descriptor(identity: .window("other")))
            let incarnation = try await host.newSession(in: retired, sessionID: "retired-session")
            _ = try await host.newSession(in: other, sessionID: "other-session")
            let held = try host.reservePrompt(in: retired)
            let turnToken = incarnation.controller.beginTurnToken()

            host.retireIncarnation(in: retired, controller: incarnation.controller)
            #expect(incarnation.controller.isCurrentTurn(turnToken, sessionID: "retired-session") == false)
            #expect(host.holdsPrompt(held))
            #expect(host.releasePrompt(held))
            #expect(throws: ChatSessionHostError.noSession) { try host.reservePrompt(in: retired) }
            #expect(throws: ChatSessionHostError.noSession) { try host.reserveReconfiguration(in: retired) }
            await #expect(throws: ChatSessionHostError.noSession) {
                try await host.newSession(in: retired, sessionID: "replacement")
            }
            #expect(host.incarnation(in: retired)?.epoch == incarnation.epoch)
            _ = try #require(host.telegramChannelCreatingIfNeeded(in: retired))
            host.slots[retired]?.setActiveChannel(.telegram)
            await #expect(throws: ChatSessionHostError.noSession) {
                try await host.runTelegramTurn(in: retired, prompt: "after the close began")
            }
            // The other slot is untouched.
            let otherReservation = try host.reservePrompt(in: other)
            #expect(host.releasePrompt(otherReservation))
            await host.closeSlot(retired)
            #expect(host.retirement.isRetired(retired) == false)

            host.beginShutdown()
            #expect(throws: ChatSessionHostError.shutDown) { try host.reservePrompt(in: other) }
            #expect(throws: ChatSessionHostError.shutDown) { try host.reserveReconfiguration(in: other) }
            #expect(host.incarnation(in: other) != nil)
            await host.shutdown()
        }
    }

    // MARK: - Slot bindings

    @Test
    nonisolated func aSlotKeepsItsBindingsAndEverySessionStartsFromTheLaunchSelection() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let presenter = RecordingChatPresenter()
            let interactionHost = ScriptedChatInteractionHost(capabilities: [], decisions: [])
            let hooks = HostTestHooks(host: host)
            let registry = ChatCommandRegistry(
                shared: ChatCommandRegistry.sharedDescriptors,
                channel: [(after: "/help", descriptors: [
                    ChatCommandDescriptor(command: "/window", summary: "window", help: "/window", scope: .channel),
                ])]
            )
            // The slot opens with its first session, without suspending.
            let first = try host.openSlot(
                ChatSlotDescriptor(
                    identity: .terminal,
                    workingDirectory: environment.workspace,
                    presenter: presenter,
                    interaction: .host(interactionHost),
                    authorizer: ChatToolConsentAuthorizer(host: interactionHost),
                    channelHooks: hooks,
                    commandRegistry: registry,
                    publishesState: false
                ),
                sessionID: "first"
            )
            let slot = first.slotID
            #expect(first.epoch == 1)
            #expect(host.incarnation(in: slot)?.epoch == first.epoch)
            #expect(first.controller.sessionID == "first")
            #expect(first.reducer == nil)
            let launchSelection = ChatSessionController.initialSelection(for: host.environment)
            #expect(first.controller.selection == launchSelection)

            // The session changes its selection; the next one starts over,
            // with the same bindings.
            first.controller.selection.modelIDOverride = "other-model"
            first.controller.selection.toolKeys = ["local"]
            first.controller.selection.skillNames = ["skill"]
            let second = try await host.newSession(in: slot, sessionID: "second")
            #expect(second.controller !== first.controller)
            #expect(second.epoch > first.epoch)
            #expect(second.controller.selection == launchSelection)
            #expect(first.controller.selection.modelIDOverride == "other-model")
            for incarnation in [first, second] {
                let controller = incarnation.controller
                // The slot's presenter and host, which forward to the
                // channel's own while the channel drives the slot.
                let slotPresenter = try #require(controller.presenter as? ChatSlotPresenter)
                #expect(slotPresenter.activePresenter as? RecordingChatPresenter === presenter)
                #expect(controller.host is ChatSlotInteractionHost)
                #expect(controller.host.capabilities == interactionHost.capabilities)
                #expect(controller.channelHooks === hooks)
                #expect(controller.commandRegistry.descriptor(forLine: "/window")?.scope == .channel)
                #expect(controller.hostBinding?.slotID == slot)
                #expect(controller.hostBinding?.host === host)
            }
            await host.shutdown()
        }
    }

    // MARK: - Hosted session operations

    @Test
    nonisolated func aHostedControllerReplacesItselfThroughTheHostAndIsFencedAfterwards() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let presenter = RecordingChatPresenter()
            let interactionHost = ScriptedChatInteractionHost(capabilities: [], decisions: [])
            let hooks = HostTestHooks(host: host)
            let first = try host.openSlot(
                ChatSlotDescriptor(
                    identity: .terminal,
                    workingDirectory: environment.workspace,
                    presenter: presenter,
                    interaction: .host(interactionHost),
                    authorizer: ChatToolConsentAuthorizer(host: interactionHost),
                    channelHooks: hooks,
                    publishesState: false,
                    sessionIDPrefix: "minted-by-slot"
                ),
                sessionID: "first"
            )
            let slot = first.slotID
            try await first.controller.createSessionWithSelectedSkills(discoverExternalTools: false)
            try await Self.runTurn("Before the new session", on: first)
            first.controller.selection.toolKeys = ["local"]
            let firstTurnToken = first.controller.beginTurnToken()

            // `/sessions new` on the hosted controller: the channel's steps
            // run around the switch, the next controller starts from the
            // launch selection with its runtime session created under an id
            // of the slot's prefix, the previous one is fenced and its
            // runtime session discarded.
            let outcome = await first.controller.handleCommandLine("/sessions new", context: [])
            #expect(outcome == ChatCommandOutcome(notices: [.sessionStarted]))
            let second = try #require(host.incarnation(in: slot))
            #expect(second.controller !== first.controller)
            #expect(second.sessionID.hasPrefix("minted-by-slot-"))
            #expect(UUID(uuidString: String(second.sessionID.dropFirst("minted-by-slot-".count))) != nil)
            #expect(second.controller.sessionID == second.sessionID)
            #expect(second.controller.selection == ChatSessionController.initialSelection(for: host.environment))
            #expect(second.controller.history.isEmpty)
            #expect(hooks.steps == [
                "newSessionWillStart@\(first.epoch)",
                "newSessionDidStart@\(second.epoch)",
            ])
            #expect(first.controller.isCurrentTurn(firstTurnToken, sessionID: "first") == false)
            #expect(await host.runner.snapshotSession(id: second.sessionID) != nil)
            #expect(await host.runner.snapshotSession(id: "first") == nil)

            // A replaced controller replaces nothing more.
            await #expect(throws: ChatSessionHostError.noSession) {
                try await first.controller.startNewSession(newSessionID: "late")
            }
            #expect(host.incarnation(in: slot)?.epoch == second.epoch)

            // A saved-session load on the hosted controller is a new
            // incarnation too: the first hook runs before the switch on the
            // controller being replaced, the others after it on the new one.
            try await Self.runTurn("Save me", on: second)
            _ = await second.controller.saveSession(named: "kept", contextWindow: nil)
            let saved = try #require(TerminalSessionStore.savedSessions(for: environment.workspace).first)
            hooks.steps = []
            let loadOutcome = try await second.controller.loadSavedSession(saved)
            let third = try #require(host.incarnation(in: slot))
            #expect(third.controller !== second.controller)
            #expect(third.epoch > second.epoch)
            #expect(third.controller.savedSessionState.savedSessionName == "kept")
            #expect(loadOutcome.restoredSession?.name == "kept")
            #expect(hooks.steps == [
                "savedSessionWillLoad@\(second.epoch)",
                "savedSessionWillRestore@\(third.epoch)",
                "savedSessionDidRestore@\(third.epoch)",
            ])
            await #expect(throws: ChatSessionHostError.noSession) {
                try await second.controller.loadSavedSession(saved)
            }
            #expect(host.incarnation(in: slot)?.epoch == third.epoch)
            await host.shutdown()
        }
    }
}

/// Channel hooks that record the session steps the controller asks of the
/// channel, each with the epoch of the incarnation the host runs at that
/// moment: a test reads on which side of the switch a step ran.
@ChatSessionActor
private final class HostTestHooks: ChatSessionChannelHooks {
    private weak var host: ChatSessionHost?
    var steps: [String] = []

    init(host: ChatSessionHost) {
        self.host = host
    }

    /// Records `step` with the epoch of the host's one slot.
    private func record(_ step: String) {
        let epoch = host?.slotIDs.first.flatMap { host?.incarnation(in: $0)?.epoch }
        steps.append("\(step)@\(epoch.map(String.init) ?? "-")")
    }

    func incarnationDidChange(reason: ChatIncarnationChange) async {
        switch reason {
        case .newSessionWillStart:
            record("newSessionWillStart")
        case .newSessionDidStart:
            record("newSessionDidStart")
        case .savedSessionWillLoad:
            record("savedSessionWillLoad")
        case .savedSessionWillRestore:
            record("savedSessionWillRestore")
        case .savedSessionDidRestore:
            record("savedSessionDidRestore")
        case .sessionDidCompact:
            record("sessionDidCompact")
        }
    }
}
