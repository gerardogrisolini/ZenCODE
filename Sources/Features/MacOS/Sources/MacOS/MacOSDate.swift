import Foundation

/// Date parsing and formatting shared by every app controller. Inputs accept
/// ISO 8601 (with or without seconds, fractional seconds, or UTC offset),
/// `yyyy-MM-dd HH:mm[:ss]`, plain `yyyy-MM-dd`, and the tokens `now`,
/// `today`, `tomorrow`, `yesterday`. Values without an explicit offset are
/// interpreted in the user's local time zone. Outputs always carry the local
/// UTC offset so the model can reason about the user's day.
enum MacOSDate {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    private static let dateOnlyPattern = #"^\d{4}-\d{2}-\d{2}$"#

    /// Forms that carry their own UTC offset (`XXXXX` accepts `Z`, `+02:00`,
    /// and `+0200`); the seconds-less ones are not covered by
    /// `ISO8601DateFormatter`.
    private static let offsetFormats = [
        "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
        "yyyy-MM-dd'T'HH:mm:ssXXXXX",
        "yyyy-MM-dd'T'HH:mmXXXXX",
        "yyyy-MM-dd HH:mm:ss.SSSXXXXX",
        "yyyy-MM-dd HH:mm:ssXXXXX",
        "yyyy-MM-dd HH:mmXXXXX",
    ]

    /// Forms without an offset, read as local wall-clock time.
    private static let localFormats = [
        "yyyy-MM-dd'T'HH:mm:ss.SSS",
        "yyyy-MM-dd'T'HH:mm:ss",
        "yyyy-MM-dd'T'HH:mm",
        "yyyy-MM-dd HH:mm:ss.SSS",
        "yyyy-MM-dd HH:mm:ss",
        "yyyy-MM-dd HH:mm",
        "yyyy-MM-dd",
    ]

    static func parse(_ raw: String) -> Date? {
        parse(raw, now: Date(), timeZone: .current)
    }

    /// `now` and `timeZone` are injectable so the relative tokens and the
    /// local forms can be verified deterministically.
    static func parse(_ raw: String, now: Date, timeZone: TimeZone) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        var calendar = Calendar.current
        calendar.timeZone = timeZone
        switch value.lowercased() {
        case "now":
            return now
        case "today":
            return calendar.startOfDay(for: now)
        case "tomorrow":
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        case "yesterday":
            return calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now))
        default:
            break
        }

        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime]] {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = options
            if let date = iso.date(from: value) {
                return date
            }
        }
        for format in offsetFormats {
            if let date = formatter(format, timeZone: timeZone).date(from: value) {
                return date
            }
        }
        for format in localFormats {
            if let date = formatter(format, timeZone: timeZone).date(from: value) {
                return date
            }
            // A wall-clock time inside a DST gap (02:30 on the spring-forward
            // day) has no instant in the local zone and is rejected above:
            // read the fields in UTC and let the calendar shift it forward.
            if let utc = TimeZone(secondsFromGMT: 0),
               let fields = formatter(format, timeZone: utc).date(from: value) {
                var utcCalendar = Calendar(identifier: .gregorian)
                utcCalendar.timeZone = utc
                let components = utcCalendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: fields)
                return calendar.date(from: components)
            }
        }
        return nil
    }

    /// Parses a required date argument, reporting the argument name on failure.
    static func parse(_ raw: String?, argument: String, action: String) throws -> Date? {
        guard let raw else { return nil }
        guard let date = parse(raw) else {
            throw MacOSControlError.invalidArgument(
                argument,
                "'\(raw)' is not a recognized date. Use ISO 8601 such as 2026-10-21T15:00:00 or 2026-10-21 (action \(action))."
            )
        }
        return date
    }

    /// True when the raw value names a day without a time of day.
    static func isDateOnly(_ raw: String?) -> Bool {
        guard let raw else { return false }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["today", "tomorrow", "yesterday"].contains(value) {
            return true
        }
        return value.range(of: dateOnlyPattern, options: .regularExpression) != nil
    }

    static func format(_ date: Date?, timeZone: TimeZone = .current) -> String? {
        guard let date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    static func formatDay(_ date: Date?, timeZone: TimeZone = .current) -> String? {
        guard let date else { return nil }
        return formatter("yyyy-MM-dd", timeZone: timeZone).string(from: date)
    }

    /// Midnight that opens the day after the one containing `date`: the
    /// exclusive upper bound used when a plain day is given as `until`.
    static func startOfNextDay(_ date: Date, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
    }

    /// Last second of the day containing `date`: the inclusive end used by
    /// all-day events and recurrence ends given as a plain day.
    static func endOfDay(_ date: Date, timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = timeZone
        return calendar.date(byAdding: .second, value: -1, to: startOfNextDay(date, timeZone: timeZone)) ?? date
    }

    /// Parses the optional `since`/`until` bounds shared by the listing tools:
    /// a plain upper-bound day is inclusive and `until` must be later than
    /// `since`.
    static func listBounds(since sinceRaw: String?, until untilRaw: String?, action: String) throws -> (since: Date?, until: Date?) {
        let since = try parse(sinceRaw, argument: "since", action: action)
        var until = try parse(untilRaw, argument: "until", action: action)
        if let resolved = until, isDateOnly(untilRaw) {
            until = startOfNextDay(resolved)
        }
        if let since, let until, until <= since {
            throw MacOSControlError.invalidArgument("until", "must be later than since.")
        }
        return (since, until)
    }

    /// Parses the UTC ISO strings produced by JavaScript `Date.toISOString()`.
    static func parseJavaScript(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return parse(raw)
    }

    /// Re-expresses a JavaScript ISO string in the local time zone.
    static func localize(_ raw: String?) -> String? {
        format(parseJavaScript(raw))
    }

    /// Formats an instant as the UTC ISO string that JavaScript `new Date()` reads.
    static func javaScript(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func formatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = posixLocale
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }
}
