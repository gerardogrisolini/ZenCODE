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
/// Rows are either values (aliases, examples, `none`, `default`) or guides
/// (`isHint`): `<minute>`, `<prompt>`, … name what the slot expects and are
/// never inserted. The subcommand is matched case-insensitively, like the
/// dispatcher, so `/cron ADD ` behaves as `/cron add `.
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

    /// `/cron add <schedule> <prompt>`: the schedule is either one `@alias` or
    /// five fields, so the meaning of a slot depends on the first operand.
    private static func cronAddSuggestions(
        precedingOperands operands: [String],
        prefix: String
    ) -> [TerminalCommandSuggestion] {
        guard let schedule = operands.first else {
            return cronScheduleSuggestions(prefix: prefix)
        }
        // An alias is the whole schedule; the prompt starts right after it.
        guard !schedule.hasPrefix("@") else {
            return [cronPromptHint]
        }
        // Five fields, then the prompt. The slot index is the field index.
        guard operands.count < cronFieldHints.count else {
            return [cronPromptHint]
        }
        return [cronFieldHints[operands.count]]
    }

    /// First operand of `add`.
    ///
    /// An empty prefix lists the aliases and a few complete five-field
    /// examples. A hand-written schedule gets no examples: they would hijack
    /// it, since Tab and Enter replace the whole token. It gets the guide of
    /// its first field instead.
    private static func cronScheduleSuggestions(prefix: String) -> [TerminalCommandSuggestion] {
        if prefix.isEmpty {
            return cronScheduleAliases + cronScheduleExamples
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
