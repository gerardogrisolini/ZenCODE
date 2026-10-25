//
//  TerminalChat+Cron.swift
//  ZenCODE
//

import Foundation
import ToolCore

/// `/cron`: schedules headless prompts in the user's crontab.
///
/// ZenCODE owns one marked block of the crontab (see `ZenCrontabDocument`);
/// every other line is preserved verbatim. Results are never collected by
/// ZenCODE: cron mails each job's output, so the only delivery setting is the
/// block's `MAILTO`.
extension TerminalChat {
    nonisolated static let cronUsageMessage =
        "Usage: /cron [list] | add [json] <schedule> [-f <path>] <prompt> | remove <n> | run <n> | mailto [address|none|default]\n"

    func handleCronCommand(_ command: String) async {
        let arguments = Self.slashCommandArguments(from: command, commandPrefix: "/cron")
        let (subcommand, remainder) = Self.cronSplitLeadingToken(arguments)

        do {
            switch subcommand.lowercased() {
            case "", "list":
                guard remainder.isEmpty else {
                    await writeFailureMessage(Self.cronUsageMessage)
                    return
                }
                try await listCronEntries()
            case "add":
                try await addCronEntry(arguments: remainder)
            case "remove":
                try await removeCronEntry(arguments: remainder)
            case "run":
                try await runCronEntry(arguments: remainder)
            case "mailto":
                try await handleCronMailTo(arguments: remainder)
            default:
                await writeFailureMessage(Self.cronUsageMessage)
            }
        } catch {
            await writeFailureMessage("ZenCODE: \(error.localizedDescription)\n")
        }
    }

    // MARK: - Subcommands

    private func listCronEntries() async throws {
        let document = try await readCronDocument()
        await writeSystemMessage(Self.renderCronList(document))
    }

    private func addCronEntry(arguments: String) async throws {
        guard let parsed = Self.parseCronAddArguments(arguments) else {
            await writeFailureMessage(Self.cronUsageMessage)
            return
        }
        // Schedule, prompt and prompt file are validated before the crontab is
        // read, so a rejected command never touches it.
        let schedule = try ZenCronSchedule(parsing: parsed.schedule)
        // With `-f` the prompt is an optional instruction; without it, required.
        let prompt: String?
        if parsed.promptFile != nil,
           parsed.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            prompt = nil
        } else {
            prompt = try Self.validatedCronPrompt(parsed.prompt)
        }
        // Only the path is stored: cron reads the file at every run, so it is
        // checked here once, to refuse a job that could never start.
        let promptFile: String?
        if let path = parsed.promptFile {
            promptFile = try Self.validatedCronPromptFile(path)
            _ = try ZenCODEPromptFile.read(path: path)
        } else {
            promptFile = nil
        }
        let job = ZenCronJobCommand(
            executable: ZenCronJobCommand.zenExecutable,
            supportDirectory: ProcessInfo.processInfo
                .environment[AppStorageDirectory.supportDirectoryEnvironmentKey]?.nilIfBlank,
            agentName: selectedAgent?.name,
            workingDirectory: configuration.workingDirectory.path,
            outputFormat: parsed.outputFormat,
            promptFile: promptFile,
            prompt: prompt
        )

        var document = try await readCronDocument()
        // The line runs a bare `zen`, found through the block's `PATH=`; refuse
        // to schedule a job that cron could not start, before writing anything.
        let path = document.effectivePath
        guard let zenPath = cronZenLocator(path) else {
            throw ZenCrontabError.zenNotOnPath(path: path)
        }
        document.appendEntry(schedule: schedule, job: job)
        try await writeCronDocument(document)

