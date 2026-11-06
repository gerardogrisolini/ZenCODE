//
//  ZenWindowResumeTaskGraphTests.swift
//  ZenAppSessionTests
//
//  The startup offer of a window: the task graphs earlier sessions of the
//  project left incomplete, offered once, right after the window opens, as a
//  pending request of the window. The checkpoints live in a support
//  directory and a workspace named by UUIDs, never in the real application
//  state.
//

import Foundation
import Testing
import ZenCODECore
@testable import ZenAppSession

@MainActor
@Suite(.serialized)
struct ZenWindowResumeTaskGraphTests {
    private static let mainMenuTitle = "Open tasks from previous sessions"
    /// The main-menu item that resumes the seeded graph.
    private static let resumeID = "resume:old-session/old-work"
    /// The notice of the seeded graph resumed: 2 of its 3 tasks are pending.
    private static let resumedNotice = ChatSessionNotice.taskGraphResumed(
        graphID: "old-work",
        pendingTaskCount: 2,
        isWorkflow: false
    )

    @Test("Nothing resumable: opening a window asks nothing and leaves it idle")
    func nothingResumableAsksNothing() async throws {
        try await withRuntime { runtime, _, workspace, _ in
            let window = try await runtime.openWindow(workspace: workspace)

            // No line was taken for the offer.
            #expect(!window.isBusy)
            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.snapshot != nil })
            #expect(window.pendingRequest == nil)
            #expect(window.snapshot?.pendingRequests.isEmpty == true)
        }
    }

    @Test("An incomplete graph of an earlier session is offered at open and resumed into the window's session")
    func anEarlierGraphIsOfferedAndResumed() async throws {
        try await withRuntime { runtime, _, workspace, store in
            try Self.seedCheckpoint(in: store, workspace: workspace)
            let window = try await runtime.openWindow(workspace: workspace)
            let sessionID = window.current.sessionID
            // The offer is the window's line while it asks.
            #expect(window.isBusy)

            let request = try #require(await Self.pendingRequest(of: window))
            guard case let .chooseOne(title, items, selectedID) = request.kind else {
                Issue.record("the offer should ask with its main menu")
                return
            }
            #expect(title == Self.mainMenuTitle)
            #expect(selectedID == Self.resumeID)
            #expect(items.map(\.id) == [Self.resumeID, "delete", "fresh"])
            #expect(items.map(\.title) == ["old-work", "Delete old tasks…", "Start fresh"])
            #expect(items.map(\.group) == ["Resume", "Other actions", "Other actions"])
            #expect(items.first?.detail?.hasPrefix("2 of 3 tasks pending · updated ") == true)

            window.answer(request.id, with: .choice(Self.resumeID))

            #expect(await window.waitUntilIdle())
            #expect(await eventually { window.transcript.contains { $0.content == .notice(Self.resumedNotice) } })
            #expect(await eventually { window.pendingRequest == nil })
            // The session keeps its id and now owns the graph.
            #expect(window.current.sessionID == sessionID)
            let graph = try await runtime.sessionHost.runner.taskGraphSnapshot(sessionID: sessionID)
            #expect(graph?.id == "old-work")
            #expect(graph?.state == .active)
            #expect(try store.load(sessionID: sessionID, workingDirectory: workspace)?.currentGraphID == "old-work")
            #expect(try store.load(sessionID: "old-session", workingDirectory: workspace) == nil)
        }
    }

    @Test("A graph resumed in one window is not offered by a second window of the same runtime")
    func aResumedGraphIsNotOfferedAgain() async throws {
        try await withRuntime { runtime, _, workspace, store in
            try Self.seedCheckpoint(in: store, workspace: workspace)
            let first = try await runtime.openWindow(workspace: workspace)
            let request = try #require(await Self.pendingRequest(of: first))
            first.answer(request.id, with: .choice(Self.resumeID))
            #expect(await first.waitUntilIdle())
            let firstSessionID = first.current.sessionID
            #expect(try store.load(sessionID: firstSessionID, workingDirectory: workspace)?.currentGraphID == "old-work")

            let second = try await runtime.openWindow(workspace: workspace)

            // The first window's session is live: nothing is left to offer, so
            // the offer ends without asking (an open request would keep the
            // window busy).
            #expect(await second.waitUntilIdle())
            #expect(await eventually { second.snapshot != nil })
            #expect(second.pendingRequest == nil)
            #expect(second.snapshot?.pendingRequests.isEmpty == true)
            #expect(try store.load(sessionID: second.current.sessionID, workingDirectory: workspace)?.graphs.isEmpty ?? true)
            #expect(try store.load(sessionID: firstSessionID, workingDirectory: workspace)?.currentGraphID == "old-work")
            #expect(first.pendingRequest == nil)
        }
    }

    @Test("Closing a window while the offer asks ends the offer without effect")
    func closingWhileAskingEndsTheOffer() async throws {
        try await withRuntime { runtime, _, workspace, store in
            try Self.seedCheckpoint(in: store, workspace: workspace)
            let window = try await runtime.openWindow(workspace: workspace)
            let sessionID = window.current.sessionID
            _ = try #require(await Self.pendingRequest(of: window))

            await window.close()

            #expect(window.isClosed)
            #expect(!window.isBusy)
            #expect(runtime.windows.isEmpty)
            #expect(!window.transcript.contains { $0.content == .notice(Self.resumedNotice) })
            #expect(try store.load(sessionID: "old-session", workingDirectory: workspace)?.graphs.map(\.id) == ["old-work"])
            #expect(try store.load(sessionID: sessionID, workingDirectory: workspace)?.graphs.isEmpty ?? true)

            // The graph is still left over: the next window offers it, and
            // resuming it there moves it into that window's session.
            let next = try await runtime.openWindow(workspace: workspace)
            let request = try #require(await Self.pendingRequest(of: next))
            guard case let .chooseOne(_, items, _) = request.kind else {
                Issue.record("the next window should ask with the main menu")
                return
            }
            #expect(items.first?.id == Self.resumeID)
            next.answer(request.id, with: .choice(Self.resumeID))
            #expect(await next.waitUntilIdle())
            #expect(try store.load(sessionID: next.current.sessionID, workingDirectory: workspace)?.currentGraphID == "old-work")
            #expect(try store.load(sessionID: sessionID, workingDirectory: workspace)?.graphs.isEmpty ?? true)
        }
    }

    @Test("A prompt submitted while the offer asks waits in the queue and runs once the offer ended")
    func aPromptWaitsForTheOffer() async throws {
        try await withRuntime { runtime, backend, workspace, store in
            try Self.seedCheckpoint(in: store, workspace: workspace)
            let window = try await runtime.openWindow(workspace: workspace)
            let request = try #require(await Self.pendingRequest(of: window))

            window.draft = "Hello"
            window.submitDraft()

            #expect(window.draft.isEmpty)
            #expect(window.queuedLines.map(\.text) == ["Hello"])
            #expect(await backend.prompts.isEmpty)

            window.answer(request.id, with: .choice("fresh"))

            #expect(await window.waitUntilIdle())
            #expect(await eventually {
                window.transcript.contains { $0.content == .assistantText("Scripted answer to Hello", isStreaming: false) }
            })
            #expect(window.queuedLines.isEmpty)
            // Started fresh: the graph stays where it was.
            #expect(try store.load(sessionID: "old-session", workingDirectory: workspace)?.graphs.map(\.id) == ["old-work"])
        }
    }

    // MARK: - Helpers

    /// Writes the checkpoint the earlier session `old-session` left in
    /// `workspace`: the graph `old-work`, active, with 2 of its 3 tasks
    /// pending.
    private static func seedCheckpoint(in store: SessionTaskGraphStore, workspace: URL) throws {
        let updatedAt = Date(timeIntervalSince1970: 1_000)
        let tasks = (0 ..< 3).map { index in
            TaskRecord(
                id: "old-work-task-\(index)",
                title: "Task \(index)",
                order: index + 1,
                status: index == 0 ? .completed : .pending,
                createdAt: updatedAt,
                updatedAt: updatedAt
            )
        }
        try store.save(
            SessionTaskGraphCheckpoint(
                sessionID: "old-session",
                currentGraphID: "old-work",
                graphs: [
                    TaskGraphSnapshot(
                        id: "old-work",
                        source: .manual,
                        state: .active,
                        tasks: tasks,
                        createdAt: updatedAt,
                        updatedAt: updatedAt
                    ),
                ]
            ),
            workingDirectory: workspace
        )
    }

    /// The request `window` shows, once it shows one; `nil` after 10 s.
    private static func pendingRequest(of window: ZenWindowSession) async -> ChatPendingRequest? {
        let deadline = ContinuousClock.now + zenTestDeadline
        while ContinuousClock.now < deadline {
            if let request = window.pendingRequest { return request }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return window.pendingRequest
    }

    /// Polls `condition` on the main actor until it holds or 10 s pass.
    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + zenTestDeadline
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A runtime over the scripted backend, a hosted configuration, and a
    /// temporary support directory and workspace, with the task-graph store
    /// of that support directory (the runner's own resolves to it).
    private func withRuntime(
        _ body: @escaping @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL, SessionTaskGraphStore) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-resume-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The support directory is task-local: everything below runs in this
        // task and the tasks it creates.
        let store = SessionTaskGraphStore(supportDirectoryURL: support)
        try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable in
            try await Self.compose(workspace: workspace, store: store, body: body)
        }
    }

    private static func compose(
        workspace: URL,
        store: SessionTaskGraphStore,
        body: @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL, SessionTaskGraphStore) async throws -> Void
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
            try await body(runtime, backend, workspace, store)
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }
}
