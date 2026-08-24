//
//  ToolExecutionLoggerTests.swift
//  ZenCODECoreTests
//

import Foundation
@testable import ZenCODECore
import Testing

@Suite(.serialized)
struct ToolExecutionLoggerTests {
    @Test
    func loggerWritesCorrelatedRedactedJSONLWithOwnerOnlyPermissions() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = ToolExecutionLogger(directoryURL: root)
        let call = DirectAgentToolCall(
            id: "call-1",
            name: "local.exec",
            argumentsObject: [
                "command": "echo ok",
                "password": "super-secret",
                "nested": ["api_key": "sk-abcdefghijklmnopqrstuvwxyz"]
            ],
            argumentsJSON: #"{"command":"echo ok","password":"super-secret","nested":{"api_key":"sk-abcdefghijklmnopqrstuvwxyz"}}"#
        )

        let started = await logger.recordStarted(
            sessionID: "session-1",
            toolCall: call,
            workingDirectory: root
        )
        #expect(started != nil)
        _ = await logger.recordCompleted(
            sessionID: "session-1",
            toolCall: call,
            workingDirectory: root,
            result: DirectAgentToolResult(
                output: "raw output\nsecond line",
                summary: "raw output",
                status: .completed
            ),
            elapsed: .milliseconds(12),
            sequence: started
        )

        let url = try await logger.ensureLogExists()
        let data = try Data(contentsOf: url)
        let report = ToolExecutionLogParser.parse(data)
        #expect(report.malformedLines.isEmpty)
        #expect(report.records.count == 2)
        #expect(report.records.map(\.event) == ["started", "completed"])
        #expect(report.records[1].correlatesTo == report.records[0].sequence)
        #expect(report.records[1].output == "raw output\nsecond line")
        #expect(report.records[1].summary == "raw output")
        #expect(report.records[1].workingDirectory == root.path)
        #expect(report.records[1].elapsedMilliseconds == 12)

