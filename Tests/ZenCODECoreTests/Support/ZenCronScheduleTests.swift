//
//  ZenCronScheduleTests.swift
//  ZenCODE
//

import Foundation
import Testing
@testable import ZenCODECore

@Suite("Cron schedule")
struct ZenCronScheduleTests {
    /// The offending field reported by `ZenCronScheduleError.invalid`, or nil when the text parses.
    private func rejectedField(_ text: String) -> String? {
        do {
            _ = try ZenCronSchedule(parsing: text)
            return nil
        } catch let ZenCronScheduleError.invalid(field, _) {
            return field
        } catch {
            return "unexpected error: \(error)"
        }
    }

    /// The reason reported by `ZenCronScheduleError.invalid`, or nil when the text parses.
    private func rejectedReason(_ text: String) -> String? {
        do {
            _ = try ZenCronSchedule(parsing: text)
            return nil
        } catch let ZenCronScheduleError.invalid(_, reason) {
            return reason
        } catch {
            return "unexpected error: \(error)"
        }
    }

    @Test(arguments: [
        "@reboot", "@yearly", "@annually", "@monthly",
        "@weekly", "@daily", "@midnight", "@hourly"
    ])
    func acceptsEveryAlias(_ alias: String) throws {
        #expect(try ZenCronSchedule(parsing: alias).rawValue == alias)
    }

    @Test
    func aliasesAreCaseInsensitiveAndNormalizedToLowercase() throws {
        #expect(try ZenCronSchedule(parsing: "@DAILY").rawValue == "@daily")
        #expect(try ZenCronSchedule(parsing: "  @Reboot\n").rawValue == "@reboot")
    }

    @Test(arguments: [
        ("* * * * *", "* * * * *"),
        ("*/15 * * * *", "*/15 * * * *"),
        ("0 9 * * 1-5", "0 9 * * 1-5"),
        ("0,30 8-17/2 1,15 * *", "0,30 8-17/2 1,15 * *"),
        ("59 23 31 12 7", "59 23 31 12 7"),
        ("0 0 1 1 0", "0 0 1 1 0"),
        ("0 9 * 1 1", "0 9 * 1 1"),
        ("0 9 * 1,3 1,5", "0 9 * 1,3 1,5"),
        ("5-10/3 * * * *", "5-10/3 * * * *"),
        ("0 0 * 6-8 6", "0 0 * 6-8 6"),
        ("  0\t9   *  *   *  ", "0 9 * * *")
    ])
    func acceptsFiveFieldsAndNormalizesThem(_ input: String, _ expected: String) throws {
        #expect(try ZenCronSchedule(parsing: input).rawValue == expected)
    }

    @Test
    func equalSchedulesCompareEqualAfterNormalization() throws {
        #expect(try ZenCronSchedule(parsing: "0  9 * 1 *") == ZenCronSchedule(parsing: "0 9 * 1 *"))
        #expect(try ZenCronSchedule(parsing: "0 9 * * *") != ZenCronSchedule(parsing: "0 10 * * *"))
    }

    @Test(arguments: [
        "", "   ", "\n",
        "* * * *", "* * * * * *", "0 9 * *",
        "@never", "@", "@daily extra", "@ daily",
        "daily"
    ])
    func rejectsWrongShapeAsScheduleError(_ text: String) {
        #expect(rejectedField(text) == "schedule")
    }

    @Test(arguments: [
        ("60 * * * *", "minute"),
        ("-1 * * * *", "minute"),
        ("+5 * * * *", "minute"),
        ("*/0 * * * *", "minute"),
        ("*/ * * * *", "minute"),
        ("*/x * * * *", "minute"),
        ("*/-1 * * * *", "minute"),
        ("5-3 * * * *", "minute"),
        ("1-5/0 * * * *", "minute"),
        ("1-5/ * * * *", "minute"),
        ("1-5-7 * * * *", "minute"),
        ("5/2 * * * *", "minute"),
        ("*,5 * * * *", "minute"),
        ("1,,2 * * * *", "minute"),
        ("1, * * * *", "minute"),
        (",1 * * * *", "minute"),
        ("1- * * * *", "minute"),
        ("a * * * *", "minute"),
        ("99999999999999999999 * * * *", "minute"),
        ("\u{0663} * * * *", "minute"),
        ("* 24 * * *", "hour"),
        ("* 5-30 * * *", "hour"),
        ("* * 0 * *", "day-of-month"),
        ("* * 32 * *", "day-of-month"),
        ("* * mon * *", "day-of-month"),
        ("* * * 0 *", "month"),
        ("* * * 13 *", "month"),
        ("* * * foo *", "month"),
        ("* * * mon *", "month"),
        ("* * * jan *", "month"),
        ("* * * jan-mar *", "month"),
        ("* * * jan/2 *", "month"),
        ("* * * * 8", "day-of-week"),
        ("* * * * jan", "day-of-week"),
        ("* * * * mon", "day-of-week"),
        ("* * * * MON,Fri", "day-of-week"),
        ("* * * * mon-fri", "day-of-week"),
        ("* * * * 1-mon", "day-of-week"),
        ("* * * * sun/2", "day-of-week")
    ])
    func rejectsInvalidFieldsAndNamesTheField(_ text: String, _ field: String) {
        #expect(rejectedField(text) == field)
    }

    @Test(arguments: [
        ("* * * jan *", "'jan' is not a valid value; use a number 1-12"),
        ("* * * * mon", "'mon' is not a valid value; use a number 0-7 (0 and 7 = Sunday)")
    ])
    func nameInMonthOrWeekdayReasonPointsToTheNumericRange(_ text: String, _ reason: String) {
        #expect(rejectedReason(text) == reason)
    }

    @Test
    func errorDescriptionNamesTheFieldAndSuggestsTheShape() {
        let error = ZenCronScheduleError.invalid(field: "hour", reason: "24 is out of range 0-23")
        let description = error.errorDescription ?? ""
        #expect(description.contains("hour"))
        #expect(description.contains("24 is out of range 0-23"))
        #expect(description.contains("@daily"))
    }

    @Test
    func validatedFieldsContainOnlyCrontabSafeCharacters() throws {
        let schedule = try ZenCronSchedule(parsing: " 1,2-4/2 \t 5 * 2\t 0 ")
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789*/,- ")
        #expect(schedule.rawValue.allSatisfy { allowed.contains($0) })
        #expect(!schedule.rawValue.contains("\n"))
        #expect(!schedule.rawValue.contains("\t"))
    }
}
