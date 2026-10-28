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

    @Test("without a prompt file the attachment is named after the inline prompt label")
    func attachmentNameFromTheInlinePrompt() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        func name(_ prompt: String?) -> String {
            ZenCronMailDelivery.attachmentFileName(
                promptFile: nil,
                prompt: prompt,
                date: runDate,
                timeZone: utc
            )
        }
        #expect(name("summarize\nthe changes") == "summarize the changes-2025-10-25.md")
        #expect(name("check a/b\\c: now") == "check a-b-c- now-2025-10-25.md")
        #expect(name(String(repeating: "a", count: 61)) == String(repeating: "a", count: 59) + "…-2025-10-25.md")
        #expect(name(nil) == "zencode-cron-2025-10-25.md")
        #expect(name("   ") == "zencode-cron-2025-10-25.md")
    }

    @Test("the day of the attachment follows the time zone like the subject")
    func attachmentNameUsesTheTimeZone() throws {
        let losAngeles = try #require(TimeZone(identifier: "America/Los_Angeles"))
        #expect(
            ZenCronMailDelivery.attachmentFileName(
                promptFile: "/x/report.md",
                prompt: nil,
                date: runDate,
                timeZone: losAngeles
            ) == "report-2025-10-24.md"
        )
    }

    @Test("separators, colons and control characters become dashes and the ends are trimmed")
    func sanitizedAttachmentBase() {
        #expect(ZenCronMailDelivery.sanitizedFileNameBase("a/b\\c:d") == "a-b-c-d")
        #expect(ZenCronMailDelivery.sanitizedFileNameBase("x\u{07}y\u{0}z\ttab\nline") == "x-y-z-tab-line")
        #expect(ZenCronMailDelivery.sanitizedFileNameBase(" ..name.. ") == "name")
        #expect(ZenCronMailDelivery.sanitizedFileNameBase(". name with spaces .") == "name with spaces")
        #expect(ZenCronMailDelivery.sanitizedFileNameBase("report.final") == "report.final")
        #expect(ZenCronMailDelivery.sanitizedFileNameBase("relatório – ✓") == "relatório – ✓")
    }

    @Test("a name with nothing left falls back to zencode-cron")
    func sanitizedAttachmentBaseFallback() {
        for name in ["", " ", "...", " . . ", "\u{A0}"] {
            // A no-break space is not trimmed: only spaces and dots are.
            #expect(
                ZenCronMailDelivery.sanitizedFileNameBase(name)
                    == (name == "\u{A0}" ? "\u{A0}" : "zencode-cron")
            )
        }
        #expect(ZenCronMailDelivery.sanitizedFileNameBase("\t") == "-")
        #expect(ZenCronMailDelivery.fallbackAttachmentBaseName == "zencode-cron")
    }

    @Test("production attachments go to a zencode-cron-mail directory in the temporary directory")
    func defaultAttachmentsDirectory() {
        let directory = ZenCronMailDelivery.defaultAttachmentsDirectory
        #expect(directory.lastPathComponent == "zencode-cron-mail")
        #expect(
            directory.deletingLastPathComponent().path
                == FileManager.default.temporaryDirectory.path
        )
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

    @Test("without attachments the send arguments have exactly the keys they always had")
    func sendArgumentsWithoutAttachments() {
        let arguments = ZenCronMailDelivery.sendArguments(
            recipient: "user@example.com",
            subject: "subject",
            body: "body",
            attachments: []
        )
        #expect(arguments.keys.sorted() == ["action", "body", "confirm", "subject", "to"])
        #expect(
            arguments == ZenCronMailDelivery.sendArguments(
                recipient: "user@example.com",
                subject: "subject",
                body: "body"
            )
        )
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

    @Test("each run gets its own subdirectory")
    func everyDeliveryHasItsOwnDirectory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = RecordingMailSender(failure: nil)

        for _ in 0..<2 {
            await deliver(
                capturedOutput([(.standardOutput, "text\n")]),
                attachmentName: "same-name.md",
                directory: directory,
                sender: sender
            )
        }

        let paths = sender.messages.compactMap(\.attachments.first)
        #expect(paths.count == 2)
        #expect(Set(paths).count == 2)
        #expect(paths.allSatisfy { FileManager.default.fileExists(atPath: $0) })
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
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

    @Test("a character split between two chunks survives the conversion")
    func splitCharactersSurvive() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = RecordingMailSender(failure: nil)
        let output = ZenCronCapturedOutput()
        output.append(Data([0xC3]))
        output.append(Data([0xA8, 0x0A]))

        await deliver(output.chunks, attachmentName: "run.md", directory: directory, sender: sender)

        let message = try #require(sender.messages.first)
        #expect(message.body == "è\n")
        #expect(message.attachmentContents == ["è\n"])
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

    @Test("a text-mode run with nothing but whitespace on standard output has no attachment")
    func noAttachmentWithoutStandardOutputText() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let cases: [[(ZenCronCapturedOutput.Stream, String)]] = [
            [],
            [(.standardOutput, "")],
            [(.standardOutput, "  \n\n\t \n")],
            [(.standardOutput, "\n"), (.standardError, "ZenCODE: failure *details*\n")]
        ]
        for output in cases {
            let sender = RecordingMailSender(failure: nil)
            let result = await deliver(
                capturedOutput(output),
                attachmentName: "run.md",
                directory: directory,
                sender: sender
            )
            #expect(result.delivered)
            let message = try #require(sender.messages.first)
            #expect(sender.messages.count == 1)
            #expect(message.attachments.isEmpty)
            #expect(!message.body.contains("Markdown file"))
            #expect(message.body == output.filter { $0.0 == .standardError }.map { $0.1 }.joined())
        }
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

    @Test("the note goes after a body that does not end with a line break, and after standard error")
    func attachmentNoteFollowsTheBody() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = RecordingMailSender(failure: nil, attachmentFailure: DirectToolError.toolFailed("no way"))

        await deliver(
            capturedOutput([(.standardOutput, "text\n"), (.standardError, "late warning")]),
            attachmentName: "run.md",
            directory: directory,
            sender: sender
        )

        #expect(
            sender.messages.last?.body == "text\nlate warning\n\n"
                + "ZenCODE: the Markdown file could not be attached: no way\n"
        )
        #expect(
            ZenCronMailDelivery.appendingAttachmentFailureLine("x", to: "")
                == "ZenCODE: the Markdown file could not be attached: x\n"
        )
        #expect(
            ZenCronMailDelivery.appendingAttachmentFailureLine("  ", to: "body\n")
                == "body\n\nZenCODE: the Markdown file could not be attached: unknown error\n"
        )
    }

    @Test("when the attachment cannot be written the message is sent without it, with a note")
    func unwritableDirectorySendsWithoutAttachment() async throws {
        // A file where the directory should be: nothing can be created in it,
        // whatever the privileges of the user running the tests.
        let blocker = temporaryDirectory()
        try Data("not a directory".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let sender = RecordingMailSender(failure: nil)

        let result = await deliver(
            capturedOutput([(.standardOutput, "Plain text\n")]),
            attachmentName: "run.md",
            directory: blocker,
            sender: sender
        )

        #expect(result.delivered)
        #expect(result.standardOutput.isEmpty)
        #expect(result.standardError.isEmpty)
        let message = try #require(sender.messages.first)
        #expect(sender.messages.count == 1)
        #expect(message.attachments.isEmpty)
        let prefix = "Plain text\n\nZenCODE: the Markdown file could not be attached: "
        #expect(message.body.hasPrefix(prefix))
        let reason = message.body.dropFirst(prefix.count)
        #expect(reason.hasSuffix("\n"))
        #expect(reason.dropLast().count > 0)
        #expect(!reason.dropLast().contains("\n"))
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

    @Test("a failure to write the attachment and to send without it falls back too")
    func unwritableDirectoryAndFailedSendFallBack() async throws {
        let blocker = temporaryDirectory()
        try Data("file".utf8).write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let sender = RecordingMailSender(failure: DirectToolError.toolFailed("Mail is not running."))

        let result = await deliver(
            capturedOutput([(.standardOutput, "# Original\n")]),
            attachmentName: "run.md",
            directory: blocker,
            sender: sender
        )

        #expect(!result.delivered)
        #expect(sender.messages.count == 1)
        #expect(result.standardOutput == Data("# Original\n".utf8))
        #expect(
            String(decoding: result.standardError, as: UTF8.self)
                == "ZenCODE: Mail.app delivery to user@example.com failed: Mail is not running.\n"
        )
    }

    @Test("a failed send without attachment prints the output and one line explaining why")
    func deliveryFailureFallsBackToTheStreams() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = RecordingMailSender(failure: DirectToolError.toolFailed("Mail did not send the message."))
        let records = "{\"type\":\"run.started\"}\n{\"type\":\"run.completed\"}\n"

        let result = await deliver(
            capturedOutput([(.standardOutput, records)]),
            format: .jsonl,
            directory: directory,
            sender: sender
        )

        #expect(!result.delivered)
        #expect(sender.messages.count == 1)
        #expect(result.standardOutput == Data(records.utf8))
        #expect(
            String(decoding: result.standardError, as: UTF8.self)
                == "ZenCODE: Mail.app delivery to user@example.com failed: Mail did not send the message.\n"
        )
    }

    @Test("a failed send prints a text-mode error on standard error, before the explanation")
    func deliveryFailureKeepsTextErrorsOnStandardError() async {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sender = RecordingMailSender(failure: ZenCronMailDeliveryError.mailToolUnavailable)
        let failure = ZenCODECommandLineRunner.failureMessage(for: ZenCODEHeadlessRunnerError.noResponse)

        let result = await deliver(
            capturedOutput([(.standardError, failure)]),
            directory: directory,
            sender: sender
        )

        #expect(result.standardOutput.isEmpty)
        #expect(
            String(decoding: result.standardError, as: UTF8.self)
                == failure
                + "ZenCODE: Mail.app delivery to user@example.com failed: "
                + "the macos.mail tool is unavailable (the macOS feature is not installed or not enabled)\n"
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

    @Test("the cleanup also runs before a JSONL delivery and tolerates a missing directory")
    func cleanupBeforeEveryDelivery() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = FileManager.default
        let old = directory.appendingPathComponent("old-run", isDirectory: true)
        try fileManager.createDirectory(at: old, withIntermediateDirectories: true)
        try fileManager.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3 * 3600)],
            ofItemAtPath: old.path
        )

        await deliver(
            capturedOutput([(.standardOutput, "{}\n")]),
            format: .jsonl,
            directory: directory,
            sender: RecordingMailSender(failure: nil)
        )
        #expect(!fileManager.fileExists(atPath: old.path))

        let missing = temporaryDirectory()
        ZenCronMailDelivery.removeStaleAttachmentDirectories(in: missing)
        #expect(!fileManager.fileExists(atPath: missing.path))
    }

    @Test("the age limit is applied to the given time")
    func cleanupAge() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileManager = FileManager.default
        let now = Date()

        func makeSubdirectory(_ name: String, age: TimeInterval) throws -> URL {
            let subdirectory = directory.appendingPathComponent(name, isDirectory: true)
            try fileManager.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            try fileManager.setAttributes(
                [.modificationDate: now.addingTimeInterval(-age)],
                ofItemAtPath: subdirectory.path
            )
            return subdirectory
        }
        let justOver = try makeSubdirectory("over", age: 3601)
        let justUnder = try makeSubdirectory("under", age: 3599)

        #expect(ZenCronMailDelivery.attachmentRetention == 3600)
        ZenCronMailDelivery.removeStaleAttachmentDirectories(in: directory, now: now)

        #expect(!fileManager.fileExists(atPath: justOver.path))
        #expect(fileManager.fileExists(atPath: justUnder.path))

        ZenCronMailDelivery.removeStaleAttachmentDirectories(in: directory, olderThan: 60, now: now)
        #expect(!fileManager.fileExists(atPath: justUnder.path))
    }

    // MARK: - Captured output

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
            try await sender.send(to: "user@example.com", subject: "subject", body: "body", attachments: [])
        }
        await #expect(throws: ZenCronMailDeliveryError.mailToolUnavailable) {
            try await sender.send(
                to: "user@example.com",
                subject: "subject",
                body: "body",
                attachments: [URL(fileURLWithPath: "/tmp/never-read.md")]
            )
        }
    }

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
