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

    // MARK: - Subject

    /// 2025-10-25 00:00:00 UTC.
    private let runDate = Date(timeIntervalSince1970: 1_761_350_400)

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

    // MARK: - Attachment name

    @Test("the attachment is named after the prompt file without its extension, then the day")
    func attachmentNameFromThePromptFile() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        func name(_ promptFile: String?, _ prompt: String? = nil) -> String {
            ZenCronMailDelivery.attachmentFileName(
                promptFile: promptFile,
                prompt: prompt,
                date: runDate,
                timeZone: utc
            )
        }
        #expect(name("/x/breafing.md") == "breafing-2025-10-25.md")
        #expect(name("/x/breafing.md", "summarize the day") == "breafing-2025-10-25.md")
        #expect(name("/Users/me/daily report.md") == "daily report-2025-10-25.md")
        #expect(name("/x/archive.tar.gz") == "archive.tar-2025-10-25.md")
        #expect(name("/x/noextension") == "noextension-2025-10-25.md")
        #expect(name("/x/.hidden.md") == "hidden-2025-10-25.md")
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

    @Test("attachments are sent as an array of file paths")
    func sendArgumentsWithAttachments() throws {
        let files = [
            URL(fileURLWithPath: "/tmp/zencode-cron-mail/ABC/report-2025-10-25.md"),
            URL(fileURLWithPath: "/tmp/zencode-cron-mail/ABC/second file.md")
        ]
        let toolCall = ZenCronMailDelivery.sendToolCall(
            recipient: "user@example.com",
            subject: "subject",
            body: "body",
            attachments: files
        )
        let arguments = try #require(
            try JSONDecoder().decode(JSONValue.self, from: Data(toolCall.argumentsJSON.utf8)).objectValue
        )
        #expect(arguments.keys.sorted() == ["action", "attachments", "body", "confirm", "subject", "to"])
        #expect(arguments["attachments"]?.arrayValue?.compactMap(\.stringValue) == files.map(\.path))
        #expect(arguments["body"]?.stringValue == "body")
        #expect(toolCall.argumentsObject["attachments"] != nil)
    }

    // MARK: - Delivery

    @Test("a text-mode run is sent as plain text with the Markdown answer attached as a .md file")
    func textDeliveryConvertsAndAttaches() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = RecordingMailSender(failure: nil)
        let subject = "ZenCODE cron: breafing.md – 2025-10-25"
        let markdown = """
        # Briefing

        | Time | Event |
        | --- | --- |
        | 09:30 | **Standup** |

        - [ ] reply
        - done & dusted
        """

        let result = await deliver(
            capturedOutput([(.standardOutput, markdown + "\n")]),
            subject: subject,
            attachmentName: "breafing-2025-10-25.md",
            directory: directory,
            sender: sender
        )

        #expect(result.delivered)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.isEmpty)
        let message = try #require(sender.messages.first)
        #expect(sender.messages.count == 1)
        #expect(message.recipient == "user@example.com")
        #expect(message.subject == subject)
        #expect(message.body == "Briefing\n\nTime: 09:30\nEvent: Standup\n\n[ ] reply\n• done & dusted\n")

        let path = try #require(message.attachments.first)
        #expect(message.attachments.count == 1)
        let file = URL(fileURLWithPath: path)
        #expect(file.lastPathComponent == "breafing-2025-10-25.md")
        // A new directory per run, named with a UUID, inside the given one.
        let runDirectory = file.deletingLastPathComponent()
        #expect(UUID(uuidString: runDirectory.lastPathComponent) != nil)
        #expect(runDirectory.deletingLastPathComponent().path == directory.path)
        // The file was complete when Mail was asked to send it, and stays.
        #expect(message.attachmentContents == [markdown + "\n"])
        #expect(FileManager.default.fileExists(atPath: path))
        let contents = try String(contentsOf: file, encoding: .utf8)
        #expect(contents == markdown + "\n")

        #expect(try permissions(of: file) == 0o600)
        #expect(try permissions(of: runDirectory) == 0o700)
        #expect(try permissions(of: directory) == 0o700)
    }

    @Test("consecutive standard output chunks are one Markdown document and standard error stays verbatim")
    func chunksAreJoinedAndStandardErrorIsVerbatim() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = RecordingMailSender(failure: nil)

        await deliver(
            capturedOutput([
                (.standardOutput, "Hello "),
                (.standardOutput, "**wor"),
                (.standardOutput, "ld**\n"),
                (.standardError, "problem: *raw* # not a title\n"),
                (.standardOutput, "# After\n")
            ]),
            attachmentName: "run.md",
            directory: directory,
            sender: sender
        )

        let message = try #require(sender.messages.first)
        #expect(message.body == "Hello world\nproblem: *raw* # not a title\nAfter\n")
        // The attachment is all the standard output, in order and as captured.
        let contents = try #require(message.attachmentContents.first ?? nil)
        #expect(contents == "Hello **world**\n# After\n")
        #expect(!contents.contains("problem"))
    }

    @Test("a JSONL run is sent unchanged and without attachment")
    func jsonlDeliveryIsUnchanged() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = RecordingMailSender(failure: nil)
        let records = "{\"type\":\"run.started\"}\n{\"type\":\"message.completed\",\"text\":\"# Title **x**\"}\n"

        let result = await deliver(
            capturedOutput([(.standardOutput, records)]),
            format: .jsonl,
            directory: directory,
            sender: sender
        )

        #expect(result.delivered)
        #expect(sender.messages == [
            RecordingMailSender.Message(
                recipient: "user@example.com",
                subject: "subject",
                body: records,
                attachments: [],
                attachmentContents: []
            )
        ])
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("when the message with the attachment is not sent it is sent again without, with a note")
    func failedSendWithAttachmentRetriesWithoutIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = RecordingMailSender(
            failure: nil,
            attachmentFailure: DirectToolError.toolFailed("Mail could not read\nthe attachment.")
        )

        let result = await deliver(
            capturedOutput([(.standardOutput, "# Report\n\nAll **good**.\n")]),
            attachmentName: "report.md",
            directory: directory,
            sender: sender
        )

        #expect(result.delivered)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.isEmpty)
        #expect(sender.messages.count == 2)
        #expect(sender.messages[0].attachments.count == 1)
        #expect(sender.messages[0].body == "Report\n\nAll good.\n")
        #expect(sender.messages[1].attachments.isEmpty)
        #expect(
            sender.messages[1].body == "Report\n\nAll good.\n\n"
                + "ZenCODE: the Markdown file could not be attached: Mail could not read the attachment.\n"
        )
        #expect(sender.messages[1].subject == sender.messages[0].subject)
        #expect(sender.messages[1].recipient == sender.messages[0].recipient)
    }

    @Test("when the last send fails too the original output is printed with the last error")
    func bothSendsFailingFallBackToTheOriginalBytes() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = RecordingMailSender(
            failure: DirectToolError.toolFailed("Mail did not send the message."),
            attachmentFailure: DirectToolError.toolFailed("attachment problem")
        )
        let original = "# Title\n\n**bold** | table | `code`\n"
        let warning = "ZenCODE: a warning\n"

        let result = await deliver(
            capturedOutput([(.standardOutput, original), (.standardError, warning)]),
            attachmentName: "run.md",
            directory: directory,
            sender: sender
        )

        #expect(!result.delivered)
        #expect(sender.messages.count == 2)
        #expect(sender.messages[0].attachments.count == 1)
        #expect(sender.messages[1].attachments.isEmpty)
        #expect(result.standardOutput == Data(original.utf8))
        #expect(
            String(decoding: result.standardError, as: UTF8.self)
                == warning
                + "ZenCODE: Mail.app delivery to user@example.com failed: Mail did not send the message.\n"
        )
    }

    // MARK: - Attachment cleanup

    @Test("a delivery removes the subdirectories older than an hour and keeps the recent ones")
    func deliveryRemovesStaleAttachmentDirectories() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        func makeSubdirectory(_ name: String, age: TimeInterval) throws -> URL {
            let subdirectory = directory.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            try Data("old".utf8).write(to: subdirectory.appendingPathComponent("report.md"))
            // Set last: writing the file just changed the directory's date.
            try fileManager.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-age)],
                ofItemAtPath: subdirectory.path
            )
            return subdirectory
        }
        let old = try makeSubdirectory("old-run", age: 2 * 3600)
        let ancient = try makeSubdirectory(UUID().uuidString, age: 30 * 24 * 3600)
        let recent = try makeSubdirectory("recent-run", age: 10 * 60)
        let stray = directory.appendingPathComponent("notes.txt")
        try Data("a file, not a delivery".utf8).write(to: stray)
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-2 * 3600)],
            ofItemAtPath: stray.path
        )
        let sender = RecordingMailSender(failure: nil)

        await deliver(
            capturedOutput([(.standardOutput, "text\n")]),
            attachmentName: "run.md",
            directory: directory,
            sender: sender
        )

        #expect(!fileManager.fileExists(atPath: old.path))
        #expect(!fileManager.fileExists(atPath: ancient.path))
        #expect(fileManager.fileExists(atPath: recent.appendingPathComponent("report.md").path))
        #expect(fileManager.fileExists(atPath: stray.path))
        let attachment = try #require(sender.messages.first?.attachments.first)
        #expect(fileManager.fileExists(atPath: attachment))
    }

    // MARK: - Captured output

    // MARK: - Helpers

    private struct Delivered {
        let delivered: Bool
        let standardOutput: Data
        let standardError: Data
    }

    /// A directory name that does not exist yet.
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("zencode-cron-mail-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.posixPermissions] as? NSNumber)?.intValue) & 0o777
    }

    @discardableResult
    private func deliver(
        _ output: [ZenCronCapturedOutput.Chunk],
        format: ZenCronJobCommand.OutputFormat = .text,
        subject: String = "subject",
        attachmentName: String = "attachment.md",
        directory: URL,
        sender: RecordingMailSender
    ) async -> Delivered {
        let standardOutput = Mutex<Data>(Data())
        let standardError = Mutex<Data>(Data())
        let delivered = await ZenCronMailDelivery.deliver(
            output,
            format: format,
            to: "user@example.com",
            subject: subject,
            attachmentName: attachmentName,
            attachmentsDirectory: directory,
            sender: sender,
            writeStandardOutput: { data in standardOutput.withLock { $0.append(data) } },
            writeStandardError: { data in standardError.withLock { $0.append(data) } }
        )
        return Delivered(
            delivered: delivered,
            standardOutput: standardOutput.withLock { $0 },
            standardError: standardError.withLock { $0 }
        )
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
///
/// A message with attachments fails with `attachmentFailure`, falling back to
/// `failure`; one without fails with `failure`. So `failure: nil` with an
/// `attachmentFailure` fails only the sends that carry attachments.
private final class RecordingMailSender: ZenCronMailSending {
    struct Message: Equatable {
        let recipient: String
        let subject: String
        let body: String
        /// The paths of the attached files.
        let attachments: [String]
        /// What each attached file held at the moment of the send, nil if it
        /// could not be read.
        let attachmentContents: [String?]
    }

    private let failure: (any Error & Sendable)?
    private let attachmentFailure: (any Error & Sendable)?
    private let recorded = Mutex<[Message]>([])

    init(failure: (any Error & Sendable)?, attachmentFailure: (any Error & Sendable)? = nil) {
        self.failure = failure
        self.attachmentFailure = attachmentFailure
    }

    var messages: [Message] {
        recorded.withLock { $0 }
    }

    func send(to recipient: String, subject: String, body: String, attachments: [URL]) async throws {
        recorded.withLock {
            $0.append(
                Message(
                    recipient: recipient,
                    subject: subject,
                    body: body,
                    attachments: attachments.map(\.path),
                    attachmentContents: attachments.map { try? String(contentsOf: $0, encoding: .utf8) }
                )
            )
        }
        if let error = attachments.isEmpty ? failure : (attachmentFailure ?? failure) {
            throw error
        }
    }
}
