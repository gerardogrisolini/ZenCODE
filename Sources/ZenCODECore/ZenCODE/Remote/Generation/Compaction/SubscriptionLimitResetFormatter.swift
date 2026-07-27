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
    /// absolute unix timestamps (seconds since 1970).
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

    /// Formats the absolute local time at which the subscription becomes
    /// available again. Includes the date when the reset is not today.
    public static func resumeTimeText(
        for resetDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String {
        if calendar.isDate(resetDate, inSameDayAs: now) {
            return resetDate.formatted(
                .dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            )
        } else {
            return resetDate.formatted(
                .dateTime.day(.twoDigits).month(.twoDigits)
                    .hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)
            )
        }
    }

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
