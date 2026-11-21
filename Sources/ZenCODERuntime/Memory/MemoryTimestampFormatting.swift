//
//  MemoryTimestampFormatting.swift
//  ZenCODE
//
//  The journal timestamp `yyyy-MM-dd HH:mm`, rendered and parsed in a zone.
//

import Foundation

/// Renders and parses the journal timestamp `yyyy-MM-dd HH:mm` with a POSIX
/// `DateFormatter` made for the call. Off Darwin, a zone the formatter cannot
/// use (see the extension below) takes a path without a formatter instead of
/// trapping.
enum MemoryTimestampFormatting {
    static let pattern = "yyyy-MM-dd HH:mm"

    static func string(from date: Date, timeZone: TimeZone) -> String {
        #if !canImport(Darwin)
        guard coreFoundationCanLoad(identifier: timeZone.identifier) else {
            return wallClockString(from: date, timeZone: timeZone)
        }
        #endif
        return makeFormatter(timeZone: timeZone).string(from: date)
    }

    static func date(from text: String, timeZone: TimeZone) -> Date? {
        #if !canImport(Darwin)
        guard coreFoundationCanLoad(identifier: timeZone.identifier) else {
            return wallClockDate(from: text, timeZone: timeZone)
        }
        #endif
        return makeFormatter(timeZone: timeZone).date(from: text)
    }

    private static func makeFormatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = pattern
        return formatter
    }
}

#if !canImport(Darwin)
/// Zones a `DateFormatter` cannot use.
///
/// swift-corelibs-foundation hands a formatter's zone to CoreFoundation by
/// name and traps (`NSTimeZone._cfObject`) when `CFTimeZoneCreateWithName`
/// finds no data for it. That happens for the legacy aliases
/// `TimeZone(identifier:)` still takes from ICU but whose TZif file is missing
/// (Debian 13 ships `Asia/Calcutta`, `Europe/Kiev`, `US/Pacific`, ... only in
/// `tzdata-legacy`). Such a zone is rendered and parsed from its offsets, with
/// the results a `DateFormatter` gives on Darwin.
extension MemoryTimestampFormatting {
    /// Where CoreFoundation reads zones: fixed when it is built, `TZDIR` is
    /// not honored.
    private static let zoneinfoDirectory = "/usr/share/zoneinfo/"

    /// The entries of CoreFoundation's abbreviation table that
    /// `TimeZone(identifier:)` accepts: such a name is loaded from the file it
    /// maps to before its own.
    static let coreFoundationAbbreviations: [String: String] = [
        "ART": "America/Argentina/Buenos_Aires", "AST": "America/Halifax", "BST": "Europe/London",
        "CAT": "Africa/Harare", "CET": "Europe/Paris", "CST": "America/Chicago",
        "EAT": "Africa/Addis_Ababa", "EET": "Europe/Istanbul", "EST": "America/New_York",
        "HST": "Pacific/Honolulu", "IST": "Asia/Calcutta", "JST": "Asia/Tokyo",
        "MST": "America/Denver", "PST": "America/Los_Angeles", "WET": "Europe/Lisbon",
    ]

    /// Whether `CFTimeZoneCreateWithName` finds the zone, without calling it:
    /// a fixed `GMT±HH` or `GMT±HHMM` name, else the file of an abbreviation,
    /// else the file the identifier names.
    ///
    /// Order and table are those of CFTimeZone.c in swift-corelibs-foundation
    /// 6.4.2. Should a later release change them, a zone this wrongly calls
    /// usable traps as it did before this check, one it wrongly calls unusable
    /// just takes the path below, with the same result;
    /// `MemoryTimestampLegacyZoneTests` checks the running toolchain.
    static func coreFoundationCanLoad(identifier: String) -> Bool {
        if isFixedOffsetName(identifier) {
            return true
        }
        if let file = coreFoundationAbbreviations[identifier], isTZifFile(named: file) {
            return true
        }
        return isTZifFile(named: identifier)
    }

    /// `GMT+HH`, `GMT-HH`, `GMT+HHMM` or `GMT-HHMM`, at most 14 hours: the
    /// names CoreFoundation makes without a file.
    private static func isFixedOffsetName(_ identifier: String) -> Bool {
        guard identifier.hasPrefix("GMT+") || identifier.hasPrefix("GMT-") else {
            return false
        }
        let digits = identifier.utf8.dropFirst(4).map { Int($0) - Int(UInt8(ascii: "0")) }
        guard digits.count == 2 || digits.count == 4,
              digits.allSatisfy({ (0...9).contains($0) }),
              digits[0] * 10 + digits[1] <= 14 else {
            return false
        }
        return digits.count == 2 || digits[2] * 10 + digits[3] <= 59
    }

    private static func isTZifFile(named name: String) -> Bool {
        let path = zoneinfoDirectory + name
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              let file = FileHandle(forReadingAtPath: path) else {
            return false
        }
        defer { try? file.close() }
        return (try? file.read(upToCount: 4)) == Data("TZif".utf8)
    }

    /// `date` as `yyyy-MM-dd HH:mm` on the wall clock of `timeZone`, in the
    /// calendar a POSIX `DateFormatter` uses (Julian before October 1582).
    static func wallClockString(from date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let fields = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return "\(padded(fields.year, 4))-\(padded(fields.month, 2))-\(padded(fields.day, 2))"
            + " \(padded(fields.hour, 2)):\(padded(fields.minute, 2))"
    }

    /// `text` read on the wall clock of `timeZone` as a strict `DateFormatter`
    /// reads it, but only in the exact form `yyyy-MM-dd HH:mm`: a field out of
    /// range or a skipped time is `nil`, a repeated time is the later instant.
    static func wallClockDate(from text: String, timeZone: TimeZone) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 16,
              bytes[4] == UInt8(ascii: "-"), bytes[7] == UInt8(ascii: "-"),
              bytes[10] == UInt8(ascii: " "), bytes[13] == UInt8(ascii: ":") else {
            return nil
        }
        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for byte in bytes[range] {
                guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) else {
                    return nil
                }
                value = value * 10 + Int(byte - UInt8(ascii: "0"))
            }
            return value
        }
        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
              let hour = number(11..<13), let minute = number(14..<16),
              year >= 1, (1...12).contains(month), (0...23).contains(hour), (0...59).contains(minute) else {
            return nil
        }
        // The wall clock time counted as GMT; a day outside its month is out
        // of range, as for a strict formatter.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let monthStart = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              calendar.range(of: .day, in: .month, for: monthStart)?.contains(day) == true,
              let wallClock = calendar.date(
                  from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
              ) else {
            return nil
        }
        // Every offset the zone has within a day of that time; an instant
        // counts when it shows the time under the offset it was made with.
        let start = wallClock.addingTimeInterval(-86_400)
        let end = wallClock.addingTimeInterval(86_400)
        var offsets: Set<Int> = [timeZone.secondsFromGMT(for: start)]
        var cursor = start
        while let transition = timeZone.nextDaylightSavingTimeTransition(after: cursor),
              transition > cursor, transition <= end {
            offsets.insert(timeZone.secondsFromGMT(for: transition))
            cursor = transition
        }
        return offsets
            .compactMap { offset -> Date? in
                let instant = wallClock.addingTimeInterval(-TimeInterval(offset))
                return timeZone.secondsFromGMT(for: instant) == offset ? instant : nil
            }
            .max()
    }

    private static func padded(_ value: Int?, _ width: Int) -> String {
        let digits = String(value ?? 0)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }
}
#endif
