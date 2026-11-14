//
//  DS4EngineCheckpointSessionTests.swift
//  ZenCODE
//
//  The explicit-save contract through `TerminalChat`: a DS4 KV checkpoint is
//  written only by `saveCurrentSession(named:)` (`/sessions save`,
//  `/sessions <name>`), read only by `loadSavedSession`, removed with the
//  session, and the user is told what happened.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

@ChatSessionActor
@Suite("DS4 engine checkpoint session commands", .serialized)
struct DS4EngineCheckpointSessionTests {
    private struct Environment {
        let root: URL
        let workspace: URL
        let support: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("zencode-ds4-checkpoint-chat-\(UUID().uuidString)", isDirectory: true)
            workspace = root.appendingPathComponent("workspace", isDirectory: true)
            support = root.appendingPathComponent("support", isDirectory: true)
            try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }

        func configuration() throws -> AgentConfiguration {
            try AgentConfiguration(
                hostedModelID: "test-model",
                availableAgents: AgentProfileStore.defaultProfiles(),
                availableModels: [AgentSettingsModelManifest(
                    id: "test-model", kind: .remoteAPI, modelID: "local/test-model"
                )],
                workingDirectory: workspace
            )
        }

        func runner(backend: any AgentRuntimeBackend) -> AgentCoreSessionRunner {
            AgentCoreSessionRunner(
                backendFactory: { _, _ in backend },
                taskGraphStore: SessionTaskGraphStore(supportDirectoryURL: support)
            )
        }

        /// The chat writes to a capturing renderer, never to the test's output.
        @ChatSessionActor
        func chat(runner: AgentCoreSessionRunner) throws -> TerminalChat {
            TerminalChat(
                configuration: try configuration(), stdinIsTerminal: false, sessionRunner: runner,
                telegramTransportFactory: nil,
                renderCoordinator: TerminalChatRenderCoordinator(
                    stdinIsTerminal: false, standardOutput: nil, standardError: nil,
                    standardOutputIsTerminal: false, standardErrorIsTerminal: false,
                    cursorTopology: .separate,
                    capturesWrites: true, streamingFlushDelay: nil, columnWidthProvider: { 100 }
                )
            )
        }

        func checkpointURL(_ name: String) -> URL {
            TerminalSessionStore.engineCheckpointURL(name: name, workingDirectory: workspace)
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
            try await Task(name: "ZenCODE.Tests.ds4-engine-checkpoint") { @ChatSessionActor in
                try await body(environment)
            }.value
        }
    }

    /// Creates the chat session and resolves the backend, as a launched chat
    /// does (the runner hydrates the backend session on the first preload).
    private static func start(_ chat: TerminalChat) async throws {
        try await chat.createCurrentSession(discoverExternalTools: false)
        _ = try await chat.preloadCurrentModel(emitStatus: false)
    }

    private static func finish(_ chat: TerminalChat, _ runner: AgentCoreSessionRunner) async {
        await chat.stopTaskGraphObserver()
        await runner.shutdown()
    }

    // MARK: - Save

    // MARK: - Delete

    @Test
    nonisolated func deletingASavedSessionRemovesItsCheckpoint() async throws {
        try await withEnvironment { environment in
            let harness = try DS4ClientHarness(contextSize: 200_000)
            harness.mock.enqueueGeneration(["Hello."])
            let client = try await harness.makeClient(sessionID: "unused")
            let runner = environment.runner(backend: client)
            let chat = try environment.chat(runner: runner)
            try await Self.start(chat)
            _ = try await client.sendPrompt(
                sessionID: chat.sessionID, prompt: "hello", attachments: [], onEvent: { _ in }
            )
            await chat.saveCurrentSession(named: "to delete")
            let checkpoint = environment.checkpointURL("to delete")
            #expect(FileManager.default.fileExists(atPath: checkpoint.path))

            let deleted = try TerminalSessionStore.delete(name: "to delete", workingDirectory: environment.workspace)

            #expect(deleted)
            #expect(!FileManager.default.fileExists(atPath: checkpoint.path))
            #expect(ds4CheckpointFiles(in: environment.root).isEmpty)
            await Self.finish(chat, runner)
        }
    }

    // MARK: - Load

    /// The chain of the terminal with a round that calls two tools: the next
    /// prompt, and the first prompt after the session is saved and loaded
    /// again, evaluate only what is new. The loaded session renders the
    /// prompt its checkpoint holds: same system prompt, same turns.
    @Test
    nonisolated func promptsAfterAToolRoundAndAfterLoadingTheSavedSessionReuseTheKV() async throws {
        try await withEnvironment { environment in
            let harness = try DS4ClientHarness(contextSize: 200_000)
            let twoCalls = "\n\n<｜DSML｜ calls>\n"
                + ["one", "two"].map { text in
                    "<｜DSML｜ invoke name=\"\(DS4ClientHarness.toolName)\">\n"
                        + "<｜DSML｜ parameter name=\"text\" string=\"true\">\(text)</｜DSML｜ parameter>\n"
                        + "</｜DSML｜ invoke>\n"
                }.joined()
                + "</｜DSML｜ calls>"
            harness.mock.enqueueGeneration(["Reasoning", "</think>", "Checking.", twoCalls])
            harness.mock.enqueueGeneration(["More reasoning", "</think>", "Done."])
            harness.mock.enqueueGeneration(["Thinking again", "</think>", "Second answer."])
            harness.mock.enqueueGeneration(["Thinking more", "</think>", "Third answer."])
            let client = try await harness.makeClient(sessionID: "unused")
            let runner = environment.runner(backend: client)
            let chat = try environment.chat(runner: runner)
            try await Self.start(chat)
            func prompt(_ text: String) async throws {
                _ = try await chat.generateResponse(attempt: TerminalPromptAttempt(
                    prompt: text, attachments: [], origin: .local,
                    locksResponseLanguage: true, purpose: .normal
                ))
            }
            /// Tokens the session held after sync `index` and its generation.
            func position(afterSync index: Int) -> Int {
                let sync = harness.engine.syncs[index]
                return sync.cached + sync.suffix + harness.engine.results[index].tokens.count
            }

            try await prompt("First question")
            try await prompt("Second question")
            try #require(harness.engine.syncs.count == 3)
            #expect(harness.engine.syncs[1].cached == position(afterSync: 0))
            #expect(harness.engine.syncs[2].cached == position(afterSync: 1))

            await chat.saveCurrentSession(named: "kv")
            let saved = try TerminalSessionStore.load(name: "kv", workingDirectory: environment.workspace)
            // One assistant message for the round, as the backend holds it.
            #expect(saved.history.map(\.role) == [.user, .assistant, .tool, .tool, .assistant, .user, .assistant])
            try await chat.loadSavedSession(saved)
            let checkpoint = environment.checkpointURL("kv")
            #expect(harness.mock.checkpointCalls == [
                .saveCheckpoint(sessionID: saved.sessionID, url: checkpoint),
                .loadCheckpoint(sessionID: saved.sessionID, url: checkpoint),
            ])
            try await prompt("Third question")

            try #require(harness.engine.syncs.count == 4)
            #expect(harness.engine.syncs[3].cached == position(afterSync: 2))
            await Self.finish(chat, runner)
        }
    }
}
