//
//  ZenCODECommandLineRunnerTests.swift
//  ZenCODE
//

import Foundation
@testable import ZenCODECore
import Synchronization
import Testing
import ToolCore

@Suite
struct ZenCODECommandLineRunnerTests {
    @Test
    func headlessArgumentRequiresAValueAndRejectsACP() {
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "-p"])
        }
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "-p", "--model", "example/model"])
        }
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "-p", "-"])
        }
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "--acp", "-p", "hello"])
        }
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "-p", "hello", "--acp"])
        }
    }

    @Test
    func jsonlArgumentSelectsHeadlessOutputAndRejectsACP() throws {
        let configuration = try AgentConfiguration(
            arguments: ["zen", "--jsonl", "-p", "summarize this", "--help"]
        )
        #expect(configuration.jsonl)
        #expect(configuration.runMode == .headless)
        #expect(configuration.headlessPrompt == "summarize this")
        try AgentConfiguration.validateArguments(["zen", "-p", "summarize this", "--jsonl"])

        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "--jsonl"])
        }
        #expect(throws: AgentConfigurationError.self) {
            try AgentConfiguration.validateArguments(["zen", "--json"])
        }
    }

    @Test
    func jsonlWriterSerializesOrderedRecordsAndFencesAfterClose() async throws {
        let lines = Mutex<[Data]>([])
        let writer = ZenCODEHeadlessJSONLWriter(runID: "run-1") { data in
            lines.withLock { $0.append(data) }
        }
        await writer.start()
        await writer.write(event: .content("hello\nworld"))
        await writer.write(result: DirectAgentResponse(
            text: "hello",
            stopReason: "stop",
            modelID: "test-model"
        ))
        await writer.close()
        await writer.write(event: .status("late"))

        let records = try lines.withLock { values in
            try values.map { data in
                try JSONDecoder().decode(JSONValue.self, from: data)
            }
        }
        #expect(records.count == 3)
        #expect(records[0].objectValue?["schema_version"]?.intValue == 1)
        #expect(records[0].objectValue?["type"]?.stringValue == "run.started")
        #expect(records[0].objectValue?["run_id"]?.stringValue == "run-1")
        #expect(records[1].objectValue?["type"]?.stringValue == "message.completed")
        #expect(records[1].objectValue?["text"]?.stringValue == "hello")
        #expect(records[2].objectValue?["type"]?.stringValue == "run.completed")
        #expect(records[2].objectValue?["status"]?.stringValue == "completed")
        #expect(records.allSatisfy { $0.objectValue?["run_id"]?.stringValue == "run-1" })
    }

    @Test
    func jsonlProtocolWritesNoRecordForAToolCallPreview() async throws {
        let fragments: [DirectAgentToolCallPreview] = [
            .toolStarted(name: "local.write"),
            .parameterStarted(name: "path"),
            .parameterText("/tmp/secret.txt"),
            .parameterEnded,
            .parameterStarted(name: "content"),
            .parameterText("secret body"),
            .parameterEnded,
            .ended,
        ]
        for fragment in fragments {
            #expect(ZenCODEHeadlessJSONLProtocol.record(
                for: .toolCallPreview(fragment),
                runID: "run-1"
            ) == nil)
        }

        let lines = Mutex<[Data]>([])
        let writer = ZenCODEHeadlessJSONLWriter(runID: "run-1") { data in
            lines.withLock { $0.append(data) }
        }
        await writer.start()
        for fragment in fragments {
            await writer.write(event: .toolCallPreview(fragment))
        }
        await writer.write(result: DirectAgentResponse(
            text: "hello",
            stopReason: "stop",
            modelID: "test-model"
        ))
        await writer.close()

        let written = lines.withLock { $0 }
        let records = try written.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
        #expect(records.compactMap { $0.objectValue?["type"]?.stringValue } == [
            "run.started", "message.completed", "run.completed",
        ])
        #expect(!written.contains { String(decoding: $0, as: UTF8.self).contains("secret") })
    }

    @Test
    func jsonlWriterExposesOnlyApprovedToolFieldsAndTerminalError() throws {
        let started = DirectAgentToolCall(
            id: "call-1",
            name: "local.read",
            argumentsObject: ["path": "/tmp/secret"],
            argumentsJSON: "{\"path\":\"/tmp/secret\"}"
        )
        let result = DirectAgentToolResult(
            output: "secret output",
            summary: "secret summary",
            status: .failed,
            attachments: [AgentRuntimeAttachment(
                kind: .image,
                originalFilename: "secret.png"
            )]
        )
        let startedRecord = ZenCODEHeadlessJSONLProtocol.record(
            for: .toolCallStarted(started),
            runID: "run-1"
        )
        let completedRecord = ZenCODEHeadlessJSONLProtocol.record(
            for: .toolCallCompleted(started, result),
            runID: "run-1"
        )
        let errorRecord = ZenCODEHeadlessJSONLProtocol.error(
            runID: "run-1",
            SensitiveHeadlessTestError()
        )

        #expect(startedRecord?.objectValue?.keys.sorted() == [
            "id", "name", "run_id", "schema_version", "type"
        ])
        #expect(completedRecord?.objectValue?.keys.sorted() == [
            "id", "name", "run_id", "schema_version", "status", "type"
        ])
        #expect(completedRecord?.objectValue?["status"]?.stringValue == "failed")
        #expect(errorRecord.objectValue?.keys.sorted() == [
            "category", "message", "run_id", "schema_version", "type"
        ])
        #expect(errorRecord.objectValue?["type"]?.stringValue == "error")
        #expect(errorRecord.objectValue?["run_id"]?.stringValue == "run-1")
        #expect(errorRecord.objectValue?["category"]?.stringValue == "runtime")
        #expect(errorRecord.objectValue?["message"]?.stringValue == "An unexpected error interrupted the run.")
        #expect(!String(decoding: try ZenCODEHeadlessJSONLProtocol.encoded(errorRecord), as: UTF8.self).contains("secret"))
    }

    @Test
    func promptFileArgumentIsAcceptedAloneAndWithInlinePromptInAnyOrder() throws {
        try AgentConfiguration.validateArguments(["zen", "-f", "/tmp/prompt.md"])
        try AgentConfiguration.validateArguments(["zen", "-p", "summarize", "-f", "/tmp/prompt.md"])
        try AgentConfiguration.validateArguments(["zen", "-f", "/tmp/prompt.md", "-p", "summarize"])
        try AgentConfiguration.validateArguments(["zen", "--jsonl", "-f", "/tmp/prompt.md"])
        try AgentConfiguration.validateArguments(["zen", "-f", "/tmp/prompt.md", "--jsonl"])
        try AgentConfiguration.validateArguments(
            ["zen", "--prompt", "summarize", "-f", "/tmp/prompt.md", "--jsonl"]
        )
    }

    @Test
    func promptFileArgumentSelectsHeadlessAndKeepsThePathAsGiven() throws {
        let fileOnly = try AgentConfiguration(arguments: ["zen", "-f", "/tmp/prompt.md", "--help"])
        #expect(fileOnly.headlessPromptFile == "/tmp/prompt.md")
        #expect(fileOnly.headlessPrompt == nil)
        #expect(fileOnly.runMode == .headless)
        #expect(!fileOnly.jsonl)

        let both = try AgentConfiguration(
            arguments: ["zen", "-f", "/tmp/prompt.md", "-p", "summarize", "--help"]
        )
        #expect(both.headlessPromptFile == "/tmp/prompt.md")
        #expect(both.headlessPrompt == "summarize")
        #expect(both.runMode == .headless)

        let jsonl = try AgentConfiguration(arguments: ["zen", "--jsonl", "-f", "/tmp/prompt.md", "--help"])
        #expect(jsonl.headlessPromptFile == "/tmp/prompt.md")
        #expect(jsonl.jsonl)
        #expect(jsonl.runMode == .headless)

        let inlineOnly = try AgentConfiguration(arguments: ["zen", "-p", "summarize", "--help"])
        #expect(inlineOnly.headlessPromptFile == nil)
        #expect(try makeHeadlessConfiguration(jsonl: false).headlessPromptFile == nil)
    }

    @Test
    func promptFileArgumentRejectsInvalidValuesAndConflicts() {
        #expect(promptArgumentError(["-f"]) == "Missing value for -f.")
        #expect(promptArgumentError(["-f", "--model"]) == "Missing value for -f.")
        #expect(promptArgumentError(["-f", "-x"]) == "Missing value for -f.")
        #expect(promptArgumentError(["-f", "-"]) == "Invalid value for -f: -")
        #expect(promptArgumentError(["-f", "relative.md"]) == "Invalid value for -f: relative.md")
        #expect(promptArgumentError(["-f", "./prompt.md"]) == "Invalid value for -f: ./prompt.md")
        #expect(promptArgumentError(["-f", "~/prompt.md"]) == "Invalid value for -f: ~/prompt.md")
        #expect(promptArgumentError(["-f", "/a", "-f", "/b"]) == "Options -f and -f cannot be combined.")
        #expect(promptArgumentError(["--acp", "-f", "/a"]) == "Options --acp and -f cannot be combined.")
        #expect(promptArgumentError(["-f", "/a", "--acp"]) == "Options --acp and -f cannot be combined.")
    }

    @Test
    func modeArgumentsSelectTheirRunMode() throws {
        // `--help` keeps the parser from reading the persisted configuration.
        let tui = try AgentConfiguration(arguments: ["zen", "--tui", "--help"])
        #expect(tui.runMode == .tui)
        #expect(tui.resolvedRunMode(stdinIsTerminal: true) == .tui)

        let telegram = try AgentConfiguration(arguments: ["zen", "--telegram", "--help"])
        #expect(telegram.runMode == .telegram)
        #expect(telegram.resolvedRunMode(stdinIsTerminal: false) == .telegram)

        let acp = try AgentConfiguration(arguments: ["zen", "--acp", "--help"])
        #expect(acp.runMode == .acp)
        #expect(acp.resolvedRunMode(stdinIsTerminal: false) == .acp)
    }

    @Test
    func repeatingTheSameModeArgumentIsAllowed() throws {
        let modes: [(flag: String, runMode: AgentRunMode)] = [
            ("--tui", .tui), ("--telegram", .telegram), ("--acp", .acp)
        ]
        for (flag, runMode) in modes {
            try AgentConfiguration.validateArguments(["zen", flag, flag])
            let configuration = try AgentConfiguration(arguments: ["zen", flag, "--agent", "Developer", flag, "--help"])
            #expect(configuration.runMode == runMode)
        }
    }

    @Test
    func withoutAModeOptionTheRunModeIsTheTUIAndTheACPBridgeInTheApp() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
        let hosted = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            workingDirectory: workingDirectory
        )
        #expect(hosted.runMode == .tui)
        #expect(hosted.resolvedRunMode(stdinIsTerminal: true) == .tui)

        // `--help` keeps the parser from reading the persisted configuration.
        let withoutModeOption = try AgentConfiguration(arguments: ["zen", "--help"])
        #expect(withoutModeOption.runMode == .tui)
        #expect(withoutModeOption.resolvedRunMode(stdinIsTerminal: true) == .tui)

        let withoutModeOptionInTheApp = try AgentConfiguration(
            arguments: ["zen", "--help"],
            appModeOverride: true
        )
        #expect(withoutModeOptionInTheApp.runMode == .acp)
        #expect(withoutModeOptionInTheApp.resolvedRunMode(stdinIsTerminal: true) == .acp)

        let telegramInTheApp = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            runMode: .telegram,
            workingDirectory: workingDirectory,
            appMode: true
        )
        #expect(telegramInTheApp.resolvedRunMode(stdinIsTerminal: false) == .telegram)
    }

    @Test(arguments: ["--tui", "--telegram"])
    func aModeArgumentConflictsWithEveryHeadlessOptionInAnyOrder(flag: String) {
        let promptConflict = "Options \(flag) and -p/--prompt cannot be combined."
        #expect(promptArgumentError([flag, "-p", "x"]) == promptConflict)
        #expect(promptArgumentError(["-p", "x", flag]) == promptConflict)
        #expect(promptArgumentError([flag, "--prompt", "x"]) == promptConflict)
        #expect(promptArgumentError(["--prompt", "x", flag]) == promptConflict)

        let fileConflict = "Options \(flag) and -f cannot be combined."
        #expect(promptArgumentError([flag, "-f", "/a"]) == fileConflict)
        #expect(promptArgumentError(["-f", "/a", flag]) == fileConflict)

        let jsonlConflict = "Options \(flag) and --jsonl cannot be combined."
        #expect(promptArgumentError([flag, "--jsonl"]) == jsonlConflict)
        #expect(promptArgumentError(["--jsonl", flag]) == jsonlConflict)
        #expect(promptArgumentError([flag, "--jsonl", "-p", "x"]) == jsonlConflict)
        #expect(promptArgumentError(["-p", "x", "--jsonl", flag]) == promptConflict)
    }

    @Test
    func differentModeArgumentsConflictNamingTheOneThatArrivesFirst() {
        let modes = ["--tui", "--telegram", "--acp"]
        for seen in modes {
            for arriving in modes where arriving != seen {
                #expect(
                    promptArgumentError([seen, arriving])
                        == "Options \(arriving) and \(seen) cannot be combined."
                )
            }
        }
        // The conflict wins over a later repetition of the first flag.
        #expect(
            promptArgumentError(["--tui", "--telegram", "--tui"])
                == "Options --telegram and --tui cannot be combined."
        )
    }

    @Test
    func worktreeArgumentRecordsTheLastNameWithTheWorkingDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-worktree-arguments-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let configuration = try AgentConfiguration.withoutPersistedConfiguration(arguments: [
            "zen", "--worktree", "first", "--working-directory", directory.path, "--worktree", "feature-1"
        ])
        let worktree = try #require(configuration.worktree)
        #expect(worktree.name == "feature-1")
        #expect(worktree.directory == configuration.workingDirectory)
        #expect(worktree.directory.path == directory.resolvingSymlinksInPath().path)

        // The terminal chat accepts a worktree in either order.
        for arguments in [["zen", "--tui", "--worktree", "x"], ["zen", "--worktree", "x", "--tui"]] {
            let terminal = try AgentConfiguration.withoutPersistedConfiguration(arguments: arguments)
            #expect(terminal.worktree?.name == "x")
            #expect(terminal.runMode == .tui)
        }
        #expect(try AgentConfiguration.withoutPersistedConfiguration(arguments: ["zen"]).worktree == nil)
        #expect(try AgentConfiguration(
            hostedModelID: "remote-community/test",
            workingDirectory: directory
        ).worktree == nil)
        #expect(AgentConfiguration.helpText.contains("[--working-directory PATH] [--worktree NAME]"))
    }

    @Test(arguments: ["a/b", "a\\b", "-x", "--tui", "a b", "tab\tname", "", ".", ".."])
    func worktreeArgumentRejectsAnInvalidName(name: String) {
        #expect(promptArgumentError(["--worktree", name]) == "Invalid value for --worktree: \(name)")
    }

    @Test
    func worktreeArgumentRequiresAValue() {
        #expect(promptArgumentError(["--worktree"]) == "Missing value for --worktree.")
        #expect(promptArgumentError(["--tui", "--worktree"]) == "Missing value for --worktree.")
    }

    @Test
    func worktreeArgumentConflictsWithEveryNonTerminalModeInAnyOrder() {
        for flag in ["--acp", "--telegram"] {
            let conflict = "Options --worktree and \(flag) cannot be combined."
            #expect(promptArgumentError(["--worktree", "x", flag]) == conflict)
            #expect(promptArgumentError([flag, "--worktree", "x"]) == conflict)
        }

        let promptConflict = "Options --worktree and -p/--prompt cannot be combined."
        #expect(promptArgumentError(["--worktree", "x", "-p", "hello"]) == promptConflict)
        #expect(promptArgumentError(["--prompt", "hello", "--worktree", "x"]) == promptConflict)

        let fileConflict = "Options --worktree and -f cannot be combined."
        #expect(promptArgumentError(["--worktree", "x", "-f", "/a"]) == fileConflict)
        #expect(promptArgumentError(["-f", "/a", "--worktree", "x"]) == fileConflict)

        let jsonlConflict = "Options --worktree and --jsonl cannot be combined."
        #expect(promptArgumentError(["--worktree", "x", "--jsonl", "-p", "hello"]) == jsonlConflict)
        #expect(promptArgumentError(["--jsonl", "--worktree", "x"]) == jsonlConflict)
        // Like the mode flags, an earlier prompt is named before `--jsonl`.
        #expect(promptArgumentError(["--jsonl", "-p", "hello", "--worktree", "x"]) == promptConflict)
    }

    @Test
    func jsonlErrorsUseOnlyClosedCategoriesAndRedactedMessages() throws {
        #expect(Set(ZenCODEHeadlessJSONLProtocol.ErrorCategory.allCases.map(\.rawValue)) == [
            "configuration", "provider", "runtime"
        ])

        let sensitive = ZenCODEHeadlessJSONLProtocol.error(
            runID: "redacted",
            SensitiveHeadlessTestError()
        )
        let encoded = String(
            decoding: try ZenCODEHeadlessJSONLProtocol.encoded(sensitive),
            as: UTF8.self
        )
        #expect(!encoded.contains("/Users/alice/.secrets/token"))
        #expect(!encoded.contains("sk-private"))
        #expect(sensitive.objectValue?["category"]?.stringValue == "runtime")
        #expect(sensitive.objectValue?["message"]?.stringValue == "An unexpected error interrupted the run.")

        let transport = ZenCODEHeadlessJSONLProtocol.error(
            runID: "transport",
            URLError(.timedOut)
        )
        #expect(transport.objectValue?["category"]?.stringValue == "provider")
        #expect(transport.objectValue?["message"]?.stringValue == "An unexpected error interrupted the run.")

        let invalid = ZenCODEHeadlessJSONLProtocol.error(
            runID: "configuration",
            AgentConfigurationError.unknownArgument("--token=sk-private")
        )
        #expect(invalid.objectValue?["category"]?.stringValue == "configuration")
        #expect(invalid.objectValue?["message"]?.stringValue == "Invalid command-line arguments.")
    }

    private func promptArgumentError(_ arguments: [String]) -> String? {
        do {
            try AgentConfiguration.validateArguments(["zen"] + arguments)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

private struct SensitiveHeadlessTestError: LocalizedError {
    var errorDescription: String? {
        "provider failed at /Users/alice/.secrets/token using sk-private"
    }
}
