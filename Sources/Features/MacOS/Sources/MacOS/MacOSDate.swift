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

    static func parse(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        switch value.lowercased() {
        case "now":
            return Date()
        case "today":
            return Calendar.current.startOfDay(for: Date())
        case "tomorrow":
            return Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
        case "yesterday":
            return Calendar.current.date(byAdding: .day, value: -1, to: Calendar.current.startOfDay(for: Date()))
        default:
            break
        }

        let isoWithFraction = ISO8601DateFormatter()
        isoWithFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithFraction.date(from: value) {
            return date
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) {
            return date
        }

        let localFormats = [
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
        ]
        for format in localFormats {
            let formatter = DateFormatter()
            formatter.locale = posixLocale
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
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

    static func format(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    static func formatDay(_ date: Date?) -> String? {
        guard let date else { return nil }
        let formatter = DateFormatter()
        formatter.locale = posixLocale
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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
}
