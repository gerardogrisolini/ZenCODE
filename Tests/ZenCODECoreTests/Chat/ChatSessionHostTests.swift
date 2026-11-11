//
//  ChatSessionHostTests.swift
//  ZenCODE
//
//  The container of the chat sessions: slots, incarnations with their epochs,
//  the exclusive prompt reservation, close against shutdown, the work of an
//  older incarnation, the Telegram router and dispatcher shared by every slot,
//  the pending requests refused with their incarnation, the reducer that
//  sees its session from the start, the bindings a slot keeps across its
//  sessions, the reload of the session a slot runs, which discards its runner
//  session, the session operations a hosted controller delegates, a retired
//  slot and an announced shutdown, the id adopted in place, and the shutdown
//  that keeps the external tools. Every test runs in directories named by
//  UUIDs; nothing touches the real application state.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

/// A runtime backend whose turns stream one content event and answer, and
/// whose model preload can be made to fail.
private actor HostTestBackend: AgentRuntimeBackend {
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]
    private var preloadFails = false
    private(set) var prompts: [String] = []
    /// The ids of the sessions the runner closed in the backend, in order: a
    /// runner session discarded (`resetSession`) or closed ends here.
    private(set) var closedSessionIDs: [String] = []

    func setPreloadFails(_ fails: Bool) {
        preloadFails = fails
    }

    func createSession(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        sessions[id] = AgentRuntimeSessionSnapshot(
            sessionID: id,
            modelID: "test-model",
            workingDirectoryPath: cwd,
            systemPrompt: systemPrompt,
            cacheKey: cacheKey,
            history: history,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func createSessionIfNeeded(
        id: String,
        cwd: String,
        systemPrompt: String?,
        history: [AgentRuntimeMessage],
        cacheKey: String?,
        allowedToolNames: Set<String>?,
        thinkingSelection: AgentThinkingSelection?,
        preserveThinking: Bool
    ) {
        guard sessions[id] == nil else { return }
        createSession(
            id: id,
            cwd: cwd,
            systemPrompt: systemPrompt,
            history: history,
            cacheKey: cacheKey,
            allowedToolNames: allowedToolNames,
            thinkingSelection: thinkingSelection,
            preserveThinking: preserveThinking
        )
    }

    func updateSessionOptions(
        id _: String,
        systemPrompt _: String?,
        allowedToolNames _: Set<String>?,
        thinkingSelection _: AgentThinkingSelection?,
        preserveThinking _: Bool
    ) {}

    func closeSession(id: String) {
        closedSessionIDs.append(id)
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        if preloadFails {
            throw HostTestBackendError.preloadFailed
        }
        return "test-model"
    }

    func activeToolDescriptors() async -> [DirectToolDescriptor] {
        []
    }

    func sendPrompt(
        sessionID: String,
        prompt: String,
        attachments _: [AgentRuntimeAttachment],
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        prompts.append(prompt)
        let answer = "Answer to: \(prompt)"
        await onEvent(.content(answer))
        if var snapshot = sessions[sessionID] {
            snapshot = AgentRuntimeSessionSnapshot(
                sessionID: snapshot.sessionID,
                modelID: snapshot.modelID,
                workingDirectoryPath: snapshot.workingDirectoryPath,
                systemPrompt: snapshot.systemPrompt,
                cacheKey: snapshot.cacheKey,
                history: snapshot.history + [
                    AgentRuntimeMessage(role: .user, content: prompt),
                    AgentRuntimeMessage(role: .assistant, content: answer)
                ],
                allowedToolNames: snapshot.allowedToolNames,
                thinkingSelection: snapshot.thinkingSelection,
                preserveThinking: snapshot.preserveThinking
            )
            sessions[sessionID] = snapshot
        }
        return DirectAgentResponse(text: answer, stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

private enum HostTestBackendError: Error {
    case preloadFailed
}

@ChatSessionActor
@Suite("Chat session host", .serialized, .timeLimit(.minutes(2)))
struct ChatSessionHostTests {
    private struct Environment {
        let root: URL
        let workspace: URL
        let support: URL
        let backend = HostTestBackend()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-chat-host-\(UUID().uuidString)", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            support = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func configuration() throws -> AgentConfiguration {
            try AgentConfiguration(
                hostedModelID: "test-model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [
                    AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")
                ],
                workingDirectory: workspace
            )
        }

        /// A host over a runner on ``backend``, with a task-graph store in
        /// the support directory.
        @ChatSessionActor
        func makeHost() throws -> ChatSessionHost {
            let backend = backend
            let runner = AgentCoreSessionRunner(
                backendFactory: { _, _ in backend },
                taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: support)
            )
            let configuration = try configuration()
            return ChatSessionHost(
                runner: runner,
                environment: ChatSessionEnvironment(configuration: configuration, featureRuntime: nil),
                sleepAssertionReason: "ZenCODE chat host test"
            )
        }

        /// A slot that publishes state and asks with pending requests.
        @ChatSessionActor
        func descriptor(
            identity: ChatSlotIdentity = .window("test"),
            interaction: ChatSlotInteraction? = nil,
            publishesState: Bool = true
        ) -> ChatSlotDescriptor {
            let scriptedHost = ScriptedChatInteractionHost(capabilities: [], decisions: [])
            return ChatSlotDescriptor(
                identity: identity,
                workingDirectory: workspace,
                presenter: RecordingChatPresenter(),
                interaction: interaction ?? .pendingRequests(capabilities: [.textInput]),
                authorizer: ChatToolConsentAuthorizer(host: scriptedHost),
                defaultOrigin: .app,
                publishesState: publishesState
            )
        }
    }

    /// Runs `body` on the chat actor with a private support directory (never
    /// the real `~/.zencode`) and a UUID-named temporary workspace.
    private nonisolated func withEnvironment(
        _ body: @escaping @Sendable @ChatSessionActor (Environment) async throws -> Void
    ) async throws {
        let environment = try Environment()
        defer { environment.remove() }
        try await AppStorageDirectory.withSupportDirectoryURL(environment.support) {
            try await Task(name: "ZenCODE.Tests.chat-session-host") { @ChatSessionActor in
                try await body(environment)
            }.value
        }
    }

    private static func waitUntil(_ condition: @ChatSessionActor () -> Bool) async {
        for _ in 0 ..< 2_000 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

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

    // MARK: - Epochs

    @Test
    nonisolated func epochsGrowAcrossSlotsAndSessionsAndAreNeverReused() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let first = try host.openSlot(environment.descriptor(identity: .window("first")))
            let second = try host.openSlot(environment.descriptor(identity: .window("second")))
            #expect(host.incarnation(in: first) == nil)

            let a = try await host.newSession(in: first, sessionID: "a")
            let b = try await host.newSession(in: second, sessionID: "b")
            let c = try await host.newSession(in: first, sessionID: "c")
            await host.closeSession(in: first)
            #expect(host.incarnation(in: first) == nil)
            let d = try await host.newSession(in: first, sessionID: "d")
            await host.closeSlot(second)
            let third = try host.openSlot(environment.descriptor(identity: .window("third")))
            let e = try await host.newSession(in: third, sessionID: "e")

            let epochs = [a, b, c, d, e].map(\.epoch)
            #expect(epochs == epochs.sorted())
            #expect(Set(epochs).count == epochs.count)
            #expect(epochs.first == 1)
            // The slot runs the latest incarnation only, and the reducer of
            // each one carries its epoch.
            #expect(host.incarnation(in: first)?.epoch == d.epoch)
            #expect(host.incarnation(in: first)?.sessionID == "d")
            #expect(host.incarnation(in: second) == nil)
            for incarnation in [a, b, c, d, e] {
                #expect(incarnation.reducer?.snapshot.epoch == incarnation.epoch)
                #expect(incarnation.reducer?.snapshot.sessionID == incarnation.sessionID)
            }
            await host.shutdown()
        }
    }

    // MARK: - Prompt reservation

    @Test
    nonisolated func onePromptPerIncarnationEvenWhenReservedConcurrently() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let slot = try host.openSlot(environment.descriptor())
            let incarnation = try await host.newSession(in: slot, sessionID: "session")

            // Reservations dispatched together: exactly one wins.
            let outcomes = await withTaskGroup(of: Result<ChatPromptReservation, ChatSessionHostError>.self) { group in
                for _ in 0 ..< 32 {
                    group.addTask { @ChatSessionActor in
                        do throws(ChatSessionHostError) {
                            return .success(try host.reservePrompt(in: slot))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                var collected: [Result<ChatPromptReservation, ChatSessionHostError>] = []
                for await outcome in group {
                    collected.append(outcome)
                }
                return collected
            }
            let reservations = outcomes.compactMap { try? $0.get() }
            let refusals = outcomes.compactMap { outcome -> ChatSessionHostError? in
                if case let .failure(error) = outcome { return error }
                return nil
            }
            #expect(reservations.count == 1)
            #expect(refusals.count == 31)
            #expect(refusals.allSatisfy { $0 == .sessionBusy })
            let reservation = try #require(reservations.first)
            #expect(reservation.epoch == incarnation.epoch)
            #expect(reservation.sessionID == "session")
            #expect(host.holdsPrompt(reservation))
            #expect(host.incarnation(in: slot)?.activePromptID == reservation.promptID)
            #expect(host.incarnation(in: slot)?.operationState == .prompting(reservation.promptID))
            #expect(host.withReservedIncarnation(reservation) { $0.epoch } == incarnation.epoch)

            // A reconfiguration is excluded by the prompt, and a prompt by a
            // reconfiguration; a release opens the session again, once.
            #expect(throws: ChatSessionHostError.sessionBusy) { try host.reserveReconfiguration(in: slot) }
            #expect(host.releasePrompt(reservation))
            #expect(host.releasePrompt(reservation) == false)
            #expect(host.holdsPrompt(reservation) == false)
            #expect(host.withReservedIncarnation(reservation) { _ in true } == nil)
            let reconfiguration = try host.reserveReconfiguration(in: slot)
            #expect(throws: ChatSessionHostError.sessionBusy) { try host.reservePrompt(in: slot) }
            #expect(host.incarnation(in: slot)?.operationState == .reconfiguring(reconfiguration.reconfigurationID))
            // Cancelling a prompt does not touch a reconfiguration.
            #expect(host.cancelPrompt(in: slot) == nil)
            #expect(host.holdsReconfiguration(reconfiguration))
            #expect(host.releaseReconfiguration(reconfiguration))
            let again = try host.reservePrompt(in: slot)
            #expect(again.promptID != reservation.promptID)
            // A cancel drops the prompt and tells which one it was.
            #expect(host.cancelPrompt(in: slot) == again.promptID)
            #expect(host.holdsPrompt(again) == false)
            #expect(host.incarnation(in: slot)?.operationState == .idle)
            await host.shutdown()
        }
    }

    // MARK: - Older incarnation

    @Test
    nonisolated func theWorkOfAnOlderIncarnationIsDiscardedByTheReplacementWithTheSameID() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let slot = try host.openSlot(environment.descriptor())
            let old = try await host.newSession(in: slot, sessionID: "same-id")
            let oldReservation = try host.reservePrompt(in: slot)
            let oldTurnToken = old.controller.beginTurnToken()

            // A busy session is not replaced; a close ends it, prompt and all.
            await #expect(throws: ChatSessionHostError.sessionBusy) {
                try await host.newSession(in: slot, sessionID: "same-id")
            }
            await host.closeSession(in: slot)
            let replacement = try await host.newSession(in: slot, sessionID: "same-id")
            #expect(replacement.epoch > old.epoch)
            #expect(replacement.controller !== old.controller)
            #expect(replacement.reducer !== old.reducer)

            // The old controller was fenced: its turn can no longer write back.
            #expect(old.controller.isCurrentTurn(oldTurnToken, sessionID: "same-id") == false)
            // Everything the old work could try is refused, and leaves the
            // replacement untouched.
            #expect(host.holdsPrompt(oldReservation) == false)
            #expect(host.releasePrompt(oldReservation) == false)
            #expect(host.withReservedIncarnation(oldReservation) { _ in true } == nil)
            #expect(host.withLiveIncarnation(slot, epoch: old.epoch) { _ in true } == nil)
            #expect(host.liveIncarnation(in: slot, epoch: old.epoch)?.activePromptID == nil)
            #expect(host.incarnation(in: slot)?.activePromptID == nil)
            #expect(host.withLiveIncarnation(slot, epoch: replacement.epoch) { $0.sessionID } == "same-id")

            // The replacement reserves and runs on its own.
            let newReservation = try host.reservePrompt(in: slot)
            #expect(newReservation.epoch == replacement.epoch)
            #expect(host.releasePrompt(oldReservation) == false)
            #expect(host.holdsPrompt(newReservation))
            #expect(host.releasePrompt(newReservation))
            await host.shutdown()
        }
    }

    // MARK: - Close and shutdown

    @Test
    nonisolated func closeSessionLeavesTheSlotOpenAndShutdownEndsEverySlot() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let first = try host.openSlot(environment.descriptor(identity: .window("first")))
            let second = try host.openSlot(environment.descriptor(identity: .window("second")))
            _ = try await host.newSession(in: first, sessionID: "first-session")
            let secondIncarnation = try await host.newSession(in: second, sessionID: "second-session")
            let secondReservation = try host.reservePrompt(in: second)

            var observed: [String?] = []
            let token = try #require(host.addIncarnationObserver(to: first) { incarnation in
                observed.append(incarnation?.sessionID)
            })
            let secondStream = host.incarnations(in: second)
            var secondIterator = secondStream.makeAsyncIterator()
            #expect(await secondIterator.next()??.sessionID == "second-session")

            // Close: the slot stays, without session; the other slot is untouched.
            await host.closeSession(in: first)
            #expect(host.incarnation(in: first) == nil)
            #expect(host.reducer(in: first) == nil)
            #expect(observed == [nil])
            #expect(host.incarnation(in: second)?.epoch == secondIncarnation.epoch)
            #expect(host.holdsPrompt(secondReservation))
            let reopened = try await host.newSession(in: first, sessionID: "first-again")
            #expect(observed == [nil, "first-again"])
            #expect(host.incarnation(in: first)?.epoch == reopened.epoch)
            host.removeIncarnationObserver(token, from: first)

            // Shutdown: every slot ends, the fence latches, and a second call
            // changes nothing.
            await host.shutdown()
            #expect(host.isShutDown)
            #expect(observed == [nil, "first-again"])
            #expect(host.incarnation(in: first) == nil)
            #expect(host.incarnation(in: second) == nil)
            #expect(host.holdsPrompt(secondReservation) == false)
            #expect(host.releasePrompt(secondReservation) == false)
            #expect(host.slotIDs.isEmpty)
            #expect(throws: ChatSessionHostError.shutDown) { try host.openSlot(environment.descriptor()) }
            #expect(throws: ChatSessionHostError.shutDown) { try host.reservePrompt(in: second) }
            await #expect(throws: ChatSessionHostError.shutDown) {
                try await host.newSession(in: first, sessionID: "after-shutdown")
            }
            #expect(host.cancelPrompt(in: second) == nil)
            // The stream of a closed slot ends.
            #expect(await secondIterator.next() == nil)
            await host.shutdown()
            #expect(host.isShutDown)
        }
    }

    // MARK: - Pending requests

    @Test
    nonisolated func pendingRequestsAreRefusedWhenTheirIncarnationEnds() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let slot = try host.openSlot(environment.descriptor())
            let incarnation = try await host.newSession(in: slot, sessionID: "asking")
            let pendingHost = try #require(incarnation.pendingRequestHost)
            let reducer = try #require(incarnation.reducer)
            // The controller asks through the slot's host, which forwards to
            // the incarnation's pending-request host while the channel that
            // opened the slot drives it.
            #expect(incarnation.controller.host is ChatSlotInteractionHost)
            #expect(host.activeChannel(in: slot) == .primary)

            let answer = Task { @ChatSessionActor in
                await pendingHost.readLine(prompt: "Name?")
            }
            await Self.waitUntil { reducer.snapshot.pendingRequests.count == 1 }
            #expect(reducer.snapshot.pendingRequests.first?.kind == .readLine(prompt: "Name?"))

            // The next session refuses what the previous one still asked.
            let next = try await host.newSession(in: slot, sessionID: "next")
            #expect(await answer.value == nil)
            #expect(reducer.snapshot.pendingRequests.isEmpty)
            #expect(next.pendingRequestHost !== pendingHost)
            #expect(next.pendingRequestHost?.reducer === next.reducer)

            // So does a close, and a shutdown.
            let nextHost = try #require(next.pendingRequestHost)
            let closedAnswer = Task { @ChatSessionActor in
                await nextHost.readLine(prompt: "Again?")
            }
            await Self.waitUntil { next.reducer?.snapshot.pendingRequests.count == 1 }
            await host.closeSession(in: slot)
            #expect(await closedAnswer.value == nil)
            let last = try await host.newSession(in: slot, sessionID: "last")
            let lastHost = try #require(last.pendingRequestHost)
            let shutDownAnswer = Task { @ChatSessionActor in
                await lastHost.readLine(prompt: "Last?")
            }
            await Self.waitUntil { last.reducer?.snapshot.pendingRequests.count == 1 }
            await host.shutdown()
            #expect(await shutDownAnswer.value == nil)

            // Pending requests need a reducer to be published in.
            let silent = try? host.openSlot(environment.descriptor(publishesState: false))
            #expect(silent == nil)
        }
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