        let items = document.block?.items ?? []
        var message = "Scheduled prompt #\(items.count) added:\n"
        if case let .entry(entry)? = items.last {
            message += "  \(entry.cronLine)\n"
        }
        message += "  zen: \(zenPath) (PATH=\(path))\n"
        await writeSystemMessage(message)
    }

    private func removeCronEntry(arguments: String) async throws {
        guard let number = Int(arguments) else {
            await writeFailureMessage(Self.cronUsageMessage)
            return
        }

        var document = try await readCronDocument()
        try document.removeItem(number: number)
        try await writeCronDocument(document)
        await writeSystemMessage("Scheduled prompt #\(number) removed.\n")
    }

    /// Runs one entry now, the way cron would (minimal environment, home
    /// directory, `/bin/sh`), so the user can check the environment, the
    /// binary and the approvals. The report arrives later: the chat stays
    /// usable while the job runs.
    private func runCronEntry(arguments: String) async throws {
        guard let number = Int(arguments) else {
            await writeFailureMessage(Self.cronUsageMessage)
            return
        }

        let document = try await readCronDocument()
        let items = document.block?.items ?? []
        guard number >= 1, number <= items.count else {
            throw ZenCrontabError.noSuchEntry(number)
        }
        guard case let .entry(entry) = items[number - 1] else {
            await writeFailureMessage(
                "ZenCODE: Scheduled prompt #\(number) is not a recognized ZenCODE entry.\n"
            )
            return
        }
        // Checked after the crontab read and recorded below without any
        // suspension in between, so two `/cron run` can never both pass.
        if let active = activeCronRun {
            await writeFailureMessage(
                "ZenCODE: A /cron run is already in progress (#\(active.number)). Wait for its report.\n"
            )
            return
        }

        let runner = cronJobRunner
        let cronCommand = entry.cronCommand
        // An entry ZenCODE did not write keeps the JSONL extraction.
        let outputFormat = entry.job?.outputFormat ?? .jsonl
        // Cron's environment, with the PATH the block sets for its jobs.
        let environment = ZenCronEnvironment.minimal(path: document.effectivePath)
        let homeDirectory = UserHomeDirectory.current()
        // Isolated to the actor, so it cannot start before `activeCronRun` is
        // assigned; the runner itself waits for the child off the actor.
        let task = Task(name: "ZenCODE.TUI.cron-run") { @TerminalChatActor [weak self] in
            let result: Result<ZenCronRunOutcome, any Error>
            do {
                result = .success(
                    try await runner.run(
                        cronCommand: cronCommand,
                        environment: environment,
                        homeDirectory: homeDirectory
                    )
                )
            } catch {
                result = .failure(error)
            }
            await self?.finishCronRun(number: number, outputFormat: outputFormat, result: result)
        }
        activeCronRun = (number, task)
        await writeSystemMessage("Running scheduled prompt #\(number) as cron would…\n")
    }

    /// Writes the deferred report of a `/cron run`, then releases the slot.
    ///
    /// The report goes straight to the render coordinator, the path every
    /// transcript message takes (it interrupts a live tool block and is held
    /// back while a consent card is open), and never through
    /// `writeSystemMessage`: it must not join the immediate output of an
    /// unrelated Telegram command that happens to be running. It is shown in
    /// the terminal only. Known limit: a report arriving while another slash
    /// command reads interactive input (e.g. the feature wizard) is printed
    /// among that command's prompts.
    ///
    /// A run cancelled by chat teardown prints nothing: the terminal is being
    /// torn down, possibly for `/setup`.
    private func finishCronRun(
        number: Int,
        outputFormat: ZenCronJobCommand.OutputFormat,
        result: Result<ZenCronRunOutcome, any Error>
    ) async {
        if !Task.isCancelled {
            switch result {
            case let .success(outcome):
                await renderCoordinator.writeSystemMessage(
                    Self.renderCronRunReport(number: number, outcome: outcome, outputFormat: outputFormat)
                )
            case let .failure(error):
                await renderCoordinator.writeFailureMessage(
                    "ZenCODE: Scheduled prompt #\(number) could not run: \(error.localizedDescription)\n"
                )
            }
        }
        // Only the owning task clears the slot, and teardown never does, so
        // no later run can be recorded here yet; the number check only guards
        // that invariant.
        if activeCronRun?.number == number {
            activeCronRun = nil
        }
    }

    private func handleCronMailTo(arguments: String) async throws {
        guard !arguments.isEmpty else {
            let document = try await readCronDocument()
            await writeSystemMessage(
                "MAILTO: \(Self.cronMailToDescription(document.block?.mailTo))\n"
            )
            return
        }

        let value: String?
        switch arguments.lowercased() {
        case "none":
            value = ""
        case "default":
            value = nil
        default:
            value = try Self.validatedCronMailTo(arguments)
        }

        var document = try await readCronDocument()
        document.setMailTo(value)
        try await writeCronDocument(document)
        await writeSystemMessage(
            "MAILTO for scheduled prompts: \(Self.cronMailToDescription(value))\n"
        )
    }

    // MARK: - Crontab access

    /// `Process` blocks, so every crontab call runs outside the actor.
    private func readCronDocument() async throws -> ZenCrontabDocument {
        let client = crontabClient
        let text = try await Task.detached { try client.readCrontab() }.value
        return try ZenCrontabDocument.parse(text)
    }

    private func writeCronDocument(_ document: ZenCrontabDocument) async throws {
        let client = crontabClient
        let text = document.render()
        try await Task.detached { try client.writeCrontab(text) }.value
    }

    // MARK: - Parsing and validation

    /// Splits `text` into its first whitespace-delimited token and the rest
    /// (without its leading whitespace). The rest keeps its inner line breaks.
    nonisolated static func cronSplitLeadingToken(
        _ text: String
    ) -> (token: String, remainder: String) {
        let trimmed = text.drop(while: \.isWhitespace)
        let token = trimmed.prefix(while: { !$0.isWhitespace })
        let remainder = trimmed.dropFirst(token.count).drop(while: \.isWhitespace)
        return (String(token), String(remainder))
    }

    /// Splits the arguments of `add` into output format, schedule text,
    /// optional prompt file and prompt text.
    ///
    /// A leading `json` token (any case) selects JSONL output; only the token
    /// right after `add` is the keyword, so `@daily json report` is a text job
    /// whose prompt is `json report`. The schedule is then the first token when
    /// it starts with `@`, otherwise the first five tokens.
    ///
    /// `-f <path>` (exact and case-sensitive) is the option only as the first
    /// token right after the schedule; anywhere else it is prompt text. The
    /// path is one whitespace-delimited token, or text wrapped in `'…'` or
    /// `"…"` (which may contain spaces; there are no escape sequences, and the
    /// closing quote must be followed by whitespace or the end). The prompt is
    /// the rest, possibly empty: whether that is acceptable is up to the caller.
    ///
    /// Returns `nil` when there are too few tokens for a schedule, when the
    /// path after `-f` is missing, or when its quote is unterminated or is
    /// followed by other characters.
    nonisolated static func parseCronAddArguments(
        _ arguments: String
    ) -> (
        schedule: String,
        prompt: String,
        outputFormat: ZenCronJobCommand.OutputFormat,
        promptFile: String?
    )? {
        var outputFormat = ZenCronJobCommand.OutputFormat.text
        var scheduleArguments = arguments
        let leading = cronSplitLeadingToken(arguments)
        if leading.token.lowercased() == cronJSONKeyword {
            outputFormat = .jsonl
            scheduleArguments = leading.remainder
        }

        let first = cronSplitLeadingToken(scheduleArguments)
        guard !first.token.isEmpty else { return nil }
        let schedule: String
        var remainder: String
        if first.token.hasPrefix("@") {
            schedule = first.token
            remainder = first.remainder
        } else {
            var fields: [String] = []
            remainder = scheduleArguments
            while fields.count < 5 {
                let next = cronSplitLeadingToken(remainder)
                guard !next.token.isEmpty else { return nil }
                fields.append(next.token)
                remainder = next.remainder
            }
            schedule = fields.joined(separator: " ")
        }

        let option = cronSplitLeadingToken(remainder)
        guard option.token == cronPromptFileOption else {
            return (schedule, remainder, outputFormat, nil)
        }
        guard let file = cronSplitPromptFilePath(option.remainder) else { return nil }
        return (schedule, file.remainder, outputFormat, file.path)
    }

    /// Splits the text after `-f` into the path and the rest (without its
    /// leading whitespace). `nil` when the path is missing, or when a quote
    /// is unterminated or is followed by a character other than whitespace.
    ///
    /// Scanned on Unicode scalars, like the stored command: a combining mark
    /// after a closing quote must not merge with it.
    private nonisolated static func cronSplitPromptFilePath(
        _ text: String
    ) -> (path: String, remainder: String)? {
        let scalars = text.unicodeScalars
        guard let opening = scalars.first else { return nil }
        guard opening == "'" || opening == "\"" else {
            let token = cronSplitLeadingToken(text)
            return (token.token, token.remainder)
        }

        let body = scalars.dropFirst()
        guard let closing = body.firstIndex(of: opening) else { return nil }
        let after = body[body.index(after: closing)...]
        if let next = after.first, !next.properties.isWhitespace {
            return nil
        }
        return (
            String(body[..<closing]),
            String(after.drop(while: { $0.properties.isWhitespace }))
        )
    }

    /// The keyword right after `add` that schedules a JSONL job.
    nonisolated static let cronJSONKeyword = "json"

    /// The option right after the schedule that reads the prompt from a file.
    nonisolated static let cronPromptFileOption = "-f"

    /// The prompt as it will be stored: trimmed, non-empty, on a single line.
    nonisolated static func validatedCronPrompt(_ prompt: String) throws -> String {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ZenCrontabError.invalidPrompt(reason: "the prompt is empty")
        }
        // Scalars, not Characters: "\r\n" is a single Character that equals
        // neither "\r" nor "\n".
        guard !trimmed.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw ZenCrontabError.invalidPrompt(reason: "it contains a line break")
        }
        return trimmed
    }

    /// The prompt file path as it will be stored: on a single line. Line
    /// breaks would split the crontab line. That the file exists and is
    /// readable is checked separately, with `ZenCODEPromptFile.read(path:)`.
    nonisolated static func validatedCronPromptFile(_ path: String) throws -> String {
        guard !path.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
            throw ZenCrontabError.invalidPromptFile(reason: "its path contains a line break")
        }
        return path
    }

    /// An address cron can place on a `MAILTO=` line: no whitespace of any
    /// kind and no double quote.
    nonisolated static func validatedCronMailTo(_ address: String) throws -> String {
        let isValid = !address.isEmpty
            && !address.unicodeScalars.contains { $0.properties.isWhitespace || $0 == "\"" }
        guard isValid else {
            throw ZenCrontabError.invalidMailTo(address)
        }
        return address
    }

    // MARK: - Rendering

    /// Lines of standard error quoted at the end of a `/cron run` report.
    nonisolated static let cronRunStderrLineLimit = 20

    nonisolated static func renderCronRunReport(
        number: Int,
        outcome: ZenCronRunOutcome,
        outputFormat: ZenCronJobCommand.OutputFormat
    ) -> String {
        var lines: [String] = []
        if outcome.wasTerminated {
            lines.append("Scheduled prompt #\(number) was terminated.")
        } else {
            lines.append(
                "Scheduled prompt #\(number) finished in \(cronRunDurationDescription(outcome.duration))"
                    + " with exit status \(outcome.exitStatus)."
            )
        }

        switch outputFormat {
        case .jsonl:
            switch ZenCronRunReport.extract(stdout: outcome.stdout) {
            case let .completed(text):
                lines.append("Result:\n\(text)")
            case let .failed(category, message):
                lines.append("Error (\(category)): \(message)")
            case .noResult:
                lines.append("No JSONL result on stdout.")
            }
        case .text:
            let text = outcome.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            lines.append(text.isEmpty ? "No output on stdout." : "Result:\n\(text)")
        }

        if !outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Split on `\n` only, like the JSONL reader: a `\r\n` stays one
            // line. Trailing empty lines carry nothing worth quoting.
            var stderrLines = outcome.stderr.utf8
                .split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
                .map { String(decoding: $0, as: UTF8.self) }
            while stderrLines.last?.isEmpty == true {
                stderrLines.removeLast()
            }
            lines.append("stderr (last \(cronRunStderrLineLimit) lines):")
            lines.append(contentsOf: stderrLines.suffix(cronRunStderrLineLimit))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// Seconds with one decimal (`12.3s`), rounded half up with integer
    /// arithmetic so the text never depends on floating-point formatting.
    nonisolated static func cronRunDurationDescription(_ duration: Duration) -> String {
        let (seconds, attoseconds) = max(duration, .zero).components
        let attosecondsPerTenth: Int64 = 100_000_000_000_000_000
        let tenths = seconds * 10 + (attoseconds + attosecondsPerTenth / 2) / attosecondsPerTenth
        return "\(tenths / 10).\(tenths % 10)s"
    }

    nonisolated static func cronMailToDescription(_ mailTo: String?) -> String {
        guard let mailTo else {
            return "not set (cron default: local mailbox of the crontab owner)"
        }
        return mailTo.isEmpty ? "\"\" (mail disabled)" : mailTo
    }

    nonisolated static func renderCronList(_ document: ZenCrontabDocument) -> String {
        var lines = [
            "Scheduled prompts — MAILTO: \(cronMailToDescription(document.block?.mailTo))"
        ]

        let items = document.block?.items ?? []
        if items.isEmpty {
            lines.append("No scheduled prompts. Use /cron add <schedule> <prompt>.")
        }
        for (offset, item) in items.enumerated() {
            let number = offset + 1
            switch item {
            case let .entry(entry):
                if let job = entry.job {
                    let output = job.outputFormat == .jsonl ? "JSONL" : "text"
                    var line = "  \(number). \(entry.schedule) · agent: \(job.agentName ?? "default")"
                        + " · dir: \(job.workingDirectory) · output: \(output)"
                    if let promptFile = job.promptFile {
                        line += " · file: \(promptFile)"
                    }
                    if let prompt = job.prompt {
                        line += " · prompt: \(prompt)"
                    }
                    lines.append(line)
                } else {
                    lines.append(
                        "  \(number). \(entry.schedule) · command: \(entry.cronCommand)"
                    )
                }
            case let .unrecognized(line):
                lines.append("  \(number). (unrecognized) \(line)")
            }
        }

        lines.append(
            "Results are mailed by cron; set the recipient with /cron mailto <address>."
        )
        return lines.joined(separator: "\n") + "\n"
    }
}
