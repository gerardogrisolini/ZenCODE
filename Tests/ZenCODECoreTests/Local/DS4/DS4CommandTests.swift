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

@Suite("DS4 command", .serialized)
struct DS4CommandTests {
    // MARK: - Parsing

    @Test
    func parsesEverySubcommand() {
        func parse(_ arguments: String) -> TerminalDS4CommandAction {
            TerminalDS4CommandAction(arguments: arguments)
        }

        #expect(parse("status") == .control(.status))
        #expect(parse("  STATUS  ") == .control(.status))
        #expect(parse("power 50") == .control(.power(50)))
        #expect(parse("power 1") == .control(.power(1)))
        #expect(parse("Power   100") == .control(.power(100)))
        #expect(parse("steer 2.5") == .control(.steer(2.5)))
        #expect(parse("steer -100") == .control(.steer(-100)))
        #expect(parse("steer 100") == .control(.steer(100)))
        #expect(parse("steer 0") == .control(.steer(0)))
        #expect(parse("steer -.5") == .control(.steer(-0.5)))
        #expect(parse("hints on") == .control(.hints(true)))
        #expect(parse("hints OFF") == .control(.hints(false)))
    }

    @Test
    func missingOrInvalidArgumentsGiveUsage() {
        #expect(TerminalDS4CommandAction(arguments: "") == .usage(reason: nil))
        #expect(TerminalDS4CommandAction(arguments: "   ") == .usage(reason: nil))

        let invalid = [
            "bogus", "status now",
            "power", "power 0", "power 101", "power -5", "power 5.5", "power abc", "power 5 6", "power 1e1",
            "steer", "steer 101", "steer -100.5", "steer nan", "steer inf", "steer 1x", "steer 1 2",
            "hints", "hints maybe", "hints on off", "hints 1",
        ]
        for arguments in invalid {
            guard case let .usage(reason) = TerminalDS4CommandAction(arguments: arguments) else {
                Issue.record("'\(arguments)' should give the usage")
                continue
            }
            #expect(reason != nil, "'\(arguments)'")
        }
    }

    @Test
    func usageMessageListsEverySubcommand() {
        let usage = TerminalDS4CommandAction.usageMessage
        for subcommand in ["/ds4 status", "/ds4 power <1-100>", "/ds4 steer <-100..100>", "/ds4 hints on|off"] {
            #expect(usage.contains(subcommand), "\(subcommand)")
        }
        #expect(usage.hasSuffix("\n"))
    }

    // MARK: - Availability

