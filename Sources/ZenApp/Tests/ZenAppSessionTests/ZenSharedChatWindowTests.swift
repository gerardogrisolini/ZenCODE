//
//  ZenSharedChatWindowTests.swift
//  ZenAppSessionTests
//
//  The shared chat of a window over a scripted backend and a real room bus:
//  the reader, the hidden coordinator turn, a trigger declined while busy,
//  the claims (acquired while a line starts, not granted, acquired as the
//  window closes, kept while a line without a Core turn ends, on its way
//  across a new session), a trigger of an observation the window left, the
//  live mentions, a new session, the reload of the active session, a stream
//  that ends, and the close.
//

import Foundation
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

/// A test observer of a room: the auto-triggers the Core offers it, in
/// order. It never answers them.
@MainActor
private final class ZenRoomProbe {
    private(set) var triggers: [AgentSharedChatAutoTrigger] = []
    private let runner: AgentCoreSessionRunner
    private let observation: AgentSharedChatCoordinator.Observation
    private var task: Task<Void, Never>?

    private init(runner: AgentCoreSessionRunner, observation: AgentSharedChatCoordinator.Observation) {
        self.runner = runner
        self.observation = observation
    }

    static func attach(to roomID: String, runner: AgentCoreSessionRunner) async -> ZenRoomProbe {
        let probe = ZenRoomProbe(
            runner: runner,
            observation: await runner.attachSharedChatObservation(rootSessionID: roomID)
        )
        let events = probe.observation.events
        probe.task = Task { [weak probe] in
            for await event in events {
                if case let .autoTrigger(trigger) = event {
                    probe?.triggers.append(trigger)
                }
            }
        }
        return probe
    }

    /// Whether a trigger offered so far carries the message `text`.
    func wasOffered(_ text: String) -> Bool {
        triggers.contains { $0.messages.contains { $0.text == text } }
    }

    func detach() async {
        task?.cancel()
        await runner.detachSharedChatObservation(observation)
    }
}

/// The detach a step of the window started, for the test to await.
@MainActor
private final class ZenDetachBox {
    private(set) var didRetire = false
    private(set) var detach: Task<Void, Never>?

    func retire(_ observation: ZenSharedChatObservation) {
        didRetire = true
        detach = observation.retire()
    }
}

@MainActor
@Suite(.serialized)
struct ZenSharedChatWindowTests {
    static let agentID = "agent-1"
    static let agentName = "Worker"

