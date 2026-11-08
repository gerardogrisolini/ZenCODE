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
    func recognizedCommandLineOptionsStillRouteToTheCommandLine() {
        let bundleExecutable = "/Applications/ZenCODE.app/Contents/MacOS/ZenCODE"
        for option in [
            "--version", "--doctor", "--acp", "--tui", "--telegram", "-p", "-f", "--prompt", "--jsonl",
            "--model", "--max-tool-rounds"
        ] {
            #expect(
                ZenCODECommandLineRunner.shouldRunAsCommandLine(
                    arguments: [bundleExecutable, option]
                )
            )
        }
    }

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
    func jsonlWriterExposesOnlyApprovedToolFieldsAndTerminalError() throws {
        let started = DirectAgentToolCall(
            id: "call-1",
            name: "local.readFile",
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
    func automaticRunModeResolvesToTheTUIAndToACPInTheApp() throws {
        let workingDirectory = FileManager.default.temporaryDirectory
        let defaultMode = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            workingDirectory: workingDirectory
        )
        #expect(defaultMode.runMode == .tui)
        #expect(defaultMode.resolvedRunMode(stdinIsTerminal: true) == .tui)

        let automatic = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            runMode: .automatic,
            workingDirectory: workingDirectory
        )
        #expect(automatic.resolvedRunMode(stdinIsTerminal: true) == .tui)

        let automaticInTheApp = try AgentConfiguration(
            hostedModelID: "remote-community/test",
            runMode: .automatic,
            workingDirectory: workingDirectory,
            appMode: true
        )
        #expect(automaticInTheApp.resolvedRunMode(stdinIsTerminal: true) == .acp)

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
    func headlessPromptUsesPipedContext() throws {
        #expect(
            try ZenCODEHeadlessRunner.prompt(
                inlinePrompt: "explain",
                stdin: pipe(containing: "build log\n"),
                stdinIsTerminal: false
            ) == "explain\n\nAdditional context from stdin:\nbuild log"
        )
        #expect(
            try ZenCODEHeadlessRunner.prompt(
                inlinePrompt: "explain",
                stdin: pipe(containing: "ignored"),
                stdinIsTerminal: true
            ) == "explain"
        )
    }

    @Test
    func headlessPromptWithoutInlineOrFileFailsBeforeReadingStdin() throws {
        let stdin = try pipe(containing: "build log")
        #expect(throws: ZenCODEHeadlessRunnerError.self) {
            try ZenCODEHeadlessRunner.prompt(
                inlinePrompt: nil,
                promptFile: nil,
                stdin: stdin,
                stdinIsTerminal: false
            )
        }
        #expect(String(decoding: stdin.readDataToEndOfFile(), as: UTF8.self) == "build log")
    }

    @Test
    func headlessPromptAddsPipedContextAfterTheFile() throws {
        try withPromptDirectory { directory in
            let path = try writePromptFile("summarize\n", in: directory)
            #expect(
                try ZenCODEHeadlessRunner.prompt(
                    inlinePrompt: nil,
                    promptFile: path,
                    stdin: pipe(containing: "build log\n"),
                    stdinIsTerminal: false
                ) == "summarize\n\nAdditional context from stdin:\nbuild log"
            )
            #expect(
                try ZenCODEHeadlessRunner.prompt(
                    inlinePrompt: "explain",
                    promptFile: path,
                    stdin: pipe(containing: "build log\n"),
                    stdinIsTerminal: false
                ) == "explain\n\nAdditional context from file:\nsummarize\n\nAdditional context from stdin:\nbuild log"
            )
        }
    }

    @Test
    func headlessPromptReportsPromptFileFailuresBeforeReadingStdin() throws {
        try withPromptDirectory { directory in
            let missing = directory.appendingPathComponent("missing.md").path
            let stdin = try pipe(containing: "build log")
            #expect(throws: ZenCODEPromptFileError.unreadable(path: missing)) {
                try ZenCODEHeadlessRunner.prompt(
                    inlinePrompt: "explain",
                    promptFile: missing,
                    stdin: stdin,
                    stdinIsTerminal: false
                )
            }
            #expect(String(decoding: stdin.readDataToEndOfFile(), as: UTF8.self) == "build log")

            #expect(throws: ZenCODEPromptFileError.unreadable(path: directory.path)) {
                try ZenCODEHeadlessRunner.prompt(
                    inlinePrompt: nil,
                    promptFile: directory.path,
                    stdinIsTerminal: true
                )
            }
            #expect(throws: ZenCODEPromptFileError.notAbsolute(path: "prompt.md")) {
                try ZenCODEHeadlessRunner.prompt(
                    inlinePrompt: "explain",
                    promptFile: "prompt.md",
                    stdinIsTerminal: true
                )
            }
        }
    }

    @Test
    func promptFileReaderClassifiesEveryFailure() throws {
        #expect(ZenCODEPromptFile.isAbsolutePath("/tmp/prompt.md"))
        #expect(!ZenCODEPromptFile.isAbsolutePath("prompt.md"))
        #expect(!ZenCODEPromptFile.isAbsolutePath("~/prompt.md"))
        #expect(!ZenCODEPromptFile.isAbsolutePath(""))

        try withPromptDirectory { directory in
            let missing = directory.appendingPathComponent("missing.md").path
            #expect(throws: ZenCODEPromptFileError.unreadable(path: missing)) {
                try ZenCODEPromptFile.read(path: missing)
            }
            #expect(throws: ZenCODEPromptFileError.unreadable(path: directory.path)) {
                try ZenCODEPromptFile.read(path: directory.path)
            }
            #expect(throws: ZenCODEPromptFileError.notAbsolute(path: "relative.md")) {
                try ZenCODEPromptFile.read(path: "relative.md")
            }

            let empty = try writePromptFile("", named: "empty.md", in: directory)
            #expect(throws: ZenCODEPromptFileError.empty(path: empty)) {
                try ZenCODEPromptFile.read(path: empty)
            }
            let blank = try writePromptFile(" \n\t\r\n ", named: "blank.md", in: directory)
            #expect(throws: ZenCODEPromptFileError.empty(path: blank)) {
                try ZenCODEPromptFile.read(path: blank)
            }

            let binary = directory.appendingPathComponent("binary.bin")
            try Data([0xFF, 0xFE, 0x41, 0x80]).write(to: binary)
            #expect(throws: ZenCODEPromptFileError.notUTF8(path: binary.path)) {
                try ZenCODEPromptFile.read(path: binary.path)
            }

            let accented = try writePromptFile("\n  Riassumi le modifiche: è già così ✓\n", named: "utf8.md", in: directory)
            #expect(try ZenCODEPromptFile.read(path: accented) == "Riassumi le modifiche: è già così ✓")
        }
    }

    @Test
    func jsonlPromptFileErrorsAreGenericAndNeverCarryThePath() throws {
        let path = "/Users/alice/.secrets/prompt.md"
        let errors: [ZenCODEPromptFileError] = [
            .notAbsolute(path: path),
            .unreadable(path: path),
            .notUTF8(path: path),
            .empty(path: path)
        ]
        for error in errors {
            let publicError = ZenCODEHeadlessJSONLProtocol.publicError(for: error)
            #expect(publicError.category == .configuration)
            #expect(
                publicError.publicMessage
                    == ZenCODEHeadlessJSONLProtocol.PublicErrorMessages.invalidPromptFile
            )
            #expect(!publicError.publicMessage.contains(path))

            let record = ZenCODEHeadlessJSONLProtocol.error(runID: "prompt-file", error)
            let encoded = String(
                decoding: try ZenCODEHeadlessJSONLProtocol.encoded(record),
                as: UTF8.self
            )
            #expect(!encoded.contains(path))
            #expect(!encoded.contains("secrets"))
            #expect(record.objectValue?["category"]?.stringValue == "configuration")
            #expect(
                record.objectValue?["message"]?.stringValue
                    == "The prompt file is missing, unreadable, empty, or not UTF-8 text."
            )
        }

        let noPrompt = ZenCODEHeadlessJSONLProtocol.publicError(for: ZenCODEHeadlessRunnerError.noPrompt)
        #expect(noPrompt.publicMessage == "No prompt provided. Pass text after -p/--prompt.")
        let missingFileValue = ZenCODEHeadlessJSONLProtocol.publicError(
            for: AgentConfigurationError.missingValue("-f")
        )
        #expect(missingFileValue.category == .configuration)
        #expect(missingFileValue.publicMessage == "Invalid command-line arguments.")
    }

    /// The run mode of the environment is validated before the other values,
    /// so the error of an invalid `--max-tool-rounds` shows that it was accepted.
    @Test(arguments: ["tui", "telegram", " TUI ", "Telegram", "acp", "headless", "auto", "automatic"])
    func zenExecutableAcceptsTheRunModesOfTheEnvironment(mode: String) throws {
        let result = try runZen(
            zenExecutableURL(),
            arguments: ["--max-tool-rounds", "abc"],
            environment: makeEnvironment(runMode: mode)
        )
        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        #expect(
            String(decoding: result.stderr, as: UTF8.self)
                == "ZenCODE: Invalid value for --max-tool-rounds: abc\n"
        )
    }

    @Test(arguments: ["chat", "Chat", " chat "])
    func zenExecutableRejectsTheRemovedChatRunModeOfTheEnvironment(mode: String) throws {
        let result = try runZen(
            zenExecutableURL(),
            arguments: ["--max-tool-rounds", "abc"],
            environment: makeEnvironment(runMode: mode)
        )
        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        #expect(
            String(decoding: result.stderr, as: UTF8.self)
                == "ZenCODE: Invalid value for --mode: \(mode)\n"
        )
    }

    @Test
    func zenExecutableStopsEveryModeButACPAtTheSetupGate() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-setup-gate-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        let invocations: [(arguments: [String], runMode: String?)] = [
            (arguments: [], runMode: nil),
            (arguments: ["--tui"], runMode: nil),
            (arguments: [], runMode: "tui"),
            (arguments: ["-p", "hello"], runMode: nil),
            (arguments: ["-f", "/tmp/zencode-setup-gate-prompt.md"], runMode: nil),
            (arguments: [], runMode: "headless"),
            (arguments: ["--telegram"], runMode: nil),
            (arguments: [], runMode: "telegram"),
            // An option that selects another mode wins over the ACP environment.
            (arguments: ["--tui"], runMode: "acp"),
        ]
        for invocation in invocations {
            var environment = makeEnvironment(runMode: invocation.runMode)
            environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = supportURL.path

            // No terminal input: the gate stops each mode before it could wait for any.
            let result = try runZen(
                zenExecutableURL(),
                arguments: invocation.arguments,
                environment: environment,
                standardInput: FileHandle.nullDevice
            )

            #expect(result.exitCode == 1, "\(invocation)")
            #expect(result.stdout.isEmpty, "\(invocation)")
            #expect(
                String(decoding: result.stderr, as: UTF8.self)
                    == "ZenCODE is not configured. Run `zen --setup` to configure it, then start zen again.\n",
                "\(invocation)"
            )
        }
    }

    @Test
    func zenExecutableFramesTheSetupGateErrorWithJSONL() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-setup-gate-jsonl-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        var environment = makeEnvironment(runMode: nil)
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = supportURL.path

        let result = try runZen(
            zenExecutableURL(),
            arguments: ["--jsonl", "-p", "hello"],
            environment: environment,
            standardInput: FileHandle.nullDevice
        )

        #expect(result.exitCode == 1)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.last == 0x0A)
        #expect(result.stdout.filter { $0 == 0x0A }.count == 1)
        let record = try JSONDecoder().decode(JSONValue.self, from: result.stdout)
        #expect(record.objectValue?["type"]?.stringValue == "error")
        #expect(record.objectValue?["category"]?.stringValue == "configuration")
        #expect(record.objectValue?["message"]?.stringValue == ZenCODESetupRequirement.notConfiguredMessage)
    }

    /// Only the refusals: a valid `zen --setup` would open the setup on the
    /// controlling terminal of the test run, if any.
    @Test
    func zenExecutableRefusesSetupWithAnyOtherOptionAsText() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-setup-conflict-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        var environment = makeEnvironment(runMode: nil)
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = supportURL.path

        let invocations: [(arguments: [String], conflicting: String)] = [
            (arguments: ["--setup", "--tui"], conflicting: "--tui"),
            (arguments: ["--acp", "--setup"], conflicting: "--acp"),
            (arguments: ["--setup", "-p", "hello"], conflicting: "-p"),
            // Always textual, even with `--jsonl`.
            (arguments: ["--jsonl", "--setup"], conflicting: "--jsonl"),
            (arguments: ["--setup", "--model", "provider:model"], conflicting: "--model"),
        ]
        for invocation in invocations {
            let result = try runZen(
                zenExecutableURL(),
                arguments: invocation.arguments,
                environment: environment,
                standardInput: FileHandle.nullDevice
            )
            #expect(result.exitCode == 1, "\(invocation.arguments)")
            #expect(result.stdout.isEmpty, "\(invocation.arguments)")
            #expect(
                String(decoding: result.stderr, as: UTF8.self)
                    == "ZenCODE: Options --setup and \(invocation.conflicting) cannot be combined.\n",
                "\(invocation.arguments)"
            )
        }
        // Refused before the setup and the migration: nothing was written.
        #expect(!FileManager.default.fileExists(atPath: supportURL.path))
    }

    #if os(macOS)
    @Test
    func zenExecutableRefusesAnOptionOfAnotherModeWithTheAppBeforeSetup() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ui-conflict-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        var environment = ProcessInfo.processInfo.environment
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = supportURL.path

        let result = try runZen(zenExecutableURL(), arguments: ["--ui", "-p", "x"], environment: environment)

        #expect(result.exitCode == 1)
        #expect(String(decoding: result.stderr, as: UTF8.self) == "ZenCODE: Options --ui and -p cannot be combined.\n")
        #expect(result.stdout.isEmpty)
        // Refused before the setup gate: nothing was written for setup or the app.
        #expect(!FileManager.default.fileExists(atPath: supportURL.path))
    }

    @Test
    func zenExecutableDoesNotOpenTheAppWithoutConfiguration() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ui-unconfigured-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        var environment = makeEnvironment(runMode: nil)
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = supportURL.path

        let result = try runZen(
            zenExecutableURL(),
            arguments: ["--ui", "--agent", "Developer"],
            environment: environment,
            standardInput: FileHandle.nullDevice
        )

        #expect(result.exitCode == 1)
        #expect(result.stdout.isEmpty)
        #expect(
            String(decoding: result.stderr, as: UTF8.self)
                == "ZenCODE is not configured. Run `zen --setup` to configure it, then start zen again.\n"
        )
        // Stopped at the gate: the app was neither built nor installed.
        #expect(!FileManager.default.fileExists(
            atPath: ZenAppInstallation.Layout(supportDirectory: supportURL).logFile.path
        ))
    }
    #else
    @Test
    func zenExecutableTreatsTheAppOptionAsUnknownOutsideMacOS() throws {
        let supportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-ui-unknown-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: supportURL)
        }
        var environment = ProcessInfo.processInfo.environment
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = supportURL.path

        let result = try runZen(zenExecutableURL(), arguments: ["--ui"], environment: environment)

        #expect(result.exitCode == 1)
        #expect(String(decoding: result.stderr, as: UTF8.self) == "ZenCODE: Unknown argument: --ui\n")
        #expect(result.stdout.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: supportURL.path))
    }
    #endif

    @Test
    func jsonlIsIgnoredForEveryTextualMetaCommand() throws {
        let conflictingFlags = ["--acp", "-p", "ignored"]
        for option in ["--help", "-h", "--version", "--doctor", "--install-features", "--install-features=git-tools"] {
            #expect(!ZenCODECommandLineRunner.jsonlIsActive(
                arguments: ["zen", "--jsonl", option] + conflictingFlags
            ))
        }
        #expect(ZenCODECommandLineRunner.jsonlIsActive(arguments: ["zen", "--jsonl", "-p", "hello"]))

        let help = try AgentConfiguration(arguments: ["zen", "--jsonl", "--help"])
        let version = try AgentConfiguration(arguments: ["zen", "--jsonl", "--version"])
        let doctor = try AgentConfiguration(arguments: ["zen", "--jsonl", "--doctor"])
        #expect(help.printHelp)
        #expect(version.printVersion)
        #expect(doctor.printDoctor)
    }

    @Test
    func zenExecutableMetaCommandsKeepTextOutputAndExitSemanticsWithJSONL() throws {
        let executable = try zenExecutableURL()
        let invocations = [
            ["--help", "--acp", "-p", "ignored"],
            ["--version", "--acp", "-p", "ignored"],
            ["--doctor", "--acp", "-p", "ignored"],
            ["--install-features", "--no-features", "--acp", "-p", "ignored"]
        ]
        var environment = ProcessInfo.processInfo.environment
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("zencode-meta-command-test-\(UUID().uuidString)", isDirectory: true)
            .path

        for arguments in invocations {
            let ordinary = try runZen(executable, arguments: arguments, environment: environment)
            let withJSONL = try runZen(executable, arguments: ["--jsonl"] + arguments, environment: environment)
            #expect(withJSONL.exitCode == ordinary.exitCode)
            #expect(withJSONL.stdout == ordinary.stdout)
            #expect(withJSONL.stderr == ordinary.stderr)
        }
    }

    /// `ZenCODEStandaloneHelp` builds the executable's help with exact string
    /// replacements over `AgentConfiguration.helpText`, which change nothing
    /// when the text drifts: only the real output shows that they matched.
    @Test
    func zenExecutableHelpListsSetupAfterDoctorAndNoSlashSetup() throws {
        var environment = ProcessInfo.processInfo.environment
        environment[AppStorageDirectory.supportDirectoryEnvironmentKey] = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("zencode-help-test-\(UUID().uuidString)", isDirectory: true)
            .path

        let result = try runZen(zenExecutableURL(), arguments: ["--help"], environment: environment)

        #expect(result.exitCode == 0)
        #expect(result.stderr.isEmpty)
        let help = String(decoding: result.stdout, as: UTF8.self)
        #expect(help.contains("zen [--doctor] [--setup] [--install-features"))

        let lines = help.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let doctorIndex = try #require(lines.firstIndex { $0.hasPrefix("  --doctor ") })
        #expect(lines.indices.contains(doctorIndex + 1))
        #expect(lines[doctorIndex + 1].hasPrefix("  --setup "))
        #expect(lines.filter { $0.hasPrefix("  --setup ") }.count == 1)
        let telegramLine = try #require(lines.first { $0.hasPrefix("  --telegram ") })
        #expect(telegramLine.hasSuffix("paired with zen --setup)."))
        #expect(!help.contains("/setup"))
    }

    @Test
    func zenExecutableEarlyJSONLErrorOwnsStdoutAndExitOne() throws {
        let result = try runZen(zenExecutableURL(), arguments: ["--jsonl"])
        #expect(result.exitCode == 1)
        #expect(result.stderr.isEmpty)
        #expect(result.stdout.last == 0x0A)
        #expect(result.stdout.filter { $0 == 0x0A }.count == 1)

        let record = try JSONDecoder().decode(JSONValue.self, from: result.stdout)
        #expect(record.objectValue?["type"]?.stringValue == "error")
        #expect(record.objectValue?["category"]?.stringValue == "configuration")
        #expect(record.objectValue?["message"]?.stringValue == "No prompt provided. Pass text after -p/--prompt.")
    }

    @Test
    func jsonlErrorsUseOnlyClosedCategoriesAndRedactedMessages() throws {
        #expect(Set(ZenCODEHeadlessJSONLProtocol.errorCategories) == [
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

    @Test
    func jsonlRunnerFramesEachRecordInOneSinkCallAndEscapesMultilineText() async throws {
        let output = Mutex<[Data]>([])
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(
                text: "first line\nsecond line",
                stopReason: "stop",
                modelID: "test-model"
            ),
            events: [.content("first line\nsecond line"), .turnEnded(.completed)]
        )
        try await ZenCODEHeadlessRunner.runTurn(
            configuration: makeHeadlessConfiguration(jsonl: true),
            prompt: "hello",
            sessionRunner: runner,
            sessionConfiguration: makeSessionConfiguration(),
            jsonlSink: { data in output.withLock { $0.append(data) } }
        )

        let writes = output.withLock { $0 }
        #expect(writes.count == 3)
        #expect(writes.allSatisfy { $0.last == 0x0A })
        #expect(writes.allSatisfy { data in data.dropLast().allSatisfy { $0 != 0x0A } })
        let records = try decodeRecords(writes)
        #expect(records.map { $0.objectValue?["type"]?.stringValue } == [
            "run.started", "message.completed", "run.completed"
        ])
        #expect(records[1].objectValue?["text"]?.stringValue == "first line\nsecond line")
        #expect(await runner.lifecycle() == ["create", "send", "close", "shutdown"])
    }

    @Test
    func failedToolEventIsNonTerminalAndRunStillCompletes() async throws {
        let output = Mutex<[Data]>([])
        let toolCall = DirectAgentToolCall(
            id: "tool-1",
            name: "local.readFile",
            argumentsObject: ["path": "/private/input"],
            argumentsJSON: "{\"path\":\"/private/input\"}"
        )
        let toolResult = DirectAgentToolResult(
            output: "private failure detail",
            summary: "private summary",
            status: .failed
        )
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(text: "recovered", stopReason: "stop", modelID: "test"),
            events: [
                .toolCallStarted(toolCall),
                .toolCallCompleted(toolCall, toolResult),
                .turnEnded(.completed)
            ]
        )

        try await ZenCODEHeadlessRunner.runTurn(
            configuration: makeHeadlessConfiguration(jsonl: true),
            prompt: "hello",
            sessionRunner: runner,
            sessionConfiguration: makeSessionConfiguration(),
            jsonlSink: { data in output.withLock { $0.append(data) } }
        )

        let records = try decodeRecords(output.withLock { $0 })
        #expect(records.map { $0.objectValue?["type"]?.stringValue } == [
            "run.started", "tool.started", "tool.completed", "message.completed", "run.completed"
        ])
        #expect(records[2].objectValue?["status"]?.stringValue == "failed")
        #expect(!records.contains { $0.objectValue?["type"]?.stringValue == "error" })
        let wire = output.withLock { String(decoding: Data($0.joined()), as: UTF8.self) }
        #expect(!wire.contains("private failure detail"))
        #expect(!wire.contains("private summary"))
    }

    @Test
    func emptyJSONLResponseClosesOnceAndEmitsOneTerminalError() async throws {
        let output = Mutex<[Data]>([])
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(text: " \n ", stopReason: "stop", modelID: "test")
        )

        await #expect(throws: ZenCODEHeadlessRunnerError.self) {
            try await ZenCODEHeadlessRunner.runTurn(
                configuration: makeHeadlessConfiguration(jsonl: true),
                prompt: "hello",
                sessionRunner: runner,
                sessionConfiguration: makeSessionConfiguration(),
                jsonlSink: { data in output.withLock { $0.append(data) } }
            )
        }

        let records = try decodeRecords(output.withLock { $0 })
        #expect(records.map { $0.objectValue?["type"]?.stringValue } == ["run.started", "error"])
        #expect(records[1].objectValue?["category"]?.stringValue == "runtime")
        #expect(await runner.lifecycle() == ["create", "send", "close", "shutdown"])
    }

    @Test
    func teardownFailureEmitsNoSuccessAndDoesNotCloseTwice() async throws {
        let output = Mutex<[Data]>([])
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(text: "would succeed", stopReason: "stop", modelID: "test"),
            failure: .close
        )

        await #expect(throws: ControlledHeadlessSessionRunner.Failure.self) {
            try await ZenCODEHeadlessRunner.runTurn(
                configuration: makeHeadlessConfiguration(jsonl: true),
                prompt: "hello",
                sessionRunner: runner,
                sessionConfiguration: makeSessionConfiguration(),
                jsonlSink: { data in output.withLock { $0.append(data) } }
            )
        }

        let records = try decodeRecords(output.withLock { $0 })
        #expect(records.map { $0.objectValue?["type"]?.stringValue } == ["run.started", "error"])
        #expect(records[1].objectValue?["category"]?.stringValue == "runtime")
        #expect(records[1].objectValue?["message"]?.stringValue == "The session could not be finalized cleanly.")
        #expect(await runner.lifecycle() == ["create", "send", "close", "shutdown"])
    }

    @Test
    func legacyHeadlessRunnerStillWritesOnlyFinalTextWithOneTrailingNewline() async throws {
        let textOutput = Mutex<[String]>([])
        let jsonlOutput = Mutex<[Data]>([])
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(text: "legacy\ntext", stopReason: "stop", modelID: "test"),
            events: [.status("hidden"), .content("hidden stream"), .turnEnded(.completed)]
        )

        try await ZenCODEHeadlessRunner.runTurn(
            configuration: makeHeadlessConfiguration(jsonl: false),
            prompt: "hello",
            sessionRunner: runner,
            sessionConfiguration: makeSessionConfiguration(),
            jsonlSink: { data in jsonlOutput.withLock { $0.append(data) } },
            textSink: { text in textOutput.withLock { $0.append(text) } }
        )

        #expect(jsonlOutput.withLock { $0.isEmpty })
        #expect(textOutput.withLock { $0 } == ["legacy\ntext\n"])
        #expect(await runner.lifecycle() == ["create", "send", "close", "shutdown"])
    }

    @Test
    func legacyHeadlessPreservesSuccessWhenTeardownFails() async throws {
        let textOutput = Mutex<[String]>([])
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(text: "legacy output", stopReason: "stop", modelID: "test"),
            failure: .close
        )

        try await ZenCODEHeadlessRunner.runTurn(
            configuration: makeHeadlessConfiguration(jsonl: false),
            prompt: "hello",
            sessionRunner: runner,
            sessionConfiguration: makeSessionConfiguration(),
            textSink: { text in textOutput.withLock { $0.append(text) } }
        )

        #expect(textOutput.withLock { $0 } == ["legacy output\n"])
        #expect(await runner.lifecycle() == ["create", "send", "close", "shutdown"])
    }

    @Test
    func headlessTurnInstallsTheSelectedPromptSkillsWhenItCreatesTheSession() async throws {
        let skill = PromptSkill(
            canonicalName: "review",
            title: "Review",
            summary: "Review changes.",
            promptBody: "Review the changes.",
            sourceHash: "review-hash"
        )
        let runner = ControlledHeadlessSessionRunner(
            response: DirectAgentResponse(text: "done", stopReason: "stop", modelID: "test")
        )

        try await ZenCODEHeadlessRunner.runTurn(
            configuration: makeHeadlessConfiguration(jsonl: false),
            prompt: "hello",
            sessionRunner: runner,
            sessionConfiguration: makeSessionConfiguration(),
            promptSkills: [skill],
            textSink: { _ in }
        )

        #expect(await runner.promptSkillsAtCreation() == [skill])
        #expect(await runner.lifecycle() == ["create", "send", "close", "shutdown"])
    }

    @Test
    func mailDeliveryCaptureReceivesTheSameJSONLRecordsAsStandardOutput() async throws {
        func runJSONLTurn(into sink: @escaping ZenCODEHeadlessJSONLWriter.Sink) async throws {
            try await ZenCODEHeadlessRunner.runTurn(
                configuration: makeHeadlessConfiguration(jsonl: true),
                prompt: "hello",
                sessionRunner: ControlledHeadlessSessionRunner(
                    response: DirectAgentResponse(text: "first\nsecond", stopReason: "stop", modelID: "test"),
                    events: [.content("first\nsecond"), .turnEnded(.completed)]
                ),
                sessionConfiguration: makeSessionConfiguration(),
                jsonlSink: sink,
                textSink: { _ in Issue.record("JSONL mode must not write text") }
            )
        }
        let reference = Mutex<[Data]>([])
        try await runJSONLTurn { data in reference.withLock { $0.append(data) } }
        let output = ZenCronCapturedOutput()
        try await runJSONLTurn { data in output.append(data) }

        // Each run has its own run_id; everything else is byte-identical.
        func normalized(_ writes: [Data]) throws -> [String] {
            let runID = try #require(
                try decodeRecords(writes).first?.objectValue?["run_id"]?.stringValue
            )
            return writes.map {
                String(decoding: $0, as: UTF8.self).replacingOccurrences(of: runID, with: "<run>")
            }
        }
        let chunks = output.chunks
        #expect(chunks.allSatisfy { $0.stream == .standardOutput })
        #expect(try normalized(chunks.map(\.data)) == normalized(reference.withLock { $0 }))
        #expect(try decodeRecords(chunks.map(\.data)).map { $0.objectValue?["type"]?.stringValue } == [
            "run.started", "message.completed", "run.completed"
        ])
    }
    private func makeHeadlessConfiguration(jsonl: Bool) throws -> AgentConfiguration {
        try AgentConfiguration(
            hostedModelID: "test-model",
            runMode: .headless,
            jsonl: jsonl,
            workingDirectory: FileManager.default.temporaryDirectory
        )
    }

    private func makeSessionConfiguration() -> AgentCoreSessionConfiguration {
        AgentCoreSessionConfiguration(
            sessionID: "headless-test-session",
            modelID: "test-model",
            workingDirectory: FileManager.default.temporaryDirectory,
            systemPrompt: nil,
            cacheKey: nil,
            history: []
        )
    }

    private func decodeRecords(_ writes: [Data]) throws -> [JSONValue] {
        try writes.map { try JSONDecoder().decode(JSONValue.self, from: $0) }
    }

    private func zenExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        let currentDirectory = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        let arguments = CommandLine.arguments
        var executableURLs: [URL] = []

        func appendExecutableURL(from path: String) {
            guard !path.isEmpty else { return }
            executableURLs.append(
                URL(fileURLWithPath: path, relativeTo: currentDirectory).standardizedFileURL
            )
        }

        // SwiftPM's test runner supplies the test bundle path. Derive the
        // product directory from that current test invocation rather than
        // guessing a `.build` path or accepting an unrelated `zen` binary.
        for (index, argument) in arguments.enumerated() {
            if argument == "--test-bundle-path",
               arguments.indices.contains(index + 1) {
                appendExecutableURL(from: arguments[index + 1])
            } else if argument.hasPrefix("--test-bundle-path=") {
                appendExecutableURL(from: String(argument.dropFirst("--test-bundle-path=".count)))
            } else if argument.contains(".xctest") {
                appendExecutableURL(from: argument)
            }
        }
        if let executableURL = Bundle.main.executableURL {
            executableURLs.append(executableURL.standardizedFileURL)
        }

        var searchedDirectories: [URL] = []

        func appendSearchDirectory(_ directory: URL) {
            let standardized = directory.standardizedFileURL
            guard !searchedDirectories.contains(where: { $0.path == standardized.path }) else {
                return
            }
            searchedDirectories.append(standardized)
        }

        for executableURL in executableURLs {
            appendSearchDirectory(productDirectory(for: executableURL))
        }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            appendSearchDirectory(productDirectory(for: bundle.bundleURL))
            if let executableURL = bundle.executableURL {
                appendSearchDirectory(productDirectory(for: executableURL))
            }
        }
        for key in ["BUILT_PRODUCTS_DIR", "TARGET_BUILD_DIR", "__XCODE_BUILT_PRODUCTS_DIR_PATHS"] {
            guard let value = ProcessInfo.processInfo.environment[key] else { continue }
            for path in value.split(separator: ":") where !path.isEmpty {
                appendSearchDirectory(URL(fileURLWithPath: String(path)))
            }
        }

        for productDirectory in searchedDirectories {
            let candidate = productDirectory.appendingPathComponent("zen")
            if fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }

        throw ZenExecutableTestError.notFound
    }

    private func productDirectory(for executableURL: URL) -> URL {
        let path = executableURL.standardizedFileURL.path
        let components = path.split(separator: "/")
        if let bundleIndex = components.firstIndex(where: { $0.hasSuffix(".xctest") }) {
            let bundlePath = "/" + components[...bundleIndex].joined(separator: "/")
            return URL(fileURLWithPath: bundlePath).deletingLastPathComponent()
        }
        return executableURL.deletingLastPathComponent()
    }


    private func runZen(
        _ executable: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        standardInput: FileHandle? = nil
    ) throws -> (exitCode: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let standardInput {
            process.standardInput = standardInput
        }
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            stdout.fileHandleForReading.readDataToEndOfFile(),
            stderr.fileHandleForReading.readDataToEndOfFile()
        )
    }

    /// The environment of this process with `ZENCODE_AGENT_MODE` set to `runMode`,
    /// or removed when it is `nil`. The process itself is never modified: other
    /// suites run in parallel and read the same variable.
    private func makeEnvironment(runMode: String?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["ZENCODE_AGENT_MODE"] = runMode
        return environment
    }

    private func promptArgumentError(_ arguments: [String]) -> String? {
        do {
            try AgentConfiguration.validateArguments(["zen"] + arguments)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Runs `body` with a fresh UUID-named directory, removed afterwards.
    private func withPromptDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-prompt-file-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    private func writePromptFile(
        _ text: String,
        named name: String = "prompt.md",
        in directory: URL
    ) throws -> String {
        let url = directory.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    private func pipe(containing text: String) throws -> FileHandle {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data(text.utf8))
        try pipe.fileHandleForWriting.close()
        return pipe.fileHandleForReading
    }
}

private struct SensitiveHeadlessTestError: LocalizedError {
    var errorDescription: String? {
        "provider failed at /Users/alice/.secrets/token using sk-private"
    }
}

private enum ZenExecutableTestError: Error {
    case notFound
}

private actor ControlledHeadlessSessionRunner: ZenCODEHeadlessSessionRunning {
    enum Failure: Error, Equatable {
        case create
        case send
        case close
    }

    private let response: DirectAgentResponse
    private let events: [DirectAgentEvent]
    private let failure: Failure?
    private var calls: [String] = []
    private var createdPromptSkills: [PromptSkill]?

    init(
        response: DirectAgentResponse,
        events: [DirectAgentEvent] = [],
        failure: Failure? = nil
    ) {
        self.response = response
        self.events = events
        self.failure = failure
    }

    func headlessCreateSession(
        configuration _: AgentCoreSessionConfiguration,
        promptSkills: [PromptSkill]
    ) async throws {
        calls.append("create")
        createdPromptSkills = promptSkills
        if failure == .create { throw Failure.create }
    }

    func sendPrompt(
        configuration _: AgentCoreSessionConfiguration,
        prompt _: String,
        attachments _: [AgentRuntimeAttachment],
        authorizeTool _: AgentToolAuthorizationHandler?,
        onToolWillExecute _: (@Sendable (DirectAgentToolCall) async -> Void)?,
        toolProviders _: [AgentToolProvider],
        turnInstruction _: String?,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        calls.append("send")
        if failure == .send { throw Failure.send }
        for event in events {
            await onEvent(event)
        }
        return response
    }

    nonisolated let taskOrchestrator = SessionTaskOrchestrator()

    func subAgentSnapshots() async -> [DirectSubAgentRuntime.AgentSnapshot] {
        []
    }

    func closeSubAgent(id _: String) async -> Bool {
        false
    }

    func taskGraphSnapshot(
        sessionID _: String,
        graphID _: String?
    ) async throws -> TaskGraphSnapshot? {
        nil
    }

    func removeTaskGraph(id _: String, sessionID _: String) async throws -> TaskGraphSnapshot {
        throw Failure.send
    }

    func snapshotSession(id _: String) async -> AgentRuntimeSessionSnapshot? {
        nil
    }

    func currentSessionGeneration(
        for _: String
    ) -> AgentCoreSessionRunner.SessionGeneration? {
        nil
    }

    func replaceSessionHistory(
        id _: String,
        history _: [AgentRuntimeMessage],
        expectedSessionGeneration _: AgentCoreSessionRunner.SessionGeneration
    ) async -> Bool {
        false
    }

    func headlessCloseSession(id _: String) async throws {
        calls.append("close")
        if failure == .close { throw Failure.close }
    }

    func headlessShutdown() async {
        calls.append("shutdown")
    }

    func lifecycle() -> [String] {
        calls
    }

    func promptSkillsAtCreation() -> [PromptSkill]? {
        createdPromptSkills
    }
}
