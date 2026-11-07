//
//  ChatShellSnapshotTests.swift
//  ZenCODE
//
//  The shell snapshot of a session host: the summary of every slot, the
//  reducer's when the session has one and otherwise built from the
//  incarnation without creating a reducer, shown once per replacement; the
//  saved sessions of the open workspaces, keyed by their standardized URL,
//  listed without migrating the store, read only while a shell observes the
//  host and again after a save, a deletion, or a new incarnation, with the
//  reads a later one overtook dropped; the Telegram settings read with the
//  terminal's rule, together with the poller; the slots Telegram drives; and
//  the stream that ends with the host, released or shut down. Every test
//  runs in directories named by UUIDs with a private support directory;
//  nothing touches the real application state.
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

/// Holds each read of the saved sessions the shell makes until the test
/// answers it, so that the test orders the reads.
@ChatSessionActor
private final class SavedSessionsReadGate {
    private var waiting: [Int: CheckedContinuation<[ChatSavedSessionSummary]?, Never>] = [:]
    private(set) var readCount = 0

    /// The reader the host calls (``ChatSessionHost/shellSavedSessionsReader``).
    nonisolated var reader: @Sendable (URL) async -> [ChatSavedSessionSummary]? {
        { [self] _ in await read() }
    }

    private func read() async -> [ChatSavedSessionSummary]? {
        let index = readCount
        readCount += 1
        return await withCheckedContinuation { waiting[index] = $0 }
    }

    /// Answers the read `index`, counted from 0 in the order the reads
    /// started, with saved sessions named `names`.
    func answer(_ index: Int, with names: [String]) {
        waiting.removeValue(forKey: index)?.resume(returning: names.map { name in
            ChatSavedSessionSummary(
                name: name, modelID: nil, messageCount: 0, contextUsedTokens: nil,
                savedAt: Date(timeIntervalSince1970: 1_000)
            )
        })
    }
}

/// Every shell snapshot one stream delivered, in order.
@ChatSessionActor
private final class ShellRecorder {
    private(set) var snapshots: [ChatShellSnapshot] = []
    private var consumer: Task<Void, Never>?

    init(_ host: ChatSessionHost) {
        let stream = host.shellSnapshots()
        consumer = Task { @ChatSessionActor [weak self] in
            for await snapshot in stream {
                self?.snapshots.append(snapshot)
            }
        }
    }

    func stop() {
        consumer?.cancel()
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

        /// A slot of `workingDirectory` (the workspace by default) that
        /// publishes state and asks with pending requests, or one with its
        /// own host that publishes none.
        @ChatSessionActor
        func descriptor(
            _ identity: String,
            publishesState: Bool,
            workingDirectory: URL? = nil
        ) -> ChatSlotDescriptor {
            let scriptedHost = ScriptedChatInteractionHost(capabilities: [], decisions: [])
            return ChatSlotDescriptor(
                identity: .window(identity),
                workingDirectory: workingDirectory ?? workspace,
                presenter: RecordingChatPresenter(),
                interaction: publishesState ? .pendingRequests(capabilities: [.textInput]) : .host(scriptedHost),
                authorizer: ChatToolConsentAuthorizer(host: scriptedHost),
                defaultOrigin: .app,
                publishesState: publishesState
            )
        }

        /// A saved session of the workspace, as another process would write
        /// it.
        func externalSession(named name: String) -> TerminalSavedSession {
            let date = Date(timeIntervalSince1970: 1_000)
            let history = [AgentRuntimeMessage(role: .user, content: "From elsewhere")]
            return TerminalSavedSession(
                name: name, sessionID: "external-\(name)", cacheKey: nil,
                workingDirectoryPath: workspace.path, createdAt: date, savedAt: date,
                modelID: "test-model", agentID: nil, agentName: nil, selectedTools: [],
                selectedSkillIDs: [], thinkingSelection: nil, systemPrompt: "Test",
                history: history,
                checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: "external-\(name)")
            )
        }

        /// A saved session of the workspace written to the store directly, as
        /// another process would.
        func saveExternalSession(named name: String) throws {
            _ = try TerminalSessionStore.save(externalSession(named: name))
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
        host.shellSnapshot.savedSessions[workspace.standardizedFileURL].map { Set($0.map(\.name)) }
    }

    /// Lets the chat actor run what the test just released, for a check that
    /// nothing changed.
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
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

