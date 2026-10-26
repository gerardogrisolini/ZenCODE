//
//  DS4EngineCheckpointTests.swift
//  ZenCODE
//
//  Explicit DS4 KV checkpoints at the client level (mock engine, no library,
//  no model): the checkpoint is written only by `saveEngineCheckpoint`,
//  restored only by `restoreEngineCheckpoint`, skips images and sessions
//  without live state, and the trailer makes the restored prompt render the
//  text that is in the KV.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

/// `.ds4kv` files (and their temporary files) below `directory`.
func ds4CheckpointFiles(in directory: URL) -> [String] {
    guard let enumerator = FileManager.default.enumerator(atPath: directory.path) else {
        return []
    }
    return enumerator.compactMap { $0 as? String }.filter { $0.contains(".ds4kv") }.sorted()
}

extension MockDS4Engine {
    var checkpointCalls: [Call] {
        calls.filter { call in
            switch call {
            case .saveCheckpoint, .loadCheckpoint: true
            default: false
            }
        }
    }

    /// The trailer stored in a checkpoint file written by the mock.
    static func checkpointTrailer(at url: URL) throws -> DS4CheckpointTrailer {
        let data = try Data(contentsOf: url)
        let trailer = Data(data.dropFirst(checkpointMagic.count))
        return try #require(DS4CheckpointTrailer.decode(trailer))
    }
}

@Suite("DS4 engine checkpoint", .serialized)
struct DS4EngineCheckpointTests {
    private static let level75 = DS4EngineABI.ThinkMode.levelBase + 75
    private static let rawAnswer = "Reasoning</think>Answer."

    private func checkpointURL(_ harness: DS4ClientHarness, _ name: String = "session") -> URL {
        harness.base.appendingPathComponent("\(name).ds4kv")
    }

    /// One turn with a memory block on a client with effort-level thinking.
    private func firstTurn(_ client: RemoteGenerationClient) async throws {
        _ = try await MemoryTurnContext.$currentTurnMemoryBlock.withValue("MEMORY BLOCK") {
            try await client.sendPrompt(sessionID: "session", prompt: "first", attachments: [], onEvent: { _ in })
        }
    }

    // MARK: - Nothing is written implicitly

