//
//  ChatShellSnapshotTests.swift
//  ZenCODE
//
//  The shell snapshot of a session host: the summary of every slot, the
//  reducer's when the session has one and otherwise built from the
//  incarnation without creating a reducer; the saved sessions of the open
//  workspaces, read only once a shell observes the host and again after a
//  save, a deletion, or a new incarnation; the Telegram settings read with
//  the terminal's rule; the slots Telegram drives; and the stream that ends
//  with the host. Every test runs in directories named by UUIDs with a
//  private support directory; nothing touches the real application state.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// A runtime backend whose turns stream one content event and answer, and
/// that keeps a snapshot of each session, so a session can be saved.
private actor ShellTestBackend: AgentRuntimeBackend {
    private var sessions: [String: AgentRuntimeSessionSnapshot] = [:]

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
        sessions.removeValue(forKey: id)
    }

    func shutdown() async {
        sessions.removeAll()
    }

    func preloadModel(
        onEvent _: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> String {
        "test-model"
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
        let answer = "Answer to: \(prompt)"
        await onEvent(.content(answer))
        if let snapshot = sessions[sessionID] {
            sessions[sessionID] = AgentRuntimeSessionSnapshot(
                sessionID: snapshot.sessionID,
                modelID: snapshot.modelID,
                workingDirectoryPath: snapshot.workingDirectoryPath,
                systemPrompt: snapshot.systemPrompt,
                cacheKey: snapshot.cacheKey,
                history: snapshot.history + [
                    AgentRuntimeMessage(role: .user, content: prompt),
                    AgentRuntimeMessage(role: .assistant, content: answer),
                ],
                allowedToolNames: snapshot.allowedToolNames,
                thinkingSelection: snapshot.thinkingSelection,
                preserveThinking: snapshot.preserveThinking
            )
        }
        return DirectAgentResponse(text: answer, stopReason: "end_turn", modelID: "test-model")
    }

    func snapshotSession(id: String) -> AgentRuntimeSessionSnapshot? {
        sessions[id]
    }
}

