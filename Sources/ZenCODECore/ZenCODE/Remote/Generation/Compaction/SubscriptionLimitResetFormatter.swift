//
//  SubscriptionLimitResetFormatter.swift
//  ZenCODE
//
//  Builds a human-readable "subscription resumes at <time>" message from a
//  rate-limit reset value (seconds-until-reset, an absolute date, or a
//  `retry-after` header value). The message reports the precise local time.
//

import Foundation
import Synchronization

public enum SubscriptionLimitResetFormatter {
    /// Resolves a reset `Date` from a value that may be a relative seconds count
    /// or an absolute unix timestamp. Values above this threshold are treated as
    /// absolute unix timestamps (seconds since 1970); smaller, non-negative values
    /// are interpreted as seconds-until-reset and resolved to the absolute instant
    /// `now + value`. A `Date` is a timezone-independent instant, so this sum does
    /// not depend on any calendar or time zone.
    static let absoluteTimestampThreshold: Double = 1_000_000_000

    public static func resetDate(
        fromSecondsValue value: Double,
        now: Date = Date()
    ) -> Date? {
        guard value.isFinite else {
            return nil
        }
        if value > absoluteTimestampThreshold {
            return Date(timeIntervalSince1970: value)
        }
        guard value >= 0 else {
            return nil
        }
        return now.addingTimeInterval(value)
    }

    /// Parses a `retry-after` header value, which may be either a number of
    /// seconds or an HTTP date, into an absolute reset `Date`.
    public static func resetDate(
        fromRetryAfterHeader value: String,
        now: Date = Date()
    ) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if let seconds = Double(trimmed) {
            return resetDate(fromSecondsValue: seconds, now: now)
        }
        if let date = httpDateFormatter.withLock({ $0.date(from: trimmed) }) {
            return date
        }
        if let date = try? Date(trimmed, strategy: .iso8601) {
            return date
        }
        return nil
    }

    /// Formats the absolute reset instant as a local wall-clock time.
    ///
    /// `resetDate` is an absolute instant (typically `now + relative seconds`, or
    /// an absolute unix timestamp). It is rendered in the time zone carried by
    /// `calendar` — the same `calendar` used to decide whether the reset falls on
    /// the same day as `now` — so the displayed time and the day comparison always
    /// agree. The date is included only when the reset is not on `now`'s day.
    ///
    /// Formatting uses an explicit `HH` pattern rather than `Date.FormatStyle`'s
    /// `.twoDigits(amPM: .omitted)` hour symbol. On Linux's corelibs-foundation
    /// that symbol does not force a 24-hour cycle: the hour cycle is inherited
    /// from the locale, so a 12-hour locale renders 14:30 as "02:30". The fixed
    /// `HH` pattern is 24-hour on every platform.
    public static func resumeTimeText(
        for resetDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(resetDate, inSameDayAs: now) {
            return formatLocal(resetDate, pattern: "HH:mm", timeZone: calendar.timeZone)
        } else {
            return formatLocal(resetDate, pattern: "dd/MM HH:mm", timeZone: calendar.timeZone)
        }
    }

    /// Renders `resetDate` with a fixed pattern in the given time zone. Uses the
    /// `en_US_POSIX` locale so the digits and separators are stable regardless of
    /// the process locale. `DateFormatter` is not Sendable, so access is
    /// serialized through `localDateFormatter`.
    static func formatLocal(
        _ date: Date,
        pattern: String,
        timeZone: TimeZone
    ) -> String {
        localDateFormatter.withLock { formatter in
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = pattern
            return formatter.string(from: date)
        }
    }

    /// Mutable, non-Sendable formatter reused across calls; access is serialized.
    static let localDateFormatter = Mutex<DateFormatter>(DateFormatter())

    /// Builds the full Italian message announcing when the subscription resumes.
    public static func limitReachedMessage(
        provider: String,
        resetDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        let timeText = resumeTimeText(for: resetDate, now: now, calendar: calendar)
        return "Limite \(provider) raggiunto: la sottoscrizione riparte alle \(timeText)."
    }

    /// RFC 7231 HTTP-date has no Foundation value-type parse strategy. Keep
    /// the reference formatter private and serialize its non-Sendable use.
    static let httpDateFormatter = Mutex<DateFormatter>({
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .gmt
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }())
}
