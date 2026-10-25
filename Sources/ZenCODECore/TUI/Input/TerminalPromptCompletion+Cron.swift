//
//  TerminalPromptCompletion+Cron.swift
//  ZenCODE
//

/// Completion vocabulary for the slots of `/cron` after its subcommand.
///
/// Like the rest of the catalogue it is static and synchronous: the crontab is
/// never read to complete anything. Texts mirror the grammar the handler
/// really accepts (`TerminalChat+Cron` and `ZenCronSchedule`); a hint that
/// advertised a value the parser rejects would be worse than no hint.
///
/// Rows are either values (aliases, examples, `-json`, `-agent`, `none`,
/// `default`) or guides (`isHint`): `<minute>`, `<prompt>`, … name what the
/// slot expects and are never inserted. The subcommand is matched
/// case-insensitively, like the dispatcher, so `/cron ADD ` behaves as
/// `/cron add `. The options of `add` (`-json`, `-agent`, `-f`) are exact and
/// case-sensitive.
///
/// `add` takes an optional leading `-json` option before the schedule. It is
/// offered only in that first operand slot; once typed it is skipped, so the
/// slots after it complete exactly like a text job.
///
/// Before the schedule, right after `add` or `-json`, `add` also takes
/// `-agent <name>`. The option is offered in that slot after the schedule
/// values; once typed, the next slot is the `<agent>` guide, and the name (all
/// its words, when it is quoted) is skipped like `-json`.
///
/// Right after the schedule `add` takes either the prompt or `-f <path>` (the
/// prompt is then an optional instruction and the file its context). `-f` is
/// offered only in that first slot, after the `<prompt>` guide, and once it is
/// the first operand the next slot is the `<path>` guide and the later ones the
/// optional-instruction guide.
extension TerminalPromptCompletionCatalog {
    static func cronLaterArgumentSuggestions(
        precedingArguments: [String],
        prefix: String
    ) -> [TerminalCommandSuggestion] {
        guard let subcommand = precedingArguments.first?.lowercased() else {
            return []
        }
        // Operands already typed before the token under the cursor.
        let operands = Array(precedingArguments.dropFirst())

        switch subcommand {
        case "add":
            return cronAddSuggestions(precedingOperands: operands, prefix: prefix)
        case "remove", "run":
            // Only the entry number: a second operand is not part of the grammar.
            return operands.isEmpty ? [cronEntryNumberHint] : []
        case "mailto":
            return operands.isEmpty ? cronMailToSuggestions(prefix: prefix) : []
        default:
            // `list`, and anything the dispatcher does not know, takes no operand.
            return []
        }
    }

    // MARK: - add

    /// `/cron add [-json] [-agent <name>] <schedule> [-f <path>] <prompt>`:
    /// the schedule is either one `@alias` or five fields, so the meaning of a
    /// slot depends on the first operand after the optional `-json` and
    /// `-agent` options.
    private static func cronAddSuggestions(
        precedingOperands: [String],
        prefix: String
    ) -> [TerminalCommandSuggestion] {
        var operands = precedingOperands
        if operands.isEmpty {
            return cronScheduleSuggestions(prefix: prefix, offersJSON: true, offersAgent: true)
        }
        // The option is not part of the schedule: drop it and complete what
        // follows as for a text job, without offering it a second time. Exact
        // and case-sensitive, like the parser: `JSON` is already the schedule.
        if operands[0] == cronJSONOption {
            operands.removeFirst()
        }
        // Neither is `-agent <name>`: drop both, without offering the option
        // a second time. Until the name is typed (and its quote closed), the
        // slot is the name.
        var offersAgent = true
        if operands.first == cronAgentOption {
            guard let nameLength = cronValueWordCount(operands.dropFirst()) else {
                return [cronAgentNameHint]
            }
            operands.removeFirst(1 + nameLength)
            offersAgent = false
        }
        guard let schedule = operands.first else {
            return cronScheduleSuggestions(prefix: prefix, offersJSON: false, offersAgent: offersAgent)
        }
        // An alias is the whole schedule; five fields, one slot each, are the
        // other. The slot index inside a schedule is the field index.
        let scheduleLength = schedule.hasPrefix("@") ? 1 : cronFieldHints.count
        guard operands.count >= scheduleLength else {
            return [cronFieldHints[operands.count]]
        }

        // After the schedule: `-f <path>` or the prompt. Words are split on
        // whitespace, so a quoted path with spaces spans several slots; that
        // only changes which guide is shown for the slots after its first word.
        let afterSchedule = operands.dropFirst(scheduleLength)
        guard let option = afterSchedule.first else {
            return cronPromptFileOrPromptSuggestions(prefix: prefix)
        }
        guard option == cronPromptFileOption else {
            return [cronPromptHint]
        }
        return afterSchedule.count == 1 ? [cronPromptFilePathHint] : [cronPromptFileInstructionHint]
    }

