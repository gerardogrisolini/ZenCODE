//
//  ZenWindowStatusModelTests.swift
//  ZenAppSessionTests
//
//  The model and the context window of the status bar before a turn reports
//  its own: the rule that picks the window to show, and a window over a
//  scripted backend whose model has a provider id other than its manifest id
//  and a configured window limit, as the terminal's status bar shows it
//  (`0.0k/<max>` from the start).
//

import Foundation
import Testing
import ToolCore
import ZenCODECore
@testable import ZenAppSession

@MainActor
@Suite("Window status model")
struct ZenWindowStatusModelTests {
    private static let reported = DirectAgentContextWindowStatus(
        usedTokens: 42_000,
        maxTokens: 200_000,
        modelID: "provider-status-model",
        isApproximate: false
    )
    private static let configured = DirectAgentContextWindowStatus(
        usedTokens: nil,
        maxTokens: 1_048_576,
        modelID: "provider-status-model",
        isApproximate: true
    )

    // MARK: - The window shown

    @Test("The window of the snapshot wins; without one the configured window shows; with neither there is none")
    func displayedContextWindow() {
        #expect(
            ZenWindowSession.displayedContextWindow(snapshot: Self.reported, configured: Self.configured)
                == Self.reported
        )
        #expect(
            ZenWindowSession.displayedContextWindow(snapshot: Self.reported, configured: nil)
                == Self.reported
        )
        #expect(
            ZenWindowSession.displayedContextWindow(snapshot: nil, configured: Self.configured)
                == Self.configured
        )
        #expect(ZenWindowSession.displayedContextWindow(snapshot: nil, configured: nil) == nil)
    }

    // MARK: - A window

    @Test("At the start the status names the model by its provider id and shows the configured window, which a turn that reports none leaves")
    func configuredWindowAtStart() async throws {
        try await withRuntime(limit: 1_048_576) { runtime, backend, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(await window.waitUntilIdle())
            #expect(window.status.modelID == "provider-status-model")
            #expect(window.status.modelID != Self.manifestID)
            let contextWindow = try #require(window.status.contextWindow)
            #expect(contextWindow.usedTokens == nil)
            #expect(contextWindow.maxTokens == 1_048_576)
            #expect(contextWindow.modelID == "provider-status-model")
            #expect(contextWindow.isApproximate)
            #expect(window.status.contextWindow == window.configuredContextWindow)
            #expect(window.lastSnapshotContextWindow == nil)

            // The scripted backend reports no window: the configured one stays.
            window.draft = "Hello"
            window.submitDraft()
            #expect(await window.waitUntilIdle())
            #expect(await backend.prompts.contains { $0.contains("Hello") })
            #expect(window.status.modelID == "provider-status-model")
            #expect(window.status.contextWindow?.maxTokens == 1_048_576)
        }
    }

    @Test("A refresh of the status facts keeps the window of the snapshot, and shows the configured one again when the snapshot has none")
    func refreshFollowsTheRule() async throws {
        try await withRuntime(limit: 1_048_576) { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(await window.waitUntilIdle())
            #expect(window.status.contextWindow?.maxTokens == 1_048_576)

            window.lastSnapshotContextWindow = Self.reported
            await window.refreshStatus()
            #expect(window.status.contextWindow == Self.reported)
            #expect(window.configuredContextWindow?.maxTokens == 1_048_576)

            window.lastSnapshotContextWindow = nil
            await window.refreshStatus()
            #expect(window.status.contextWindow == window.configuredContextWindow)
            #expect(window.status.contextWindow?.maxTokens == 1_048_576)
        }
    }

    @Test("Without a configured limit the status names the model and shows no window")
    func noLimitNoWindow() async throws {
        try await withRuntime(limit: nil) { runtime, _, workspace in
            let window = try await runtime.openWindow(workspace: workspace)
            #expect(await eventually { window.snapshot != nil })
            #expect(await window.waitUntilIdle())
            #expect(window.status.modelID == "provider-status-model")
            #expect(window.status.contextWindow == nil)
            #expect(window.configuredContextWindow == nil)
        }
    }

    // MARK: - Fixtures

    /// The id of the model in the manifest, which differs from its provider id.
    private nonisolated static let manifestID = "zen-app-status-model"

    private nonisolated static func model(limit: Int?) -> AgentSettingsModelManifest {
        AgentSettingsModelManifest(
            id: manifestID,
            kind: .remoteAPI,
            modelID: "provider-status-model",
            provider: AgentRemoteProvider(
                name: "remote-server",
                baseURL: "http://127.0.0.1",
                modelID: "provider-status-model"
            ),
            configuredContextWindowLimit: limit
        )
    }

    private func eventually(_ condition: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + zenTestDeadline
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    /// A runtime over the scripted backend and a hosted configuration whose
    /// model has `limit` as its window, in a temporary support directory and
    /// workspace (named by UUIDs, so nothing reads the real settings).
    private func withRuntime(
        limit: Int?,
        _ body: @escaping @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zen-app-status-model-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        let workspace = root.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The support directory is task-local: everything below runs in this
        // task and the tasks it creates.
        try await AppStorageDirectory.withSupportDirectoryURL(support) { @Sendable in
            let model = Self.model(limit: limit)
            try AgentSettingsManifestStore.save(
                AgentSettingsManifest(models: [model], selectedModelID: model.id),
                to: AgentSettingsManifestStore.settingsURL()
            )
            try await Self.compose(workspace: workspace, model: model, body: body)
        }
    }

    private static func compose(
        workspace: URL,
        model: AgentSettingsModelManifest,
        body: @MainActor @Sendable (ZenAppRuntime, ZenScriptedBackend, URL) async throws -> Void
    ) async throws {
        let configuration = try AgentConfiguration(
            hostedModelID: model.id,
            availableAgents: AgentProfileStore.defaultProfiles(),
            availableModels: [model],
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