    @Test("A claim acquired as the window closes is given back: the batch is offered to the next observer")
    func claimAcquiredAsTheWindowCloses() async throws {
        try await withRoom { _, backend, window, room, chat in
            let claim = ZenGate()
            let giveBack = ZenGate()
            // Open from the start: it only tells that the give-back began.
            await giveBack.open()
            window.sharedChatClaimWillResolve = { resolution in
                if resolution == .started {
                    await claim.pass()
                } else {
                    await giveBack.pass()
                }
            }
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .coordinator, text: "Need a decision")
            await waitUntil("the claim is on its way") { await claim.reached }

            window.markClosed()
            await claim.open()
            await waitUntil("the closed window gives the claim back") { await giveBack.reached }
            // The give-back is on the chain: once flushed, it reached the Core.
            await window.sharedChatObservation.flushConsumerBusy()

            let probe = await ZenRoomProbe.attach(to: room, runner: window.runner)
            await waitUntil("the batch is offered to the next observer") { probe.wasOffered("Need a decision") }
            #expect(await backend.prompts == ["Hello"])
            #expect(!window.isBusy)
            await probe.detach()
        }
    }

    @Test("A line that ends without a Core turn while the claim is on its way cannot release it: given back, the batch runs once")
    func lineEndsWhileTheClaimIsOnItsWay() async throws {
        try await withRoom { _, backend, window, room, chat in
            let claim = ZenGate()
            let reserve = ZenGate()
            window.sharedChatClaimWillResolve = { resolution in
                if resolution == .started {
                    await claim.pass()
                }
            }
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .coordinator, text: "Need a decision")
            await waitUntil("the claim is on its way") { await claim.reached }

            // A local command runs and ends while the claim waits on the
            // chain: no Core turn, so only the window's declarations tell the
            // Core whether it is busy, and they queue behind the claim.
            window.run("/help")
            #expect(await window.waitUntilIdle())
            #expect(window.transcript.contains { $0.content == .commandLine("/help") })

            // The claim lands, then the command's declarations: none of them
            // may say idle and release the claim. The coordinator turn it
            // grants is stopped before it reaches the Core, so its claim is
            // given back.
            window.turnDidReserve = { await reserve.pass() }
            await claim.open()
            await waitUntil("the coordinator turn reserved its prompt") { await reserve.reached }
            #expect(window.isBusy)
            window.stop()
            await reserve.open()
            await waitUntil("the stopped turn shows") {
                window.transcript.contains { $0.content == .local(text: ZenWindowSession.turnCancelledText, isFailure: false) }
            }
            #expect(await backend.prompts == ["Hello"])

            // Given back, the batch is offered again and runs once.
            await waitUntil("the batch runs again") { await backend.prompts.count == 2 }
            #expect(await window.waitUntilIdle())
            #expect(await backend.prompts.last?.contains("Need a decision") == true)
            await Self.expectNextTurnCarriesOnly(
                "Second question",
                notCarrying: "Need a decision",
                window: window,
                backend: backend,
                chat: chat,
                room: room
            )
        }
    }

    @Test("A claim still on its way when the window moves to a new session leaves the new room idle for the Core")
    func claimOnItsWayAcrossANewSession() async throws {
        try await withRoom { _, backend, window, room, chat in
            let claim = ZenGate()
            window.sharedChatClaimWillResolve = { resolution in
                if resolution == .started {
                    await claim.pass()
                }
            }
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .coordinator, text: "Need a decision")
            await waitUntil("the claim is on its way") { await claim.reached }

            // The window moves to a new session while the claim waits: the
            // new observation is declared busy for the claim, behind it, and
            // the old room is stopped with its session, so the claim is not
            // granted.
            window.startNewSession()
            await waitUntil("the new session is followed") {
                window.sharedChatObservation.observation != nil && window.sharedChatObservation.roomID != room
            }
            #expect(await window.waitUntilIdle())
            let newRoom = try #require(window.sharedChatObservation.roomID)
            await claim.open()

            // Once the claim returned, the new room is idle for the Core: its
            // message for the coordinator runs a turn, the only one since the
            // session began.
            try await chat.registerCoordinator(roomID: newRoom)
            try await chat.registerAgent(id: "agent-2", name: "Helper", roomID: newRoom)
            try await chat.send(roomID: newRoom, senderID: "agent-2", destination: .coordinator, text: "New question")
            await waitUntil("the new room's coordinator turn runs") { await backend.prompts.count == 2 }
            #expect(await window.waitUntilIdle())
            let prompts = await backend.prompts
            #expect(prompts.last?.contains("New question") == true)
            #expect(prompts.last?.contains("Need a decision") == false)
        }
    }

    @Test("A trigger reaching an observation the window no longer holds is declined ownerless and starts nothing")
    func triggerOfARetiredObservation() async throws {
        try await withRoom { _, backend, window, room, chat in
            let probe = await ZenRoomProbe.attach(to: room, runner: window.runner)
            let retired = ZenDetachBox()
            // The window leaves the room while it answers the trigger.
            window.sharedChatTriggerWillResolve = { @MainActor in
                retired.retire(window.sharedChatObservation)
            }
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .coordinator, text: "Need a decision")
            await waitUntil("the window left the room") { retired.didRetire }
            // Ends once the window's answer to the trigger returned.
            await retired.detach?.value

            // Declined, the batch is offered again under a new trigger, which
            // a trigger left unanswered would have kept from being minted.
            await waitUntil("the batch is offered again") { Set(probe.triggers.map(\.id)).count == 2 }
            #expect(probe.triggers.allSatisfy { $0.messages.map(\.text) == ["Need a decision"] })
            #expect(await backend.prompts == ["Hello"])
            #expect(!window.isBusy)
            await probe.detach()
        }
    }

    @Test("A mention is sent at once while a turn runs, never queued")
    func mentionWhileATurnRuns() async throws {
        try await withRoom { _, backend, window, room, _ in
            await backend.hold()
            window.draft = "First"
            window.submitDraft()
            await backend.waitUntilHeld()
            #expect(window.isBusy)

            window.draft = "@coordinator status?"
            window.submitDraft()
            #expect(window.draft.isEmpty)
            #expect(window.queuedLines.isEmpty)
            await waitUntil("the mention is sent") { await backend.sentSharedChatMessages.count == 1 }
            let sent = try #require(await backend.sentSharedChatMessages.first)
            #expect(sent.destination == .coordinator)
            #expect(sent.text == "status?")
            #expect(sent.rootSessionID == room)
            #expect(window.isBusy)
            await waitUntil("the operator's message reaches the reader") { window.sharedChat.messages.count == 1 }
            #expect(window.sharedChat.unreadCount == 0)
            #expect(!window.sharedChat.isPresented)

            // The coordinator answers once the turn that runs ended.
            await backend.release()
            await waitUntil("the coordinator turn runs") { await backend.prompts.count == 3 }
            #expect(await window.waitUntilIdle())
            let prompts = await backend.prompts
            #expect(prompts[1].contains("First"))
            #expect(prompts[2].contains("status?"))
        }
    }

    @Test("A mention without a message keeps the draft; a failed one shows why and comes back to the draft")
    func mentionFailures() async throws {
        try await withRoom { _, backend, window, room, chat in
            let handle = try await Self.agentHandle(in: window)

            window.draft = "@coordinator"
            window.submitDraft()
            #expect(window.draft == "@coordinator")
            #expect(window.transcript.last?.content == .local(
                text: "ZenCODE message: add a message after the live mention.",
                isFailure: true
            ))
            #expect(window.history.entries.last == "@coordinator")

            // The agent left: nothing is sent.
            await chat.unregisterParticipant(id: Self.agentID, roomID: room)
            window.draft = "\(handle)are you there?"
            window.submitDraft()
            #expect(window.draft.isEmpty)
            #expect(await window.waitUntilIdle())
            #expect(window.transcript.last?.content == .local(
                text: "ZenCODE message: selected agent is no longer active.",
                isFailure: true
            ))
            #expect(window.draft == "\(handle)are you there?")
            #expect(await backend.sentSharedChatMessages.isEmpty)
            await waitUntil("the suggestions drop the agent") {
                !window.mentionSuggestions.contains { $0.target == .agent(name: Self.agentName) }
            }

            // The room refuses it.
            await backend.failSharedChatSends(with: .coordinatorUnavailable)
            window.draft = "@coordinator hi"
            window.submitDraft()
            window.draft = "Typing something else"
            #expect(await window.waitUntilIdle())
            #expect(window.transcript.last?.content == .local(
                text: "ZenCODE message: \(AgentSharedChat.Error.coordinatorUnavailable.localizedDescription)",
                isFailure: true
            ))
            // A draft typed meanwhile is kept.
            #expect(window.draft == "Typing something else")
            #expect(await backend.sentSharedChatMessages.map(\.text) == ["hi"])
            #expect(await backend.prompts == ["Hello"])
        }
    }

    @Test("A new session resets the reader and observes the new session's room")
    func newSessionMovesTheObservation() async throws {
        try await withRoom { runtime, _, window, room, chat in
            _ = try await Self.agentHandle(in: window)
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .operator, text: "Old room")
            await waitUntil("the message reaches the reader") { window.sharedChat.messages.count == 1 }
            window.toggleSharedChatReader()
            #expect(window.isSharedChatReaderOpen)
            #expect(window.isSharedChatReaderOpen == window.sharedChat.isReaderOpen)
            let attaches = window.sharedChatObservation.attachCount
            let firstEpoch = window.current.epoch

            window.startNewSession()
            await waitUntil("the new session is followed") {
                window.current.epoch != firstEpoch
                    && window.sharedChatObservation.observation != nil
                    && window.sharedChatObservation.roomID != room
            }
            #expect(await window.waitUntilIdle())
            let newRoom = try #require(await runtime.sessionHost.incarnation(in: window.slotID)?.sessionID)
            #expect(newRoom != room)
            #expect(window.sharedChatObservation.roomID == newRoom)
            #expect(window.sharedChatObservation.attachCount == attaches + 1)
            #expect(window.sharedChatObservation.detachCount >= 1)
            #expect(window.sharedChat == ZenSharedChatReader())
            #expect(!window.isSharedChatReaderOpen)
            #expect(window.isSharedChatReaderOpen == window.sharedChat.isReaderOpen)
            #expect(window.mentionSuggestions == ZenWindowSession.emptyMentionSuggestions)
            #expect(window.sharedChatParticipants[Self.agentID] == nil)

            // The old room is no longer shown; the new one is.
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .operator, text: "Old again")
            try await chat.registerCoordinator(roomID: newRoom)
            try await chat.registerAgent(id: "agent-2", name: "Helper", roomID: newRoom)
            try await chat.send(roomID: newRoom, senderID: "agent-2", destination: .operator, text: "New room")
            await waitUntil("the new room's message reaches the reader") { !window.sharedChat.messages.isEmpty }
            try await Task.sleep(for: .milliseconds(300))
            #expect(window.sharedChat.messages.map(\.text) == ["New room"])
            await waitUntil("the new roster") { window.sharedChatParticipants["agent-2"] != nil }
        }
    }

    @Test("Loading the active saved session again keeps its room observed, once, and working")
    func reloadingTheActiveSession() async throws {
        try await withRoom { _, backend, window, room, chat in
            window.saveSession()
            #expect(await window.waitUntilIdle())
            await waitUntil("the session is saved") { window.currentSavedSessionName != nil }
            let name = try #require(window.currentSavedSessionName)
            let epoch = window.current.epoch
            let attaches = window.sharedChatObservation.attachCount

            window.loadSavedSession(named: name)
            #expect(await window.waitUntilIdle())
            await waitUntil("the reloaded session is followed") { window.current.epoch != epoch }
            #expect(window.current.sessionID == room)

            // The room still delivers, to one observation of it: the window
            // attached it again with the reloaded session.
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .operator, text: "After the reload")
            await waitUntil("the message reaches the reader") {
                window.sharedChat.messages.contains { $0.text == "After the reload" }
            }
            #expect(window.sharedChatObservation.roomID == room)
            #expect(window.sharedChatObservation.observation?.roomID == room)
            #expect(window.sharedChatObservation.attachCount > attaches)
            #expect(window.sharedChatObservation.detachCount == window.sharedChatObservation.attachCount - 1)
            // And its messages for the coordinator still run a turn.
            await Self.expectNextTurnCarriesOnly(
                "Need a decision",
                notCarrying: "After the reload",
                window: window,
                backend: backend,
                chat: chat,
                room: room
            )
        }
    }

    @Test("A stream that ends on its own is replaced while the room is current; close detaches")
    func recoveryAndClose() async throws {
        try await withRoom { _, _, window, room, chat in
            let attaches = window.sharedChatObservation.attachCount
            await window.runner.stopSharedChatObservation(rootSessionID: room)
            await waitUntil("the observation is replaced") {
                window.sharedChatObservation.recoveryCount == 1 && window.sharedChatObservation.observation != nil
            }
            #expect(window.sharedChatObservation.attachCount == attaches + 1)
            #expect(window.sharedChatObservation.roomID == room)

            // The replacement still delivers.
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .operator, text: "Still here")
            await waitUntil("the message reaches the reader") {
                window.sharedChat.messages.map(\.text) == ["Still here"]
            }

            await window.close()
            #expect(window.sharedChatObservation.isStopped)
            #expect(window.sharedChatObservation.observation == nil)
            #expect(window.sharedChatObservation.detachCount == window.sharedChatObservation.attachCount)
            // A closed window does nothing with the chat.
            window.toggleSharedChatReader()
            #expect(!window.sharedChat.isReaderOpen)
            window.draft = "@coordinator late"
            window.submitDraft()
            #expect(window.draft == "@coordinator late")
        }
    }

    @Test("markClosed detaches the observation: the Core forgets what it declared")
    func markClosedDetaches() async throws {
        try await withRoom { _, backend, window, room, chat in
            let observation = try #require(window.sharedChatObservation.observation)
            let probe = await ZenRoomProbe.attach(to: room, runner: window.runner)
            // Busy on the window's observation, which only its detach clears:
            // nothing is offered while it is attached.
            await window.runner.setSharedChatConsumerBusy(true, observation: observation)
            try await chat.send(roomID: room, senderID: Self.agentID, destination: .coordinator, text: "Need a decision")
            await waitUntil("the message reaches the reader") { window.sharedChat.messages.count == 1 }
            #expect(probe.triggers.isEmpty)

            window.markClosed()
            #expect(window.sharedChatObservation.isStopped)
            #expect(window.sharedChatObservation.observation == nil)
            #expect(window.sharedChatObservation.detachCount == window.sharedChatObservation.attachCount)
            await waitUntil("the batch is offered once the window's observation is detached") {
                probe.wasOffered("Need a decision")
            }
            #expect(await backend.prompts == ["Hello"])
            await probe.detach()
        }
    }

    // MARK: - Helpers

    /// Sends `text` to the coordinator and waits for its turn, which must be
    /// the next one and carry `text` without `earlier`: a batch left behind
    /// or given back twice would run before it or with it.
    static func expectNextTurnCarriesOnly(
        _ text: String,
        notCarrying earlier: String,
        window: ZenWindowSession,
        backend: ZenScriptedBackend,
        chat: AgentSharedChat,
        room: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let count = await backend.prompts.count
        do {
            try await chat.send(roomID: room, senderID: agentID, destination: .coordinator, text: text)
        } catch {
            Issue.record(error, sourceLocation: sourceLocation)
            return
        }
        await waitUntil("the turn for \(text) runs", sourceLocation: sourceLocation) {
            await backend.prompts.count > count
        }
        #expect(await window.waitUntilIdle(), sourceLocation: sourceLocation)
        let prompts = await backend.prompts
        #expect(prompts.count == count + 1, sourceLocation: sourceLocation)
        #expect(prompts.last?.contains(text) == true, sourceLocation: sourceLocation)
        #expect(prompts.last?.contains(earlier) == false, sourceLocation: sourceLocation)
    }

    /// The agent's mention as the composer offers it (`@handle `), once the
    /// roster shows it.
    static func agentHandle(in window: ZenWindowSession) async throws -> String {
        await waitUntil("the agent's mention is offered") {
            window.mentionSuggestions.contains { $0.target == .agent(name: agentName) }
        }
        let suggestion = try #require(window.mentionSuggestions.first { $0.target == .agent(name: agentName) })
        return suggestion.command
    }

    /// A window whose session ran one prompt (so the backend exists), and its
    /// room with the coordinator and one agent registered.
    func withRoom(
        _ body: @escaping @MainActor @Sendable (
            ZenAppRuntime,
            ZenScriptedBackend,
            ZenWindowSession,
            String,
            AgentSharedChat
        ) async throws -> Void
    ) async throws {
        try await withRuntime { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            await waitUntil("the room is observed") { window.sharedChatObservation.observation != nil }
            let room = try #require(await runtime.sessionHost.incarnation(in: window.slotID)?.sessionID)
            #expect(window.sharedChatObservation.roomID == room)
            let chat = await backend.sharedChat()
            try await chat.registerCoordinator(roomID: room)
            try await chat.registerAgent(id: Self.agentID, name: Self.agentName, roomID: room)
            try await body(runtime, backend, window, room, chat)
            await runtime.shutdown()
        }
    }

    /// A runtime over the scripted backend, a hosted configuration, and a
    /// temporary support directory and workspace.
    private func withRuntime(
        _ body: @escaping @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-shared-chat-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable in
            try await Self.compose(workspace: workspace, body: body)
        }
    }

    private static func compose(
        workspace: URL,
        body: @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL) async throws -> Void
    ) async throws {
        let configuration = try AgentConfiguration(
            hostedModelID: "zen-app-model",
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [
                AgentSettingsModelManifest(
                    id: "zen-app-model",
                    kind: .remoteAPI,
                    modelID: "local/zen-app-model"
                ),
            ],
            workingDirectory: workspace,
            appMode: true
        )
        let backend = ZenScriptedBackend()
        let runtime = await ZenAppRuntime(
            configuration: configuration,
            featureRuntime: nil,
            userHomeDirectoryURL: nil,
            backendFactory: { _, _ in backend },
            openExternal: { _ in }
        )
        do {
            try await body(runtime, backend, workspace)
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }
}
