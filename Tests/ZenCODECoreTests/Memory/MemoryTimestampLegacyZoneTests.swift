//
//  MemoryTimestampLegacyZoneTests.swift
//  ZenCODECoreTests (memory)
//
//  Legacy zone names a `DateFormatter` cannot use on Linux: journal
//  timestamps in them render and parse as a `DateFormatter` does on Darwin.
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite struct MemoryTimestampLegacyZoneTests {
    @Test
    func legacyZonesRenderAndParseAsOnDarwin() async {
        await Task.yield()
        // A `DateFormatter` on macOS: a repeated wall time is the later instant.
        let cases: [(zone: String, seconds: TimeInterval, text: String)] = [
            ("Asia/Calcutta", 1_800_000_000, "2027-01-15 13:30"),
            ("Asia/Katmandu", 1_800_000_000, "2027-01-15 13:45"),
            ("Europe/Kiev", 1_792_891_800, "2026-10-25 03:30"),     // repeated hour, EET
            ("US/Pacific", 1_793_525_400, "2026-11-01 01:30"),      // repeated hour, PST
        ]
        for item in cases {
            guard let timeZone = TimeZone(identifier: item.zone) else { continue }
            let date = Date(timeIntervalSince1970: item.seconds)
            let stamp = "\(item.text) \(item.zone)"
            #expect(MemoryService.timestampString(date, timeZone: timeZone) == stamp)
            #expect(MemoryEntryMetadata.date(fromTimestamp: stamp) == date, "\(stamp)")
            #expect(MemoryAutoTimestamp.isGeneratedLine("Timestamp: " + stamp), "\(stamp)")
        }
        guard let kiev = TimeZone(identifier: "Europe/Kiev") else { return }
        // A skipped wall time and malformed texts are nil, as on macOS.
        let rejected = [
            "2026-03-29 03:30", "2026-02-30 10:00", "2026-05-27 24:00", "2026-05-27 10:00:00", "yesterday", "",
        ]
        for text in rejected {
            #expect(MemoryTimestampFormatting.date(from: text, timeZone: kiev) == nil, "\(text)")
        }
    }

    #if !canImport(Darwin)
    /// The CoreFoundation lookup copied from swift-corelibs-foundation 6.4.2,
    /// against the running toolchain: a zone judged usable goes through a
    /// `DateFormatter` (a wrong judgement traps here) and, outside the
    /// abbreviations CoreFoundation loads from another zone's file, the path
    /// without a formatter returns what the formatter returns.
    @Test
    func coreFoundationJudgementHoldsOnThisToolchain() async {
        await Task.yield()
        let names = TimeZone.knownTimeZoneIdentifiers
            + Array(MemoryTimestampFormatting.coreFoundationAbbreviations.keys)
            + ["US/Pacific", "Asia/Saigon", "Eire", "GB", "GMT0", "NST", "GMT+0100", "GMT+1500"]
        let dates = [0, 1_774_746_000, 1_792_890_000].map { Date(timeIntervalSince1970: $0) }
        for name in names {
            guard let timeZone = TimeZone(identifier: name),
                  MemoryTimestampFormatting.coreFoundationCanLoad(identifier: timeZone.identifier) else { continue }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = MemoryTimestampFormatting.pattern
            for date in dates {
                let text = formatter.string(from: date)
                guard MemoryTimestampFormatting.coreFoundationAbbreviations[timeZone.identifier] == nil else { continue }
                #expect(MemoryTimestampFormatting.wallClockString(from: date, timeZone: timeZone) == text, "\(name)")
                #expect(
                    MemoryTimestampFormatting.wallClockDate(from: text, timeZone: timeZone) == formatter.date(from: text),
                    "\(name) \(text)"
                )
            }
        }
    }
    #endif
}