        let lines = try #require(String(data: data, encoding: .utf8)?.split(separator: "\n"))
        let startedObject = try #require(
            JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any]
        )
        let arguments = try #require(startedObject["arguments"] as? [String: Any])
        #expect(arguments["command"] as? String == "echo ok")
        #expect(arguments["password"] as? String == ZenSecretRedactor.placeholder)
        let nested = try #require(arguments["nested"] as? [String: Any])
        #expect(nested["api_key"] as? String == ZenSecretRedactor.placeholder)
        #expect(!String(decoding: data, as: UTF8.self).contains("super-secret"))
        #expect(!String(decoding: data, as: UTF8.self).contains("sk-abcdefghijklmnopqrstuvwxyz"))

        #if canImport(Darwin) || canImport(Glibc)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path
        )
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #endif
    }

    // MARK: - Filesystem hardening

    // MARK: - Retention

    @Test
    func retentionDeletesOnlyRecognizedLogsOlderThanTenDays() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = try preparedLogDirectory(root)
        let directory = current.deletingLastPathComponent()
        let old = directory.appendingPathComponent("tool-executions-42-00000000-0000-4000-8000-000000000001.jsonl")
        let recent = directory.appendingPathComponent("tool-executions-42-00000000-0000-4000-8000-000000000002.jsonl")
        let foreign = directory.appendingPathComponent("unrelated.jsonl")
        for file in [current, old, recent, foreign] { try Data().write(to: file) }
        try setModificationDate(now.addingTimeInterval(-11 * 24 * 60 * 60), for: old)
        try setModificationDate(now.addingTimeInterval(-9 * 24 * 60 * 60), for: recent)
        try setModificationDate(now.addingTimeInterval(-11 * 24 * 60 * 60), for: current)
        try setModificationDate(now.addingTimeInterval(-11 * 24 * 60 * 60), for: foreign)

        let logger = ToolExecutionLogger(directoryURL: root, now: { now })
        _ = try await logger.ensureLogExists()

        #expect(!FileManager.default.fileExists(atPath: old.path))
        #expect(FileManager.default.fileExists(atPath: recent.path))
        #expect(FileManager.default.fileExists(atPath: current.path))
        #expect(FileManager.default.fileExists(atPath: foreign.path))
    }

    @Test
    func retentionIgnoresSymbolicLinksAndUnexpectedNodes() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let current = try preparedLogDirectory(root)
        let directory = current.deletingLastPathComponent()
        try Data().write(to: current)
        let target = root.appendingPathComponent("target")
        try Data("target".utf8).write(to: target)
        let symlink = directory.appendingPathComponent("tool-executions-42-00000000-0000-4000-8000-000000000003.jsonl")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        let unexpectedDirectory = directory.appendingPathComponent("tool-executions-42-00000000-0000-4000-8000-000000000004.jsonl")
        try FileManager.default.createDirectory(at: unexpectedDirectory, withIntermediateDirectories: false)
        try setModificationDate(now.addingTimeInterval(-11 * 24 * 60 * 60), for: target)
        try setModificationDate(now.addingTimeInterval(-11 * 24 * 60 * 60), for: unexpectedDirectory)

        let logger = ToolExecutionLogger(directoryURL: root, now: { now })
        _ = try await logger.ensureLogExists()

        let linkDestination = try FileManager.default.destinationOfSymbolicLink(atPath: symlink.path)
        let targetContents = String(decoding: try Data(contentsOf: target), as: UTF8.self)
        #expect(linkDestination == target.path)
        #expect(targetContents == "target")
        #expect(FileManager.default.fileExists(atPath: unexpectedDirectory.path))
    }

    @Test
    func retentionFailureIsBestEffortAndDoesNotPreventLogging() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = ToolExecutionLogger(
            directoryURL: root,
            now: { .now },
            retentionCleanup: { _, _, _ in throw RetentionCleanupError.failed }
        )

        #expect(await logger.recordStarted(
            sessionID: nil,
            toolCall: toolCall(),
            workingDirectory: root
        ) != nil)
        let logURL = try await logger.ensureLogExists()
        let data = try Data(contentsOf: logURL)
        #expect(!data.isEmpty)
    }

    @Test
    func loggerRefusesPreexistingSymlink() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = try preparedLogDirectory(root)
        let target = root.appendingPathComponent("target")
        try Data().write(to: target)
        try FileManager.default.createSymbolicLink(at: logURL, withDestinationURL: target)
        let logger = ToolExecutionLogger(directoryURL: root)

        await #expect(throws: ToolExecutionLogError.isSymbolicLink(logURL.path)) {
            _ = try await logger.ensureLogExists()
        }
        // The symlink target must stay untouched: O_NOFOLLOW refuses before any write.
        #expect(try Data(contentsOf: target).isEmpty)
    }

    @Test
    func loggerRefusesDanglingSymlinkWithoutCreatingTheTarget() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = try preparedLogDirectory(root)
        let missingTarget = root.appendingPathComponent("missing-target")
        try FileManager.default.createSymbolicLink(at: logURL, withDestinationURL: missingTarget)
        let logger = ToolExecutionLogger(directoryURL: root)

        await #expect(throws: ToolExecutionLogError.isSymbolicLink(logURL.path)) {
            _ = try await logger.ensureLogExists()
        }
        #expect(!FileManager.default.fileExists(atPath: missingTarget.path))
    }

    @Test
    func loggerRefusesSymlinkedLogDirectory() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = ToolExecutionLogger.resolveLogURL(directoryURL: root)
        let directory = logURL.deletingLastPathComponent()
        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: elsewhere)
        let logger = ToolExecutionLogger(directoryURL: root)

        await #expect(throws: ToolExecutionLogError.isSymbolicLink(directory.path)) {
            _ = try await logger.ensureLogExists()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    #if canImport(Darwin) || canImport(Glibc)
    @Test
    func loggerRefusesNonRegularNodeAtLogPath() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = try preparedLogDirectory(root)
        #expect(mkfifo(logURL.path, 0o600) == 0)
        let logger = ToolExecutionLogger(directoryURL: root)

        await #expect(throws: ToolExecutionLogError.invalidFile(logURL.path)) {
            _ = try await logger.ensureLogExists()
        }
    }

    @Test
    func loggerRefusesDirectoryAtLogPath() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = try preparedLogDirectory(root)
        try FileManager.default.createDirectory(at: logURL, withIntermediateDirectories: true)
        let logger = ToolExecutionLogger(directoryURL: root)

        await #expect(throws: ToolExecutionLogError.invalidFile(logURL.path)) {
            _ = try await logger.ensureLogExists()
        }
    }

    @Test
    func loggerTightensWidePermissionsThroughTheDescriptor() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = try preparedLogDirectory(root)
        #expect(FileManager.default.createFile(
            atPath: logURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o666]
        ))
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o777],
            ofItemAtPath: logURL.deletingLastPathComponent().path
        )
        let logger = ToolExecutionLogger(directoryURL: root)

        let url = try await logger.ensureLogExists()
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: url.deletingLastPathComponent().path
        )
        #expect((fileAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test
    func loggerAppendsInsteadOfOverwritingExistingContent() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logURL = try preparedLogDirectory(root)
        try Data("preexisting\n".utf8).write(to: logURL)
        let logger = ToolExecutionLogger(directoryURL: root)

        _ = await logger.recordStarted(
            sessionID: nil,
            toolCall: toolCall(),
            workingDirectory: root
        )

        let text = try String(contentsOf: logURL, encoding: .utf8)
        #expect(text.hasPrefix("preexisting\n"))
        let report = ToolExecutionLogParser.parse(text)
        #expect(report.malformedLines == [1])
        #expect(report.records.count == 1)
    }
    #endif

    // MARK: - Output preservation

    @Test
    func largeOutputStaysCompleteWhileSecretsAreStillRedacted() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = ToolExecutionLogger(directoryURL: root)
        // Comfortably above the redactor's own 64 KiB ceiling, so a single
        // whole-payload call would collapse into a placeholder.
        let filler = (0..<4_000).map { "line \($0) padding padding padding" }
        var lines = filler
        lines.insert("api_key=sk-abcdefghijklmnopqrstuvwxyz", at: 2_000)
        lines.insert("FIRST-MARKER", at: 0)
        lines.append("LAST-MARKER")
        let output = lines.joined(separator: "\n")
        #expect(output.lengthOfBytes(using: .utf8) > 64 * 1_024)

        let started = await logger.recordStarted(
            sessionID: nil,
            toolCall: toolCall(),
            workingDirectory: root
        )
        _ = await logger.recordCompleted(
            sessionID: nil,
            toolCall: toolCall(),
            workingDirectory: root,
            result: DirectAgentToolResult(output: output, summary: output, status: .completed),
            elapsed: .milliseconds(1),
            sequence: started
        )

        let url = try await logger.ensureLogExists()
        let report = ToolExecutionLogParser.parse(try Data(contentsOf: url))
        #expect(report.malformedLines.isEmpty)
        let logged = try #require(report.records.last?.output)
        #expect(logged != ZenSecretRedactor.placeholder)
        #expect(logged.hasPrefix("FIRST-MARKER\n"))
        #expect(logged.hasSuffix("\nLAST-MARKER"))
        #expect(logged.contains("line 3999 padding padding padding"))
        #expect(!logged.contains("sk-abcdefghijklmnopqrstuvwxyz"))
        #expect(logged.contains("api_key=\(ZenSecretRedactor.placeholder)"))
        #expect(logged.split(separator: "\n", omittingEmptySubsequences: false).count == lines.count)
    }

    @Test
    func redactionChunkingKeepsLineCountAndReplacesOnlyOversizedLines() {
        let oversized = String(repeating: "a", count: 96 * 1_024)
        let text = "head\n" + oversized + "\ntail"

        let redacted = ToolExecutionLogger.redactedText(text)
        let redactedLines = redacted.split(separator: "\n", omittingEmptySubsequences: false)

        #expect(redactedLines.count == 3)
        #expect(redactedLines[0] == "head")
        #expect(redactedLines[1] == Substring(ZenSecretRedactor.placeholder))
        #expect(redactedLines[2] == "tail")
    }

    @Test
    func failureRecordsKeepStatusAndRedactedFailureText() async throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let logger = ToolExecutionLogger(directoryURL: root)
        let started = await logger.recordStarted(
            sessionID: nil,
            toolCall: toolCall(),
            workingDirectory: root
        )
        _ = await logger.recordCompleted(
            sessionID: nil,
            toolCall: toolCall(),
            workingDirectory: root,
            elapsed: .milliseconds(3),
            sequence: started,
            status: "permissionDenied",
            failure: "denied with token=sk-abcdefghijklmnopqrstuvwxyz"
        )

        let url = try await logger.ensureLogExists()
        let report = ToolExecutionLogParser.parse(try Data(contentsOf: url))
        #expect(report.malformedLines.isEmpty)
        let record = try #require(report.records.last)
        #expect(record.status == "permissionDenied")
        #expect(record.summary == nil)
        #expect(record.output == nil)
        #expect(record.failure?.contains(ZenSecretRedactor.placeholder) == true)
        #expect(record.failure?.contains("sk-abcdefghijklmnopqrstuvwxyz") == false)
    }

    // MARK: - Strict parser

    @Test
    func strictParserAcceptsTheSchemaTheLoggerEmits() {
        let report = ToolExecutionLogParser.parse(
            line(startedObject()) + "\n" + line(completedObject()) + "\n"
        )

        #expect(report.malformedLines.isEmpty)
        #expect(report.records.count == 2)
        #expect(report.records[0].workingDirectory == "/tmp/workspace")
        #expect(report.records[0].status == nil)
        #expect(report.records[1].correlatesTo == 0)
        #expect(report.records[1].elapsedMilliseconds == 12)
        #expect(report.records[1].summary == "ok")
    }

    @Test
    func strictParserReportsBlankInvalidSchemaAndInvalidEventLines() {
        var invalidEvent = startedObject()
        invalidEvent["event"] = "other"
        var fractional = startedObject()
        fractional["sequence"] = 1.5
        let report = ToolExecutionLogParser.parse(
            line(startedObject()) + "\n\n"
                + line(invalidEvent) + "\n"
                + line(fractional) + "\nnot-json\n"
        )

        #expect(report.records.count == 1)
        #expect(report.malformedLines == [2, 3, 4, 5])
    }

    @Test
    func strictParserRejectsMissingOrMistypedRequiredFields() {
        var withoutArguments = startedObject()
        withoutArguments["arguments"] = nil
        var withoutWorkingDirectory = startedObject()
        withoutWorkingDirectory["workingDirectory"] = nil
        var emptyTool = startedObject()
        emptyTool["tool"] = ""
        var booleanSequence = startedObject()
        booleanSequence["sequence"] = true
        var negativePID = startedObject()
        negativePID["pid"] = -1
        var numericSession = startedObject()
        numericSession["sessionID"] = 7
        var unknownKey = startedObject()
        unknownKey["unexpected"] = "value"

        for object in [
            withoutArguments, withoutWorkingDirectory, emptyTool,
            booleanSequence, negativePID, numericSession, unknownKey
        ] {
            let report = ToolExecutionLogParser.parse(line(object) + "\n")
            #expect(report.records.isEmpty)
            #expect(report.malformedLines == [1])
        }
    }

    @Test
    func strictParserRejectsNonISO8601Timestamps() {
        var badTimestamp = startedObject()
        badTimestamp["timestamp"] = "yesterday"
        var emptyTimestamp = startedObject()
        emptyTimestamp["timestamp"] = ""
        var fractionalTimestamp = startedObject()
        fractionalTimestamp["timestamp"] = "2026-01-01T00:00:00.123Z"
        var plainTimestamp = startedObject()
        plainTimestamp["timestamp"] = "2026-01-01T00:00:00Z"

        #expect(ToolExecutionLogParser.parse(line(badTimestamp)).malformedLines == [1])
        #expect(ToolExecutionLogParser.parse(line(emptyTimestamp)).malformedLines == [1])
        #expect(ToolExecutionLogParser.parse(line(fractionalTimestamp)).records.count == 1)
        #expect(ToolExecutionLogParser.parse(line(plainTimestamp)).records.count == 1)
    }

    @Test
    func strictParserRejectsStartedRecordsCarryingTerminalFields() {
        for key in ["status", "correlatesTo", "elapsedMilliseconds", "summary", "output", "failure"] {
            var object = startedObject()
            object[key] = key == "correlatesTo" || key == "elapsedMilliseconds" ? 1 : "value"
            let report = ToolExecutionLogParser.parse(line(object))
            #expect(report.records.isEmpty)
            #expect(report.malformedLines == [1])
        }
    }

    @Test
    func strictParserRejectsUncorrelatedOrInconsistentCompletedRecords() {
        var withoutStatus = completedObject()
        withoutStatus["status"] = nil
        var emptyStatus = completedObject()
        emptyStatus["status"] = ""
        var withoutCorrelation = completedObject()
        withoutCorrelation["correlatesTo"] = nil
        var forwardCorrelation = completedObject()
        forwardCorrelation["correlatesTo"] = 1
        var withoutSummary = completedObject()
        withoutSummary["summary"] = nil
        var failureWithOutput = completedObject()
        failureWithOutput["failure"] = "boom"
        var negativeElapsed = completedObject()
        negativeElapsed["elapsedMilliseconds"] = -1
        var unknownStatus = completedObject()
        unknownStatus["status"] = "cancelledBySomeoneElse"

        for object in [
            withoutStatus, emptyStatus, withoutCorrelation, forwardCorrelation,
            withoutSummary, failureWithOutput, negativeElapsed, unknownStatus
        ] {
            let report = ToolExecutionLogParser.parse(line(object))
            #expect(report.records.isEmpty)
            #expect(report.malformedLines == [1])
        }
    }

    @Test
    func strictParserRejectsResultCompletionWithoutOutput() {
        var withoutOutput = completedObject()
        withoutOutput["output"] = nil

        let report = ToolExecutionLogParser.parse(
            line(startedObject()) + "\n" + line(withoutOutput)
        )

        #expect(report.records.map(\.event) == ["started"])
        #expect(report.malformedLines == [2])
    }

    @Test
    func strictParserAcceptsFailureOnlyTerminalRecords() {
        var failure = completedObject()
        failure["summary"] = nil
        failure["output"] = nil
        failure["failure"] = "boom"
        failure["status"] = "failed"

        let report = ToolExecutionLogParser.parse(line(startedObject()) + "\n" + line(failure))

        #expect(report.malformedLines.isEmpty)
        #expect(report.records.last?.failure == "boom")
        #expect(report.records.last?.status == "failed")
    }

    @Test
    func strictParserRequiresMatchingUniqueStartedCorrelation() {
        var orphan = completedObject()
        orphan["correlatesTo"] = 99
        var mismatched = completedObject()
        mismatched["toolID"] = "another-call"
        var duplicateTerminal = completedObject()
        duplicateTerminal["sequence"] = 2

        let orphanReport = ToolExecutionLogParser.parse(line(orphan))
        #expect(orphanReport.records.isEmpty)
        #expect(orphanReport.malformedLines == [1])

        let mismatchReport = ToolExecutionLogParser.parse(
            line(startedObject()) + "\n" + line(mismatched)
        )
        #expect(mismatchReport.records.map(\.event) == ["started"])
        #expect(mismatchReport.malformedLines == [2])

        let duplicateReport = ToolExecutionLogParser.parse(
            line(startedObject()) + "\n" + line(completedObject()) + "\n" + line(duplicateTerminal)
        )
        #expect(duplicateReport.records.map(\.event) == ["started", "completed"])
        #expect(duplicateReport.malformedLines == [3])
    }

    @Test
    func strictParserRejectsCompletedRecordWithDifferentArguments() {
        var differentArguments = completedObject()
        differentArguments["arguments"] = ["command": "echo altered"]

        let report = ToolExecutionLogParser.parse(
            line(startedObject()) + "\n" + line(differentArguments)
        )

        #expect(report.records.map(\.event) == ["started"])
        #expect(report.malformedLines == [2])
    }

    @Test
    func strictParserRejectsNonUTF8Payloads() {
        let report = ToolExecutionLogParser.parse(Data([0xFF, 0xFE, 0xFD]))

        #expect(report.records.isEmpty)
        #expect(report.malformedLines == [1])
        #expect(ToolExecutionLogParser.parse(Data()).malformedLines.isEmpty)
    }

    // MARK: - Command surface

    @Test
    func toolsLogsRequestRequiresExactlyOneArgumentToken() {
        #expect(TerminalChat.isToolLogsRequest("logs"))
        #expect(TerminalChat.isToolLogsRequest("  LOGS\t"))
        #expect(!TerminalChat.isToolLogsRequest(""))
        #expect(!TerminalChat.isToolLogsRequest("logs extra"))
        #expect(!TerminalChat.isToolLogsRequest("log"))
    }

    @Test
    func toolsUsageAndHelpDocumentTheLogsSubcommand() {
        #expect(TerminalChat.renderToolSelectionUsage().contains("logs"))
        let descriptor = TerminalChat.visibleCommandDescriptors(
            builderAgentEnabled: false,
            telegramEnabled: false
        ).first { $0.command == "/tools" }
        #expect(descriptor?.help.contains("/tools logs") == true)
        let suggestions = TerminalPromptCompletionCatalog.argumentSuggestions(for: "/tools")
        #expect(suggestions.contains { $0.command == "logs" })
    }

    @Test
    func sharedLauncherBuildsPlatformCommand() throws {
        let command = try SystemFileLauncher.command(for: "/tmp/tool log.jsonl")
        #if os(macOS)
        #expect(command.executableURL.path == "/usr/bin/open")
        #expect(command.arguments == ["/tmp/tool log.jsonl"])
        #elseif os(Windows)
        #expect(command.arguments == ["/c", "start", "", "/tmp/tool log.jsonl"])
        #else
        #expect(command.arguments == ["/tmp/tool log.jsonl"])
        #endif
    }

    @Test
    func sharedLauncherReportsUnavailableWhenNoExecutableExists() {
        #if os(Windows)
        // The Windows command is a fixed shell invocation with no probe step.
        #expect(throws: Never.self) { _ = try SystemFileLauncher.command(for: "x") }
        #else
        #expect(throws: SystemFileLauncher.LaunchError.unavailable) {
            _ = try SystemFileLauncher.command(for: "x", fileManager: NoExecutableFileManager())
        }
        #endif
    }

    @Test
    func sharedLauncherErrorsExplainTheFailure() {
        #expect(
            SystemFileLauncher.LaunchError.unavailable.errorDescription
                == "No system file launcher is available."
        )
        #expect(
            SystemFileLauncher.LaunchError.timedOut.errorDescription
                == "The system file launcher did not finish before the timeout."
        )
        #expect(
            SystemFileLauncher.LaunchError.failed(3).errorDescription
                == "The system file launcher failed with exit code 3."
        )
    }

    // MARK: - Helpers

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolExecutionLoggerTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// Creates the `logs` parent directory and returns the concrete log URL.
    private func preparedLogDirectory(_ root: URL) throws -> URL {
        let logURL = ToolExecutionLogger.resolveLogURL(directoryURL: root)
        try FileManager.default.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        return logURL
    }

    private func setModificationDate(_ date: Date, for url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private func toolCall() -> DirectAgentToolCall {
        DirectAgentToolCall(
            id: "call-1",
            name: "local.exec",
            argumentsObject: ["command": "echo ok"],
            argumentsJSON: #"{"command":"echo ok"}"#
        )
    }

    private func startedObject() -> [String: Any] {
        [
            "event": "started",
            "timestamp": "2026-01-01T00:00:00.000Z",
            "sequence": 0,
            "pid": 42,
            "processLaunchID": "boot",
            "toolID": "call-1",
            "tool": "local.exec",
            "arguments": ["command": "echo ok"],
            "workingDirectory": "/tmp/workspace"
        ]
    }

    private func completedObject() -> [String: Any] {
        [
            "event": "completed",
            "timestamp": "2026-01-01T00:00:01.000Z",
            "sequence": 1,
            "pid": 42,
            "processLaunchID": "boot",
            "toolID": "call-1",
            "tool": "local.exec",
            "arguments": ["command": "echo ok"],
            "workingDirectory": "/tmp/workspace",
            "correlatesTo": 0,
            "status": "completed",
            "elapsedMilliseconds": 12,
            "summary": "ok",
            "output": "ok"
        ]
    }

    private func line(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

private enum RetentionCleanupError: Error {
    case failed
}

/// Reports no executable candidate so the launcher must fail closed.
private final class NoExecutableFileManager: FileManager, @unchecked Sendable {
    override func isExecutableFile(atPath path: String) -> Bool { false }
}
