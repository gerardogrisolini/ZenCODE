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
@testable import ZenCODERuntime

/// A runtime backend whose turns stream one content event and answer, and
/// whose model preload can be made to fail.
actor HostTestBackend: AgentRuntimeBackend {
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
    struct Environment {
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
    nonisolated func withEnvironment(
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
            host.slots[first]?.incarnationObservers.removeValue(forKey: token)

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
}
