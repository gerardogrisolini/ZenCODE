//
//  ZenCODESetupCommandTests.swift
//  ZenCODETests
//
//  `zen --setup`, the only way into the interactive setup, and the startup
//  gate that stops every other mode except ACP while ZenCODE is not
//  configured.
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@Suite
struct ZenCODESetupCommandTests {
    // MARK: - Detection and validation

    @Test
    func setupIsDetectedAnywhereAfterTheExecutable() {
        #expect(ZenCODESetupCommand.option == "--setup")
        #expect(ZenCODESetupCommand.shouldRun(arguments: ["zen", "--setup"]))
        #expect(ZenCODESetupCommand.shouldRun(arguments: ["zen", "--tui", "--setup"]))
        #expect(ZenCODESetupCommand.shouldRun(arguments: ["zen", "--model", "x", "--setup"]))
        #expect(!ZenCODESetupCommand.shouldRun(arguments: ["zen"]))
        #expect(!ZenCODESetupCommand.shouldRun(arguments: ["zen", "--tui"]))
        // The executable itself is never an option.
        #expect(!ZenCODESetupCommand.shouldRun(arguments: ["--setup"]))
    }

    @Test
    func setupAloneOrRepeatedIsValid() throws {
        try ZenCODESetupCommand.validateArguments(["zen", "--setup"])
        try ZenCODESetupCommand.validateArguments(["zen", "--setup", "--setup"])
        try ZenCODESetupCommand.validateArguments(["zen", "--setup", "--setup", "--setup"])
    }

