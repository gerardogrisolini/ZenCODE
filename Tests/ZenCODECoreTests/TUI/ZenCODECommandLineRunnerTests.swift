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
        for option in ["--version", "--doctor", "--acp", "-p", "--prompt", "--jsonl", "--model", "--max-tool-rounds"] {
            #expect(
                ZenCODECommandLineRunner.shouldRunAsCommandLine(
                    arguments: [bundleExecutable, option]
                )
            )
        }
    }

    @Test
    func headlessArgumentAcceptsInlinePrompt() throws {
        try AgentConfiguration.validateArguments(["zen", "-p", "summarize this"])
        try AgentConfiguration.validateArguments(["zen", "--prompt", "summarize this"])
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
    func jsonlWriterEmitsOneTerminalErrorForFailedTurn() async {
        let lines = Mutex<[Data]>([])
        let writer = ZenCODEHeadlessJSONLWriter(runID: "run-error") { data in
            lines.withLock { $0.append(data) }
        }

        await writer.start()
        await writer.write(event: .turnEnded(.failed(message: "backend failed")))
        await writer.write(error: ZenCODEHeadlessRunnerError.noResponse)

        let records = lines.withLock { values in
            values.compactMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
        }
        #expect(records.count == 2)
        #expect(records[0].objectValue?["type"]?.stringValue == "run.started")
        #expect(records[1].objectValue?["type"]?.stringValue == "error")
        #expect(records[1].objectValue?["category"]?.stringValue == "runtime")
        #expect(records[1].objectValue?["message"]?.stringValue == "The backend produced no assistant text.")
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

        for arguments in invocations {
            let ordinary = try runZen(executable, arguments: arguments)
            let withJSONL = try runZen(executable, arguments: ["--jsonl"] + arguments)
            #expect(withJSONL.exitCode == ordinary.exitCode)
            #expect(withJSONL.stdout == ordinary.stdout)
            #expect(withJSONL.stderr == ordinary.stderr)
        }
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
        arguments: [String]
    ) throws -> (exitCode: Int32, stdout: Data, stderr: Data) {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
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

    init(
        response: DirectAgentResponse,
        events: [DirectAgentEvent] = [],
        failure: Failure? = nil
    ) {
        self.response = response
        self.events = events
        self.failure = failure
    }

    func headlessCreateSession(configuration _: AgentCoreSessionConfiguration) async throws {
        calls.append("create")
        if failure == .create { throw Failure.create }
    }

    func headlessSendPrompt(
        configuration _: AgentCoreSessionConfiguration,
        prompt _: String,
        onEvent: @escaping @Sendable (DirectAgentEvent) async -> Void
    ) async throws -> DirectAgentResponse {
        calls.append("send")
        if failure == .send { throw Failure.send }
        for event in events {
            await onEvent(event)
        }
        return response
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
}
