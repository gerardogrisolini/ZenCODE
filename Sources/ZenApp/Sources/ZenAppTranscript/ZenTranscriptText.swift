//
//  ZenTranscriptText.swift
//  ZenApp
//
//  Pure text helpers shared by the transcript views: bounding, single-line
//  sanitizing, path abbreviation, origin badges, and slash-command tokens.
//

import Foundation
import ZenCODECore

/// A text cut to a maximum number of lines, with the count of the lines left out.
public struct ZenBoundedLines: Sendable, Equatable {
    /// The kept lines, each cut to the line-length limit.
    public let lines: [String]
    /// The lines after the kept ones that are not shown.
    public let hiddenLineCount: Int

    public init(lines: [String], hiddenLineCount: Int) {
        self.lines = lines
        self.hiddenLineCount = hiddenLineCount
    }

    /// Whether some lines were left out.
    public var isTruncated: Bool {
        hiddenLineCount > 0
    }

    /// The kept lines joined with newlines.
    public var text: String {
        lines.joined(separator: "\n")
    }
}

/// The badge a prompt shows for the channel it came from.
public struct ZenOriginBadge: Sendable, Equatable {
    /// The channel's name, such as `Telegram`.
    public let title: String
    /// The SF Symbol of the channel.
    public let systemImage: String

    public init(title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }
}

/// A typed slash command split into its `/command` token and its arguments.
public struct ZenCommandToken: Sendable, Equatable {
    /// The command token with its slash, such as `/tasks`.
    public let command: String
    /// The text after the token, without the separating whitespace.
    public let arguments: String

    public init(command: String, arguments: String) {
        self.command = command
        self.arguments = arguments
    }
}

/// Pure text helpers of the transcript views.
public enum ZenTranscriptText {
    /// Characters of a long body text (an assistant block, a notice, a
    /// prompt) rendered in one `Text`.
    public static let longTextLimit = 40_000
    /// Characters of a single inline value (a target, a parameter, a title).
    public static let inlineLimit = 500

    /// `text` cut to `limit` characters, with an ellipsis and the count of the
    /// characters left out when it is longer.
    public static func bounded(_ text: String, limit: Int) -> String {
        guard limit > 0 else { return "" }
        // `utf8.count` is O(1) for native strings and bounds the character count.
        guard text.utf8.count > limit else { return text }
        let end = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex) ?? text.endIndex
        guard end < text.endIndex else { return text }
        let hidden = text.distance(from: end, to: text.endIndex)
        return "\(text[..<end])… (\(hidden) more characters)"
    }

    /// `text` on one line: control and bidi characters become spaces, runs of
    /// whitespace collapse to one space, the ends are trimmed, and the result
    /// is cut to `limit` characters with an ellipsis. `nil` when nothing
    /// visible remains.
    public static func inline(_ text: String, limit: Int = inlineLimit) -> String? {
        var output = ""
        output.reserveCapacity(min(text.utf8.count, limit + 1))
        var count = 0
        var pendingSpace = false
        for character in text {
            let isSeparator = character.isWhitespace || character.unicodeScalars.contains { scalar in
                CharacterSet.controlCharacters.contains(scalar)
                    || scalar.properties.isBidiControl
                    || scalar.properties.isJoinControl
            }
            if isSeparator {
                pendingSpace = !output.isEmpty
                continue
            }
            if pendingSpace {
                output.append(" ")
                count += 1
                pendingSpace = false
            }
            guard count < limit else {
                return output.trimmingCharacters(in: .whitespaces) + "…"
            }
            output.append(character)
            count += 1
        }
        return output.isEmpty ? nil : output
    }

    /// The first `maxLines` lines of `text`, each cut to `maxLineLength`
    /// characters, and the number of further lines. A trailing line break
    /// does not count as an empty last line; CRLF counts as one break.
    public static func boundedLines(
        _ text: String,
        maxLines: Int,
        maxLineLength: Int = 1_000
    ) -> ZenBoundedLines {
        var lines: [String] = []
        var remaining = 0
        var index = text.startIndex
        while index < text.endIndex {
            let lineEnd = text[index...].firstIndex(where: \.isNewline) ?? text.endIndex
            if lines.count < maxLines {
                let line = text[index..<lineEnd]
                lines.append(line.count > maxLineLength
                    ? String(line.prefix(maxLineLength)) + "…"
                    : String(line))
            } else {
                remaining += 1
            }
            guard lineEnd < text.endIndex else { break }
            index = text.index(after: lineEnd)
        }
        return ZenBoundedLines(lines: lines, hiddenLineCount: remaining)
    }

    /// `path` with the home directory replaced by `~`.
    public static func abbreviatedPath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let home = homeDirectory.hasSuffix("/") && homeDirectory.count > 1
            ? String(homeDirectory.dropLast())
            : homeDirectory
        guard !home.isEmpty, home != "/" else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    /// The badge of a prompt's origin, or `nil` for a prompt typed in the app.
    public static func originBadge(for origin: ChatTurnOrigin) -> ZenOriginBadge? {
        switch origin {
        case .app:
            nil
        case .local:
            ZenOriginBadge(title: "Terminal", systemImage: "terminal")
        case .acp:
            ZenOriginBadge(title: "ACP", systemImage: "chevron.left.forwardslash.chevron.right")
        case .headless:
            ZenOriginBadge(title: "Headless", systemImage: "gearshape")
        case .telegram:
            ZenOriginBadge(title: "Telegram", systemImage: "paperplane")
        case .unknown:
            ZenOriginBadge(title: "Restored", systemImage: "clock.arrow.circlepath")
        @unknown default:
            // A channel newer than the app.
            ZenOriginBadge(title: "Other", systemImage: "bubble.left.and.bubble.right")
        }
    }

    /// The `/command` token of a typed command line and its arguments, or
    /// `nil` when the line does not start with a slash command.
    public static func commandToken(in line: String) -> ZenCommandToken? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return nil }
        let tokenEnd = trimmed.firstIndex(where: \.isWhitespace) ?? trimmed.endIndex
        let command = String(trimmed[..<tokenEnd])
        let arguments = trimmed[tokenEnd...].trimmingCharacters(in: .whitespacesAndNewlines)
        return ZenCommandToken(command: command, arguments: arguments)
    }

    /// The first non-blank line of `text` on one line, for collapsed previews.
    public static func firstLinePreview(_ text: String, limit: Int = 160) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            if let preview = inline(String(line), limit: limit) {
                return preview
            }
        }
        return nil
    }

    /// `text` without the line breaks a text channel writes at its end.
    static func trimmingTrailingNewlines(_ text: String) -> String {
        var end = text.endIndex
        while end > text.startIndex {
            let previous = text.index(before: end)
            guard text[previous].isNewline else { break }
            end = previous
        }
        return String(text[..<end])
    }

    /// `value` when it has visible characters, otherwise `nil`.
    static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return value
    }
}
