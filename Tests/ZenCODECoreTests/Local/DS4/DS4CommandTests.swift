//
//  DS4CommandTests.swift
//  ZenCODE
//
//  `/ds4`: the parsing of the command, its availability, and the forwarding of
//  status, power, steering and hints through `TerminalChat`, the session runner
//  and `RemoteGenerationClient` to `MockDS4Engine` (no library, no model).
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore
@testable import ZenCODERuntime

@Suite("DS4 command", .serialized)
struct DS4CommandTests {
    // MARK: - Status

    @Test
    func statusWithoutAnOpenEngineDoesNotOpenIt() async throws {
        let harness = try DS4ClientHarness(contextSize: 8192, steeringRelativePath: "steering.gguf", power: 80)
        let client = try await harness.makeClient()

        let result = try await client.ds4Control(.status, sessionID: "session")

        let status = try #require(result.status)
        #expect(!status.engineIsOpen)
        #expect(status.engineModelName == nil)
        #expect(status.backend == "metal")
        #expect(status.libraryState == .built)
        #expect(status.libraryPath == harness.configuration.libraryURL.path)
        #expect(status.contextUsedTokens == nil)
        #expect(status.contextTotalTokens == 8192)
        #expect(status.liveSessions == nil)
        #expect(status.sessionCapacity == 2)
        #expect(status.powerPercent == 80)
        #expect(!status.powerIsOverride)
        #expect(status.steeringFile == "steering.gguf")
        #expect(status.steeringScale == 1)
        #expect(!status.hintsEnabled)
        #expect(result.message == status.renderedText)
        #expect(result.message.contains("not open"))
        #expect(result.message.contains("built (\(harness.configuration.libraryURL.path))"))
        #expect(result.message.contains("0 / 8,192 tokens"))
        #expect(result.message.contains("0 / 2 (engine not open)"))
        // The model was never opened and the engine never called.
        #expect(harness.openCount == 0)
        #expect(harness.mock.calls.isEmpty)
        await client.shutdown()
    }

    @Test
    func statusReportsTheLibraryProblems() async throws {
        let expected = URL(fileURLWithPath: "/tmp/zencode-ds4-tests/metal-0123456789abcdef/libzencode-ds4.dylib")
        let missing = try DS4ClientHarness(libraryStatus: .missing(expected: expected))
        let missingClient = try await missing.makeClient()
        let missingStatus = try #require(try await missingClient.ds4Control(.status, sessionID: "session").status)
        #expect(missingStatus.libraryState == .missing)
        #expect(missingStatus.libraryPath == expected.path)
        #expect(missingStatus.renderedText.contains("missing (expected at \(expected.path)"))

        let stale = try DS4ClientHarness(libraryStatus: .stale(
            found: URL(fileURLWithPath: "/tmp/old/libzencode-ds4.dylib"), expected: expected
        ))
        let staleClient = try await stale.makeClient()
        let staleStatus = try #require(try await staleClient.ds4Control(.status, sessionID: "session").status)
        #expect(staleStatus.libraryState == .stale)
        #expect(staleStatus.renderedText.contains("stale (rebuild it at \(expected.path)"))
        await missingClient.shutdown()
        await staleClient.shutdown()
    }

    @Test
    func statusAfterGenerationsReportsContextCacheAndPool() async throws {
        let harness = try DS4ClientHarness(contextSize: 8192)
        harness.mock.enqueueGeneration(["First."])
        harness.mock.enqueueGeneration(["Second."])
        let client = try await harness.makeClient()
        try await Self.send("first", to: client)
        try await Self.send("second", to: client)

        let status = try #require(try await client.ds4Control(.status, sessionID: "session").status)

        let position = await harness.engine.stats(sessionID: "session").position
        let syncs = harness.engine.syncs
        try #require(syncs.count == 2)
        #expect(status.engineIsOpen)
        #expect(status.engineModelName == "mock-ds4")
        #expect(status.engineModelID == 41)
        #expect(position > 0)
        #expect(status.contextUsedTokens == position)
        #expect(status.contextTotalTokens == 8192)
        #expect(status.cachedTokens == syncs[1].cached)
        #expect(syncs[1].cached > 0)
        #expect(status.liveSessions == 1)
        #expect(status.sessionCapacity == 2)
        #expect(status.renderedText.contains("open: mock-ds4 (model id 41)"))
        #expect(status.renderedText.contains("1 / 2 live in the engine pool"))
        #expect(status.renderedText.contains("tokens reused at the last sync"))
        #expect(!status.hasPendingControls)
        await client.shutdown()
    }

