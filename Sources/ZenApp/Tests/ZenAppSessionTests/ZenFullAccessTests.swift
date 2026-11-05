//
//  ZenFullAccessTests.swift
//  ZenAppSessionTests
//
//  The app's Full Access mode (the terminal's Ctrl+G): one runner-wide mode
//  that every open window shows in its status bar and in a message row.
//

import Foundation
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

@MainActor
@Suite(.serialized)
struct ZenFullAccessTests {
    private static let fullAccessText = "Mode: full access — local.exec commands run without approval.\n"
    private static let defaultText = "Mode: default — local.exec approvals restored.\n"

    @Test("A toggle reaches every open window: its status and a message row in each; toggling back restores")
    func aToggleReachesEveryWindow() async throws {
        try await withRuntime { runtime, _, workspace in
            #expect(runtime.localExecAccessMode == .standard)
            let first = try await runtime.openWindow(workspace: workspace)
            let second = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { first.snapshot != nil && second.snapshot != nil })
            for window in [first, second] {
                #expect(window.status.localExecAccessMode == .standard)
                #expect(!window.isFullAccess)
                #expect(Self.modeRows(in: window).isEmpty)
            }
            let observed = ZenObservationCounter { _ = first.isFullAccess }

            first.toggleFullAccess()
            await runtime.waitForAccessModeToggles()

            #expect(runtime.localExecAccessMode == .fullAccess)
            #expect(await runtime.runner.localExecAccessMode() == .fullAccess)
            #expect(await eventually { observed.count > 0 })
            for window in [first, second] {
                #expect(window.isFullAccess)
                #expect(window.status.localExecAccessMode == .fullAccess)
                #expect(Self.modeRows(in: window) == [Self.fullAccessText])
            }

            // Back from the other window: every window again.
            second.toggleFullAccess()
            await runtime.waitForAccessModeToggles()

            #expect(runtime.localExecAccessMode == .standard)
            #expect(await runtime.runner.localExecAccessMode() == .standard)
            for window in [first, second] {
                #expect(!window.isFullAccess)
                #expect(window.status.localExecAccessMode == .standard)
                #expect(Self.modeRows(in: window) == [Self.fullAccessText, Self.defaultText])
            }
        }
    }

    @Test("A window opened after a toggle starts in the current mode, without a message row")
    func aLaterWindowInheritsTheMode() async throws {
        try await withRuntime { runtime, _, workspace in
            let first = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { first.snapshot != nil })
            first.toggleFullAccess()
            await runtime.waitForAccessModeToggles()
            #expect(runtime.localExecAccessMode == .fullAccess)

            let later = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { later.snapshot != nil })
            #expect(later.status.localExecAccessMode == .fullAccess)
            #expect(later.isFullAccess)
            #expect(Self.modeRows(in: later).isEmpty)
            #expect(Self.modeRows(in: first) == [Self.fullAccessText])
        }
    }

    @Test("Two quick toggles apply in order and end in the default mode, as the runner")
    func twoQuickTogglesApplyInOrder() async throws {
        try await withRuntime { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })

            window.toggleFullAccess()
            window.toggleFullAccess()
            await runtime.waitForAccessModeToggles()

            #expect(runtime.localExecAccessMode == .standard)
            #expect(await runtime.runner.localExecAccessMode() == runtime.localExecAccessMode)
            #expect(window.status.localExecAccessMode == .standard)
            #expect(Self.modeRows(in: window) == [Self.fullAccessText, Self.defaultText])
        }
    }

    @Test("A closed window and a runtime that shut down toggle nothing")
    func noToggleAfterCloseOrShutdown() async throws {
        try await withRuntime { runtime, _, workspace in
            let closing = try await runtime.openWindow(workspace: workspace)
            await closing.close()
            closing.toggleFullAccess()
            await runtime.waitForAccessModeToggles()
            #expect(runtime.localExecAccessMode == .standard)
            #expect(await runtime.runner.localExecAccessMode() == .standard)

            await runtime.shutdown()
            runtime.toggleLocalExecAccessMode()
            await runtime.waitForAccessModeToggles()
            #expect(runtime.localExecAccessMode == .standard)
            #expect(await runtime.runner.localExecAccessMode() == .standard)
        }
    }

    // MARK: - Helpers

    /// The texts of the window's access-mode message rows, in order; each is
    /// a system row, never a failure.
    private static func modeRows(in window: ZenWindowSession) -> [String] {
        window.transcript.compactMap { item in
            guard case let .local(text, isFailure) = item.content,
                  text == fullAccessText || text == defaultText else {
                return nil
            }
            #expect(!isFailure)
            return text
        }
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
    /// temporary support directory and workspace.
    private func withRuntime(
        _ body: @escaping @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-full-access-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The support directory is task-local: everything below runs in this
        // task and the tasks it creates.
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