    @Test(arguments: [true, false])
    nonisolated func aReplacementShowsTheNewSessionWithNothingInBetween(_ publishesState: Bool) async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let slot = try host.openSlot(environment.descriptor("main", publishesState: publishesState))
            let first = try await host.newSession(in: slot, sessionID: "first")
            try await first.controller.createSessionWithSelectedSkills(discoverExternalTools: false)
            // Reserved, as a channel runs it: a slot without a reducer shows
            // its title once the reservation ends.
            let reservation = try host.reservePrompt(in: slot)
            try await Self.runTurn("Name the first session", on: first)
            #expect(host.releasePrompt(reservation))
            let recorder = ShellRecorder(host)
            await Self.waitUntil { Self.savedNames(host, environment.workspace) != nil }
            await Self.waitUntil { recorder.snapshots.last == host.shellSnapshot }
            #expect(host.shellSnapshot.sessions[slot]?.title == "Name the first session")
            let before = recorder.snapshots.count

            // The new session has no title yet: one snapshot shows it.
            let second = try await host.newSession(in: slot, sessionID: "second")
            await Self.waitUntil { recorder.snapshots.count > before }
            await Self.settle()
            let replacement = recorder.snapshots.dropFirst(before)
            #expect(replacement.count == 1)
            #expect(replacement.allSatisfy { $0.sessions[slot] != nil && $0.sessions[slot]?.title == nil })
            #expect(host.shellSnapshot.sessions[slot] == host.shellSummary(of: try #require(host.slots[slot])))
            #expect(second.epoch != first.epoch)

            // A closed session leaves the slot without one, once.
            let beforeClose = recorder.snapshots.count
            await host.closeSession(in: slot)
            await Self.waitUntil { recorder.snapshots.count > beforeClose }
            await Self.settle()
            #expect(recorder.snapshots.dropFirst(beforeClose).map { $0.sessions[slot] == nil } == [true])
            recorder.stop()
            await host.shutdown()
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
            let saved = try #require(host.shellSnapshot.savedSessions[environment.workspace.standardizedFileURL])
            #expect(saved.map(\.savedAt) == saved.map(\.savedAt).sorted(by: >))

            // The workspace leaves the shell with its last slot, and the
            // stream ends with the host.
            await host.closeSlot(slot)
            #expect(Self.savedNames(host, environment.workspace) == nil)
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

    @Test
    nonisolated func theShellListsTheSavedSessionsWithoutMovingAFile() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            _ = try host.openSlot(environment.descriptor("main", publishesState: false))
            // A session file with a name of an older scheme, and a save in
            // progress: a migration would move both.
            let directory = TerminalSessionStore.sessionsDirectoryURL(for: environment.workspace)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try PropertyListEncoder().encode(environment.externalSession(named: "legacy"))
            let legacyURL = directory.appendingPathComponent("stored-record")
            let inProgressURL = directory.appendingPathComponent(
                ".\(TerminalSessionStore.filename(for: "saving")).\(UUID().uuidString).tmp"
            )
            try data.write(to: legacyURL)
            try data.write(to: inProgressURL)

            let stream = host.shellSnapshots()
            await Self.waitUntil { Self.savedNames(host, environment.workspace) != nil }