    /// Words taken by the value that starts `words`: one, or, when it opens
    /// with a quote, every word up to the one that closes it. `nil` while
    /// there is no value yet or its quote is still open.
    private static func cronValueWordCount(_ words: ArraySlice<String>) -> Int? {
        guard let first = words.first else { return nil }
        guard let quote = first.first, quote == "'" || quote == "\"" else { return 1 }
        if first.count > 1, first.last == quote { return 1 }
        for (offset, word) in words.dropFirst().enumerated() where word.last == quote {
            return offset + 2
        }
        return nil
    }

    /// The first slot after the schedule. An empty prefix lists the `<prompt>`
    /// guide first, so the initial selection is a row that does nothing (like
    /// `mailto`), then `-f`. A prefix of `-f` completes the option; anything
    /// else, `-F` included, is the start of the prompt.
    private static func cronPromptFileOrPromptSuggestions(
        prefix: String
    ) -> [TerminalCommandSuggestion] {
        if prefix.isEmpty {
            return [cronPromptHint, cronPromptFileValue]
        }
        if prefix.hasPrefix("-"), cronPromptFileOption.hasPrefix(prefix) {
            return [cronPromptFileValue]
        }
        return [cronPromptHint]
    }

    /// First operand of `add` (or the one after `-json` or `-agent <name>`).
    ///
    /// An empty prefix lists the aliases and a few complete five-field
    /// examples, then `-json` when `offersJSON` and `-agent` when
    /// `offersAgent`: they come last so the initial selection stays on the
    /// first alias. A prefix that starts with `-` completes the options it is a
    /// prefix of, `-json` first (`-` offers both, `-j` only `-json`, `-a` only
    /// `-agent`), case-sensitively. When it is a prefix of neither (`-J`,
    /// `--a`), it is treated like any other text. A hand-written schedule
    /// gets no examples: they would hijack it, since Tab and Enter replace the
    /// whole token. It gets the guide of its first field instead.
    private static func cronScheduleSuggestions(
        prefix: String,
        offersJSON: Bool,
        offersAgent: Bool
    ) -> [TerminalCommandSuggestion] {
        if prefix.isEmpty {
            return cronScheduleAliases + cronScheduleExamples
                + (offersJSON ? [cronJSONValue] : [])
                + (offersAgent ? [cronAgentValue] : [])
        }
        if prefix.hasPrefix("-") {
            let options = (offersJSON && cronJSONOption.hasPrefix(prefix) ? [cronJSONValue] : [])
                + (offersAgent && cronAgentOption.hasPrefix(prefix) ? [cronAgentValue] : [])
            if !options.isEmpty {
                return options
            }
        }
        guard prefix.hasPrefix("@") else {
            return [cronFieldHints[0]]
        }

        // `ZenCronSchedule` accepts aliases case-insensitively, so match so.
        let typed = prefix.lowercased()
        // `@annually` and `@midnight` are plain synonyms: they would only
        // crowd the six-row menu, so they appear once the user typed
        // something beyond the bare `@`, e.g. `@mid`.
        let candidates = cronScheduleAliases + (typed.count > 1 ? cronScheduleAliasSynonyms : [])
        let matches = candidates.filter { $0.command.hasPrefix(typed) }
        let exactMatches = matches.filter { $0.command == typed }
        return exactMatches + matches.filter { $0.command != typed }
    }

    // MARK: - mailto

    /// `/cron mailto [address|none|default]`.
    ///
    /// The guide comes first, so the initial selection of `/cron mailto ` is a
    /// row that does nothing: Enter then shows the current value instead of
    /// silently picking `none` and disabling the mail. While the typed prefix
    /// matches no keyword it is an address being typed, so the guide stays.
    private static func cronMailToSuggestions(prefix: String) -> [TerminalCommandSuggestion] {
        let typed = prefix.lowercased()
        guard !typed.isEmpty else {
            return [cronMailToAddressHint] + cronMailToKeywords
        }
        let keywords = cronMailToKeywords.filter { $0.command.hasPrefix(typed) }
        return keywords.isEmpty ? [cronMailToAddressHint] : keywords
    }

