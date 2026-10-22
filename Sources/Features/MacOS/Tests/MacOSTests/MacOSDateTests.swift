import Foundation
import Testing

@testable import MacOS

@Suite
struct MacOSDateTests {
    private let rome = TimeZone(identifier: "Europe/Rome")!
    private let utc = TimeZone(secondsFromGMT: 0)!

    private func instant(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private func parse(_ raw: String, now: String = "2026-10-21T10:30:00+02:00") -> Date? {
        MacOSDate.parse(raw, now: instant(now), timeZone: rome)
    }

    @Test
    func acceptsISO8601WithOffsets() {
        #expect(parse("2026-10-21T15:00:00Z") == instant("2026-10-21T15:00:00Z"))
        #expect(parse("2026-10-21T15:00:00+02:00") == instant("2026-10-21T13:00:00Z"))
        #expect(parse("2026-10-21T15:00:00+0200") == instant("2026-10-21T13:00:00Z"))
        #expect(parse("2026-10-21T15:00:00.250Z") == instant("2026-10-21T15:00:00Z").addingTimeInterval(0.25))
    }

    @Test
    func acceptsOffsetFormsWithoutSeconds() {
        #expect(parse("2026-10-21T15:00+02:00") == instant("2026-10-21T13:00:00Z"))
        #expect(parse("2026-10-21T15:00Z") == instant("2026-10-21T15:00:00Z"))
        #expect(parse("2026-10-21 15:00+02:00") == instant("2026-10-21T13:00:00Z"))
    }

    @Test
    func readsValuesWithoutOffsetInTheLocalTimeZone() {
        #expect(parse("2026-10-21T15:00:00") == instant("2026-10-21T13:00:00Z"))
        #expect(parse("2026-10-21T15:00") == instant("2026-10-21T13:00:00Z"))
        #expect(parse("2026-10-21 15:00:00") == instant("2026-10-21T13:00:00Z"))
        #expect(parse("2026-10-21 15:00") == instant("2026-10-21T13:00:00Z"))
        #expect(parse("  2026-10-21  ") == instant("2026-10-20T22:00:00Z"))
        // Winter: UTC+1.
        #expect(parse("2026-01-15 09:00") == instant("2026-01-15T08:00:00Z"))
    }

    @Test
    func resolvesRelativeTokensFromTheInjectedClock() {
        #expect(parse("now") == instant("2026-10-21T10:30:00+02:00"))
        #expect(parse("today") == instant("2026-10-20T22:00:00Z"))
        #expect(parse("Tomorrow") == instant("2026-10-21T22:00:00Z"))
        #expect(parse("yesterday") == instant("2026-10-19T22:00:00Z"))
    }

    @Test
    func toleratesWallClockTimesInsideADSTGap() {
        // 2026-03-29 02:30 does not exist in Europe/Rome; it is shifted forward.
        #expect(parse("2026-03-29 02:30") == instant("2026-03-29T01:30:00Z"))
        // The repeated hour on the fall-back day resolves to a valid instant.
        let overlap = parse("2026-10-25 02:30")
        #expect(overlap == instant("2026-10-25T00:30:00Z") || overlap == instant("2026-10-25T01:30:00Z"))
    }

    @Test
    func rejectsGarbageAndImpossibleDates() {
        #expect(parse("") == nil)
        #expect(parse("next week") == nil)
        #expect(parse("2026-02-30") == nil)
        #expect(parse("2026-13-01") == nil)
        #expect(parse("2026-10-21 25:00") == nil)
        #expect(parse("21/10/2026") == nil)
    }

    @Test
    func reportsTheArgumentOnFailure() throws {
        #expect(throws: MacOSControlError.self) {
            try MacOSDate.parse("bogus", argument: "start", action: "events")
        }
        #expect(try MacOSDate.parse(nil, argument: "start", action: "events") == nil)
        do {
            _ = try MacOSDate.parse("bogus", argument: "start", action: "events")
            Issue.record("expected an error")
        } catch let error as MacOSControlError {
            let description = error.errorDescription ?? ""
            #expect(description.contains("'start'"))
            #expect(description.contains("bogus"))
        }
    }

    @Test
    func detectsDateOnlyValues() {
        #expect(MacOSDate.isDateOnly("2026-10-21"))
        #expect(MacOSDate.isDateOnly(" today "))
        #expect(MacOSDate.isDateOnly("TOMORROW"))
        #expect(!MacOSDate.isDateOnly("2026-10-21T00:00"))
        #expect(!MacOSDate.isDateOnly("now"))
        #expect(!MacOSDate.isDateOnly(nil))
    }