    @Test
    func promptsToolRoundsCloseSessionAndShutdownNeverTouchCheckpoints() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["Let me check.", DS4ClientHarness.dsml41EchoCall("hi")])
        harness.mock.enqueueGeneration(["Done: ", "hi"])
        harness.mock.enqueueGeneration(["Second answer."])
        let client = try await harness.makeClient()

        _ = try await client.sendPrompt(sessionID: "session", prompt: "Echo hi", attachments: [], onEvent: { _ in })
        _ = try await client.sendPrompt(sessionID: "session", prompt: "Again", attachments: [], onEvent: { _ in })
        #expect(harness.echoedArguments == [#"{"text":"hi"}"#])
        #expect(harness.mock.checkpointCalls.isEmpty)

        await client.closeSession(id: "session")
        #expect(harness.mock.checkpointCalls.isEmpty)
        #expect(harness.mock.calls.contains(.releaseSession("session")))

        await client.shutdown()
        await harness.registry.shutdown()
        #expect(harness.mock.checkpointCalls.isEmpty)
        #expect(ds4CheckpointFiles(in: harness.base).isEmpty)
    }

    // MARK: - Save

    @Test
    func saveWritesTheLiveStateWithTheMessageKeysInTheTrailer() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["Reasoning", "</think>", "Answer."])
        let client = try await harness.makeClient(thinkingSelection: nil)
        try await firstTurn(client)
        let url = checkpointURL(harness)
        #expect(!FileManager.default.fileExists(atPath: url.path))

        let outcome = try await client.saveEngineCheckpoint(sessionID: "session", to: url)

        #expect(outcome == .saved)
        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(harness.mock.checkpointCalls == [.saveCheckpoint(sessionID: "session", url: url)])
        let trailer = try MockDS4Engine.checkpointTrailer(at: url)
        #expect(trailer.format == DS4CheckpointTrailer.formatName)
        #expect(trailer.version == 1)
        // System prompt (0) has no private keys; user (1) and assistant (2) do.
        #expect(trailer.messages.map(\.index) == [1, 2])
        #expect(trailer.messages.map(\.role) == ["user", "assistant"])
        #expect(trailer.messages[0].ds4.userContent == "first\n\nMEMORY BLOCK")
        #expect(trailer.messages[1].ds4.rawAssistant == Self.rawAnswer)
        // The exact ids the engine committed travel with the model that produced them.
        let generated = try #require(harness.engine.results.first).tokens
        #expect(!generated.isEmpty)
        #expect(trailer.messages[1].ds4.rawTokens == generated)
        #expect(trailer.messages[1].ds4.rawTokensModel == harness.engine.info.tokenIdentity)
        #expect(trailer.messages[0].ds4.rawTokens == nil)
        #expect(trailer.messages[1].ds4.thinkMode == Int(Self.level75))
        await client.shutdown()
    }

    @Test
    func saveWithoutAnOpenEngineSkipsAndNeverOpensTheModel() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient()
        let url = checkpointURL(harness)

        let outcome = try await client.saveEngineCheckpoint(sessionID: "session", to: url)

        #expect(outcome == .skippedNoLiveState)
        #expect(harness.openCount == 0)
        #expect(harness.mock.calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await client.shutdown()
    }

    @Test
    func saveOfASessionNeverSyncedSkipsWithoutPrefill() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient()
        _ = try await client.preloadModel(onEvent: { _ in })
        let url = checkpointURL(harness)

        let outcome = try await client.saveEngineCheckpoint(sessionID: "session", to: url)

        #expect(outcome == .skippedNoLiveState)
        #expect(harness.openCount == 1)
        #expect(harness.engine.syncs.isEmpty)
        #expect(harness.mock.checkpointCalls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await client.shutdown()
    }

    @Test
    func saveOfAnEvictedEngineSessionSkipsWithoutPrefill() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient(sessionID: "a")
        for id in ["b", "c"] {
            await client.createSession(id: id, cwd: harness.base.path, allowedToolNames: [DS4ClientHarness.toolName])
        }
        for id in ["a", "b", "c"] {
            _ = try await client.sendPrompt(sessionID: id, prompt: "hi \(id)", attachments: [], onEvent: { _ in })
        }
        // The mock engine keeps two sessions: "a" was evicted by "c".
        #expect(harness.mock.liveSessionIDs.contains("a") == false)
        let syncsBefore = harness.engine.syncs.count
        let url = checkpointURL(harness, "a")

        let outcome = try await client.saveEngineCheckpoint(sessionID: "a", to: url)

        #expect(outcome == .skippedNoLiveState)
        #expect(harness.engine.syncs.count == syncsBefore)
        #expect(harness.mock.checkpointCalls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await client.shutdown()
    }

    @Test
    func saveSkipsSessionsWithImagesAndWritesNothing() async throws {
        let harness = try DS4ClientHarness(hasVision: true, visionRelativePath: "vision.gguf")
        harness.mock.enqueueGeneration(["seen"])
        let client = try await harness.makeClient()
        _ = try await client.sendPrompt(
            sessionID: "session",
            prompt: "Look",
            attachments: [RemoteGenerationClientDS4EngineTests.pngAttachment],
            onEvent: { _ in }
        )
        let url = checkpointURL(harness)

        let outcome = try await client.saveEngineCheckpoint(sessionID: "session", to: url)

        #expect(outcome == .skippedImages)
        #expect(harness.mock.checkpointCalls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await client.shutdown()
    }

    @Test
    func saveSkipsWhenTheEngineHoldsVisionState() async throws {
        let harness = try DS4ClientHarness(hasVision: true, visionRelativePath: "vision.gguf")
        harness.mock.enqueueGeneration(["text only"])
        let client = try await harness.makeClient()
        _ = try await client.sendPrompt(sessionID: "session", prompt: "Hi", attachments: [], onEvent: { _ in })
        // Image-conditioned state in the engine session, whatever the messages say.
        let image = harness.base.appendingPathComponent("i.png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        _ = try await harness.engine.sync(
            sessionID: "session",
            transcript: [.begin, .multimodalMessage(role: "user", textParts: ["a", "b"], imageFiles: [image])],
            onProgress: { _, _, _ in }
        )
        let url = checkpointURL(harness)

        let outcome = try await client.saveEngineCheckpoint(sessionID: "session", to: url)

        #expect(outcome == .skippedImages)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        await client.shutdown()
    }

    @Test
    func backendsWithoutAnEngineHaveNothingToSaveOrRestore() async throws {
        let harness = try DS4ClientHarness()
        let provider = AgentRemoteProvider(
            name: "Remote",
            baseURL: "http://127.0.0.1:9/v1",
            modelID: "remote-model",
            chatEndpoint: .chatCompletions,
            providerProfileID: .openAI,
            protocolProfileID: .openAIChatCompletions,
            authPolicy: .noAuthentication
        )
        let client = RemoteGenerationClient(
            configuration: harness.runtimeConfiguration(),
            provider: provider,
            apiKey: nil
        )
        await client.createSession(id: "session", cwd: harness.base.path)
        let url = checkpointURL(harness)

        #expect(try await client.saveEngineCheckpoint(sessionID: "session", to: url) == .notApplicable)
        try Data("x".utf8).write(to: url)
        #expect(await client.restoreEngineCheckpoint(sessionID: "session", from: url, onEvent: { _ in }) == .notApplicable)
        await client.shutdown()
    }

    // MARK: - Restore

    @Test
    func restoreRendersTheSavedPromptAndReusesTheSavedPrefix() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["Reasoning", "</think>", "Answer."])
        harness.mock.enqueueGeneration(["Second answer."])
        let client = try await harness.makeClient(thinkingSelection: nil)
        try await firstTurn(client)
        let url = checkpointURL(harness)
        #expect(try await client.saveEngineCheckpoint(sessionID: "session", to: url) == .saved)
        let first = try #require(harness.engine.transcripts.first)
        let snapshot = try #require(await client.snapshotSession(id: "session"))
        // The private keys never reach the saved snapshot: only the trailer has them.
        #expect(snapshot.history.map(\.content) == ["first", "Answer."])
        await client.closeSession(id: "session")

        // A new process: only the snapshot history is available.
        let restored = try await harness.makeClient(
            sessionID: "session", history: snapshot.history, thinkingSelection: nil
        )
        let outcome = await restored.restoreEngineCheckpoint(sessionID: "session", from: url, onEvent: { _ in })
        #expect(outcome == .restored)
        #expect(harness.mock.checkpointCalls.last == .loadCheckpoint(sessionID: "session", url: url))
        _ = try await restored.sendPrompt(sessionID: "session", prompt: "second", attachments: [], onEvent: { _ in })

        let second = try #require(harness.engine.transcripts.last)
        // The turns already evaluated render byte for byte as before the save:
        // the frozen user content (memory block) and the exact token ids of the
        // assistant turn (the trailer carries them next to the KV).
        let generated = try #require(harness.engine.results.first).tokens
        #expect(!generated.isEmpty)
        #expect(Array(second.prefix(first.count)) == first)
        #expect(second.contains(.message(role: "user", content: "first\n\nMEMORY BLOCK")))
        #expect(second[first.count] == .tokens(generated))
        #expect(second[first.count + 1] == .endOfSequence)
        #expect(second[first.count + 2] == .message(role: "user", content: "second"))
        #expect(second.last == .assistantPrefix(mode: Self.level75))
        // The next sync reuses exactly the saved prefix, generated tokens included.
        let sync = try #require(harness.engine.syncs.last)
        #expect(sync.cached == MockDS4Engine.tokenCount(of: first) + generated.count)
        await restored.shutdown()
    }

    @Test
    func restoredMessagesThatChangedAreLeftWithoutKeys() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["Reasoning", "</think>", "Answer."])
        harness.mock.enqueueGeneration(["Second answer."])
        let client = try await harness.makeClient(thinkingSelection: nil)
        try await firstTurn(client)
        let url = checkpointURL(harness)
        #expect(try await client.saveEngineCheckpoint(sessionID: "session", to: url) == .saved)
        var history = try #require(await client.snapshotSession(id: "session")).history
        await client.closeSession(id: "session")
        // The user message was edited after the checkpoint was taken.
        history[0] = AgentRuntimeMessage(role: .user, content: "edited")

        let restored = try await harness.makeClient(
            sessionID: "session", history: history, thinkingSelection: nil
        )
        #expect(await restored.restoreEngineCheckpoint(sessionID: "session", from: url, onEvent: { _ in }) == .restored)
        _ = try await restored.sendPrompt(sessionID: "session", prompt: "second", attachments: [], onEvent: { _ in })

        let second = try #require(harness.engine.transcripts.last)
        #expect(second.contains(.message(role: "user", content: "edited")))
        #expect(!second.contains(.message(role: "user", content: "first\n\nMEMORY BLOCK")))
        // The unchanged assistant turn still replays its exact token ids.
        let generated = try #require(harness.engine.results.first).tokens
        #expect(second.contains(.tokens(generated)))
        await restored.shutdown()
    }

    @Test
    func incompatibleCheckpointIsReportedAndTheSessionKeepsWorking() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["Fine."])
        let client = try await harness.makeClient()
        let url = checkpointURL(harness)
        try Data("another model's cache".utf8).write(to: url)

        let outcome = await client.restoreEngineCheckpoint(sessionID: "session", from: url, onEvent: { _ in })

        #expect(outcome == .incompatible)
        let response = try await client.sendPrompt(sessionID: "session", prompt: "hi", attachments: [], onEvent: { _ in })
        #expect(response.text == "Fine.")
        #expect(harness.engine.syncs.first?.cached == 0)
        await client.shutdown()
    }

    @Test
    func missingCheckpointFileIsNotApplicable() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient()

        let outcome = await client.restoreEngineCheckpoint(
            sessionID: "session", from: checkpointURL(harness), onEvent: { _ in }
        )

        #expect(outcome == .notApplicable)
        #expect(harness.openCount == 0)
        #expect(harness.mock.checkpointCalls.isEmpty)
        await client.shutdown()
    }

    @Test
    func restoreOpensTheModelWhenNeededAndReportsTheStatus() async throws {
        // The checkpoint comes from another process (another harness)...
        let writerHarness = try DS4ClientHarness()
        writerHarness.mock.enqueueGeneration(["Hi."])
        let writer = try await writerHarness.makeClient()
        _ = try await writer.sendPrompt(sessionID: "session", prompt: "hi", attachments: [], onEvent: { _ in })
        let url = checkpointURL(writerHarness)
        #expect(try await writer.saveEngineCheckpoint(sessionID: "session", to: url) == .saved)
        let history = try #require(await writer.snapshotSession(id: "session")).history

        // ...and this one has not opened its model yet.
        let harness = try DS4ClientHarness()
        let restored = try await harness.makeClient(sessionID: "session", history: history)
        #expect(harness.openCount == 0)
        let recorder = DS4EventRecorder()
        let outcome = await restored.restoreEngineCheckpoint(sessionID: "session", from: url, onEvent: recorder.handler)

        #expect(outcome == .restored)
        #expect(harness.openCount == 1)
        #expect(recorder.statuses.first == "Loading DS4 model …")
        #expect(harness.mock.checkpointCalls == [.loadCheckpoint(sessionID: "session", url: url)])
        await restored.shutdown()
        await writer.shutdown()
    }

    // MARK: - Engine registry

    @Test
    func leaseIfOpenNeverOpensAnEngine() async throws {
        let harness = try DS4ClientHarness()
        let ran = DS4TestBox(false)

        let value = try await harness.registry.withGenerationLeaseIfOpen(
            configuration: harness.configuration,
            sessionID: "session"
        ) { _ in
            ran.update { $0 = true }
            return 1
        }

        #expect(value == nil)
        #expect(ran.value == false)
        #expect(harness.openCount == 0)
        #expect(await harness.registry.isGenerationLockHeld == false)

        _ = try await harness.registry.engine(for: harness.configuration)
        let opened = try await harness.registry.withGenerationLeaseIfOpen(
            configuration: harness.configuration,
            sessionID: "session"
        ) { _ in 2 }
        #expect(opened == 2)
        #expect(harness.openCount == 1)
        #expect(await harness.registry.isGenerationLockHeld == false)
    }
}

