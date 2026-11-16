//
//  DS4CommandTests+Parsing.swift
//  ZenCODE
//
//  `/ds4`: the parsing of the command, its availability, the hints state
//  machine with its private key, renderer and trailer, and the rejection of
//  every control by backends without a DS4 engine.
//  Tests of this serialized suite run in file-name order: keep the name.
//

import Foundation
import Testing
import ToolCore
@testable import ZenCODECore

extension DS4CommandTests {
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
        let hidden = TerminalChat.commandRegistry.visibleDescriptors(
            in: TerminalChat.commandContext(
                builderAgentEnabled: false, telegramEnabled: false, ds4ModelEnabled: false
            )
        )
        #expect(!hidden.map(\.command).contains("/ds4"))

        let visible = TerminalChat.commandRegistry.visibleDescriptors(
            in: TerminalChat.commandContext(
                builderAgentEnabled: false, telegramEnabled: false, ds4ModelEnabled: true
            )
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
}
