//
//  ZenCrontabDocument.swift
//  ZenCODE
//

import Foundation

/// One scheduled prompt found in the ZenCODE block of a crontab.
struct ZenCronEntry: Sendable, Equatable {
    let id: UUID
    let createdAt: Date
    /// The schedule tokens (an `@alias` or five fields) joined by single spaces.
    let schedule: String
    /// Everything after the schedule on the cron line, `%` still escaped as `\%`.
    let cronCommand: String
    /// `cronCommand` decoded back to a job, or `nil` when it was not written by
    /// ZenCODE (or was hand-edited into a different shape).
    let job: ZenCronJobCommand?
    /// The original `# zencode-cron …` line, re-emitted verbatim by `render()`.
    let markerLine: String
    /// The original cron line, re-emitted verbatim by `render()`.
    let cronLine: String

    init(
        id: UUID,
        createdAt: Date,
        schedule: String,
        cronCommand: String,
        markerLine: String,
        cronLine: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.schedule = schedule
        self.cronCommand = cronCommand
        self.job = ZenCronJobCommand.cronUnescape(cronCommand).flatMap(ZenCronJobCommand.decode)
        self.markerLine = markerLine
        self.cronLine = cronLine
    }
}

/// A pure model of a user's crontab text: the foreign lines (never touched)
/// plus the single block owned by ZenCODE. Parsing and rendering perform no I/O.
///
/// Invariants:
/// - Foreign lines are preserved verbatim and in order; the ZenCODE block is
///   always rendered last.
/// - Entries keep their original marker and cron lines when rendered, so a
///   hand-tuned line is never silently re-encoded.
/// - `parse(render(doc))` equals `doc` for any parsed document.
struct ZenCrontabDocument: Sendable, Equatable {
    /// The ZenCODE block: a header (`PATH=`, then an optional `MAILTO=`) followed
    /// by the scheduled prompts.
    struct Block: Sendable, Equatable {
        /// The block's `PATH=` value, verbatim. `nil` means the default
        /// (`ZenCrontabDocument.defaultPath`): a block is always rendered with a
        /// `PATH=` line, and a line equal to the default is read back as `nil`.
        var path: String?
        /// `nil` means no `MAILTO` line; `""` renders `MAILTO=""`.
        var mailTo: String?
        var items: [Item]

        init(path: String? = nil, mailTo: String? = nil, items: [Item] = []) {
            self.path = path
            self.mailTo = mailTo
            self.items = items
        }

        /// The `PATH` cron gives to the block's jobs: the block's value (or the
        /// default) without one pair of surrounding double quotes, which cron
        /// also strips.
        var effectivePath: String {
            ZenCrontabDocument.stripOuterDoubleQuotes(path ?? ZenCrontabDocument.defaultPath)
        }
    }

    enum Item: Sendable, Equatable {
        case entry(ZenCronEntry)
        /// A non-empty line inside the block that is not a well-formed entry,
        /// preserved verbatim.
        case unrecognized(String)
    }

    static let beginMarker = "# >>> ZenCODE cron >>>"
    static let endMarker = "# <<< ZenCODE cron <<<"

    /// The `PATH` written at the head of the block. Cron gives its jobs only
    /// `/usr/bin:/bin`, so this adds `/usr/local/bin`, where `Scripts/install.sh`
    /// installs `zen`. The block is always the tail of the crontab, so the
    /// assignment only affects ZenCODE's entries.
    static let defaultPath = "/usr/local/bin:/usr/bin:/bin"

    private static let markerPrefix = "# zencode-cron "
    private static let pathPrefix = "PATH="
    private static let mailToPrefix = "MAILTO="

    /// Every line outside the ZenCODE block, in original order. When a block
    /// is present, one blank line ending this list after a non-blank line is
    /// the separator `render()` inserts, so `parse` does not report it here.
    var foreignLines: [String]
    var block: Block?

    init(foreignLines: [String] = [], block: Block? = nil) {
        self.foreignLines = foreignLines
        self.block = block
    }

    /// The `PATH` cron gives to ZenCODE's entries: the block's (see
    /// `Block.effectivePath`) or, without a block, the default one. This is
    /// where `zen` must be installed for a scheduled prompt to run.
    var effectivePath: String {
        (block ?? Block()).effectivePath
    }

    // MARK: - Parsing