// MARK: - Trailer

@Suite("DS4 engine checkpoint trailer")
struct DS4EngineCheckpointTrailerTests {
    private func message(
        _ role: String,
        _ content: String,
        keys: [String: Any] = [:]
    ) -> [String: Any] {
        var message: [String: Any] = ["role": role, "content": content]
        for (key, value) in keys {
            message[key] = value
        }
        return message
    }

    private var sampleMessages: [[String: Any]] {
        [
            message("system", "System", keys: [DS4MessageKeys.systemReminder: true]),
            message("user", "first", keys: [DS4MessageKeys.userContent: "first\n\nMEMORY"]),
            message("assistant", "Answer", keys: [
                DS4MessageKeys.rawAssistant: "Think</think>Answer",
                DS4MessageKeys.thinkMode: 7,
                DS4MessageKeys.toolCallReplays: [["name": "fixture.echo", "arguments": #"{"text":"x"}"#]],
                DS4MessageKeys.toolObservation: "Tool error: nope"
            ]),
            message("user", "plain")
        ]
    }

    @Test
    func roundTripsEveryPrivateKey() throws {
        let trailer = DS4CheckpointTrailer.capture(from: sampleMessages)
        #expect(trailer.messages.map(\.index) == [0, 1, 2])

        let decoded = try #require(DS4CheckpointTrailer.decode(try trailer.encoded()))
        #expect(decoded == trailer)

        var restored: [[String: Any]] = sampleMessages.map(DS4MessageKeys.removingPrivateKeys(from:))
        #expect(!restored.contains { $0.keys.contains(where: DS4MessageKeys.isPrivate) })
        #expect(decoded.apply(to: &restored) == 3)
        #expect(restored[0][DS4MessageKeys.systemReminder] as? Bool == true)
        #expect(restored[1][DS4MessageKeys.userContent] as? String == "first\n\nMEMORY")
        #expect(restored[2][DS4MessageKeys.rawAssistant] as? String == "Think</think>Answer")
        #expect(restored[2][DS4MessageKeys.thinkMode] as? Int == 7)
        #expect(restored[2][DS4MessageKeys.toolCallReplays] as? [[String: String]]
            == [["name": "fixture.echo", "arguments": #"{"text":"x"}"#]])
        #expect(restored[2][DS4MessageKeys.toolObservation] as? String == "Tool error: nope")
        #expect(restored[3].keys.contains(where: DS4MessageKeys.isPrivate) == false)
    }

    @Test
    func matchesAcrossShiftedIndexesAndIgnoresChangedMessages() throws {
        let trailer = DS4CheckpointTrailer.capture(from: sampleMessages)
        // A dynamic-context message was inserted before the conversation, the
        // first user message was edited and the assistant one is unchanged.
        var restored: [[String: Any]] = [
            message("system", "System"),
            message("user", "context"),
            message("user", "edited"),
            message("assistant", "Answer"),
            message("user", "plain")
        ]

        #expect(trailer.apply(to: &restored) == 2)

        #expect(restored[0][DS4MessageKeys.systemReminder] as? Bool == true)
        #expect(restored[2][DS4MessageKeys.userContent] == nil)
        #expect(restored[3][DS4MessageKeys.rawAssistant] as? String == "Think</think>Answer")
    }

    @Test
    func repeatedIdenticalMessagesKeepTheirOrder() {
        let original: [[String: Any]] = [
            message("user", "go", keys: [DS4MessageKeys.userContent: "go #1"]),
            message("assistant", "ok", keys: [DS4MessageKeys.rawAssistant: "ok #1"]),
            message("user", "go", keys: [DS4MessageKeys.userContent: "go #2"]),
            message("assistant", "ok", keys: [DS4MessageKeys.rawAssistant: "ok #2"])
        ]
        let trailer = DS4CheckpointTrailer.capture(from: original)
        var restored = original.map(DS4MessageKeys.removingPrivateKeys(from:))

        #expect(trailer.apply(to: &restored) == 4)

        #expect(restored.map { $0[DS4MessageKeys.userContent] as? String ?? $0[DS4MessageKeys.rawAssistant] as? String }
            == ["go #1", "ok #1", "go #2", "ok #2"])
    }

    @Test
    func fingerprintIgnoresPrivateKeysAndEdgeWhitespace() {
        let plain = message("user", "hello")
        let decorated = message("user", "  hello \n", keys: [DS4MessageKeys.userContent: "hello\n\nMEMORY"])
        #expect(DS4CheckpointTrailer.fingerprint(of: plain) == DS4CheckpointTrailer.fingerprint(of: decorated))
        #expect(DS4CheckpointTrailer.fingerprint(of: plain) != DS4CheckpointTrailer.fingerprint(of: message("assistant", "hello")))
    }

    @Test
    func fingerprintsSurviveTheSnapshotRoundTrip() throws {
        let toolCall: [String: Any] = [
            "id": "call_1", "type": "function",
            "function": ["name": "fixture.echo", "arguments": #"{"text":"x"}"#]
        ]
        let live: [[String: Any]] = [
            message("system", "System"),
            message("user", "first"),
            ["role": "assistant", "content": "", "tool_calls": [toolCall],
             DS4MessageKeys.rawAssistant: "raw"],
            ["role": "tool", "tool_call_id": "call_1", "name": "fixture.echo", "content": "echo"],
            message("assistant", "Done")
        ]
        let split = RemoteGenerationClient.snapshotMessages(from: live)
        let rebuilt = RemoteGenerationClient.initialMessages(
            cwd: "/tmp", systemPrompt: split.systemPrompt, history: split.history, allowedToolNames: nil
        )
        let trailer = DS4CheckpointTrailer.capture(from: live)

        var restored = rebuilt
        #expect(trailer.apply(to: &restored) == 1)
        #expect(restored[2][DS4MessageKeys.rawAssistant] as? String == "raw")
    }

    @Test
    func unknownFormatOrVersionIsIgnored() throws {
        var trailer = DS4CheckpointTrailer.capture(from: sampleMessages)
        trailer.version = 2
        #expect(DS4CheckpointTrailer.decode(try trailer.encoded()) == nil)
        trailer.version = 1
        trailer.format = "title"
        #expect(DS4CheckpointTrailer.decode(try trailer.encoded()) == nil)
        #expect(DS4CheckpointTrailer.decode(Data("not json".utf8)) == nil)
    }
}

// MARK: - Store

@Suite("DS4 engine checkpoint store", .serialized)
struct DS4EngineCheckpointStoreTests {
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ds4-checkpoint-store-\(UUID().uuidString)", isDirectory: true)
    }

    private func session(name: String, workingDirectory: URL) -> TerminalSavedSession {
        let id = "session-\(name)"
        return TerminalSavedSession(
            name: name,
            sessionID: id,
            cacheKey: nil,
            workingDirectoryPath: workingDirectory.path,
            createdAt: Date(timeIntervalSince1970: 1),
            savedAt: Date(timeIntervalSince1970: 2),
            modelID: "deepseek-v4-flash",
            agentID: nil,
            agentName: nil,
            selectedTools: [],
            selectedSkillIDs: [],
            thinkingSelection: nil,
            systemPrompt: "System",
            history: [],
            checkpointTree: SessionCheckpointTree.fromLinearHistory([], sessionID: id)
        )
    }

    @Test
    func checkpointURLIsTheSessionFileWithTheDS4KVExtension() {
        let support = temporaryDirectory()
        let project = support.appendingPathComponent("Project", isDirectory: true)

        let sessionURL = TerminalSessionStore.sessionFileURL(
            name: "v1.2 review", workingDirectory: project, supportDirectoryURL: support
        )
        let checkpointURL = TerminalSessionStore.engineCheckpointURL(
            name: "v1.2 review", workingDirectory: project, supportDirectoryURL: support
        )

        #expect(checkpointURL.pathExtension == "ds4kv")
        #expect(checkpointURL.deletingLastPathComponent() == sessionURL.deletingLastPathComponent())
        #expect(checkpointURL.deletingPathExtension() == sessionURL.deletingPathExtension())
    }

    @Test
    func deleteRemovesTheCheckpointTogetherWithTheSession() throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let project = support.appendingPathComponent("Project", isDirectory: true)
        _ = try TerminalSessionStore.save(session(name: "work", workingDirectory: project), supportDirectoryURL: support)
        _ = try TerminalSessionStore.save(session(name: "keep", workingDirectory: project), supportDirectoryURL: support)
        let work = TerminalSessionStore.engineCheckpointURL(name: "work", workingDirectory: project, supportDirectoryURL: support)
        let keep = TerminalSessionStore.engineCheckpointURL(name: "keep", workingDirectory: project, supportDirectoryURL: support)
        try Data("kv".utf8).write(to: work)
        try Data("kv".utf8).write(to: keep)

        let deleted = try TerminalSessionStore.delete(name: "work", workingDirectory: project, supportDirectoryURL: support)

        #expect(deleted)
        #expect(!FileManager.default.fileExists(atPath: work.path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
    }

    @Test
    func deleteWithoutACheckpointIsNotAnError() throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let project = support.appendingPathComponent("Project", isDirectory: true)
        _ = try TerminalSessionStore.save(session(name: "work", workingDirectory: project), supportDirectoryURL: support)

        #expect(try TerminalSessionStore.delete(name: "work", workingDirectory: project, supportDirectoryURL: support))
        #expect(!(try TerminalSessionStore.delete(name: "work", workingDirectory: project, supportDirectoryURL: support)))
    }

    @Test
    func listingAndLoadingNeverReadOrMigrateCheckpoints() throws {
        let support = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: support) }
        let project = support.appendingPathComponent("Project", isDirectory: true)
        let saved = session(name: "work", workingDirectory: project)
        _ = try TerminalSessionStore.save(saved, supportDirectoryURL: support)
        let directory = TerminalSessionStore.sessionsDirectoryURL(for: project, supportDirectoryURL: support)
        // A checkpoint whose bytes happen to be a valid session file would be
        // moved by the legacy-name migration; one that is read at all would be
        // chmod-ed to 0600 by the session loader.
        let lookalike = directory.appendingPathComponent("legacy-name.ds4kv")
        let temporary = directory.appendingPathComponent("legacy-name.ds4kv.tmp.AbC123")
        let other = session(name: "other", workingDirectory: project)
        let otherData = try PropertyListEncoder().encode(other)
        try otherData.write(to: lookalike)
        try otherData.write(to: temporary)
        for url in [lookalike, temporary] {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }

        let sessions = try TerminalSessionStore.savedSessions(for: project, supportDirectoryURL: support)
        let loaded = try TerminalSessionStore.load(name: "work", workingDirectory: project, supportDirectoryURL: support)

        #expect(sessions == [saved])
        #expect(loaded == saved)
        for url in [lookalike, temporary] {
            #expect(FileManager.default.fileExists(atPath: url.path))
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            #expect(mode?.intValue == 0o644)
        }
        let migrated = TerminalSessionStore.sessionFileURL(name: "other", workingDirectory: project, supportDirectoryURL: support)
        #expect(!FileManager.default.fileExists(atPath: migrated.path))
    }
}
