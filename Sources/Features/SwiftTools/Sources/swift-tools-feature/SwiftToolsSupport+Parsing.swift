//
//  SwiftToolsSupport+Parsing.swift
//  ZenCODE
//
//  Created by Gerardo Grisolini on 31/05/26.
//

import ToolCore
import Foundation
import FeatureKit

extension SwiftToolsSupport {
    enum Severity {
        case error
        case warning
    }

    struct Diagnostic {
        let severity: Severity
        let location: String
        let message: String

        var formatted: String {
            location.isEmpty ? message : "\(location): \(message)"
        }
    }

    /// Parses `file:line:col: error|warning: message` diagnostics, deduplicated.
    static func parseDiagnostics(from output: String) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []
        var seen = Set<String>()
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let (severity, markerRange) = severityMarker(in: trimmed) else {
                continue
            }
            let location = String(trimmed[..<markerRange.lowerBound])
                .trimmingCharacters(in: CharacterSet(charactersIn: " :"))
            let message = String(trimmed[markerRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            let key = "\(location)|\(message)"
            guard seen.insert(key).inserted else {
                continue
            }
            diagnostics.append(
                Diagnostic(severity: severity, location: location, message: message)
            )
        }
        return diagnostics
    }

    /// The severity and the range of its `error:`/`warning:` marker. The marker
    /// must either open the line or follow a `file:line:col` prefix (`: error:`),
    /// so prose and paths that merely contain the word are not matched, and the
    /// location is cut at the marker rather than at an earlier occurrence of
    /// the word inside the path.
    private static func severityMarker(in line: String) -> (Severity, Range<String.Index>)? {
        for (severity, word) in [(Severity.error, "error:"), (.warning, "warning:")] {
            if line.hasPrefix(word + " ") || line == word, let range = line.range(of: word) {
                return (severity, range)
            }
            if let range = line.range(of: ": " + word) {
                return (severity, line.index(range.lowerBound, offsetBy: 2) ..< range.upperBound)
            }
        }
        return nil
    }

    /// Captures both XCTest and swift-testing failure lines.
    static func parseTestFailures(from output: String) -> [String] {
        var failures: [String] = []
        var seen = Set<String>()
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFailure = (trimmed.contains("error:") && trimmed.contains(" failed"))
                || trimmed.hasPrefix("✘")
                || trimmed.contains("recorded an issue")
                || (trimmed.contains("Test Case") && trimmed.contains("failed"))
            // The run-level summary carries the same failure mark but is not a
            // failing test; it is reported separately as the run summary.
            guard isFailure, !isTestRunSummary(trimmed) else {
                continue
            }
            guard seen.insert(trimmed).inserted else {
                continue
            }
            failures.append(trimmed)
        }
        return failures
    }

    /// True for the Swift Testing run-level summary line, which is not a test
    /// failure even when it is prefixed with the failure mark.
    static func isTestRunSummary(_ line: String) -> Bool {
        line.contains("Test run with")
    }

    /// Every run-level summary produced by the command, in output order.
    ///
    /// `swift test` emits one summary per test bundle, and Swift Testing and
    /// XCTest each report separately, so keeping only the last line reports a
    /// single bundle as if it were the whole run. All summaries are returned so
    /// the caller can surface the complete picture.
    static func parseTestSummaries(from output: String) -> [String] {
        var legacySummaries: [String] = []
        var swiftTestingSummaries: [String] = []
        var seen = Set<String>()
        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Swift Testing (import Testing) reports with "Test run with …".
            // It is the authoritative summary when present because it reflects
            // the actual matched tests, while the legacy XCTest runner may
            // print "Executed 0 tests" for the same filter.
            if isTestRunSummary(trimmed) {
                guard seen.insert(trimmed).inserted else { continue }
                swiftTestingSummaries.append(trimmed)
            } else if trimmed.hasPrefix("Executed ")
                || (trimmed.hasPrefix("Test Suite") && (trimmed.contains("passed") || trimmed.contains("failed"))) {
                guard seen.insert(trimmed).inserted else { continue }
                legacySummaries.append(trimmed)
            }
        }
        return swiftTestingSummaries.isEmpty ? legacySummaries : swiftTestingSummaries
    }

    /// Totals across every Swift Testing summary line, so a multi-bundle run is
    /// reported as one number instead of the last bundle's number.
    static func aggregateTestSummary(_ summaries: [String]) -> String? {
        let runSummaries = summaries.filter(isTestRunSummary)
        guard runSummaries.count > 1 else { return nil }

        var tests = 0
        var suites = 0
        var failed = false
        for summary in runSummaries {
            tests += count(of: "test", in: summary) ?? 0
            suites += count(of: "suite", in: summary) ?? 0
            if summary.contains("failed") {
                failed = true
            }
        }
        guard tests > 0 else { return nil }

        var text = "\(tests) tests"
        if suites > 0 {
            text += " in \(suites) suites"
        }
        return text + " across \(runSummaries.count) runs \(failed ? "failed" : "passed")"
    }

    /// Reads the integer immediately preceding a noun such as `tests`/`suites`.
    private static func count(of noun: String, in line: String) -> Int? {
        let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
        for (index, token) in tokens.enumerated()
        where token.lowercased().hasPrefix(noun) && index > 0 {
            if let value = Int(tokens[index - 1]) {
                return value
            }
        }
        return nil
    }

    /// Upper bound for a single raw-output line. Toolchain failures echo the
    /// whole `swift-frontend` invocation on one line, which is several thousand
    /// characters and would otherwise consume the entire output budget and push
    /// the actual diagnostics out of view.
    private static let maximumRawLineLength = 500

    static func tail(of text: String, lines count: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        return lines.suffix(count).map(clampLineLength).joined(separator: "\n")
    }

    private static func clampLineLength(_ line: String) -> String {
        guard line.count > maximumRawLineLength else { return line }
        let elided = line.count - maximumRawLineLength
        return line.prefix(maximumRawLineLength) + "… (+\(elided) characters elided)"
    }
}
