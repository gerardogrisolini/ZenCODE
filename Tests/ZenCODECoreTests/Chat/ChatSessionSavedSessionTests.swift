//
//  ChatSessionSavedSessionTests.swift
//  ZenCODE
//
//  Saved-session operations of the shared controller through the terminal
//  chat: a `.session` file written in the current format before the session
//  operations moved to `ChatSessionController` still lists and loads, and
//  deleting a saved session also removes its `sessions.json` index entry.
//

import Foundation
import Testing
@testable import ZenCODECore

@ChatSessionActor
@Suite("Saved-session operations", .serialized)
struct ChatSessionSavedSessionTests {
    private struct Environment {
        let root: URL
        let workspace: URL
        let support: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-saved-sessions-\(UUID().uuidString)", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            support = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        var workspacePath: String {
            URL(fileURLWithPath: workspace.path).standardizedFileURL.path
        }

        func runner() -> AgentCoreSessionRunner {
            let backend = CapturingACPBackend()
            return AgentCoreSessionRunner(
                backendFactory: { _, _ in backend },
                taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: support)
            )
        }

        @ChatSessionActor
        func chat(runner: AgentCoreSessionRunner) throws -> TerminalChat {
            TerminalChat(
                configuration: try AgentConfiguration(
                    hostedModelID: "test-model",
                    availableAgents: AgentProfileStore.defaultProfiles(),
                    availableModels: [AgentSettingsModelManifest(
                        id: "test-model", kind: .remoteAPI, modelID: "local/test-model"
                    )],
                    workingDirectory: workspace
                ),
                stdinIsTerminal: false,
                sessionRunner: runner
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
            try await Task(name: "ZenCODE.Tests.saved-session-operations") { @ChatSessionActor in
                try await body(environment)
            }.value
        }
    }

    // MARK: - Index

    @Test
    nonisolated func deletingASavedSessionRemovesItsIndexEntry() async throws {
        try await withEnvironment { environment in
            let runner = environment.runner()
            let chat = try environment.chat(runner: runner)
            try await chat.createCurrentSession(discoverExternalTools: false)
            _ = try await chat.preloadCurrentModel(emitStatus: false)
            await chat.saveCurrentSession(named: "indexed")
            #expect(SavedSessionsStore().sessions().map(\.sessionName) == ["indexed"])

            let outcome = try await chat.chatSession.deleteSavedSessions(names: ["indexed"])

            #expect(outcome.notices == [.sessionDeleted(name: "indexed")])
            #expect(chat.activeSavedSessionName == nil)
            #expect(try TerminalSessionStore.savedSessions(for: environment.workspace).isEmpty)
            #expect(SavedSessionsStore().sessions().isEmpty)

            await chat.stopTaskGraphObserver()
            await runner.shutdown()
        }
    }

    // MARK: - Fixtures
}