@ChatSessionActor
@Suite("Chat shell snapshot", .serialized, .timeLimit(.minutes(2)))
struct ChatShellSnapshotTests {
    private struct Environment {
        let root: URL
        let workspace: URL
        let support: URL
        let backend = ShellTestBackend()

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-chat-shell-\(UUID().uuidString)", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            support = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        @ChatSessionActor
        func makeHost() throws -> ChatSessionHost {
            let backend = backend
            let runner = AgentCoreSessionRunner(
                backendFactory: { _, _ in backend },
                taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: support)
            )
            let configuration = try AgentConfiguration(
                hostedModelID: "test-model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [
                    AgentSettingsModelManifest(id: "test-model", kind: .remoteAPI, modelID: "local/test-model")
                ],
                workingDirectory: workspace
            )
            return ChatSessionHost(
                runner: runner,
                environment: ChatSessionEnvironment(configuration: configuration, featureRuntime: nil),
                sleepAssertionReason: "ZenCODE chat shell test"
            )
        }

        /// A slot of the workspace that publishes state and asks with
        /// pending requests, or one with its own host that publishes none.
        @ChatSessionActor
        func descriptor(_ identity: String, publishesState: Bool) -> ChatSlotDescriptor {
            let scriptedHost = ScriptedChatInteractionHost(capabilities: [], decisions: [])
            return ChatSlotDescriptor(
                identity: .window(identity),
                workingDirectory: workspace,
                presenter: RecordingChatPresenter(),
                interaction: publishesState ? .pendingRequests(capabilities: [.textInput]) : .host(scriptedHost),
                authorizer: ChatToolConsentAuthorizer(host: scriptedHost),
                defaultOrigin: .app,
                publishesState: publishesState
            )
        }

        /// A saved session of the workspace written to the store directly, as
        /// another process would.
        func saveExternalSession(named name: String) throws {
            let date = Date(timeIntervalSince1970: 1_000)
            let history = [AgentRuntimeMessage(role: .user, content: "From elsewhere")]
            _ = try TerminalSessionStore.save(TerminalSavedSession(
                name: name, sessionID: "external-\(name)", cacheKey: nil,
                workingDirectoryPath: workspace.path, createdAt: date, savedAt: date,
                modelID: "test-model", agentID: nil, agentName: nil, selectedTools: [],
                selectedSkillIDs: [], thinkingSelection: nil, systemPrompt: "Test",
                history: history,
                checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: "external-\(name)")
            ))
        }
    }

    /// Runs `body` on the chat actor with a private support directory that
    /// holds `telegram` when given, and a UUID-named workspace.
    private nonisolated func withEnvironment(
        telegram: AgentTelegramSettingsManifest? = nil,
        _ body: @escaping @Sendable @ChatSessionActor (Environment) async throws -> Void
    ) async throws {
        let environment = try Environment()
        defer { environment.remove() }
        try AgentSettingsManifestStore.save(
            AgentSettingsManifest(models: [], telegram: telegram),
            to: environment.support.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
        )
        try await AppStorageDirectory.withSupportDirectoryURL(environment.support) {
            try await Task(name: "ZenCODE.Tests.chat-shell") { @ChatSessionActor in
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

    /// Runs one turn on `incarnation` through its controller.
    private static func runTurn(_ prompt: String, on incarnation: ChatSessionIncarnation) async throws {
        let controller = incarnation.controller
        _ = try await controller.runTurn(
            ChatTurnRequest(
                prompt: prompt,
                sessionConfiguration: await controller.currentSessionConfiguration(responseLanguageSection: nil)
            )
        )
    }

    /// The names of the saved sessions the shell shows for `workspace`.
    private static func savedNames(_ host: ChatSessionHost, _ workspace: URL) -> Set<String>? {
        host.shellSnapshot.savedSessions[workspace].map { Set($0.map(\.name)) }
    }

    // MARK: - Sessions

    @Test
    nonisolated func everySlotShowsItsReducersSummaryOrOneBuiltFromItsIncarnation() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let published = try host.openSlot(environment.descriptor("published", publishesState: true))
            let plain = try host.openSlot(environment.descriptor("plain", publishesState: false))
            #expect(host.shellSnapshot.sessions.isEmpty)
            let observed = try await host.newSession(in: published, sessionID: "observed")
            let unobserved = try await host.newSession(in: plain, sessionID: "unobserved")
            let reducer = try #require(observed.reducer)

            // The slot that publishes state shows its reducer's summary; the
            // other one a summary of its incarnation, with no reducer made.
            #expect(host.shellSnapshot.sessions[published] == reducer.snapshot.summary)
            #expect(unobserved.reducer == nil)
            let summary = try #require(host.shellSnapshot.sessions[plain])
            #expect(summary.workspace == environment.workspace)
            #expect(summary.title == nil)
            #expect(summary.isGenerating == false)
            #expect(summary.pendingRequestCount == 0)
            #expect(summary.activeChannel == .app)

            // A reserved prompt is a session generating; its first prompt
            // names it once the turn is in the transcript.
            try await unobserved.controller.createSessionWithSelectedSkills(discoverExternalTools: false)
            let reservation = try host.reservePrompt(in: plain)
            #expect(host.shellSnapshot.sessions[plain]?.isGenerating == true)
            try await Self.runTurn("Read the parser and fix the bug", on: unobserved)
            #expect(host.releasePrompt(reservation))
            #expect(host.shellSnapshot.sessions[plain]?.isGenerating == false)
            #expect(host.shellSnapshot.sessions[plain]?.title == "Read the parser and fix the bug")
            #expect(host.incarnation(in: plain)?.reducer == nil)

            // The reducer's summary follows its session.
            try await observed.controller.createSessionWithSelectedSkills(discoverExternalTools: false)
            try await Self.runTurn("Explain the reducer", on: observed)
            #expect(reducer.snapshot.summary.title == "Explain the reducer")
            #expect(host.shellSnapshot.sessions[published] == reducer.snapshot.summary)

            // A saved session's name is the title, on both slots.
            _ = await observed.controller.saveSession(named: "observed-kept", contextWindow: nil)
            _ = await unobserved.controller.saveSession(named: "plain-kept", contextWindow: nil)
            #expect(host.shellSnapshot.sessions[published]?.title == "observed-kept")
            #expect(host.shellSnapshot.sessions[published] == reducer.snapshot.summary)
            #expect(host.shellSnapshot.sessions[plain]?.title == "plain-kept")

            // A closed session or slot leaves the shell, and so do all of them
            // at shutdown.
            await host.closeSession(in: plain)
            #expect(host.shellSnapshot.sessions[plain] == nil)
            await host.closeSlot(plain)
            #expect(Array(host.shellSnapshot.sessions.keys) == [published])
            await host.shutdown()
            #expect(host.shellSnapshot.sessions.isEmpty)
        }
    }

    // MARK: - Saved sessions

    @Test
    nonisolated func savedSessionsAreReadOnceObservedThenAfterSavesDeletionsAndNewSessions() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let slot = try host.openSlot(environment.descriptor("main", publishesState: false))
            let first = try await host.newSession(in: slot, sessionID: "first")
            try await first.controller.createSessionWithSelectedSkills(discoverExternalTools: false)
            try await Self.runTurn("Remember this", on: first)
            _ = await first.controller.saveSession(named: "before-observation", contextWindow: nil)

            // Nobody observes the host: the store is not read.
            #expect(host.isShellObserved == false)
            #expect(host.shellSnapshot.savedSessions.isEmpty)

            // The first observation reads it, off the chat actor.
            let stream = host.shellSnapshots()
            await Self.waitUntil { Self.savedNames(host, environment.workspace) != nil }
            #expect(Self.savedNames(host, environment.workspace) == ["before-observation"])

            // A save and a deletion of the host's sessions read it again.
            _ = await first.controller.saveSession(named: "after-observation", contextWindow: nil)
            await Self.waitUntil { Self.savedNames(host, environment.workspace)?.count == 2 }
            #expect(Self.savedNames(host, environment.workspace) == ["before-observation", "after-observation"])
            _ = try await first.controller.deleteSavedSessions(names: ["before-observation"])
            await Self.waitUntil { Self.savedNames(host, environment.workspace) == ["after-observation"] }
            #expect(Self.savedNames(host, environment.workspace) == ["after-observation"])

            // A session saved elsewhere appears when the slot starts another
            // session, and on request.
            try environment.saveExternalSession(named: "external-one")
            _ = try await host.newSession(in: slot, sessionID: "second")
            await Self.waitUntil { Self.savedNames(host, environment.workspace)?.contains("external-one") == true }
            #expect(Self.savedNames(host, environment.workspace) == ["after-observation", "external-one"])
            try environment.saveExternalSession(named: "external-two")
            await host.refreshShellSnapshot()
            #expect(Self.savedNames(host, environment.workspace) == ["after-observation", "external-one", "external-two"])
            // Most recently saved first.
            let saved = try #require(host.shellSnapshot.savedSessions[environment.workspace])
            #expect(saved.map(\.savedAt) == saved.map(\.savedAt).sorted(by: >))

            // The workspace leaves the shell with its last slot, and the
            // stream ends with the host.
            await host.closeSlot(slot)
            #expect(host.shellSnapshot.savedSessions[environment.workspace] == nil)
            await host.shutdown()
            var delivered: [ChatShellSnapshot] = []
            for await snapshot in stream {
                delivered.append(snapshot)
            }
            #expect(delivered.last?.sessions.isEmpty == true)
            #expect(delivered.last?.savedSessions.isEmpty == true)
            // After the shutdown a stream ends at once, on the last snapshot.
            var late: [ChatShellSnapshot] = []
            for await snapshot in host.shellSnapshots() {
                late.append(snapshot)
            }
            #expect(late == [host.shellSnapshot])
        }
    }

    // MARK: - Telegram

    @Test
    nonisolated func telegramIsConfiguredByTheTerminalsRuleAndTheDrivenSlotsFollowTheChannel() async throws {
        let settings = ACPTelegramTestSupport.pairedSettings()
        #expect(settings.isEnabled)
        try await withEnvironment(telegram: settings) { environment in
            let host = try environment.makeHost()
            let slot = try host.openSlot(environment.descriptor("main", publishesState: false))
            _ = try await host.newSession(in: slot, sessionID: "linked")
            #expect(host.shellSnapshot.telegram.isConfigured == false)

            // Read from the settings at the first observation.
            _ = host.shellSnapshots()
            await Self.waitUntil { host.shellSnapshot.telegram.isConfigured }
            #expect(host.shellSnapshot.telegram.isConfigured)
            // No poller exists before a `/telegram on`, and none is created to
            // be read.
            await host.refreshShellSnapshot()
            #expect(host.shellSnapshot.telegram.isPolling == false)
            #expect(host.telegramDispatcherStorage == nil)
            #expect(host.telegramRouterStorage == nil)

            // The slots the linked chat drives follow the slot's channel.
            let channelSlot = try #require(host.slots[slot])
            channelSlot.setActiveChannel(.telegram)
            #expect(host.shellSnapshot.telegram.drivenSlots == [slot])
            channelSlot.setActiveChannel(.primary)
            #expect(host.shellSnapshot.telegram.drivenSlots.isEmpty)
            await host.shutdown()
        }
    }

    @Test
    nonisolated func telegramIsNotConfiguredWithoutItsSettings() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            _ = try host.openSlot(environment.descriptor("main", publishesState: false))
            await host.refreshShellSnapshot()
            #expect(host.shellSnapshot.telegram == ChatShellTelegramState())
            await host.shutdown()
        }
    }
}
