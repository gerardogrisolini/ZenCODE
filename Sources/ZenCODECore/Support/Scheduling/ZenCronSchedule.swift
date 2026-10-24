//
//  ZenCronSchedule.swift
//  ZenCODE
//

import Foundation

/// A validation failure for a cron schedule expression.
enum ZenCronScheduleError: LocalizedError, Equatable {
    /// `field` names the offending part (`schedule`, `minute`, `hour`,
    /// `day-of-month`, `month`, `day-of-week`); `reason` explains why.
    case invalid(field: String, reason: String)

    var errorDescription: String? {
        switch self {
        case let .invalid(field, reason):
            return "Invalid cron schedule (\(field)): \(reason). Use five fields (minute hour day-of-month month day-of-week) or an alias such as @daily."
        }
    }
}

/// A validated, normalized cron schedule.
///
/// Accepts either one of the aliases `@reboot @yearly @annually @monthly
/// @weekly @daily @midnight @hourly` (case-insensitive) or exactly five
/// whitespace-separated fields. Every field is `*`, `*/step`, or a
/// comma-separated list of `n`, `a-b` and `a-b/step`. `rawValue` is lowercase
/// with fields joined by a single space, so it is safe to place on a crontab
/// line.
struct ZenCronSchedule: Sendable, Equatable {
    let rawValue: String

    init(parsing text: String) throws {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !tokens.isEmpty else {
            throw ZenCronScheduleError.invalid(field: "schedule", reason: "the schedule is empty")
        }

        if tokens.count == 1, tokens[0].hasPrefix("@") {
            let alias = tokens[0].lowercased()
            guard Self.aliases.contains(alias) else {
                throw ZenCronScheduleError.invalid(
                    field: "schedule",
                    reason: "unknown alias '\(alias)'"
                )
            }
            rawValue = alias
            return
        }

        guard tokens.count == Self.fieldSpecs.count else {
            throw ZenCronScheduleError.invalid(
                field: "schedule",
                reason: "expected 5 fields or an alias, found \(tokens.count)"
            )
        }

        var normalized: [String] = []
        normalized.reserveCapacity(tokens.count)
        for (token, spec) in zip(tokens, Self.fieldSpecs) {
            normalized.append(try Self.normalizeField(token.lowercased(), spec: spec))
        }
        rawValue = normalized.joined(separator: " ")
    }

    // MARK: - Grammar

    private static let aliases: Set<String> = [
        "@reboot", "@yearly", "@annually", "@monthly", "@weekly", "@daily", "@midnight", "@hourly"
    ]

    private struct FieldSpec {
        let name: String
        let range: ClosedRange<Int>
        /// Set for the fields that take numbers only. A non-numeric value there
        /// is rejected with this hint, which names the numeric range to use.
        let numberHint: String?
    }

    private static let fieldSpecs: [FieldSpec] = [
        FieldSpec(name: "minute", range: 0...59, numberHint: nil),
        FieldSpec(name: "hour", range: 0...23, numberHint: nil),
        FieldSpec(name: "day-of-month", range: 1...31, numberHint: nil),
        FieldSpec(name: "month", range: 1...12, numberHint: "use a number 1-12"),
        FieldSpec(
            name: "day-of-week",
            range: 0...7,
            numberHint: "use a number 0-7 (0 and 7 = Sunday)"
        )
    ]

    /// Validates one lowercase field and returns it unchanged when valid.
    private static func normalizeField(_ field: String, spec: FieldSpec) throws -> String {
        func fail(_ reason: String) -> ZenCronScheduleError {
            .invalid(field: spec.name, reason: reason)
        }

        if field == "*" { return field }

        if field.hasPrefix("*/") {
            let stepText = String(field.dropFirst(2))
            _ = try parseStep(stepText, fail: fail)
            return field
        }

        let items = field.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        for item in items {
            guard !item.isEmpty else {
                throw fail("empty list item in '\(field)'")
            }
            try validateItem(item, spec: spec, fail: fail)
        }
        return field
    }

    /// Validates `n`, `a-b` or `a-b/step`.
    private static func validateItem(
        _ item: String,
        spec: FieldSpec,
        fail: (String) -> ZenCronScheduleError
    ) throws {
        let stepParts = item.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard stepParts.count <= 2 else {
            throw fail("too many '/' in '\(item)'")
        }
        let rangeText = stepParts[0]
        let rangeParts = rangeText.split(separator: "-", omittingEmptySubsequences: false).map(String.init)

        switch rangeParts.count {
        case 1:
            guard stepParts.count == 1 else {
                throw fail("a step requires a range (a-b/step) or '*/step', found '\(item)'")
            }
            _ = try parseValue(rangeParts[0], spec: spec, fail: fail)
        case 2:
            let lower = try parseValue(rangeParts[0], spec: spec, fail: fail)
            let upper = try parseValue(rangeParts[1], spec: spec, fail: fail)
            guard lower <= upper else {
                throw fail("range start \(lower) is greater than range end \(upper)")
            }
            if stepParts.count == 2 {
                _ = try parseStep(stepParts[1], fail: fail)
            }
        default:
            throw fail("malformed range '\(item)'")
        }
    }

    private static func parseValue(
        _ text: String,
        spec: FieldSpec,
        fail: (String) -> ZenCronScheduleError
    ) throws -> Int {
        guard !text.isEmpty else {
            throw fail("missing value")
        }
        guard let number = parseNumber(text) else {
            if let numberHint = spec.numberHint {
                throw fail("'\(text)' is not a valid value; \(numberHint)")
            }
            throw fail("'\(text)' is not a valid value")
        }
        guard spec.range.contains(number) else {
            throw fail("\(number) is out of range \(spec.range.lowerBound)-\(spec.range.upperBound)")
        }
        return number
    }

    private static func parseStep(
        _ text: String,
        fail: (String) -> ZenCronScheduleError
    ) throws -> Int {
        guard let step = parseNumber(text) else {
            throw fail("'\(text)' is not a valid step")
        }
        guard step >= 1 else {
            throw fail("the step must be at least 1")
        }
        return step
    }

    /// Parses a non-empty run of ASCII digits (no sign, no other numerals).
    private static func parseNumber(_ text: String) -> Int? {
        guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }) else {
            return nil
        }
        return Int(text)
    }
}