            #expect(Self.savedNames(host, environment.workspace) == [])
            #expect(FileManager.default.fileExists(atPath: legacyURL.path))
            #expect(FileManager.default.fileExists(atPath: inProgressURL.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
            _ = stream
            await host.shutdown()
        }
    }

    @Test
    nonisolated func twoSpellingsOfOneFolderAreOneWorkspace() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let alias = environment.root.appendingPathComponent("elsewhere/../workspace", isDirectory: true)
            #expect(alias != environment.workspace)
            #expect(alias.standardizedFileURL == environment.workspace.standardizedFileURL)
            let first = try host.openSlot(environment.descriptor("first", publishesState: false))
            let second = try host.openSlot(
                environment.descriptor("second", publishesState: false, workingDirectory: alias)
            )
            try environment.saveExternalSession(named: "kept")

            await host.refreshShellSnapshot()
            #expect(Array(host.shellSnapshot.savedSessions.keys) == [environment.workspace.standardizedFileURL])
            #expect(Self.savedNames(host, alias) == ["kept"])

            // The workspace stays while a slot of it is open, by either name.
            await host.closeSlot(first)
            #expect(Self.savedNames(host, alias) == ["kept"])
            await host.closeSlot(second)
            #expect(host.shellSnapshot.savedSessions.isEmpty)
            await host.shutdown()
        }
    }

    @Test
    nonisolated func aReadOvertakenByALaterOneIsDroppedWhenItEnds() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let gate = SavedSessionsReadGate()
            host.shellSavedSessionsReader = gate.reader
            _ = try host.openSlot(environment.descriptor("main", publishesState: false))
            let stream = host.shellSnapshots()
            await Self.waitUntil { gate.readCount == 1 }
            host.savedSessionsDidChange(in: environment.workspace)
            await Self.waitUntil { gate.readCount == 2 }

            // The later read ends first and shows; the earlier one ends
            // after it and is dropped.
            gate.answer(1, with: ["newer"])
            await Self.waitUntil { Self.savedNames(host, environment.workspace) != nil }
            #expect(Self.savedNames(host, environment.workspace) == ["newer"])
            gate.answer(0, with: ["older"])
            await Self.settle()
            #expect(Self.savedNames(host, environment.workspace) == ["newer"])
            _ = stream
            await host.shutdown()
        }
    }

    @Test
    nonisolated func aReopenedWorkspaceReadsItsSavedSessionsAgain() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let gate = SavedSessionsReadGate()
            host.shellSavedSessionsReader = gate.reader
            let first = try host.openSlot(environment.descriptor("first", publishesState: false))
            let stream = host.shellSnapshots()
            await Self.waitUntil { gate.readCount == 1 }

            // Closed with its read in flight, then opened again: a new read
            // starts, and the old one, ending last, is dropped.
            await host.closeSlot(first)
            _ = try host.openSlot(environment.descriptor("second", publishesState: false))
            await Self.waitUntil { gate.readCount == 2 }
            #expect(gate.readCount == 2)
            gate.answer(1, with: ["reopened"])
            await Self.waitUntil { Self.savedNames(host, environment.workspace) != nil }
            #expect(Self.savedNames(host, environment.workspace) == ["reopened"])
            gate.answer(0, with: ["stale"])
            await Self.settle()
            #expect(Self.savedNames(host, environment.workspace) == ["reopened"])
            _ = stream
            await host.shutdown()
        }
    }

    // MARK: - Observation

    @Test
    nonisolated func theObservationEndsWithTheLastStream() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            let slot = try host.openSlot(environment.descriptor("main", publishesState: false))
            let first = try await host.newSession(in: slot, sessionID: "first")
            try await first.controller.createSessionWithSelectedSkills(discoverExternalTools: false)
            try await Self.runTurn("Remember this", on: first)
            let one = ShellRecorder(host)
            let two = ShellRecorder(host)
            await Self.waitUntil { Self.savedNames(host, environment.workspace) != nil }
            #expect(host.isShellObserved)

            one.stop()
            await Self.waitUntil { host.shellStreams.count == 1 }
            #expect(host.isShellObserved)
            two.stop()
            await Self.waitUntil { host.shellStreams.isEmpty }
            #expect(host.isShellObserved == false)

            // Nobody observes the host: a save and a new session read nothing.
            let reads = host.nextShellReadValue
            _ = await first.controller.saveSession(named: "unobserved", contextWindow: nil)
            _ = try await host.newSession(in: slot, sessionID: "second")
            await Self.settle()
            #expect(host.nextShellReadValue == reads)
            #expect(Self.savedNames(host, environment.workspace) == [])

            // A new stream observes it again and reads.
            let three = ShellRecorder(host)
            await Self.waitUntil { Self.savedNames(host, environment.workspace) == ["unobserved"] }
            #expect(Self.savedNames(host, environment.workspace) == ["unobserved"])
            #expect(host.isShellObserved)
            three.stop()
            await host.shutdown()
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

    /// The settings are read with the poller, so the two never come from
    /// reads made at different times: a slot that closes reads both.
    @Test
    nonisolated func theTelegramSettingsAreReadWithThePoller() async throws {
        try await withEnvironment { environment in
            let host = try environment.makeHost()
            _ = try host.openSlot(environment.descriptor("main", publishesState: false))
            let other = try host.openSlot(environment.descriptor("other", publishesState: false))
            await host.refreshShellSnapshot()
            #expect(host.shellSnapshot.telegram.isConfigured == false)

            // Setup configures Telegram meanwhile.
            let settings = ACPTelegramTestSupport.pairedSettings()
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: [], telegram: settings),
                to: environment.support.appendingPathComponent(AgentSettingsManifestStore.settingsFilename)
            )
            await host.closeSlot(other)
            await Self.waitUntil { host.shellSnapshot.telegram.isConfigured }
            #expect(host.shellSnapshot.telegram.isConfigured)
            #expect(host.shellSnapshot.telegram.isPolling == false)
            #expect(host.telegramDispatcherStorage == nil)
            await host.shutdown()
        }
    }
}