    @Test
    func formatsWithTheLocalOffsetAndAsPlainDays() {
        let date = instant("2026-10-21T13:00:00Z")
        #expect(MacOSDate.format(date, timeZone: rome) == "2026-10-21T15:00:00+02:00")
        #expect(MacOSDate.format(date, timeZone: utc) == "2026-10-21T13:00:00Z")
        #expect(MacOSDate.formatDay(instant("2026-10-20T22:30:00Z"), timeZone: rome) == "2026-10-21")
        #expect(MacOSDate.format(nil) == nil)
        #expect(MacOSDate.formatDay(nil) == nil)
    }

    @Test
    func roundTripsJavaScriptDates() {
        let date = instant("2026-10-21T13:00:00Z")
        #expect(MacOSDate.javaScript(date) == "2026-10-21T13:00:00.000Z")
        #expect(MacOSDate.parseJavaScript("2026-10-21T13:00:00.000Z") == date)
        #expect(MacOSDate.parseJavaScript(nil) == nil)
        #expect(MacOSDate.localize("not a date") == nil)
    }

    @Test
    func computesInclusiveDayEndsInTheGivenTimeZone() {
        // 2026-10-21 in Rome is UTC+2: the day runs 22:00Z (20th) to 22:00Z (21st).
        let midnight = instant("2026-10-20T22:00:00Z")
        #expect(MacOSDate.startOfNextDay(midnight, timeZone: rome) == instant("2026-10-21T22:00:00Z"))
        #expect(MacOSDate.endOfDay(midnight, timeZone: rome) == instant("2026-10-21T21:59:59Z"))
        // Any instant inside the day yields the same bounds as its midnight.
        let afternoon = instant("2026-10-21T13:00:00Z")
        #expect(MacOSDate.startOfNextDay(afternoon, timeZone: rome) == instant("2026-10-21T22:00:00Z"))
        #expect(MacOSDate.endOfDay(afternoon, timeZone: rome) == instant("2026-10-21T21:59:59Z"))
        // The same instant is still the 21st in UTC, with UTC bounds.
        #expect(MacOSDate.startOfNextDay(afternoon, timeZone: utc) == instant("2026-10-22T00:00:00Z"))
        #expect(MacOSDate.endOfDay(afternoon, timeZone: utc) == instant("2026-10-21T23:59:59Z"))
        // DST transitions: the spring-forward day has 23 hours, the fall-back day 25.
        let springForward = instant("2026-03-28T23:00:00Z")
        #expect(MacOSDate.startOfNextDay(springForward, timeZone: rome) == instant("2026-03-29T22:00:00Z"))
        #expect(MacOSDate.endOfDay(springForward, timeZone: rome) == instant("2026-03-29T21:59:59Z"))
        let fallBack = instant("2026-10-24T22:00:00Z")
        #expect(MacOSDate.startOfNextDay(fallBack, timeZone: rome) == instant("2026-10-25T23:00:00Z"))
        #expect(MacOSDate.endOfDay(fallBack, timeZone: rome) == instant("2026-10-25T22:59:59Z"))
    }

    @Test
    func listBoundsMakePlainUntilDaysInclusiveAndRejectInvertedRanges() throws {
        let open = try MacOSDate.listBounds(since: nil, until: nil, action: "list")
        #expect(open.since == nil && open.until == nil)

        let explicit = try MacOSDate.listBounds(since: "2026-10-20T08:00:00Z", until: "2026-10-21T08:00:00Z", action: "list")
        #expect(explicit.since == instant("2026-10-20T08:00:00Z"))
        #expect(explicit.until == instant("2026-10-21T08:00:00Z"))

        // A plain day as `until` extends to the start of the following local day.
        let inclusive = try MacOSDate.listBounds(since: nil, until: "2026-10-21", action: "list")
        let untilDay = try #require(MacOSDate.parse("2026-10-21"))
        #expect(inclusive.until == MacOSDate.startOfNextDay(untilDay))
        #expect(inclusive.since == nil)

        #expect(throws: MacOSControlError.self) {
            try MacOSDate.listBounds(since: "2026-10-21T10:00:00Z", until: "2026-10-21T09:00:00Z", action: "list")
        }
        #expect(throws: MacOSControlError.self) {
            try MacOSDate.listBounds(since: "2026-10-21T10:00:00Z", until: "2026-10-21T10:00:00Z", action: "list")
        }
        #expect(throws: MacOSControlError.self) {
            try MacOSDate.listBounds(since: "bogus", until: nil, action: "list")
        }
    }
}