    @Test
    func setupCannotBeCombinedWithAnyOtherArgument() {
        let cases: [(arguments: [String], conflicting: String)] = [
            (["zen", "--setup", "--tui"], "--tui"),
            (["zen", "--tui", "--setup"], "--tui"),
            (["zen", "--setup", "--acp"], "--acp"),
            (["zen", "--setup", "--telegram"], "--telegram"),
            (["zen", "--setup", "-p", "hello"], "-p"),
            (["zen", "--setup", "--prompt", "hello"], "--prompt"),
            (["zen", "--setup", "-f", "/tmp/prompt.md"], "-f"),
            (["zen", "--setup", "--jsonl"], "--jsonl"),
            (["zen", "--jsonl", "--setup", "-p", "hi"], "--jsonl"),
            (["zen", "--setup", "--model", "provider:model"], "--model"),
            (["zen", "--setup", "--agent", "Developer"], "--agent"),
            (["zen", "--setup", "--working-directory", "/tmp"], "--working-directory"),
            (["zen", "--setup", "--skills", "all"], "--skills"),
            (["zen", "--setup", "--ui"], "--ui"),
            (["zen", "--setup", "--setup", "extra"], "extra"),
        ]
        for (arguments, conflicting) in cases {
            #expect(validationError(arguments) == "Options --setup and \(conflicting) cannot be combined.", "\(arguments)")
        }
        #expect(throws: AgentConfigurationError.self) {
            try ZenCODESetupCommand.validateArguments(["zen", "--setup", "--tui"])
        }
    }

    // MARK: - Setup loop

    @Test
    func aConfiguredSetupEndsConfigured() async throws {
        let runs = Mutex(0)
        let configured = try await ZenCODESetupCommand.run(
            setupRunner: {
                runs.withLock { $0 += 1 }
                return .configured
            },
            isConfigured: { true }
        )
        #expect(configured)
        #expect(runs.withLock { $0 } == 1)
    }

    @Test
    func aCancelledSetupReportsWhetherAConfigurationExists() async throws {
        let unconfigured = try await ZenCODESetupCommand.run(
            setupRunner: { .cancelled },
            isConfigured: { false }
        )
        #expect(!unconfigured)

        // A cancel over an existing valid configuration still ends configured.
        let stillConfigured = try await ZenCODESetupCommand.run(
            setupRunner: { .cancelled },
            isConfigured: { true }
        )
        #expect(stillConfigured)

        // The outcome alone never decides: a completed setup is checked too.
        let configuredButInvalid = try await ZenCODESetupCommand.run(
            setupRunner: { .configured },
            isConfigured: { false }
        )
        #expect(!configuredButInvalid)
    }

    @Test
    func aResetOrAReplacedSupportDirectoryOpensTheSetupAgain() async throws {
        let outcomes = Mutex<[SetupOutcome]>([.reset, .dataReplaced, .reset, .configured])
        let runs = Mutex(0)
        let checks = Mutex(0)
        let configured = try await ZenCODESetupCommand.run(
            setupRunner: {
                runs.withLock { $0 += 1 }
                return outcomes.withLock { $0.removeFirst() }
            },
            isConfigured: {
                checks.withLock { $0 += 1 }
                return true
            }
        )
        #expect(configured)
        #expect(runs.withLock { $0 } == 4)
        #expect(outcomes.withLock { $0.isEmpty })
        // Only the final outcome is checked.
        #expect(checks.withLock { $0 } == 1)

        let afterReset = try await ZenCODESetupCommand.run(
            setupRunner: {
                outcomes.withLock { $0.isEmpty ? .cancelled : $0.removeFirst() }
            },
            isConfigured: { false }
        )
        #expect(!afterReset)
    }

    @Test
    func aSetupErrorEndsTheCommand() async {
        let runs = Mutex(0)
        await #expect(throws: ZenCODESetupError.self) {
            _ = try await ZenCODESetupCommand.run(
                setupRunner: {
                    runs.withLock { $0 += 1 }
                    throw ZenCODESetupError.nonInteractiveTerminal
                },
                isConfigured: { true }
            )
        }
        #expect(runs.withLock { $0 } == 1)
    }

    private func validationError(_ arguments: [String]) -> String? {
        do {
            try ZenCODESetupCommand.validateArguments(arguments)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

@Suite
struct ZenCODESetupGateTests {
    // MARK: - Message

    @Test
    func theNotConfiguredMessagePointsToSetup() {
        #expect(ZenCODESetupRequirement.notConfiguredMessage
            == "ZenCODE is not configured. Run `zen --setup` to configure it, then start zen again.")
        #expect(ZenCODESetupRequirement.NotConfiguredError().localizedDescription
            == ZenCODESetupRequirement.notConfiguredMessage)
        #expect(ZenCODESetupRequirement.NotConfiguredError().errorDescription
            == ZenCODESetupRequirement.notConfiguredMessage)
    }

    @Test
    func theJSONLErrorFrameCarriesTheConfigurationCategoryAndTheMessage() throws {
        let error = ZenCODESetupRequirement.NotConfiguredError()
        #expect(ZenCODEHeadlessJSONLProtocol.category(for: error) == "configuration")
        #expect(ZenCODEHeadlessJSONLProtocol.PublicErrorMessages.notConfigured
            == ZenCODESetupRequirement.notConfiguredMessage)

        let data = try #require(ZenCODEHeadlessJSONLProtocol.framedErrorData(error, runID: "run-1"))
        #expect(data.last == UInt8(ascii: "\n"))
        let record = try JSONDecoder().decode(JSONValue.self, from: data)
        let object = try #require(record.objectValue)
        #expect(object.keys.sorted() == ["category", "message", "run_id", "schema_version", "type"])
        #expect(object["type"]?.stringValue == "error")
        #expect(object["run_id"]?.stringValue == "run-1")
        #expect(object["schema_version"]?.intValue == ZenCODEHeadlessJSONLProtocol.schemaVersion)
        #expect(object["category"]?.stringValue == "configuration")
        #expect(object["message"]?.stringValue == ZenCODESetupRequirement.notConfiguredMessage)
    }

    // MARK: - Applicability

    @Test
    func acpIsTheOnlyModeExemptFromTheGate() {
        let noMode: [String: String] = [:]
        // Exempt: ACP by option, or by environment.
        #expect(!ZenCODESetupRequirement.gateApplies(arguments: ["zen", "--acp"], environment: noMode))
        #expect(!ZenCODESetupRequirement.gateApplies(arguments: ["zen", "--acp", "--acp"], environment: noMode))
        #expect(!ZenCODESetupRequirement.gateApplies(
            arguments: ["zen", "--acp", "--model", "provider:model"], environment: noMode
        ))
        for mode in ["acp", "ACP", "  acp\n"] {
            #expect(!ZenCODESetupRequirement.gateApplies(
                arguments: ["zen"], environment: ["ZENCODE_AGENT_MODE": mode]
            ), "\(mode)")
        }
        #expect(!ZenCODESetupRequirement.gateApplies(
            arguments: ["zen", "--agent", "Developer"], environment: ["ZENCODE_AGENT_MODE": "acp"]
        ))

        // Gated: the TUI (default, option, or environment), headless, JSONL,
        // and Telegram.
        let gated: [[String]] = [
            ["zen"],
            ["zen", "--tui"],
            ["zen", "-p", "hello"],
            ["zen", "--prompt", "hello"],
            ["zen", "-f", "/tmp/prompt.md"],
            ["zen", "--jsonl", "-p", "hello"],
            ["zen", "--telegram"],
            ["zen", "--model", "provider:model"],
        ]
        for arguments in gated {
            #expect(ZenCODESetupRequirement.gateApplies(arguments: arguments, environment: noMode), "\(arguments)")
        }
        for mode in ["tui", "headless", "telegram", "auto", "automatic"] {
            #expect(ZenCODESetupRequirement.gateApplies(
                arguments: ["zen"], environment: ["ZENCODE_AGENT_MODE": mode]
            ), "\(mode)")
        }
    }

    @Test
    func anOptionThatSelectsAnotherModeWinsOverTheACPEnvironment() {
        let acpEnvironment = ["ZENCODE_AGENT_MODE": "acp"]
        for arguments in [
            ["zen", "--tui"],
            ["zen", "--telegram"],
            ["zen", "-p", "hello"],
            ["zen", "--prompt", "hello"],
            ["zen", "-f", "/tmp/prompt.md"],
            ["zen", "--jsonl", "-p", "hello"],
        ] {
            #expect(ZenCODESetupRequirement.gateApplies(arguments: arguments, environment: acpEnvironment), "\(arguments)")
        }
    }

    @Test
    func optionValuesAreNeverReadAsModeOptions() {
        let acpEnvironment = ["ZENCODE_AGENT_MODE": "acp"]
        // The value of `--agent` (or of any other option) is not `--tui`...
        #expect(!ZenCODESetupRequirement.gateApplies(
            arguments: ["zen", "--agent", "--tui"], environment: acpEnvironment
        ))
        #expect(!ZenCODESetupRequirement.gateApplies(
            arguments: ["zen", "--working-directory", "--jsonl"], environment: acpEnvironment
        ))
        // ...nor `--acp`.
        #expect(ZenCODESetupRequirement.gateApplies(
            arguments: ["zen", "--agent", "--acp"], environment: [:]
        ))
        #expect(ZenCODESetupRequirement.gateApplies(
            arguments: ["zen", "--skills", "--acp", "--tui"], environment: [:]
        ))
    }

    // MARK: - Requirement

    @Test
    func anEmptySupportDirectoryRequiresSetup() throws {
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ZenCODESetupGate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: supportDirectory) }

        AppStorageDirectory.withSupportDirectoryURL(supportDirectory) {
            #expect(ZenCODESetupRequirement.isRequired())
        }
    }
}
