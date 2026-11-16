//
//  MemoryJSONDateCoding.swift
//  ZenCODE
//
//  The ISO-8601 date coding of the graph persistence format, with nanosecond
//  fractions on write and whole-second or fractional dates on read.
//

import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Date coding used by the graph persistence format.
///
/// Foundation's built-in `.iso8601` encoder emits whole seconds (and
/// `ISO8601DateFormatter` with `.withFractionalSeconds` is limited to
/// milliseconds on some platforms). A graph mutation can therefore reload a
/// `Date` under the persistence lock with its subsecond component truncated.
/// Keep the existing ISO-8601 string schema, but write a nanosecond fraction so
/// a normal `Date` round-trip remains exact. The decoder deliberately accepts
/// both the old whole-second representation and fractional representations.
enum MemoryJSONDateCoding {
    static func encodingStrategy() -> JSONEncoder.DateEncodingStrategy {
        .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(string(from: date))
        }
    }

    static func decodingStrategy() -> JSONDecoder.DateDecodingStrategy {
        .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = fractionalDate(from: value) {
                return date
            }

            if let date = try? Date.ISO8601FormatStyle(
                includingFractionalSeconds: true
            ).parse(value) {
                return date
            }

            // Keep a Foundation formatter fallback for ISO-8601 spellings
            // accepted by older `.iso8601` implementations but not by the
            // value-type parser on every supported platform.
            let fractionalFormatter = ISO8601DateFormatter()
            fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractionalFormatter.date(from: value) {
                return date
            }

            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) {
                return date
            }

            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 date string."
            )
        }
    }

    /// Parses a fractional ISO-8601 value by adding the fraction to the
    /// already-decoded whole-second `Date`. Doing the addition at Date's
    /// reference-epoch magnitude avoids the one-ULP drift that can occur when
    /// a Unix-epoch `Double` is formed first and the reference offset is later
    /// subtracted by Foundation.
    private static func fractionalDate(from value: String) -> Date? {
        guard let decimalPoint = value.firstIndex(of: ".") else { return nil }
        let suffix = value[decimalPoint...]
        guard let zoneStart = suffix.firstIndex(where: { character in
            character == "Z" || character == "+" || character == "-"
        }) else {
            return nil
        }

        let fractionStart = value.index(after: decimalPoint)
        guard fractionStart < zoneStart else { return nil }
        let fractionText = value[fractionStart..<zoneStart]
        guard fractionText.allSatisfy(\.isNumber),
              let fraction = Double("0." + fractionText) else {
            return nil
        }

        let wholeSecondsText = String(value[..<decimalPoint]) + String(value[zoneStart...])
        guard let wholeDate = try? Date.ISO8601FormatStyle().parse(wholeSecondsText) else {
            return nil
        }
        return wholeDate.addingTimeInterval(fraction)
    }

    private static func string(from date: Date) -> String {
        // Date's internal reference epoch (2001-01-01) is deliberately used
        // for the split. It has a smaller magnitude than Unix seconds, so the
        // fraction survives the later ISO calendar conversion without an ULP
        // changing the reconstructed Date.
        var wholeSeconds = floor(date.timeIntervalSinceReferenceDate)
        var nanoseconds = Int(
            ((date.timeIntervalSinceReferenceDate - wholeSeconds) * 1_000_000_000).rounded()
        )
        if nanoseconds >= 1_000_000_000 {
            wholeSeconds += 1
            nanoseconds = 0
        }

        // Formatting the integral second through Foundation keeps calendar,
        // leap-year and pre-epoch handling in the standard implementation.
        let base = Date(timeIntervalSinceReferenceDate: wholeSeconds).ISO8601Format()
        let fraction = String(nanoseconds)
        let paddedFraction = String(repeating: "0", count: 9 - fraction.count) + fraction
        return String(base.dropLast()) + "." + paddedFraction + "Z"
    }
}
