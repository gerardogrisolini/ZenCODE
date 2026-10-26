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

@TerminalChatActor
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

        @TerminalChatActor
        func chat(runner: AgentCoreSessionRunner) throws -> TerminalChat {
            TerminalChat(configuration: try configuration(), stdinIsTerminal: false, sessionRunner: runner)
        }

        func checkpointURL(_ name: String) -> URL {
            TerminalSessionStore.engineCheckpointURL(name: name, workingDirectory: workspace)
        }
    }

    /// Runs `body` on the chat actor with a private support directory (never
    /// the real `~/.zencode`) and a UUID-named temporary workspace.
    private nonisolated func withEnvironment(
        _ body: @escaping @Sendable @TerminalChatActor (Environment) async throws -> Void
    ) async throws {
        let environment = try Environment()
        defer { environment.remove() }
        try await AppStorageDirectory.withSupportDirectoryURL(environment.support) {
            try await Task(name: "ZenCODE.Tests.ds4-engine-checkpoint") { @TerminalChatActor in
                try await body(environment)
            }.value
        }
    }

    /// Output of `body` (system and failure messages of the chat).
    private static func captureOutput(
        of chat: TerminalChat,
        _ body: () async throws -> Void
    ) async rethrows -> String {
        chat.telegramImmediateCommandOutput = []
        defer { chat.telegramImmediateCommandOutput = nil }
        try await body()
        return chat.telegramImmediateCommandOutput?.joined() ?? ""
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

    @Test
    nonisolated func theCheckpointIsWrittenOnlyByTheExplicitSave() async throws {
        try await withEnvironment { environment in
            let harness = try DS4ClientHarness(contextSize: 200_000)
            harness.mock.enqueueGeneration(["Reasoning", "</think>", "Answer."])
            let client = try await harness.makeClient(sessionID: "unused", thinkingSelection: nil)
            let runner = environment.runner(backend: client)
            let chat = try environment.chat(runner: runner)
            try await Self.start(chat)
            _ = try await MemoryTurnContext.$currentTurnMemoryBlock.withValue("MEMORY BLOCK") {
                try await client.sendPrompt(
                    sessionID: chat.sessionID, prompt: "first", attachments: [], onEvent: { _ in }
                )
            }
            let checkpoint = environment.checkpointURL("ds4 chat")

            // A finished generation leaves nothing on disk.
            #expect(harness.mock.checkpointCalls.isEmpty)
            #expect(ds4CheckpointFiles(in: environment.root).isEmpty)

            let output = await Self.captureOutput(of: chat) {
                await chat.handleSessionsCommand("/sessions ds4 chat")
            }

            #expect(output.contains("Saved session: ds4 chat"))
            #expect(output.contains("Saved DS4 KV checkpoint"))
            #expect(FileManager.default.fileExists(atPath: checkpoint.path))
            #expect(harness.mock.checkpointCalls == [.saveCheckpoint(sessionID: chat.sessionID, url: checkpoint)])
            let saved = try TerminalSessionStore.load(name: "ds4 chat", workingDirectory: environment.workspace)
            #expect(saved.sessionID == chat.sessionID)
            #expect(ds4CheckpointFiles(in: environment.root).count == 1)

            // Closing the session and shutting down add nothing.
            await Self.finish(chat, runner)
            #expect(harness.mock.checkpointCalls.count == 1)
        }
    }

    @Test
    nonisolated func saveActiveSessionAlsoSavesTheCheckpoint() async throws {
        try await withEnvironment { environment in
            let harness = try DS4ClientHarness(contextSize: 200_000)
            harness.mock.enqueueGeneration(["Hello."])
            let client = try await harness.makeClient(sessionID: "unused")
            let runner = environment.runner(backend: client)
            let chat = try environment.chat(runner: runner)
            try await Self.start(chat)
            _ = try await client.sendPrompt(
                sessionID: chat.sessionID, prompt: "hello there", attachments: [], onEvent: { _ in }
            )
            chat.activeSavedSessionName = "known name"

            let output = await Self.captureOutput(of: chat) {
                await chat.handleSessionsCommand("/sessions save")
            }

            #expect(output.contains("Saved DS4 KV checkpoint"))
            #expect(FileManager.default.fileExists(atPath: environment.checkpointURL("known name").path))
            await Self.finish(chat, runner)
        }
    }

    @Test
    nonisolated func saveWithImagesSkipsTheCheckpointAndRemovesAStaleOne() async throws {
        try await withEnvironment { environment in
            let harness = try DS4ClientHarness(contextSize: 200_000, hasVision: true, visionRelativePath: "vision.gguf")
            harness.mock.enqueueGeneration(["seen"])
            let client = try await harness.makeClient(sessionID: "unused")
            let runner = environment.runner(backend: client)
            let chat = try environment.chat(runner: runner)
            try await Self.start(chat)
            _ = try await client.sendPrompt(
                sessionID: chat.sessionID,
                prompt: "Look",
                attachments: [RemoteGenerationClientDS4EngineTests.pngAttachment],
                onEvent: { _ in }
            )
            // A checkpoint left by an earlier save of the same name.
            let checkpoint = environment.checkpointURL("with images")
            try FileManager.default.createDirectory(
                at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("stale".utf8).write(to: checkpoint)

            let output = await Self.captureOutput(of: chat) {
                await chat.saveCurrentSession(named: "with images")
            }

            #expect(output.contains("Saved session: with images"))
            #expect(output.contains("KV checkpoint skipped: session contains images"))
            #expect(!output.contains("Saved DS4 KV checkpoint"))
            #expect(!FileManager.default.fileExists(atPath: checkpoint.path))
            #expect(harness.mock.checkpointCalls.isEmpty)
            #expect(FileManager.default.fileExists(atPath: TerminalSessionStore.sessionFileURL(
                name: "with images", workingDirectory: environment.workspace
            ).path))
            await Self.finish(chat, runner)
        }
    }

    @Test
    nonisolated func saveWithoutLiveStateSkipsWithoutOpeningTheModel() async throws {
        try await withEnvironment { environment in
            let harness = try DS4ClientHarness(contextSize: 200_000)
            let client = try await harness.makeClient(sessionID: "unused")
            let runner = environment.runner(backend: client)
            let chat = try environment.chat(runner: runner)
            try await Self.start(chat)
            let opensAfterStart = harness.openCount

            let output = await Self.captureOutput(of: chat) {
                await chat.saveCurrentSession(named: "fresh")
            }

            #expect(output.contains("Saved session: fresh"))
            #expect(output.contains("DS4 KV checkpoint skipped: no live DS4 state for this session"))
            #expect(!FileManager.default.fileExists(atPath: environment.checkpointURL("fresh").path))
            // Only the startup preload opened the model; the save evaluated nothing.
            #expect(harness.openCount == opensAfterStart)
            #expect(harness.engine.syncs.isEmpty)
            #expect(harness.mock.checkpointCalls.isEmpty)
            await Self.finish(chat, runner)
        }
    }

    @Test
    nonisolated func saveWithAModelWithoutAnEngineIsSilentAndRemovesAStaleCheckpoint() async throws {
        try await withEnvironment { environment in
            let runner = environment.runner(backend: CapturingACPBackend())
            let chat = try environment.chat(runner: runner)
            try await Self.start(chat)
            let checkpoint = environment.checkpointURL("remote")
            try FileManager.default.createDirectory(
                at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("stale".utf8).write(to: checkpoint)

            let output = await Self.captureOutput(of: chat) {
                await chat.saveCurrentSession(named: "remote")
            }

            #expect(output.contains("Saved session: remote"))
            #expect(!output.localizedCaseInsensitiveContains("checkpoint"))
            #expect(!FileManager.default.fileExists(atPath: checkpoint.path))
            await Self.finish(chat, runner)
        }
    }

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

    @Test
    nonisolated func loadingASavedSessionRestoresTheCheckpointAndTheRenderedPrompt() async throws {
        try await withEnvironment { environment in
            let harness = try DS4ClientHarness(contextSize: 200_000)
            harness.mock.enqueueGeneration(["Reasoning", "</think>", "Answer."])
            harness.mock.enqueueGeneration(["Second answer."])
            let client = try await harness.makeClient(sessionID: "unused", thinkingSelection: nil)
            let runner = environment.runner(backend: client)
            let chat = try environment.chat(runner: runner)
            try await Self.start(chat)
            let originalSessionID = chat.sessionID
            _ = try await MemoryTurnContext.$currentTurnMemoryBlock.withValue("MEMORY BLOCK") {
                try await client.sendPrompt(
                    sessionID: originalSessionID, prompt: "first", attachments: [], onEvent: { _ in }
                )
            }
            await chat.saveCurrentSession(named: "resume me")
            let checkpoint = environment.checkpointURL("resume me")
            #expect(FileManager.default.fileExists(atPath: checkpoint.path))
            await Self.finish(chat, runner)
            await client.closeSession(id: originalSessionID)

            // Later, in a new process: a new client, runner and chat.
            let restoredClient = try await harness.makeClient(sessionID: "unused-2", thinkingSelection: nil)
            let restoredRunner = environment.runner(backend: restoredClient)
            let restoredChat = try environment.chat(runner: restoredRunner)
            let saved = try TerminalSessionStore.load(name: "resume me", workingDirectory: environment.workspace)
            let loadsBefore = harness.mock.checkpointCalls.count

            let output = try await Self.captureOutput(of: restoredChat) {
                try await restoredChat.loadSavedSession(saved)
            }

            #expect(output.contains("Loaded session: resume me"))
            #expect(output.contains("Restored DS4 KV checkpoint"))
            #expect(harness.mock.checkpointCalls.count == loadsBefore + 1)
            #expect(harness.mock.checkpointCalls.last
                == .loadCheckpoint(sessionID: saved.sessionID, url: checkpoint))
            #expect(restoredChat.sessionID == saved.sessionID)

            _ = try await restoredClient.sendPrompt(
                sessionID: restoredChat.sessionID, prompt: "second", attachments: [], onEvent: { _ in }
            )
            let transcripts = harness.engine.transcripts
            let second = try #require(transcripts.last)
            // The restored turns render as before the save (memory block and the
            // exact token ids of the reply).
            let generated = try #require(harness.engine.results.first).tokens
            #expect(second.contains(.message(role: "user", content: "first\n\nMEMORY BLOCK")))
            #expect(second.contains(.tokens(generated)))
            #expect((harness.engine.syncs.last?.cached ?? 0) > 0)
            await Self.finish(restoredChat, restoredRunner)
        }
    }

    @Test
    nonisolated func loadingWithoutACheckpointFileDoesNotTouchTheEngine() async throws {
        try await withEnvironment { environment in
            let harness = try DS4ClientHarness(contextSize: 200_000)
            let client = try await harness.makeClient(sessionID: "unused")
            let runner = environment.runner(backend: client)
            let chat = try environment.chat(runner: runner)
            let history = [AgentRuntimeMessage(role: .user, content: "old question")]
            let saved = TerminalSavedSession(
                name: "plain", sessionID: "terminal-plain", cacheKey: nil,
                workingDirectoryPath: environment.workspace.path, createdAt: Date(), savedAt: Date(),
                modelID: "test-model", agentID: nil, agentName: nil, selectedTools: [],
                selectedSkillIDs: [], thinkingSelection: nil, systemPrompt: "Test",
                history: history,
                checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: "terminal-plain")
            )

            let output = try await Self.captureOutput(of: chat) {
                try await chat.loadSavedSession(saved)
            }

            #expect(output.contains("Loaded session: plain"))
            #expect(!output.localizedCaseInsensitiveContains("checkpoint"))
            #expect(harness.mock.checkpointCalls.isEmpty)
            await Self.finish(chat, runner)
        }
    }

    @Test
    nonisolated func loadingAnIncompatibleCheckpointExplainsAndKeepsTheSession() async throws {
        try await withEnvironment { environment in
            let harness = try DS4ClientHarness(contextSize: 200_000)
            let client = try await harness.makeClient(sessionID: "unused")
            let runner = environment.runner(backend: client)
            let chat = try environment.chat(runner: runner)
            let history = [AgentRuntimeMessage(role: .user, content: "old question")]
            let saved = TerminalSavedSession(
                name: "other model", sessionID: "terminal-other", cacheKey: nil,
                workingDirectoryPath: environment.workspace.path, createdAt: Date(), savedAt: Date(),
                modelID: "test-model", agentID: nil, agentName: nil, selectedTools: [],
                selectedSkillIDs: [], thinkingSelection: nil, systemPrompt: "Test",
                history: history,
                checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: "terminal-other")
            )
            _ = try TerminalSessionStore.save(saved)
            let checkpoint = environment.checkpointURL("other model")
            try Data("a cache of another model".utf8).write(to: checkpoint)

            let output = try await Self.captureOutput(of: chat) {
                try await chat.loadSavedSession(saved)
            }

            #expect(output.contains("DS4 checkpoint not compatible, the prompt will be re-evaluated"))
            #expect(output.contains("Loaded session: other model"))
            #expect(!output.contains("Restored DS4 KV checkpoint"))
            #expect(chat.sessionID == "terminal-other")
            await Self.finish(chat, runner)
        }
    }

    @Test
    nonisolated func loadingWithAModelWithoutAnEngineIgnoresTheCheckpoint() async throws {
        try await withEnvironment { environment in
            let runner = environment.runner(backend: CapturingACPBackend())
            let chat = try environment.chat(runner: runner)
            let history = [AgentRuntimeMessage(role: .user, content: "old question")]
            let saved = TerminalSavedSession(
                name: "remote now", sessionID: "terminal-remote", cacheKey: nil,
                workingDirectoryPath: environment.workspace.path, createdAt: Date(), savedAt: Date(),
                modelID: "test-model", agentID: nil, agentName: nil, selectedTools: [],
                selectedSkillIDs: [], thinkingSelection: nil, systemPrompt: "Test",
                history: history,
                checkpointTree: SessionCheckpointTree.fromLinearHistory(history, sessionID: "terminal-remote")
            )
            let checkpoint = environment.checkpointURL("remote now")
            try FileManager.default.createDirectory(
                at: checkpoint.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data("kv".utf8).write(to: checkpoint)

            let output = try await Self.captureOutput(of: chat) {
                try await chat.loadSavedSession(saved)
            }

            #expect(output.contains("Loaded session: remote now"))
            #expect(!output.localizedCaseInsensitiveContains("checkpoint"))
            // Nothing reads or removes it: it simply is not used.
            #expect(FileManager.default.fileExists(atPath: checkpoint.path))
            await Self.finish(chat, runner)
        }
    }
}
