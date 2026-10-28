//
//  ZenCronMailDelivery.swift
//  ZenCODE
//

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Synchronization
import ToolCore

/// Delivers the output of a scheduled headless run through Mail.app instead
/// of cron's own mail.
///
/// Cron mails whatever a job writes through the local `sendmail`. On a network
/// that blocks outbound port 25 that message never leaves the Mac. So when
/// `zen` runs under cron with a deliverable `MAILTO`, it captures what it would
/// have printed and sends it as one message from Mail's default account,
/// printing nothing. If Mail.app cannot send it, the captured bytes are printed
/// exactly as before (plus one line explaining why), so cron falls back to its
/// own mail and nothing is lost.
///
/// Delivery depends only on the environment cron gives the job. `/cron run`
/// starts the job with `ZenCronEnvironment.minimal`, which has no `MAILTO`,
/// so its output stays in the chat.
///
/// Mail.app takes only plain text as a message body. So for a text-mode run
/// (not `--jsonl`) the body is the plain text of the Markdown answer
/// (`ZenCronMailPlainText`) and the Markdown answer itself, as it is, goes
/// along as a `.md` attachment. A `--jsonl` run is sent as is, without
/// attachment. If the attachment cannot be made or sent the message goes
/// without it, with a line saying so.
enum ZenCronMailDelivery {
    /// The crontab variable that cron passes to every job and that names
    /// where its output is mailed.
    nonisolated static let mailToEnvironmentKey = "MAILTO"
    /// The macOS feature tool that drives Mail.app.
    nonisolated static let mailToolName = "macos.mail"
    /// Maximum length of an inline prompt used as subject label, ellipsis
    /// included.
    nonisolated static let labelCharacterLimit = 60
    /// The directory, inside the temporary directory, that holds the Markdown
    /// attachments, one subdirectory per delivery.
    nonisolated static let attachmentsDirectoryName = "zencode-cron-mail"
    /// How long the subdirectory of a delivery is kept: Mail may read an
    /// attachment after the delivery returned, so a delivery only removes the
    /// directories of earlier ones that are older than this.
    nonisolated static let attachmentRetention: TimeInterval = 60 * 60
    /// The attachment name base used when the job gives none that survives
    /// `sanitizedFileNameBase`.
    nonisolated static let fallbackAttachmentBaseName = "zencode-cron"

