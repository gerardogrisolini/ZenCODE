//
//  ZenSavedSessionFirstLoadTests.swift
//  ZenAppSessionTests
//
//  The first load of a saved session from the sidebar in a window that just
//  opened: the saved session already exists on disk, written by an earlier
//  run, and the load replaces the window's initial incarnation. While it
//  loads, the window shows the loading indicator in place of the welcome
//  view (`loadingSavedSessionName`).
//

import Foundation
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

@MainActor
@Suite(.serialized)
struct ZenSavedSessionFirstLoadTests {
    @Test("The first load in a new window of a session an earlier run saved restores its transcript, name, and title")
    func firstLoadAfterAnEarlierRun() async throws {
        try await withSupport { workspace in
            let name = try await Self.saveSessionInEarlierRun(workspace: workspace, prompt: "Hello")

            try await Self.withRuntime(workspace: workspace) { runtime, _ in
                let window = try await runtime.openWindow(workspace: workspace)
                #expect(await eventually { window.snapshot != nil && window.epoch == window.current.epoch })
                #expect(await eventually { window.savedSessions.map(\.name) == [name] })
                #expect(window.loadingSavedSessionName == nil)
                let initialEpoch = window.current.epoch

                window.loadSavedSession(named: name)
                #expect(window.loadingSavedSessionName == name)
                #expect(await window.waitUntilIdle())
                #expect(await eventually { window.current.epoch != initialEpoch })
                #expect(await eventually {
                    Self.showsRestored(window, prompt: "Hello", name: name) && window.loadingSavedSessionName == nil
                })
                await window.close()
            }
        }
    }

    // MARK: - The loading indicator

    @Test("While the first load waits for the model preload, the window shows the loading indicator over an empty transcript")
    func firstLoadShowsTheIndicatorUntilThePreloadEnds() async throws {
        try await withSupport { workspace in
            let name = try await Self.saveSessionInEarlierRun(workspace: workspace, prompt: "Hello")

            try await Self.withRuntime(workspace: workspace) { runtime, backend in
                let window = try await runtime.openWindow(workspace: workspace)
                #expect(await eventually { window.snapshot != nil })
                let gate = ZenGate()
                await backend.holdPreloads(at: gate)
                let initialEpoch = window.current.epoch

                window.loadSavedSession(named: name)
                #expect(await waitUntil("the first load preloads the model") { await gate.reached })
                // The slot already runs the new incarnation; its log is still empty.
                #expect(await eventually { window.current.epoch != initialEpoch && window.epoch == window.current.epoch })
                #expect(window.transcript.isEmpty)
                #expect(window.loadingSavedSessionName == name)
                #expect(window.isBusy)

                await gate.open()
                #expect(await window.waitUntilIdle())
                #expect(await eventually {
                    Self.showsRestored(window, prompt: "Hello", name: name) && window.loadingSavedSessionName == nil
                })
                await window.close()
            }
        }
    }

    @Test("A load that ends before the window applied the restored snapshot keeps the indicator until it is applied")
    func indicatorWaitsForTheRestoredSnapshot() async throws {
        try await withSupport { workspace in
            let name = try await Self.saveSessionInEarlierRun(workspace: workspace, prompt: "Hello")

            try await Self.withRuntime(workspace: workspace) { runtime, backend in
                let window = try await runtime.openWindow(workspace: workspace)
                #expect(await eventually { window.snapshot != nil })
                let preload = ZenGate()
                await backend.holdPreloads(at: preload)
                let initialEpoch = window.current.epoch

                window.loadSavedSession(named: name)
                #expect(await waitUntil("the load preloads the model") { await preload.reached })
                #expect(await eventually { window.current.epoch != initialEpoch && window.epoch == window.current.epoch })

                // From now on the window applies no snapshot until the test lets it.
                let apply = ZenGate()
                window.snapshotWillApply = { await apply.pass() }
                await preload.open()
                #expect(await window.waitUntilIdle())
                #expect(await waitUntil("a snapshot waits to be applied") { await apply.reached })
                #expect(!window.isBusy)
                #expect(window.transcript.isEmpty)
                #expect(window.loadingSavedSessionName == name)

                window.snapshotWillApply = nil
                await apply.open()
                #expect(await eventually {
                    Self.showsRestored(window, prompt: "Hello", name: name) && window.loadingSavedSessionName == nil
                })
                await window.close()
            }
        }
    }

    @Test("A load that starts while the previous one waits for its snapshot keeps its own indicator")
    func laterLoadReplacesTheWaitingIndicator() async throws {
        try await withSupport { workspace in
            let name = try await Self.saveSessionInEarlierRun(workspace: workspace, prompt: "Hello")

            try await Self.withRuntime(workspace: workspace) { runtime, backend in
                let window = try await runtime.openWindow(workspace: workspace)
                #expect(await eventually { window.snapshot != nil })
                let firstPreload = ZenGate()
                await backend.holdPreloads(at: firstPreload)
                let initialEpoch = window.current.epoch

                // The first load ends while its restored snapshot waits.
                window.loadSavedSession(named: name)
                #expect(await waitUntil("the first load preloads the model") { await firstPreload.reached })
                #expect(await eventually { window.current.epoch != initialEpoch && window.epoch == window.current.epoch })
                let apply = ZenGate()
                window.snapshotWillApply = { await apply.pass() }
                await firstPreload.open()
                #expect(await window.waitUntilIdle())
                #expect(window.loadingSavedSessionName == name)
                let firstLoadEpoch = window.current.epoch

                // The second load waits for its preload; the first one's
                // snapshot, applied now, leaves its indicator alone.
                let secondPreload = ZenGate()
                await backend.holdPreloads(at: secondPreload)
                window.snapshotWillApply = nil
                window.loadSavedSession(named: name)
                await apply.open()
                #expect(await waitUntil("the second load preloads the model") { await secondPreload.reached })
                #expect(await eventually { window.current.epoch != firstLoadEpoch && window.epoch == window.current.epoch })
                #expect(window.transcript.isEmpty)
                #expect(window.loadingSavedSessionName == name)

                await secondPreload.open()
                #expect(await window.waitUntilIdle())
                #expect(await eventually {
                    Self.showsRestored(window, prompt: "Hello", name: name) && window.loadingSavedSessionName == nil
                })
                await window.close()
            }
        }
    }

    @Test("A first load whose preload fails clears the indicator and shows the failure; a second load restores the rows")
    func firstLoadWithAFailedPreload() async throws {
        try await withSupport { workspace in
            let name = try await Self.saveSessionInEarlierRun(workspace: workspace, prompt: "Hello")

            try await Self.withRuntime(workspace: workspace) { runtime, backend in
                let window = try await runtime.openWindow(workspace: workspace)
                #expect(await eventually { window.snapshot != nil })
                await backend.failNextPreloads(1)
                let initialEpoch = window.current.epoch

                window.loadSavedSession(named: name)
                #expect(window.loadingSavedSessionName == name)
                #expect(await window.waitUntilIdle())
                #expect(await eventually { window.current.epoch != initialEpoch && window.epoch == window.current.epoch })
                #expect(await eventually {
                    window.loadingSavedSessionName == nil
                        && window.transcript.last?.content == .local(text: "Scripted preload failure", isFailure: true)
                })
                #expect(!window.transcript.contains {
                    $0.content == .userPrompt(text: "Hello", attachments: [], origin: .unknown)
                })

                let failedEpoch = window.current.epoch
                window.loadSavedSession(named: name)
                #expect(await window.waitUntilIdle())
                #expect(await eventually { window.current.epoch != failedEpoch })
                #expect(await eventually {
                    Self.showsRestored(window, prompt: "Hello", name: name) && window.loadingSavedSessionName == nil
                })
                await window.close()
            }
        }
    }

    @Test("A load of a saved session that does not exist clears the indicator and shows the failure")
    func loadOfAMissingSession() async throws {
        try await withSupport { workspace in
            try await Self.withRuntime(workspace: workspace) { runtime, _ in
                let window = try await runtime.openWindow(workspace: workspace)
                #expect(await eventually { window.snapshot != nil })
                let epoch = window.current.epoch

                window.loadSavedSession(named: "missing-session")
                #expect(window.loadingSavedSessionName == "missing-session")
                #expect(await window.waitUntilIdle())
                #expect(await eventually {
                    window.loadingSavedSessionName == nil && window.transcript.last?.content == .local(
                        text: "ZenCODE: saved session 'missing-session' not found.",
                        isFailure: true
                    )
                })
                #expect(window.current.epoch == epoch)
                await window.close()
            }
        }
    }

    @Test("A load refused while the window is busy never shows the indicator")
    func loadRefusedWhileBusy() async throws {
        try await withSupport { workspace in
            let name = try await Self.saveSessionInEarlierRun(workspace: workspace, prompt: "Hello")

            try await Self.withRuntime(workspace: workspace) { runtime, backend in
                let window = try await runtime.openWindow(workspace: workspace)
                #expect(await eventually { window.savedSessions.map(\.name) == [name] })
                await backend.hold()
                window.draft = "Busy"
                window.submitDraft()
                #expect(await backend.waitUntilHeld())
                #expect(window.isBusy)
                let epoch = window.current.epoch

                window.loadSavedSession(named: name)
                #expect(window.loadingSavedSessionName == nil)
                #expect(window.transcript.last?.content == .local(
                    text: "ZenCODE: command '/sessions' is unavailable while a prompt is running.",
                    isFailure: true
                ))

                await backend.release()
                #expect(await window.waitUntilIdle())
                #expect(window.loadingSavedSessionName == nil)
                #expect(window.current.epoch == epoch)
                await window.close()
            }
        }
    }

    // MARK: - Helpers

    /// The window shows the restored prompt and its answer, and the saved
    /// session's name as its name and title, on the incarnation it follows.
    private static func showsRestored(_ window: ZenWindowSession, prompt: String, name: String) -> Bool {
        window.epoch == window.current.epoch
            && window.snapshot?.epoch == window.current.epoch
            && window.transcript.contains { $0.content == .userPrompt(text: prompt, attachments: [], origin: .unknown) }
            && window.transcript.contains { $0.content == .assistantText("Scripted answer to \(prompt)", isStreaming: false) }
            && window.currentSavedSessionName == name
            && window.sessionTitle == name
    }

    /// An earlier run: a runtime, a window that sends `prompt` and saves,
    /// then the shutdown. Returns the saved session's name.
    private static func saveSessionInEarlierRun(workspace: URL, prompt: String) async throws -> String {
        var savedName: String?
        try await withRuntime(workspace: workspace) { runtime, _ in
            let window = try await runtime.openWindow(workspace: workspace)
            window.draft = prompt
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            window.saveSession()
            #expect(await window.waitUntilIdle())
            let deadline = ContinuousClock.now + zenTestDeadline
            while window.currentSavedSessionName == nil, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(10))
            }
            savedName = window.currentSavedSessionName
            await window.close()
        }
        let name = try #require(savedName)
        let onDisk = try TerminalSessionStore.savedSessions(for: workspace)
        #expect(onDisk.map(\.name) == [name])
        return name
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

    /// A temporary support directory and workspace, shared by every runtime
    /// `body` composes.
    private func withSupport(
        _ body: @escaping @MainActor @Sendable (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-first-load-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The support directory is task-local: everything below runs in this
        // task and the tasks it creates.
        try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable in
            try await body(workspace)
        }
    }

    /// A runtime over a new scripted backend and a hosted configuration,
    /// shut down after `body`.
    private static func withRuntime(
        workspace: URL,
        _ body: @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend) async throws -> Void
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
            try await body(runtime, backend)
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
    }
}