    // MARK: - Power

    @Test
    func powerOnAnOpenEngineIsAppliedAtOnceToTheCurrentSession() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient()
        _ = try await client.preloadModel(onEvent: { _ in })
        #expect(harness.openCount == 1)

        let result = try await client.ds4Control(.power(60), sessionID: "session")

        #expect(result.isApplied)
        #expect(result.message == "DS4 power set to 60% for this session.")
        #expect(harness.mock.calls == [.setPower(sessionID: "session", percent: 60)])
        let status = try #require(try await client.ds4Control(.status, sessionID: "session").status)
        #expect(status.powerPercent == 60)
        #expect(status.powerIsOverride)
        #expect(!status.hasPendingControls)

        // The value is not applied again by the next generation.
        try await Self.send("go", to: client)
        let powerCalls = harness.mock.calls.filter { if case .setPower = $0 { true } else { false } }
        #expect(powerCalls.count == 1)
        await client.shutdown()
    }

    @Test
    func powerWithoutAnOpenEngineIsAppliedInTheLeaseBeforeTheNextSync() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient()

        let result = try await client.ds4Control(.power(40), sessionID: "session")

        #expect(!result.isApplied)
        #expect(result.message.contains("applied when the model loads"))
        #expect(harness.openCount == 0)
        #expect(harness.mock.calls.isEmpty)
        let pending = try #require(try await client.ds4Control(.status, sessionID: "session").status)
        #expect(pending.powerPercent == 40)
        #expect(pending.hasPendingControls)
        #expect(pending.renderedText.contains("Pending:"))

        try await Self.send("go", to: client)

        let calls = harness.mock.calls
        let power = try #require(calls.firstIndex(of: .setPower(sessionID: "session", percent: 40)))
        let sync = try #require(calls.firstIndex { if case .sync = $0 { true } else { false } })
        #expect(power < sync)
        let applied = try #require(try await client.ds4Control(.status, sessionID: "session").status)
        #expect(!applied.hasPendingControls)
        try await Self.send("again", to: client)
        let powerCalls = harness.mock.calls.filter { if case .setPower = $0 { true } else { false } }
        #expect(powerCalls.count == 1)
        await client.shutdown()
    }

    @Test
    func powerOutOfRangeIsRejectedWithoutTouchingTheEngine() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient()
        _ = try await client.preloadModel(onEvent: { _ in })

        for percent in [0, -3, 101, 1000] {
            await #expect(throws: AgentDS4ControlError.invalidPower(percent)) {
                try await client.ds4Control(.power(percent), sessionID: "session")
            }
        }
        #expect(harness.mock.calls.isEmpty)
        await client.shutdown()
    }

    // MARK: - Steering

    @Test
    func steerWithoutASteeringFileIsRejected() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient()
        _ = try await client.preloadModel(onEvent: { _ in })

        let error = await #expect(throws: AgentDS4ControlError.self) {
            try await client.ds4Control(.steer(2), sessionID: "session")
        }
        #expect(error == .noSteeringFile)
        #expect(error?.errorDescription?.contains("no steering file configured") == true)
        #expect(harness.mock.calls.isEmpty)
        await client.shutdown()
    }

    @Test
    func steerOnAnOpenEngineIsAppliedAtOnce() async throws {
        let harness = try DS4ClientHarness(steeringRelativePath: "steering.gguf")
        let client = try await harness.makeClient()
        _ = try await client.preloadModel(onEvent: { _ in })

        let result = try await client.ds4Control(.steer(2.5), sessionID: "session")

        #expect(result.isApplied)
        #expect(result.message == "DS4 steering FFN set to 2.5 for this session.")
        #expect(harness.mock.calls == [.setSteeringFFN(sessionID: "session", scale: 2.5)])
        let status = try #require(try await client.ds4Control(.status, sessionID: "session").status)
        #expect(status.steeringScale == 2.5)
        #expect(status.steeringIsOverride)
        for scale in [100.5, -101, Double.nan, Double.infinity] {
            await #expect(throws: AgentDS4ControlError.self) {
                try await client.ds4Control(.steer(scale), sessionID: "session")
            }
        }
        let steerCalls = harness.mock.calls.filter { if case .setSteeringFFN = $0 { true } else { false } }
        #expect(steerCalls.count == 1)
        await client.shutdown()
    }

    @Test
    func steerWithoutAnOpenEngineWaitsForTheNextLease() async throws {
        let harness = try DS4ClientHarness(steeringRelativePath: "steering.gguf")
        let client = try await harness.makeClient()

        let result = try await client.ds4Control(.steer(-30), sessionID: "session")

        #expect(!result.isApplied)
        #expect(harness.openCount == 0)
        try await Self.send("go", to: client)
        let calls = harness.mock.calls
        let steer = try #require(calls.firstIndex(of: .setSteeringFFN(sessionID: "session", scale: -30)))
        let sync = try #require(calls.firstIndex { if case .sync = $0 { true } else { false } })
        #expect(steer < sync)
        await client.shutdown()
    }

    // MARK: - Hints

    @Test
    func hintsNoteIsRecordedAtTheNextUserMessageAndKeepsThePrefixStable() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient()

        let result = try await client.ds4Control(.hints(true), sessionID: "session")
        #expect(result.message == "DS4 hints on (applies at the next conversation boundary).")
        #expect(harness.mock.calls.isEmpty)

        try await Self.send("first", to: client)
        try await Self.send("second", to: client)
        _ = try await client.ds4Control(.hints(false), sessionID: "session")
        try await Self.send("third", to: client)
        _ = try await client.ds4Control(.hints(true), sessionID: "session")
        try await Self.send("fourth", to: client)

        let transcripts = harness.engine.transcripts
        try #require(transcripts.count == 4)
        // First boundary: the full instructions, a system message right before
        // the user message, after the system prompt (never in the initial prefix).
        let instructions = DS4TranscriptOperation.message(role: "system", content: DS4HintsNotes.instructions)
        let first = transcripts[0]
        let firstUser = try #require(first.firstIndex(of: .message(role: "user", content: "first")))
        #expect(first[firstUser - 1] == instructions)
        let systemPrompt = try #require(first.firstIndex { operation in
            if case let .message(role, content) = operation { role == "system" && content.contains(DS4ClientHarness.systemPrompt) } else { false }
        })
        #expect(systemPrompt < firstUser - 1)
        // No further note while the setting is unchanged; every earlier turn is
        // re-rendered unchanged, so the KV prefix is reused.
        #expect(!transcripts[1].suffix(from: first.count).contains(instructions))
        #expect(Array(transcripts[1].prefix(first.count)) == first)
        // on -> off adds the "disabled" note before the third user message.
        let disabled = DS4TranscriptOperation.message(role: "system", content: DS4HintsNotes.disabled)
        let third = transcripts[2]
        let thirdUser = try #require(third.firstIndex(of: .message(role: "user", content: "third")))
        #expect(third[thirdUser - 1] == disabled)
        #expect(Array(third.prefix(transcripts[1].count)) == transcripts[1])
        // off -> on adds the short note, not the instructions again.
        let enabled = DS4TranscriptOperation.message(role: "system", content: DS4HintsNotes.enabled)
        let fourth = transcripts[3]
        let fourthUser = try #require(fourth.lastIndex { operation in
            if case let .message(role, content) = operation { role == "user" && content == "fourth" } else { false }
        })
        #expect(fourth[fourthUser - 1] == enabled)
        #expect(fourth.filter { $0 == instructions }.count == 1)
        #expect(Array(fourth.prefix(third.count)) == third)

        let syncs = harness.engine.syncs
        try #require(syncs.count == 4)
        for index in 1..<4 {
            #expect(syncs[index].cached > syncs[index - 1].cached, "turn \(index)")
        }
        await client.shutdown()
    }

    @Test
    func hintsOffFromTheStartAddsNothing() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient()
        _ = try await client.ds4Control(.hints(false), sessionID: "session")

        try await Self.send("first", to: client)

        let hasHintsNote = try #require(harness.engine.transcripts.first).contains { operation in
            if case let .message(role, content) = operation { role == "system" && content.contains("programming hints") } else { false }
        }
        #expect(!hasHintsNote)
        await client.shutdown()
    }

    @Test
    func hintsNoteStaysOutOfSnapshotsAndTheNextBackendStartsWithTheDefaults() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient()
        _ = try await client.ds4Control(.hints(true), sessionID: "session")
        _ = try await client.ds4Control(.power(33), sessionID: "session")
        try await Self.send("first", to: client)

        let snapshot = try #require(await client.snapshotSession(id: "session"))
        #expect(snapshot.history.map(\.content) == ["first", "mock reply"])
        await client.shutdown()

        // A new backend (new client) knows nothing about the earlier values.
        let next = try await harness.makeClient()
        let status = try #require(try await next.ds4Control(.status, sessionID: "session").status)
        #expect(!status.hintsEnabled)
        #expect(!status.powerIsOverride)
        #expect(status.powerPercent == 100)
        await next.shutdown()
    }

    @Test
    func compactingTheSessionRepeatsTheInstructionsAtTheNextBoundary() async throws {
        let harness = try DS4ClientHarness(contextSize: 200_000)
        let client = try await harness.makeClient()
        _ = try await client.ds4Control(.hints(true), sessionID: "session")
        for index in 1...4 {
            harness.mock.enqueueGeneration(["Answer \(index) " + String(repeating: "word ", count: 80)])
            try await Self.send("question \(index) " + String(repeating: "text ", count: 80), to: client)
        }
        let instructions = DS4TranscriptOperation.message(role: "system", content: DS4HintsNotes.instructions)
        #expect(harness.engine.transcripts.last?.filter { $0 == instructions }.count == 1)

        let compacted = await client.compactSession(id: "session", force: true)
        try #require(compacted != nil)
        try await Self.send("after compaction", to: client)

        // The compacted context forgot the instructions: they are sent again, once.
        let last = try #require(harness.engine.transcripts.last)
        let lastUser = try #require(last.lastIndex(of: .message(role: "user", content: "after compaction")))
        #expect(last[lastUser - 1] == instructions)
        #expect(last.filter { $0 == instructions }.count >= 1)
        await client.shutdown()
    }

    @Test
    func aRestoredCheckpointStatesTheCurrentHintsSettingAgain() async throws {
        let harness = try DS4ClientHarness()
        harness.mock.enqueueGeneration(["Answer."])
        harness.mock.enqueueGeneration(["Second answer."])
        let client = try await harness.makeClient(thinkingSelection: nil)
        _ = try await client.ds4Control(.hints(true), sessionID: "session")
        try await Self.send("first", to: client)
        let url = harness.base.appendingPathComponent("session.ds4kv")
        #expect(try await client.saveEngineCheckpoint(sessionID: "session", to: url) == .saved)
        let first = try #require(harness.engine.transcripts.first)
        let history = try #require(await client.snapshotSession(id: "session")).history
        await client.closeSession(id: "session")

        // A new process: hints start off, but the restored context holds the note.
        let restored = try await harness.makeClient(sessionID: "session", history: history, thinkingSelection: nil)
        #expect(await restored.restoreEngineCheckpoint(sessionID: "session", from: url, onEvent: { _ in }) == .restored)
        try await Self.send("second", to: restored)

        let second = try #require(harness.engine.transcripts.last)
        #expect(Array(second.prefix(first.count)) == first)
        #expect(second.contains(.message(role: "system", content: DS4HintsNotes.instructions)))
        let secondUser = try #require(second.lastIndex(of: .message(role: "user", content: "second")))
        #expect(second[secondUser - 1] == .message(role: "system", content: DS4HintsNotes.disabled))
        await restored.shutdown()
    }

    // MARK: - Sessions

    @Test
    func closingTheSessionDropsItsRuntimeValues() async throws {
        let harness = try DS4ClientHarness()
        let client = try await harness.makeClient()
        _ = try await client.ds4Control(.power(25), sessionID: "session")
        _ = try await client.ds4Control(.hints(true), sessionID: "session")

        await client.closeSession(id: "session")
        await client.createSession(id: "session", cwd: harness.base.path, systemPrompt: DS4ClientHarness.systemPrompt)

        let status = try #require(try await client.ds4Control(.status, sessionID: "session").status)
        #expect(!status.powerIsOverride)
        #expect(status.powerPercent == 100)
        #expect(!status.hintsEnabled)
        await client.shutdown()
    }

    @Test
    func controlsNeedAnExistingSession() async throws {
        let harness = try DS4ClientHarness(steeringRelativePath: "steering.gguf")
        let client = try await harness.makeClient()

        await #expect(throws: AgentDS4ControlError.sessionNotFound("other")) {
            try await client.ds4Control(.power(50), sessionID: "other")
        }
        await #expect(throws: AgentDS4ControlError.sessionNotFound("other")) {
            try await client.ds4Control(.steer(1), sessionID: "other")
        }
        await #expect(throws: AgentDS4ControlError.sessionNotFound("other")) {
            try await client.ds4Control(.hints(true), sessionID: "other")
        }
        // The status needs no session.
        _ = try await client.ds4Control(.status, sessionID: "other")
        await client.shutdown()
    }

    // MARK: - Helpers

    fileprivate static func send(_ prompt: String, to client: RemoteGenerationClient) async throws {
        _ = try await client.sendPrompt(sessionID: "session", prompt: prompt, attachments: [], onEvent: { _ in })
    }
}