    /// Where production deliveries put their attachments.
    nonisolated static var defaultAttachmentsDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(attachmentsDirectoryName, isDirectory: true)
    }

    // MARK: - Activation

    /// The address Mail.app should deliver to, or nil when delivery stays with
    /// cron.
    ///
    /// The address must satisfy the rule `/cron mailto` applies
    /// (`TerminalChat.validatedCronMailTo`) and contain "@": a bare local user
    /// name is a mailbox only cron's `sendmail` can reach. A terminal on
    /// standard output means a person is running `zen` (maybe with `MAILTO`
    /// exported in the shell), not cron, so their output is never mailed
    /// away. Mail.app exists only on macOS: elsewhere this is always nil.
    nonisolated static func recipient(
        environment: [String: String],
        standardOutputIsTerminal: Bool
    ) -> String? {
        #if os(macOS)
        guard !standardOutputIsTerminal,
              let value = environment[mailToEnvironmentKey],
              let address = try? TerminalChat.validatedCronMailTo(
                  value.trimmingCharacters(in: .whitespacesAndNewlines)
              ),
              address.contains("@") else {
            return nil
        }
        return address
        #else
        return nil
        #endif
    }

    // MARK: - Message

    /// The subject of the delivered message, for example
    /// `ZenCODE cron: report.md – 2026-10-25`.
    ///
    /// A failed run says so in the subject, so the message can be spotted in
    /// the mailbox without opening it. When the label is empty the
    /// `: <label>` part is left out.
    nonisolated static func subject(
        succeeded: Bool,
        promptFile: String?,
        prompt: String?,
        date: Date,
        timeZone: TimeZone
    ) -> String {
        let prefix = succeeded ? "ZenCODE cron" : "ZenCODE cron failed"
        let label = label(promptFile: promptFile, prompt: prompt)
        let title = label.isEmpty ? prefix : "\(prefix): \(label)"
        return "\(title) – \(day(of: date, in: timeZone))"
    }

    /// What identifies the job in a subject: the prompt file name, which says
    /// more than its inline instruction when both are present, or else the
    /// inline prompt on one line, shortened to `labelCharacterLimit`
    /// characters.
    nonisolated static func label(promptFile: String?, prompt: String?) -> String {
        if let promptFile {
            return URL(fileURLWithPath: promptFile).lastPathComponent
        }
        let text = singleLine(prompt ?? "")
        guard text.count > labelCharacterLimit else {
            return text
        }
        return String(text.prefix(labelCharacterLimit - 1)) + "…"
    }

    /// The day of a run as `yyyy-MM-dd` in `timeZone`. The format is fixed
    /// (POSIX locale, Gregorian calendar) so subjects sort and read the same
    /// whatever the user's locale.
    nonisolated static func day(of date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    /// `text` with every run of whitespace, line breaks included, replaced by
    /// one space, and trimmed.
    nonisolated static func singleLine(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The file name of the Markdown attachment, for example
    /// `report-2025-10-25.md`: the name of the prompt file without its
    /// extension, or else the label of the inline prompt, then the day of the
    /// run as in the subject.
    nonisolated static func attachmentFileName(
        promptFile: String?,
        prompt: String?,
        date: Date,
        timeZone: TimeZone
    ) -> String {
        let base: String
        if let promptFile {
            base = URL(fileURLWithPath: promptFile).deletingPathExtension().lastPathComponent
        } else {
            base = label(promptFile: nil, prompt: prompt)
        }
        return "\(sanitizedFileNameBase(base))-\(day(of: date, in: timeZone)).md"
    }

    /// `name` fit to be part of a file name: path separators, `:` and control
    /// characters become `-`, and spaces and dots are trimmed from both ends.
    /// A name with nothing left is `fallbackAttachmentBaseName`.
    nonisolated static func sanitizedFileNameBase(_ name: String) -> String {
        let forbidden: Set<Unicode.Scalar> = ["/", "\\", ":"]
        var replaced = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            if forbidden.contains(scalar) || scalar.properties.generalCategory == .control {
                replaced.append("-")
            } else {
                replaced.append(scalar)
            }
        }
        let trimmed = String(replaced).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? fallbackAttachmentBaseName : trimmed
    }

    /// The arguments of `macos.mail` `send`. `confirm` is the explicit
    /// approval the tool requires for outbound mail: the user gave it once,
    /// by scheduling the job with a `MAILTO`. `from` is omitted so that Mail
    /// sends from its default account. `attachments`, the paths of the files
    /// to attach, is present only when there is at least one.
    nonisolated static func sendArguments(
        recipient: String,
        subject: String,
        body: String,
        attachments: [URL] = []
    ) -> [String: JSONValue] {
        var arguments: [String: JSONValue] = [
            "action": .string("send"),
            "confirm": .bool(true),
            "to": .array([.string(recipient)]),
            "subject": .string(subject),
            "body": .string(body)
        ]
        if !attachments.isEmpty {
            arguments["attachments"] = .array(attachments.map { .string($0.path) })
        }
        return arguments
    }

    nonisolated static func sendToolCall(
        recipient: String,
        subject: String,
        body: String,
        attachments: [URL] = []
    ) -> DirectAgentToolCall {
        let arguments = sendArguments(
            recipient: recipient,
            subject: subject,
            body: body,
            attachments: attachments
        )
        return DirectAgentToolCall(
            id: "zen-cron-mail-\(UUID().uuidString)",
            name: mailToolName,
            argumentsObject: arguments.mapValues(\.jsonObject),
            argumentsJSON: JSONValue.object(arguments).compactString(sortedKeys: true)
        )
    }

    // MARK: - Delivery

    /// Sends `output` to `recipient`, or, when Mail.app cannot, writes it as
    /// the run would have printed it.
    ///
    /// A text-mode `output` is sent as plain text converted from its Markdown
    /// (consecutive standard output chunks are one document; standard error is
    /// kept verbatim, in order) and, when it has standard output text, with the
    /// Markdown answer, as it is, attached as the `.md` file `attachmentName`
    /// in a new subdirectory of `attachmentsDirectory` (owner-only
    /// permissions). The file is left in
    /// place after the send, because Mail may read it later; each delivery
    /// removes the subdirectories older than `attachmentRetention` first. A
    /// JSONL `output` is sent unchanged and without attachment.
    ///
    /// If the attachment cannot be written, or the message with it is not
    /// sent, the message is sent again without it, with a final line telling
    /// the recipient why the Markdown file is missing.
    ///
    /// On success nothing is written: any output would make cron send a second
    /// message, which would only sit in the local mail queue. When the last
    /// attempt fails, every captured chunk, as captured and not converted, goes
    /// to the stream it was meant for, followed by one
    /// `ZenCODE: Mail.app delivery to <address> failed: <reason>` line on
    /// standard error, so the message cron sends explains why it came that way.
    ///
    /// - Returns: Whether Mail.app sent the message.
    @discardableResult
    static func deliver(
        _ output: [ZenCronCapturedOutput.Chunk],
        format: ZenCronJobCommand.OutputFormat,
        to recipient: String,
        subject: String,
        attachmentName: String,
        attachmentsDirectory: URL,
        sender: any ZenCronMailSending,
        writeStandardOutput: (Data) -> Void,
        writeStandardError: (Data) -> Void
    ) async -> Bool {
        removeStaleAttachmentDirectories(in: attachmentsDirectory)

        let message = Message(output, format: format)
        var attachments: [URL] = []
        var attachmentFailure: String?
        if let markdown = message.attachableMarkdown {
            do {
                attachments = [
                    try writeAttachment(
                        markdown,
                        named: attachmentName,
                        in: attachmentsDirectory
                    )
                ]
            } catch {
                attachmentFailure = error.localizedDescription
            }
        }

        if !attachments.isEmpty {
            do {
                try await sender.send(
                    to: recipient,
                    subject: subject,
                    body: message.body,
                    attachments: attachments
                )
                return true
            } catch {
                attachmentFailure = error.localizedDescription
            }
        }

        let body: String
        if let attachmentFailure {
            body = appendingAttachmentFailureLine(attachmentFailure, to: message.body)
        } else {
            body = message.body
        }
        do {
            try await sender.send(to: recipient, subject: subject, body: body, attachments: [])
            return true
        } catch {
            for chunk in output {
                switch chunk.stream {
                case .standardOutput:
                    writeStandardOutput(chunk.data)
                case .standardError:
                    writeStandardError(chunk.data)
                }
            }
            writeStandardError(Data(deliveryFailureLine(recipient: recipient, error: error).utf8))
            return false
        }
    }

    /// What a delivery sends, built from the captured output.
    struct Message: Equatable {
        /// The plain-text body.
        let body: String
        /// The standard output text, which the Markdown attachment contains as
        /// it is, or nil when the message has no attachment: a JSONL run, or a
        /// text run with nothing but whitespace on standard output.
        let attachableMarkdown: String?

        init(_ output: [ZenCronCapturedOutput.Chunk], format: ZenCronJobCommand.OutputFormat) {
            switch format {
            case .jsonl:
                body = ZenCronCapturedOutput.body(of: output)
                attachableMarkdown = nil
            case .text:
                // Consecutive chunks of a stream are decoded together, so that
                // a character split between two of them survives.
                var runs: [(stream: ZenCronCapturedOutput.Stream, data: Data)] = []
                for chunk in output {
                    if let last = runs.last, last.stream == chunk.stream {
                        runs[runs.count - 1].data.append(chunk.data)
                    } else {
                        runs.append((chunk.stream, chunk.data))
                    }
                }
                var body = ""
                var standardOutput = ""
                for run in runs {
                    let text = String(decoding: run.data, as: UTF8.self)
                    switch run.stream {
                    case .standardOutput:
                        standardOutput += text
                        body += ZenCronMailPlainText.render(markdown: text)
                    case .standardError:
                        body += text
                    }
                }
                self.body = body
                attachableMarkdown = standardOutput.contains { !$0.isWhitespace } ? standardOutput : nil
            }
        }
    }

    /// `body` followed, after a blank line, by one line saying that the
    /// Markdown file is missing and why.
    nonisolated static func appendingAttachmentFailureLine(_ reason: String, to body: String) -> String {
        var text = body
        if !text.isEmpty {
            if !text.hasSuffix("\n") {
                text += "\n"
            }
            text += "\n"
        }
        let reason = singleLine(reason)
        return text + "ZenCODE: the Markdown file could not be attached: \(reason.isEmpty ? "unknown error" : reason)\n"
    }

    /// Writes `contents` as `name` in a subdirectory of `directory` created for
    /// this delivery, readable by the owner only.
    private static func writeAttachment(
        _ contents: String,
        named name: String,
        in directory: URL
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let deliveryDirectory = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(
            at: deliveryDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let file = deliveryDirectory.appendingPathComponent(name, isDirectory: false)
        try Data(contents.utf8).write(to: file, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    /// Removes the subdirectories of `directory` last modified before `now`
    /// minus `age`: the leftovers of earlier deliveries. Errors are ignored:
    /// the cleanup never stands in the way of a delivery.
    static func removeStaleAttachmentDirectories(
        in directory: URL,
        olderThan age: TimeInterval = attachmentRetention,
        now: Date = Date()
    ) {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: keys
        ) else {
            return
        }
        let cutoff = now.addingTimeInterval(-age)
        for entry in entries {
            guard let values = try? entry.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true,
                  let modified = values.contentModificationDate,
                  modified < cutoff else {
                continue
            }
            try? fileManager.removeItem(at: entry)
        }
    }

    /// One line, whatever the error: a multi-line reason (a feature process
    /// failure quotes the process output) is flattened.
    nonisolated static func deliveryFailureLine(recipient: String, error: Error) -> String {
        "ZenCODE: Mail.app delivery to \(recipient) failed: \(singleLine(error.localizedDescription))\n"
    }
}

// MARK: - Capture

/// What a Mail-delivered run would have printed, in order, with the stream
/// each part was meant for. The stream is kept so that a fallback prints
/// exactly what the run would have printed without Mail.app (a text-mode
/// failure goes to standard error), even though cron mails both streams
/// together.
final class ZenCronCapturedOutput: Sendable {
    enum Stream: Sendable, Equatable {
        case standardOutput
        case standardError
    }

    struct Chunk: Sendable, Equatable {
        let stream: Stream
        let data: Data
    }

    private let storage = Mutex<[Chunk]>([])

    var chunks: [Chunk] {
        storage.withLock { $0 }
    }

    func append(_ data: Data, to stream: Stream = .standardOutput) {
        storage.withLock { $0.append(Chunk(stream: stream, data: data)) }
    }

    func append(_ text: String, to stream: Stream = .standardOutput) {
        append(Data(text.utf8), to: stream)
    }

    /// The message body: every chunk, decoded as UTF-8 with invalid bytes
    /// replaced rather than dropping the message.
    static func body(of chunks: [Chunk]) -> String {
        String(decoding: chunks.reduce(into: Data()) { $0.append($1.data) }, as: UTF8.self)
    }
}

// MARK: - Fallback streams

/// Private duplicates of the process's real standard output and standard
/// error, taken before `AgentOutput.silenceAllStandardError()` points the
/// shared error handle at `/dev/null`. Only the Mail.app fallback writes to
/// them, so stray diagnostics during the run cannot become cron output.
struct ZenCronFallbackOutput {
    let standardOutput: FileHandle
    let standardError: FileHandle

    /// Duplicates the handles `AgentOutput` keeps for the original streams.
    /// If a descriptor cannot be duplicated, the shared handle is used: it
    /// still works for standard output, while standard error then ends up
    /// silenced together with it.
    static func duplicatingAgentOutput() -> ZenCronFallbackOutput {
        ZenCronFallbackOutput(
            standardOutput: duplicate(AgentOutput.standardOutput),
            standardError: duplicate(AgentOutput.standardError)
        )
    }

    private static func duplicate(_ handle: FileHandle) -> FileHandle {
        let fileDescriptor = dup(handle.fileDescriptor)
        guard fileDescriptor >= 0 else {
            return handle
        }
        return FileHandle(fileDescriptor: fileDescriptor, closeOnDealloc: true)
    }
}

// MARK: - Sending

/// Sends one message: a plain-text body and, optionally, files attached to
/// it. Production uses Mail.app through `ZenCronFeatureMailSender`; tests
/// supply a fake so no mail is ever sent.
protocol ZenCronMailSending: Sendable {
    /// Throws when the message was not sent, for whatever reason, an
    /// attachment Mail cannot read included.
    func send(to recipient: String, subject: String, body: String, attachments: [URL]) async throws
}

/// Sends through the `macos.mail` tool of the macOS feature, invoked directly
/// rather than through a model turn: the content is fixed and no agent is
/// involved.
struct ZenCronFeatureMailSender: ZenCronMailSending {
    let workingDirectory: URL
    /// Only enabled features are loaded, so a disabled macOS feature is
    /// reported as unavailable instead of being run. Tests pass a runtime
    /// without features, so they can never reach Mail.app.
    var makeRuntime: @Sendable () -> SwiftFeatureRuntime = { SwiftFeatureRuntime() }

    func send(to recipient: String, subject: String, body: String, attachments: [URL]) async throws {
        let runtime = makeRuntime()
        let result: SwiftFeatureInvocationResult?
        do {
            // Every feature-side failure (`ok: false`, a failing exit status, a
            // timeout) is thrown by the runtime.
            result = try await runtime.executeResultIfAvailable(
                toolCall: ZenCronMailDelivery.sendToolCall(
                    recipient: recipient,
                    subject: subject,
                    body: body,
                    attachments: attachments
                ),
                workingDirectory: workingDirectory
            )
        } catch {
            await runtime.shutdown()
            throw error
        }
        await runtime.shutdown()
        guard result != nil else {
            throw ZenCronMailDeliveryError.mailToolUnavailable
        }
    }
}

enum ZenCronMailDeliveryError: LocalizedError, Equatable {
    /// No enabled feature provides `macos.mail`.
    case mailToolUnavailable

    var errorDescription: String? {
        switch self {
        case .mailToolUnavailable:
            return "the \(ZenCronMailDelivery.mailToolName) tool is unavailable "
                + "(the macOS feature is not installed or not enabled)"
        }
    }
}