    /// Parses crontab text. Throws `ZenCrontabError.malformedBlock` when the
    /// ZenCODE block has no end marker or when more than one block is present.
    static func parse(_ text: String) throws -> ZenCrontabDocument {
        let lines = splitLines(text)

        var beforeBlock: [String] = []
        var afterBlock: [String] = []
        var body: [String] = []
        var state = ParseState.beforeBlock

        for line in lines {
            switch state {
            case .beforeBlock:
                if line == beginMarker {
                    state = .insideBlock
                } else {
                    beforeBlock.append(line)
                }
            case .insideBlock:
                if line == beginMarker {
                    throw ZenCrontabError.malformedBlock(
                        reason: "found a second '\(beginMarker)' before the end marker"
                    )
                } else if line == endMarker {
                    state = .afterBlock
                } else {
                    body.append(line)
                }
            case .afterBlock:
                if line == beginMarker {
                    throw ZenCrontabError.malformedBlock(
                        reason: "found more than one ZenCODE block"
                    )
                }
                afterBlock.append(line)
            }
        }

        switch state {
        case .beforeBlock:
            return ZenCrontabDocument(foreignLines: lines, block: nil)
        case .insideBlock:
            throw ZenCrontabError.malformedBlock(
                reason: "'\(beginMarker)' has no matching '\(endMarker)'"
            )
        case .afterBlock:
            let parsedBlock = parseBlock(body)
            var foreignLines = beforeBlock + afterBlock
            // `render()` re-inserts one blank separator before a non-empty block
            // whenever the last foreign line is not blank. Drop exactly that
            // shape from the tail so rendering and parsing stay inverse.
            if parsedBlock != nil,
               foreignLines.count >= 2,
               foreignLines[foreignLines.count - 1].isEmpty,
               !foreignLines[foreignLines.count - 2].isEmpty {
                foreignLines.removeLast()
            }
            return ZenCrontabDocument(foreignLines: foreignLines, block: parsedBlock)
        }
    }

    private enum ParseState {
        case beforeBlock
        case insideBlock
        case afterBlock
    }

    /// Returns `nil` for a block without `MAILTO` and items: it renders as
    /// nothing, so it is read back as no block at all, whatever its `PATH`.
    ///
    /// The header is the run of non-blank lines before the first entry or the
    /// first unrecognized line. It may hold `PATH=` and `MAILTO=` in any order,
    /// each at most once: a repeat is an unrecognized line, and ends the header.
    private static func parseBlock(_ body: [String]) -> Block? {
        var path: String?
        var mailTo: String?
        var items: [Item] = []
        var index = 0
        var isInHeader = true
        var hasPathLine = false
        var hasMailToLine = false

        while index < body.count {
            let line = body[index]
            if isBlank(line) {
                index += 1
                continue
            }

            if isInHeader {
                if line.hasPrefix(pathPrefix), !hasPathLine {
                    hasPathLine = true
                    let value = String(line.dropFirst(pathPrefix.count))
                    path = value == defaultPath ? nil : value
                    index += 1
                    continue
                }
                if line.hasPrefix(mailToPrefix), !hasMailToLine {
                    hasMailToLine = true
                    mailTo = stripOuterDoubleQuotes(String(line.dropFirst(mailToPrefix.count)))
                    index += 1
                    continue
                }
                isInHeader = false
            }

            if let marker = parseMarker(line),
               index + 1 < body.count,
               let cron = splitCronLine(body[index + 1]) {
                items.append(
                    .entry(
                        ZenCronEntry(
                            id: marker.id,
                            createdAt: marker.createdAt,
                            schedule: cron.schedule,
                            cronCommand: cron.command,
                            markerLine: line,
                            cronLine: body[index + 1]
                        )
                    )
                )
                index += 2
                continue
            }

            items.append(.unrecognized(line))
            index += 1
        }

        return mailTo == nil && items.isEmpty ? nil : Block(path: path, mailTo: mailTo, items: items)
    }

