//
//  ZenCronMailDeliveryTests.swift
//  ZenCODE
//

import Foundation
import Synchronization
import Testing
import ToolCore
@testable import ZenCODECore

@Suite("Cron Mail.app delivery")
struct ZenCronMailDeliveryTests {
    // MARK: - Recipient

    @Test("delivery stays with cron without a usable MAILTO")
    func recipientRequiresAUsableMailTo() {
        let rejected: [[String: String]] = [
            [:],
            ["MAILTO": ""],
            ["MAILTO": "  \n\t "],
            ["MAILTO": "first last@example.com"],
            ["MAILTO": "user@example.com,\tother@example.com"],
            ["MAILTO": "\"user\"@example.com"],
            ["MAILTO": "gerardo"]
        ]
        for environment in rejected {
            #expect(
                ZenCronMailDelivery.recipient(
                    environment: environment,
                    standardOutputIsTerminal: false
                ) == nil
            )
        }
    }

    @Test("a terminal on standard output keeps the output on the terminal")
    func recipientIgnoresAnInteractiveRun() {
        #expect(
            ZenCronMailDelivery.recipient(
                environment: ["MAILTO": "user@example.com"],
                standardOutputIsTerminal: true
            ) == nil
        )
    }

    @Test("a deliverable MAILTO is trimmed and used only on macOS")
    func recipientAcceptsADeliverableAddress() {
        let recipient = ZenCronMailDelivery.recipient(
            environment: ["MAILTO": "  user@example.com\n", "PATH": "/usr/bin:/bin"],
            standardOutputIsTerminal: false
        )
        #if os(macOS)
        #expect(recipient == "user@example.com")
        #else
        #expect(recipient == nil)
        #endif
    }

    @Test("the /cron run environment never activates delivery")
    func recipientIsNilInTheCronRunEnvironment() {
        let environment = ZenCronEnvironment.minimal(
            current: ["MAILTO": "user@example.com", "USER": "gerardo"],
            home: URL(fileURLWithPath: "/Users/gerardo")
        )
        #expect(
            ZenCronMailDelivery.recipient(
                environment: environment,
                standardOutputIsTerminal: false
            ) == nil
        )
    }

    // MARK: - Subject

    /// 2025-10-25 00:00:00 UTC.
    private let runDate = Date(timeIntervalSince1970: 1_761_350_400)

    @Test("the prompt file name labels the job, even with an inline prompt")
    func labelPrefersThePromptFileName() {
        #expect(
            ZenCronMailDelivery.label(
                promptFile: "/Users/gerardo/jobs/daily report.md",
                prompt: "summarize"
            ) == "daily report.md"
        )
        #expect(
            ZenCronMailDelivery.label(promptFile: "/tmp/prompt.md", prompt: nil) == "prompt.md"
        )
    }

    @Test("an inline prompt label is collapsed to one line")
    func labelCollapsesWhitespace() {
        #expect(
            ZenCronMailDelivery.label(
                promptFile: nil,
                prompt: "  summarize\n\nthe \t changes\r\nof today  "
            ) == "summarize the changes of today"
        )
        #expect(ZenCronMailDelivery.label(promptFile: nil, prompt: " \n ") == "")
        #expect(ZenCronMailDelivery.label(promptFile: nil, prompt: nil) == "")
    }

    @Test("an inline prompt label is at most 60 characters, ellipsis included")
    func labelTruncatesLongPrompts() {
        let sixty = String(repeating: "a", count: 60)
        #expect(ZenCronMailDelivery.label(promptFile: nil, prompt: sixty) == sixty)

        let label = ZenCronMailDelivery.label(promptFile: nil, prompt: sixty + "b")
        #expect(label == String(repeating: "a", count: 59) + "…")
        #expect(label.count == 60)

        let accented = ZenCronMailDelivery.label(
            promptFile: nil,
            prompt: String(repeating: "è", count: 70)
        )
        #expect(accented == String(repeating: "è", count: 59) + "…")
    }

    @Test("subjects carry the label and the day of the run")
    func subjectFormat() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(
            ZenCronMailDelivery.subject(
                succeeded: true,
                promptFile: "/tmp/report.md",
                prompt: nil,
                date: runDate,
                timeZone: utc
            ) == "ZenCODE cron: report.md – 2025-10-25"
        )
        #expect(
            ZenCronMailDelivery.subject(
                succeeded: false,
                promptFile: nil,
                prompt: "check\nthe build",
                date: runDate,
                timeZone: utc
            ) == "ZenCODE cron failed: check the build – 2025-10-25"
        )
    }

    @Test("an empty label leaves out the colon")
    func subjectWithoutLabel() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(
            ZenCronMailDelivery.subject(
                succeeded: false,
                promptFile: nil,
                prompt: "   ",
                date: runDate,
                timeZone: utc
            ) == "ZenCODE cron failed – 2025-10-25"
        )
        #expect(
            ZenCronMailDelivery.subject(
                succeeded: true,
                promptFile: nil,
                prompt: nil,
                date: runDate,
                timeZone: utc
            ) == "ZenCODE cron – 2025-10-25"
        )
    }

    @Test("the day is taken in the given time zone")
    func subjectDayUsesTheTimeZone() throws {
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        #expect(ZenCronMailDelivery.day(of: runDate, in: losAngeles) == "2025-10-24")
        #expect(ZenCronMailDelivery.day(of: runDate, in: tokyo) == "2025-10-25")
    }

    // MARK: - Send arguments

    @Test("the send call targets macos.mail with confirm and no sender")
    func sendToolCallArguments() throws {
        let toolCall = ZenCronMailDelivery.sendToolCall(
            recipient: "user@example.com",
            subject: "ZenCODE cron: report.md – 2025-10-25",
            body: "line one\nline \"two\" ✓\n"
        )
        #expect(toolCall.name == "macos.mail")

        let arguments = try #require(
            try JSONDecoder().decode(JSONValue.self, from: Data(toolCall.argumentsJSON.utf8)).objectValue
        )
        #expect(arguments.keys.sorted() == ["action", "body", "confirm", "subject", "to"])
        #expect(arguments["action"]?.stringValue == "send")
        #expect(arguments["confirm"]?.boolValue == true)
        #expect(arguments["to"]?.arrayValue?.compactMap(\.stringValue) == ["user@example.com"])
        #expect(arguments["subject"]?.stringValue == "ZenCODE cron: report.md – 2025-10-25")
        #expect(arguments["body"]?.stringValue == "line one\nline \"two\" ✓\n")
        #expect(arguments["from"] == nil)
    }

    // MARK: - Delivery

    @Test("a sent message writes nothing")
    func deliverySuccessWritesNothing() async {
        let sender = RecordingMailSender(failure: nil)
        let writes = Mutex<[String]>([])
        let output = capturedOutput([
            (.standardOutput, "first\n"),
            (.standardError, "second\n")
        ])

        let delivered = await ZenCronMailDelivery.deliver(
            output,
            to: "user@example.com",
            subject: "subject",
            sender: sender,
            writeStandardOutput: { data in writes.withLock { $0.append("out:" + String(decoding: data, as: UTF8.self)) } },
            writeStandardError: { data in writes.withLock { $0.append("err:" + String(decoding: data, as: UTF8.self)) } }
        )

        #expect(delivered)
        #expect(writes.withLock { $0 }.isEmpty)
        #expect(sender.messages == [
            RecordingMailSender.Message(
                recipient: "user@example.com",
                subject: "subject",
                body: "first\nsecond\n"
            )
        ])
    }

    @Test("a failed send prints the output and one line explaining why")
    func deliveryFailureFallsBackToTheStreams() async {
        let sender = RecordingMailSender(failure: DirectToolError.toolFailed("Mail did not send the message."))
        let standardOutput = Mutex<Data>(Data())
        let standardError = Mutex<Data>(Data())
        let records = "{\"type\":\"run.started\"}\n{\"type\":\"run.completed\"}\n"

        let delivered = await ZenCronMailDelivery.deliver(
            capturedOutput([(.standardOutput, records)]),
            to: "user@example.com",
            subject: "subject",
            sender: sender,
            writeStandardOutput: { data in standardOutput.withLock { $0.append(data) } },
            writeStandardError: { data in standardError.withLock { $0.append(data) } }
        )

        #expect(!delivered)
        #expect(sender.messages.count == 1)
        #expect(standardOutput.withLock { $0 } == Data(records.utf8))
        #expect(
            String(decoding: standardError.withLock { $0 }, as: UTF8.self)
                == "ZenCODE: Mail.app delivery to user@example.com failed: Mail did not send the message.\n"
        )
    }

    @Test("a failed send prints a text-mode error on standard error, before the explanation")
    func deliveryFailureKeepsTextErrorsOnStandardError() async {
        let sender = RecordingMailSender(failure: ZenCronMailDeliveryError.mailToolUnavailable)
        let standardOutput = Mutex<Data>(Data())
        let standardError = Mutex<Data>(Data())
        let failure = ZenCODECommandLineRunner.failureMessage(for: ZenCODEHeadlessRunnerError.noResponse)

        await ZenCronMailDelivery.deliver(
            capturedOutput([(.standardError, failure)]),
            to: "user@example.com",
            subject: "subject",
            sender: sender,
            writeStandardOutput: { data in standardOutput.withLock { $0.append(data) } },
            writeStandardError: { data in standardError.withLock { $0.append(data) } }
        )

        #expect(standardOutput.withLock { $0 }.isEmpty)
        #expect(
            String(decoding: standardError.withLock { $0 }, as: UTF8.self)
                == failure
                + "ZenCODE: Mail.app delivery to user@example.com failed: "
                + "the macos.mail tool is unavailable (the macOS feature is not installed or not enabled)\n"
        )
    }

    @Test("the failure explanation stays on one line")
    func deliveryFailureLineIsSingleLine() {
        let line = ZenCronMailDelivery.deliveryFailureLine(
            recipient: "user@example.com",
            error: DirectToolError.processFailed(
                "Swift feature 'macos' failed with exit code 1.\nstderr:\nboom\n"
            )
        )
        #expect(
            line == "ZenCODE: Mail.app delivery to user@example.com failed: "
                + "Swift feature 'macos' failed with exit code 1. stderr: boom\n"
        )
    }

    @Test("the body is the captured bytes decoded as lossy UTF-8")
    func capturedBodyIsLossyUTF8() {
        let output = ZenCronCapturedOutput()
        output.append("ok ")
        output.append(Data([0xFF, 0x41]), to: .standardError)
        #expect(output.chunks.map(\.stream) == [.standardOutput, .standardError])
        #expect(ZenCronCapturedOutput.body(of: output.chunks) == "ok \u{FFFD}A")
    }

    @Test("without an enabled macOS feature the sender reports Mail.app as unavailable")
    func featureSenderWithoutTheMailTool() async {
        let sender = ZenCronFeatureMailSender(
            workingDirectory: FileManager.default.temporaryDirectory,
            makeRuntime: { SwiftFeatureRuntime(features: []) }
        )
        await #expect(throws: ZenCronMailDeliveryError.mailToolUnavailable) {
            try await sender.send(to: "user@example.com", subject: "subject", body: "body")
        }
    }

    private func capturedOutput(
        _ parts: [(ZenCronCapturedOutput.Stream, String)]
    ) -> [ZenCronCapturedOutput.Chunk] {
        let output = ZenCronCapturedOutput()
        for (stream, text) in parts {
            output.append(text, to: stream)
        }
        return output.chunks
    }
}

/// Records every message instead of sending it, and fails when told to.
private final class RecordingMailSender: ZenCronMailSending {
    struct Message: Equatable {
        let recipient: String
        let subject: String
        let body: String
    }

    private let failure: (any Error & Sendable)?
    private let recorded = Mutex<[Message]>([])

    init(failure: (any Error & Sendable)?) {
        self.failure = failure
    }

    var messages: [Message] {
        recorded.withLock { $0 }
    }

    func send(to recipient: String, subject: String, body: String) async throws {
        recorded.withLock { $0.append(Message(recipient: recipient, subject: subject, body: body)) }
        if let failure {
            throw failure
        }
    }
}