    @Test
    func commandIsListedOnlyForDS4Models() throws {
        let hidden = TerminalChat.visibleCommandDescriptors(builderAgentEnabled: false, telegramEnabled: false)
        #expect(!hidden.map(\.command).contains("/ds4"))

        let visible = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false, telegramEnabled: false, ds4ModelEnabled: true
        )
        let descriptor = try #require(visible.first { $0.command == "/ds4" })
        #expect(descriptor.availability == .ds4Model)
        #expect(!descriptor.requiresArgument)
        for subcommand in ["status", "power", "steer", "hints"] {
            #expect(descriptor.help.contains("/ds4 \(subcommand)"), "\(subcommand)")
        }
        // Everything else is unchanged.
        #expect(visible.filter { $0.command != "/ds4" } == hidden)
        #expect(TerminalChat.isKnownSlashCommand("/ds4 status"))
        #expect(!TerminalChat.isAvailableDuringGeneration(for: "/ds4 status"))
        #expect(TerminalPromptCompletionCatalog.argumentSuggestions(for: "/ds4").map(\.command)
            == ["status", "power", "steer", "hints"])
    }

    // MARK: - Hints state machine (ds4_agent.c test_agent_hints_state)

    @Test
    func hintsNoteFollowsTheDS4AgentStateMachine() throws {
        var hints = DS4HintsState()
        #expect(hints.nextNote() == nil)

        hints.enabled = true
        #expect(hints.nextNote() == DS4HintsNotes.instructions)
        #expect(hints.nextNote() == nil)

        // on -> off adds a note; so does off -> on, with the short one.
        hints.enabled = false
        let disabledNote = hints.nextNote()
        let disabled = try #require(disabledNote)
        #expect(disabled == DS4HintsNotes.disabled)
        #expect(disabled.contains("disabled"))
        #expect(hints.nextNote() == nil)
        hints.enabled = true
        let enabledNote = hints.nextNote()
        let enabled = try #require(enabledNote)
        #expect(enabled == DS4HintsNotes.enabled)
        #expect(enabled != DS4HintsNotes.instructions)
        #expect(enabled.contains("enabled"))

        // Compaction forgets the instructions.
        hints.contextCompacted()
        #expect(hints.enabled && !hints.instructed)
        #expect(hints.nextNote() == DS4HintsNotes.instructions)
        hints.enabled = false
        hints.contextCompacted()
        #expect(hints.nextNote() == DS4HintsNotes.disabled)
        #expect(!hints.instructed)
        hints.contextCompacted()
        #expect(hints.nextNote() == DS4HintsNotes.disabled)

        // A restored transcript overrides old "on" notes without restoring a setting.
        hints = DS4HintsState()
        hints.contextRestoredWithNotes()
        #expect(hints.nextNote() == DS4HintsNotes.disabled)
        #expect(!hints.enabled && !hints.instructed)
        hints.enabled = true
        #expect(hints.nextNote() == DS4HintsNotes.instructions)

        // Several changes before a boundary coalesce to the latest request.
        hints = DS4HintsState()
        hints.enabled = true
        hints.enabled = false
        #expect(hints.nextNote() == nil)
        hints.contextCompacted()
        #expect(hints.nextNote() == nil)
    }

    @Test
    func hintsNotesUseTheDS4AgentTexts() {
        #expect(DS4HintsNotes.instructions.hasPrefix(
            "The user enabled programming hints. Occasionally explain a useful concept behind the current work"
        ))
        #expect(DS4HintsNotes.instructions.contains("starting with > **Hint:**."))
        #expect(DS4HintsNotes.instructions.hasSuffix("Later system notes may enable or disable hints; follow the latest setting.\n"))
        #expect(DS4HintsNotes.enabled == "The user enabled programming hints. Produce them from now on.\n")
        #expect(DS4HintsNotes.disabled
            == "Programming hints are disabled. Do not produce teaching asides; continue the task normally.\n")
    }

    // MARK: - Private key, renderer and trailer

    @Test
    func hintsKeyIsPrivateAndRenderedBeforeTheUserMessage() {
        #expect(DS4MessageKeys.hintsNote == "ds4_hints_note")
        #expect(DS4MessageKeys.isPrivate(DS4MessageKeys.hintsNote))
        let message: [String: Any] = ["role": "user", "content": "hi", DS4MessageKeys.hintsNote: "note\n"]
        #expect(DS4MessageKeys.removingPrivateKeys(from: message).keys.sorted() == ["content", "role"])

        let context = DS4TranscriptRenderer.Context(
            syntax: .dsml41, thinkMode: DS4EngineABI.ThinkMode.none, toolsPrompt: "", preserveThinking: false
        )
        let plain = DS4TranscriptRenderer.render(
            messages: [["role": "system", "content": "SYS"], ["role": "user", "content": "hi"]],
            context: context
        ).operations
        let noted = DS4TranscriptRenderer.render(
            messages: [["role": "system", "content": "SYS"], message],
            context: context
        ).operations

        // Only one system message is inserted, right before the user message;
        // the system prefix is untouched.
        var expected = plain
        let userIndex = expected.firstIndex(of: .message(role: "user", content: "hi"))!
        expected.insert(.message(role: "system", content: "note\n"), at: userIndex)
        #expect(noted == expected)
        #expect(noted.prefix(userIndex) == plain.prefix(userIndex))
    }

    @Test
    func checkpointTrailerCarriesTheHintsNote() throws {
        let note = DS4HintsNotes.instructions
        let messages: [[String: Any]] = [
            ["role": "system", "content": "SYS"],
            ["role": "user", "content": "first", DS4MessageKeys.hintsNote: note],
            ["role": "user", "content": "second"],
        ]
        let trailer = DS4CheckpointTrailer.capture(from: messages)
        #expect(trailer.messages.count == 1)
        #expect(trailer.messages.first?.ds4.hintsNote == note)

        let data = try trailer.encoded()
        #expect(String(decoding: data, as: UTF8.self).contains("\"ds4_hints_note\""))
        let decoded = try #require(DS4CheckpointTrailer.decode(data))
        var restored: [[String: Any]] = [
            ["role": "system", "content": "SYS"],
            ["role": "user", "content": "first"],
            ["role": "user", "content": "second"],
        ]
        #expect(decoded.apply(to: &restored) == 1)
        #expect(restored[1][DS4MessageKeys.hintsNote] as? String == note)
        #expect(restored[2][DS4MessageKeys.hintsNote] == nil)
    }

    // MARK: - Backend default

    @Test
    func backendsWithoutADS4EngineRejectEveryControl() async throws {
        let backend = CapturingACPBackend()
        for command in [AgentDS4ControlCommand.status, .power(50), .steer(1), .hints(true)] {
            await #expect(throws: AgentDS4ControlError.unavailable) {
                try await backend.ds4Control(command, sessionID: "session")
            }
        }
        #expect(AgentDS4ControlError.unavailable.errorDescription
            == "DS4 controls are available only with a DS4 model")

        // A remote (non-DS4) generation client behaves the same.
        let harness = try DS4ClientHarness()
        let remote = RemoteGenerationClient(
            configuration: harness.runtimeConfiguration(),
            provider: AgentRemoteProvider(
                name: "Remote",
                baseURL: "http://127.0.0.1:9/v1",
                modelID: "remote-model",
                chatEndpoint: .chatCompletions,
                providerProfileID: .openAI,
                protocolProfileID: .openAIChatCompletions,
                authPolicy: .noAuthentication
            ),
            apiKey: nil
        )
        await remote.createSession(id: "session", cwd: harness.base.path)
        await #expect(throws: AgentDS4ControlError.unavailable) {
            try await remote.ds4Control(.status, sessionID: "session")
        }
        await remote.shutdown()
    }

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

    // MARK: - Through TerminalChat

    @TerminalChatActor
    @Suite("through TerminalChat", .serialized)
    struct Chat {
        private struct Environment {
            let root: URL
            let workspace: URL
            let support: URL

            init() throws {
                root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("zencode-ds4-command-chat-\(UUID().uuidString)", isDirectory: true)
                workspace = root.appendingPathComponent("workspace", isDirectory: true)
                support = root.appendingPathComponent("support", isDirectory: true)
                try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
            }

            func remove() {
                try? FileManager.default.removeItem(at: root)
            }

            func configuration(ds4Runtime: AgentDS4RuntimeManifest?) throws -> AgentConfiguration {
                try AgentConfiguration(
                    hostedModelID: "ds4-model",
                    availableAgents: AgentProfileStore.defaultProfiles(),
                    availableModels: [
                        AgentSettingsModelManifest(
                            id: "ds4-model", kind: .remoteAPI, modelID: "deepseek-v4-flash", ds4Runtime: ds4Runtime
                        ),
                        AgentSettingsModelManifest(
                            id: "remote-model", kind: .remoteAPI, modelID: "local/remote-model"
                        ),
                    ],
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
            func chat(ds4Runtime: AgentDS4RuntimeManifest?, runner: AgentCoreSessionRunner) throws -> TerminalChat {
                TerminalChat(
                    configuration: try configuration(ds4Runtime: ds4Runtime),
                    stdinIsTerminal: false,
                    sessionRunner: runner
                )
            }
        }

        private nonisolated func withEnvironment(
            _ body: @escaping @Sendable @TerminalChatActor (Environment) async throws -> Void
        ) async throws {
            let environment = try Environment()
            defer { environment.remove() }
            try await AppStorageDirectory.withSupportDirectoryURL(environment.support) {
                try await Task(name: "ZenCODE.Tests.ds4-command") { @TerminalChatActor in
                    try await body(environment)
                }.value
            }
        }

        private static func output(of chat: TerminalChat, _ body: () async throws -> Void) async rethrows -> String {
            chat.telegramImmediateCommandOutput = []
            defer { chat.telegramImmediateCommandOutput = nil }
            try await body()
            return chat.telegramImmediateCommandOutput?.joined() ?? ""
        }

        private static func start(_ chat: TerminalChat) async throws {
            try await chat.createCurrentSession(discoverExternalTools: false)
            _ = try await chat.preloadCurrentModel(emitStatus: false)
        }

        private static func isContinue(_ action: TerminalSubmittedLineAction) -> Bool {
            if case .continueChat = action { true } else { false }
        }

        private static func finish(_ chat: TerminalChat, _ runner: AgentCoreSessionRunner) async {
            await chat.stopTaskGraphObserver()
            await runner.shutdown()
        }

        @Test
        nonisolated func commandIsVisibleOnlyWhileTheCurrentModelHasADS4Runtime() async throws {
            try await withEnvironment { environment in
                let harness = try DS4ClientHarness()
                let client = try await harness.makeClient(sessionID: "unused")
                let runner = environment.runner(backend: client)
                let chat = try environment.chat(ds4Runtime: harness.manifest, runner: runner)

                // The DS4 model is current: listed, suggested, documented, handled.
                #expect(chat.currentModelUsesDS4Runtime())
                #expect(chat.visibleCommandNamesForCurrentAgent().contains("/ds4"))
                #expect(chat.commandSuggestionsForCurrentAgent().contains { $0.command == "/ds4" })
                #expect(chat.renderHelpTextForCurrentAgent().contains("/ds4 status"))
                #expect(chat.unavailableLocalSlashCommandMessage(for: "/ds4 status") == nil)
                #expect(chat.generatingSlashCommandMessage(for: "/ds4 status")
                    == "ZenCODE: command '/ds4' is unavailable while a prompt is running.\n")

                // Switching to a model without a DS4 runtime hides it everywhere.
                chat.manualModelIDOverride = "remote-model"
                #expect(!chat.currentModelUsesDS4Runtime())
                #expect(!chat.visibleCommandNamesForCurrentAgent().contains("/ds4"))
                #expect(!chat.commandSuggestionsForCurrentAgent().contains { $0.command == "/ds4" })
                #expect(!chat.renderHelpTextForCurrentAgent().contains("/ds4"))
                #expect(chat.unavailableLocalSlashCommandMessage(for: "/ds4 status")
                    == "ZenCODE: unknown command '/ds4'.\n")
                #expect(chat.generatingSlashCommandMessage(for: "/ds4 status")
                    == "ZenCODE: unknown command '/ds4'.\n")
                let output = await Self.output(of: chat) {
                    let action = await chat.submittedLineAction("/ds4 status")
                    #expect(Self.isContinue(action))
                }
                #expect(output == "ZenCODE: unknown command '/ds4'.\n")
                #expect(harness.mock.calls.isEmpty)
                #expect(harness.openCount == 0)
                await runner.shutdown()
            }
        }

        @Test
        nonisolated func commandForwardsStatusPowerSteerAndHintsToTheEngine() async throws {
            try await withEnvironment { environment in
                let harness = try DS4ClientHarness(contextSize: 200_000, steeringRelativePath: "steering.gguf")
                harness.mock.enqueueGeneration(["Hello."])
                let client = try await harness.makeClient(sessionID: "unused")
                let runner = environment.runner(backend: client)
                let chat = try environment.chat(ds4Runtime: harness.manifest, runner: runner)
                try await Self.start(chat)
                let sessionID = chat.sessionID

                let power = await Self.output(of: chat) {
                    #expect(Self.isContinue(await chat.submittedLineAction("/ds4 power 70")))
                }
                #expect(power == "DS4 power set to 70% for this session.\n")
                let steer = await Self.output(of: chat) {
                    await chat.handleDS4Command("/ds4 steer -2.5")
                }
                #expect(steer == "DS4 steering FFN set to -2.5 for this session.\n")
                #expect(harness.mock.calls == [
                    .setPower(sessionID: sessionID, percent: 70),
                    .setSteeringFFN(sessionID: sessionID, scale: -2.5),
                ])

                let hints = await Self.output(of: chat) {
                    await chat.handleDS4Command("/ds4 hints on")
                }
                #expect(hints == "DS4 hints on (applies at the next conversation boundary).\n")
                _ = try await client.sendPrompt(
                    sessionID: sessionID, prompt: "hello there", attachments: [], onEvent: { _ in }
                )
                let transcript = try #require(harness.engine.transcripts.first)
                let user = try #require(transcript.firstIndex(of: .message(role: "user", content: "hello there")))
                #expect(transcript[user - 1] == .message(role: "system", content: DS4HintsNotes.instructions))

                let status = await Self.output(of: chat) {
                    await chat.handleDS4Command("/ds4 status")
                }
                #expect(status.hasPrefix("DS4 status\n"))
                #expect(status.contains("open: mock-ds4 (model id 41)"))
                #expect(status.contains("70% (set with /ds4 power)"))
                #expect(status.contains("FFN -2.5 (set with /ds4 steer)"))
                #expect(status.contains("Hints:"))
                #expect(status.hasSuffix("on\n"))
                #expect(status.contains("1 / 2 live in the engine pool"))
                #expect(status.hasSuffix("\n"))
                await Self.finish(chat, runner)
            }
        }

        @Test
        nonisolated func commandReportsUsageAndErrors() async throws {
            try await withEnvironment { environment in
                let harness = try DS4ClientHarness()
                let client = try await harness.makeClient(sessionID: "unused")
                let runner = environment.runner(backend: client)
                let chat = try environment.chat(ds4Runtime: harness.manifest, runner: runner)
                try await Self.start(chat)
                let calls = harness.mock.calls

                let bare = await Self.output(of: chat) {
                    await chat.handleDS4Command("/ds4")
                }
                #expect(bare == TerminalDS4CommandAction.usageMessage)
                let wrong = await Self.output(of: chat) {
                    await chat.handleDS4Command("/ds4 power 500")
                }
                #expect(wrong == "ZenCODE: power must be between 1 and 100.\n" + TerminalDS4CommandAction.usageMessage)
                let unknown = await Self.output(of: chat) {
                    await chat.handleDS4Command("/ds4 reboot")
                }
                #expect(unknown.contains("unknown /ds4 subcommand 'reboot'"))
                #expect(unknown.hasSuffix(TerminalDS4CommandAction.usageMessage))
                let noSteering = await Self.output(of: chat) {
                    await chat.handleDS4Command("/ds4 steer 2")
                }
                #expect(noSteering == "ZenCODE: /ds4: no steering file configured for this model.\n")
                // Nothing reached the engine.
                #expect(harness.mock.calls == calls)
                await Self.finish(chat, runner)
            }
        }

        @Test
        nonisolated func commandWithABackendWithoutAnEngineReportsIt() async throws {
            try await withEnvironment { environment in
                let harness = try DS4ClientHarness()
                // The model says DS4, but the active backend has no engine.
                let runner = environment.runner(backend: CapturingACPBackend())
                let chat = try environment.chat(ds4Runtime: harness.manifest, runner: runner)
                try await Self.start(chat)

                let output = await Self.output(of: chat) {
                    await chat.handleDS4Command("/ds4 status")
                }

                #expect(output == "ZenCODE: /ds4: DS4 controls are available only with a DS4 model.\n")
                await Self.finish(chat, runner)
            }
        }
    }
}