    /// Parses `# zencode-cron id=<UUID> created=<ISO8601>` (single spaces).
    private static func parseMarker(_ line: String) -> (id: UUID, createdAt: Date)? {
        guard line.hasPrefix(markerPrefix) else { return nil }
        let parts = line.split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0] == "#",
              parts[1] == "zencode-cron",
              parts[2].hasPrefix("id="),
              parts[3].hasPrefix("created="),
              let id = UUID(uuidString: String(parts[2].dropFirst("id=".count))),
              let createdAt = parseDate(String(parts[3].dropFirst("created=".count)))
        else { return nil }
        return (id, createdAt)
    }

    /// Splits a cron line into its schedule tokens and the remaining command.
    /// Returns `nil` for empty lines, comments, and lines without a command.
    private static func splitCronLine(_ line: String) -> (schedule: String, command: String)? {
        let scalars = Array(line.unicodeScalars)
        var position = 0

        func skipBlanks() {
            while position < scalars.count, isCronBlank(scalars[position]) {
                position += 1
            }
        }

        skipBlanks()
        guard position < scalars.count, scalars[position] != "#" else { return nil }

        let tokenCount = scalars[position] == "@" ? 1 : 5
        var tokens: [String] = []
        for tokenIndex in 0..<tokenCount {
            skipBlanks()
            guard position < scalars.count else { return nil }
            let start = position
            while position < scalars.count, !isCronBlank(scalars[position]) {
                position += 1
            }
            tokens.append(String(String.UnicodeScalarView(scalars[start..<position])))
            if tokenIndex == tokenCount - 1 { break }
        }

        skipBlanks()
        var end = scalars.count
        while end > position, isCronBlank(scalars[end - 1]) || scalars[end - 1] == "\r" {
            end -= 1
        }
        guard end > position else { return nil }

        return (
            tokens.joined(separator: " "),
            String(String.UnicodeScalarView(scalars[position..<end]))
        )
    }

    private static func isCronBlank(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t"
    }

    private static func isBlank(_ line: String) -> Bool {
        line.unicodeScalars.allSatisfy { isCronBlank($0) || $0 == "\r" }
    }

    /// Removes one pair of surrounding double quotes, as cron does for the
    /// value of an environment assignment.
    private static func stripOuterDoubleQuotes(_ value: String) -> String {
        if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    /// Splits on `\n` only (on scalars, so a `\r` stays at the end of its line
    /// and re-renders byte-identically). The empty tail after a final newline
    /// is not a line.
    private static func splitLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        if !current.isEmpty {
            lines.append(String(current))
        }
        return lines
    }

    private static func makeDateFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .gmt
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    private static func parseDate(_ text: String) -> Date? {
        makeDateFormatter(fractionalSeconds: false).date(from: text)
            ?? makeDateFormatter(fractionalSeconds: true).date(from: text)
    }

    // MARK: - Rendering

    /// Renders the full crontab text: foreign lines verbatim, then (only when
    /// it has a `MAILTO` or items) the ZenCODE block, whose header is always a
    /// `PATH=` line followed by the optional `MAILTO=`. A non-empty result ends
    /// with a newline.
    func render() -> String {
        var lines = foreignLines

        if let block, block.mailTo != nil || !block.items.isEmpty {
            if let last = lines.last, !last.isEmpty {
                lines.append("")
            }
            lines.append(Self.beginMarker)
            lines.append(Self.pathPrefix + (block.path ?? Self.defaultPath))
            if let mailTo = block.mailTo {
                lines.append(Self.mailToLine(for: mailTo))
            }
            for item in block.items {
                switch item {
                case let .entry(entry):
                    lines.append(entry.markerLine)
                    lines.append(entry.cronLine)
                case let .unrecognized(line):
                    lines.append(line)
                }
            }
            lines.append(Self.endMarker)
        }

        return lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
    }

    /// `MAILTO=<v>`; values that would not survive `parse` unquoted (empty, or
    /// wrapped in double quotes) are written inside double quotes.
    private static func mailToLine(for value: String) -> String {
        let needsQuotes = value.isEmpty || (value.count >= 2 && value.hasPrefix("\"") && value.hasSuffix("\""))
        return needsQuotes ? "\(mailToPrefix)\"\(value)\"" : "\(mailToPrefix)\(value)"
    }

    // MARK: - Mutation

    /// Appends a new scheduled prompt, creating the block when absent.
    ///
    /// The caller must have validated that `job.prompt` and `job.promptFile`
    /// are single lines; this method does not reject line breaks.
    mutating func appendEntry(
        schedule: ZenCronSchedule,
        job: ZenCronJobCommand,
        id: UUID = UUID(),
        createdAt: Date = .now
    ) {
        let timestamp = Self.makeDateFormatter(fractionalSeconds: false).string(from: createdAt)
        let cronCommand = ZenCronJobCommand.cronEscape(job.encode())
        let entry = ZenCronEntry(
            id: id,
            // Keep exactly what the marker records so a re-parse compares equal.
            createdAt: Self.parseDate(timestamp) ?? createdAt,
            schedule: schedule.rawValue,
            cronCommand: cronCommand,
            markerLine: "\(Self.markerPrefix)id=\(id.uuidString) created=\(timestamp)",
            cronLine: "\(schedule.rawValue) \(cronCommand)"
        )
        var current = block ?? Block()
        current.items.append(.entry(entry))
        block = current
    }

    /// Removes the item at the 1-based `number` (entries and unrecognized lines
    /// are both numbered). Throws `ZenCrontabError.noSuchEntry` when out of range.
    mutating func removeItem(number: Int) throws {
        guard var current = block, number >= 1, number <= current.items.count else {
            throw ZenCrontabError.noSuchEntry(number)
        }
        current.items.remove(at: number - 1)
        block = current
        dropBlockIfEmpty()
    }

    /// Sets (`""` disables mail) or clears (`nil`) the block's `MAILTO` line.
    ///
    /// The caller must have validated `value`; this method does not.
    mutating func setMailTo(_ value: String?) {
        var current = block ?? Block()
        current.mailTo = value
        block = current
        dropBlockIfEmpty()
    }

    /// A block with neither `MAILTO` nor items renders nothing (even with a
    /// custom `PATH`), and `parse` would read it back as no block at all; keep
    /// both views identical.
    private mutating func dropBlockIfEmpty() {
        if let block, block.mailTo == nil, block.items.isEmpty {
            self.block = nil
        }
    }
}