    // MARK: - Vocabulary

    private static let cronScheduleAliases: [TerminalCommandSuggestion] = [
        cronValue("@hourly", "every hour, at minute 0"),
        cronValue("@daily", "every day at midnight"),
        cronValue("@weekly", "every Sunday at midnight"),
        cronValue("@monthly", "on the 1st of each month at midnight"),
        cronValue("@yearly", "every 1 January at midnight"),
        cronValue("@reboot", "when the system starts")
    ]

    private static let cronScheduleAliasSynonyms: [TerminalCommandSuggestion] = [
        cronValue("@annually", "same as @yearly"),
        cronValue("@midnight", "same as @daily")
    ]

    /// The option `/cron add` takes before the schedule; the handler owns it.
    private static let cronJSONOption = TerminalChat.cronJSONOption

    private static let cronJSONValue = cronValue(
        cronJSONOption,
        "mail the run as JSONL records instead of the answer text"
    )

    /// The option before the schedule that names the agent profile; the
    /// handler owns it.
    private static let cronAgentOption = TerminalChat.cronAgentOption

    private static let cronAgentValue = cronValue(
        cronAgentOption,
        "agent profile the job runs with; default: Developer"
    )

    private static let cronAgentNameHint = cronHint(
        "<agent>",
        "profile name or ID; quote it if it contains spaces"
    )

    /// The option right after the schedule that reads the prompt from a file;
    /// the handler owns it.
    private static let cronPromptFileOption = TerminalChat.cronPromptFileOption

    private static let cronPromptFileValue = cronValue(
        cronPromptFileOption,
        "read the prompt from a file (absolute path)"
    )

    /// Complete five-field schedules, inserted as one token run. Each one must
    /// pass `ZenCronSchedule(parsing:)`; a test enforces it.
    static let cronScheduleExamples: [TerminalCommandSuggestion] = [
        cronValue("0 9 * * 1-5", "weekdays at 09:00"),
        cronValue("*/15 * * * *", "every 15 minutes"),
        cronValue("30 18 * * *", "every day at 18:30")
    ]

    /// Guides of the five schedule fields, in order. Ranges follow
    /// `ZenCronSchedule`, which takes numbers only: month and day-of-week have
    /// no names, so their guides list numbers and nothing else.
    private static let cronFieldHints: [TerminalCommandSuggestion] = [
        cronHint("<minute>", "0-59, */n, a-b or a,b"),
        cronHint("<hour>", "0-23"),
        cronHint("<day-of-month>", "1-31"),
        cronHint("<month>", "1-12"),
        cronHint("<day-of-week>", "0-7 (0 and 7 = Sunday)")
    ]

    private static let cronPromptHint = cronHint(
        "<prompt>",
        "text the agent runs headless, on one line"
    )

    private static let cronPromptFilePathHint = cronHint(
        "<path>",
        "absolute path of the prompt file; quote it if it contains spaces"
    )

    private static let cronPromptFileInstructionHint = cronHint(
        "<prompt>",
        "optional instruction; the file becomes context"
    )

    private static let cronEntryNumberHint = cronHint("<n>", "entry number shown by /cron list")

    private static let cronMailToAddressHint = cronHint(
        "<address>",
        "e-mail address cron mails results to"
    )

    private static let cronMailToKeywords: [TerminalCommandSuggestion] = [
        TerminalCommandSuggestion(command: "none", summary: "disable mail for scheduled prompts"),
        TerminalCommandSuggestion(
            command: "default",
            summary: "cron default: local mailbox of the crontab owner"
        )
    ]

    /// A value that is typed as is and still needs the prompt after it, so
    /// accepting it leaves a separator instead of sending the line.
    private static func cronValue(_ command: String, _ summary: String) -> TerminalCommandSuggestion {
        TerminalCommandSuggestion(command: command, summary: summary, requiresArgument: true)
    }

    private static func cronHint(_ command: String, _ summary: String) -> TerminalCommandSuggestion {
        TerminalCommandSuggestion(command: command, summary: summary, isHint: true)
    }
}
